//! Screenshots (gRPC `getScreenshot` → PNG) and screen recording: the
//! daemon streams frames from the emulator and encodes MP4/H.264 at a
//! constant frame rate (D13; no 180 s cap), with the device's audio as AAC
//! (#28) from gRPC `streamAudio`.

pub mod audio;
#[cfg(target_os = "macos")]
pub mod mp4;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
#[cfg(target_os = "macos")]
use std::time::Instant;

use miko_core::provider::{CallCtx, CommandSpec, DeviceParams, parse_params};
use miko_core::{MikoError, MikoResult};
use miko_proto::control as pb;
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::device::{Target, grpc_err, target};

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ShotParams {
    pub device: String,
    /// Where to save the PNG (default `~/Pictures/Miko/<device> <time>.png`).
    #[serde(default)]
    pub path: Option<PathBuf>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RecordParams {
    pub device: String,
    /// Where to save the MP4 (default `~/Movies/Miko/<device> <time>.mp4`).
    #[serde(default)]
    pub path: Option<PathBuf>,
    /// Stop on its own after this many seconds (default 3600).
    #[serde(default)]
    pub max_seconds: Option<u64>,
    /// Frames per second (default 30).
    #[serde(default)]
    pub fps: Option<u32>,
    /// Also record the device's audio (AAC; default true). If the emulator's
    /// audio stream fails, the recording goes on without it.
    #[serde(default)]
    pub audio: Option<bool>,
}

#[derive(Debug, Default)]
pub struct Recordings(Mutex<HashMap<Uuid, Arc<AtomicBool>>>);

pub fn specs() -> Vec<CommandSpec> {
    vec![
        CommandSpec::new::<ShotParams>("media.screenshot", "Save a PNG of the screen"),
        CommandSpec::new::<RecordParams>(
            "media.record",
            "Record the screen and the device's audio to MP4 (H.264, AAC) until media.record_stop or max_seconds",
        )
        .long_running(),
        CommandSpec::new::<DeviceParams>(
            "media.record_stop",
            "Stop the screen recording and save it",
        ),
    ]
}

/// `<dir>/<name> 2026-10-13 at 14.02.07.<ext>`, made unique.
pub fn default_path(dir: &Path, name: &str, ext: &str) -> PathBuf {
    let stamp = chrono::Local::now().format("%Y-%m-%d at %H.%M.%S");
    let safe: String = name
        .chars()
        .map(|c| {
            if matches!(c, '/' | ':' | '\\' | '"') || c.is_control() {
                '-'
            } else {
                c
            }
        })
        .collect();
    let mut p = dir.join(format!("{safe} {stamp}.{ext}"));
    let mut n = 2;
    while p.exists() {
        p = dir.join(format!("{safe} {stamp} {n}.{ext}"));
        n += 1;
    }
    p
}

fn home_dir(sub: &str) -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(std::env::temp_dir)
        .join(sub)
        .join("miko")
}

/// Recording size: the device's, long side capped at 1280, even sides.
pub fn record_size(w: u32, h: u32) -> (u32, u32) {
    let long = w.max(h).max(1);
    let k = (1280.0 / f64::from(long)).min(1.0);
    let (w, h) = ((f64::from(w) * k) as u32, (f64::from(h) * k) as u32);
    (w & !1, h & !1)
}

#[cfg(target_os = "macos")]
async fn lcd_size(t: &Target) -> MikoResult<(u32, u32)> {
    let st = t
        .grpc()
        .await?
        .get_status(())
        .await
        .map_err(grpc_err("getStatus"))?
        .into_inner();
    // Newer SDK protos mark `hardwareConfig` deprecated; the build uses the
    // installed SDK's protos when there is one, so allow it either way.
    #[allow(deprecated)]
    let get = |k: &str| {
        st.hardware_config
            .as_ref()
            .and_then(|c| c.entry.iter().find(|e| e.key == k))
            .and_then(|e| e.value.parse::<u32>().ok())
    };
    match (get("hw.lcd.width"), get("hw.lcd.height")) {
        (Some(w), Some(h)) => Ok((w, h)),
        _ => Err(MikoError::sdk("the emulator didn't report its screen size")),
    }
}

