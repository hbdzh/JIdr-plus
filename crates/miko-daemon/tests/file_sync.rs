//! Synced folders (#27) over the socket: the fake backend, a real folder
//! watcher, and a fake adb that logs what it's asked to do.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod common;

use std::path::{Path, PathBuf};
use std::time::Duration;

use common::{Conn, Harness};
use serde_json::{Value, json};

/// Replaces the fake SDK's adb with one that logs its arguments.
fn logging_adb(h: &Harness) -> PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let log = h.tmp.path().join("adb.log");
    let adb = h.tmp.path().join("studio/platform-tools/adb");
    std::fs::write(
        &adb,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\necho ok\n",
            log.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&adb, std::fs::Permissions::from_mode(0o755)).unwrap();
    log
}

fn adb_log(log: &Path) -> String {
    std::fs::read_to_string(log).unwrap_or_default()
}

/// Reads events until `pick` returns something, for at most 15 s.
async fn wait_for<T>(sub: &mut Conn, mut pick: impl FnMut(&str, &Value) -> Option<T>) -> T {
    tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            let v = sub.read().await;
            if v["method"] == "event"
                && let Some(t) = pick(
                    v["params"]["topic"].as_str().unwrap_or_default(),
                    &v["params"]["data"],
                )
            {
                return t;
            }
        }
    })
    .await
    .expect("event never came")
}

/// Waits until a `file.sync.synced` of sync `id` satisfies `ok`.
async fn synced(sub: &mut Conn, id: &Value, ok: impl Fn(&Value) -> bool) -> Value {
    wait_for(sub, |topic, d| {
        (topic == "file.sync.synced" && &d["id"] == id && ok(d)).then(|| d.clone())
    })
    .await
}

async fn client(h: &Harness) -> Conn {
    let mut c = h.client().await;
    c.read_timeout = Duration::from_secs(25);
    c
}

async fn running_device(c: &mut Conn, name: &str) {
    c.ok("device.create", json!({ "name": name, "image": "35" }))
        .await;
    c.run("device.start", json!({ "device": name })).await;
}

fn folder(h: &Harness) -> PathBuf {
    let dir = h.tmp.path().join("site");
    for (f, body) in [
        ("index.html", "<h1>hi</h1>"),
        ("css/app.css", "body{}"),
        ("node_modules/left-pad/index.js", "x"),
        (".git/HEAD", "ref"),
    ] {
        let p = dir.join(f);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, body).unwrap();
    }
    std::fs::canonicalize(dir).unwrap()
}

