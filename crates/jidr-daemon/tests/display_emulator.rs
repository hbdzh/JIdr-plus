//! Display changes on an isolated real emulator and its guest data.
#![cfg(feature = "emulator")]
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod common;

use common::emulator::{Emu, name};
use serde_json::{Value, json};
use std::process::Command;

fn adb(info: &Value, args: &[&str]) -> String {
    let output = Command::new(info["adb_path"].as_str().unwrap())
        .args(["-s", info["adb_serial"].as_str().unwrap()])
        .args(args)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).to_string()
}

#[tokio::test(flavor = "multi_thread")]
async fn display_change_preserves_guest_file_and_snapshot_files() {
    let h = Emu::start().await;
    let mut c = h.client().await;
    let dev = name("display");
    let d = h.create(&mut c, &dev, "agent-lean").await;
    let original = c.ok("device.details", json!({"device":dev})).await;
    let width: u32 = original["config"]["hw.lcd.width"]
        .as_str()
        .unwrap()
        .parse()
        .unwrap();
    let height: u32 = original["config"]["hw.lcd.height"]
        .as_str()
        .unwrap()
        .parse()
        .unwrap();
    let density: u32 = original["config"]["hw.lcd.density"]
        .as_str()
        .unwrap()
        .parse()
        .unwrap();
    let avd = h
        .paths
        .avd_home()
        .join(format!("{}.avd", d["avd"].as_str().unwrap()));
    c.run_long("device.start", json!({"device":dev})).await;
    let info = c.ok("device.connect_info", json!({"device":dev})).await;
    adb(
        &info,
        &["shell", "touch", "/data/local/tmp/jidr_display_test_marker"],
    );
    adb(&info, &["shell", "sync"]);
    let saved = adb(
        &info,
        &["emu", "avd", "snapshot", "save", "display_safety_test"],
    );
    assert!(!saved.contains("KO"), "{saved}");
    let quick = adb(&info, &["emu", "avd", "snapshot", "save", "default_boot"]);
    assert!(!quick.contains("KO"), "{quick}");
    c.ok("device.stop", json!({"device":dev})).await;
    let named = avd.join("snapshots/display_safety_test/snapshot.pb");
    let old_named = std::fs::read(&named).unwrap();
    assert!(
        avd.join("snapshots/default_boot/ram.bin")
            .metadata()
            .unwrap()
            .len()
            > 0
    );
    c.ok(
        "device.edit",
        json!({"device":dev,"width":640,"height":1280,"density":280}),
    )
    .await;
    let backup = std::fs::read_dir(avd.join("jidr/display-backups"))
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path();
    assert!(
        backup
            .join("default_boot/ram.bin")
            .metadata()
            .unwrap()
            .len()
            > 0
    );
    assert_eq!(std::fs::read(&named).unwrap(), old_named);
    c.run_long("device.start", json!({"device":dev})).await;
    let info = c.ok("device.connect_info", json!({"device":dev})).await;
    let size = adb(&info, &["shell", "wm", "size"]);
    let current_density = adb(&info, &["shell", "wm", "density"]);
    assert!(size.contains("640x1280"), "{size}");
    assert!(current_density.contains("280"), "{current_density}");
    assert!(
        adb(
            &info,
            &["shell", "ls", "/data/local/tmp/jidr_display_test_marker"]
        )
        .contains("jidr_display_test_marker")
    );
    c.ok("device.stop", json!({"device":dev})).await;
    assert_eq!(std::fs::read(&named).unwrap(), old_named);
    c.ok(
        "device.edit",
        json!({"device":dev,"width":width,"height":height,"density":density}),
    )
    .await;
    c.run_long("device.start", json!({"device":dev})).await;
    let info = c.ok("device.connect_info", json!({"device":dev})).await;
    let restored = adb(
        &info,
        &["emu", "avd", "snapshot", "load", "display_safety_test"],
    );
    assert!(!restored.contains("KO"), "{restored}");
    adb(&info, &["wait-for-device"]);
    assert!(
        adb(
            &info,
            &["shell", "ls", "/data/local/tmp/jidr_display_test_marker"]
        )
        .contains("jidr_display_test_marker")
    );
    c.ok("device.stop", json!({"device":dev})).await;
    c.ok("device.delete", json!({"device":dev})).await;
    h.stop().await;
}
