//! Operation-recording manager for the player bridge.
//!
//! The bridge records normalised player input (touch, mapped touch, keys, text,
//! paste and tool keys) with timestamps and replays it locally. Format, limits
//! and storage live in `jidr_automation`; this module owns the bridge state
//! machine (record/pause/stop + the non-blocking playback tick), the stderr
//! `JIDR_SCRIPT:` notifications and the playback injection into the emulator.
//!
//! The playback engine is advanced from the bridge main loop with a ~5 ms tick,
//! so the frame stream stays responsive (no blocking waits between events).

use std::path::PathBuf;
use std::sync::atomic::AtomicU32;
use std::time::{Duration, Instant};

use anyhow::Result;
use jidr_automation::{
    DisplayInfo, Event, PlaybackMode, PlaybackOptions, Recorder, Script, ScriptStore,
};
use jidr_client::Client;
use jidr_core::{ErrorCode, JidrError};
use jidr_proto::Controller;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::{Command, HeldInputs, input};

/// Every script notification is one line on stderr with this prefix.
const PREFIX: &str = "JIDR_SCRIPT:";
/// Stable codes the Swift player can translate; the bridge sends English text.
const BUSY_CODE: &str = "script.busy";
const INVALID_CODE: &str = "script.invalid";
const NOT_FOUND_CODE: &str = "script.not_found";
const FAILED_CODE: &str = "script.failed";
const NOT_RECORDING_CODE: &str = "script.not_recording";
const NOT_PLAYING_CODE: &str = "script.not_playing";

fn notify(value: Value) {
    eprintln!("{PREFIX}{value}");
}

fn notify_error(code: &str, message: impl Into<String>) {
    notify(json!({"op":"error","code":code,"message":message.into()}));
}

/// The bridge's stable error code for a store/format failure.
fn error_code(error: &JidrError) -> &'static str {
    match error.code {
        ErrorCode::NotFound => NOT_FOUND_CODE,
        ErrorCode::Usage => INVALID_CODE,
        ErrorCode::Busy => BUSY_CODE,
        _ => FAILED_CODE,
    }
}

fn notify_store_error(error: &JidrError) {
    notify_error(error_code(error), error.message.clone());
}

/// Result of one script state-machine step. `events` are due playback inputs
/// for the caller to inject; `release` asks the caller to release held inputs.
#[derive(Default)]
pub struct ScriptOutcome {
    pub events: Vec<Event>,
    pub release: bool,
}

impl ScriptOutcome {
    fn release() -> Self {
        Self {
            events: Vec::new(),
            release: true,
        }
    }
}

/// One recorded command, if it is part of the v1 recording whitelist.
fn event_from_command(command: &Command) -> Option<Event> {
    match command {
        Command::Touch { x, y, down } => Some(Event::Touch {
            x: *x,
            y: *y,
            down: *down,
        }),
        Command::MappedTouch { id, x, y, down } => Some(Event::MappedTouch {
            id: *id,
            x: *x,
            y: *y,
            down: *down,
        }),
        Command::Key { key, down } => Some(Event::Key {
            key: key.clone(),
            down: *down,
        }),
        Command::Text { text } => Some(Event::Text { text: text.clone() }),
        Command::Paste { text } => Some(Event::Paste { text: text.clone() }),
        Command::ToolKey { key } => Some(Event::ToolKey { key: key.clone() }),
        _ => None,
    }
}

/// Cheap pre-check for the recorder: the same bounds the v1 validator applies,
/// so one invalid UI command cannot poison an otherwise valid recording.
fn event_fits_the_format(event: &Event) -> bool {
    match event {
        Event::Touch { x, y, .. } => {
            x.is_finite() && y.is_finite() && (0.0..=1.0).contains(x) && (0.0..=1.0).contains(y)
        }
        Event::MappedTouch { id, x, y, .. } => {
            (jidr_automation::MAPPED_ID_MIN..=jidr_automation::MAPPED_ID_MAX).contains(id)
                && x.is_finite()
                && y.is_finite()
                && (0.0..=1.0).contains(x)
                && (0.0..=1.0).contains(y)
        }
        Event::Key { key, .. } | Event::ToolKey { key } => {
            !key.is_empty() && key.len() <= jidr_automation::MAX_KEY_BYTES
        }
        Event::Text { text } | Event::Paste { text } => {
            text.len() <= jidr_automation::MAX_TEXT_BYTES
        }
    }
}

