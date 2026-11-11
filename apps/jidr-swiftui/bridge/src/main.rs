//! Private prototype transport: NDJSON commands on stdin; bounded RGBA frames on stdout.
use anyhow::{Context, Result, bail};
use jidr_core::{ConnectInfo, JidrPaths};
use jidr_proto::{BearerToken, control as pb};
use serde::Deserialize;
use serde_json::json;
use std::io::{BufRead, Write};
use std::sync::{
    Arc,
    atomic::{AtomicU32, Ordering},
    mpsc,
};
use std::time::Duration;
use tokio::sync::mpsc as async_mpsc;

mod frame_transport;
use frame_transport::{FramePacket, FrameTransport};
mod player_input;
use player_input::{GrpcInput, InputState, SerialInput};

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Command {
    Touch { x: f64, y: f64, down: bool },
    MappedTouch { id: i32, x: f64, y: f64, down: bool },
    Key { key: String, down: bool },
    Text { text: String },
    Paste { text: String },
    Copy { request_id: u64 },
    Cut { request_id: u64 },
    SelectAll,
    Rotate { direction: i32 },
    ToolKey { key: String },
    Screenshot { path: String },
    SendFile { path: String },
    StartRecording { path: String },
    StopRecording,
    AppInspect { path: String },
    AppUninstall { package: String },
}

/// One user-visible bridge notification: a stable machine code plus an English
/// fallback message. The Swift player may translate the code; the bridge itself
/// never sends Chinese UI text, so English mode cannot leak it.
#[derive(Debug, Clone, Copy)]
struct Diagnostic {
    code: &'static str,
    message: &'static str,
}

impl Diagnostic {
    const fn new(code: &'static str, message: &'static str) -> Self {
        Self { code, message }
    }
}

const FILE_INVALID_PATH: Diagnostic =
    Diagnostic::new("file.invalid_path", "Choose a valid local file path");
const FILE_NOT_A_FILE: Diagnostic =
    Diagnostic::new("file.not_a_file", "Choose a file, not a folder");
const SCREENSHOT_SAVED: Diagnostic = Diagnostic::new("screenshot.saved", "Screenshot saved");
const APP_INSTALLED: Diagnostic = Diagnostic::new("app.installed", "App installed");
const FILE_SENT: Diagnostic =
    Diagnostic::new("file.sent", "File sent to the device's Downloads folder");
const RECORDING_INVALID_PATH: Diagnostic = Diagnostic::new(
    "recording.invalid_path",
    "Invalid recording path, or the file already exists",
);
const RECORDING_STARTED: Diagnostic = Diagnostic::new("recording.started", "Recording");
const RECORDING_SAVED: Diagnostic = Diagnostic::new("recording.saved", "Recording saved");

/// Codes for failures whose readable text carries the daemon's own error.
const FILE_OPERATION_FAILED: &str = "file.operation_failed";
const RECORDING_FAILED: &str = "recording.failed";
const RECORDING_STOP_FAILED: &str = "recording.stop_failed";
const APP_INSPECTED: &str = "app.inspected";
const APP_INSPECT_FAILED: &str = "app.inspect_failed";
const APP_UNINSTALLED: &str = "app.uninstalled";
const APP_UNINSTALL_FAILED: &str = "app.uninstall_failed";

fn panel_point(x: f64, y: f64, width: u32, height: u32, quarter: u32) -> Option<(i32, i32)> {
    if !x.is_finite()
        || !y.is_finite()
        || !(0.0..=1.0).contains(&x)
        || !(0.0..=1.0).contains(&y)
        || width == 0
        || height == 0
    {
        return None;
    }
    let (shown_w, shown_h) = if quarter.is_multiple_of(2) {
        (width, height)
    } else {
        (height, width)
    };
    let px = (x * f64::from(shown_w)).min(f64::from(shown_w - 1)) as i32;
    let py = (y * f64::from(shown_h)).min(f64::from(shown_h - 1)) as i32;
    let (r, b) = (width as i32 - 1, height as i32 - 1);
    Some(match quarter % 4 {
        1 => (r - py, px),
        2 => (r - px, b - py),
        3 => (py, b - px),
        _ => (px, py),
    })
}

