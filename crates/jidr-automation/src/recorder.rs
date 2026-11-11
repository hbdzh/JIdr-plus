//! Records normalised input events with timings.
//!
//! The recorder takes an explicit [`Instant`] for every call so the bridge can
//! feed it the same monotonic clock it uses for input handling, and so tests
//! need no sleeping. Wall-clock time is only used for the script's
//! `created_at`.

use std::collections::{BTreeMap, BTreeSet};
use std::time::{Duration, Instant};

use chrono::Utc;
use jidr_core::{JidrError, JidrResult};
use uuid::Uuid;

use crate::model::{
    DisplayInfo, Event, FORMAT, MAX_EVENTS, MAX_SCRIPT_MS, PlaybackOptions, Script, TimedEvent,
    VERSION,
};
use crate::validate::validate;

/// Builds a script from live input events.
///
/// `t` counts from [`Recorder::new`] and is corrected by the time spent paused.
/// While paused, [`Recorder::record`] ignores events. [`Recorder::finish`]
/// appends release events for anything still held, validates the result and
/// stamps the script.
#[derive(Debug)]
pub struct Recorder {
    start: Instant,
    paused_at: Option<Instant>,
    paused_total: Duration,
    events: Vec<TimedEvent>,
    touch: Option<(f64, f64)>,
    mapped: BTreeMap<i32, (f64, f64)>,
    keys: BTreeSet<String>,
}

impl Recorder {
    /// Starts recording at `now`.
    pub fn new(now: Instant) -> Self {
        Self {
            start: now,
            paused_at: None,
            paused_total: Duration::ZERO,
            events: Vec::new(),
            touch: None,
            mapped: BTreeMap::new(),
            keys: BTreeSet::new(),
        }
    }

    /// Records one input event. Events recorded while paused are ignored.
    ///
    /// Returns a usage error when the recording would exceed the v1 limits.
    pub fn record(&mut self, event: Event, now: Instant) -> JidrResult<()> {
        if self.paused_at.is_some() {
            return Ok(());
        }
        let t = self.elapsed_ms(now);
        if t > MAX_SCRIPT_MS {
            return Err(JidrError::usage(
                "the recording exceeds the 24 hour limit; stop it and start a new recording",
            ));
        }
        if self.events.len() >= MAX_EVENTS {
            return Err(JidrError::usage(format!(
                "the recording exceeds the {MAX_EVENTS} event limit; stop it and start a new recording"
            )));
        }
        self.track_held_state(&event);
        self.events.push(TimedEvent { t, event });
        Ok(())
    }

    /// Pauses recording; the wall time spent paused is not recorded.
    pub fn pause(&mut self, now: Instant) {
        if self.paused_at.is_none() {
            self.paused_at = Some(now);
        }
    }

    /// Resumes a paused recording.
    pub fn resume(&mut self, now: Instant) {
        if let Some(paused_at) = self.paused_at.take() {
            self.paused_total += now.saturating_duration_since(paused_at);
        }
    }

    /// Whether recording is currently paused.
    pub fn is_paused(&self) -> bool {
        self.paused_at.is_some()
    }

    /// Number of events recorded so far (release events added by `finish` are
    /// not counted here).
    pub fn event_count(&self) -> usize {
        self.events.len()
    }

    /// Finishes the recording: appends releases for still-held inputs, then
    /// validates and stamps the script.
    pub fn finish(
        self,
        name: impl Into<String>,
        device: impl Into<String>,
        display: DisplayInfo,
        playback: PlaybackOptions,
        now: Instant,
    ) -> JidrResult<Script> {
        let Self {
            events,
            touch,
            mapped,
            keys,
            paused_at,
            paused_total,
            start,
        } = self;
        let elapsed = match paused_at {
            Some(at) => at
                .saturating_duration_since(start)
                .saturating_sub(paused_total),
            None => now
                .saturating_duration_since(start)
                .saturating_sub(paused_total),
        };
        let t = elapsed.as_millis().min(u128::from(u64::MAX)) as u64;
        let mut events = events;
        // Release order (touch, mapped ids ascending, keys ascending) keeps the
        // produced script deterministic.
        if let Some((x, y)) = touch {
            events.push(TimedEvent {
                t,
                event: Event::Touch { x, y, down: false },
            });
        }
        for (id, (x, y)) in mapped {
            events.push(TimedEvent {
                t,
                event: Event::MappedTouch {
                    id,
                    x,
                    y,
                    down: false,
                },
            });
        }
        for key in keys {
            events.push(TimedEvent {
                t,
                event: Event::Key { key, down: false },
            });
        }
        let script = Script {
            format: FORMAT.to_owned(),
            version: VERSION,
            id: Uuid::new_v4(),
            name: name.into(),
            created_at: Utc::now(),
            device: device.into(),
            display,
            playback,
            events,
        };
        validate(&script)?;
        Ok(script)
    }

    /// Elapsed recording time with pauses removed.
    pub fn elapsed(&self, now: Instant) -> Duration {
        match self.paused_at {
            Some(at) => at.saturating_duration_since(self.start),
            None => now.saturating_duration_since(self.start),
        }
        .saturating_sub(self.paused_total)
    }

    fn elapsed_ms(&self, now: Instant) -> u64 {
        self.elapsed(now).as_millis().min(u128::from(u64::MAX)) as u64
    }

