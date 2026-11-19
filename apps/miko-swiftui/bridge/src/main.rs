//! Private prototype transport: NDJSON commands on stdin; bounded RGBA frames on stdout.
use anyhow::{Context, Result, bail};
use miko_core::{ConnectInfo, MikoPaths};
use miko_proto::{BearerToken, control as pb};
use serde::Deserialize;
use serde_json::json;
use std::io::{BufRead, Write};
use std::sync::{
    Arc,
    atomic::{AtomicU32, Ordering},
    mpsc,
};
use std::time::{Duration, Instant};
use tokio::sync::mpsc as async_mpsc;

mod frame_transport;
mod script;
mod sync;
use frame_transport::{FramePacket, FrameTransport};
mod player_input;
use player_input::{GrpcInput, InputState, SerialInput};

fn default_true() -> bool {
    true
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Command {
    Touch {
        x: f64,
        y: f64,
        down: bool,
    },
    MappedTouch {
        id: i32,
        x: f64,
        y: f64,
        down: bool,
    },
    Key {
        key: String,
        down: bool,
    },
    Text {
        text: String,
    },
    Paste {
        text: String,
    },
    Copy {
        request_id: u64,
    },
    Cut {
        request_id: u64,
    },
    SelectAll,
    Rotate {
        direction: i32,
    },
    ToolKey {
        key: String,
    },
    Screenshot {
        path: String,
    },
    SendFile {
        path: String,
    },
    StartRecording {
        path: String,
        #[serde(default = "default_true")]
        audio: bool,
    },
    StopRecording,
    AppInspect {
        path: String,
    },
    AppUninstall {
        package: String,
    },
    // Operation-recording control (docs/player-scripts.md).
    ScriptRecordStart,
    ScriptRecordPause,
    ScriptRecordResume,
    ScriptRecordStop {
        name: String,
    },
    ScriptRecordCancel,
    ScriptList,
    ScriptDelete {
        id: String,
    },
    ScriptRename {
        id: String,
        name: String,
    },
    ScriptImport {
        path: String,
    },
    ScriptExport {
        id: String,
        path: String,
    },
    ScriptPlayStart {
        id: String,
        #[serde(default)]
        options: Option<serde_json::Value>,
    },
    ScriptPlayPause,
    ScriptPlayResume,
    ScriptPlayStop,
    // Input synchronizer control and event injection (D45).
    SyncMode {
        role: sync::SyncRole,
        #[serde(default = "default_true")]
        lock: bool,
        #[serde(default)]
        leader: Option<String>,
        #[serde(default)]
        leader_display: Option<miko_sync::DisplaySize>,
        #[serde(default)]
        adaptation: miko_sync::Adaptation,
        #[serde(default = "default_true")]
        sync_keyboard: bool,
        #[serde(default = "default_true")]
        sync_text: bool,
        #[serde(default = "default_true")]
        sync_tool_keys: bool,
    },
    SyncInput {
        #[serde(default)]
        seq: Option<u64>,
        event: miko_automation::Event,
    },
    SyncRelease,
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
const MODULE_INSTALLED: Diagnostic = Diagnostic::new("module.installed", "Module installed");
const FILE_SENT: Diagnostic =
    Diagnostic::new("file.sent", "File sent to the device's Downloads folder");
const RECORDING_INVALID_PATH: Diagnostic = Diagnostic::new(
    "recording.invalid_path",
    "Invalid recording path, or the file already exists",
);
const RECORDING_STARTED: Diagnostic = Diagnostic::new("recording.started", "Recording");
const RECORDING_SAVED: Diagnostic = Diagnostic::new("recording.saved", "Recording saved");
const RECORDING_SAVED_NO_AUDIO: Diagnostic = Diagnostic::new(
    "recording.saved_no_audio",
    "Recording saved, but no device audio was received",
);

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
    client: &miko_client::Client,
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
    } else if path
        .extension()
        .is_some_and(|ext| ext.eq_ignore_ascii_case("zip"))
    {
        let result = client
            .run("file.flash", json!({"device":device,"path":path}), |_| {})
            .await
            .map_err(|error| FileOperationError::Daemon(error.into()))?;
        Ok(if result["action"] == "module_installed" {
            MODULE_INSTALLED
        } else {
            FILE_SENT
        })
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
fn fixture_reply(line: &str) -> Option<(&'static str, serde_json::Value)> {
    let mut value =
        json!({"ok":false,"code":PREVIEW_UNSUPPORTED.code,"message":PREVIEW_UNSUPPORTED.message});
    let prefix = match serde_json::from_str::<Command>(line) {
        Ok(Command::SyncMode { .. } | Command::SyncInput { .. } | Command::SyncRelease) => {
            return None;
        }
        Ok(
            Command::ScriptRecordStart
            | Command::ScriptRecordPause
            | Command::ScriptRecordResume
            | Command::ScriptRecordStop { .. }
            | Command::ScriptRecordCancel
            | Command::ScriptList
            | Command::ScriptDelete { .. }
            | Command::ScriptRename { .. }
            | Command::ScriptImport { .. }
            | Command::ScriptExport { .. }
            | Command::ScriptPlayStart { .. }
            | Command::ScriptPlayPause
            | Command::ScriptPlayResume
            | Command::ScriptPlayStop,
        ) => {
            value["op"] = json!("error");
            return Some(("MIKO_SCRIPT:", value));
        }
        Ok(Command::StartRecording { .. } | Command::StopRecording) => {
            value["state"] = json!("failed");
            "MIKO_RECORD:"
        }
        Ok(Command::AppInspect { .. }) => {
            value["op"] = json!("inspect");
            "MIKO_APP:"
        }
        Ok(Command::AppUninstall { .. }) => {
            value["op"] = json!("uninstall");
            "MIKO_APP:"
        }
        _ => "MIKO_OPERATION:",
    };
    Some((prefix, value))
}

/// `MIKO_PLAYER_FIXTURE=1` replaces the gRPC stream with synthetic frames.
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
        if let Some((prefix, value)) = fixture_reply(&line) {
            eprintln!("{prefix}{value}");
        }
    }
    Ok(())
}

