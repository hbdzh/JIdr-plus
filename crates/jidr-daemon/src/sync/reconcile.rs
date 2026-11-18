//! Three-way comparison and tree scanning for bidirectional folder synchronization.
//!
//! A baseline records content agreed by both sides (SHA-256), not merely a
//! timestamp. Callers must only advance it after verifying a successful
//! transfer.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::Read;
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use jidr_core::{JidrError, JidrResult};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};

use super::plan::Ignore;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Version<T> {
    pub content: T,
    /// Modification time in a common time scale, with device precision.
    pub modified: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    None,
    Push,
    Pull,
    DeleteLocal,
    DeleteRemote,
    Conflict,
}

/// Stat metadata for change detection before hashing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FileStat {
    pub size: u64,
    /// Modification time in Unix epoch seconds.
    pub modified: i64,
}

/// A scanned regular file with content fingerprint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileEntry {
    pub size: u64,
    pub modified: i64,
    pub sha256: String,
}

impl FileEntry {
    pub fn stat(&self) -> FileStat {
        FileStat {
            size: self.size,
            modified: self.modified,
        }
    }

    pub fn version(&self) -> Version<&str> {
        Version {
            content: &self.sha256,
            modified: self.modified,
        }
    }
}

/// An unresolved conflict reported in `SyncInfo` and `file.sync.conflict`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct SyncConflict {
    pub path: PathBuf,
    pub local_exists: bool,
    pub remote_exists: bool,
    #[serde(default)]
    pub local_modified: Option<i64>,
    #[serde(default)]
    pub remote_modified: Option<i64>,
}

/// Full tree reconciliation output for one bidirectional sync cycle.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ReconcilePlan {
    pub pushes: Vec<PathBuf>,
    pub pulls: Vec<PathBuf>,
    pub delete_remote: Vec<PathBuf>,
    pub delete_local: Vec<PathBuf>,
    pub conflicts: Vec<SyncConflict>,
    pub agreed: Vec<(PathBuf, String)>,
    pub both_gone: Vec<PathBuf>,
}

impl ReconcilePlan {
    pub fn has_transfers(&self) -> bool {
        !self.pushes.is_empty()
            || !self.pulls.is_empty()
            || !self.delete_remote.is_empty()
            || !self.delete_local.is_empty()
    }
}

pub fn decide<T: Eq>(
    base: Option<&T>,
    local: Option<&Version<T>>,
    remote: Option<&Version<T>>,
) -> Action {
    let local_content = local.map(|v| &v.content);
    let remote_content = remote.map(|v| &v.content);
    if local_content == remote_content {
        return Action::None;
    }
    if let Some(base) = base {
        if local_content == Some(base) {
            return if remote.is_some() {
                Action::Pull
            } else {
                Action::DeleteLocal
            };
        }
        if remote_content == Some(base) {
            return if local.is_some() {
                Action::Push
            } else {
                Action::DeleteRemote
            };
        }
        // A deletion has no modification time to compare. Preserve the
        // changed survivor for the user to resolve rather than deleting it.
        if local.is_none() || remote.is_none() {
            return Action::Conflict;
        }
    }
    match (local, remote) {
        (Some(_), None) => Action::Push,
        (None, Some(_)) => Action::Pull,
        (Some(l), Some(r)) => match l.modified.cmp(&r.modified) {
            std::cmp::Ordering::Greater => Action::Push,
            std::cmp::Ordering::Less => Action::Pull,
            std::cmp::Ordering::Equal => Action::Conflict,
        },
        (None, None) => Action::None,
    }
}

/// Reconciles `base`, `local`, and `remote` file maps into transfer/delete
/// actions and conflicts, guarding against file-vs-directory collisions.
pub fn reconcile_trees(
    base: &BTreeMap<PathBuf, String>,
    local: &BTreeMap<PathBuf, FileEntry>,
    remote: &BTreeMap<PathBuf, FileEntry>,
) -> ReconcilePlan {
    let mut all_paths = BTreeSet::new();
    all_paths.extend(base.keys().cloned());
    all_paths.extend(local.keys().cloned());
    all_paths.extend(remote.keys().cloned());

    let mut plan = ReconcilePlan::default();
    for path in all_paths {
        let b = base.get(&path).map(String::as_str);
        let l = local.get(&path).map(FileEntry::version);
        let r = remote.get(&path).map(FileEntry::version);
        match decide(b.as_ref(), l.as_ref(), r.as_ref()) {
            Action::None => {
                if let Some(entry) = local.get(&path) {
                    plan.agreed.push((path, entry.sha256.clone()));
                } else {
                    plan.both_gone.push(path);
                }
            }
            Action::Push => plan.pushes.push(path),
            Action::Pull => plan.pulls.push(path),
            Action::DeleteRemote => plan.delete_remote.push(path),
            Action::DeleteLocal => plan.delete_local.push(path),
            Action::Conflict => plan.conflicts.push(make_conflict(path, local, remote)),
        }
    }

    protect_type_collisions(&mut plan, local, remote);
    plan
}

