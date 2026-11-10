//! Private prototype transport: NDJSON commands on stdin; bounded RGBA frames on stdout.
use anyhow::{Context, Result, bail};
use jidr_core::{ConnectInfo, JidrPaths};
use jidr_proto::{BearerToken, Controller, control as pb};
use serde::Deserialize;
use serde_json::json;
use std::collections::{HashMap, HashSet};
use std::io::{BufRead, Write};
use std::sync::{
    Arc,
    atomic::{AtomicU32, Ordering},
    mpsc,
};
use std::time::Duration;
use tokio::sync::mpsc as async_mpsc;

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
}

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

async fn send_chord(ctl: &mut Controller, code: i32) -> Result<()> {
    for (key_code, down) in [(29, true), (code, true), (code, false), (29, false)] {
        let event = pb::KeyboardEvent {
            code_type: pb::keyboard_event::KeyCodeType::Evdev as i32,
            event_type: if down {
                pb::keyboard_event::KeyEventType::Keydown as i32
            } else {
                pb::keyboard_event::KeyEventType::Keyup as i32
            },
            key_code,
            ..Default::default()
        };
        if let Err(error) = ctl.send_key(event).await {
            let _ = ctl
                .send_key(pb::KeyboardEvent {
                    code_type: pb::keyboard_event::KeyCodeType::Evdev as i32,
                    event_type: pb::keyboard_event::KeyEventType::Keyup as i32,
                    key_code: 29,
                    ..Default::default()
                })
                .await;
            return Err(error.into());
        }
    }
    Ok(())
}

#[derive(Default)]
struct HeldInputs {
    touch: Option<(i32, i32)>,
    keys: HashSet<String>,
    mapped: HashMap<i32, (i32, i32)>,
}

async fn release_inputs(ctl: &mut Controller, held: &mut HeldInputs) {
    if let Some((x, y)) = held.touch.take() {
        let _ = tokio::time::timeout(
            Duration::from_secs(1),
            ctl.send_touch(pb::TouchEvent {
                touches: vec![pb::Touch {
                    x,
                    y,
                    identifier: 1,
                    pressure: 0,
                    ..Default::default()
                }],
                display: 0,
            }),
        )
        .await;
    }
    for (id, (x, y)) in held.mapped.drain() {
        let _ = tokio::time::timeout(
            Duration::from_secs(1),
            ctl.send_touch(pb::TouchEvent {
                touches: vec![pb::Touch {
                    x,
                    y,
                    identifier: id,
                    pressure: 0,
                    ..Default::default()
                }],
                display: 0,
            }),
        )
        .await;
    }
    for key in held.keys.drain() {
        let _ = tokio::time::timeout(
            Duration::from_secs(1),
            ctl.send_key(pb::KeyboardEvent {
                code_type: pb::keyboard_event::KeyCodeType::Usb as i32,
                event_type: pb::keyboard_event::KeyEventType::Keyup as i32,
                key,
                ..Default::default()
            }),
        )
        .await;
    }
}