/// Whether direct user input must be ignored while a script drives the device.
fn is_direct_input(command: &Command) -> bool {
    matches!(
        command,
        Command::Touch { .. }
            | Command::MappedTouch { .. }
            | Command::Key { .. }
            | Command::Text { .. }
            | Command::Paste { .. }
            | Command::Copy { .. }
            | Command::Cut { .. }
            | Command::SelectAll
    )
}

/// Record/playback state owned by the bridge main loop.
pub struct ScriptManager {
    store: ScriptStore,
    device: String,
    display: DisplayInfo,
    recorder: Option<Recorder>,
    playback: Option<Playback>,
}

impl ScriptManager {
    pub fn new(data_dir: PathBuf, device: String, display_width: u32, display_height: u32) -> Self {
        Self {
            store: ScriptStore::new(data_dir),
            device,
            display: DisplayInfo {
                width: display_width,
                height: display_height,
            },
            recorder: None,
            playback: None,
        }
    }

    /// True while a script is playing (paused playback counts as active).
    pub fn is_playing(&self) -> bool {
        self.playback.is_some()
    }

    /// True when the UI's direct input must be ignored during playback.
    pub fn ignores_user_input(&self, command: &Command) -> bool {
        self.playback.is_some() && is_direct_input(command)
    }

    /// Records a whitelisted user command while a recording is running.
    pub fn record_user_command(&mut self, command: &Command, now: Instant) {
        let Some(event) = event_from_command(command) else {
            return;
        };
        self.record_event(event, now);
    }

    /// Records a toolbar tool key (handled outside the normal input dispatch).
    pub fn record_tool_key(&mut self, key: &str, now: Instant) {
        self.record_event(
            Event::ToolKey {
                key: key.to_owned(),
            },
            now,
        );
    }

    fn record_event(&mut self, event: Event, now: Instant) {
        let Some(recorder) = self.recorder.as_mut() else {
            return;
        };
        if recorder.is_paused() || !event_fits_the_format(&event) {
            return;
        }
        if let Err(error) = recorder.record(event, now) {
            self.recorder = None;
            notify(json!({
                "op":"record", "state":"failed",
                "code": error_code(&error), "message": error.message,
            }));
        }
    }

    /// Handles a script control command. Returns due events (none today) and a
    /// release request for pause/stop; notifications are emitted here.
    pub fn handle_command(&mut self, command: &Command, now: Instant) -> ScriptOutcome {
        match command {
            Command::ScriptRecordStart => self.start_recording(now),
            Command::ScriptRecordPause => self.pause_recording(now),
            Command::ScriptRecordResume => self.resume_recording(now),
            Command::ScriptRecordStop { name } => self.stop_recording(name, now),
            Command::ScriptRecordCancel => self.cancel_recording(),
            Command::ScriptList => {
                self.send_list();
                ScriptOutcome::default()
            }
            Command::ScriptDelete { id } => {
                let _ = self.with_id(id, |store, id| store.delete(&id));
                self.send_list();
                ScriptOutcome::default()
            }
            Command::ScriptRename { id, name } => {
                self.with_id(id, |store, id| store.rename(&id, name).map(|_| ()));
                self.send_list();
                ScriptOutcome::default()
            }
            Command::ScriptImport { path } => {
                match self.store.import(path) {
                    Ok(script) => notify(json!({
                        "op":"list", "scripts": self.summaries(), "imported": script.summary(),
                    })),
                    Err(error) => notify_store_error(&error),
                }
                ScriptOutcome::default()
            }
            Command::ScriptExport { id, path } => {
                if let Ok(id) = self.parse_id(id) {
                    match self.store.export(&id, path) {
                        Ok(()) => notify(json!({"op":"list", "scripts": self.summaries()})),
                        Err(error) => notify_store_error(&error),
                    }
                }
                ScriptOutcome::default()
            }
            Command::ScriptPlayStart { id, options } => {
                self.start_playback(id, options.as_ref(), now)
            }
            Command::ScriptPlayPause => self.pause_playback(now),
            Command::ScriptPlayResume => self.resume_playback(now),
            Command::ScriptPlayStop => self.stop_playback(),
            _ => ScriptOutcome::default(),
        }
    }