pub async fn call(
    ctx: &CallCtx,
    recs: &Recordings,
    method: &str,
    params: Value,
) -> MikoResult<Value> {
    match method {
        "media.screenshot" => {
            let p: ShotParams = parse_params(params)?;
            let t = target(ctx, &p.device).await?;
            let img = t
                .grpc()
                .await?
                .get_screenshot(pb::ImageFormat {
                    format: pb::image_format::ImgFormat::Png as i32,
                    ..Default::default()
                })
                .await
                .map_err(grpc_err("getScreenshot"))?
                .into_inner();
            let path = p
                .path
                .unwrap_or_else(|| default_path(&home_dir("Pictures"), &t.device.name, "png"));
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir).map_err(|e| {
                    MikoError::usage(format!("cannot create {}: {e}", dir.display()))
                })?;
            }
            std::fs::write(&path, &img.image)
                .map_err(|e| MikoError::usage(format!("cannot write {}: {e}", path.display())))?;
            let (w, h) = img.format.map(|f| (f.width, f.height)).unwrap_or((0, 0));
            Ok(json!({ "path": path, "width": w, "height": h }))
        }
        "media.record" => {
            let p: RecordParams = parse_params(params)?;
            let t = target(ctx, &p.device).await?;
            let fps = p.fps.unwrap_or(30).clamp(1, 60);
            let max = Duration::from_secs(p.max_seconds.unwrap_or(3600).max(1));
            let path = p
                .path
                .unwrap_or_else(|| default_path(&home_dir("Movies"), &t.device.name, "mp4"));
            if path.exists() {
                return Err(MikoError::usage(format!(
                    "{} already exists",
                    path.display()
                )));
            }
            if let Some(dir) = path.parent() {
                std::fs::create_dir_all(dir).map_err(|e| {
                    MikoError::usage(format!("cannot create {}: {e}", dir.display()))
                })?;
            }
            let stop = Arc::new(AtomicBool::new(false));
            if let Ok(mut m) = recs.0.lock() {
                if m.contains_key(&t.device.id) {
                    return Err(MikoError::busy(format!(
                        "{} is already recording",
                        t.device.name
                    )));
                }
                m.insert(t.device.id, stop.clone());
            }
            let audio = p.audio.unwrap_or(true);
            let r = record(ctx, &t, &path, fps, max, audio, stop).await;
            if let Ok(mut m) = recs.0.lock() {
                m.remove(&t.device.id);
            }
            r
        }
        "media.record_stop" => {
            let p: DeviceParams = parse_params(params)?;
            let d = ctx.daemon.device(&p.device).await?;
            let flag = recs.0.lock().ok().and_then(|m| m.get(&d.id).cloned());
            match flag {
                Some(f) => {
                    f.store(true, Ordering::Relaxed);
                    Ok(json!({ "stopping": true }))
                }
                None => Err(MikoError::not_found(format!("{} isn't recording", d.name))),
            }
        }
        _ => Err(MikoError::usage(format!("unknown method {method}"))),
    }
}

/// The latest frame from the stream.
#[cfg(target_os = "macos")]
#[derive(Default)]
struct Latest {
    frame: Option<(u32, u32, Vec<u8>)>,
}

/// Copies frames into `slot` until the stream ends, then sets `ended`: when
/// the device stops or crashes the encoder finishes the file instead of
/// repeating the last frame until `max_seconds`.
#[cfg(target_os = "macos")]
async fn pump<S>(mut frames: S, slot: Arc<Mutex<Latest>>, ended: Arc<AtomicBool>)
where
    S: tokio_stream::Stream<Item = Result<pb::Image, tonic::Status>> + Unpin,
{
    use tokio_stream::StreamExt as _;
    while let Some(Ok(img)) = frames.next().await {
        if let (Some(f), false) = (img.format, img.image.is_empty())
            && let Ok(mut l) = slot.lock()
        {
            l.frame = Some((f.width, f.height, img.image));
        }
    }
    ended.store(true, Ordering::Relaxed);
}