async fn input(
    ctl: &mut Controller,
    command: Command,
    panel: (u32, u32),
    rotation: &AtomicU32,
    held: &mut HeldInputs,
) -> Result<()> {
    match command {
        Command::Touch { x, y, down } => {
            let Some((x, y)) =
                panel_point(x, y, panel.0, panel.1, rotation.load(Ordering::Relaxed))
            else {
                return Ok(());
            };
            ctl.send_touch(pb::TouchEvent {
                touches: vec![pb::Touch {
                    x,
                    y,
                    identifier: 1,
                    pressure: if down { 100 } else { 0 },
                    touch_major: if down { 5 } else { 0 },
                    expiration: pb::touch::EventExpiration::NeverExpire as i32,
                    ..Default::default()
                }],
                display: 0,
            })
            .await?;
            held.touch = down.then_some((x, y));
        }
        Command::MappedTouch { id, x, y, down } => {
            if !(3..=9).contains(&id) {
                bail!("invalid mapped touch id");
            }
            let point = if down {
                panel_point(x, y, panel.0, panel.1, rotation.load(Ordering::Relaxed))
            } else {
                held.mapped.get(&id).copied()
            };
            let Some((x, y)) = point else { return Ok(()) };
            ctl.send_touch(pb::TouchEvent {
                touches: vec![pb::Touch {
                    x,
                    y,
                    identifier: id,
                    pressure: if down { 100 } else { 0 },
                    touch_major: if down { 5 } else { 0 },
                    expiration: pb::touch::EventExpiration::NeverExpire as i32,
                    ..Default::default()
                }],
                display: 0,
            })
            .await?;
            if down {
                held.mapped.insert(id, (x, y));
            } else {
                held.mapped.remove(&id);
            }
        }
        Command::Key { key, down } => {
            if key.len() > 64 || key.is_empty() {
                bail!("invalid key");
            }
            ctl.send_key(pb::KeyboardEvent {
                code_type: pb::keyboard_event::KeyCodeType::Usb as i32,
                event_type: if down {
                    pb::keyboard_event::KeyEventType::Keydown as i32
                } else {
                    pb::keyboard_event::KeyEventType::Keyup as i32
                },
                key: key.clone(),
                ..Default::default()
            })
            .await?;
            if down {
                held.keys.insert(key);
            } else {
                held.keys.remove(&key);
            }
        }
        Command::Text { text } | Command::Paste { text } => {
            if text.len() > 1024 * 1024 {
                bail!("text too large");
            }
            ctl.set_clipboard(pb::ClipData { text }).await?;
            send_chord(ctl, 47).await?;
        }
        Command::Copy { request_id } | Command::Cut { request_id } => {
            // Subscribe before the chord so a stale clipboard is never treated as a new copy.
            let mut stream = tokio::time::timeout(Duration::from_secs(2), ctl.stream_clipboard(()))
                .await??
                .into_inner();
            let _ = tokio::time::timeout(Duration::from_secs(2), stream.message()).await??;
            send_chord(
                ctl,
                if matches!(command, Command::Copy { .. }) {
                    46
                } else {
                    45
                },
            )
            .await?;
            if let Ok(Ok(Some(clip))) =
                tokio::time::timeout(Duration::from_millis(1500), stream.message()).await
            {
                // A distinct side channel avoids putting clipboard text into frame packets.
                eprintln!(
                    "JIDR_CLIPBOARD:{}",
                    json!({"request_id": request_id, "text": clip.text})
                );
            }
        }
        Command::SelectAll => send_chord(ctl, 30).await?,
        Command::Rotate { .. }
        | Command::ToolKey { .. }
        | Command::Screenshot { .. }
        | Command::SendFile { .. }
        | Command::StartRecording { .. }
        | Command::StopRecording => {
            bail!("toolbar commands must be handled by the daemon")
        }
    }
    Ok(())
}

fn is_apk(path: &str) -> bool {
    std::path::Path::new(path)
        .extension()
        .is_some_and(|ext| ext.eq_ignore_ascii_case("apk"))
}