    /// Advances playback by one tick. Due events are returned for injection.
    pub fn tick(&mut self, now: Instant) -> ScriptOutcome {
        let Some(playback) = self.playback.as_mut() else {
            return ScriptOutcome::default();
        };
        let outcome = playback.tick(now);
        if playback.is_finished() {
            self.playback = None;
        }
        outcome
    }

    // MARK: recording

    fn start_recording(&mut self, now: Instant) -> ScriptOutcome {
        if self.recorder.is_some() || self.playback.is_some() {
            notify_error(
                BUSY_CODE,
                "An operation recording or playback is already running",
            );
            return ScriptOutcome::default();
        }
        self.recorder = Some(Recorder::new(now));
        notify(json!({"op":"record","state":"recording"}));
        ScriptOutcome::default()
    }

    fn pause_recording(&mut self, now: Instant) -> ScriptOutcome {
        match self.recorder.as_mut() {
            Some(recorder) => {
                recorder.pause(now);
                notify(json!({"op":"record","state":"paused"}));
            }
            None => notify_error(NOT_RECORDING_CODE, "No operation recording is running"),
        }
        ScriptOutcome::default()
    }

    fn resume_recording(&mut self, now: Instant) -> ScriptOutcome {
        match self.recorder.as_mut() {
            Some(recorder) => {
                recorder.resume(now);
                notify(json!({"op":"record","state":"recording"}));
            }
            None => notify_error(NOT_RECORDING_CODE, "No operation recording is running"),
        }
        ScriptOutcome::default()
    }

    fn stop_recording(&mut self, name: &str, now: Instant) -> ScriptOutcome {
        let Some(recorder) = self.recorder.take() else {
            notify_error(NOT_RECORDING_CODE, "No operation recording is running");
            return ScriptOutcome::default();
        };
        let result = recorder.finish(
            name,
            self.device.clone(),
            self.display,
            PlaybackOptions::default(),
            now,
        );
        match result {
            Ok(script) => match self.store.save(&script) {
                Ok(()) => notify(json!({
                    "op":"record", "state":"saved",
                    "name": script.name, "script": script.summary(),
                })),
                Err(error) => notify(json!({
                    "op":"record", "state":"failed",
                    "code": error_code(&error), "message": error.message,
                })),
            },
            Err(error) => notify(json!({
                "op":"record", "state":"failed",
                "code": error_code(&error), "message": error.message,
            })),
        }
        // The recording may still hold a touch or key on the device: the
        // bridge must release it even when finishing or saving failed.
        ScriptOutcome::release()
    }

    fn cancel_recording(&mut self) -> ScriptOutcome {
        if self.recorder.take().is_none() {
            notify_error(NOT_RECORDING_CODE, "No operation recording is running");
            return ScriptOutcome::default();
        }
        notify(json!({"op":"record","state":"stopped"}));
        // Same as stop: cancelling while an input is held must release it.
        ScriptOutcome::release()
    }

    // MARK: library

    fn summaries(&self) -> Vec<jidr_automation::ScriptSummary> {
        self.store.list().unwrap_or_default()
    }

    fn send_list(&self) {
        match self.store.list() {
            Ok(scripts) => notify(json!({"op":"list","scripts":scripts})),
            Err(error) => notify_store_error(&error),
        }
    }