/// Starts the device's audio for a recording; `None` (video-only, with a
/// warning) when the device starts with `-no-audio`.
#[cfg(target_os = "macos")]
fn start_audio(t: &Target, stop: Arc<AtomicBool>) -> Option<audio::Feed> {
    let name = t.device.name.clone();
    if t.device.launch.audio == Some(false) {
        tracing::warn!("recording {name} without audio: the device starts with -no-audio");
        return None;
    }
    let (port, token) = (t.info.grpc_port, t.info.grpc_token.clone());
    let open = async move {
        miko_backend::grpc::connect_port(port, &token)
            .await?
            .0
            .stream_audio(audio::format_pb())
            .await
            .map(tonic::Response::into_inner)
            .map_err(grpc_err("streamAudio"))
    };
    Some(audio::Feed::spawn(name, open, stop))
}

/// Lays the packets that came in on the timeline and writes them, then
/// silence up to `now`. A failed append, or a stream that failed to open,
/// ends the audio track (with a warning) and the video goes on.
#[cfg(target_os = "macos")]
fn feed_audio(
    wr: &mut mp4::Mp4Writer,
    tl: &mut audio::Timeline,
    feed: &audio::Feed,
    start: Instant,
    now: Duration,
) -> bool {
    if feed.failed() {
        wr.end_audio();
        return false;
    }
    let rate = f64::from(audio::RATE);
    let mut chunks = Vec::new();
    for (at, pcm) in feed.drain() {
        let len = Duration::from_secs_f64((pcm.len() / audio::FRAME_BYTES) as f64 / rate);
        let since = at.saturating_duration_since(start).saturating_sub(len);
        chunks.extend(tl.place(since, &pcm));
    }
    chunks.extend(tl.fill(now));
    for c in chunks {
        if let Err(e) = wr.push_audio(c.start, &c.pcm) {
            tracing::warn!("recording: audio dropped from here on: {}", e.message);
            wr.end_audio();
            return false;
        }
    }
    true
}