fn make_conflict(
    path: PathBuf,
    local: &BTreeMap<PathBuf, FileEntry>,
    remote: &BTreeMap<PathBuf, FileEntry>,
) -> SyncConflict {
    SyncConflict {
        local_exists: local.contains_key(&path),
        remote_exists: remote.contains_key(&path),
        local_modified: local.get(&path).map(|e| e.modified),
        remote_modified: remote.get(&path).map(|e| e.modified),
        path,
    }
}

/// Prevents pushing or pulling a file whose path collides with a surviving
/// descendant file (which implies a directory) on the opposite side.
fn protect_type_collisions(
    plan: &mut ReconcilePlan,
    local: &BTreeMap<PathBuf, FileEntry>,
    remote: &BTreeMap<PathBuf, FileEntry>,
) {
    let deleted_remote: BTreeSet<&Path> = plan.delete_remote.iter().map(PathBuf::as_path).collect();
    let deleted_local: BTreeSet<&Path> = plan.delete_local.iter().map(PathBuf::as_path).collect();

    let surviving_remote: Vec<&Path> = remote
        .keys()
        .map(PathBuf::as_path)
        .filter(|p| !deleted_remote.contains(p))
        .collect();
    let surviving_local: Vec<&Path> = local
        .keys()
        .map(PathBuf::as_path)
        .filter(|p| !deleted_local.contains(p))
        .collect();

    let mut collided = BTreeSet::new();
    for p in &plan.pushes {
        if surviving_remote.iter().any(|r| {
            (*r != p.as_path() && r.starts_with(p)) || has_strict_ancestor(p, &surviving_remote)
        }) {
            collided.insert(p.clone());
        }
    }
    for p in &plan.pulls {
        if surviving_local.iter().any(|l| {
            (*l != p.as_path() && l.starts_with(p)) || has_strict_ancestor(p, &surviving_local)
        }) {
            collided.insert(p.clone());
        }
    }
    if collided.is_empty() {
        return;
    }

    plan.pushes.retain(|p| !collided.contains(p));
    plan.pulls.retain(|p| !collided.contains(p));
    for path in collided {
        if !plan.conflicts.iter().any(|c| c.path == path) {
            plan.conflicts.push(make_conflict(path, local, remote));
        }
    }
    plan.conflicts.sort_by(|a, b| a.path.cmp(&b.path));
}

fn has_strict_ancestor(path: &Path, candidates: &[&Path]) -> bool {
    let mut cur = path.parent();
    while let Some(parent) = cur {
        if !parent.as_os_str().is_empty() && candidates.contains(&parent) {
            return true;
        }
        cur = parent.parent();
    }
    false
}

/// Converts a `std::fs::Metadata` modification timestamp to Unix epoch seconds.
pub fn metadata_mtime_secs(meta: &std::fs::Metadata) -> i64 {
    let Ok(mtime) = meta.modified() else {
        return 0;
    };
    system_time_to_secs(mtime)
}

fn system_time_to_secs(t: SystemTime) -> i64 {
    match t.duration_since(UNIX_EPOCH) {
        Ok(d) => i64::try_from(d.as_secs()).unwrap_or(i64::MAX),
        Err(e) => {
            let secs = i64::try_from(e.duration().as_secs()).unwrap_or(i64::MAX);
            secs.saturating_neg()
        }
    }
}

/// Reads `(size, modified_secs)` for an existing local regular file without
/// following symlinks.
pub fn local_file_stat(path: &Path) -> std::io::Result<Option<FileStat>> {
    match std::fs::symlink_metadata(path) {
        Ok(meta) if meta.is_file() => Ok(Some(FileStat {
            size: meta.len(),
            modified: metadata_mtime_secs(&meta),
        })),
        Ok(_) => Ok(None),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

/// Streams a local file and returns its lowercase hex SHA-256 digest.
pub fn hash_file(path: &Path) -> std::io::Result<String> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 64 * 1024];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hex::encode(hasher.finalize()))
}

