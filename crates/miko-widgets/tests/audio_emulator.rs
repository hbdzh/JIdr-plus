//! #70: `audio.inject` streams a WAV to a real emulator's microphone over
//! gRPC `injectAudio`: the emulator accepts the format, a second injection
//! on the same device is `busy`, and `audio.stop` ends the job cleanly.
//!
//! Nothing on a stock image records the microphone from the shell, so this
//! doesn't check what an app hears; with no reader the emulator's blocking
//! delivery holds the stream, which is why the job is stopped rather than
//! run to the end.
#![cfg(feature = "emulator")]
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod common;

use std::time::Duration;

use miko_core::{ErrorCode, JobState};
use serde_json::json;

/// A 16-bit 44.1 kHz stereo WAV: `secs` of a 440 Hz tone.
fn tone(secs: u32) -> Vec<u8> {
    let rate = 44_100u32;
    let frames = rate * secs;
    let mut data = Vec::with_capacity(frames as usize * 4);
    for i in 0..frames {
        let v = ((f64::from(i) * 440.0 * std::f64::consts::TAU / f64::from(rate)).sin() * 8_000.0)
            as i16;
        data.extend(v.to_le_bytes());
        data.extend(v.to_le_bytes());
    }
    let mut b = Vec::new();
    b.extend(b"RIFF");
    b.extend((36 + data.len() as u32).to_le_bytes());
    b.extend(b"WAVEfmt ");
    b.extend(16u32.to_le_bytes());
    b.extend(1u16.to_le_bytes());
    b.extend(2u16.to_le_bytes());
    b.extend(rate.to_le_bytes());
    b.extend((rate * 4).to_le_bytes());
    b.extend(4u16.to_le_bytes());
    b.extend(16u16.to_le_bytes());
    b.extend(b"data");
    b.extend((data.len() as u32).to_le_bytes());
    b.extend(data);
    b
}

#[tokio::test(flavor = "multi_thread")]
async fn inject_busy_and_stop() {
    let env = common::Env::boot("audio70").await;
    let wav = env.tmp.path().join("tone.wav");
    std::fs::write(&wav, tone(5)).unwrap();

    let v = env
        .call("audio.inject", json!({ "path": wav, "loop": true }))
        .await;
    let job: uuid::Uuid = serde_json::from_value(v["job"].clone()).unwrap();

    // The stream is up (no gRPC error) and a second one is refused.
    tokio::time::sleep(Duration::from_secs(2)).await;
    let j = env
        .client
        .wait_job(job, Some(Duration::from_secs(1)))
        .await
        .unwrap();
    assert_eq!(j.state, JobState::Running, "{j:?}");
    let e = env
        .client
        .run(
            "audio.inject",
            json!({ "device": env.device, "path": wav }),
            |_| {},
        )
        .await
        .unwrap_err();
    assert_eq!(e.code, ErrorCode::Busy, "{}", e.message);

    let s = env.call("audio.stop", json!({})).await;
    assert_eq!(s["stopped"], true);
    let mut j = env
        .client
        .wait_job(job, Some(Duration::from_secs(15)))
        .await
        .unwrap();
    for _ in 0..3 {
        if j.state != JobState::Running {
            break;
        }
        j = env
            .client
            .wait_job(job, Some(Duration::from_secs(15)))
            .await
            .unwrap();
    }
    assert_eq!(j.state, JobState::Succeeded, "{j:?}");
    let r = j.result.unwrap();
    assert_eq!(r["stopped"], true, "{r}");
    assert_eq!(r["sample_rate"], 44_100);
    assert!(r["played_s"].as_f64().unwrap() > 0.0, "{r}");

    // Nothing plays now; the microphone is free for the next injection.
    assert_eq!(env.call("audio.stop", json!({})).await["stopped"], false);
    let v = env.call("audio.inject", json!({ "path": wav })).await;
    let job: uuid::Uuid = serde_json::from_value(v["job"].clone()).unwrap();
    tokio::time::sleep(Duration::from_secs(1)).await;
    env.call("audio.stop", json!({})).await;
    let j = env
        .client
        .wait_job(job, Some(Duration::from_secs(15)))
        .await
        .unwrap();
    assert_eq!(j.state, JobState::Succeeded, "{j:?}");
}

/// With no input device, do not invoke the emulator's crashing audio path.
#[cfg(target_os = "macos")]
#[tokio::test(flavor = "multi_thread")]
async fn no_host_input_reports_error_and_keeps_device_running() {
    fn has_input(value: &serde_json::Value) -> bool {
        match value {
            serde_json::Value::Object(fields) => {
                fields.get("coreaudio_device_input").is_some_and(|v| {
                    v.as_u64().is_some_and(|n| n > 0)
                        || v.as_str()
                            .and_then(|s| s.parse::<u64>().ok())
                            .is_some_and(|n| n > 0)
                }) || fields.values().any(has_input)
            }
            serde_json::Value::Array(items) => items.iter().any(has_input),
            _ => false,
        }
    }
    let status = std::process::Command::new("/usr/sbin/system_profiler")
        .args(["SPAudioDataType", "-json"])
        .output()
        .unwrap();
    assert!(status.status.success());
    let info = serde_json::from_slice(&status.stdout).unwrap();
    if has_input(&info) {
        eprintln!("host has an audio input; no-input scenario not available");
        return;
    }
    let env = common::Env::boot("no-input").await;
    let wav = env.tmp.path().join("tone.wav");
    std::fs::write(&wav, tone(1)).unwrap();
    let err = env
        .client
        .run(
            "audio.inject",
            json!({ "device": env.device, "path": wav }),
            |_| {},
        )
        .await
        .unwrap_err();
    assert!(err.message.contains("audio input device"), "{err}");
    assert_eq!(env.shell("getprop sys.boot_completed").trim(), "1");
    env.stop().await;
}
