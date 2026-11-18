//! The rooted on-device helper (see docs/on-device-helper.md) on a real emulator, Shell root
//! (`adb`): `root.helper.status` pushes and starts the build from
//! `cargo xtask helper`, `network.shaping.set` drops packets with netem, a
//! killed helper is started again with the kernel's shaping intact, and `0`
//! clears it. Bad DNS and restoration across cold boots are also checked.
//! API 30 without netem must return an unsupported error.
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
use jidr_core::{ConnectInfo, JidrPaths, JidrResult};
use jidr_daemon::{Daemon, DaemonConfig};
use jidr_helper::netem::NO_ROUTE;
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

/// How long a shaping call waits for a default route.
const NETWORK_WAIT: Duration = Duration::from_secs(120);

/// `network.shaping.*`, waiting while the guest has no default route:
/// Wi-Fi comes up some seconds after a boot, and can drop for a moment
/// (main's CI failed in a `get` after the helper restart, 2026-11).
async fn shaping_result(
    daemon: &Arc<Daemon>,
    ctx: &CallCtx,
    method: &str,
    params: Value,
) -> JidrResult<Value> {
    let (p, _) = daemon.registry().get(method).unwrap();
    let deadline = Instant::now() + NETWORK_WAIT;
    loop {
        match p.call(ctx, method, params.clone()).await {
            Err(e) if e.message.contains(NO_ROUTE) && Instant::now() < deadline => {
                println!("{method}: no network yet: {e}");
                tokio::time::sleep(Duration::from_secs(3)).await;
            }
            r => return r,
        }
    }
}

/// [`shaping_result`] that must succeed.
async fn shaping(daemon: &Arc<Daemon>, ctx: &CallCtx, method: &str, params: Value) -> Value {
    shaping_result(daemon, ctx, method, params)
        .await
        .unwrap_or_else(|e| panic!("{method}: {e}"))
}

/// The interface names in a shaping result.
fn names(v: &Value) -> Vec<String> {
    v["interfaces"]
        .as_array()
        .unwrap()
        .iter()
        .map(|i| i["name"].as_str().unwrap().to_string())
        .collect()
}

fn shell(info: &ConnectInfo, cmd: &str) -> String {
    let out = Command::new(&info.adb_path)
        .args(["-s", &info.adb_serial, "shell", cmd])
        .output()
        .unwrap();
    String::from_utf8_lossy(&out.stdout).into_owned()
}

/// How long the guest takes to look up a name nobody looked up before
/// (no resolver cache): `ping` resolves it first, through Android's
/// resolver, and `.invalid` never exists.
fn lookup_secs(info: &ConnectInfo) -> f64 {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let t = Instant::now();
    let out = shell(info, &format!("ping -c 1 -W 1 jidr-{nanos}.invalid 2>&1"));
    let secs = t.elapsed().as_secs_f64();
    println!("lookup: {secs:.1} s: {}", out.trim());
    secs
}

