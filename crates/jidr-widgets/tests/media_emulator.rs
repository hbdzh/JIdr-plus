//! Phase 10a: a screenshot is a PNG of the screen, and a 5-minute
//! recording passes ffprobe (h264, 300 ± 2 s, ≥ 30 × 300 × 0.9 frames).
//! #28: the emulator streams audio in the format the recorder asks for, and
//! recordings carry an AAC track as long as the video (the 5-minute one is
//! mostly silence, so it also checks the audio doesn't drift).
#![cfg(feature = "emulator")]
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod common;

use std::path::Path;
use std::time::Duration;

use jidr_widgets::media::audio;
use serde_json::{Value, json};

/// ffprobe's JSON for the first stream of `kind` (`v` or `a`) and the format.
fn probe(path: &Path, kind: &str) -> Value {
    let probe = std::process::Command::new("ffprobe")
        .args(["-v", "error", "-select_streams", &format!("{kind}:0")])
        .args(if kind == "v" {
            &["-count_frames"][..]
        } else {
            &[][..]
        })
        .args([
            "-show_entries",
            "stream=codec_name,nb_read_frames,duration,width,height,sample_rate,channels",
            "-show_entries",
            "format=duration",
            "-of",
            "json",
        ])
        .arg(path)
        .output()
        .expect("ffprobe on PATH");
    assert!(
        probe.status.success(),
        "{}",
        String::from_utf8_lossy(&probe.stderr)
    );
    let v: Value = serde_json::from_slice(&probe.stdout).unwrap();
    println!("ffprobe {kind}: {v}");
    v
}

/// The audio track has sound in it (not only the silence that fills gaps).
fn loud(path: &Path) -> bool {
    let pcm = std::process::Command::new("ffmpeg")
        .args(["-v", "error", "-i"])
        .arg(path)
        .args(["-vn", "-ac", "1", "-ar", "8000", "-f", "s16le", "-"])
        .output()
        .expect("ffmpeg on PATH")
        .stdout;
    pcm.as_chunks::<2>()
        .0
        .iter()
        .any(|s| i16::from_le_bytes(*s).unsigned_abs() > 1_000)
}

fn secs(v: &Value) -> f64 {
    v.as_str().unwrap().parse().unwrap()
}

/// Makes the guest play a sound: an incoming call rings. Stock images have
/// no ringtone set (telecom logs `isRingtonePresent=false` and stays
/// silent), so one of the image's own sounds becomes the ringtone first.
async fn ring(env: &common::Env) {
    let deadline = std::time::Instant::now() + Duration::from_secs(60);
    let id = loop {
        let rows =
            env.shell("content query --uri content://media/internal/audio/media --projection _id");
        if let Some(id) = rows
            .split("_id=")
            .nth(1)
            .and_then(|r| r.split(|c: char| !c.is_ascii_digit()).next())
            .filter(|id| !id.is_empty())
        {
            break id.to_owned();
        }
        assert!(
            std::time::Instant::now() < deadline,
            "Android media index did not become ready"
        );
        tokio::time::sleep(Duration::from_secs(1)).await;
    };
    env.shell(&format!(
        "settings put system ringtone content://media/internal/audio/media/{id}"
    ));
    env.call("phone.call", json!({ "number": "5551234" })).await;
}

async fn hang_up(env: &common::Env) {
    env.call(
        "phone.call",
        json!({ "number": "5551234", "action": "reject" }),
    )
    .await;
}

