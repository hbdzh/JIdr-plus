//! Quit coordination against a real daemon and a fake emulator backend.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use jidr_client::Client;
use jidr_daemon::testing::TestDaemon;
use serde_json::json;

#[tokio::test]
async fn quit_stops_all_running_devices_without_deleting_them() {
    let temp = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(temp.path()).await.unwrap();
    let client = Client::connect(&daemon.paths.socket(), "quit-test")
        .await
        .unwrap();
    client
        .call("settings.set", json!({"quick_boot":false}))
        .await
        .unwrap();
    for name in ["First", "Second"] {
        client
            .call("device.create", json!({"name":name,"image":"35"}))
            .await
            .unwrap();
        client
            .run("device.start", json!({"device":name}), |_| {})
            .await
            .unwrap();
    }
    client.call("daemon.quit", json!({})).await.unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(5), async {
        while daemon.paths.socket().exists() {
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap();
    let devices: Vec<jidr_core::Device> =
        serde_json::from_slice(&std::fs::read(daemon.paths.devices_file()).unwrap()).unwrap();
    assert_eq!(devices.len(), 2);
    assert!(daemon.backend.running().is_empty());
    drop(client);
    daemon.stop().await;
}

#[tokio::test]
async fn quit_refuses_active_job_and_succeeds_after_it_finishes() {
    let temp = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(temp.path()).await.unwrap();
    let client = Client::connect(&daemon.paths.socket(), "quit-busy-test")
        .await
        .unwrap();
    client
        .call("settings.set", json!({"quick_boot":false}))
        .await
        .unwrap();
    client
        .call("device.create", json!({"name":"Busy","image":"35"}))
        .await
        .unwrap();
    let gate = daemon.backend.gate_starts();
    let started = client
        .call("device.start", json!({"device":"Busy"}))
        .await
        .unwrap();
    let job = jidr_client::pending_job(&started).unwrap();
    assert_eq!(
        client
            .call("daemon.quit", json!({}))
            .await
            .unwrap_err()
            .code,
        jidr_core::ErrorCode::Busy
    );
    assert!(daemon.paths.socket().exists());
    gate.add_permits(1);
    let result = client
        .wait_job(job, Some(std::time::Duration::from_secs(5)))
        .await
        .unwrap();
    assert!(matches!(result.state, jidr_core::JobState::Succeeded));
    client.call("daemon.quit", json!({})).await.unwrap();
    assert!(daemon.backend.running().is_empty());
    drop(client);
    daemon.stop().await;
}

#[tokio::test]
async fn quit_does_not_stop_device_when_guest_sync_fails() {
    let temp = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(temp.path()).await.unwrap();
    let client = Client::connect(&daemon.paths.socket(), "quit-sync-test")
        .await
        .unwrap();
    client
        .call("settings.set", json!({"quick_boot":false}))
        .await
        .unwrap();
    client
        .call("device.create", json!({"name":"Sync","image":"35"}))
        .await
        .unwrap();
    client
        .run("device.start", json!({"device":"Sync"}), |_| {})
        .await
        .unwrap();
    let adb = daemon.studio.join("platform-tools/adb");
    std::fs::write(&adb, "#!/bin/sh\nexit 1\n").unwrap();
    assert!(client.call("daemon.quit", json!({})).await.is_err());
    assert_eq!(daemon.backend.running().len(), 1);
    assert!(daemon.paths.socket().exists());
    std::fs::write(&adb, "#!/bin/sh\nexit 0\n").unwrap();
    client.call("daemon.quit", json!({})).await.unwrap();
    assert!(daemon.backend.running().is_empty());
    drop(client);
    daemon.stop().await;
}

#[tokio::test]
async fn failed_graceful_stop_keeps_device_owned_and_allows_retry() {
    let temp = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(temp.path()).await.unwrap();
    let client = Client::connect(&daemon.paths.socket(), "quit-stop-test")
        .await
        .unwrap();
    client
        .call("settings.set", json!({"quick_boot":false}))
        .await
        .unwrap();
    client
        .call("device.create", json!({"name":"Retry","image":"35"}))
        .await
        .unwrap();
    client
        .run("device.start", json!({"device":"Retry"}), |_| {})
        .await
        .unwrap();
    daemon.backend.fail_next_quit();
    assert!(client.call("daemon.quit", json!({})).await.is_err());
    assert_eq!(daemon.backend.running().len(), 1);
    let devices: Vec<jidr_core::Device> = client.call_as("device.list", json!({})).await.unwrap();
    assert!(matches!(
        devices[0].status,
        jidr_core::DeviceStatus::Running
    ));
    client.call("daemon.quit", json!({})).await.unwrap();
    assert!(daemon.backend.running().is_empty());
    drop(client);
    daemon.stop().await;
}

#[tokio::test]
async fn legacy_daemon_is_not_forced_to_shutdown() {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let temp = tempfile::tempdir().unwrap();
    let paths = jidr_core::JidrPaths::under(temp.path());
    std::fs::create_dir_all(&paths.data).unwrap();
    let listener = tokio::net::UnixListener::bind(paths.socket()).unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (reader, mut writer) = stream.into_split();
        let mut reader = BufReader::new(reader);
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();
        let hello: serde_json::Value = serde_json::from_str(&line).unwrap();
        let response = json!({"jsonrpc":"2.0","id":hello["id"],"result":{"version":"0.3.1","protocol":"0.1","pid":999999}});
        writer
            .write_all(format!("{response}\n").as_bytes())
            .await
            .unwrap();
        line.clear();
        reader.read_line(&mut line).await.unwrap();
        let request: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(request["method"], "daemon.quit");
        let response = json!({"jsonrpc":"2.0","id":request["id"],"error":{"code":-32601,"message":"unknown method daemon.quit"}});
        writer
            .write_all(format!("{response}\n").as_bytes())
            .await
            .unwrap();
        line.clear();
        assert_eq!(reader.read_line(&mut line).await.unwrap(), 0);
    });
    let error = jidr_ui::shutdown::orderly_exit(&paths).await.unwrap_err();
    assert!(error.message.contains("older version") || error.message.contains("旧版本"));
    server.await.unwrap();
}
