//! Microphone injection (#70): `audio.inject` plays a WAV or raw PCM file
//! as the device's microphone over gRPC `injectAudio` (a job that runs until
//! the clip ends, `audio.stop` or a cancel); `audio.stop` ends it.

use std::path::PathBuf;
use std::time::Duration;

use jidr_backend::audio::{self, Clip, Playback, Played};
use jidr_core::provider::{CallCtx, CommandSpec, DeviceParams, parse_params};
use jidr_core::{JidrError, JidrResult};
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::device::target;
use crate::running::Running;

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct InjectParams {
    pub device: String,
    /// A WAV file on this machine: 8-, 16-, 24- or 32-bit PCM or 32/64-bit
    /// float, mono or stereo, 8–48 kHz. Or headerless 16-bit little-endian
    /// PCM with `sample_rate`.
    pub path: PathBuf,
    /// Start again at the end, until `audio.stop`.
    #[serde(default, rename = "loop")]
    pub repeat: bool,
    /// Headerless PCM only: its sample rate in Hz (8000–48000).
    #[serde(default)]
    pub sample_rate: Option<u32>,
    /// Headerless PCM only: 1 (mono, the default) or 2 (stereo).
    #[serde(default)]
    pub channels: Option<u16>,
}

/// Stop flags of the injections in progress, by device.
pub type Injections = Running;

pub fn specs() -> Vec<CommandSpec> {
    vec![
        CommandSpec::new::<InjectParams>(
            "audio.inject",
            "Play a WAV (or raw PCM) file as the device's microphone until it ends or audio.stop",
        )
        .long_running(),
        CommandSpec::new::<DeviceParams>(
            "audio.stop",
            "Stop the audio playing into the microphone",
        ),
    ]
}

/// The headerless-PCM layout from the params, if any.
pub fn raw_layout(p: &InjectParams) -> JidrResult<Option<(u32, u16)>> {
    match (p.sample_rate, p.channels) {
        (Some(rate), ch) => Ok(Some((rate, ch.unwrap_or(1)))),
        (None, Some(_)) => Err(JidrError::usage(
            "channels is only for headerless PCM; pass sample_rate too",
        )),
        (None, None) => Ok(None),
    }
}

fn secs(d: Duration) -> f64 {
    (d.as_secs_f64() * 100.0).round() / 100.0
}

/// "1.2 / 5.0 s" (with "pass 2 · " when looping).
pub fn progress_text(at: Duration, total: Duration, loops: u32, repeat: bool) -> String {
    let pass = if repeat {
        format!("pass {} · ", loops + 1)
    } else {
        String::new()
    };
    format!(
        "{pass}{:.1} / {:.1} s",
        at.as_secs_f64(),
        total.as_secs_f64()
    )
}

/// The `audio.inject` result.
pub fn result(path: &std::path::Path, clip: &Clip, played: Played) -> Value {
    json!({
        "path": path,
        "duration_s": secs(clip.duration()),
        "played_s": secs(played.played),
        "loops": played.loops,
        "stopped": played.stopped,
        "sample_rate": clip.rate,
        "channels": clip.channels,
        "format": clip.format.as_str(),
        "converted_from": clip.converted_from,
    })
}

pub async fn call(
    ctx: &CallCtx,
    injections: &Injections,
    method: &str,
    params: Value,
) -> JidrResult<Value> {
    match method {
        "audio.inject" => {
            let p: InjectParams = parse_params(params)?;
            let raw = raw_layout(&p)?;
            let path = p.path.clone();
            let clip = tokio::task::spawn_blocking(move || audio::wav::load(&path, raw))
                .await
                .map_err(|e| JidrError::unexpected(format!("reading the audio file: {e}")))??;
            let t = target(ctx, &p.device).await?;
            let reg = injections.start(t.device.id, || {
                format!(
                    "{} is already playing audio into its microphone; stop it first (audio.stop)",
                    t.device.name
                )
            })?;
            let total = clip.duration();
            ctx.report(
                Some(0.0),
                &progress_text(Duration::ZERO, total, 0, p.repeat),
            );
            let play = Playback {
                repeat: p.repeat,
                ..Playback::default()
            };
            let report = |at: Duration, loops: u32| {
                // Within the current pass.
                let at = at.saturating_sub(total.checked_mul(loops).unwrap_or(Duration::MAX));
                let f = if total.is_zero() {
                    1.0
                } else {
                    (at.as_secs_f64() / total.as_secs_f64()).min(1.0) as f32
                };
                ctx.report(Some(f), &progress_text(at, total, loops, p.repeat));
            };
            let played = audio::inject(
                t.grpc().await?,
                &clip,
                play,
                &reg.flag,
                &ctx.cancel,
                &report,
            )
            .await?;
            Ok(result(&p.path, &clip, played))
        }
        "audio.stop" => {
            let p: DeviceParams = parse_params(params)?;
            let d = ctx.daemon.device(&p.device).await?;
            Ok(json!({ "stopped": injections.stop(d.id) }))
        }
        _ => Err(JidrError::usage(format!("unknown method {method}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params(v: Value) -> InjectParams {
        parse_params(v).unwrap()
    }

    #[test]
    fn raw_layout_needs_a_rate() {
        let p = params(json!({"device": "P", "path": "/a.wav"}));
        assert_eq!(raw_layout(&p).unwrap(), None);
        assert!(!p.repeat);
        let p = params(json!({"device": "P", "path": "/a.pcm", "sample_rate": 16000}));
        assert_eq!(raw_layout(&p).unwrap(), Some((16_000, 1)));
        let p = params(
            json!({"device": "P", "path": "/a.pcm", "sample_rate": 48000, "channels": 2, "loop": true}),
        );
        assert_eq!(raw_layout(&p).unwrap(), Some((48_000, 2)));
        assert!(p.repeat);
        let p = params(json!({"device": "P", "path": "/a.pcm", "channels": 2}));
        assert_eq!(
            raw_layout(&p).unwrap_err().code,
            jidr_core::ErrorCode::Usage
        );
        assert!(
            parse_params::<InjectParams>(json!({"device": "P", "path": "/a", "rate": 1})).is_err()
        );
    }

    #[test]
    fn progress_reads_well() {
        let s = Duration::from_secs_f64;
        assert_eq!(progress_text(s(1.24), s(5.0), 0, false), "1.2 / 5.0 s");
        assert_eq!(
            progress_text(s(0.0), s(5.0), 2, true),
            "pass 3 · 0.0 / 5.0 s"
        );
    }

    #[test]
    fn result_reports_the_clip_and_what_played() {
        let clip = audio::wav::raw_s16(vec![0; 32_000], 16_000, 1).unwrap();
        let v = result(
            std::path::Path::new("/tmp/a.pcm"),
            &clip,
            Played {
                played: Duration::from_millis(250),
                loops: 0,
                stopped: true,
            },
        );
        assert_eq!(v["duration_s"], 1.0);
        assert_eq!(v["played_s"], 0.25);
        assert_eq!(v["stopped"], true);
        assert_eq!(v["format"], "s16le");
        assert_eq!(v["sample_rate"], 16_000);
        assert_eq!(v["converted_from"], Value::Null);
    }
}