#[tokio::test]
async fn a_sync_mirrors_the_folder_then_each_change_until_the_device_stops() {
    let h = Harness::start().await;
    let log = logging_adb(&h);
    let mut c = client(&h).await;
    let mut sub = client(&h).await;
    sub.ok("events.subscribe", json!({ "topics": ["file.sync."] }))
        .await;
    running_device(&mut c, "P").await;
    let dir = folder(&h);

    let s = c
        .ok("file.sync.start", json!({ "device": "P", "local": dir }))
        .await;
    let id = s["id"].clone();
    assert_eq!(s["remote"], "/sdcard/Download/site");
    assert_eq!(s["files"], 2, ".git and node_modules are skipped: {s}");
    assert_eq!(s["ignore"], json!([".DS_Store", ".git", "node_modules"]));
    assert_eq!(s["state"], "mirroring");

    let first = synced(&mut sub, &id, |_| true).await;
    assert_eq!(first["pushed"], 2, "{first}");
    let l = adb_log(&log);
    assert!(
        l.contains("shell set -e; mkdir -p '/sdcard/Download/site'"),
        "{l}"
    );
    assert!(
        l.contains(&format!(
            "push {} {} /sdcard/Download/site/",
            dir.join("css").display(),
            dir.join("index.html").display()
        )),
        "the clean tree goes in one push: {l}"
    );
    assert!(!l.contains("node_modules") && !l.contains(".git"), "{l}");

    // A change goes out alone.
    std::fs::write(dir.join("css/app.css"), "body{color:red}").unwrap();
    synced(&mut sub, &id, |d| d["pushed"] == 1).await;
    let l = adb_log(&log);
    assert!(
        l.contains(&format!(
            "push {} /sdcard/Download/site/css/",
            dir.join("css/app.css").display()
        )),
        "{l}"
    );

    // Deleting on the host deletes on the device.
    std::fs::remove_file(dir.join("index.html")).unwrap();
    synced(&mut sub, &id, |d| d["removed"] == 1).await;
    assert!(
        adb_log(&log).contains("rm -f '/sdcard/Download/site/index.html'"),
        "{}",
        adb_log(&log)
    );

    // Changes under a skipped folder never reach the device.
    std::fs::write(dir.join("node_modules/left-pad/index.js"), "y").unwrap();

    let list = c.ok("file.sync.list", json!({ "device": "P" })).await;
    assert_eq!(list.as_array().unwrap().len(), 1, "{list}");
    assert_eq!(list[0]["id"], id);
    assert!(list[0]["pushed"].as_u64().unwrap() >= 3, "{list}");
    assert!(list[0]["last_error"].is_null(), "{list}");

    // One sync per device folder.
    let e = c
        .err(
            "file.sync.start",
            json!({ "device": "P", "local": dir, "remote": "/sdcard/Download/site/css" }),
        )
        .await;
    assert_eq!(e["data"]["code"], "usage", "{e}");

    // Stopping the device ends the sync.
    c.ok("device.stop", json!({ "device": "P" })).await;
    let reason = wait_for(&mut sub, |topic, d| {
        (topic == "file.sync.stopped" && d["id"] == id).then(|| d["reason"].clone())
    })
    .await;
    assert_eq!(reason, "device_stopped");
    assert_eq!(c.ok("file.sync.list", json!({})).await, json!([]));
    assert!(!adb_log(&log).contains("node_modules"));
    h.stop().await;
}

#[tokio::test]
async fn stop_takes_an_id_prefix() {
    let h = Harness::start().await;
    logging_adb(&h);
    let mut c = client(&h).await;
    running_device(&mut c, "P").await;
    let dir = folder(&h);
    let s = c
        .ok(
            "file.sync.start",
            json!({ "device": "P", "local": dir, "remote": "/sdcard/www/" }),
        )
        .await;
    assert_eq!(s["remote"], "/sdcard/www");
    let id = s["id"].as_str().unwrap();
    let stopped = c.ok("file.sync.stop", json!({ "id": &id[..8] })).await;
    assert_eq!(stopped["id"], id);
    assert_eq!(c.ok("file.sync.list", json!({})).await, json!([]));
    let e = c.err("file.sync.stop", json!({ "id": id })).await;
    assert_eq!(e["data"]["code"], "not_found", "{e}");
    h.stop().await;
}

#[tokio::test]
async fn deleting_a_host_directory_removes_only_previously_synced_files() {
    let h = Harness::start().await;
    let log = logging_adb(&h);
    let mut c = client(&h).await;
    let mut sub = client(&h).await;
    sub.ok("events.subscribe", json!({ "topics": ["file.sync."] }))
        .await;
    running_device(&mut c, "P").await;
    let dir = folder(&h);
    let s = c
        .ok("file.sync.start", json!({ "device": "P", "local": dir }))
        .await;
    let id = s["id"].clone();
    synced(&mut sub, &id, |_| true).await;
    std::fs::remove_dir_all(dir.join("css")).unwrap();
    synced(&mut sub, &id, |d| d["removed"] == 1).await;
    let log = adb_log(&log);
    assert!(
        log.contains("rm -f '/sdcard/Download/site/css/app.css'"),
        "{log}"
    );
    assert!(!log.contains("rm -rf '/sdcard/Download/site/css'"), "{log}");
    assert!(!log.contains("rm -f '/sdcard/Download/site/css'"), "{log}");
    h.stop().await;
}

