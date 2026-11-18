//! `input.gamepad.*` (#23) through a daemon with the fake backend: the
//! command specs, a device that isn't running, and disconnect/get with no
//! controller forwarded. The HID reports and the forwarding loop are
//! unit-tested in `jidr_widgets::gamepad`; the guest side was checked by
//! hand on API 30 and 35 (see `docs/cli.md`, "Game controller").
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use jidr_client::Client;
use jidr_core::ErrorCode;
use jidr_daemon::testing::TestDaemon;
use serde_json::json;

#[tokio::test]
async fn gamepad_commands_check_the_device_and_report_no_controller() {
    let tmp = tempfile::tempdir().unwrap();
    let d = TestDaemon::start_with_providers(tmp.path(), vec![jidr_widgets::provider()])
        .await
        .unwrap();
    let c = Client::connect(&d.paths.socket(), "test").await.unwrap();

    let list = c.call("commands.list", json!({})).await.unwrap();
    let spec = |id: &str| {
        list.as_array()
            .unwrap()
            .iter()
            .find(|s| s["id"] == id)
            .cloned()
            .unwrap_or_else(|| panic!("{id} not listed"))
    };
    let connect = spec("input.gamepad.connect");
    assert_eq!(connect["longRunning"], true);
    assert_eq!(connect["destructive"], false);
    for key in ["device", "controller"] {
        assert!(
            connect["params"]["properties"].get(key).is_some(),
            "{key}: {connect}"
        );
    }
    for id in [
        "input.gamepad.list",
        "input.gamepad.disconnect",
        "input.gamepad.get",
    ] {
        assert_eq!(spec(id)["longRunning"], false, "{id}");
    }

    c.call("device.create", json!({ "name": "P", "image": "35" }))
        .await
        .unwrap();

    // Nothing is forwarded yet.
    let v = c
        .call("input.gamepad.get", json!({ "device": "P" }))
        .await
        .unwrap();
    assert_eq!(v, json!({ "connected": false }));
    let v = c
        .call("input.gamepad.disconnect", json!({ "device": "P" }))
        .await
        .unwrap();
    assert_eq!(v, json!({ "disconnected": false }));

    // The device isn't running: refused before any controller is opened.
    let e = c
        .run("input.gamepad.connect", json!({ "device": "P" }), |_| {})
        .await
        .unwrap_err();
    assert_eq!(e.code, ErrorCode::NotFound, "{}", e.message);
    assert!(e.message.contains("isn't running"), "{}", e.message);
    let v = c
        .call("input.gamepad.get", json!({ "device": "P" }))
        .await
        .unwrap();
    assert_eq!(
        v["connected"], false,
        "a failed connect leaves nothing behind"
    );

    // Unknown devices and params.
    let e = c
        .call("input.gamepad.get", json!({ "device": "nope" }))
        .await
        .unwrap_err();
    assert_eq!(e.code, ErrorCode::NotFound);
    let e = c
        .run(
            "input.gamepad.connect",
            json!({ "device": "P", "controller": "first" }),
            |_| {},
        )
        .await
        .unwrap_err();
    assert_eq!(e.code, ErrorCode::Usage, "{}", e.message);

    // Controllers are read on macOS only (gilrs needs libudev on Linux).
    let listed = c.call("input.gamepad.list", json!({})).await;
    if cfg!(target_os = "macos") {
        assert!(listed.unwrap()["controllers"].is_array());
    } else {
        assert_eq!(listed.unwrap_err().code, ErrorCode::Usage);
    }

    d.stop().await;
}