fn request_size(width: u32, height: u32, quality: u8) -> (u32, u32) {
    let factor = match quality {
        0 => 0.65,
        2 => 0.45,
        _ => 1.0,
    };
    let scale = (720.0 / f64::from(width))
        .min(1280.0 / f64::from(height))
        .min(1.0)
        * factor;
    (
        (f64::from(width) * scale).round().max(1.0) as u32,
        (f64::from(height) * scale).round().max(1.0) as u32,
    )
}

fn frame_packet(width: u32, height: u32, quarter: u32, bytes: &[u8]) -> Option<Vec<u8>> {
    let len = (width as usize)
        .checked_mul(height as usize)?
        .checked_mul(4)?;
    if width == 0 || height == 0 || len != bytes.len() || len > 32 * 1024 * 1024 {
        return None;
    }
    let mut out = Vec::with_capacity(20 + len);
    out.extend_from_slice(b"JFR1");
    for n in [width, height, quarter % 4, len as u32] {
        out.extend_from_slice(&n.to_be_bytes());
    }
    out.extend_from_slice(bytes);
    Some(out)
}

/// Android's logical display orientation can differ from the emulator's
/// physical pose (for example, a portrait-locked launcher on its side).
fn display_orientation(output: &str) -> Option<u32> {
    output.lines().find_map(|line| {
        let value = line.trim().strip_prefix("mCurrentOrientation=")?;
        value.parse::<u32>().ok().filter(|value| *value < 4)
    })
}

/// Reorient the RGBA image from emulator pose to Android display orientation.
fn orient_frame(width: u32, height: u32, turns: u32, pixels: &[u8]) -> Option<(u32, u32, Vec<u8>)> {
    let expected = (width as usize)
        .checked_mul(height as usize)?
        .checked_mul(4)?;
    if width == 0 || height == 0 || pixels.len() != expected || expected > 32 * 1024 * 1024 {
        return None;
    }
    let turns = turns % 4;
    if turns == 0 {
        return Some((width, height, pixels.to_vec()));
    }
    let (out_width, out_height) = if turns.is_multiple_of(2) {
        (width, height)
    } else {
        (height, width)
    };
    let mut out = vec![0; expected];
    for y in 0..height {
        for x in 0..width {
            let (dx, dy) = match turns {
                1 => (y, width - 1 - x),
                2 => (width - 1 - x, height - 1 - y),
                _ => (height - 1 - y, x),
            };
            let source = ((y as usize * width as usize) + x as usize) * 4;
            let target = ((dy as usize * out_width as usize) + dx as usize) * 4;
            out[target..target + 4].copy_from_slice(&pixels[source..source + 4]);
        }
    }
    Some((out_width, out_height, out))
}

async fn read_display_orientation(adb: &std::path::Path, serial: &str) -> Option<u32> {
    let mut command = tokio::process::Command::new(adb);
    command
        .args(["-s", serial, "shell", "dumpsys", "display"])
        .kill_on_drop(true);
    match tokio::time::timeout(Duration::from_secs(3), command.output()).await {
        Ok(Ok(output)) if output.status.success() => {
            display_orientation(&String::from_utf8_lossy(&output.stdout))
        }
        _ => None,
    }
}

async fn watch_display_orientation(adb: std::path::PathBuf, serial: String, value: Arc<AtomicU32>) {
    loop {
        // Keep the last known orientation on transient ADB errors.
        if let Some(orientation) = read_display_orientation(&adb, &serial).await {
            value.store(orientation, Ordering::Relaxed);
        }
        tokio::time::sleep(Duration::from_millis(750)).await;
    }
}

fn oriented_packet(
    width: u32,
    height: u32,
    pose: u32,
    logical: u32,
    pixels: &[u8],
) -> Option<(u32, Vec<u8>)> {
    let shown = if logical < 4 { logical } else { pose };
    let turns = (shown + 4 - pose) % 4;
    let packet = if turns == 0 {
        frame_packet(width, height, shown, pixels)
    } else {
        orient_frame(width, height, turns, pixels)
            .and_then(|(w, h, data)| frame_packet(w, h, shown, &data))
    }?;
    Some((shown, packet))
}

fn is_apk(path: &str) -> bool {
    std::path::Path::new(path)
        .extension()
        .is_some_and(|ext| ext.eq_ignore_ascii_case("apk"))
}