#[tokio::test]
async fn failed_initial_copy_is_retried_without_another_file_change() {
    use std::os::unix::fs::PermissionsExt;
    let h = Harness::start().await;
    let adb = h.tmp.path().join("studio/platform-tools/adb");
    let marker = h.tmp.path().join("push-failed");
    std::fs::write(&adb, format!("#!/bin/sh\ncase \"$*\" in *' push '*) if [ ! -e '{}' ]; then touch '{}'; echo failed >&2; exit 1; fi;; esac\necho ok\n", marker.display(), marker.display())).unwrap();
    std::fs::set_permissions(&adb, std::fs::Permissions::from_mode(0o755)).unwrap();
    let mut c = client(&h).await;
    let mut sub = client(&h).await;
    sub.ok("events.subscribe", json!({ "topics": ["file.sync."] }))
        .await;
    running_device(&mut c, "P").await;
    let dir = folder(&h);
    let s = c
        .ok("file.sync.start", json!({ "device": "P", "local": dir }))
        .await;
    let id = s["id"].clone();
    wait_for(&mut sub, |topic, d| {
        (topic == "file.sync.error" && d["id"] == id).then_some(())
    })
    .await;
    synced(&mut sub, &id, |d| d["pushed"] == 2).await;
    assert!(marker.exists());
    h.stop().await;
}

#[tokio::test]
async fn bad_starts_are_refused() {
    let h = Harness::start().await;
    logging_adb(&h);
    let mut c = client(&h).await;
    let dir = folder(&h);
    c.ok("device.create", json!({ "name": "Off", "image": "35" }))
        .await;
    let e = c
        .err("file.sync.start", json!({ "device": "Off", "local": dir }))
        .await;
    assert_eq!(e["data"]["code"], "not_found", "a stopped device: {e}");

    running_device(&mut c, "P").await;
    for (params, why) in [
        (json!({ "device": "P", "local": "site" }), "a relative path"),
        (
            json!({ "device": "P", "local": dir.join("index.html") }),
            "a file",
        ),
        (
            json!({ "device": "P", "local": dir, "remote": "/" }),
            "the device root",
        ),
        (
            json!({ "device": "P", "local": dir, "max_files": 1 }),
            "too many files",
        ),
    ] {
        let e = c.err("file.sync.start", params).await;
        assert_eq!(e["data"]["code"], "usage", "{why}: {e}");
    }
    // Opting out of the default skips counts them again.
    let e = c
        .err(
            "file.sync.start",
            json!({ "device": "P", "local": dir, "no_default_ignore": true, "max_files": 3 }),
        )
        .await;
    assert!(
        e["message"].as_str().unwrap().contains("more than 3 files"),
        "{e}"
    );
    assert_eq!(c.ok("file.sync.list", json!({})).await, json!([]));
    h.stop().await;
}