    fn track_held_state(&mut self, event: &Event) {
        match event {
            Event::Touch { x, y, down } => {
                self.touch = if *down { Some((*x, *y)) } else { None };
            }
            Event::MappedTouch { id, x, y, down } => {
                if *down {
                    self.mapped.insert(*id, (*x, *y));
                } else {
                    self.mapped.remove(id);
                }
            }
            Event::Key { key, down } => {
                if *down {
                    self.keys.insert(key.clone());
                } else {
                    self.keys.remove(key);
                }
            }
            Event::Text { .. } | Event::Paste { .. } | Event::ToolKey { .. } => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{PlaybackMode, PlaybackOptions};
    use std::time::Duration;

    fn display() -> DisplayInfo {
        DisplayInfo {
            width: 576,
            height: 1280,
        }
    }

    fn playback() -> PlaybackOptions {
        PlaybackOptions {
            mode: PlaybackMode::Count,
            count: 2,
            ..PlaybackOptions::default()
        }
    }

    fn touch(down: bool) -> Event {
        Event::Touch {
            x: 0.5,
            y: 0.4,
            down,
        }
    }

    #[test]
    fn timestamps_are_monotonic_and_pause_is_removed() {
        let start = Instant::now();
        let mut recorder = Recorder::new(start);
        recorder
            .record(touch(true), start + Duration::from_millis(10))
            .expect("record");
        recorder
            .record(
                Event::Key {
                    key: "ENTER".to_owned(),
                    down: true,
                },
                start + Duration::from_millis(20),
            )
            .expect("record");
        recorder.pause(start + Duration::from_millis(30));
        assert!(recorder.is_paused());
        // Events during the pause are ignored.
        recorder
            .record(touch(false), start + Duration::from_millis(40))
            .expect("paused record is a no-op");
        assert_eq!(recorder.event_count(), 2);
        recorder.resume(start + Duration::from_millis(100));
        assert!(!recorder.is_paused());
        recorder
            .record(
                Event::Text {
                    text: "hello".to_owned(),
                },
                start + Duration::from_millis(150),
            )
            .expect("record");
        assert_eq!(recorder.event_count(), 3);

        let script = recorder
            .finish(
                "pause",
                "Phone",
                display(),
                playback(),
                start + Duration::from_millis(200),
            )
            .expect("finish");
        let ts: Vec<u64> = script.events.iter().map(|event| event.t).collect();
        // 10, 20, 150-70=80, then the two releases at 200-70=130.
        assert_eq!(ts, vec![10, 20, 80, 130, 130]);
        assert_eq!(script.name, "pause");
        assert_eq!(script.device, "Phone");
        assert_eq!(script.display, display());
        assert_eq!(script.playback, playback());
        assert_eq!(script.format, FORMAT);
        assert_eq!(script.version, VERSION);
        validate(&script).expect("finished script is valid");
    }

    #[test]
    fn finish_releases_held_touch_mapped_and_key_inputs() {
        let start = Instant::now();
        let mut recorder = Recorder::new(start);
        for event in [
            touch(true),
            Event::MappedTouch {
                id: 5,
                x: 0.25,
                y: 0.75,
                down: true,
            },
            Event::Key {
                key: "SPACE".to_owned(),
                down: true,
            },
            Event::Key {
                key: "A".to_owned(),
                down: true,
            },
        ] {
            recorder
                .record(event, start + Duration::from_millis(5))
                .expect("record");
        }
        // A released key must not be released again by `finish`.
        recorder
            .record(
                Event::Key {
                    key: "A".to_owned(),
                    down: false,
                },
                start + Duration::from_millis(6),
            )
            .expect("record");

        let script = recorder
            .finish(
                "release",
                "",
                display(),
                playback(),
                start + Duration::from_millis(10),
            )
            .expect("finish");
        let releases: Vec<&Event> = script
            .events
            .iter()
            .filter(|event| event.t == 10)
            .map(|event| &event.event)
            .collect();
        assert_eq!(
            releases,
            vec![
                &Event::Touch {
                    x: 0.5,
                    y: 0.4,
                    down: false,
                },
                &Event::MappedTouch {
                    id: 5,
                    x: 0.25,
                    y: 0.75,
                    down: false,
                },
                &Event::Key {
                    key: "SPACE".to_owned(),
                    down: false,
                },
            ]
        );
        validate(&script).expect("finished script is valid");
    }

    #[test]
    fn finish_while_paused_freezes_the_timeline() {
        let start = Instant::now();
        let mut recorder = Recorder::new(start);
        recorder.record(touch(true), start).expect("record");
        recorder.pause(start + Duration::from_millis(50));
        // Finish much later: while paused the timeline must not grow, so the
        // added touch release is stamped at the pause instant, not at 5 s.
        let script = recorder
            .finish(
                "paused",
                "",
                display(),
                playback(),
                start + Duration::from_secs(5),
            )
            .expect("finish while paused");
        assert_eq!(script.events.last().map(|event| event.t), Some(50));
    }

    #[test]
    fn empty_recordings_are_rejected_at_finish() {
        let start = Instant::now();
        let recorder = Recorder::new(start);
        let error = recorder
            .finish("empty", "", display(), playback(), start)
            .expect_err("empty recording");
        assert_eq!(error.code, jidr_core::ErrorCode::Usage);
        assert!(error.message.contains("no events"), "{}", error.message);
    }

    #[test]
    fn event_cap_is_enforced_at_record_time() {
        let start = Instant::now();
        let mut recorder = Recorder::new(start);
        for _ in 0..MAX_EVENTS {
            recorder
                .record(
                    Event::Text {
                        text: "x".to_owned(),
                    },
                    start,
                )
                .expect("record");
        }
        let error = recorder
            .record(
                Event::Text {
                    text: "y".to_owned(),
                },
                start,
            )
            .expect_err("event cap");
        assert_eq!(error.code, jidr_core::ErrorCode::Usage);
        assert!(error.message.contains("event limit"), "{}", error.message);
        std::mem::drop(recorder);
    }
}
