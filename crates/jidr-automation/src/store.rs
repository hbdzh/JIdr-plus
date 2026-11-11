//! Persistent script library under `<Jidr data>/scripts/`.
//!
//! One pretty-printed JSON file per script, named by id (`<uuid>.json`), so a
//! script is portable: import/export moves the same file. Writes are atomic
//! (temp file + rename) so a crash never leaves a truncated script, and
//! `list()` skips files that are not valid scripts instead of failing the
//! whole library.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

use jidr_core::{ErrorCode, JidrError, JidrResult, ResultExt};
use uuid::Uuid;

use crate::model::{Script, ScriptSummary};
use crate::validate::{validate, validate_name};

/// Largest script file the store reads or imports, in bytes.
pub const MAX_SCRIPT_BYTES: u64 = 64 * 1024 * 1024;

/// Unique suffix for the temporary file of an atomic write.
static TEMP_COUNTER: AtomicU64 = AtomicU64::new(0);

/// The script library rooted at one Jidr data directory.
#[derive(Debug, Clone)]
pub struct ScriptStore {
    dir: PathBuf,
}

impl ScriptStore {
    /// Uses `<data_dir>/scripts` as the library directory (it is created on
    /// the first save, and a missing directory simply lists as empty).
    pub fn new(data_dir: impl AsRef<Path>) -> Self {
        Self {
            dir: data_dir.as_ref().join("scripts"),
        }
    }

