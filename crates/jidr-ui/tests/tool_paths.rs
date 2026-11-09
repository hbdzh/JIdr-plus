//! Configured Android SDK selection reaches the daemon without modifying it.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
use jidr_client::Client;
use jidr_core::storage_lease::StorageLease;
use jidr_core::tool_paths::ToolPaths;
use jidr_daemon::testing::TestDaemon;
use serde_json::json;

#[tokio::test]
async fn daemon_uses_selected_sdk_and_does_not_fall_back_when_missing() {
    let temp = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(temp.path()).await.unwrap();
    let sdk = temp.path().join("custom-sdk");
    std::fs::create_dir_all(sdk.join("emulator")).unwrap();
    std::fs::create_dir_all(sdk.join("platform-tools")).unwrap();
    std::fs::write(sdk.join("emulator/emulator"), b"custom emulator").unwrap();
    std::fs::write(sdk.join("platform-tools/adb"), b"custom adb").unwrap();
    ToolPaths {
        android_sdk: Some(sdk.clone()),
        jdk_home: None,
    }
    .save(&daemon.paths)
    .unwrap();
    let client = Client::connect(&daemon.paths.socket(), "sdk-selection-test")
        .await
        .unwrap();
    let status = client.call("sdk.status", json!({})).await.unwrap();
    assert_eq!(status["tools_sdk"], sdk.to_str().unwrap());
    std::fs::remove_file(sdk.join("platform-tools/adb")).unwrap();
    let status = client.call("sdk.status", json!({})).await.unwrap();
    assert!(status["tools_sdk"].is_null());
    assert!(
        client
            .run("image.install", json!({"image":"35"}), |_| {})
            .await
            .is_err()
    );
    assert_eq!(
        std::fs::read(sdk.join("emulator/emulator")).unwrap(),
        b"custom emulator"
    );
    drop(client);
    daemon.stop().await;
}

#[tokio::test]
async fn running_daemon_excludes_migration_until_shutdown() {
    let temp = tempfile::tempdir().unwrap();
    let daemon = TestDaemon::start(temp.path()).await.unwrap();
    let data = daemon.paths.data.clone();
    assert!(StorageLease::acquire(&data).is_err());
    daemon.stop().await;
    let lease = tokio::time::timeout(std::time::Duration::from_secs(5), async {
        loop {
            if let Ok(lease) = StorageLease::acquire(&data) {
                break lease;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("daemon tasks must release the lease after shutdown");
    assert!(lease.covers(&data).unwrap());
    let config = jidr_daemon::DaemonConfig::new(jidr_core::JidrPaths::under(temp.path().join("j")));
    let backend = std::sync::Arc::new(jidr_backend::fake::FakeBackend::new());
    let blocked = jidr_daemon::Daemon::builder(config, backend)
        .build()
        .unwrap();
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(2),
        blocked.serve(std::future::pending()),
    )
    .await
    .expect("daemon must fail promptly while migration holds the lease");
    assert!(result.is_err());
    assert!(!data.join("daemon.sock").exists());
}

#[cfg(unix)]
#[tokio::test]
async fn legacy_socket_barrier_blocks_daemon_and_client_autostart() {
    let temp = tempfile::tempdir().unwrap();
    let paths = jidr_core::JidrPaths::under(temp.path());
    std::fs::create_dir_all(&paths.data).unwrap();
    let barrier = jidr_sdk::legacy_barrier::LegacySocketBarrier::acquire(&paths.socket()).unwrap();
    assert!(jidr_daemon::server::bind(&paths.socket()).is_err());
    let options = jidr_client::SpawnOptions {
        program: Some(temp.path().join("must-not-run")),
        ..Default::default()
    };
    let error = Client::connect_or_spawn(&paths, "barrier-test", &options)
        .await
        .unwrap_err();
    assert_eq!(error.code, jidr_core::ErrorCode::Busy);
    assert!(barrier.is_intact());
    drop(barrier);
    assert!(!paths.socket().exists());
}
