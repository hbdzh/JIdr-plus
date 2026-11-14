//! A graceful stop flushes the guest's storage first (#79): `proxy clear`
//! right before `device stop` must survive the next start.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod common;

use std::path::Path;
use std::time::{Duration, Instant};

use common::Harness;
use serde_json::json;

/// Replaces the fake SDK's `adb` with `body` (a `sh` script).
fn replace_adb(h: &Harness, body: &str) {
    let adb = h.tmp.path().join("studio/platform-tools/adb");
    // Write a sibling and rename: never rewrite a script a shell may be reading.
    let tmp = adb.with_extension("new");
    std::fs::write(&tmp, body).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    std::fs::rename(&tmp, &adb).unwrap();
}

async fn wait_for(what: &str, mut f: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !f() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

fn read(path: &Path) -> String {
    std::fs::read_to_string(path).unwrap_or_default()
}

#[tokio::test]
async fn stop_syncs_guest_storage_before_shutdown() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    c.ok("device.create", json!({ "name": "S", "image": "35" }))
        .await;
    let d = c.run("device.start", json!({ "device": "S" })).await;
    let serial = d["runtime"]["adb_serial"].as_str().unwrap().to_string();
    assert_eq!(h.backend.running().len(), 1);

    // An adb whose `shell sync` logs itself, then holds until released.
    let log = h.tmp.path().join("adb.log");
    let release = h.tmp.path().join("release");
    replace_adb(
        &h,
        &format!(
            "#!/bin/sh\necho \"$*\" >> '{log}'\n\
             while [ \"$1\" = -s ]; do shift 2; done\n\
             if [ \"$1 $2\" = 'shell sync' ]; then\n\
               i=0; while [ ! -e '{release}' ] && [ $i -lt 500 ]; do sleep 0.02; i=$((i+1)); done\n\
             fi\necho ok\n",
            log = log.display(),
            release = release.display(),
        ),
    );

    let mut c2 = h.client().await;
    let stop = tokio::spawn(async move { c2.ok("device.stop", json!({ "device": "S" })).await });

    let expected = format!("-s {serial} shell sync");
    wait_for("the guest sync", || {
        read(&log).lines().any(|l| l.trim() == expected)
    })
    .await;
    assert_eq!(
        h.backend.running().len(),
        1,
        "the emulator must still run while the guest syncs"
    );

    std::fs::write(&release, b"").unwrap();
    let s = stop.await.unwrap();
    assert_eq!(s["status"]["state"], "stopped", "{s}");
    assert!(h.backend.running().is_empty());
    h.stop().await;
}

#[tokio::test]
async fn stop_goes_ahead_when_the_guest_sync_fails() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    c.ok("device.create", json!({ "name": "F", "image": "35" }))
        .await;
    c.run("device.start", json!({ "device": "F" })).await;
    replace_adb(&h, "#!/bin/sh\necho 'error: device offline' >&2\nexit 1\n");
    let s = c.ok("device.stop", json!({ "device": "F" })).await;
    assert_eq!(s["status"]["state"], "stopped", "{s}");
    assert!(h.backend.running().is_empty());
    h.stop().await;
}

#[tokio::test]
async fn accepted_stop_finishes_after_client_disconnects() {
    let h = Harness::start().await;
    let mut admin = h.client().await;
    admin
        .ok(
            "device.create",
            json!({ "name": "Detached", "image": "35" }),
        )
        .await;
    admin
        .run("device.start", json!({ "device": "Detached" }))
        .await;
    let started = h.tmp.path().join("sync-started");
    let release = h.tmp.path().join("sync-release");
    replace_adb(
        &h,
        &format!(
            "#!/bin/sh\ntouch '{started}'\nwhile [ ! -e '{release}' ]; do sleep 0.02; done\necho ok\n",
            started = started.display(),
            release = release.display(),
        ),
    );
    let mut client = h.client().await;
    client.send_raw(&json!({"jsonrpc":"2.0", "id":99, "method":"device.stop", "params":{"device":"Detached"}}).to_string()).await;
    wait_for("stop enters guest sync", || started.exists()).await;
    drop(client);
    std::fs::write(&release, b"").unwrap();
    wait_for("the detached stop", || h.backend.running().is_empty()).await;
    let details = admin
        .ok("device.details", json!({"device":"Detached"}))
        .await;
    assert_eq!(details["device"]["status"]["state"], "stopped");
    h.stop().await;
}