/// Replaces the fake SDK's adb with a stateful device filesystem simulator
/// backed by `<tmp>/device_fs`, supporting `shell` (find/stat/sha256sum/
/// mkdir/rm/test), `push`, and `pull`.
fn device_adb(h: &Harness) -> (PathBuf, PathBuf, PathBuf) {
    use std::os::unix::fs::PermissionsExt;
    let dev_root = h.tmp.path().join("device_fs");
    std::fs::create_dir_all(&dev_root).unwrap();
    let log = h.tmp.path().join("adb.log");
    let fail_marker = h.tmp.path().join("fail-adb");
    let helper = h.tmp.path().join("fake_adb.py");
    std::fs::write(
        &helper,
        r#"#!/usr/bin/env python3
import hashlib, os, shlex, shutil, sys

dev_root = sys.argv[1]
log_path = sys.argv[2]
fail_marker = sys.argv[3]
args = sys.argv[4:]
while len(args) >= 2 and args[0] == "-s":
    args = args[2:]

with open(log_path, "a") as f:
    f.write(" ".join(args) + "\n")

if os.path.exists(fail_marker):
    sys.stderr.write("injected adb failure\n")
    sys.exit(1)

def to_host(p):
    if not p.startswith("/"):
        return p
    return os.path.join(dev_root, p.lstrip("/"))

def to_dev(p):
    rel = os.path.relpath(p, dev_root)
    return "/" + rel.replace(os.sep, "/")

if not args:
    sys.exit(0)

cmd = args[0]
if cmd == "push":
    srcs = args[1:-1]
    dest = to_host(args[-1].rstrip("/"))
    os.makedirs(dest, exist_ok=True)
    for s in srcs:
        base = os.path.basename(s.rstrip("/"))
        target = os.path.join(dest, base)
        if os.path.isdir(s):
            shutil.copytree(s, target, dirs_exist_ok=True)
        else:
            shutil.copy2(s, target)
    sys.exit(0)

if cmd == "pull":
    src = to_host(args[1])
    dst = args[2]
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
    sys.exit(0)

if cmd == "shell":
    script = args[1]
    if "find " in script and "-exec stat -c" in script:
        tokens = shlex.split(script)
        idx = tokens.index("find")
        remote = tokens[idx + 1]
        h_remote = to_host(remote)
        if not os.path.exists(h_remote):
            sys.exit(0)
        if not os.path.isdir(h_remote):
            sys.stderr.write("remote path is not a directory\n")
            sys.exit(2)
        ignored = set()
        for i, t in enumerate(tokens):
            if t == "-name" and i + 1 < len(tokens):
                ignored.add(tokens[i + 1])
        for cur, dirs, files in os.walk(h_remote):
            dirs[:] = sorted(d for d in dirs if d not in ignored)
            for name in sorted(files):
                if name in ignored:
                    continue
                fp = os.path.join(cur, name)
                st = os.lstat(fp)
                print(f"{st.st_size} {int(st.st_mtime)} {to_dev(fp)}")
        sys.exit(0)

    if script.startswith("set -e; sha256sum ") or script.startswith("sha256sum "):
        for sub in [s.strip() for s in script.split(";")]:
            if not sub or sub == "set -e":
                continue
            parts = shlex.split(sub)
            if parts[0] == "sha256sum":
                for rp in parts[1:]:
                    hp = to_host(rp)
                    with open(hp, "rb") as fh:
                        digest = hashlib.sha256(fh.read()).hexdigest()
                    print(f"{digest}  {rp}")
        sys.exit(0)

    # Generic mkdir / rm / test script
    for sub in [s.strip() for s in script.split(";")]:
        if not sub or sub == "set -e":
            continue
        if sub.startswith("mkdir -p "):
            for p in shlex.split(sub)[2:]:
                os.makedirs(to_host(p), exist_ok=True)
        elif sub.startswith("rm -f "):
            for p in shlex.split(sub)[2:]:
                hp = to_host(p)
                if os.path.exists(hp):
                    os.remove(hp)
        elif sub.startswith("[ ! -d "):
            p = shlex.split(sub)[3]
            if os.path.isdir(to_host(p)):
                sys.exit(1)
    sys.exit(0)

sys.exit(0)
"#,
    )
    .unwrap();
    let adb = h.tmp.path().join("studio/platform-tools/adb");
    std::fs::write(
        &adb,
        format!(
            "#!/bin/sh\nexec python3 '{}' '{}' '{}' '{}' \"$@\"\n",
            helper.display(),
            dev_root.display(),
            log.display(),
            fail_marker.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&adb, std::fs::Permissions::from_mode(0o755)).unwrap();
    (dev_root, log, fail_marker)
}

#[tokio::test]
async fn bidirectional_sync_merges_and_propagates_changes_both_ways() {
    let h = Harness::start().await;
    let (dev_root, _log, _fail) = device_adb(&h);
    let mut c = client(&h).await;
    let mut sub = client(&h).await;
    sub.ok("events.subscribe", json!({ "topics": ["file.sync."] }))
        .await;
    running_device(&mut c, "P").await;

    let dir = folder(&h);
    let remote_dir = dev_root.join("sdcard/Download/site");
    std::fs::create_dir_all(&remote_dir).unwrap();
    std::fs::write(remote_dir.join("from-device.txt"), "hello from android").unwrap();

    let s = c
        .ok(
            "file.sync.start",
            json!({ "device": "P", "local": dir, "direction": "bidirectional" }),
        )
        .await;
    let id = s["id"].clone();
    assert_eq!(s["direction"], "bidirectional");

    let first = synced(&mut sub, &id, |_| true).await;
    assert_eq!(first["pushed"], 2, "{first}");
    assert_eq!(first["pulled"], 1, "{first}");
    assert_eq!(
        std::fs::read_to_string(dir.join("from-device.txt")).unwrap(),
        "hello from android"
    );
    assert_eq!(
        std::fs::read_to_string(remote_dir.join("index.html")).unwrap(),
        "<h1>hi</h1>"
    );
    assert!(!remote_dir.join(".git").exists());
    assert!(!remote_dir.join("node_modules").exists());

    // Edit on device -> pulled to host.
    std::fs::write(remote_dir.join("from-device.txt"), "edited on android").unwrap();
    synced(&mut sub, &id, |d| d["pulled"] == 1).await;
    assert_eq!(
        std::fs::read_to_string(dir.join("from-device.txt")).unwrap(),
        "edited on android"
    );

    // Delete on device -> deleted on host.
    std::fs::remove_file(remote_dir.join("index.html")).unwrap();
    synced(&mut sub, &id, |d| d["removed_local"] == 1).await;
    assert!(!dir.join("index.html").exists());

    // Edit and delete on host -> pushed/removed on device.
    std::fs::write(dir.join("css/app.css"), "body{color:blue}").unwrap();
    synced(&mut sub, &id, |d| d["pushed"] == 1).await;
    assert_eq!(
        std::fs::read_to_string(remote_dir.join("css/app.css")).unwrap(),
        "body{color:blue}"
    );

    std::fs::remove_file(dir.join("from-device.txt")).unwrap();
    synced(&mut sub, &id, |d| d["removed"] == 1).await;
    assert!(!remote_dir.join("from-device.txt").exists());

    let list = c.ok("file.sync.list", json!({ "device": "P" })).await;
    assert_eq!(list[0]["direction"], "bidirectional");
    assert_eq!(list[0]["pulled"], 2);
    assert_eq!(list[0]["removed_local"], 1);
    assert_eq!(list[0]["conflicts"], json!([]));

    c.ok("file.sync.stop", json!({ "id": id })).await;
    h.stop().await;
}

#[tokio::test]
async fn bidirectional_conflict_preserves_both_sides_until_resolved() {
    let h = Harness::start().await;
    let (dev_root, _log, _fail) = device_adb(&h);
    let mut c = client(&h).await;
    let mut sub = client(&h).await;
    sub.ok("events.subscribe", json!({ "topics": ["file.sync."] }))
        .await;
    running_device(&mut c, "P").await;

    let dir = h.tmp.path().join("notes");
    std::fs::create_dir_all(&dir).unwrap();
    let dir = std::fs::canonicalize(dir).unwrap();
    std::fs::write(dir.join("a.txt"), "base").unwrap();
    std::fs::write(dir.join("b.txt"), "base").unwrap();

    let s = c
        .ok(
            "file.sync.start",
            json!({ "device": "P", "local": dir, "direction": "bidirectional" }),
        )
        .await;
    let id = s["id"].clone();
    synced(&mut sub, &id, |d| d["pushed"] == 2).await;

    let remote_dir = dev_root.join("sdcard/Download/notes");
    // Modify a.txt on local and delete a.txt on remote -> conflict (survivor protected).
    // Modify b.txt on both sides with identical mtime -> conflict.
    let same_time = std::time::SystemTime::UNIX_EPOCH + Duration::from_secs(1_700_000_500);
    std::fs::write(dir.join("a.txt"), "local-a-edit").unwrap();
    std::fs::remove_file(remote_dir.join("a.txt")).unwrap();

    std::fs::write(dir.join("b.txt"), "local-b").unwrap();
    std::fs::File::options()
        .write(true)
        .open(dir.join("b.txt"))
        .unwrap()
        .set_modified(same_time)
        .unwrap();
    std::fs::write(remote_dir.join("b.txt"), "remote-b").unwrap();
    std::fs::File::options()
        .write(true)
        .open(remote_dir.join("b.txt"))
        .unwrap()
        .set_modified(same_time)
        .unwrap();

    let conflict_ev = wait_for(&mut sub, |topic, d| {
        (topic == "file.sync.conflict" && d["id"] == id).then(|| d.clone())
    })
    .await;
    assert_eq!(conflict_ev["conflicts"].as_array().unwrap().len(), 2);
    assert_eq!(
        std::fs::read_to_string(dir.join("a.txt")).unwrap(),
        "local-a-edit",
        "changed local survivor must not be deleted"
    );

    // Resolve a.txt by keeping local.
    let after_a = c
        .ok(
            "file.sync.resolve",
            json!({ "id": id, "path": "a.txt", "resolution": "keep_local" }),
        )
        .await;
    assert_eq!(after_a["conflicts"].as_array().unwrap().len(), 1);
    assert_eq!(
        std::fs::read_to_string(remote_dir.join("a.txt")).unwrap(),
        "local-a-edit"
    );

    // Resolve b.txt by keeping both.
    let after_b = c
        .ok(
            "file.sync.resolve",
            json!({ "id": id, "path": "b.txt", "resolution": "keep_both" }),
        )
        .await;
    assert_eq!(after_b["conflicts"], json!([]));
    assert_eq!(
        std::fs::read_to_string(dir.join("b.txt")).unwrap(),
        "remote-b"
    );
    assert_eq!(
        std::fs::read_to_string(remote_dir.join("b.txt")).unwrap(),
        "remote-b"
    );
    let conflict_copy = std::fs::read_dir(&dir)
        .unwrap()
        .filter_map(Result::ok)
        .find(|e| e.file_name().to_string_lossy().contains("sync-conflict"))
        .expect("conflict copy must exist locally");
    assert_eq!(
        std::fs::read_to_string(conflict_copy.path()).unwrap(),
        "local-b"
    );
    assert!(remote_dir.join(conflict_copy.file_name()).exists());

    c.ok("file.sync.stop", json!({ "id": id })).await;
    h.stop().await;
}

#[tokio::test]
async fn bidirectional_transient_adb_failure_does_not_lose_files() {
    let h = Harness::start().await;
    let (dev_root, _log, fail_marker) = device_adb(&h);
    let mut c = client(&h).await;
    let mut sub = client(&h).await;
    sub.ok("events.subscribe", json!({ "topics": ["file.sync."] }))
        .await;
    running_device(&mut c, "P").await;

    let dir = folder(&h);
    std::fs::write(&fail_marker, "1").unwrap();
    let s = c
        .ok(
            "file.sync.start",
            json!({ "device": "P", "local": dir, "direction": "bidirectional" }),
        )
        .await;
    let id = s["id"].clone();
    wait_for(&mut sub, |topic, d| {
        (topic == "file.sync.error" && d["id"] == id).then_some(())
    })
    .await;

    // Clear injected failure; next poll must still push both local files.
    std::fs::remove_file(&fail_marker).unwrap();
    synced(&mut sub, &id, |d| d["pushed"] == 2).await;
    assert!(dev_root.join("sdcard/Download/site/index.html").exists());
    assert!(dir.join("index.html").exists());

    c.ok("file.sync.stop", json!({ "id": id })).await;
    h.stop().await;
}