/// A local validation failure or the daemon's own error. Daemon failures keep
/// their raw English detail so the player can still classify `INSTALL_FAILED_*`.
enum FileOperationError {
    InvalidPath,
    NotAFile,
    Daemon(anyhow::Error),
}

impl FileOperationError {
    fn code(&self) -> &'static str {
        match self {
            Self::InvalidPath => FILE_INVALID_PATH.code,
            Self::NotAFile => FILE_NOT_A_FILE.code,
            Self::Daemon(_) => FILE_OPERATION_FAILED,
        }
    }

    fn message(&self) -> String {
        match self {
            Self::InvalidPath => FILE_INVALID_PATH.message.to_owned(),
            Self::NotAFile => FILE_NOT_A_FILE.message.to_owned(),
            Self::Daemon(error) => format!("{error:#}"),
        }
    }
}

async fn run_file_operation(
    client: &jidr_client::Client,
    device: &str,
    path: &str,
    screenshot: bool,
) -> std::result::Result<Diagnostic, FileOperationError> {
    let path = std::path::Path::new(path);
    if !path.is_absolute() || path.file_name().is_none() {
        return Err(FileOperationError::InvalidPath);
    }
    if screenshot {
        client
            .call("media.screenshot", json!({"device":device,"path":path}))
            .await
            .map_err(|error| FileOperationError::Daemon(error.into()))?;
        return Ok(SCREENSHOT_SAVED);
    }
    if !path.is_file() {
        return Err(FileOperationError::NotAFile);
    }
    if is_apk(&path.to_string_lossy()) {
        client
            .call(
                "file.install",
                json!({"device":device,"apk":path,"replace":true}),
            )
            .await
            .map_err(|error| FileOperationError::Daemon(error.into()))?;
        Ok(APP_INSTALLED)
    } else {
        client
            .call("file.push", json!({"device":device,"local":path}))
            .await
            .map_err(|error| FileOperationError::Daemon(error.into()))?;
        Ok(FILE_SENT)
    }
}

/// Deterministic synthetic RGBA panel for the snapshot renderer: a status bar,
/// a game-screen card and a two-axis gradient. No randomness, no gRPC.
fn fixture_pixels(width: u32, height: u32) -> Vec<u8> {
    let mut pixels = Vec::with_capacity(width as usize * height as usize * 4);
    for y in 0..height {
        for x in 0..width {
            let fx = f64::from(x) / f64::from(width - 1).max(1.0);
            let fy = f64::from(y) / f64::from(height - 1).max(1.0);
            let (mut r, mut g, mut b) = (12.0 + 34.0 * fy, 16.0 + 48.0 * fx, 34.0 + 60.0 * fy);
            if (0.14..=0.86).contains(&fx) && (0.22..=0.78).contains(&fy) {
                r = 58.0 + 60.0 * fx;
                g = 74.0 + 80.0 * fy;
                b = 120.0 + 70.0 * fx;
            }
            if fy < 0.05 {
                (r, g, b) = (20.0, 170.0, 120.0);
            }
            pixels.extend_from_slice(&[r as u8, g as u8, b as u8, 255]);
        }
    }
    pixels
}

const PREVIEW_UNSUPPORTED: Diagnostic = Diagnostic::new(
    "preview.unsupported",
    "UI preview: this operation requires a real device connection.",
);

/// Fixtures must never silently accept a device command. Recording and app
/// flows need their own failure envelopes to release the UI's pending state.
fn fixture_reply(line: &str) -> (&'static str, serde_json::Value) {
    let mut value =
        json!({"ok":false,"code":PREVIEW_UNSUPPORTED.code,"message":PREVIEW_UNSUPPORTED.message});
    let prefix = match serde_json::from_str::<Command>(line) {
        Ok(Command::StartRecording { .. } | Command::StopRecording) => {
            value["state"] = json!("failed");
            "JIDR_RECORD:"
        }
        Ok(Command::AppInspect { .. }) => {
            value["op"] = json!("inspect");
            "JIDR_APP:"
        }
        Ok(Command::AppUninstall { .. }) => {
            value["op"] = json!("uninstall");
            "JIDR_APP:"
        }
        _ => "JIDR_OPERATION:",
    };
    (prefix, value)
}