    /// The library directory.
    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// Lists valid scripts, newest first. Corrupt or foreign files are skipped.
    pub fn list(&self) -> JidrResult<Vec<ScriptSummary>> {
        let entries = match std::fs::read_dir(&self.dir) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
            Err(error) => {
                return Err(JidrError::unexpected(format!(
                    "listing {}: {error}",
                    self.dir.display()
                )));
            }
        };
        let mut scripts = Vec::new();
        for entry in entries {
            let entry = entry.ctx(
                ErrorCode::Unexpected,
                format!("listing {}", self.dir.display()),
            )?;
            let path = entry.path();
            if path.extension().and_then(|extension| extension.to_str()) != Some("json")
                || !path.is_file()
            {
                continue;
            }
            // A corrupt script must not hide the rest of the library.
            if let Ok(script) = self.read_script(&path) {
                scripts.push(script.summary());
            }
        }
        scripts.sort_by(|left, right| {
            right
                .created_at
                .cmp(&left.created_at)
                .then_with(|| left.id.cmp(&right.id))
        });
        Ok(scripts)
    }

    /// Loads and validates one script.
    pub fn load(&self, id: &Uuid) -> JidrResult<Script> {
        self.read_script(&self.path_for(id))
    }

    /// Validates and writes a script atomically.
    pub fn save(&self, script: &Script) -> JidrResult<()> {
        validate(script)?;
        std::fs::create_dir_all(&self.dir).ctx(
            ErrorCode::Unexpected,
            format!("creating {}", self.dir.display()),
        )?;
        let bytes = encode(script)?;
        write_atomic(&self.path_for(&script.id), &bytes)
    }

    /// Deletes one script; missing ids are a not-found error.
    pub fn delete(&self, id: &Uuid) -> JidrResult<()> {
        let path = self.path_for(id);
        match std::fs::remove_file(&path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                Err(JidrError::not_found(format!("script {id} not found")))
            }
            Err(error) => Err(JidrError::unexpected(format!(
                "deleting {}: {error}",
                path.display()
            ))),
        }
    }

    /// Renames one script and returns the updated copy.
    pub fn rename(&self, id: &Uuid, name: &str) -> JidrResult<Script> {
        validate_name(name)?;
        let mut script = self.load(id)?;
        script.name = name.to_owned();
        self.save(&script)?;
        Ok(script)
    }

    /// Imports an exported script file under a fresh id and saves it.
    ///
    /// The original name, timestamps and timeline are preserved; only the id
    /// changes so an import can never overwrite an existing script.
    pub fn import(&self, path: impl AsRef<Path>) -> JidrResult<Script> {
        let path = path.as_ref();
        let metadata = match std::fs::metadata(path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Err(JidrError::not_found(format!(
                    "no script file at {}",
                    path.display()
                )));
            }
            Err(error) => {
                return Err(JidrError::unexpected(format!(
                    "reading {}: {error}",
                    path.display()
                )));
            }
        };
        if !metadata.is_file() {
            return Err(JidrError::usage(format!(
                "{} is not a script file",
                path.display()
            )));
        }
        if metadata.len() > MAX_SCRIPT_BYTES {
            return Err(JidrError::usage(format!(
                "the script file is larger than {MAX_SCRIPT_BYTES} bytes"
            )));
        }
        let bytes = std::fs::read(path)
            .ctx(ErrorCode::Unexpected, format!("reading {}", path.display()))?;
        let mut script = decode(&bytes, path)?;
        script.id = Uuid::new_v4();
        self.save(&script)?;
        Ok(script)
    }

    /// Writes one stored script to `path` (an export; the library is unchanged).
    pub fn export(&self, id: &Uuid, path: impl AsRef<Path>) -> JidrResult<()> {
        let path = path.as_ref();
        let script = self.load(id)?;
        if let Some(parent) = path.parent()
            && !parent.as_os_str().is_empty()
            && !parent.is_dir()
        {
            return Err(JidrError::usage(format!(
                "the export destination directory does not exist: {}",
                parent.display()
            )));
        }
        let bytes = encode(&script)?;
        std::fs::write(path, bytes)
            .map_err(|error| JidrError::usage(format!("cannot write {}: {error}", path.display())))
    }

    fn path_for(&self, id: &Uuid) -> PathBuf {
        self.dir.join(format!("{id}.json"))
    }

    fn read_script(&self, path: &Path) -> JidrResult<Script> {
        match std::fs::metadata(path) {
            Ok(metadata) if metadata.len() > MAX_SCRIPT_BYTES => {
                return Err(JidrError::usage(format!(
                    "{} is larger than the {MAX_SCRIPT_BYTES} byte limit",
                    path.display()
                )));
            }
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Err(JidrError::not_found(format!(
                    "no script file at {}",
                    path.display()
                )));
            }
            Err(error) => {
                return Err(JidrError::unexpected(format!(
                    "reading {}: {error}",
                    path.display()
                )));
            }
        }
        let bytes = match std::fs::read(path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Err(JidrError::not_found(format!(
                    "no script file at {}",
                    path.display()
                )));
            }
            Err(error) => {
                return Err(JidrError::unexpected(format!(
                    "reading {}: {error}",
                    path.display()
                )));
            }
        };
        decode(&bytes, path)
    }
}

/// Serialises a script as pretty JSON with a trailing newline.
fn encode(script: &Script) -> JidrResult<Vec<u8>> {
    let mut bytes =
        serde_json::to_vec_pretty(script).ctx(ErrorCode::Unexpected, "encoding the script")?;
    bytes.push(b'\n');
    Ok(bytes)
}

/// Parses and validates a script, reporting `usage` errors with the file name.
fn decode(bytes: &[u8], path: &Path) -> JidrResult<Script> {
    let script: Script = serde_json::from_slice(bytes).map_err(|error| {
        JidrError::usage(format!(
            "{} is not a valid operation recording: {error}",
            path.display()
        ))
    })?;
    validate(&script)
        .map_err(|error| JidrError::usage(format!("{}: {}", path.display(), error.message)))?;
    Ok(script)
}

