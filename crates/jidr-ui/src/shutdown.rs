//! Orderly application exit. Devices remain daemon-owned until stopped; never
//! use process signals or delete device files here.
use jidr_client::Client;
use jidr_core::{JidrError, JidrPaths, JidrResult};
use serde_json::json;

/// Stops devices, verifies their AVD files are closed, then asks the daemon
/// to exit. A failed check keeps the application open for recovery.
pub async fn orderly_exit(paths: &JidrPaths) -> JidrResult<()> {
    let socket = paths.socket();
    if !socket.exists() {
        return check_closed(paths).await;
    }
    let client = Client::connect(&socket, "gui-quit").await?;
    let pid = client.daemon().pid;
    if let Err(error) = client.call("daemon.quit", json!({})).await {
        if error.code == jidr_core::ErrorCode::Usage && error.message.contains("unknown method") {
            return Err(JidrError::unexpected(crate::i18n::text(
                "The running background service is an older version; stop its devices before replacing it.",
                "当前后台是旧版本；请先通过旧版停止设备，再更新后台。",
            )));
        }
        return Err(error);
    }
    drop(client);
    let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(10);
    while tokio::time::Instant::now() < deadline {
        if !jidr_sdk::avd::process_alive(pid) {
            return Ok(());
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    Err(JidrError::unexpected(
        "Jidr background process did not exit",
    ))
}

async fn check_closed(paths: &JidrPaths) -> JidrResult<()> {
    let paths = paths.clone();
    tokio::task::spawn_blocking(move || jidr_sdk::migration::ensure_avds_quiescent(&paths))
        .await
        .map_err(|e| JidrError::unexpected(format!("device verification failed: {e}")))?
        .map_err(|e| JidrError::unexpected(format!("device is still in use: {e}")))
}