/// Scans `root` for regular files, reusing `cache` hashes when `(size, modified)`
/// matches. Any metadata/read error fails closed so unreadable files are never
/// misinterpreted as deletions.
pub fn scan_local_with_cache(
    root: &Path,
    ignore: &Ignore,
    max_files: u64,
    cache: &mut HashMap<PathBuf, FileEntry>,
) -> JidrResult<BTreeMap<PathBuf, FileEntry>> {
    let mut files = BTreeMap::new();
    scan_local_dir(
        root,
        root,
        Path::new(""),
        ignore,
        max_files,
        cache,
        &mut files,
    )?;
    cache.retain(|k, _| files.contains_key(k));
    Ok(files)
}

fn scan_local_dir(
    root: &Path,
    abs: &Path,
    rel: &Path,
    ignore: &Ignore,
    max_files: u64,
    cache: &mut HashMap<PathBuf, FileEntry>,
    out: &mut BTreeMap<PathBuf, FileEntry>,
) -> JidrResult<()> {
    let rd = std::fs::read_dir(abs)
        .map_err(|e| JidrError::usage(format!("can't read {}: {e}", abs.display())))?;
    let mut entries: Vec<_> = rd
        .collect::<Result<_, _>>()
        .map_err(|e| JidrError::sdk(format!("reading {}: {e}", abs.display())))?;
    entries.sort_by_key(|e| e.file_name());

    for entry in entries {
        let name = entry.file_name();
        if ignore.skips_name(&name) {
            continue;
        }
        let path = entry.path();
        let meta = std::fs::symlink_metadata(&path)
            .map_err(|e| JidrError::sdk(format!("reading {}: {e}", path.display())))?;
        let child_rel = rel.join(&name);
        if meta.is_dir() {
            scan_local_dir(root, &path, &child_rel, ignore, max_files, cache, out)?;
        } else if meta.is_file() {
            if out.len() as u64 >= max_files {
                return Err(JidrError::usage(format!(
                    "{} has more than {} files (not counting {}); pick a smaller folder, skip more names, or raise max_files",
                    root.display(),
                    max_files,
                    ignore.names().join(", ")
                ))
                .with_data(json!({ "max_files": max_files })));
            }
            let size = meta.len();
            let modified = metadata_mtime_secs(&meta);
            let sha256 = match cache.get(&child_rel) {
                Some(c) if c.size == size && c.modified == modified => c.sha256.clone(),
                _ => hash_file(&path)
                    .map_err(|e| JidrError::sdk(format!("reading {}: {e}", path.display())))?,
            };
            let entry = FileEntry {
                size,
                modified,
                sha256,
            };
            cache.insert(child_rel.clone(), entry.clone());
            out.insert(child_rel, entry);
        }
    }
    Ok(())
}

/// Builds a single `adb shell` command that lists all regular files under
/// `remote` (pruning ignored names) as `<size> <mtime_sec> <full_path>`.
/// Missing `remote` succeeds with empty output; a non-directory fails.
pub fn build_remote_scan_script(remote: &str, ignore: &Ignore) -> String {
    let q_remote = jidr_adb::shell_quote(remote);
    let names = ignore.names();
    let prune = if names.is_empty() {
        String::new()
    } else {
        let clauses: Vec<String> = names
            .iter()
            .map(|n| format!("-name {}", jidr_adb::shell_quote(n)))
            .collect();
        format!(r"\( {} \) -prune -o ", clauses.join(" -o "))
    };
    format!(
        "if [ ! -e {q_remote} ]; then exit 0; fi; if [ ! -d {q_remote} ]; then echo 'remote path is not a directory' >&2; exit 2; fi; find {q_remote} -mindepth 1 {prune}-type f -exec stat -c '%s %Y %n' {{}} +"
    )
}

/// Parses the output of [`build_remote_scan_script`], validating relative paths
/// and enforcing `ignore` and `max_files`.
pub fn parse_remote_scan_output(
    remote: &str,
    stdout: &str,
    ignore: &Ignore,
    max_files: u64,
) -> JidrResult<BTreeMap<PathBuf, FileStat>> {
    let prefix = format!("{}/", remote.trim_end_matches('/'));
    let mut files = BTreeMap::new();
    for raw in stdout.lines() {
        let line = raw.trim_end_matches('\r');
        if line.is_empty() {
            continue;
        }
        let mut parts = line.splitn(3, ' ');
        let Some(size_s) = parts.next() else {
            return Err(JidrError::sdk(format!(
                "unexpected remote stat line: {line}"
            )));
        };
        let Some(mtime_s) = parts.next() else {
            return Err(JidrError::sdk(format!(
                "unexpected remote stat line: {line}"
            )));
        };
        let Some(full_path) = parts.next() else {
            return Err(JidrError::sdk(format!(
                "unexpected remote stat line: {line}"
            )));
        };
        let size: u64 = size_s
            .parse()
            .map_err(|_| JidrError::sdk(format!("invalid remote file size in: {line}")))?;
        let modified: i64 = mtime_s
            .parse()
            .map_err(|_| JidrError::sdk(format!("invalid remote mtime in: {line}")))?;
        let rel = validate_remote_rel(&prefix, full_path)?;
        if ignore.skips(&rel) {
            continue;
        }
        if files.len() as u64 >= max_files {
            return Err(JidrError::usage(format!(
                "{remote} on the device has more than {max_files} files (not counting {}); pick a smaller folder, skip more names, or raise max_files",
                ignore.names().join(", ")
            ))
            .with_data(json!({ "max_files": max_files })));
        }
        files.insert(rel, FileStat { size, modified });
    }
    Ok(files)
}

