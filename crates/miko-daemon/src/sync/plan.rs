//! The pure part of `file.sync` (#27): which host paths a sync skips, the
//! adb batches of a mirror with its file-count guard, the debouncer that
//! coalesces watcher events, and the plan that turns changed paths into
//! device operations. No adb and no watcher here, so it's unit-tested on
//! temp folders.
//!
//! Paths are relative to the synced host folder; the empty path is the
//! folder itself.

use std::collections::BTreeSet;
use std::ffi::OsStr;
use std::path::{Component, Path, PathBuf};
use std::time::{Duration, Instant};

use miko_core::{MikoError, MikoResult};
use serde_json::json;

/// Skipped at any depth unless a sync opts out: version control and
/// dependency folders are big, rarely wanted on a device, and the cause of
/// most accidental huge syncs. `.DS_Store` is Finder's clutter.
pub const DEFAULT_IGNORE: [&str; 3] = [".git", "node_modules", ".DS_Store"];

/// A folder with more files than this (after skips) is refused unless the
/// caller raises `max_files`.
pub const DEFAULT_MAX_FILES: u64 = 10_000;

/// How long the folder must be quiet before a batch of changes goes out.
pub const QUIET: Duration = Duration::from_millis(300);

/// The longest a change waits while the folder keeps changing (a build
/// writing for minutes still reaches the device every 2 s).
pub const MAX_WAIT: Duration = Duration::from_secs(2);

/// Source paths per `adb push`, so a command line stays well under the
/// host's argument limit.
pub const PUSH_CHUNK: usize = 200;

/// Bytes per device shell script; old adb shell protocols cap a command at
/// 4 KiB.
pub const SCRIPT_LIMIT: usize = 4000;

/// File and folder names a sync skips.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Ignore {
    names: BTreeSet<String>,
}

impl Ignore {
    /// `defaults` adds [`DEFAULT_IGNORE`]; `extra` are more exact names.
    pub fn new(defaults: bool, extra: &[String]) -> Self {
        let mut names: BTreeSet<String> = extra
            .iter()
            .map(|n| n.trim().to_string())
            .filter(|n| !n.is_empty())
            .collect();
        if defaults {
            names.extend(DEFAULT_IGNORE.iter().map(|n| n.to_string()));
        }
        Self { names }
    }

    pub fn names(&self) -> Vec<String> {
        self.names.iter().cloned().collect()
    }

    pub fn skips_name(&self, name: &OsStr) -> bool {
        name.to_str().is_some_and(|n| self.names.contains(n))
    }

    /// True when any part of `rel` is a skipped name.
    pub fn skips(&self, rel: &Path) -> bool {
        rel.components()
            .any(|c| matches!(c, Component::Normal(n) if self.skips_name(n)))
    }
}

/// One `adb push` (in [`PUSH_CHUNK`]s): `sources` (absolute host paths,
/// files or whole folders) into the device folder `dir`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Batch {
    /// Relative to the synced folder.
    pub dir: PathBuf,
    pub sources: Vec<PathBuf>,
    /// Files the sources hold, for progress.
    pub files: u64,
    /// `adb push --sync`: skip files the device already has at least as new.
    pub newer_only: bool,
}

/// How to copy a host folder to the device: create `mkdirs`, then run the
/// batches. A folder without anything skipped inside goes as one source of
/// its parent's batch, so a clean tree costs one `adb push`; only folders
/// holding something skipped are walked into.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Mirror {
    pub files: u64,
    pub bytes: u64,
    /// Regular files included in this scan, relative to the root.
    pub paths: BTreeSet<PathBuf>,
    pub mkdirs: Vec<PathBuf>,
    pub batches: Vec<Batch>,
}

/// Plans copying `sub` (relative to `root`, empty for all of it). Fails
/// with `usage` past `max_files` files, without walking further.
pub fn scan(root: &Path, sub: &Path, ignore: &Ignore, max_files: u64) -> MikoResult<Mirror> {
    let abs = root.join(sub);
    let mut walk = Walk {
        root,
        ignore,
        max_files,
        files: 0,
        bytes: 0,
        paths: BTreeSet::new(),
    };
    let dir = walk.dir(&abs, sub, true)?;
    Ok(Mirror {
        files: walk.files,
        bytes: walk.bytes,
        paths: walk.paths,
        mkdirs: dir.mkdirs,
        batches: dir.batches,
    })
}