#[cfg(target_os = "macos")]
async fn record(
    ctx: &CallCtx,
    t: &Target,
    path: &Path,
    fps: u32,
    max: Duration,
    audio: bool,
    stop: Arc<AtomicBool>,
) -> MikoResult<Value> {
    let (lw, lh) = lcd_size(t).await?;
    let (w, h) = record_size(lw, lh);
    let latest: Arc<Mutex<Latest>> = Arc::default();
    // Frame stream (emulator → latest slot).
    let mut grpc = t.grpc().await?;
    let stream = grpc
        .stream_screenshot(pb::ImageFormat {
            format: pb::image_format::ImgFormat::Rgba8888 as i32,
            width: w,
            height: h,
            ..Default::default()
        })
        .await
        .map_err(grpc_err("streamScreenshot"))?
        .into_inner();
    let reader = tokio::spawn(pump(stream, latest.clone(), stop.clone()));
    // Audio stream (emulator → feed); dropped with the encoder's state.
    let audio_feed = if audio {
        start_audio(t, stop.clone())
    } else {
        None
    };
    // Encoder on its own thread at a constant rate; duplicates the last
    // frame when the screen doesn't change.
    let cancel = ctx.cancel.clone();
    let progress = ctx.progress.clone();
    let path_buf = path.to_path_buf();
    let enc = tokio::task::spawn_blocking(move || -> MikoResult<(i64, bool, bool, bool)> {
        let mut writer: Option<mp4::Mp4Writer> = None;
        let mut timeline = audio::Timeline::default();
        let mut audio_feed = audio_feed;
        let start = Instant::now();
        let mut last_report = Instant::now();
        let mut cancelled = false;
        let frame_dt = Duration::from_secs_f64(1.0 / f64::from(fps));
        let mut current: Option<Vec<u8>> = None;
        loop {
            if cancel.is_cancelled() {
                cancelled = true;
                break;
            }
            let elapsed = start.elapsed();
            if stop.load(Ordering::Relaxed) || elapsed >= max {
                break;
            }
            if let Ok(mut l) = latest.lock()
                && let Some((fw, fh, px)) = l.frame.take()
            {
                if writer.is_none() {
                    if audio_feed.as_ref().is_some_and(audio::Feed::failed) {
                        audio_feed = None;
                    }
                    let spec = audio_feed.as_ref().map(|_| mp4::AudioSpec {
                        rate: audio::RATE,
                        channels: audio::CHANNELS,
                    });
                    let wr = mp4::Mp4Writer::create(&path_buf, fw, fh, fps as i32, spec)?;
                    if !wr.has_audio() {
                        audio_feed = None;
                    }
                    writer = Some(wr);
                }
                if let Some(wr) = writer.as_ref() {
                    // Frames of another size (rotation) are cropped/padded to the first.
                    current = Some(fit(&px, fw, fh, wr.size()));
                }
            }
            if let (Some(wr), Some(px)) = (writer.as_mut(), current.as_ref()) {
                // Catch up to the wall clock with the latest frame.
                let due = (start.elapsed().as_secs_f64() * f64::from(fps)) as i64;
                while wr.frames() <= due {
                    wr.push(px)?;
                }
                if let Some(feed) = audio_feed.as_ref()
                    && !feed_audio(wr, &mut timeline, feed, start, start.elapsed())
                {
                    audio_feed = None;
                }
            }
            if last_report.elapsed() >= Duration::from_secs(1) {
                last_report = Instant::now();
                let s = start.elapsed().as_secs();
                progress(
                    Some((elapsed.as_secs_f64() / max.as_secs_f64()) as f32),
                    &format!("Recording {}:{:02}", s / 60, s % 60),
                );
            }
            std::thread::sleep(frame_dt / 2);
        }
        let frames = writer.as_ref().map(mp4::Mp4Writer::frames).unwrap_or(0);
        let has_audio = writer.as_ref().is_some_and(mp4::Mp4Writer::has_audio);
        if let (Some(wr), Some(feed), false) = (writer.as_mut(), audio_feed.as_ref(), cancelled) {
            // The last packets, then silence to the video's end.
            let end = Duration::from_secs_f64(frames as f64 / f64::from(fps));
            if feed_audio(wr, &mut timeline, feed, start, end)
                && let Some(c) = timeline.finish(end)
                && let Err(e) = wr.push_audio(c.start, &c.pcm)
            {
                tracing::warn!("recording: the audio's end is missing: {}", e.message);
            }
        }
        match writer {
            Some(w) if cancelled => w.cancel(),
            Some(w) => w.finish()?,
            None => {}
        }
        let audio_received = audio_feed.as_ref().is_some_and(audio::Feed::received);
        Ok((frames, cancelled, has_audio, audio_received))
    });
    let r = enc
        .await
        .map_err(|e| MikoError::unexpected(format!("encoder: {e}")))?;
    reader.abort();
    let (frames, cancelled, has_audio, audio_received) = r?;
    if cancelled {
        let _ = std::fs::remove_file(path);
        return Err(miko_core::cancel::cancelled());
    }
    if frames == 0 {
        return Err(MikoError::sdk("no frames arrived from the emulator"));
    }
    Ok(json!({
        "path": path,
        "frames": frames,
        "fps": fps,
        "duration_s": frames as f64 / f64::from(fps),
        "width": w,
        "height": h,
        "audio": has_audio,
        "audio_received": audio_received,
    }))
}

#[cfg(not(target_os = "macos"))]
async fn record(
    _ctx: &CallCtx,
    _t: &Target,
    _path: &Path,
    _fps: u32,
    _max: Duration,
    _audio: bool,
    _stop: Arc<AtomicBool>,
) -> MikoResult<Value> {
    Err(MikoError::sdk(
        "screen recording uses VideoToolbox and is macOS-only for now",
    ))
}