/// `JIDR_PLAYER_FIXTURE=1` replaces the gRPC stream with synthetic frames.
/// Device commands explicitly fail; local window tools still work normally.
async fn player_fixture(width: u32, height: u32) -> Result<()> {
    let frame_width = 360u32.min(width).max(1);
    let frame_height = 640u32.min(height).max(1);
    let (frame_tx, frame_rx) = mpsc::sync_channel::<Vec<u8>>(2);
    std::thread::spawn(move || {
        let mut out = std::io::stdout().lock();
        for frame in frame_rx {
            if out.write_all(&frame).is_err() {
                break;
            }
        }
    });
    let (input_tx, mut input_rx) = async_mpsc::channel::<String>(128);
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            if line.len() <= 1024 * 1024 + 256 && input_tx.blocking_send(line).is_err() {
                break;
            }
        }
    });
    let pixels = fixture_pixels(frame_width, frame_height);
    let packet =
        frame_packet(frame_width, frame_height, 0, &pixels).context("invalid fixture frame")?;
    tokio::time::sleep(Duration::from_millis(250)).await;
    eprintln!("fixture: connected");
    for _ in 0..3 {
        let mut pending = Some(packet.clone());
        while let Some(frame) = pending {
            match frame_tx.try_send(frame) {
                Ok(()) => pending = None,
                Err(mpsc::TrySendError::Full(frame)) => {
                    pending = Some(frame);
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
                Err(mpsc::TrySendError::Disconnected(_)) => return Ok(()),
            }
        }
        tokio::time::sleep(Duration::from_millis(40)).await;
    }
    while let Some(line) = input_rx.recv().await {
        let (prefix, value) = fixture_reply(&line);
        eprintln!("{prefix}{value}");
    }
    Ok(())
}

struct BridgeInputs {
    state: InputState<GrpcInput>,
    client: Arc<jidr_client::Client>,
    device: String,
    panel: (u32, u32),
    rotation: Arc<AtomicU32>,
    physical_rotation: Arc<AtomicU32>,
}

