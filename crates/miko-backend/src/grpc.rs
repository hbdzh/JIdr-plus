//! Authenticated gRPC clients for a running emulator.

use std::time::Duration;

use miko_core::{ErrorCode, MikoError, MikoResult, ResultExt};
use miko_proto::{BearerToken, Controller, Snapshots};
use tonic::transport::Endpoint;

use crate::InstanceInfo;

/// Connects to `127.0.0.1:<port>` with the bearer token.
pub async fn connect_port(port: u16, token: &str) -> MikoResult<(Controller, Snapshots)> {
    let token = BearerToken::new(token).ctx(ErrorCode::Unexpected, "invalid gRPC token")?;
    let channel = Endpoint::from_shared(format!("http://127.0.0.1:{port}"))
        .ctx(ErrorCode::Unexpected, "gRPC endpoint")?
        .connect_timeout(Duration::from_secs(5))
        .tcp_nodelay(true)
        .connect()
        .await
        .map_err(|e| MikoError::sdk(format!("cannot reach emulator gRPC on port {port}: {e}")))?;
    Ok(miko_proto::clients(channel, token))
}

pub async fn connect(instance: &InstanceInfo) -> MikoResult<(Controller, Snapshots)> {
    connect_port(instance.grpc_port, &instance.grpc_token).await
}

/// Maps a gRPC status to a Miko error.
pub fn status_error(what: &str, s: tonic::Status) -> MikoError {
    let code = match s.code() {
        tonic::Code::NotFound => ErrorCode::NotFound,
        tonic::Code::InvalidArgument => ErrorCode::Usage,
        tonic::Code::Unavailable | tonic::Code::DeadlineExceeded => ErrorCode::Sdk,
        _ => ErrorCode::Sdk,
    };
    MikoError::new(code, format!("{what}: {}", s.message()))
        .with_data(serde_json::json!({"grpc_code": format!("{:?}", s.code())}))
}