    fn parse_id(&self, id: &str) -> Result<Uuid, ()> {
        match Uuid::parse_str(id) {
            Ok(id) => Ok(id),
            Err(_) => {
                notify_error(INVALID_CODE, "The script id is not a valid UUID");
                Err(())
            }
        }
    }

    fn with_id(
        &self,
        id: &str,
        operation: impl FnOnce(&ScriptStore, Uuid) -> jidr_core::JidrResult<()>,
    ) -> Option<()> {
        let id = self.parse_id(id).ok()?;
        match operation(&self.store, id) {
            Ok(()) => Some(()),
            Err(error) => {
                notify_store_error(&error);
                None
            }
        }
    }

    // MARK: playback

    fn start_playback(&mut self, id: &str, options: Option<&Value>, now: Instant) -> ScriptOutcome {
        if self.recorder.is_some() || self.playback.is_some() {
            notify_error(
                BUSY_CODE,
                "An operation recording or playback is already running",
            );
            return ScriptOutcome::default();
        }
        let Ok(id) = self.parse_id(id) else {
            return ScriptOutcome::default();
        };
        let script = match self.store.load(&id) {
            Ok(script) => script,
            Err(error) => {
                notify_store_error(&error);
                return ScriptOutcome::default();
            }
        };
        let options = match options {
            Some(value) => match serde_json::from_value::<PlaybackOptions>(value.clone()) {
                Ok(options) => options,
                Err(error) => {
                    notify_error(INVALID_CODE, format!("Invalid playback options: {error}"));
                    return ScriptOutcome::default();
                }
            },
            None => script.playback,
        };
        if let Err(error) = options.validate() {
            notify(json!({
                "op":"play", "state":"failed",
                "code": error_code(&error), "message": error.message,
            }));
            return ScriptOutcome::default();
        }
        let playback = Playback::new(script, options, now);
        playback.notify_state("playing", None);
        self.playback = Some(playback);
        ScriptOutcome::default()
    }

    fn pause_playback(&mut self, now: Instant) -> ScriptOutcome {
        let Some(playback) = self.playback.as_mut() else {
            notify_error(NOT_PLAYING_CODE, "No script playback is running");
            return ScriptOutcome::default();
        };
        playback.pause(now);
        playback.notify_state("paused", None);
        ScriptOutcome::release()
    }

    fn resume_playback(&mut self, now: Instant) -> ScriptOutcome {
        let Some(playback) = self.playback.as_mut() else {
            notify_error(NOT_PLAYING_CODE, "No script playback is running");
            return ScriptOutcome::default();
        };
        playback.resume(now);
        playback.notify_state("playing", None);
        ScriptOutcome::default()
    }

    fn stop_playback(&mut self) -> ScriptOutcome {
        let Some(playback) = self.playback.take() else {
            notify_error(NOT_PLAYING_CODE, "No script playback is running");
            return ScriptOutcome::default();
        };
        playback.notify_state("stopped", None);
        ScriptOutcome::release()
    }
}

/// One playback run: a loaded script plus the options for this run.
struct Playback {
    script: Script,
    options: PlaybackOptions,
    /// Next event index inside the current loop.
    index: usize,
    /// 1-based loop number used in notifications.
    loop_number: u32,
    /// Completed loops.
    loops_done: u32,
    /// Playback clock in event-time milliseconds (advanced by `speed`).
    virtual_ms: f64,
    last_tick: Instant,
    started_at: Instant,
    paused_at: Option<Instant>,
    paused_total: Duration,
    /// Set while waiting `interval_ms` between loops (real time).
    interval_until: Option<Instant>,
    finished: bool,
}

impl Playback {
    fn new(script: Script, options: PlaybackOptions, now: Instant) -> Self {
        Self {
            script,
            options,
            index: 0,
            loop_number: 1,
            loops_done: 0,
            virtual_ms: 0.0,
            last_tick: now,
            started_at: now,
            paused_at: None,
            paused_total: Duration::ZERO,
            interval_until: None,
            finished: false,
        }
    }

