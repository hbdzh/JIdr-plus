//! Device-scoped app listing using the fake backend.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use jidr_client::Client;
use jidr_daemon::testing::TestDaemon;
use serde_json::json;

#[tokio::test]
async fn listing_requires_the_requested_device_to_be_running() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start_with_providers(dir.path(), vec![jidr_widgets::provider()])
        .await
        .unwrap();
    let generated = jidr_daemon::protocol_doc::render(&daemon.daemon.registry().list());
    let section = generated
        .split("#### `app.list`\n")
        .nth(1)
        .unwrap()
        .split("\n#### ")
        .next()
        .unwrap();
    assert!(
        include_str!("../../../docs/control-protocol.md").contains(section.trim()),
        "{section}"
    );
    let client = Client::connect(&daemon.paths.socket(), "test")
        .await
        .unwrap();
    let first = client
        .call("device.create", json!({"name":"First", "image":"35"}))
        .await
        .unwrap();
    client
        .call("device.create", json!({"name":"Second", "image":"35"}))
        .await
        .unwrap();
    client
        .run("device.start", json!({"device":"First"}), |_| {})
        .await
        .unwrap();
    let result = client
        .call("app.list", json!({"device":"First"}))
        .await
        .unwrap();
    assert_eq!(result["device"], first["id"]);
    assert_eq!(result["apps"], json!([]));
    assert!(
        client
            .call("app.list", json!({"device":"Second"}))
            .await
            .is_err()
    );
    client
        .call("device.stop", json!({"device":"First"}))
        .await
        .unwrap();
    drop(client);
    daemon.stop().await;
}
