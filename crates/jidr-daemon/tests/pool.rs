//! Bases, the pool and leases (D42, Phase 13d) on the fake backend.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod common;

use chrono::{Duration, Utc};
use common::{Conn, Harness};
use jidr_core::provider::DaemonContext;
use serde_json::{Value, json};

/// A lean base `Base` made from a running device.
async fn base(c: &mut Conn) -> Value {
    c.ok(
        "device.create",
        json!({ "name": "Src", "image": "35", "profile": "agent-lean", "root_mode": "adb" }),
    )
    .await;
    c.run("device.start", json!({ "device": "Src" })).await;
    c.run(
        "base.create",
        json!({ "from_device": "Src", "name": "Base" }),
    )
    .await
}

fn avd_dir(h: &Harness, d: &Value) -> std::path::PathBuf {
    h.paths
        .avd_home()
        .join(format!("{}.avd", d["avd"].as_str().unwrap()))
}

fn replace_adb(h: &Harness, script: &str) {
    use std::os::unix::fs::PermissionsExt;
    let path = h.tmp.path().join("studio/platform-tools/adb");
    let tmp = path.with_extension("test");
    std::fs::write(&tmp, script).unwrap();
    std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755)).unwrap();
    std::fs::rename(tmp, path).unwrap();
}

#[tokio::test]
async fn base_leaves_source_animation_settings_untouched_and_configures_clone() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    c.ok(
        "device.create",
        json!({"name":"Src", "image":"35", "profile":"agent-lean"}),
    )
    .await;
    let source = c.run("device.start", json!({"device":"Src"})).await;
    let source_serial = source["runtime"]["adb_serial"].as_str().unwrap();
    let log = h.tmp.path().join("animation-commands.log");
    replace_adb(
        &h,
        &format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\necho ok\n",
            log.display()
        ),
    );
    c.run("base.create", json!({"from_device":"Src", "name":"Base"}))
        .await;
    let before = std::fs::read_to_string(&log).unwrap_or_default();
    assert!(
        !before.contains("settings put global"),
        "base changed source: {before}"
    );
    let clone = c.run("pool.get", json!({"base":"Base", "ttl_s":600})).await;
    let commands = std::fs::read_to_string(&log).unwrap();
    for key in [
        "window_animation_scale",
        "transition_animation_scale",
        "animator_duration_scale",
    ] {
        assert!(
            commands.lines().any(|line| line
                == format!(
                    "-s {} shell settings put global {key} 0",
                    clone["serial"].as_str().unwrap()
                )),
            "{commands}"
        );
        assert!(
            !commands.lines().any(|line| line.contains(source_serial)
                && line.contains(&format!("settings put global {key}"))),
            "{commands}"
        );
    }
    c.ok("pool.release", json!({"lease":clone["lease"]["id"]}))
        .await;
    h.stop().await;
}

#[tokio::test]
async fn base_snapshot_failure_does_not_change_source_animations() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    c.ok("device.create", json!({"name":"Src", "image":"35"}))
        .await;
    c.run("device.start", json!({"device":"Src"})).await;
    let log = h.tmp.path().join("animation-commands.log");
    replace_adb(
        &h,
        &format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\necho ok\n",
            log.display()
        ),
    );
    h.backend.fail_saves();
    let job = c
        .ok("base.create", json!({"from_device":"Src", "name":"Base"}))
        .await;
    let done = c.ok("jobs.wait", json!({"job":job["job"]})).await;
    assert_eq!(done["state"], "failed", "{done}");
    assert!(
        !std::fs::read_to_string(&log)
            .unwrap_or_default()
            .contains("settings put global")
    );
    assert_eq!(
        c.ok("device.details", json!({"device":"Src"})).await["device"]["status"]["state"],
        "running"
    );
    h.stop().await;
}

