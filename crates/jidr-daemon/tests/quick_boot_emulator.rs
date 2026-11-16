//! Real-emulator regression for explicit quick-boot saves on rooted devices.
#![cfg(feature = "emulator")]
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod common;
use common::emulator::{Emu, name};
use serde_json::{Value, json};
use std::{
    process::Command,
    time::{Duration, Instant},
};

fn adb(info: &Value, args: &[&str]) -> String {
    let out = Command::new(info["adb_path"].as_str().unwrap())
        .args(["-s", info["adb_serial"].as_str().unwrap()])
        .args(args)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "adb failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}
fn top(info: &Value) -> String {
    adb(info, &["shell", "dumpsys", "activity", "activities"])
        .lines()
        .find(|l| l.contains("topResumedActivity") || l.contains("mResumedActivity"))
        .and_then(|l| l.split_whitespace().find(|w| w.contains('/')))
        .unwrap_or_default()
        .trim_end_matches('}')
        .to_string()
}
#[tokio::test(flavor = "multi_thread")]
async fn rooted_quick_boot_repeatedly_saves_and_restores() {
    let h = Emu::start_with_root(true).await;
    let mut c = h.client().await;
    let dev = name("quickroot");
    let d = c.ok("device.create", json!({"name":dev,"image":h.image.package(),"profile":"phone-6.1-fhd","root_mode":"adb"})).await;
    let avd = d["avd"].as_str().unwrap().to_owned();
    h.guard(&avd);
    let dir = h.paths.avd_home().join(format!("{avd}.avd"));
    c.run_long("device.start", json!({"device":dev})).await;
    for cycle in 0..2 {
        let info = c.ok("device.connect_info", json!({"device":dev})).await;
        assert_eq!(adb(&info, &["shell", "id", "-u"]), "0");
        let mut before = String::new();
        for _ in 0..10 {
            adb(
                &info,
                &[
                    "shell",
                    "am",
                    "start",
                    "-W",
                    "-n",
                    "com.android.settings/.Settings",
                ],
            );
            tokio::time::sleep(Duration::from_secs(2)).await;
            before = top(&info);
            if before.contains("settings") {
                break;
            }
        }
        assert!(before.contains("settings"), "{before}");
        let t = Instant::now();
        c.ok("device.stop", json!({"device":dev})).await;
        println!("cycle {cycle} stop {:.2}s", t.elapsed().as_secs_f64());
        let ram = std::fs::metadata(dir.join("snapshots/default_boot/ram.bin"))
            .unwrap()
            .len();
        assert!(ram > 0);
        println!("cycle {cycle} snapshot {ram} bytes");
        let t = Instant::now();
        c.run_long("device.start", json!({"device":dev})).await;
        println!("cycle {cycle} start {:.2}s", t.elapsed().as_secs_f64());
        let info = c.ok("device.connect_info", json!({"device":dev})).await;
        assert_eq!(adb(&info, &["shell", "id", "-u"]), "0");
        assert_eq!(top(&info), before);
        let mut logs: Vec<_> = std::fs::read_dir(h.paths.device_logs(&avd))
            .unwrap()
            .flatten()
            .map(|e| e.path())
            .collect();
        logs.sort();
        let log = std::fs::read_to_string(logs.last().unwrap()).unwrap();
        assert!(
            log.contains("Successfully loaded snapshot 'default_boot'"),
            "{log}"
        );
    }
    c.ok("device.stop", json!({"device":dev})).await;
    c.ok("device.delete", json!({"device":dev})).await;
    h.stop().await;
}