/// Parses `sha256sum` output (`<64-hex>  <full_path>`) into relative paths.
pub fn parse_sha256sum_output(remote: &str, stdout: &str) -> JidrResult<HashMap<PathBuf, String>> {
    let prefix = format!("{}/", remote.trim_end_matches('/'));
    let mut hashes = HashMap::new();
    for raw in stdout.lines() {
        let line = raw.trim_end_matches('\r');
        if line.is_empty() {
            continue;
        }
        if line.len() < 67 {
            return Err(JidrError::sdk(format!(
                "unexpected remote sha256sum line: {line}"
            )));
        }
        let (digest, rest) = line.split_at(64);
        if !digest.bytes().all(|b| b.is_ascii_hexdigit())
            || !(rest.starts_with("  ") || rest.starts_with(" *"))
        {
            return Err(JidrError::sdk(format!(
                "unexpected remote sha256sum line: {line}"
            )));
        }
        let rel = validate_remote_rel(&prefix, &rest[2..])?;
        hashes.insert(rel, digest.to_ascii_lowercase());
    }
    Ok(hashes)
}

fn validate_remote_rel(prefix: &str, full_path: &str) -> JidrResult<PathBuf> {
    let Some(rel_str) = full_path.strip_prefix(prefix) else {
        return Err(JidrError::sdk(format!(
            "remote path {full_path:?} is outside {prefix:?}"
        )));
    };
    let rel = PathBuf::from(rel_str);
    if rel.as_os_str().is_empty() || rel.components().any(|c| !matches!(c, Component::Normal(_))) {
        return Err(JidrError::sdk(format!(
            "unsafe remote relative path: {rel_str:?}"
        )));
    }
    Ok(rel)
}