struct Walk<'a> {
    root: &'a Path,
    ignore: &'a Ignore,
    max_files: u64,
    files: u64,
    bytes: u64,
    paths: BTreeSet<PathBuf>,
}

/// A walked folder: `clean` when nothing inside was skipped.
struct Walked {
    clean: bool,
    files: u64,
    mkdirs: Vec<PathBuf>,
    batches: Vec<Batch>,
}

impl Walk<'_> {
    fn count(&mut self, len: u64) -> MikoResult<()> {
        self.files += 1;
        self.bytes += len;
        if self.files > self.max_files {
            return Err(MikoError::usage(format!(
                "{} has more than {} files (not counting {}); pick a smaller folder, skip more names, or raise max_files",
                self.root.display(),
                self.max_files,
                self.ignore.names().join(", ")
            ))
            .with_data(json!({ "max_files": self.max_files })));
        }
        Ok(())
    }

    fn dir(&mut self, abs: &Path, rel: &Path, _top: bool) -> MikoResult<Walked> {
        let entries = match std::fs::read_dir(abs) {
            Ok(rd) => rd,
            Err(e) => {
                return Err(MikoError::usage(format!(
                    "can't read {}: {e}",
                    abs.display()
                )));
            }
        };
        let mut entries: Vec<_> = entries
            .collect::<Result<_, _>>()
            .map_err(|e| MikoError::sdk(format!("reading {}: {e}", abs.display())))?;
        entries.sort_by_key(|e| e.file_name());
        let mut clean = true;
        let mut files = 0;
        let mut sources = Vec::new();
        let mut in_sources = 0;
        let mut mkdirs = vec![rel.to_path_buf()];
        let mut nested = Vec::new();
        for e in entries {
            let name = e.file_name();
            if self.ignore.skips_name(&name) {
                clean = false;
                continue;
            }
            let path = e.path();
            // Not followed: a link could leave the folder or loop.
            let meta = std::fs::symlink_metadata(&path)
                .map_err(|e| MikoError::sdk(format!("reading {}: {e}", path.display())))?;
            if meta.is_dir() {
                let d = self.dir(&path, &rel.join(&name), false)?;
                files += d.files;
                if d.clean {
                    sources.push(path);
                    in_sources += d.files;
                } else {
                    clean = false;
                    mkdirs.extend(d.mkdirs);
                    nested.extend(d.batches);
                }
            } else if meta.is_file() {
                self.count(meta.len())?;
                self.paths.insert(rel.join(&name));
                files += 1;
                sources.push(path);
                in_sources += 1;
            } else {
                clean = false;
            }
        }
        let mut batches = Vec::new();
        if !sources.is_empty() {
            batches.push(Batch {
                dir: rel.to_path_buf(),
                sources,
                files: in_sources,
                newer_only: false,
            });
        }
        batches.extend(nested);
        Ok(Walked {
            clean,
            files,
            mkdirs,
            batches,
        })
    }
}

/// Coalesces watcher events: a batch is due once the folder has been quiet
/// for [`QUIET`], or [`MAX_WAIT`] after its first change.
#[derive(Debug, Default)]
pub struct Debouncer {
    paths: BTreeSet<PathBuf>,
    first: Option<Instant>,
    last: Option<Instant>,
}

impl Debouncer {
    pub fn add(&mut self, rel: PathBuf, now: Instant) {
        self.paths.insert(rel);
        self.first.get_or_insert(now);
        self.last = Some(now);
    }

    pub fn is_empty(&self) -> bool {
        self.paths.is_empty()
    }

    /// When the pending batch is due; `None` when nothing is pending.
    pub fn deadline(&self) -> Option<Instant> {
        Some((self.last? + QUIET).min(self.first? + MAX_WAIT))
    }

    /// The pending paths, if they are due at `now`.
    pub fn take(&mut self, now: Instant) -> Option<BTreeSet<PathBuf>> {
        if self.deadline()? > now {
            return None;
        }
        self.first = None;
        self.last = None;
        Some(std::mem::take(&mut self.paths))
    }
}