#[tokio::test(flavor = "multi_thread")]
async fn media_screenshot_and_five_minute_recording() {
    let env = common::Env::boot("widgets10a").await;

    // Screenshot.
    let png = env.tmp.path().join("shot.png");
    let s = env.call("media.screenshot", json!({ "path": png })).await;
    assert_eq!(s["path"], json!(png));
    let bytes = std::fs::read(&png).unwrap();
    assert_eq!(&bytes[..8], b"\x89PNG\r\n\x1a\n");
    assert_eq!(
        (s["width"].as_u64(), s["height"].as_u64()),
        (Some(720), Some(1280)),
        "{s}"
    );

    // A stalled audio stream must not block the recorder.
    let (port, token) = (env.info.grpc_port, env.info.grpc_token.clone());
    let open = async move {
        jidr_backend::grpc::connect_port(port, &token)
            .await?
            .0
            .stream_audio(audio::format_pb())
            .await
            .map(tonic::Response::into_inner)
            .map_err(|s| jidr_backend::grpc::status_error("streamAudio", s))
    };
    let feed = audio::Feed::spawn("widgets10a".into(), open, Default::default());
    ring(&env).await;
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    let mut got = 0usize;
    while got == 0 && !feed.failed() && std::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(100)).await;
        got += feed.drain().map(|(_, pcm)| pcm.len()).sum::<usize>();
    }
    println!("preflight audio bytes: {got}, failed: {}", feed.failed());
    drop(feed);
    hang_up(&env).await;

    // Recording encodes with AVFoundation (VideoToolbox): macOS only.
    if !cfg!(target_os = "macos") {
        env.stop().await;
        return;
    }

    // A short recording with a ringing call has an AAC track as long as the
    // video, with sound in it.
    let short = env.tmp.path().join("audio.mp4");
    let (rec, ()) = tokio::join!(
        env.run(
            "media.record",
            json!({ "path": short, "max_seconds": 8, "fps": 30 }),
        ),
        async {
            tokio::time::sleep(Duration::from_secs(2)).await;
            ring(&env).await;
            tokio::time::sleep(Duration::from_secs(3)).await;
            hang_up(&env).await;
        }
    );
    println!("audio recording: {rec}");
    assert_eq!(rec["audio"], true, "{rec}");
    let a = probe(&short, "a");
    assert_eq!(a["streams"][0]["codec_name"], "aac", "{a}");
    assert_eq!(a["streams"][0]["sample_rate"], "48000");
    assert_eq!(a["streams"][0]["channels"], 2);
    let video_s = secs(&a["format"]["duration"]);
    let audio_s = secs(&a["streams"][0]["duration"]);
    assert!((7.0..=9.0).contains(&video_s), "duration {video_s}");
    assert!(
        (audio_s - video_s).abs() < 0.5,
        "audio {audio_s} s, file {video_s} s"
    );
    assert!(
        loud(&short),
        "the ringtone isn't in the recording; recording: {rec}"
    );

    // `audio: false` is video-only.
    let silent = env.tmp.path().join("silent.mp4");
    let rec = env
        .run(
            "media.record",
            json!({ "path": silent, "max_seconds": 2, "audio": false }),
        )
        .await;
    assert_eq!(rec["audio"], false, "{rec}");
    let a = probe(&silent, "a");
    assert_eq!(a["streams"], json!([]), "{a}");

    // Recording at a constant 30 fps (the last frame repeats while the screen is still).
    let mp4 = env.tmp.path().join("rec.mp4");
    let started = std::time::Instant::now();
    let rec = env
        .run(
            "media.record",
            json!({ "path": mp4, "max_seconds": 300, "fps": 30 }),
        )
        .await;
    println!(
        "recorded in {:.1} s: {rec}",
        started.elapsed().as_secs_f64()
    );
    assert!(rec["frames"].as_i64().unwrap() >= 8100, "{rec}");
    assert_eq!(rec["audio"], true, "{rec}");

    let v = probe(&mp4, "v");
    let stream = &v["streams"][0];
    assert_eq!(stream["codec_name"], "h264");
    let duration: f64 = v["format"]["duration"].as_str().unwrap().parse().unwrap();
    assert!((298.0..=302.0).contains(&duration), "duration {duration}");
    let frames: u64 = stream["nb_read_frames"].as_str().unwrap().parse().unwrap();
    assert!(frames >= 8100, "frames {frames}");
    // Five minutes of mostly silence: the audio still ends with the video.
    let a = probe(&mp4, "a");
    let audio_s = secs(&a["streams"][0]["duration"]);
    assert!(
        (audio_s - duration).abs() < 0.5,
        "audio {audio_s} s, file {duration} s"
    );

    env.stop().await;
}
