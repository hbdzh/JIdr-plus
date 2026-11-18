//! Game controller passthrough (#23): a controller on this machine drives
//! the device. `input.gamepad.connect` is a job that reads the controller
//! ([`host`]) and replays it through a virtual USB controller in the guest
//! ([`hid`]), made by AOSP's `hid` command over `adb shell`. No root: the
//! `shell` user may open `/dev/uhid`. `input.gamepad.disconnect` ends it.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use jidr_core::cancel::Cancel;
use jidr_core::provider::{CallCtx, CommandSpec, DeviceParams, NoParams, parse_params};
use jidr_core::{JidrError, JidrResult};
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc;

use crate::device::target;
use crate::running::Running;

pub mod hid;
pub mod host;

use hid::{Pad, PadEvent};

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ConnectParams {
    /// Device name or id.
    pub device: String,
    /// Which controller: an `id` from `input.gamepad.list`. Default: the
    /// first one connected.
    #[serde(default)]
    pub controller: Option<usize>,
}

/// Stop flags of the controllers being forwarded, by device.
pub type Pads = Running;

/// How often the forwarding loop checks for a stop or a cancel.
const TICK: Duration = Duration::from_millis(100);
/// How long `hid` gets to refuse the device before the job reports success.
const REGISTER_GRACE: Duration = Duration::from_millis(500);

pub fn specs() -> Vec<CommandSpec> {
    vec![
        CommandSpec::new::<NoParams>(
            "input.gamepad.list",
            "List the game controllers connected to this computer",
        ),
        CommandSpec::new::<ConnectParams>(
            "input.gamepad.connect",
            "Forward a game controller on this computer to the device until input.gamepad.disconnect",
        )
        .long_running(),
        CommandSpec::new::<DeviceParams>(
            "input.gamepad.disconnect",
            "Stop forwarding the game controller to the device",
        ),
        CommandSpec::new::<DeviceParams>(
            "input.gamepad.get",
            "Whether a game controller is being forwarded to the device",
        ),
    ]
}

/// Why forwarding stopped.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ended {
    /// `input.gamepad.disconnect`.
    Disconnected,
    /// The controller went away.
    Unplugged,
    /// The guest's `hid` command stopped taking reports (the device stopped).
    DeviceStopped,
}

impl Ended {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Disconnected => "disconnected",
            Self::Unplugged => "unplugged",
            Self::DeviceStopped => "device_stopped",
        }
    }
}

async fn write_line<W: AsyncWrite + Unpin>(w: &mut W, v: &Value) -> std::io::Result<()> {
    let mut line = v.to_string().into_bytes();
    line.push(b'\n');
    w.write_all(&line).await?;
    w.flush().await
}

/// Replays `rx` into `hid` on `w`, one report per change, until a stop,
/// a cancel (an error), the controller going away or `w` closing. Returns
/// why it ended and how many reports it sent.
pub async fn forward<W: AsyncWrite + Unpin>(
    rx: &mut mpsc::Receiver<PadEvent>,
    w: &mut W,
    stop: &AtomicBool,
    cancel: &Cancel,
) -> JidrResult<(Ended, u64)> {
    let mut pad = Pad::default();
    let mut sent = 0;
    loop {
        cancel.check()?;
        if stop.load(Ordering::Relaxed) {
            return Ok((Ended::Disconnected, sent));
        }
        let ev = match tokio::time::timeout(TICK, rx.recv()).await {
            Err(_) => continue,
            Ok(None | Some(PadEvent::Disconnected)) => return Ok((Ended::Unplugged, sent)),
            Ok(Some(ev)) => ev,
        };
        if pad.apply(ev) {
            if write_line(w, &hid::report_line(&pad)).await.is_err() {
                return Ok((Ended::DeviceStopped, sent));
            }
            sent += 1;
        }
    }
}

/// Sets the reader thread's stop flag however the job ends.
struct StopReader(Arc<AtomicBool>);

impl Drop for StopReader {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Relaxed);
    }
}

async fn read_all<R: AsyncRead + Unpin>(r: Option<R>) -> String {
    let mut s = String::new();
    if let Some(mut r) = r {
        let _ = r.read_to_string(&mut s).await;
    }
    s.trim().to_string()
}