/// Packets the DNS band's netem (`1d1:`) sent and dropped, over `ifaces`,
/// from `tc -s qdisc show`:
///
/// ```text
/// qdisc netem 1d1: parent 1d:1 limit 1000 delay 3s
///  Sent 360 bytes 4 pkt (dropped 0, overlimits 0 requeues 0)
/// ```
fn dns_band(info: &ConnectInfo, ifaces: &[String]) -> (u64, u64) {
    let (mut sent, mut dropped) = (0, 0);
    for iface in ifaces {
        let out = shell(info, &format!("tc -s qdisc show dev {iface}"));
        let mut lines = out.lines();
        if lines.find(|l| l.starts_with("qdisc netem 1d1:")).is_none() {
            panic!("{iface} has no DNS band: {out}");
        }
        let stats: Vec<&str> = lines.next().unwrap_or("").split_whitespace().collect();
        assert_eq!(stats.first(), Some(&"Sent"), "{iface}: {out}");
        sent += stats[3].parse::<u64>().unwrap();
        dropped += stats[6].trim_end_matches(',').parse::<u64>().unwrap();
    }
    (sent, dropped)
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
    let get = shaping(
        &daemon,
        &ctx,
        "network.shaping.get",
        json!({ "device": name }),
    )
    .await;
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
        let e = shaping_result(
            &daemon,
            &ctx,
            "network.shaping.set",
            json!({ "device": name, "loss_pct": 50 }),
        )
        .await
        .unwrap_err();
        assert_eq!(e.code, jidr_core::ErrorCode::Usage, "{e}");
        assert!(e.message.contains("netem"), "{e}");
        let e = shaping_result(
            &daemon,
            &ctx,
            "network.shaping.set",
            json!({ "device": name, "dns": "fail" }),
        )
        .await
        .unwrap_err();
        assert_eq!(
            e.data.as_ref().unwrap()["helper_error"],
            "unsupported",
            "{e}"
        );
        assert!(state.device(&name).await.unwrap().network_shaping.is_off());
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
    // The interfaces the set shaped: those with a route at that moment.
    for iface in &names(&v) {
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
    let v = shaping(
        &daemon,
        &ctx,
        "network.shaping.get",
        json!({ "device": name }),
    )
    .await;
    assert_eq!(v["loss_pct"], 50.0, "{v}");

    // 5. 0 removes Jidr's netem.
    let v = shaping(
        &daemon,
        &ctx,
        "network.shaping.set",
        json!({ "device": name, "loss_pct": 0 }),
    )
    .await;
    assert_eq!(v["loss_pct"], 0.0, "{v}");
    for iface in ifaces.iter().chain(&names(&v)) {
        let q = shell(&info, &format!("tc qdisc show dev {iface}"));
        assert!(!q.contains("netem"), "{iface}: {q}");
    }

    // 6. Slow DNS. A lookup before it is only printed: on the CI emulator
    // a fresh name can take the resolver's whole 5 s timeout (CI,
    // 2026-11-14), so it is no baseline. The proof is that DNS packets go
    // through the delaying band, and that a lookup takes the delay.
    lookup_secs(&info);
    let v = shaping(
        &daemon,
        &ctx,
        "network.shaping.set",
        json!({ "device": name, "dns": "slow", "dns_delay_ms": 3000 }),
    )
    .await;
    assert_eq!(
        (&v["dns"], &v["dns_delay_ms"]),
        (&json!("slow"), &json!(3000)),
        "{v}"
    );
    let shaped = names(&v);
    for iface in &shaped {
        let q = shell(&info, &format!("tc qdisc show dev {iface}"));
        assert!(
            q.contains("prio 1d:") && q.contains("delay 3"),
            "{iface}: {q}"
        );
        // Port 53 (0x35) and 853 (0x355), each to the DNS band.
        let f = shell(&info, &format!("tc filter show dev {iface} parent 1d:"));
        assert!(
            f.contains("00000035/0000ffff")
                && f.contains("00000355/0000ffff")
                && f.contains("flowid 1d:1"),
            "{iface}: {f}"
        );
    }
    let (sent, _) = dns_band(&info, &shaped);
    let slow = lookup_secs(&info);
    let (sent_after, _) = dns_band(&info, &shaped);
    assert!(
        sent_after > sent,
        "the lookup's queries didn't go through the DNS band ({sent} → {sent_after} packets)"
    );
    assert!(slow >= 2.9, "slow DNS answered in {slow:.1} s, under 3 s");

    // 7. Failing DNS: every query is dropped in the DNS band, and the
    // lookup only ends when the resolver gives up.
    let v = shaping(
        &daemon,
        &ctx,
        "network.shaping.set",
        json!({ "device": name, "dns": "fail" }),
    )
    .await;
    let shaped = names(&v);
    let (_, dropped) = dns_band(&info, &shaped);
    let fail = lookup_secs(&info);
    let (sent, dropped_after) = dns_band(&info, &shaped);
    assert!(
        dropped_after > dropped,
        "the lookup's queries weren't dropped ({dropped} → {dropped_after})"
    );
    assert_eq!(sent, 0, "failing DNS let {sent} packets through");
    assert!(fail >= 4.0, "failing DNS gave up after {fail:.1} s");

    // 8. Loss and slow DNS are stored and come back after a cold boot.
    shaping(
        &daemon,
        &ctx,
        "network.shaping.set",
        json!({ "device": name, "loss_pct": 20, "dns": "slow", "dns_delay_ms": 1500 }),
    )
    .await;
    call(&daemon, &ctx, "device.stop", json!({ "device": name })).await;
    call(
        &daemon,
        &ctx,
        "device.start",
        json!({ "device": name, "cold_boot": true }),
    )
    .await;
    let info = state
        .connect_info(state.device(&name).await.unwrap().id)
        .await
        .unwrap();
    let v = shaping(
        &daemon,
        &ctx,
        "network.shaping.get",
        json!({ "device": name }),
    )
    .await;
    println!("after a cold boot: {v}");
    // The boot hook shaped every interface that had a route once the list
    // settled; one that comes up later only gets it at the next set. Every
    // shaped interface has exactly the stored values.
    let ifs = v["interfaces"].as_array().unwrap();
    let shaped: Vec<&Value> = ifs.iter().filter(|i| i["dns"] != "normal").collect();
    assert!(
        !shaped.is_empty(),
        "nothing re-applied after a cold boot: {v}"
    );
    for i in shaped {
        assert_eq!(
            (&i["loss_pct"], &i["dns"], &i["dns_delay_ms"]),
            (&json!(20.0), &json!("slow"), &json!(1500)),
            "{v}"
        );
    }

    // 9. Cleared: the kernel's own qdiscs, and nothing stored.
    let v = shaping(
        &daemon,
        &ctx,
        "network.shaping.set",
        json!({ "device": name, "loss_pct": 0, "dns": "normal" }),
    )
    .await;
    assert_eq!(
        (&v["loss_pct"], &v["dns"]),
        (&json!(0.0), &json!("normal")),
        "{v}"
    );
    for iface in ifaces.iter().chain(&names(&v)) {
        let q = shell(&info, &format!("tc qdisc show dev {iface}"));
        assert!(
            !q.contains("netem") && !q.contains("prio 1d:"),
            "{iface}: {q}"
        );
    }
    assert!(
        state.device(&name).await.unwrap().network_shaping.is_off(),
        "clearing forgets the stored shaping"
    );

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