struct BridgeInputs {
    state: InputState<GrpcInput>,
    client: Arc<miko_client::Client>,
    device: String,
    panel: (u32, u32),
    rotation: Arc<AtomicU32>,
    physical_rotation: Arc<AtomicU32>,
    scripts: script::ScriptManager,
    sync: sync::BridgeSync,
}

impl SerialInput for BridgeInputs {
    async fn handle(&mut self, line: String) {
        let command = match serde_json::from_str::<Command>(&line) {
            Ok(command) => command,
            Err(error) => {
                eprintln!("Invalid input: {error}");
                return;
            }
        };
        match command {
            Command::SyncMode {
                role,
                lock,
                leader,
                leader_display,
                adaptation,
                sync_keyboard,
                sync_text,
                sync_tool_keys,
            } => {
                if role == sync::SyncRole::Follower
                    && (self.scripts.is_recording() || self.scripts.is_playing())
                {
                    sync::notify_sync_busy(
                        "Cannot become a sync follower while recording or playing a script",
                    );
                    return;
                }
                if self.sync.set_mode(
                    role,
                    lock,
                    leader,
                    leader_display,
                    adaptation,
                    sync_keyboard,
                    sync_text,
                    sync_tool_keys,
                ) {
                    self.state.release().await;
                }
                return;
            }
            Command::SyncInput { seq, event } => {
                let rotation = self.rotation.load(Ordering::Relaxed);
                if let Some(adapted) = self.sync.accept_follower_input(seq, &event, rotation)
                    && let Err(error) = script::execute_event(
                        &mut self.state,
                        &self.client,
                        &self.device,
                        self.panel,
                        &self.rotation,
                        &adapted,
                    )
                    .await
                {
                    eprintln!("Sync input failed: {error:#}");
                }
                return;
            }
            Command::SyncRelease => {
                if self.sync.is_active() {
                    self.state.release().await;
                }
                return;
            }
            _ => {}
        }
        // Script control commands are handled before any device input; pause,
        // stop and cancel may ask us to release held inputs.
        if script::is_script_command(&command) {
            if self.sync.is_follower()
                && matches!(
                    command,
                    Command::ScriptRecordStart | Command::ScriptPlayStart { .. }
                )
            {
                let op = if matches!(command, Command::ScriptRecordStart) {
                    "record"
                } else {
                    "play"
                };
                eprintln!(
                    "MIKO_SCRIPT:{}",
                    json!({
                        "op": op,
                        "state": "failed",
                        "code": "script.busy",
                        "message": "Cannot record or play a script while following input sync"
                    })
                );
                return;
            }
            let outcome = self.scripts.handle_command(&command, Instant::now());
            if outcome.release {
                self.state.release().await;
                self.sync.emit_leader_release();
            }
            return;
        }
        // While a script plays back or this bridge is a locked sync follower,
        // direct user input is ignored.
        if self.scripts.ignores_user_input(&command) || self.sync.ignores_user_input(&command) {
            return;
        }
        match command {
            Command::Rotate { direction } => {
                if self.scripts.is_playing() || self.sync.is_locked_follower() {
                    return;
                }
                let current = self.physical_rotation.load(Ordering::Relaxed) as i32;
                let angle = (current + direction.signum()).rem_euclid(4) * 90;
                if let Err(e) = self
                    .client
                    .call(
                        "sensor.rotate",
                        json!({"device":self.device, "angle":angle}),
                    )
                    .await
                {
                    eprintln!("Rotate failed: {e}");
                }
            }
            Command::ToolKey { key } => {
                if self.scripts.is_playing() || self.sync.is_locked_follower() {
                    return;
                }
                if [
                    "back",
                    "home",
                    "recents",
                    "volume_up",
                    "volume_down",
                    "power",
                ]
                .contains(&key.as_str())
                {
                    self.scripts.record_tool_key(&key, Instant::now());
                    self.sync.emit_leader_tool_key(&key);
                    if let Err(e) = self
                        .client
                        .call("key.press", json!({"device":self.device, "key":key}))
                        .await
                    {
                        eprintln!("Key failed: {e}");
                    }
                }
            }
            Command::StartRecording { path, audio } => {
                let path = std::path::PathBuf::from(path);
                if !path.is_absolute() || path.exists() {
                    eprintln!(
                        "MIKO_RECORD:{}",
                        json!({"state":"failed", "code":RECORDING_INVALID_PATH.code, "message":RECORDING_INVALID_PATH.message})
                    );
                } else {
                    let client = Arc::clone(&self.client);
                    let device = self.device.clone();
                    tokio::spawn(async move {
                        let announced = std::sync::atomic::AtomicBool::new(false);
                        let result = client.run("media.record", json!({"device":device,"path":path,"audio":audio}), |_| {
                            if !announced.swap(true, Ordering::Relaxed) {
                                eprintln!("MIKO_RECORD:{}", json!({"state":"recording", "code":RECORDING_STARTED.code, "message":RECORDING_STARTED.message}));
                            }
                        }).await;
                        match result {
                            Ok(value) => {
                                let notice = if audio
                                    && (value["audio"] == false || value["audio_received"] == false)
                                {
                                    RECORDING_SAVED_NO_AUDIO
                                } else {
                                    RECORDING_SAVED
                                };
                                eprintln!(
                                    "MIKO_RECORD:{}",
                                    json!({"state":"finished","code":notice.code,"message":notice.message,"result":value})
                                );
                            }
                            Err(error) => eprintln!(
                                "MIKO_RECORD:{}",
                                json!({"state":"failed","code":RECORDING_FAILED,"message":format!("Recording failed: {error}")})
                            ),
                        }
                    });
                }
            }
            Command::StopRecording => {
                let client = Arc::clone(&self.client);
                let device = self.device.clone();
                tokio::spawn(async move {
                    if let Err(error) = client
                        .call("media.record_stop", json!({"device":device}))
                        .await
                    {
                        eprintln!(
                            "MIKO_RECORD:{}",
                            json!({"state":"stop_failed", "code":RECORDING_STOP_FAILED, "message":format!("Could not stop recording: {error}")})
                        );
                    }
                });
            }
            command @ (Command::Screenshot { .. } | Command::SendFile { .. }) => {
                let screenshot = matches!(command, Command::Screenshot { .. });
                let path = match command {
                    Command::Screenshot { path } | Command::SendFile { path } => path,
                    _ => return,
                };
                let client = Arc::clone(&self.client);
                let device = self.device.clone();
                tokio::spawn(async move {
                    match run_file_operation(&client, &device, &path, screenshot).await {
                        Ok(saved) => eprintln!(
                            "MIKO_OPERATION:{}",
                            json!({"ok":true,"code":saved.code,"message":saved.message,"path":path})
                        ),
                        Err(error) => eprintln!(
                            "MIKO_OPERATION:{}",
                            json!({"ok":false,"code":error.code(),"message":error.message()})
                        ),
                    }
                });
            }
            Command::AppInspect { path } => {
                let client = Arc::clone(&self.client);
                tokio::spawn(async move {
                    match client.call("app.inspect", json!({"apk": path})).await {
                        Ok(value) => eprintln!(
                            "MIKO_APP:{}",
                            json!({"op":"inspect","ok":true,"code":APP_INSPECTED,"apk":path,"package":value.get("package"),"label":value.get("label")})
                        ),
                        Err(error) => eprintln!(
                            "MIKO_APP:{}",
                            json!({"op":"inspect","ok":false,"code":APP_INSPECT_FAILED,"apk":path,"message":format!("{error}")})
                        ),
                    }
                });
            }
            Command::AppUninstall { package } => {
                let client = Arc::clone(&self.client);
                let device = self.device.clone();
                tokio::spawn(async move {
                    match client
                        .call("app.uninstall", json!({"device":device,"package":package}))
                        .await
                    {
                        Ok(_) => eprintln!(
                            "MIKO_APP:{}",
                            json!({"op":"uninstall","ok":true,"code":APP_UNINSTALLED,"package":package})
                        ),
                        Err(error) => eprintln!(
                            "MIKO_APP:{}",
                            json!({"op":"uninstall","ok":false,"code":APP_UNINSTALL_FAILED,"package":package,"message":format!("{error}")})
                        ),
                    }
                });
            }
            command => {
                self.scripts.record_user_command(&command, Instant::now());
                self.sync.emit_leader_command(&command);
                if let Err(e) = self
                    .state
                    .command(command, self.panel, &self.rotation)
                    .await
                {
                    eprintln!("Input failed: {e:#}");
                }
            }
        }
    }
    async fn release(&mut self) {
        self.state.release().await;
    }
    fn next_tick(&self) -> Option<Instant> {
        self.scripts.next_tick()
    }
    async fn tick(&mut self, now: Instant) {
        let outcome = self.scripts.tick(now);
        for event in outcome.events {
            self.sync.emit_leader_event(&event);
            if let Err(error) = script::execute_event(
                &mut self.state,
                &self.client,
                &self.device,
                self.panel,
                &self.rotation,
                &event,
            )
            .await
            {
                eprintln!("Script playback event failed: {error:#}");
            }
        }
        // Release after the last injected events, so a script that ends with a
        // press/release pair does not leave the device held.
        if outcome.release {
            self.state.release().await;
            self.sync.emit_leader_release();
        }
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
        bail!("usage: miko-swiftui-bridge DEVICE PANEL_WIDTH PANEL_HEIGHT [QUALITY]");
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
    if std::env::var("MIKO_PLAYER_FIXTURE").is_ok_and(|value| value == "1") {
        return player_fixture(width, height).await;
    }
    let scheduling = player_input::Scheduling::parse(
        &std::env::var("MIKO_PLAYER_INPUT_SCHEDULER").unwrap_or_else(|_| "fifo".into()),
    )
    .context("MIKO_PLAYER_INPUT_SCHEDULER must be fifo or inline")?;
    let paths = MikoPaths::discover()?;
    let client =
        Arc::new(miko_client::Client::connect(&paths.socket(), "miko-swiftui-bridge").await?);
    let info: ConnectInfo = client
        .call_as("device.connect_info", json!({"device":args[1]}))
        .await?;
    let mapping_path = paths
        .data
        .join("keymaps")
        .join(format!("{}.json", info.device));
    eprintln!("MIKO_MAPPING_PATH:{}", json!({"path":mapping_path}));
    let endpoint =
        tonic::transport::Endpoint::from_shared(format!("http://{}", info.grpc_endpoint))?
            .connect_timeout(Duration::from_secs(5))
            .tcp_nodelay(true);
    let channel = endpoint.clone().connect().await?;
    let mut ctl = miko_proto::clients(channel, BearerToken::new(&info.grpc_token)?).0;
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
        &std::env::var("MIKO_PLAYER_FRAME_TRANSPORT").unwrap_or_else(|_| "shared".into()),
    )
    .context("MIKO_PLAYER_FRAME_TRANSPORT must be shared or legacy")?;
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
    // A cloned Controller shares its HTTP/2 connection. Use another actual
    // connection in FIFO mode so screenshot flow control cannot hold up small
    // input/clipboard responses, even with continuously changing frames.
    let input_ctl = if scheduling == player_input::Scheduling::Fifo {
        miko_proto::clients(
            endpoint.connect().await?,
            BearerToken::new(&info.grpc_token)?,
        )
        .0
    } else {
        ctl.clone()
    };
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
        state: InputState::new(GrpcInput::new(input_ctl)),
        client,
        device: args[1].clone(),
        panel: (width, height),
        rotation: Arc::clone(&rotation),
        physical_rotation: Arc::clone(&physical_rotation),
        scripts: script::ScriptManager::new(
            paths.data.clone(),
            args[1].clone(),
            frame_width,
            frame_height,
        ),
        sync: sync::BridgeSync::new(width, height),
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
                        match handler.next_tick() {
                            Some(deadline) => {
                                tokio::select! {
                                    running = pump.step() => if !running { break; },
                                    line = input_rx.recv() => match line {
                                        Some(line) => handler.handle(line).await, None => break,
                                    },
                                    _ = tokio::time::sleep_until(tokio::time::Instant::from_std(deadline)) => {
                                        handler.tick(Instant::now()).await;
                                    }
                                }
                            }
                            None => {
                                tokio::select! {
                                    running = pump.step() => if !running { break; },
                                    line = input_rx.recv() => match line {
                                        Some(line) => handler.handle(line).await, None => break,
                                    }
                                }
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
                "MIKO_OPERATION:",
                "code",
                "preview.unsupported",
            ),
            (
                r#"{"type":"rotate","direction":1}"#,
                "MIKO_OPERATION:",
                "code",
                "preview.unsupported",
            ),
            (
                r#"{"type":"start_recording","path":"/tmp/preview.mp4"}"#,
                "MIKO_RECORD:",
                "state",
                "failed",
            ),
            (
                r#"{"type":"stop_recording"}"#,
                "MIKO_RECORD:",
                "state",
                "failed",
            ),
            (
                r#"{"type":"app_inspect","path":"/tmp/preview.apk"}"#,
                "MIKO_APP:",
                "op",
                "inspect",
            ),
            (
                r#"{"type":"app_uninstall","package":"example.test"}"#,
                "MIKO_APP:",
                "op",
                "uninstall",
            ),
        ] {
            let (actual, value) = fixture_reply(command).unwrap();
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
            MODULE_INSTALLED,
            FILE_SENT,
            RECORDING_INVALID_PATH,
            RECORDING_STARTED,
            RECORDING_SAVED,
            RECORDING_SAVED_NO_AUDIO,
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
    type CommandPredicate = fn(&Command) -> bool;

    #[test]
    fn script_commands_parse() {
        let cases: [(&str, CommandPredicate); 12] = [
            (r#"{"type":"script_record_start"}"#, |c| {
                matches!(c, Command::ScriptRecordStart)
            }),
            (r#"{"type":"script_record_pause"}"#, |c| {
                matches!(c, Command::ScriptRecordPause)
            }),
            (r#"{"type":"script_record_resume"}"#, |c| {
                matches!(c, Command::ScriptRecordResume)
            }),
            (r#"{"type":"script_record_cancel"}"#, |c| {
                matches!(c, Command::ScriptRecordCancel)
            }),
            (r#"{"type":"script_list"}"#, |c| {
                matches!(c, Command::ScriptList)
            }),
            (r#"{"type":"script_play_pause"}"#, |c| {
                matches!(c, Command::ScriptPlayPause)
            }),
            (r#"{"type":"script_play_resume"}"#, |c| {
                matches!(c, Command::ScriptPlayResume)
            }),
            (r#"{"type":"script_play_stop"}"#, |c| {
                matches!(c, Command::ScriptPlayStop)
            }),
            (
                r#"{"type":"script_delete","id":"00000000-0000-0000-0000-000000000000"}"#,
                |c| matches!(c, Command::ScriptDelete { .. }),
            ),
            (
                r#"{"type":"script_rename","id":"00000000-0000-0000-0000-000000000000","name":"daily"}"#,
                |c| matches!(c, Command::ScriptRename { .. }),
            ),
            (r#"{"type":"script_import","path":"/tmp/a.json"}"#, |c| {
                matches!(c, Command::ScriptImport { .. })
            }),
            (
                r#"{"type":"script_export","id":"00000000-0000-0000-0000-000000000000","path":"/tmp/b.json"}"#,
                |c| matches!(c, Command::ScriptExport { .. }),
            ),
        ];
        for (json, ok) in cases {
            let command: Command = serde_json::from_str(json).expect("script command parses");
            assert!(ok(&command), "unexpected variant for {json}");
        }
        let stop: Command =
            serde_json::from_str(r#"{"type":"script_record_stop","name":"daily"}"#).unwrap();
        assert!(matches!(stop, Command::ScriptRecordStop { ref name } if name == "daily"));
        let play: Command = serde_json::from_str(
            r#"{"type":"script_play_start","id":"00000000-0000-0000-0000-000000000000"}"#,
        )
        .unwrap();
        assert!(matches!(
            play,
            Command::ScriptPlayStart { options: None, .. }
        ));
        let play_with_options: Command = serde_json::from_str(
            r#"{"type":"script_play_start","id":"00000000-0000-0000-0000-000000000000","options":{"mode":"infinite","speed":2.0}}"#,
        )
        .unwrap();
        assert!(matches!(
            play_with_options,
            Command::ScriptPlayStart {
                options: Some(_),
                ..
            }
        ));
    }

    #[test]
    fn fixture_script_commands_report_preview_unsupported() {
        for command in [
            r#"{"type":"script_record_start"}"#,
            r#"{"type":"script_play_stop"}"#,
            r#"{"type":"script_list"}"#,
        ] {
            let (prefix, value) = fixture_reply(command).unwrap();
            assert_eq!(prefix, "MIKO_SCRIPT:");
            assert_eq!(value["op"], "error");
            assert_eq!(value["code"], PREVIEW_UNSUPPORTED.code);
        }
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

    #[test]
    fn start_recording_command_defaults_audio_to_true() {
        let legacy: Command =
            serde_json::from_str(r#"{"type":"start_recording","path":"/tmp/a.mp4"}"#).unwrap();
        assert!(matches!(
            legacy,
            Command::StartRecording { ref path, audio: true } if path == "/tmp/a.mp4"
        ));
        let muted: Command =
            serde_json::from_str(r#"{"type":"start_recording","path":"/tmp/b.mp4","audio":false}"#)
                .unwrap();
        assert!(matches!(
            muted,
            Command::StartRecording { ref path, audio: false } if path == "/tmp/b.mp4"
        ));
    }

    #[test]
    fn sync_commands_parse_contract() {
        let mode: Command = serde_json::from_str(
            r#"{"type":"sync_mode","role":"follower","lock":true,"leader":"L1","leader_display":{"width":1080,"height":2400},"adaptation":"stretch"}"#,
        )
        .unwrap();
        assert!(matches!(
            mode,
            Command::SyncMode {
                role: sync::SyncRole::Follower,
                lock: true,
                leader: Some(ref l),
                leader_display: Some(miko_sync::DisplaySize {
                    width: 1080,
                    height: 2400
                }),
                adaptation: miko_sync::Adaptation::Stretch,
                sync_keyboard: true,
                sync_text: true,
                sync_tool_keys: true,
            } if l == "L1"
        ));

        let input: Command = serde_json::from_str(
            r#"{"type":"sync_input","seq":42,"event":{"type":"touch","x":0.51,"y":0.37,"down":true}}"#,
        )
        .unwrap();
        assert!(matches!(
            input,
            Command::SyncInput {
                seq: Some(42),
                event: miko_automation::Event::Touch {
                    x,
                    y,
                    down: true,
                },
            } if (x - 0.51).abs() < 1e-9 && (y - 0.37).abs() < 1e-9
        ));

        let release: Command = serde_json::from_str(r#"{"type":"sync_release"}"#).unwrap();
        assert!(matches!(release, Command::SyncRelease));
        assert!(fixture_reply(r#"{"type":"sync_mode","role":"off"}"#).is_none());
        assert!(fixture_reply(r#"{"type":"sync_release"}"#).is_none());
    }
}
