//! The rooted on-device helper (see docs/on-device-helper.md) on a real emulator, Shell root
//! (`adb`): `root.helper.status` pushes and starts the build from
//! `cargo xtask helper`, `network.shaping.set` drops packets with netem, a
//! killed helper is started again with the kernel's shaping intact, and `0`
//! clears it. On API 30, whose kernel has no netem, it checks the
//! "unsupported" answer instead (see docs/on-device-helper.md).
//!
//! Build the helper for the image's CPU first: `cargo xtask helper` (CI runs
//! `--arch x86_64`). The image comes from `JIDR_TEST_IMAGE` (default: API 31
//! `google_apis` for the host ABI) in `JIDR_TEST_SDK` (default: Android
//! Studio's SDK, opened read-only). The AVD lives in a temp Jidr home.
#![cfg(feature = "emulator")]
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::path::PathBuf;
use std::process::Command;
use std::sync::Arc;
use std::time::{Duration, Instant};

use jidr_backend::AospBackend;
use jidr_backend::testing::{AvdGuard, kill_orphans, unique_avd};
use jidr_core::provider::{CallCtx, DaemonContext};
use jidr_core::{ConnectInfo, JidrPaths};
use jidr_daemon::{Daemon, DaemonConfig};
use serde_json::{Value, json};

fn test_sdk() -> PathBuf {
    std::env::var_os("JIDR_TEST_SDK")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Library/Android/sdk")))
        .unwrap()
}

fn test_image() -> String {
    std::env::var("JIDR_TEST_IMAGE").unwrap_or_else(|_| {
        let abi = if cfg!(target_arch = "aarch64") {
            "arm64-v8a"
        } else {
            "x86_64"
        };
        format!("system-images;android-31;google_apis;{abi}")
    })
}

/// The image's API level (`JIDR_TEST_API`, default 31 like the image).
fn test_api() -> u32 {
    std::env::var("JIDR_TEST_API")
        .ok()
        .and_then(|a| a.parse().ok())
        .unwrap_or(31)
}

async fn call(daemon: &Arc<Daemon>, ctx: &CallCtx, method: &str, params: Value) -> Value {
    let (p, _) = daemon.registry().get(method).unwrap();
    p.call(ctx, method, params)
        .await
        .unwrap_or_else(|e| panic!("{method}: {e}"))
}

fn shell(info: &ConnectInfo, cmd: &str) -> String {
    let out = Command::new(&info.adb_path)
        .args(["-s", &info.adb_serial, "shell", cmd])
        .output()
        .unwrap();
    String::from_utf8_lossy(&out.stdout).into_owned()
}