async fn connect(ctx: &CallCtx, pads: &Pads, p: ConnectParams) -> JidrResult<Value> {
    let t = target(ctx, &p.device).await?;
    let name = t.device.name.clone();
    let reg = pads.start(t.device.id, || {
        format!(
            "a game controller is already forwarded to {name}; disconnect it first (input.gamepad.disconnect)"
        )
    })?;
    let adb = t.adb();
    let (status, _) = adb.shell_status("command -v hid").await?;
    if status != 0 {
        return Err(JidrError::usage(format!(
            "{name} has no `hid` command, which Jidr uses to add a game controller"
        )));
    }

    let (tx, mut rx) = mpsc::channel(256);
    let stop = reg.flag.clone();
    let _reader = StopReader(stop.clone());
    let wanted = p.controller;
    let controller = tokio::task::spawn_blocking(move || host::open(wanted, tx, stop))
        .await
        .map_err(|e| JidrError::unexpected(format!("opening the controller: {e}")))??;

    let mut child = adb.spawn_with_stdin(&["shell", "hid", "-"])?;
    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| JidrError::unexpected("adb shell hid has no stdin"))?;
    let refused = |detail: String| {
        JidrError::sdk(format!(
            "{name} refused the virtual controller{}",
            if detail.is_empty() {
                String::new()
            } else {
                format!(": {detail}")
            }
        ))
    };
    if write_line(&mut stdin, &hid::register_line(&controller.name))
        .await
        .is_err()
    {
        return Err(refused(read_all(child.stderr.take()).await));
    }
    tokio::time::sleep(REGISTER_GRACE).await;
    if let Ok(Some(_)) = child.try_wait() {
        return Err(refused(read_all(child.stderr.take()).await));
    }

    ctx.report(None, &format!("{} → {name}", controller.name));
    let (ended, reports) = forward(&mut rx, &mut stdin, &reg.flag, &ctx.cancel).await?;
    // EOF ends `hid`, and the guest removes the controller.
    drop(stdin);
    let _ = tokio::time::timeout(Duration::from_secs(2), child.wait()).await;
    Ok(json!({
        "controller": controller,
        "reports": reports,
        "ended": ended.as_str(),
    }))
}

pub async fn call(ctx: &CallCtx, pads: &Pads, method: &str, params: Value) -> JidrResult<Value> {
    match method {
        "input.gamepad.list" => {
            let _: NoParams = parse_params(params)?;
            let all = tokio::task::spawn_blocking(host::list)
                .await
                .map_err(|e| JidrError::unexpected(format!("listing controllers: {e}")))??;
            Ok(json!({ "controllers": all }))
        }
        "input.gamepad.connect" => connect(ctx, pads, parse_params(params)?).await,
        "input.gamepad.disconnect" => {
            let p: DeviceParams = parse_params(params)?;
            let d = ctx.daemon.device(&p.device).await?;
            Ok(json!({ "disconnected": pads.stop(d.id) }))
        }
        "input.gamepad.get" => {
            let p: DeviceParams = parse_params(params)?;
            let d = ctx.daemon.device(&p.device).await?;
            Ok(json!({ "connected": pads.get(d.id).is_some() }))
        }
        _ => Err(JidrError::usage(format!("unknown method {method}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::hid::{Axis, Button};
    use super::*;

    fn lines(buf: &[u8]) -> Vec<Value> {
        String::from_utf8_lossy(buf)
            .lines()
            .map(|l| serde_json::from_str(l).unwrap())
            .collect()
    }

    #[tokio::test]
    async fn forwards_changes_until_the_controller_goes_away() {
        let (tx, mut rx) = mpsc::channel(8);
        for ev in [
            PadEvent::Button(Button::South, true),
            PadEvent::Button(Button::South, true), // no change, no report
            PadEvent::Axis(Axis::LeftTrigger, 1.0),
            PadEvent::Disconnected,
        ] {
            tx.send(ev).await.unwrap();
        }
        let mut out = Vec::new();
        let (ended, sent) = forward(&mut rx, &mut out, &AtomicBool::new(false), &Cancel::new())
            .await
            .unwrap();
        assert_eq!((ended, sent), (Ended::Unplugged, 2));
        let l = lines(&out);
        assert_eq!(l.len(), 2);
        assert_eq!(l[0]["command"], "report");
        assert_eq!(l[1]["report"][0], 1, "A still held");
        assert_eq!(l[1]["report"][10], 255, "left trigger");
    }

    #[tokio::test]
    async fn stops_on_disconnect_and_on_cancel() {
        let (_tx, mut rx) = mpsc::channel::<PadEvent>(1);
        let stop = AtomicBool::new(true);
        let (ended, sent) = forward(&mut rx, &mut Vec::new(), &stop, &Cancel::new())
            .await
            .unwrap();
        assert_eq!((ended, sent), (Ended::Disconnected, 0));

        let cancel = Cancel::new();
        cancel.cancel();
        let e = forward(&mut rx, &mut Vec::new(), &AtomicBool::new(false), &cancel)
            .await
            .unwrap_err();
        assert!(jidr_core::cancel::is_cancelled(&e));
    }

    #[tokio::test]
    async fn a_closed_guest_ends_the_job() {
        let (tx, mut rx) = mpsc::channel(1);
        tx.send(PadEvent::Button(Button::Start, true))
            .await
            .unwrap();
        let (w, r) = tokio::io::duplex(64);
        drop(r);
        let mut w = w;
        let (ended, sent) = forward(&mut rx, &mut w, &AtomicBool::new(false), &Cancel::new())
            .await
            .unwrap();
        assert_eq!((ended, sent), (Ended::DeviceStopped, 0));
    }
}