/// Copies an RGBA frame into a `size` canvas (top-left aligned, black pad).
pub fn fit(px: &[u8], w: u32, h: u32, size: (u32, u32)) -> Vec<u8> {
    let (tw, th) = (size.0 as usize, size.1 as usize);
    let (w, h) = (w as usize, h as usize);
    if (w, h) == (tw, th) && px.len() >= tw * th * 4 {
        return px[..tw * th * 4].to_vec();
    }
    let mut out = vec![0u8; tw * th * 4];
    for y in 0..th.min(h) {
        let n = tw.min(w) * 4;
        let (s, d) = (y * w * 4, y * tw * 4);
        if let (Some(src), Some(dst)) = (px.get(s..s + n), out.get_mut(d..d + n)) {
            dst.copy_from_slice(src);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn record_size_caps_the_long_side_and_keeps_it_even() {
        assert_eq!(record_size(1080, 2400), (576, 1280));
        assert_eq!(record_size(720, 1280), (720, 1280));
        assert_eq!(record_size(1601, 2561), (800, 1280));
    }

    #[test]
    fn fit_pads_and_crops() {
        let px = vec![7u8; 2 * 2 * 4];
        let out = fit(&px, 2, 2, (3, 1));
        assert_eq!(out.len(), 12);
        assert_eq!(&out[..8], &[7; 8]);
        assert_eq!(&out[8..], &[0; 4]);
    }

    #[test]
    fn default_paths_are_unique() {
        let tmp = tempfile::tempdir().unwrap();
        let a = default_path(tmp.path(), "Pixel/ish", "png");
        std::fs::write(&a, b"x").unwrap();
        let b = default_path(tmp.path(), "Pixel/ish", "png");
        assert_ne!(a, b);
        assert!(
            a.file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("Pixel-ish ")
        );
    }

    /// Device names may hold `\` and `"`; file names never do (they reach
    /// the GUI's pasteboard script).
    #[test]
    fn default_paths_drop_quotes_backslashes_and_controls() {
        let tmp = tempfile::tempdir().unwrap();
        let p = default_path(tmp.path(), "a\\\"&(x)\n--", "png");
        let name = p.file_name().unwrap().to_string_lossy().into_owned();
        assert!(name.starts_with("a--&(x)--- "), "{name}");
        assert_eq!(p.parent(), Some(tmp.path()));
    }

    /// Regression (review of PR #3): when the frame stream ended (device
    /// stopped), the encoder kept repeating the last frame until
    /// `max_seconds`, and `media.record` stayed busy for up to an hour.
    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn the_recorder_stops_when_the_frame_stream_ends() {
        let img = pb::Image {
            format: Some(pb::ImageFormat {
                width: 2,
                height: 1,
                ..Default::default()
            }),
            image: vec![1; 8],
            ..Default::default()
        };
        for frames in [
            vec![Ok(img.clone())],
            vec![Ok(img.clone()), Err(tonic::Status::unavailable("gone"))],
        ] {
            let slot: Arc<Mutex<Latest>> = Arc::default();
            let ended = Arc::new(AtomicBool::new(false));
            pump(tokio_stream::iter(frames), slot.clone(), ended.clone()).await;
            assert!(ended.load(Ordering::Relaxed));
            assert_eq!(
                slot.lock().unwrap().frame.as_ref().map(|f| (f.0, f.1)),
                Some((2, 1))
            );
        }
    }

    /// Encodes 2 s of frames and checks the file is a valid MP4.
    #[cfg(target_os = "macos")]
    #[test]
    fn writes_an_mp4() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("t.mp4");
        let mut w = mp4::Mp4Writer::create(&path, 320, 240, 30, None).unwrap();
        assert!(!w.has_audio());
        let mut px = vec![0u8; 320 * 240 * 4];
        for i in 0..60u32 {
            px.iter_mut().for_each(|b| *b = (i * 4) as u8);
            w.push(&px).unwrap();
        }
        w.finish().unwrap();
        let bytes = std::fs::read(&path).unwrap();
        assert!(bytes.len() > 1000);
        assert_eq!(&bytes[4..8], b"ftyp");
        assert!(!contains(&bytes, b"mp4a"), "no audio track was asked for");
    }

    #[cfg(target_os = "macos")]
    fn contains(hay: &[u8], needle: &[u8]) -> bool {
        hay.windows(needle.len()).any(|w| w == needle)
    }

    /// `ms` of a 440 Hz tone, 16-bit stereo at the recording rate.
    #[cfg(target_os = "macos")]
    fn tone(ms: u32) -> Vec<u8> {
        let n = audio::RATE * ms / 1000;
        let mut out = Vec::with_capacity(n as usize * audio::FRAME_BYTES);
        for i in 0..n {
            let t = f64::from(i) / f64::from(audio::RATE);
            let v = ((t * 440.0 * std::f64::consts::TAU).sin() * 8_000.0) as i16;
            out.extend(v.to_le_bytes());
            out.extend(v.to_le_bytes());
        }
        out
    }

    /// #28: 2 s of video with a tone that stops for a second (no packets)
    /// in the middle, laid out by the timeline as the recorder does; the
    /// file gets an AAC track next to the H.264 one.
    #[cfg(target_os = "macos")]
    #[test]
    fn writes_an_mp4_with_an_aac_track() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("a.mp4");
        let spec = mp4::AudioSpec {
            rate: audio::RATE,
            channels: audio::CHANNELS,
        };
        let mut w = mp4::Mp4Writer::create(&path, 320, 240, 30, Some(spec)).unwrap();
        assert!(w.has_audio());
        let mut tl = audio::Timeline::default();
        let px = vec![90u8; 320 * 240 * 4];
        for i in 0..60u64 {
            w.push(&px).unwrap();
            let now = Duration::from_millis(i * 1000 / 30);
            // Sound in the first and last 500 ms, 20 ms packets.
            if now < Duration::from_millis(500) || now >= Duration::from_millis(1500) {
                for c in tl.place(now, &tone(34)) {
                    w.push_audio(c.start, &c.pcm).unwrap();
                }
            }
            if let Some(c) = tl.fill(now) {
                w.push_audio(c.start, &c.pcm).unwrap();
            }
        }
        if let Some(c) = tl.finish(Duration::from_secs(2)) {
            w.push_audio(c.start, &c.pcm).unwrap();
        }
        // The last packet may run past the video; the file ends with it.
        assert!(tl.end() >= u64::from(audio::RATE) * 2);
        w.finish().unwrap();
        let bytes = std::fs::read(&path).unwrap();
        assert_eq!(&bytes[4..8], b"ftyp");
        assert!(contains(&bytes, b"avc1"), "an H.264 track");
        assert!(contains(&bytes, b"mp4a"), "an AAC track");
        assert!(contains(&bytes, b"soun"), "a sound handler");
    }

    /// A broken audio input ends the track; the video still finishes.
    #[cfg(target_os = "macos")]
    #[test]
    fn ending_the_audio_early_keeps_the_video() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("b.mp4");
        let spec = mp4::AudioSpec {
            rate: audio::RATE,
            channels: audio::CHANNELS,
        };
        let mut w = mp4::Mp4Writer::create(&path, 320, 240, 30, Some(spec)).unwrap();
        let px = vec![30u8; 320 * 240 * 4];
        w.push(&px).unwrap();
        w.push_audio(0, &tone(100)).unwrap();
        w.end_audio();
        // Audio after the end is ignored, not an error.
        w.push_audio(4_800, &tone(100)).unwrap();
        for _ in 0..30 {
            w.push(&px).unwrap();
        }
        w.finish().unwrap();
        assert!(std::fs::read(&path).unwrap().len() > 1000);
    }
}