/// Chooses a non-colliding relative conflict copy path under `root` for `rel`.
pub fn conflict_copy_rel(root: &Path, rel: &Path, timestamp: i64) -> PathBuf {
    let parent = rel.parent().unwrap_or(Path::new(""));
    let stem = rel
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "file".to_string());
    let ext = rel
        .extension()
        .map(|e| format!(".{}", e.to_string_lossy()))
        .unwrap_or_default();
    let first = parent.join(format!("{stem}.sync-conflict-{timestamp}{ext}"));
    if !root.join(&first).exists() {
        return first;
    }
    for n in 1u32.. {
        let candidate = parent.join(format!("{stem}.sync-conflict-{timestamp}-{n}{ext}"));
        if !root.join(&candidate).exists() {
            return candidate;
        }
    }
    first
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> PathBuf {
        PathBuf::from(s)
    }

    fn v(content: u8, modified: i64) -> Version<u8> {
        Version { content, modified }
    }

    fn entry(hash: &str, modified: i64) -> FileEntry {
        FileEntry {
            size: 10,
            modified,
            sha256: hash.into(),
        }
    }

    #[test]
    fn first_scan_merges_and_selects_newer_content() {
        assert_eq!(decide(None, Some(&v(1, 1)), None), Action::Push);
        assert_eq!(decide(None, None, Some(&v(2, 2))), Action::Pull);
        assert_eq!(decide(None, Some(&v(1, 1)), Some(&v(2, 2))), Action::Pull);
        assert_eq!(decide(None, Some(&v(1, 2)), Some(&v(2, 1))), Action::Push);
        assert_eq!(
            decide(None, Some(&v(1, 1)), Some(&v(2, 1))),
            Action::Conflict
        );
        assert_eq!(decide(None, Some(&v(1, 1)), Some(&v(1, 2))), Action::None);
    }

    #[test]
    fn tracks_changes_and_deletes_and_protects_a_changed_survivor() {
        assert_eq!(
            decide(Some(&1), Some(&v(2, 1)), Some(&v(1, 2))),
            Action::Push
        );
        assert_eq!(
            decide(Some(&1), Some(&v(1, 2)), Some(&v(2, 1))),
            Action::Pull
        );
        assert_eq!(decide(Some(&1), None, Some(&v(1, 1))), Action::DeleteRemote);
        assert_eq!(decide(Some(&1), Some(&v(1, 1)), None), Action::DeleteLocal);
        assert_eq!(decide(Some(&1), None, Some(&v(2, 2))), Action::Conflict);
        assert_eq!(decide(Some(&1), Some(&v(2, 2)), None), Action::Conflict);
        assert_eq!(
            decide(Some(&1), Some(&v(2, 3)), Some(&v(3, 2))),
            Action::Push
        );
    }

    #[test]
    fn reconcile_trees_protects_file_vs_directory_collisions() {
        let base = BTreeMap::new();
        let local = BTreeMap::from([(p("docs"), entry("h1", 10)), (p("ok.txt"), entry("h2", 10))]);
        let remote = BTreeMap::from([(p("docs/readme.md"), entry("h3", 10))]);

        let plan = reconcile_trees(&base, &local, &remote);
        assert_eq!(plan.pushes, vec![p("ok.txt")]);
        assert!(plan.pulls.is_empty());
        assert_eq!(
            plan.conflicts
                .iter()
                .map(|c| c.path.clone())
                .collect::<Vec<_>>(),
            vec![p("docs"), p("docs/readme.md")]
        );
    }

    #[test]
    fn remote_scan_script_and_parsers_handle_spaces_and_ignores() {
        let ignore = Ignore::new(true, &[]);
        let script = build_remote_scan_script("/sdcard/Download/My Site", &ignore);
        assert!(script.contains("'/sdcard/Download/My Site'"));
        assert!(script.contains("-name '.git'"));
        assert!(script.contains("-prune -o -type f"));

        let stdout = "\
12 1700000001 /sdcard/Download/My Site/hello world.txt\n\
5 1700000002 /sdcard/Download/My Site/.git/HEAD\n\
9 1700000003 /sdcard/Download/My Site/sub/a.txt\n";
        let parsed =
            parse_remote_scan_output("/sdcard/Download/My Site", stdout, &ignore, 10).unwrap();
        assert_eq!(
            parsed,
            BTreeMap::from([
                (
                    p("hello world.txt"),
                    FileStat {
                        size: 12,
                        modified: 1_700_000_001
                    }
                ),
                (
                    p("sub/a.txt"),
                    FileStat {
                        size: 9,
                        modified: 1_700_000_003
                    }
                ),
            ])
        );

        let hashes = parse_sha256sum_output(
            "/sdcard/Download/My Site",
            &format!(
                "{}  /sdcard/Download/My Site/hello world.txt\n",
                "A".repeat(64)
            ),
        )
        .unwrap();
        assert_eq!(hashes[&p("hello world.txt")], "a".repeat(64));
    }

    #[test]
    fn parse_remote_scan_rejects_traversal_and_max_files() {
        let ignore = Ignore::new(true, &[]);
        let err = parse_remote_scan_output(
            "/sdcard/site",
            "1 1 /sdcard/site/../etc/passwd\n",
            &ignore,
            10,
        )
        .unwrap_err();
        assert_eq!(err.code, jidr_core::ErrorCode::Sdk);

        let err = parse_remote_scan_output(
            "/sdcard/site",
            "1 1 /sdcard/site/a\n1 1 /sdcard/site/b\n",
            &ignore,
            1,
        )
        .unwrap_err();
        assert_eq!(err.code, jidr_core::ErrorCode::Usage);
    }

    #[test]
    fn local_scan_uses_cache_and_detects_changes() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join("a.txt"), b"hello").unwrap();
        std::fs::create_dir_all(dir.path().join(".git")).unwrap();
        std::fs::write(dir.path().join(".git/HEAD"), b"ref").unwrap();

        let ignore = Ignore::new(true, &[]);
        let mut cache = HashMap::new();
        let first = scan_local_with_cache(dir.path(), &ignore, 10, &mut cache).unwrap();
        assert_eq!(first.len(), 1);
        assert_eq!(first[&p("a.txt")].sha256.len(), 64);

        // Removing the file clears it from the scan and cache.
        std::fs::remove_file(dir.path().join("a.txt")).unwrap();
        let second = scan_local_with_cache(dir.path(), &ignore, 10, &mut cache).unwrap();
        assert!(second.is_empty());
        assert!(cache.is_empty());
    }
}