/// Writes `bytes` to `path` atomically: a temp file in the same directory is
/// renamed into place, so a crash never leaves a half-written script.
fn write_atomic(path: &Path, bytes: &[u8]) -> JidrResult<()> {
    let dir = path.parent().ok_or_else(|| {
        JidrError::unexpected(format!("{} has no parent directory", path.display()))
    })?;
    std::fs::create_dir_all(dir)
        .ctx(ErrorCode::Unexpected, format!("creating {}", dir.display()))?;
    let suffix = TEMP_COUNTER.fetch_add(1, Ordering::Relaxed);
    let temp = dir.join(format!(
        ".jidr-automation-{}-{suffix}.tmp",
        std::process::id()
    ));
    std::fs::write(&temp, bytes)
        .ctx(ErrorCode::Unexpected, format!("writing {}", temp.display()))?;
    if let Err(error) = std::fs::rename(&temp, path) {
        let _ = std::fs::remove_file(&temp);
        return Err(JidrError::unexpected(format!(
            "writing {}: {error}",
            path.display()
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Event, PlaybackMode, PlaybackOptions, VERSION};
    use crate::test_support::fixture;
    use chrono::DateTime;
    use tempfile::TempDir;

    fn script(name: &str, created_at: i64) -> Script {
        let mut script = fixture();
        script.id = Uuid::new_v4();
        script.name = name.to_owned();
        script.created_at = DateTime::from_timestamp_millis(created_at).expect("timestamp");
        script
    }

    fn store() -> (TempDir, ScriptStore) {
        let dir = TempDir::new().expect("temp dir");
        let store = ScriptStore::new(dir.path());
        (dir, store)
    }

    #[test]
    fn save_load_and_summarise_round_trip() {
        let (_dir, store) = store();
        let script = script("first", 1_700_000_000_000);
        store.save(&script).expect("save");
        let loaded = store.load(&script.id).expect("load");
        assert_eq!(loaded, script);
        let summaries = store.list().expect("list");
        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0], script.summary());
        assert_eq!(summaries[0].duration_ms, script.duration_ms());
        assert!(store.dir().join(format!("{}.json", script.id)).is_file());
    }

    #[test]
    fn list_sorts_newest_first_and_skips_corrupt_files() {
        let (_dir, store) = store();
        let older = script("older", 1_700_000_000_000);
        let newer = script("newer", 1_700_000_100_000);
        store.save(&older).expect("save older");
        store.save(&newer).expect("save newer");
        std::fs::write(store.dir().join("broken.json"), b"{not json").expect("write corrupt");
        std::fs::write(store.dir().join("foreign.json"), b"{\"hi\":1}").expect("write foreign");
        std::fs::write(store.dir().join("notes.txt"), b"not a script").expect("write text");
        let summaries = store.list().expect("list");
        assert_eq!(summaries.len(), 2);
        assert_eq!(summaries[0].name, "newer");
        assert_eq!(summaries[1].name, "older");
    }

    #[test]
    fn missing_library_lists_empty_and_load_is_not_found() {
        let (_dir, store) = store();
        assert!(store.list().expect("list").is_empty());
        let error = store.load(&Uuid::new_v4()).expect_err("missing script");
        assert_eq!(error.code, ErrorCode::NotFound);
    }

    #[test]
    fn rename_updates_the_file_and_delete_removes_it() {
        let (_dir, store) = store();
        let script = script("before", 1_700_000_000_000);
        store.save(&script).expect("save");
        let renamed = store.rename(&script.id, "after").expect("rename");
        assert_eq!(renamed.name, "after");
        assert_eq!(store.load(&script.id).expect("load").name, "after");

        store.delete(&script.id).expect("delete");
        let error = store.load(&script.id).expect_err("deleted");
        assert_eq!(error.code, ErrorCode::NotFound);
        let error = store.delete(&script.id).expect_err("deleted twice");
        assert_eq!(error.code, ErrorCode::NotFound);

        let error = store.rename(&script.id, "again").expect_err("missing");
        assert_eq!(error.code, ErrorCode::NotFound);
        let error = store.rename(&Uuid::new_v4(), "  ").expect_err("empty name");
        assert_eq!(error.code, ErrorCode::Usage);
    }

    #[test]
    fn save_validates_before_touching_the_library() {
        let (_dir, store) = store();
        let mut invalid = script("invalid", 1_700_000_000_000);
        invalid.version = VERSION + 1;
        let error = store.save(&invalid).expect_err("invalid script");
        assert_eq!(error.code, ErrorCode::Usage);
        assert!(store.list().expect("list").is_empty());
    }

    #[test]
    fn import_copies_under_a_new_id_and_export_reproduces_it() {
        let (_source_dir, source_store) = store();
        let original = script("imported", 1_700_000_000_000);
        source_store.save(&original).expect("save source");
        let export_path = source_store.dir().join("exported.json");
        source_store
            .export(&original.id, &export_path)
            .expect("export");

        let (_dir, store) = store();
        let imported = store.import(&export_path).expect("import");
        assert_ne!(imported.id, original.id);
        assert_eq!(imported.name, original.name);
        assert_eq!(imported.created_at, original.created_at);
        assert_eq!(imported.events, original.events);
        assert_eq!(store.load(&imported.id).expect("load imported"), imported);
        assert_eq!(store.list().expect("list").len(), 1);

        // Exporting the imported copy and importing it again yields another id.
        let second_path = store.dir().join("second.json");
        store
            .export(&imported.id, &second_path)
            .expect("export imported");
        let reimported = store.import(&second_path).expect("re-import");
        assert_ne!(reimported.id, imported.id);
        assert_eq!(reimported.events, imported.events);
    }

    #[test]
    fn import_and_export_errors_use_usage_and_not_found() {
        let (_dir, store) = store();
        let missing = store
            .import(store.dir().join("nope.json"))
            .expect_err("missing import");
        assert_eq!(missing.code, ErrorCode::NotFound);

        let broken = TempDir::new().expect("temp dir");
        let broken_path = broken.path().join("broken.json");
        std::fs::write(&broken_path, b"{not json").expect("write");
        let error = store.import(&broken_path).expect_err("bad import");
        assert_eq!(error.code, ErrorCode::Usage);

        let invalid = TempDir::new().expect("temp dir");
        let invalid_path = invalid.path().join("invalid.json");
        let mut bad = script("bad", 1_700_000_000_000);
        bad.events.clear();
        std::fs::write(&invalid_path, serde_json::to_vec(&bad).expect("encode")).expect("write");
        let error = store.import(&invalid_path).expect_err("invalid import");
        assert_eq!(error.code, ErrorCode::Usage);

        let oversized_dir = TempDir::new().expect("temp dir");
        let oversized_path = oversized_dir.path().join("oversized.json");
        let file = std::fs::File::create(&oversized_path).expect("create sparse file");
        file.set_len(MAX_SCRIPT_BYTES + 1)
            .expect("size sparse file");
        drop(file);
        let error = store.import(&oversized_path).expect_err("oversized import");
        assert_eq!(error.code, ErrorCode::Usage);
        assert!(error.message.contains("larger"), "{}", error.message);

        let error = store
            .export(&Uuid::new_v4(), invalid.path().join("out.json"))
            .expect_err("missing export id");
        assert_eq!(error.code, ErrorCode::NotFound);
    }

    #[test]
    fn infinite_playback_round_trips_through_the_store() {
        let (_dir, store) = store();
        let mut script = script("playback", 1_700_000_000_000);
        script.playback = PlaybackOptions {
            mode: PlaybackMode::Infinite,
            count: 0,
            duration_ms: 0,
            interval_ms: 250,
            speed: 2.0,
        };
        script.events = vec![crate::model::TimedEvent {
            t: 0,
            event: Event::ToolKey {
                key: "back".to_owned(),
            },
        }];
        store.save(&script).expect("save");
        let loaded = store.load(&script.id).expect("load");
        assert_eq!(loaded.playback.mode, PlaybackMode::Infinite);
        assert!((loaded.playback.speed - 2.0).abs() < f64::EPSILON);
        assert_eq!(loaded.playback.interval_ms, 250);
    }
}