#[tokio::test]
async fn cancelled_base_snapshot_does_not_change_or_stop_source() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    c.ok("device.create", json!({"name":"Src", "image":"35"}))
        .await;
    c.run("device.start", json!({"device":"Src"})).await;
    let log = h.tmp.path().join("animation-commands.log");
    replace_adb(
        &h,
        &format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\necho ok\n",
            log.display()
        ),
    );
    let gate = h.backend.gate_snapshots();
    let job = c
        .ok("base.create", json!({"from_device":"Src", "name":"Base"}))
        .await;
    for _ in 0..100 {
        if !h.backend.saves().is_empty() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert!(!h.backend.saves().is_empty());
    c.ok("jobs.cancel", json!({"job":job["job"]})).await;
    gate.add_permits(1);
    let done = c.ok("jobs.wait", json!({"job":job["job"]})).await;
    assert_eq!(done["state"], "cancelled", "{done}");
    assert!(
        !std::fs::read_to_string(&log)
            .unwrap_or_default()
            .contains("settings put global")
    );
    assert_eq!(
        c.ok("device.details", json!({"device":"Src"})).await["device"]["status"]["state"],
        "running"
    );
    h.stop().await;
}

#[tokio::test]
async fn clone_animation_failure_removes_clone_and_lease() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    base(&mut c).await;
    replace_adb(
        &h,
        "#!/bin/sh\ncase \"$*\" in *'settings put global'*) echo denied >&2; exit 1;; esac\necho ok\n",
    );
    let job = c.ok("pool.get", json!({"base":"Base", "ttl_s":600})).await;
    let done = c.ok("jobs.wait", json!({"job":job["job"]})).await;
    assert_eq!(done["state"], "failed", "{done}");
    assert!(
        done["error"]["message"]
            .as_str()
            .unwrap()
            .contains("clone animations")
    );
    assert!(
        c.ok("pool.list", json!({}))
            .await
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert_eq!(
        c.ok("device.list", json!({}))
            .await
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert!(h.backend.running().is_empty());
    h.stop().await;
}

#[tokio::test]
async fn pool_base_create_get_and_release() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    let b = base(&mut c).await;
    assert_eq!(b["base"], true, "{b}");
    assert_eq!(b["root"]["mode"], "adb", "root travels (D29)");
    assert!(
        avd_dir(&h, &b)
            .join("snapshots/jidr-base/ram.bin")
            .is_file()
    );
    let src = c.ok("device.details", json!({ "device": "Src" })).await;
    assert_eq!(src["device"]["status"]["state"], "stopped");
    // A base is read-only.
    let job = c.ok("device.start", json!({ "device": "Base" })).await;
    let done = c.ok("jobs.wait", json!({ "job": job["job"] })).await;
    assert!(
        done["error"]["message"]
            .as_str()
            .unwrap()
            .contains("pool.get"),
        "{done}"
    );

    let r = c
        .run("pool.get", json!({ "base": "Base", "ttl_s": 600 }))
        .await;
    let d = &r["device"];
    assert_eq!(d["status"]["state"], "running", "{r}");
    assert_eq!(d["agent_owned"], true);
    assert_eq!(d["pool_base"], b["id"]);
    assert!(r["serial"].as_str().unwrap().starts_with("emulator-"));
    assert_eq!(r["lease"]["holder"]["kind"], "ttl");
    let launches = h.backend.launches();
    let opts = &launches.last().unwrap().1;
    assert_eq!(opts.snapshot.as_deref(), Some("jidr-base"));
    assert!(!opts.snapshot_save && !opts.cold_boot);
    let list = c.ok("pool.list", json!({})).await;
    assert_eq!(list[0]["base"], "Base");
    assert_eq!(c.ok("base.list", json!({})).await[0]["leases"], 1);

    // A base with leased clones can't go.
    let e = c.err("base.delete", json!({ "base": "Base" })).await;
    assert_eq!(e["data"]["code"], "busy", "{e}");

    let dir = avd_dir(&h, d);
    assert!(dir.is_dir());
    c.ok("pool.release", json!({ "lease": r["lease"]["id"] }))
        .await;
    assert!(!dir.exists(), "the clone's AVD is deleted");
    assert!(h.backend.running().is_empty());
    let names: Vec<String> = c
        .ok("device.list", json!({}))
        .await
        .as_array()
        .unwrap()
        .iter()
        .map(|d| d["name"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(names, ["Src", "Base"]);
    assert_eq!(c.ok("pool.list", json!({})).await, json!([]));
    c.ok("base.delete", json!({ "base": "Base" })).await;
    h.stop().await;
}

#[tokio::test]
async fn pool_ttl_lease_expires_and_renews() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    base(&mut c).await;
    let r = c
        .run("pool.get", json!({ "base": "Base", "ttl_s": 60 }))
        .await;
    let lease = r["lease"]["id"].clone();
    let state = h.daemon.state().clone();
    assert!(
        state
            .reap(Utc::now() + Duration::seconds(30))
            .await
            .is_empty()
    );
    let renewed = c
        .ok("pool.renew", json!({ "lease": lease, "ttl_s": 3600 }))
        .await;
    assert!(renewed["expires_at"].is_string());
    assert!(
        state
            .reap(Utc::now() + Duration::seconds(120))
            .await
            .is_empty(),
        "renewed"
    );
    let reaped = state.reap(Utc::now() + Duration::seconds(3601)).await;
    assert_eq!(reaped.len(), 1);
    assert!(h.backend.running().is_empty());
    assert_eq!(
        c.ok("device.list", json!({}))
            .await
            .as_array()
            .unwrap()
            .len(),
        2
    );
    h.stop().await;
}

/// A connection lease outlives its connection by 2 minutes, then is reaped.
#[tokio::test]
async fn pool_connection_lease_reaped_after_grace() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    base(&mut c).await;
    let mut agent = h.client().await;
    let r = agent.run("pool.get", json!({ "base": "Base" })).await;
    assert_eq!(r["lease"]["holder"]["kind"], "connection", "{r}");
    assert!(r["lease"]["expires_at"].is_null());
    let state = h.daemon.state().clone();
    assert!(
        state.reap(Utc::now() + Duration::days(1)).await.is_empty(),
        "connected"
    );
    drop(agent);
    // The daemon notices the closed socket.
    for _ in 0..100 {
        if !c.ok("pool.list", json!({})).await[0]["lease"]["expires_at"].is_null() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert!(
        state
            .reap(Utc::now() + Duration::seconds(100))
            .await
            .is_empty(),
        "in grace"
    );
    assert_eq!(
        state.reap(Utc::now() + Duration::seconds(121)).await.len(),
        1
    );
    assert_eq!(c.ok("pool.list", json!({})).await, json!([]));
    assert!(h.backend.running().is_empty());
    h.stop().await;
}

/// 8 GB × 75% = 6 GB: one lean clone (4 GB) fits. A second pool.get waits,
/// then fails; one that waits long enough gets the slot when it frees up.
#[tokio::test]
async fn pool_full_waits_then_errors() {
    let h = Harness::start_with_memory(8192).await;
    let mut c = h.client().await;
    base(&mut c).await;
    let first = c
        .run("pool.get", json!({ "base": "Base", "ttl_s": 600 }))
        .await;
    let t = std::time::Instant::now();
    let job = c
        .ok(
            "pool.get",
            json!({ "base": "Base", "ttl_s": 600, "timeout_s": 1 }),
        )
        .await;
    let done = c.ok("jobs.wait", json!({ "job": job["job"] })).await;
    assert!(
        t.elapsed() >= std::time::Duration::from_secs(1),
        "it waited"
    );
    assert_eq!(done["error"]["code"], "resource_exhausted", "{done}");
    assert!(
        done["error"]["message"]
            .as_str()
            .unwrap()
            .contains("pool is full")
    );
    assert_eq!(
        c.ok("pool.list", json!({})).await.as_array().unwrap().len(),
        1
    );
    assert_eq!(
        c.ok("device.list", json!({}))
            .await
            .as_array()
            .unwrap()
            .len(),
        3,
        "the failed clone was cleaned up"
    );

    let job = c
        .ok(
            "pool.get",
            json!({ "base": "Base", "ttl_s": 600, "timeout_s": 20 }),
        )
        .await;
    tokio::time::sleep(std::time::Duration::from_millis(700)).await;
    c.ok("pool.release", json!({ "device": first["device"]["name"] }))
        .await;
    let done = c
        .ok("jobs.wait", json!({ "job": job["job"], "timeout_s": 8 }))
        .await;
    assert_eq!(done["state"], "succeeded", "{done}");
    h.stop().await;
}

#[tokio::test]
async fn pool_ttl_starts_after_boot_and_pending_is_not_reaped() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    base(&mut c).await;
    let gate = h.backend.gate_starts();
    let job = c.ok("pool.get", json!({"base":"Base", "ttl_s": 1})).await;
    for _ in 0..100 {
        if !c
            .ok("pool.list", json!({}))
            .await
            .as_array()
            .unwrap()
            .is_empty()
        {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    let pending = c.ok("pool.list", json!({})).await;
    assert_eq!(pending.as_array().unwrap().len(), 1);
    let pending_id = serde_json::from_value(pending[0]["lease"]["id"].clone()).unwrap();
    let now = Utc::now();
    let recovered = jidr_daemon::leases::Leases::load(
        &h.paths.data.join("pool-leases.json"),
        &h.daemon.state().devices().await,
        now,
    )
    .unwrap();
    assert!(!recovered.is_pending(pending_id));
    assert_eq!(
        recovered.get(pending_id).unwrap().expires_at,
        Some(now + Duration::seconds(120))
    );
    tokio::time::sleep(std::time::Duration::from_millis(1200)).await;
    assert!(
        h.daemon
            .state()
            .reap(Utc::now() + Duration::days(1))
            .await
            .is_empty()
    );
    gate.add_permits(1);
    let done = c
        .ok("jobs.wait", json!({"job":job["job"], "timeout_s":8}))
        .await;
    assert_eq!(done["state"], "succeeded", "{done}");
    let expiry = chrono::DateTime::parse_from_rfc3339(
        done["result"]["lease"]["expires_at"].as_str().unwrap(),
    )
    .unwrap();
    assert!(expiry > Utc::now() + Duration::milliseconds(500), "{done}");
    c.ok(
        "pool.release",
        json!({"lease":done["result"]["lease"]["id"]}),
    )
    .await;
    h.stop().await;
}

#[tokio::test]
async fn pool_ttl_and_id_survive_state_reconstruction() {
    use jidr_backend::fake::FakeBackend;
    use jidr_daemon::{DaemonConfig, state::State};
    use std::sync::Arc;
    let h = Harness::start().await;
    let mut c = h.client().await;
    base(&mut c).await;
    let leased = c
        .run("pool.get", json!({"base":"Base", "ttl_s":3600}))
        .await;
    let id = serde_json::from_value(leased["lease"]["id"].clone()).unwrap();
    let renewed = c.ok("pool.renew", json!({"lease":id,"ttl_s":7200})).await;
    let devices = h.daemon.state().devices().await;
    let path = h.paths.data.join("pool-leases.json");
    let restored = jidr_daemon::leases::Leases::load(&path, &devices, Utc::now()).unwrap();
    let lease = restored.get(id).unwrap();
    assert_eq!(serde_json::to_value(lease).unwrap(), renewed);
    let state = State::new(
        DaemonConfig {
            paths: h.paths.clone(),
            studio_sdk: Some(h.tmp.path().join("studio")),
            idle_timeout: None,
            sdk_repo: None,
        },
        Arc::new(FakeBackend::new()),
        None,
    )
    .unwrap();
    assert_eq!(state.lease_count(), 1);
    assert!(
        state
            .reap(Utc::now() + Duration::seconds(121))
            .await
            .is_empty()
    );
    c.ok("pool.release", json!({"lease":id})).await;
    h.stop().await;
}

#[tokio::test]
async fn corrupt_lease_file_fails_closed_without_deleting_clones() {
    use jidr_backend::fake::FakeBackend;
    use jidr_daemon::{DaemonConfig, state::State};
    use std::sync::Arc;
    let h = Harness::start().await;
    let mut c = h.client().await;
    base(&mut c).await;
    let leased = c
        .run("pool.get", json!({"base":"Base", "ttl_s":3600}))
        .await;
    let clone_dir = avd_dir(&h, &leased["device"]);
    let path = h.paths.data.join("pool-leases.json");
    let original = std::fs::read(&path).unwrap();
    std::fs::write(&path, b"{broken").unwrap();
    let result = State::new(
        DaemonConfig {
            paths: h.paths.clone(),
            studio_sdk: Some(h.tmp.path().join("studio")),
            idle_timeout: None,
            sdk_repo: None,
        },
        Arc::new(FakeBackend::new()),
        None,
    );
    assert!(result.is_err());
    assert_eq!(std::fs::read(&path).unwrap(), b"{broken");
    assert!(clone_dir.is_dir());
    std::fs::write(&path, original).unwrap();
    c.ok("pool.release", json!({"lease":leased["lease"]["id"]}))
        .await;
    h.stop().await;
}

#[tokio::test]
async fn recovered_connection_lease_grace_does_not_restart_on_each_reload() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    base(&mut c).await;
    let leased = c.run("pool.get", json!({"base":"Base"})).await;
    let id = serde_json::from_value(leased["lease"]["id"].clone()).unwrap();
    let devices = h.daemon.state().devices().await;
    let path = h.paths.data.join("pool-leases.json");
    let now = Utc::now();
    let first = jidr_daemon::leases::Leases::load(&path, &devices, now).unwrap();
    assert_eq!(
        first.get(id).unwrap().expires_at,
        Some(now + Duration::seconds(120))
    );
    // Write only to an isolated test path; the live daemon keeps its file.
    let recovered_path = h.tmp.path().join("recovered-leases.json");
    first.save(&recovered_path).unwrap();
    let second =
        jidr_daemon::leases::Leases::load(&recovered_path, &devices, now + Duration::seconds(60))
            .unwrap();
    assert_eq!(
        second.get(id).unwrap().expires_at,
        Some(now + Duration::seconds(120))
    );
    c.ok("pool.release", json!({"lease":id})).await;
    h.stop().await;
}

#[tokio::test]
async fn disconnected_pending_lease_keeps_its_original_grace_on_recovery() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    base(&mut c).await;
    let gate = h.backend.gate_starts();
    let mut agent = h.client().await;
    let job = agent.ok("pool.get", json!({"base":"Base"})).await;
    for _ in 0..100 {
        if !c
            .ok("pool.list", json!({}))
            .await
            .as_array()
            .unwrap()
            .is_empty()
        {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    drop(agent);
    let mut rows = Value::Null;
    for _ in 0..100 {
        rows = c.ok("pool.list", json!({})).await;
        if rows[0]["lease"]["expires_at"].is_string() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    let lease = &rows[0]["lease"];
    let id = serde_json::from_value(lease["id"].clone()).unwrap();
    let original =
        chrono::DateTime::parse_from_rfc3339(lease["expires_at"].as_str().unwrap()).unwrap();
    let recovered = jidr_daemon::leases::Leases::load(
        &h.paths.data.join("pool-leases.json"),
        &h.daemon.state().devices().await,
        Utc::now() + Duration::seconds(60),
    )
    .unwrap();
    assert_eq!(recovered.get(id).unwrap().expires_at.unwrap(), original);
    gate.add_permits(1);
    let done = c
        .ok("jobs.wait", json!({"job":job["job"],"timeout_s":8}))
        .await;
    assert_eq!(done["state"], "succeeded", "{done}");
    c.ok("pool.release", json!({"lease":id})).await;
    h.stop().await;
}

#[tokio::test]
async fn renewal_during_reap_is_rejected_instead_of_losing_the_device() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    base(&mut c).await;
    let leased = c.run("pool.get", json!({"base":"Base", "ttl_s":60})).await;
    let id = leased["lease"]["id"].clone();
    let device = leased["device"]["id"].as_str().unwrap().to_string();
    let gate = h.backend.gate_stops();
    let state = h.daemon.state().clone();
    let reaper = tokio::spawn(async move { state.reap(Utc::now() + Duration::seconds(61)).await });
    for _ in 0..100 {
        let details = c.ok("device.details", json!({"device":device})).await;
        if details["device"]["status"]["state"] == "stopping" {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    let error = c.err("pool.renew", json!({"lease":id,"ttl_s":3600})).await;
    assert_eq!(error["data"]["code"], "busy", "{error}");
    gate.add_permits(1);
    assert_eq!(reaper.await.unwrap().len(), 1);
    h.stop().await;
}

#[tokio::test]
async fn failed_lease_persistence_does_not_acknowledge_renewal() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    base(&mut c).await;
    let leased = c.run("pool.get", json!({"base":"Base", "ttl_s":60})).await;
    let id = leased["lease"]["id"].clone();
    let path = h.paths.data.join("pool-leases.json");
    let old = std::fs::read(&path).unwrap();
    std::fs::remove_file(&path).unwrap();
    std::fs::create_dir(&path).unwrap();
    let error = c.err("pool.renew", json!({"lease":id,"ttl_s":3600})).await;
    assert_eq!(error["data"]["code"], "unexpected", "{error}");
    assert_eq!(
        c.ok("pool.list", json!({})).await[0]["lease"]["expires_at"],
        leased["lease"]["expires_at"]
    );
    std::fs::remove_dir(&path).unwrap();
    std::fs::write(&path, old).unwrap();
    c.ok("pool.release", json!({"lease":id})).await;
    h.stop().await;
}

/// D4: the daemon stays up while leases exist, even with no client.
#[tokio::test]
async fn pool_leases_keep_the_daemon_alive() {
    let h = Harness::start().await;
    {
        let mut c = h.client().await;
        base(&mut c).await;
        let r = c
            .run("pool.get", json!({ "base": "Base", "ttl_s": 600 }))
            .await;
        c.ok("device.stop", json!({ "device": r["device"]["name"] }))
            .await;
    }
    for _ in 0..100 {
        if h.daemon.client_count() == 0 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
    }
    assert_eq!(h.daemon.client_count(), 0);
    assert_eq!(h.daemon.state().running_count(), 0);
    assert!(!h.daemon.is_idle(), "a lease keeps it up");
    h.daemon
        .state()
        .reap(Utc::now() + Duration::seconds(601))
        .await;
    assert!(h.daemon.is_idle());
    h.stop().await;
}

#[tokio::test]
async fn pool_refuses_stopped_sources_and_non_bases() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    c.ok("device.create", json!({ "name": "Off", "image": "35" }))
        .await;
    let job = c
        .ok("base.create", json!({ "from_device": "Off", "name": "B" }))
        .await;
    let done = c.ok("jobs.wait", json!({ "job": job["job"] })).await;
    assert_eq!(done["error"]["code"], "not_found", "{done}");
    let e = c.err("pool.release", json!({})).await;
    assert_eq!(e["data"]["code"], "usage");
    let job = c.ok("pool.get", json!({ "base": "Off" })).await;
    let done = c.ok("jobs.wait", json!({ "job": job["job"] })).await;
    assert!(
        done["error"]["message"]
            .as_str()
            .unwrap()
            .contains("not a base"),
        "{done}"
    );
    h.stop().await;
}

#[tokio::test]
async fn pool_refuses_a_writable_system_source() {
    use jidr_core::provider::DaemonContext;
    let h = Harness::start().await;
    let mut c = h.client().await;
    c.ok(
        "device.create",
        json!({ "name": "Rw", "image": "35", "root_mode": "adb" }),
    )
    .await;
    let st = h.daemon.state();
    let d = st.device("Rw").await.unwrap();
    st.update_device(
        d.id,
        Box::new(|d: &mut jidr_core::Device| d.root.writable_system = true),
    )
    .await
    .unwrap();
    c.run("device.start", json!({ "device": "Rw" })).await;
    let job = c
        .ok("base.create", json!({ "from_device": "Rw", "name": "B" }))
        .await;
    let done = c.ok("jobs.wait", json!({ "job": job["job"] })).await;
    assert_eq!(done["error"]["code"], "usage", "{done}");
    assert!(
        done["error"]["message"]
            .as_str()
            .unwrap()
            .contains("writable /system"),
        "{done}"
    );
    h.stop().await;
}