    fn is_finished(&self) -> bool {
        self.finished
    }

    fn count(&self) -> u32 {
        self.options.count.max(1)
    }

    fn is_paused(&self) -> bool {
        self.paused_at.is_some()
    }

    fn pause(&mut self, now: Instant) {
        if self.paused_at.is_none() {
            self.paused_at = Some(now);
        }
    }

    fn resume(&mut self, now: Instant) {
        if let Some(paused_at) = self.paused_at.take() {
            let paused = now.saturating_duration_since(paused_at);
            self.paused_total += paused;
            if let Some(until) = self.interval_until {
                self.interval_until = Some(until + paused);
            }
            self.last_tick = now;
        }
    }

    fn tick(&mut self, now: Instant) -> ScriptOutcome {
        if self.finished || self.is_paused() {
            self.last_tick = now;
            return ScriptOutcome::default();
        }
        // Real-time loop interval: no event clock advance while waiting.
        if let Some(until) = self.interval_until {
            if now < until {
                self.last_tick = now;
                return ScriptOutcome::default();
            }
            self.interval_until = None;
            self.begin_loop(now);
            self.notify_state("playing", None);
        }
        let delta = now.saturating_duration_since(self.last_tick);
        self.last_tick = now;
        self.virtual_ms += delta.as_secs_f64() * 1000.0 * self.options.speed;

        let mut events = Vec::new();
        while let Some(timed) = self.script.events.get(self.index) {
            if (timed.t as f64) > self.virtual_ms {
                break;
            }
            events.push(timed.event.clone());
            self.index += 1;
        }

        // Duration mode stops mid-run once the real active time is reached.
        if self.options.mode == PlaybackMode::Duration {
            let active = now
                .saturating_duration_since(self.started_at)
                .saturating_sub(self.paused_total);
            if active.as_millis() >= u128::from(self.options.duration_ms) {
                return self.finish(events);
            }
        }

        if self.index < self.script.events.len() {
            return ScriptOutcome {
                events,
                release: false,
            };
        }

        // The current loop ended.
        self.loops_done += 1;
        let more = match self.options.mode {
            PlaybackMode::Count => self.loops_done < self.count(),
            PlaybackMode::Infinite | PlaybackMode::Duration => true,
        };
        if !more {
            return self.finish(events);
        }
        if self.options.interval_ms > 0 {
            self.interval_until = Some(now + Duration::from_millis(self.options.interval_ms));
        } else {
            self.begin_loop(now);
            self.notify_state("playing", None);
        }
        ScriptOutcome {
            events,
            release: false,
        }
    }

    fn begin_loop(&mut self, now: Instant) {
        self.index = 0;
        self.loop_number = self.loop_number.saturating_add(1);
        self.virtual_ms = 0.0;
        self.last_tick = now;
    }

    fn finish(&mut self, mut events: Vec<Event>) -> ScriptOutcome {
        self.finished = true;
        self.virtual_ms = 0.0;
        events.shrink_to_fit();
        self.notify_state("finished", None);
        ScriptOutcome {
            events,
            release: true,
        }
    }

    fn notify_state(&self, state: &str, message: Option<&str>) {
        let mut value = json!({
            "op": "play",
            "state": state,
            "name": self.script.name,
            "loop": self.loop_number,
            "speed": self.options.speed,
            "interval_ms": self.options.interval_ms,
        });
        match self.options.mode {
            PlaybackMode::Count => {
                value["count"] = json!(self.count());
                value["total"] = json!(self.count());
            }
            PlaybackMode::Duration => {
                value["duration_ms"] = json!(self.options.duration_ms);
            }
            PlaybackMode::Infinite => {
                value["count"] = json!(0);
            }
        }
        if let Some(message) = message {
            value["message"] = json!(message);
        }
        notify(value);
    }
}