#[tokio::test(flavor = "multi_thread")]
async fn helper_starts_as_root_and_drops_packets() {
    let tmp = tempfile::tempdir().unwrap();
    let daemon = Daemon::builder(
        DaemonConfig {
            paths: JidrPaths::under(tmp.path()),
            studio_sdk: Some(test_sdk()),
            idle_timeout: None,
            sdk_repo: None,
        },
        Arc::new(AospBackend::new()),
    )
    .provider(jidr_root::provider())
    .provider(jidr_widgets::provider())
    .build()
    .unwrap();
    let ctx = CallCtx::new(daemon.state().clone());
    let state = daemon.state().clone();
    kill_orphans("helper-e2e");
    let name = unique_avd("helper-e2e");
    call(
        &daemon,
        &ctx,
        "device.create",
        json!({ "name": name, "image": test_image(), "profile": "small-phone-5", "root_mode": "adb" }),
    )
    .await;
    let _guard = AvdGuard::new(&state.device(&name).await.unwrap().avd);
    let t = Instant::now();
    call(&daemon, &ctx, "device.start", json!({ "device": name })).await;
    println!("cold boot: {:.1} s", t.elapsed().as_secs_f64());
    let info = state
        .connect_info(state.device(&name).await.unwrap().id)
        .await
        .unwrap();

    // 1. Started as root, in the root shell's SELinux domain.
    let t = Instant::now();
    let v = call(
        &daemon,
        &ctx,
        "root.helper.status",
        json!({ "device": name }),
    )
    .await;
    println!(
        "first helper start: {:.1} s: {v}",
        t.elapsed().as_secs_f64()
    );
    assert_eq!(v["helper"]["uid"], 0, "{v}");
    assert_eq!(v["helper"]["protocol"], jidr_helper::rpc::PROTOCOL);
    let pid = v["helper"]["pid"].as_u64().unwrap();
    assert!(
        shell(&info, "ps -A -o PID,ARGS").contains(&format!("{pid} ")),
        "helper pid {pid} isn't running"
    );

    // 2. Wait for a network with a default route (Wi-Fi or mobile data).
    let deadline = Instant::now() + Duration::from_secs(120);
    let get = loop {
        let (p, _) = daemon.registry().get("network.shaping.get").unwrap();
        match p
            .call(&ctx, "network.shaping.get", json!({ "device": name }))
            .await
        {
            Ok(v) => break v,
            Err(e) if Instant::now() < deadline => {
                println!("no network yet: {e}");
                tokio::time::sleep(Duration::from_secs(3)).await;
            }
            Err(e) => panic!("network.shaping.get: {e}"),
        }
    };
    println!("before: {get}");
    let ifaces: Vec<String> = get["interfaces"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["name"].as_str().unwrap().to_string())
        .collect();
    assert!(!ifaces.is_empty());
    assert_eq!(get["loss_pct"], 0.0, "{get}");

    // API 30's emulator kernel has no netem (see docs/on-device-helper.md): the helper says so as a
    // usage error instead of failing, and changes nothing.
    if test_api() < 31 {
        let (p, _) = daemon.registry().get("network.shaping.set").unwrap();
        let e = p
            .call(
                &ctx,
                "network.shaping.set",
                json!({ "device": name, "loss_pct": 50 }),
            )
            .await
            .unwrap_err();
        assert_eq!(e.code, jidr_core::ErrorCode::Usage, "{e}");
        assert!(e.message.contains("netem"), "{e}");
        call(&daemon, &ctx, "device.stop", json!({ "device": name })).await;
        call(&daemon, &ctx, "device.delete", json!({ "device": name })).await;
        return;
    }

    // Measure actual egress on the Android emulator's Wi-Fi gateway, not
    // just `tc` configuration. The adb connection itself remains available.
    if ifaces.iter().any(|name| name == "wlan0") {
        let adb = jidr_adb::Adb::new(&info.adb_path).device(&info.adb_serial);
        let ping = "ping -I wlan0 -c 3 -W 2 10.0.2.2";
        let (before, out) = adb.shell_status(ping).await.unwrap();
        assert_eq!(before, 0, "Wi-Fi baseline gateway ping: {out}");
        call(
            &daemon,
            &ctx,
            "network.shaping.set",
            json!({"device": name, "loss_pct": 100}),
        )
        .await;
        let (blocked, out) = adb.shell_status(ping).await.unwrap();
        assert_ne!(blocked, 0, "100% loss must drop the gateway ping: {out}");
        call(
            &daemon,
            &ctx,
            "network.shaping.set",
            json!({"device": name, "loss_pct": 0}),
        )
        .await;
        let (after, out) = adb.shell_status(ping).await.unwrap();
        assert_eq!(after, 0, "gateway ping after clearing loss: {out}");
    }

    // 3. 50% loss: the kernel shows netem on every shaped interface.
    let v = call(
        &daemon,
        &ctx,
        "network.shaping.set",
        json!({ "device": name, "loss_pct": 50 }),
    )
    .await;
    assert_eq!(v["loss_pct"], 50.0, "{v}");
    for iface in &ifaces {
        let q = shell(&info, &format!("tc qdisc show dev {iface}"));
        assert!(
            q.contains("netem") && q.contains("loss 50%"),
            "{iface}: {q}"
        );
    }

    // 4. A killed helper is started again; the shaping is kernel state and stays.
    shell(&info, "pkill -x jidr-helper");
    let v = call(
        &daemon,
        &ctx,
        "root.helper.status",
        json!({ "device": name }),
    )
    .await;
    assert_ne!(v["helper"]["pid"].as_u64().unwrap(), pid, "{v}");
    let v = call(
        &daemon,
        &ctx,
        "network.shaping.get",
        json!({ "device": name }),
    )
    .await;
    assert_eq!(v["loss_pct"], 50.0, "{v}");

    // 5. 0 removes Jidr's netem.
    let v = call(
        &daemon,
        &ctx,
        "network.shaping.set",
        json!({ "device": name, "loss_pct": 0 }),
    )
    .await;
    assert_eq!(v["loss_pct"], 0.0, "{v}");
    for iface in &ifaces {
        let q = shell(&info, &format!("tc qdisc show dev {iface}"));
        assert!(!q.contains("netem"), "{iface}: {q}");
    }

    call(&daemon, &ctx, "device.stop", json!({ "device": name })).await;
    call(&daemon, &ctx, "device.delete", json!({ "device": name })).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn helper_operates_on_a_real_magisk_device() {
    let tmp = tempfile::tempdir().unwrap();
    let daemon = Daemon::builder(
        DaemonConfig {
            paths: JidrPaths::under(tmp.path()),
            studio_sdk: Some(test_sdk()),
            idle_timeout: None,
            sdk_repo: None,
        },
        Arc::new(AospBackend::new()),
    )
    .provider(jidr_root::provider())
    .provider(jidr_widgets::provider())
    .build()
    .unwrap();
    let ctx = CallCtx::new(daemon.state().clone());
    let state = daemon.state().clone();
    kill_orphans("helper-magisk-e2e");
    let name = unique_avd("helper-magisk-e2e");
    call(
        &daemon,
        &ctx,
        "device.create",
        json!({"name":name,"image":test_image(),"profile":"small-phone-5","root_mode":"none"}),
    )
    .await;
    let _guard = AvdGuard::new(&state.device(&name).await.unwrap().avd);
    let mut params = json!({"device":name,"mode":"magisk"});
    if let Some(apk) = std::env::var_os("JIDR_TEST_MAGISK") {
        let entry = call(
            &daemon,
            &ctx,
            "cache.import",
            json!({"path":apk.to_string_lossy()}),
        )
        .await;
        params["magisk_sha256"] = entry["sha256"].clone();
    }
    let rooted = call(&daemon, &ctx, "root.set", params).await;
    assert_eq!(rooted["verification"]["uid"], 0);
    let helper = call(&daemon, &ctx, "root.helper.status", json!({"device":name})).await;
    assert_eq!(helper["root_mode"], "magisk");
    assert_eq!(helper["helper"]["uid"], 0);
    let deadline = Instant::now() + Duration::from_secs(120);
    loop {
        let (p, _) = daemon.registry().get("network.shaping.get").unwrap();
        match p
            .call(&ctx, "network.shaping.get", json!({"device":name}))
            .await
        {
            Ok(_) => break,
            Err(_) if Instant::now() < deadline => tokio::time::sleep(Duration::from_secs(3)).await,
            Err(e) => panic!("network.shaping.get: {e}"),
        }
    }
    if test_api() >= 31 {
        let set = call(
            &daemon,
            &ctx,
            "network.shaping.set",
            json!({"device":name,"loss_pct":20}),
        )
        .await;
        assert_eq!(set["loss_pct"], 20.0);
        let clear = call(
            &daemon,
            &ctx,
            "network.shaping.set",
            json!({"device":name,"loss_pct":0}),
        )
        .await;
        assert_eq!(clear["loss_pct"], 0.0);
    }
    call(&daemon, &ctx, "device.stop", json!({"device":name})).await;
    call(&daemon, &ctx, "device.delete", json!({"device":name})).await;
}