async fn run_file_operation(
    client: &jidr_client::Client,
    device: &str,
    path: &str,
    screenshot: bool,
) -> Result<()> {
    let path = std::path::Path::new(path);
    if !path.is_absolute() || path.file_name().is_none() {
        bail!("请选择有效的本地文件路径");
    }
    if screenshot {
        client
            .call("media.screenshot", json!({"device":device,"path":path}))
            .await?;
    } else {
        if !path.is_file() {
            bail!("请选择本地文件，不支持文件夹");
        }
        if is_apk(&path.to_string_lossy()) {
            client
                .call(
                    "file.install",
                    json!({"device":device,"apk":path,"replace":true}),
                )
                .await?;
        } else {
            client
                .call("file.push", json!({"device":device,"local":path}))
                .await?;
        }
    }
    Ok(())
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

/// `JIDR_PLAYER_FIXTURE=1` replaces the gRPC stream with three identical
/// synthetic frames and one fixed diagnostic line. The normal path below is
/// untouched; only this process sees the variable.
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
    // Drain UI commands until the player closes stdin so the lifecycle matches
    // the real bridge. Toolbar commands are accepted and ignored.
    while input_rx.recv().await.is_some() {}
    Ok(())
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
    let mut frames = ctl
        .stream_screenshot(pb::ImageFormat {
            format: pb::image_format::ImgFormat::Rgba8888 as i32,
            width: frame_width,
            height: frame_height,
            ..Default::default()
        })
        .await?
        .into_inner();
    let (frame_tx, frame_rx) = mpsc::sync_channel::<Vec<u8>>(1);
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
    let mut held = HeldInputs::default();
    let mut latest_frame: Option<(u32, u32, u32, Vec<u8>)> = None;
    let mut orientation_tick = tokio::time::interval(Duration::from_millis(150));
    loop {
        tokio::select! {
            _ = orientation_tick.tick() => {
                let logical = logical_rotation.load(Ordering::Relaxed);
                if logical < 4 && logical != rotation.load(Ordering::Relaxed)
                    && let Some((width, height, pose, pixels)) = &latest_frame
                    && let Some((shown, packet)) = oriented_packet(*width, *height, *pose, logical, pixels)
                    && frame_tx.try_send(packet).is_ok() {
                    rotation.store(shown, Ordering::Relaxed);
                }
            },
            message = frames.message() => match message { Ok(Some(image)) => {
                if let Some(format) = image.format {
                    let pose = format.rotation.map_or(0, |r| r.rotation.rem_euclid(4) as u32);
                    physical_rotation.store(pose, Ordering::Relaxed);
                    latest_frame = Some((format.width, format.height, pose, image.image));
                    if let Some((w, h, q, pixels)) = &latest_frame
                        && let Some((shown, packet)) = oriented_packet(*w, *h, *q, logical_rotation.load(Ordering::Relaxed), pixels)
                        && frame_tx.try_send(packet).is_ok() {
                        rotation.store(shown, Ordering::Relaxed);
                    }
                }
            }, Ok(None) => break, Err(error) => { eprintln!("Frame stream failed: {error}"); break; } },
            line = input_rx.recv() => match line { Some(line) => match serde_json::from_str::<Command>(&line) { Ok(Command::Rotate { direction }) => { let current = physical_rotation.load(Ordering::Relaxed) as i32; let angle = (current + direction.signum()).rem_euclid(4) * 90; if let Err(e) = client.call("sensor.rotate", json!({"device":args[1], "angle":angle})).await { eprintln!("Rotate failed: {e}"); } }, Ok(Command::ToolKey { key }) => { if ["back", "home", "recents", "volume_up", "volume_down", "power"].contains(&key.as_str()) && let Err(e) = client.call("key.press", json!({"device":args[1], "key":key})).await { eprintln!("Key failed: {e}"); } }, Ok(Command::StartRecording { path }) => {
                let path = std::path::PathBuf::from(path);
                if !path.is_absolute() || path.exists() {
                    eprintln!("JIDR_RECORD:{}", json!({"state":"failed", "message":"录屏路径无效或文件已存在"}));
                } else {
                    let client = Arc::clone(&client);
                    let device = args[1].clone();
                    tokio::spawn(async move {
                        let announced = std::sync::atomic::AtomicBool::new(false);
                        let result = client.run("media.record", json!({"device":device,"path":path}), |_| {
                            if !announced.swap(true, Ordering::Relaxed) {
                                eprintln!("JIDR_RECORD:{}", json!({"state":"recording", "message":"正在录屏"}));
                            }
                        }).await;
                        match result {
                            Ok(value) => eprintln!("JIDR_RECORD:{}", json!({"state":"finished","message":"录屏已保存","result":value})),
                            Err(error) => eprintln!("JIDR_RECORD:{}", json!({"state":"failed","message":format!("录屏失败：{error}")})),
                        }
                    });
                }
            }, Ok(Command::StopRecording) => {
                let client = Arc::clone(&client); let device = args[1].clone();
                tokio::spawn(async move {
                    if let Err(error) = client.call("media.record_stop", json!({"device":device})).await {
                        eprintln!("JIDR_RECORD:{}", json!({"state":"stop_failed", "message":format!("停止录屏失败：{error}")}));
                    }
                });
            }, Ok(command @ (Command::Screenshot { .. } | Command::SendFile { .. })) => {
                let screenshot = matches!(command, Command::Screenshot { .. });
                let path = match command { Command::Screenshot { path } | Command::SendFile { path } => path, _ => continue };
                let client = Arc::clone(&client);
                let device = args[1].clone();
                tokio::spawn(async move {
                    if let Err(error) = run_file_operation(&client, &device, &path, screenshot).await {
                        eprintln!("JIDR_OPERATION:{}", json!({"ok":false,"message":format!("{error:#}")}));
                    } else {
                        let label = if screenshot { "截图已保存" } else if is_apk(&path) { "应用已安装" } else { "文件已发送到设备下载目录" };
                        eprintln!("JIDR_OPERATION:{}", json!({"ok":true,"message":label,"path":path}));
                    }
                });
            }, Ok(command) => if let Err(e) = input(&mut ctl,command,(width,height),&rotation,&mut held).await { eprintln!("Input failed: {e:#}"); }, Err(e) => eprintln!("Invalid input: {e}") }, None => break },
        }
    }
    release_inputs(&mut ctl, &mut held).await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
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
