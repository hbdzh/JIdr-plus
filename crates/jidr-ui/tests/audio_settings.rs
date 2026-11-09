//! Audio settings survive create, edit, and daemon restart.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use jidr_client::Client;
use jidr_daemon::testing::TestDaemon;
use serde_json::json;

#[tokio::test]
async fn audio_setting_is_persisted_per_device() {
    let tmp = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(tmp.path()).await.unwrap();
    let generated = jidr_daemon::protocol_doc::render(&daemon.daemon.registry().list());
    let protocol = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../docs/control-protocol.md"
    ))
    .unwrap();
    for text in [
        "| `audio` | boolean |  | Play Android audio on the host; defaults to the selected profile. |",
        "| `audio` | boolean |  | Play Android audio on the host on the next device start. |",
    ] {
        assert!(generated.contains(text));
        assert!(protocol.contains(text));
    }
    let client = Client::connect(&daemon.paths.socket(), "audio-test")
        .await
        .unwrap();
    let created = client
        .call(
            "device.create",
            json!({"name":"Audio test", "image":"35", "audio":false}),
        )
        .await
        .unwrap();
    assert_eq!(created["launch"]["audio"], false);
    client
        .run("device.start", json!({"device":"Audio test"}), |_| {})
        .await
        .unwrap();
    assert!(!daemon.backend.launches().last().unwrap().1.audio);
    let edited = client
        .call("device.edit", json!({"device":"Audio test", "audio":true}))
        .await
        .unwrap();
    assert_eq!(edited["launch"]["audio"], true);
    client
        .run("device.stop", json!({"device":"Audio test"}), |_| {})
        .await
        .unwrap();
    drop(client);
    daemon.stop().await;
    let daemon = TestDaemon::start(tmp.path()).await.unwrap();
    let client = Client::connect(&daemon.paths.socket(), "audio-test")
        .await
        .unwrap();
    let details = client
        .call("device.details", json!({"device":"Audio test"}))
        .await
        .unwrap();
    assert_eq!(details["device"]["launch"]["audio"], true);
    client
        .run("device.start", json!({"device":"Audio test"}), |_| {})
        .await
        .unwrap();
    assert!(daemon.backend.launches().last().unwrap().1.audio);
    drop(client);
    daemon.stop().await;
}