/// What a changed path is on the host now.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Now {
    Gone,
    File,
    Dir,
    /// A symlink, socket or pipe: not synced.
    Other,
    /// Metadata could not be read; this is not evidence of deletion.
    Unavailable,
}

/// What [`plan`] asks the device to do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Op {
    Remove(PathBuf),
    PushFile(PathBuf),
    PushDir(PathBuf),
}

/// Turns changed paths into device operations by what each one is now (the
/// event kinds aren't trusted: FSEvents merges them, and a rename arrives as
/// its two paths). Gone → `Remove`, a file → `PushFile`, a folder →
/// `PushDir`. Paths inside a folder that is removed or pushed whole are
/// dropped, as are skipped names. The folder itself is never removed: a
/// sync whose folder is gone stops instead.
pub fn plan(changed: &BTreeSet<PathBuf>, ignore: &Ignore, now: impl Fn(&Path) -> Now) -> Vec<Op> {
    let mut ops = Vec::new();
    // Ancestors sort before their descendants (Path orders by component).
    let mut whole: Vec<&Path> = Vec::new();
    for rel in changed {
        if ignore.skips(rel) || whole.iter().any(|w| rel.starts_with(w)) {
            continue;
        }
        match now(rel) {
            Now::Gone if rel.as_os_str().is_empty() => {}
            Now::Gone => {
                whole.push(rel);
                ops.push(Op::Remove(rel.clone()));
            }
            Now::Dir => {
                whole.push(rel);
                ops.push(Op::PushDir(rel.clone()));
            }
            Now::File => ops.push(Op::PushFile(rel.clone())),
            Now::Other => {}
            Now::Unavailable => {}
        }
    }
    ops
}

/// What `rel` under `root` is now, without following a symlink.
pub fn probe(root: &Path, rel: &Path) -> Now {
    classify_metadata(std::fs::symlink_metadata(root.join(rel)))
}

fn classify_metadata(result: std::io::Result<std::fs::Metadata>) -> Now {
    match result {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Now::Gone,
        Err(_) => Now::Unavailable,
        Ok(m) if m.is_dir() => Now::Dir,
        Ok(m) if m.is_file() => Now::File,
        Ok(_) => Now::Other,
    }
}

/// `base` on the device joined with `rel` (always `/`-separated).
pub fn remote_path(base: &str, rel: &Path) -> String {
    let mut out = base.trim_end_matches('/').to_string();
    for c in rel.components() {
        if let Component::Normal(n) = c {
            out.push('/');
            out.push_str(&n.to_string_lossy());
        }
    }
    if out.is_empty() { "/".into() } else { out }
}