/// Injects one recorded event into the emulator, sharing the released-input
/// bookkeeping with direct user input.
pub async fn execute_event(
    ctl: &mut Controller,
    held: &mut HeldInputs,
    rotation: &AtomicU32,
    panel: (u32, u32),
    event: &Event,
    client: &Client,
    device: &str,
) -> Result<()> {
    let command = match event {
        Event::Touch { x, y, down } => Command::Touch {
            x: *x,
            y: *y,
            down: *down,
        },
        Event::MappedTouch { id, x, y, down } => Command::MappedTouch {
            id: *id,
            x: *x,
            y: *y,
            down: *down,
        },
        Event::Key { key, down } => Command::Key {
            key: key.clone(),
            down: *down,
        },
        Event::Text { text } => Command::Text { text: text.clone() },
        Event::Paste { text } => Command::Paste { text: text.clone() },
        Event::ToolKey { key } => {
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
                client
                    .call("key.press", json!({"device": device, "key": key}))
                    .await?;
            }
            return Ok(());
        }
    };
    input(ctl, command, panel, rotation, held).await
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;
    use jidr_automation::{DisplayInfo, Event, PlaybackMode, PlaybackOptions, Script};

    fn sample_script(events: Vec<jidr_automation::TimedEvent>) -> Script {
        Script {
            format: jidr_automation::FORMAT.to_owned(),
            version: jidr_automation::VERSION,
            id: Uuid::nil(),
            name: "test".to_owned(),
            created_at: chrono::Utc::now(),
            device: "Phone".to_owned(),
            display: DisplayInfo {
                width: 576,
                height: 1280,
            },
            playback: PlaybackOptions::default(),
            events,
        }
    }

    fn timed(t: u64, event: Event) -> jidr_automation::TimedEvent {
        jidr_automation::TimedEvent { t, event }
    }

    #[test]
    fn playback_emits_events_per_tick_and_finishes_after_the_last_loop() {
        let events = vec![
            timed(
                0,
                Event::Touch {
                    x: 0.5,
                    y: 0.4,
                    down: true,
                },
            ),
            timed(
                80,
                Event::Touch {
                    x: 0.5,
                    y: 0.4,
                    down: false,
                },
            ),
        ];
        let script = sample_script(events);
        let options = PlaybackOptions {
            mode: PlaybackMode::Count,
            count: 2,
            ..PlaybackOptions::default()
        };
        let start = Instant::now();
        let mut playback = Playback::new(script, options, start);

        let first = playback.tick(start);
        assert_eq!(first.events.len(), 1, "the t=0 event fires immediately");
        assert!(!first.release);

        let second = playback.tick(start + Duration::from_millis(100));
        assert_eq!(second.events.len(), 1);
        assert!(
            !second.release,
            "the first loop ends but count mode continues"
        );
        assert_eq!(playback.loop_number, 2);

        let third = playback.tick(start + Duration::from_millis(200));
        assert_eq!(third.events.len(), 2, "the second loop replays both events");
        assert!(third.release, "the second and last loop finished");
        assert!(playback.is_finished());
    }

    #[test]
    fn playback_speed_scales_the_event_clock() {
        let script = sample_script(vec![timed(
            1000,
            Event::Text {
                text: "x".to_owned(),
            },
        )]);
        let options = PlaybackOptions {
            speed: 4.0,
            ..PlaybackOptions::default()
        };
        let start = Instant::now();
        let mut playback = Playback::new(script, options, start);
        assert!(
            playback
                .tick(start + Duration::from_millis(200))
                .events
                .is_empty()
        );
        let outcome = playback.tick(start + Duration::from_millis(300));
        assert_eq!(
            outcome.events.len(),
            1,
            "4x speed reaches t=1000 after 250 ms"
        );
    }

    #[test]
    fn playback_interval_waits_in_real_time_between_loops() {
        let script = sample_script(vec![timed(
            0,
            Event::Text {
                text: "x".to_owned(),
            },
        )]);
        let options = PlaybackOptions {
            mode: PlaybackMode::Count,
            count: 2,
            interval_ms: 50,
            ..PlaybackOptions::default()
        };
        let start = Instant::now();
        let mut playback = Playback::new(script, options, start);
        assert_eq!(playback.tick(start).events.len(), 1, "first loop event");
        assert!(
            playback
                .tick(start + Duration::from_millis(10))
                .events
                .is_empty()
        );
        assert!(
            playback
                .tick(start + Duration::from_millis(40))
                .events
                .is_empty()
        );
        let second_loop = playback.tick(start + Duration::from_millis(70));
        assert_eq!(
            second_loop.events.len(),
            1,
            "second loop after the interval"
        );
        assert!(second_loop.release);
    }

    #[test]
    fn playback_pause_freezes_the_event_clock() {
        let script = sample_script(vec![
            timed(
                0,
                Event::Touch {
                    x: 0.5,
                    y: 0.5,
                    down: true,
                },
            ),
            timed(
                100,
                Event::Touch {
                    x: 0.5,
                    y: 0.5,
                    down: false,
                },
            ),
        ]);
        let start = Instant::now();
        let mut playback = Playback::new(script, PlaybackOptions::default(), start);
        assert_eq!(playback.tick(start).events.len(), 1);
        playback.pause(start + Duration::from_millis(10));
        assert!(
            playback
                .tick(start + Duration::from_millis(500))
                .events
                .is_empty()
        );
        playback.resume(start + Duration::from_millis(500));
        let outcome = playback.tick(start + Duration::from_millis(600));
        assert_eq!(outcome.events.len(), 1, "the paused time is skipped");
        assert!(outcome.release);
    }

    #[test]
    fn playback_duration_mode_stops_mid_script() {
        let script = sample_script(vec![
            timed(
                0,
                Event::Text {
                    text: "a".to_owned(),
                },
            ),
            timed(
                10_000,
                Event::Text {
                    text: "b".to_owned(),
                },
            ),
        ]);
        let options = PlaybackOptions {
            mode: PlaybackMode::Duration,
            duration_ms: 100,
            ..PlaybackOptions::default()
        };
        let start = Instant::now();
        let mut playback = Playback::new(script, options, start);
        assert_eq!(playback.tick(start).events.len(), 1);
        let outcome = playback.tick(start + Duration::from_millis(150));
        assert!(outcome.release, "duration reached and playback finished");
        assert!(playback.is_finished());
    }

    fn recording_manager() -> (tempfile::TempDir, ScriptManager) {
        let temp = tempfile::tempdir().expect("temp dir");
        let manager = ScriptManager::new(temp.path().to_path_buf(), "dev".to_owned(), 576, 1280);
        (temp, manager)
    }

    #[test]
    fn stopping_a_recording_releases_held_device_inputs() {
        let (_temp, mut manager) = recording_manager();
        let start = Instant::now();
        manager.handle_command(&Command::ScriptRecordStart, start);
        manager.record_user_command(
            &Command::Key {
                key: "ENTER".to_owned(),
                down: true,
            },
            start + Duration::from_millis(10),
        );
        assert_eq!(
            manager.recorder.as_ref().map(|r| r.event_count()),
            Some(1),
            "the key down is being recorded"
        );
        let outcome = manager.handle_command(
            &Command::ScriptRecordStop {
                name: "daily".to_owned(),
            },
            start + Duration::from_millis(20),
        );
        assert!(outcome.release, "stop must release held inputs");
        assert!(manager.recorder.is_none());
    }

    #[test]
    fn failed_recording_stop_still_releases_held_device_inputs() {
        let (_temp, mut manager) = recording_manager();
        let start = Instant::now();
        manager.handle_command(&Command::ScriptRecordStart, start);
        manager.record_user_command(
            &Command::Touch {
                x: 0.5,
                y: 0.5,
                down: true,
            },
            start + Duration::from_millis(10),
        );
        // An empty name fails validation inside Recorder::finish.
        let outcome = manager.handle_command(
            &Command::ScriptRecordStop {
                name: String::new(),
            },
            start + Duration::from_millis(20),
        );
        assert!(
            outcome.release,
            "a failed stop must still release held inputs"
        );
    }

    #[test]
    fn cancelling_a_recording_releases_held_device_inputs() {
        let (_temp, mut manager) = recording_manager();
        let start = Instant::now();
        manager.handle_command(&Command::ScriptRecordStart, start);
        manager.record_user_command(
            &Command::Key {
                key: "W".to_owned(),
                down: true,
            },
            start + Duration::from_millis(10),
        );
        let outcome = manager.handle_command(
            &Command::ScriptRecordCancel,
            start + Duration::from_millis(20),
        );
        assert!(outcome.release, "cancel must release held inputs");
        assert!(manager.recorder.is_none());
    }

    #[test]
    fn cancelling_without_a_recording_does_not_release_anything() {
        let (_temp, mut manager) = recording_manager();
        let outcome = manager.handle_command(&Command::ScriptRecordCancel, Instant::now());
        assert!(!outcome.release);
    }

    #[test]
    fn recording_whitelist_matches_the_documented_events() {
        assert!(
            event_from_command(&Command::Touch {
                x: 0.5,
                y: 0.5,
                down: true
            })
            .is_some()
        );
        assert!(
            event_from_command(&Command::MappedTouch {
                id: 4,
                x: 0.1,
                y: 0.2,
                down: false
            })
            .is_some()
        );
        assert!(
            event_from_command(&Command::Key {
                key: "ENTER".to_owned(),
                down: true
            })
            .is_some()
        );
        assert!(
            event_from_command(&Command::Text {
                text: "hi".to_owned()
            })
            .is_some()
        );
        assert!(
            event_from_command(&Command::Paste {
                text: "hi".to_owned()
            })
            .is_some()
        );
        assert!(
            event_from_command(&Command::ToolKey {
                key: "back".to_owned()
            })
            .is_some()
        );
        assert!(event_from_command(&Command::Rotate { direction: 1 }).is_none());
        assert!(event_from_command(&Command::Copy { request_id: 1 }).is_none());
        assert!(
            event_from_command(&Command::Screenshot {
                path: "a".to_owned()
            })
            .is_none()
        );
    }

    #[test]
    fn record_precheck_matches_the_format_bounds() {
        assert!(event_fits_the_format(&Event::Touch {
            x: 0.5,
            y: 0.5,
            down: true
        }));
        assert!(!event_fits_the_format(&Event::Touch {
            x: 1.5,
            y: 0.5,
            down: true
        }));
        assert!(event_fits_the_format(&Event::MappedTouch {
            id: 3,
            x: 0.0,
            y: 1.0,
            down: true
        }));
        assert!(!event_fits_the_format(&Event::MappedTouch {
            id: 2,
            x: 0.5,
            y: 0.5,
            down: true
        }));
        assert!(event_fits_the_format(&Event::Key {
            key: "ENTER".to_owned(),
            down: true
        }));
        assert!(!event_fits_the_format(&Event::Key {
            key: String::new(),
            down: true
        }));
        assert!(!event_fits_the_format(&Event::ToolKey {
            key: String::new()
        }));
        assert!(event_fits_the_format(&Event::Text {
            text: "hi".to_owned()
        }));
    }

    #[test]
    fn direct_input_is_ignored_only_while_playback_is_active() {
        let command = Command::Touch {
            x: 0.5,
            y: 0.5,
            down: false,
        };
        let temp = tempfile::tempdir().expect("temp dir");
        let mut manager =
            ScriptManager::new(temp.path().to_path_buf(), "dev".to_owned(), 576, 1280);
        assert!(!manager.ignores_user_input(&command));
        manager.playback = Some(Playback::new(
            sample_script(vec![timed(
                0,
                Event::Text {
                    text: "x".to_owned(),
                },
            )]),
            PlaybackOptions::default(),
            Instant::now(),
        ));
        assert!(manager.ignores_user_input(&command));
        assert!(!manager.ignores_user_input(&Command::Rotate { direction: 1 }));
    }
}