impl SerialInput for BridgeInputs {
    async fn handle(&mut self, line: String) {
        let client = &self.client;
        let device = &self.device;
        match serde_json::from_str::<Command>(&line) {
            Ok(Command::Rotate { direction }) => {
                let current = self.physical_rotation.load(Ordering::Relaxed) as i32;
                let angle = (current + direction.signum()).rem_euclid(4) * 90;
                if let Err(e) = client
                    .call("sensor.rotate", json!({"device":device, "angle":angle}))
                    .await
                {
                    eprintln!("Rotate failed: {e}");
                }
            }
            Ok(Command::ToolKey { key }) => {
                if [
                    "back",
                    "home",
                    "recents",
                    "volume_up",
                    "volume_down",
                    "power",
                ]
                .contains(&key.as_str())
                    && let Err(e) = client
                        .call("key.press", json!({"device":device, "key":key}))
                        .await
                {
                    eprintln!("Key failed: {e}");
                }
            }
            Ok(Command::StartRecording { path }) => {
                let path = std::path::PathBuf::from(path);
                if !path.is_absolute() || path.exists() {
                    eprintln!(
                        "JIDR_RECORD:{}",
                        json!({"state":"failed", "code":RECORDING_INVALID_PATH.code, "message":RECORDING_INVALID_PATH.message})
                    );
                } else {
                    let client = Arc::clone(client);
                    let device = device.clone();
                    tokio::spawn(async move {
                        let announced = std::sync::atomic::AtomicBool::new(false);
                        let result = client.run("media.record", json!({"device":device,"path":path}), |_| {
                            if !announced.swap(true, Ordering::Relaxed) {
                                eprintln!("JIDR_RECORD:{}", json!({"state":"recording", "code":RECORDING_STARTED.code, "message":RECORDING_STARTED.message}));
                            }
                        }).await;
                        match result {
                            Ok(value) => eprintln!(
                                "JIDR_RECORD:{}",
                                json!({"state":"finished","code":RECORDING_SAVED.code,"message":RECORDING_SAVED.message,"result":value})
                            ),
                            Err(error) => eprintln!(
                                "JIDR_RECORD:{}",
                                json!({"state":"failed","code":RECORDING_FAILED,"message":format!("Recording failed: {error}")})
                            ),
                        }
                    });
                }
            }
            Ok(Command::StopRecording) => {
                let client = Arc::clone(client);
                let device = device.clone();
                tokio::spawn(async move {
                    if let Err(error) = client
                        .call("media.record_stop", json!({"device":device}))
                        .await
                    {
                        eprintln!(
                            "JIDR_RECORD:{}",
                            json!({"state":"stop_failed", "code":RECORDING_STOP_FAILED, "message":format!("Could not stop recording: {error}")})
                        );
                    }
                });
            }
            Ok(command @ (Command::Screenshot { .. } | Command::SendFile { .. })) => {
                let screenshot = matches!(command, Command::Screenshot { .. });
                let path = match command {
                    Command::Screenshot { path } | Command::SendFile { path } => path,
                    _ => return,
                };
                let client = Arc::clone(client);
                let device = device.clone();
                tokio::spawn(async move {
                    match run_file_operation(&client, &device, &path, screenshot).await {
                        Ok(saved) => eprintln!(
                            "JIDR_OPERATION:{}",
                            json!({"ok":true,"code":saved.code,"message":saved.message,"path":path})
                        ),
                        Err(error) => eprintln!(
                            "JIDR_OPERATION:{}",
                            json!({"ok":false,"code":error.code(),"message":error.message()})
                        ),
                    }
                });
            }
            Ok(Command::AppInspect { path }) => {
                let client = Arc::clone(client);
                tokio::spawn(async move {
                    match client.call("app.inspect", json!({"apk": path})).await {
                        Ok(value) => eprintln!(
                            "JIDR_APP:{}",
                            json!({"op":"inspect","ok":true,"code":APP_INSPECTED,"apk":path,"package":value.get("package"),"label":value.get("label")})
                        ),
                        Err(error) => eprintln!(
                            "JIDR_APP:{}",
                            json!({"op":"inspect","ok":false,"code":APP_INSPECT_FAILED,"apk":path,"message":format!("{error}")})
                        ),
                    }
                });
            }
            Ok(Command::AppUninstall { package }) => {
                let client = Arc::clone(client);
                let device = device.clone();
                tokio::spawn(async move {
                    match client
                        .call("app.uninstall", json!({"device":device,"package":package}))
                        .await
                    {
                        Ok(_) => eprintln!(
                            "JIDR_APP:{}",
                            json!({"op":"uninstall","ok":true,"code":APP_UNINSTALLED,"package":package})
                        ),
                        Err(error) => eprintln!(
                            "JIDR_APP:{}",
                            json!({"op":"uninstall","ok":false,"code":APP_UNINSTALL_FAILED,"package":package,"message":format!("{error}")})
                        ),
                    }
                });
            }
            Ok(command) => {
                if let Err(e) = self
                    .state
                    .command(command, self.panel, &self.rotation)
                    .await
                {
                    eprintln!("Input failed: {e:#}");
                }
            }
            Err(e) => eprintln!("Invalid input: {e}"),
        }
    }
    async fn release(&mut self) {
        self.state.release().await;
    }
}