/// `cmd 'a' 'b' …` as few commands as fit in `limit` bytes each.
pub fn pack(cmd: &str, args: &[String], limit: usize) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    for a in args {
        let q = miko_adb::shell_quote(a);
        if !cur.is_empty() && cur.len() + 1 + q.len() > limit {
            out.push(std::mem::take(&mut cur));
        }
        if cur.is_empty() {
            cur.push_str(cmd);
        }
        cur.push(' ');
        cur.push_str(&q);
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// Joins commands into `set -e` scripts of at most `limit` bytes (a longer
/// single command gets a script of its own).
pub fn scripts(commands: &[String], limit: usize) -> Vec<String> {
    const HEAD: &str = "set -e";
    let mut out = Vec::new();
    let mut cur = String::new();
    for c in commands {
        if !cur.is_empty() && cur.len() + 2 + c.len() > limit {
            out.push(std::mem::take(&mut cur));
        }
        if cur.is_empty() {
            cur.push_str(HEAD);
        }
        cur.push_str("; ");
        cur.push_str(c);
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// The device commands that prepare `ops`: removals, a file where a folder
/// was (and the reverse), and the folders pushes land in. `mkdirs` are the
/// folders of the `PushDir` scans.
pub fn prepare(remote: &str, ops: &[Op], mkdirs: &[PathBuf]) -> Vec<String> {
    let mut commands = Vec::new();
    let removes: Vec<String> = ops
        .iter()
        .filter_map(|o| match o {
            Op::Remove(r) => Some(remote_path(remote, r)),
            _ => None,
        })
        .collect();
    commands.extend(pack("rm -f", &removes, SCRIPT_LIMIT / 2));
    let mut dirs = BTreeSet::new();
    for o in ops {
        match o {
            Op::PushFile(r) => {
                let q = miko_adb::shell_quote(&remote_path(remote, r));
                commands.push(format!("[ ! -d {q} ]"));
                dirs.insert(remote_path(remote, r.parent().unwrap_or(Path::new(""))));
            }
            Op::PushDir(r) => {
                let q = miko_adb::shell_quote(&remote_path(remote, r));
                commands.push(format!("{{ [ ! -e {q} ] || [ -d {q} ]; }}"));
            }
            Op::Remove(_) => {}
        }
    }
    dirs.extend(mkdirs.iter().map(|d| remote_path(remote, d)));
    let dirs: Vec<String> = dirs.into_iter().collect();
    commands.extend(pack("mkdir -p", &dirs, SCRIPT_LIMIT / 2));
    commands
}

/// The batches that push `ops`' files, grouped by device folder.
pub fn file_batches(root: &Path, ops: &[Op]) -> Vec<Batch> {
    let mut batches: Vec<Batch> = Vec::new();
    for o in ops {
        let Op::PushFile(r) = o else { continue };
        let dir = r.parent().unwrap_or(Path::new("")).to_path_buf();
        match batches.iter_mut().find(|b| b.dir == dir) {
            Some(b) => {
                b.sources.push(root.join(r));
                b.files += 1;
            }
            None => batches.push(Batch {
                dir,
                sources: vec![root.join(r)],
                files: 1,
                newer_only: false,
            }),
        }
    }
    batches
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(s: &str) -> PathBuf {
        PathBuf::from(s)
    }

    fn tree(files: &[&str]) -> tempfile::TempDir {
        let t = tempfile::tempdir().unwrap();
        for f in files {
            let path = t.path().join(f);
            if f.ends_with('/') {
                std::fs::create_dir_all(&path).unwrap();
            } else {
                std::fs::create_dir_all(path.parent().unwrap()).unwrap();
                std::fs::write(&path, b"12345").unwrap();
            }
        }
        t
    }

    #[test]
    fn metadata_errors_do_not_masquerade_as_deletions() {
        assert_eq!(
            classify_metadata(Err(std::io::ErrorKind::NotFound.into())),
            Now::Gone
        );
        assert_eq!(
            classify_metadata(Err(std::io::ErrorKind::PermissionDenied.into())),
            Now::Unavailable
        );
        assert_eq!(
            classify_metadata(Err(std::io::ErrorKind::Other.into())),
            Now::Unavailable
        );
    }

    #[test]
    fn ignore_matches_any_component() {
        let i = Ignore::new(true, &["build".into(), " ".into()]);
        assert!(i.skips(&p("node_modules/x/y.js")));
        assert!(i.skips(&p("app/build/out.apk")));
        assert!(i.skips(&p("a/.git")));
        assert!(!i.skips(&p("src/git.rs")));
        assert!(!i.skips(&p("")));
        assert_eq!(
            i.names(),
            vec![".DS_Store", ".git", "build", "node_modules"]
        );
        assert!(!Ignore::new(false, &[]).skips(&p(".git/HEAD")));
    }

    #[test]
    fn a_clean_tree_is_one_push() {
        let t = tree(&["a.txt", "img/b.png", "img/deep/c.png", "empty/"]);
        let m = scan(t.path(), Path::new(""), &Ignore::new(true, &[]), 100).unwrap();
        assert_eq!(m.files, 3);
        assert_eq!(m.bytes, 15);
        assert_eq!(m.mkdirs, vec![p("")]);
        assert_eq!(m.batches.len(), 1);
        assert_eq!(m.batches[0].dir, p(""));
        assert_eq!(m.batches[0].files, 3);
        assert_eq!(
            m.batches[0].sources,
            vec![
                t.path().join("a.txt"),
                t.path().join("empty"),
                t.path().join("img")
            ]
        );
    }

    #[test]
    fn skipped_names_split_their_folders_only() {
        let t = tree(&[
            "README.md",
            ".git/HEAD",
            "web/node_modules/x/index.js",
            "web/src/app.js",
            "web/package.json",
            "docs/a.md",
        ]);
        let m = scan(t.path(), Path::new(""), &Ignore::new(true, &[]), 100).unwrap();
        assert_eq!(m.files, 4, "{m:?}");
        assert_eq!(m.mkdirs, vec![p(""), p("web")]);
        assert_eq!(
            m.batches,
            vec![
                Batch {
                    dir: p(""),
                    sources: vec![t.path().join("README.md"), t.path().join("docs")],
                    files: 2,
                    newer_only: false,
                },
                Batch {
                    dir: p("web"),
                    sources: vec![t.path().join("web/package.json"), t.path().join("web/src")],
                    files: 2,
                    newer_only: false,
                },
            ]
        );
    }

    #[cfg(unix)]
    #[test]
    fn symlinks_are_not_followed() {
        let t = tree(&["a.txt", "sub/b.txt"]);
        std::os::unix::fs::symlink(t.path(), t.path().join("sub/loop")).unwrap();
        let m = scan(t.path(), Path::new(""), &Ignore::new(true, &[]), 100).unwrap();
        assert_eq!(m.files, 2);
        assert_eq!(m.mkdirs, vec![p(""), p("sub")]);
    }

    #[test]
    fn too_many_files_is_refused_with_the_limit() {
        let t = tree(&["1", "2", "3", "node_modules/4", "node_modules/5"]);
        let ignore = Ignore::new(true, &[]);
        assert_eq!(scan(t.path(), Path::new(""), &ignore, 3).unwrap().files, 3);
        let e = scan(t.path(), Path::new(""), &ignore, 2).unwrap_err();
        assert_eq!(e.code, miko_core::ErrorCode::Usage);
        assert!(e.message.contains("more than 2 files"), "{e}");
        assert!(e.message.contains("node_modules"), "{e}");
        assert_eq!(e.data.unwrap()["max_files"], 2);
    }

    #[test]
    fn scanning_a_subfolder_keeps_its_relative_place() {
        let t = tree(&["a/b/c.txt", "a/b/.DS_Store"]);
        let m = scan(t.path(), Path::new("a/b"), &Ignore::new(true, &[]), 10).unwrap();
        assert_eq!(m.mkdirs, vec![p("a/b")]);
        assert_eq!(m.batches[0].dir, p("a/b"));
        assert_eq!(m.batches[0].sources, vec![t.path().join("a/b/c.txt")]);
        assert!(scan(t.path(), Path::new("nope"), &Ignore::new(true, &[]), 10).is_err());
    }

    #[test]
    fn debouncer_waits_for_quiet_but_not_forever() {
        let t0 = Instant::now();
        let ms = |n| t0 + Duration::from_millis(n);
        let mut d = Debouncer::default();
        assert_eq!(d.deadline(), None);
        assert_eq!(d.take(ms(10_000)), None);
        d.add(p("a"), ms(0));
        d.add(p("a"), ms(100));
        d.add(p("b"), ms(200));
        assert_eq!(d.deadline(), Some(ms(500)));
        assert_eq!(d.take(ms(499)), None);
        assert_eq!(d.take(ms(500)).unwrap(), BTreeSet::from([p("a"), p("b")]));
        assert!(d.is_empty());
        assert_eq!(d.deadline(), None);
        // A folder that never goes quiet still flushes after MAX_WAIT.
        for i in 0..30 {
            d.add(p("log"), ms(1_000 + i * 100));
        }
        assert_eq!(d.deadline(), Some(ms(3_000)));
        assert!(d.take(ms(3_000)).is_some());
    }

    #[test]
    fn plan_follows_what_paths_are_now() {
        let changed = BTreeSet::from([
            p("old.txt"),
            p("new.txt"),
            p("moved"),
            p("moved/inner.txt"),
            p("gone"),
            p("gone/x/y.txt"),
            p("node_modules/z.js"),
            p("link"),
        ]);
        let ops = plan(&changed, &Ignore::new(true, &[]), |r| {
            match r.to_str().unwrap() {
                "new.txt" | "moved/inner.txt" => Now::File,
                "moved" => Now::Dir,
                "link" => Now::Other,
                _ => Now::Gone,
            }
        });
        assert_eq!(
            ops,
            vec![
                Op::Remove(p("gone")),
                Op::PushDir(p("moved")),
                Op::PushFile(p("new.txt")),
                Op::Remove(p("old.txt")),
            ]
        );
    }

    /// A rename (`a.txt` → `b.txt`) arrives as both paths: the old one is
    /// removed and the new one pushed.
    #[test]
    fn a_rename_removes_the_old_path_and_pushes_the_new() {
        let t = tree(&["b.txt"]);
        let changed = BTreeSet::from([p("a.txt"), p("b.txt")]);
        let ops = plan(&changed, &Ignore::new(true, &[]), |r| probe(t.path(), r));
        assert_eq!(ops, vec![Op::Remove(p("a.txt")), Op::PushFile(p("b.txt"))]);
    }

    #[test]
    fn the_root_is_never_removed_and_a_rescan_covers_all() {
        let ignore = Ignore::new(true, &[]);
        let changed = BTreeSet::from([p(""), p("a")]);
        // The folder itself is skipped; what was inside it still goes.
        assert_eq!(
            plan(&changed, &ignore, |_| Now::Gone),
            vec![Op::Remove(p("a"))]
        );
        assert!(plan(&BTreeSet::from([p("")]), &ignore, |_| Now::Gone).is_empty());
        assert_eq!(
            plan(&changed, &ignore, |_| Now::Dir),
            vec![Op::PushDir(p(""))]
        );
    }

    #[test]
    fn remote_paths_join_with_slashes() {
        assert_eq!(remote_path("/sdcard/x/", Path::new("")), "/sdcard/x");
        assert_eq!(
            remote_path("/sdcard/x", Path::new("a/b c")),
            "/sdcard/x/a/b c"
        );
        assert_eq!(remote_path("/", Path::new("")), "/");
    }

    #[test]
    fn pack_and_scripts_stay_under_the_limit() {
        let args: Vec<String> = (0..50).map(|i| format!("/sdcard/dir/{i:03}")).collect();
        let cmds = pack("mkdir -p", &args, 100);
        assert!(cmds.len() > 1);
        assert!(
            cmds.iter()
                .all(|c| c.len() <= 100 && c.starts_with("mkdir -p '"))
        );
        assert_eq!(cmds.join(" ").matches("/sdcard/dir/").count(), 50);
        assert!(pack("rm -rf", &[], 100).is_empty());
        let s = scripts(&cmds, 250);
        assert!(
            s.iter()
                .all(|c| c.len() <= 250 && c.starts_with("set -e; "))
        );
        assert_eq!(s.join("").matches("mkdir -p").count(), cmds.len());
    }

    #[test]
    fn prepare_quotes_and_handles_type_changes() {
        let ops = vec![
            Op::Remove(p("it's")),
            Op::PushFile(p("d/f.txt")),
            Op::PushDir(p("e")),
        ];
        let cmds = prepare("/sdcard/s", &ops, &[p("e"), p("e/sub")]);
        assert_eq!(
            cmds,
            vec![
                r"rm -f '/sdcard/s/it'\''s'".to_string(),
                "[ ! -d '/sdcard/s/d/f.txt' ]".into(),
                "{ [ ! -e '/sdcard/s/e' ] || [ -d '/sdcard/s/e' ]; }".into(),
                "mkdir -p '/sdcard/s/d' '/sdcard/s/e' '/sdcard/s/e/sub'".into(),
            ]
        );
    }

    #[test]
    fn file_batches_group_by_folder() {
        let root = Path::new("/h");
        let ops = vec![
            Op::PushFile(p("a.txt")),
            Op::PushFile(p("d/b.txt")),
            Op::Remove(p("x")),
            Op::PushFile(p("c.txt")),
        ];
        let b = file_batches(root, &ops);
        assert_eq!(b.len(), 2);
        assert_eq!(b[0].dir, p(""));
        assert_eq!(b[0].sources, vec![p("/h/a.txt"), p("/h/c.txt")]);
        assert_eq!(b[0].files, 2);
        assert_eq!(b[1].dir, p("d"));
    }
}