struct FramePump {
    frames: tonic::Streaming<pb::Image>,
    sender: async_mpsc::Sender<FramePacket>,
    transport: FrameTransport,
    rotation: Arc<AtomicU32>,
    physical: Arc<AtomicU32>,
    logical: Arc<AtomicU32>,
    latest: Option<(u32, u32, u32, Arc<Vec<u8>>)>,
    tick: tokio::time::Interval,
}
impl FramePump {
    async fn step(&mut self) -> bool {
        tokio::select! {
            _ = self.tick.tick() => {
                let logical = self.logical.load(Ordering::Relaxed);
                if logical < 4 && logical != self.rotation.load(Ordering::Relaxed)
                    && let Some((w,h,pose,pixels)) = &self.latest
                    && let Some(shown) = self.transport.offer(&self.sender, (*w,*h), *pose, logical, pixels) {
                    self.rotation.store(shown, Ordering::Relaxed);
                }
            }
            message = self.frames.message() => match message {
                Ok(Some(image)) => {
                    if let Some(format) = image.format {
                        let pose = format.rotation.map_or(0, |r| r.rotation.rem_euclid(4) as u32);
                        self.physical.store(pose, Ordering::Relaxed);
                        self.latest = Some((format.width, format.height, pose, Arc::new(image.image)));
                        if let Some((w,h,pose,pixels)) = &self.latest
                            && let Some(shown) = self.transport.offer(&self.sender, (*w,*h), *pose, self.logical.load(Ordering::Relaxed), pixels) {
                            self.rotation.store(shown, Ordering::Relaxed);
                        }
                    }
                }
                Ok(None) => return false,
                Err(error) => { eprintln!("Frame stream failed: {error}"); return false; }
            }
        }
        true
    }
    async fn run(&mut self) {
        while self.step().await {}
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if !(4..=5).contains(&args.len()) {
        bail!("usage: jidr-swiftui-bridge DEVICE PANEL_WIDTH PANEL_HEIGHT [QUALITY]");
    }
    let width: u32 = args[2].parse().context("invalid panel width")?;
    let height: u32 = args[3].parse().context("invalid panel height")?;
    if !(1..=8192).contains(&width) || !(1..=8192).contains(&height) {
        bail!("invalid panel dimensions");
    }
    let quality: u8 = args
        .get(4)
        .map_or(Ok(1), |arg| arg.parse())
        .context("invalid quality")?;
    if quality > 2 {
        bail!("invalid quality");
    }
    if std::env::var("JIDR_PLAYER_FIXTURE").is_ok_and(|value| value == "1") {
        return player_fixture(width, height).await;
    }
    let scheduling = player_input::Scheduling::parse(
        &std::env::var("JIDR_PLAYER_INPUT_SCHEDULER").unwrap_or_else(|_| "fifo".into()),
    )
    .context("JIDR_PLAYER_INPUT_SCHEDULER must be fifo or inline")?;
    let client = Arc::new(
        jidr_client::Client::connect(&JidrPaths::discover()?.socket(), "swiftui-prototype").await?,
    );
    let info: ConnectInfo = client
        .call_as("device.connect_info", json!({"device":args[1]}))
        .await?;
    let mapping_path = JidrPaths::discover()?
        .data
        .join("keymaps")
        .join(format!("{}.json", info.device));
    eprintln!("JIDR_MAPPING_PATH:{}", json!({"path":mapping_path}));
    let channel =
        tonic::transport::Endpoint::from_shared(format!("http://{}", info.grpc_endpoint))?
            .connect_timeout(Duration::from_secs(5))
            .tcp_nodelay(true)
            .connect()
            .await?;
    let mut ctl = jidr_proto::clients(channel, BearerToken::new(&info.grpc_token)?).0;
    let (frame_width, frame_height) = request_size(width, height, quality);
    let frames = ctl
        .stream_screenshot(pb::ImageFormat {
            format: pb::image_format::ImgFormat::Rgba8888 as i32,
            width: frame_width,
            height: frame_height,
            ..Default::default()
        })
        .await?
        .into_inner();
    let transport = FrameTransport::parse(
        &std::env::var("JIDR_PLAYER_FRAME_TRANSPORT").unwrap_or_else(|_| "shared".into()),
    )
    .context("JIDR_PLAYER_FRAME_TRANSPORT must be shared or legacy")?;
    let (frame_tx, mut frame_rx) = async_mpsc::channel::<FramePacket>(1);
    let (output_done, mut output_closed) = tokio::sync::oneshot::channel();
    std::thread::spawn(move || {
        let mut out = std::io::stdout().lock();
        while let Some(frame) = frame_rx.blocking_recv() {
            if frame.write_to(&mut out).is_err() {
                break;
            }
        }
        let _ = output_done.send(());
    });
    let (input_tx, mut input_rx) = async_mpsc::channel::<String>(128);
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            if line.len() <= 1024 * 1024 + 256 && input_tx.blocking_send(line).is_err() {
                break;
            }
        }
    });
    let rotation = Arc::new(AtomicU32::new(0));
    let physical_rotation = Arc::new(AtomicU32::new(0));
    let initial_orientation = read_display_orientation(&info.adb_path, &info.adb_serial)
        .await
        .unwrap_or(4);
    let logical_rotation = Arc::new(AtomicU32::new(initial_orientation));
    tokio::spawn(watch_display_orientation(
        info.adb_path.clone(),
        info.adb_serial.clone(),
        Arc::clone(&logical_rotation),
    ));
    // Before this point no input RPC has been sent, so startup retains the
    // default immediate SIGTERM behavior. Install graceful cleanup before the
    // single input owner can begin delivering downs.
    #[cfg(unix)]
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let shutdown = async {
        #[cfg(unix)]
        tokio::select! { _ = terminate.recv() => {}, _ = tokio::signal::ctrl_c() => {} }
        #[cfg(not(unix))]
        let _ = tokio::signal::ctrl_c().await;
    };
    tokio::pin!(shutdown);
    let mut handler = BridgeInputs {
        state: InputState::new(GrpcInput::new(ctl)),
        client,
        device: args[1].clone(),
        panel: (width, height),
        rotation: Arc::clone(&rotation),
        physical_rotation: Arc::clone(&physical_rotation),
    };
    let mut pump = FramePump {
        frames,
        sender: frame_tx,
        transport,
        rotation,
        physical: physical_rotation,
        logical: logical_rotation,
        latest: None,
        tick: tokio::time::interval(Duration::from_millis(150)),
    };
    match scheduling {
        player_input::Scheduling::Fifo => {
            let (stop, stopping) = tokio::sync::oneshot::channel();
            let mut worker = tokio::spawn(player_input::worker(handler, input_rx, stopping));
            let completed = tokio::select! {
                () = pump.run() => false,
                () = &mut shutdown => false,
                _ = &mut output_closed => false,
                result = &mut worker => {
                    if let Err(error) = result { eprintln!("Input worker failed: {error}"); }
                    true
                }
            };
            // Close the screenshot stream before releasing inputs; an unread
            // frame stream must not keep transport resources during shutdown.
            drop(pump);
            if !completed {
                let _ = stop.send(());
                if let Err(error) = worker.await {
                    eprintln!("Input worker failed: {error}");
                }
            }
        }
        player_input::Scheduling::Inline => {
            {
                let serial = async {
                    loop {
                        tokio::select! {
                            running = pump.step() => if !running { break; },
                            line = input_rx.recv() => match line {
                                Some(line) => handler.handle(line).await, None => break,
                            }
                        }
                    }
                };
                tokio::select! { () = serial => {}, () = &mut shutdown => {}, _ = &mut output_closed => {} }
            }
            drop(pump);
            handler.release().await;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preview_commands_fail_explicitly_and_release_pending_flows() {
        for (command, prefix, field, expected) in [
            (
                r#"{"type":"tool_key","key":"home"}"#,
                "JIDR_OPERATION:",
                "code",
                "preview.unsupported",
            ),
            (
                r#"{"type":"rotate","direction":1}"#,
                "JIDR_OPERATION:",
                "code",
                "preview.unsupported",
            ),
            (
                r#"{"type":"start_recording","path":"/tmp/preview.mp4"}"#,
                "JIDR_RECORD:",
                "state",
                "failed",
            ),
            (
                r#"{"type":"stop_recording"}"#,
                "JIDR_RECORD:",
                "state",
                "failed",
            ),
            (
                r#"{"type":"app_inspect","path":"/tmp/preview.apk"}"#,
                "JIDR_APP:",
                "op",
                "inspect",
            ),
            (
                r#"{"type":"app_uninstall","package":"example.test"}"#,
                "JIDR_APP:",
                "op",
                "uninstall",
            ),
        ] {
            let (actual, value) = fixture_reply(command);
            assert_eq!(actual, prefix);
            assert_eq!(value["ok"], false);
            assert_eq!(value[field], expected);
            assert_eq!(value["message"], PREVIEW_UNSUPPORTED.message);
        }
    }

    /// The player's UI copy lives in Swift; the bridge must only send stable
    /// codes and English fallbacks. This guards the contract M3 introduced.
    #[test]
    fn bridge_diagnostics_use_ascii_codes_and_english() {
        for diagnostic in [
            FILE_INVALID_PATH,
            FILE_NOT_A_FILE,
            SCREENSHOT_SAVED,
            APP_INSTALLED,
            FILE_SENT,
            RECORDING_INVALID_PATH,
            RECORDING_STARTED,
            RECORDING_SAVED,
            PREVIEW_UNSUPPORTED,
        ] {
            assert!(
                diagnostic.code.is_ascii() && !diagnostic.code.contains(' '),
                "code {:?}",
                diagnostic.code
            );
            assert!(
                diagnostic.message.is_ascii(),
                "message {:?}",
                diagnostic.message
            );
        }
        assert_eq!(
            FILE_INVALID_PATH.code,
            FileOperationError::InvalidPath.code()
        );
        assert_eq!(FILE_NOT_A_FILE.code, FileOperationError::NotAFile.code());
        for code in [
            FILE_OPERATION_FAILED,
            RECORDING_FAILED,
            RECORDING_STOP_FAILED,
            APP_INSPECTED,
            APP_INSPECT_FAILED,
            APP_UNINSTALLED,
            APP_UNINSTALL_FAILED,
        ] {
            assert!(code.is_ascii() && code.contains('.'), "code {code:?}");
        }
    }
    #[test]
    fn app_commands_parse() {
        let inspect: Command =
            serde_json::from_str(r#"{"type":"app_inspect","path":"/tmp/a.apk"}"#).unwrap();
        assert!(matches!(inspect, Command::AppInspect { ref path } if path == "/tmp/a.apk"));
        let uninstall: Command =
            serde_json::from_str(r#"{"type":"app_uninstall","package":"com.example.shop"}"#)
                .unwrap();
        assert!(
            matches!(uninstall, Command::AppUninstall { ref package } if package == "com.example.shop")
        );
    }
    #[test]
    fn file_type_is_based_on_apk_extension() {
        assert!(is_apk("/tmp/game.APK"));
        assert!(!is_apk("/tmp/game.apk.zip"));
        assert!(!is_apk("/tmp/no-extension"));
    }
    #[test]
    fn touch_rotations_and_invalid_coordinates() {
        assert_eq!(panel_point(0.0, 0.0, 720, 1280, 0), Some((0, 0)));
        assert_eq!(panel_point(0.0, 0.0, 720, 1280, 1), Some((719, 0)));
        assert_eq!(panel_point(1.0, 1.0, 720, 1280, 3), Some((719, 0)));
        assert_eq!(panel_point(-0.1, 0.0, 720, 1280, 0), None);
        assert_eq!(panel_point(f64::NAN, 0.0, 720, 1280, 0), None);
    }
    #[test]
    fn display_orientation_only_accepts_valid_logical_rotation() {
        assert_eq!(
            display_orientation("other=1\n    mCurrentOrientation=3\n"),
            Some(3)
        );
        assert_eq!(display_orientation("mCurrentOrientation=4"), None);
        assert_eq!(display_orientation("orientation=1"), None);
    }
    #[test]
    fn orient_frame_handles_every_quarter_turn() {
        let source = [
            1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 4, 0, 0, 0, 5, 0, 0, 0, 6, 0, 0, 0,
        ];
        let labels = |turn| {
            let (w, h, p) = orient_frame(3, 2, turn, &source).unwrap();
            (
                w,
                h,
                p.as_chunks::<4>()
                    .0
                    .iter()
                    .map(|p| p[0])
                    .collect::<Vec<_>>(),
            )
        };
        assert_eq!(labels(0), (3, 2, vec![1, 2, 3, 4, 5, 6]));
        assert_eq!(labels(1), (2, 3, vec![3, 6, 2, 5, 1, 4]));
        assert_eq!(labels(2), (3, 2, vec![6, 5, 4, 3, 2, 1]));
        assert_eq!(labels(3), (2, 3, vec![4, 1, 5, 2, 6, 3]));
        assert!(orient_frame(3, 2, 1, &source[..20]).is_none());
    }

    #[test]
    fn request_size_preserves_panel_aspect_ratio() {
        assert_eq!(request_size(1080, 2400, 1), (576, 1280));
        assert_eq!(request_size(720, 1280, 1), (720, 1280));
        assert_eq!(request_size(1280, 720, 1), (720, 405));
        for (width, height) in [(720, 1280), (1280, 720)] {
            let sharp = request_size(width, height, 1);
            let smooth = request_size(width, height, 0);
            let economy = request_size(width, height, 2);
            assert!(economy.0 < smooth.0 && smooth.0 < sharp.0);
            assert!(economy.1 < smooth.1 && smooth.1 < sharp.1);
        }
    }

    #[test]
    fn frames_reject_invalid_sizes() {
        assert!(frame_packet(2, 2, 0, &[0; 15]).is_none());
        let frame = frame_packet(1, 1, 5, &[1, 2, 3, 4]);
        assert!(frame.is_some_and(|f| f.len() == 24 && &f[..4] == b"JFR1"));
    }
}
