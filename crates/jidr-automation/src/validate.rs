//! Structural validation of scripts and playback options.
//!
//! Deserialisation only checks JSON shape (serde). Everything the bridge and
//! the UI rely on — version, limits, monotonic timestamps, normalised
//! coordinates — is enforced here with [`jidr_core::JidrError::usage`], so the
//! player can report a clear message instead of crashing or misbehaving.

use jidr_core::{JidrError, JidrResult};

use crate::model::{
    DisplayInfo, Event, FORMAT, MAPPED_ID_MAX, MAPPED_ID_MIN, MAX_COUNT, MAX_DEVICE_CHARS,
    MAX_DISPLAY, MAX_EVENTS, MAX_INTERVAL_MS, MAX_KEY_BYTES, MAX_NAME_CHARS, MAX_SCRIPT_MS,
    MAX_SPEED, MAX_TEXT_BYTES, MIN_SPEED, PlaybackMode, PlaybackOptions, Script, VERSION,
};

/// Validates a script loaded from disk or produced by the recorder.
pub fn validate(script: &Script) -> JidrResult<()> {
    if script.format != FORMAT {
        return Err(JidrError::usage(format!(
            "not a Jidr operation recording: expected format {FORMAT:?}, found {:?}",
            script.format
        )));
    }
    if script.version != VERSION {
        return Err(JidrError::usage(format!(
            "unsupported operation-recording version {}: this build reads version {VERSION}",
            script.version
        )));
    }
    validate_name(&script.name)?;
    if script.device.chars().count() > MAX_DEVICE_CHARS {
        return Err(JidrError::usage(format!(
            "the device name must be at most {MAX_DEVICE_CHARS} characters"
        )));
    }
    validate_display(script.display)?;
    script.playback.validate()?;
    if script.events.is_empty() {
        return Err(JidrError::usage("the recording contains no events"));
    }
    if script.events.len() > MAX_EVENTS {
        return Err(JidrError::usage(format!(
            "the recording contains {} events; the maximum is {MAX_EVENTS}",
            script.events.len()
        )));
    }
    let mut previous = 0;
    for (index, timed) in script.events.iter().enumerate() {
        if timed.t < previous {
            return Err(JidrError::usage(format!(
                "event {index}: timestamp {} is before the previous timestamp {previous}",
                timed.t
            )));
        }
        previous = timed.t;
        if timed.t > MAX_SCRIPT_MS {
            return Err(JidrError::usage(format!(
                "event {index}: timestamp {} is beyond the 24 hour limit",
                timed.t
            )));
        }
        validate_event(&timed.event, index)?;
    }
    Ok(())
}

/// Validates a script name (also used by the store's rename).
pub(crate) fn validate_name(name: &str) -> JidrResult<()> {
    if name.trim().is_empty() {
        return Err(JidrError::usage("the script name must not be empty"));
    }
    let chars = name.chars().count();
    if chars > MAX_NAME_CHARS {
        return Err(JidrError::usage(format!(
            "the script name must be at most {MAX_NAME_CHARS} characters"
        )));
    }
    Ok(())
}

fn validate_display(display: DisplayInfo) -> JidrResult<()> {
    if display.width == 0
        || display.height == 0
        || display.width > MAX_DISPLAY
        || display.height > MAX_DISPLAY
    {
        return Err(JidrError::usage(format!(
            "display size {}×{} is out of range (1…{MAX_DISPLAY})",
            display.width, display.height
        )));
    }
    Ok(())
}

fn validate_event(event: &Event, index: usize) -> JidrResult<()> {
    match event {
        Event::Touch { x, y, .. } => validate_point(*x, *y, index),
        Event::MappedTouch { id, x, y, .. } => {
            if !(MAPPED_ID_MIN..=MAPPED_ID_MAX).contains(id) {
                return Err(JidrError::usage(format!(
                    "event {index}: mapped touch id {id} is out of range ({MAPPED_ID_MIN}…{MAPPED_ID_MAX})"
                )));
            }
            validate_point(*x, *y, index)
        }
        Event::Key { key, .. } => validate_key(key, index),
        Event::ToolKey { key } => validate_tool_key(key, index),
        Event::Text { text } => validate_text(text, index),
        Event::Paste { text } => validate_text(text, index),
    }
}

fn validate_point(x: f64, y: f64, index: usize) -> JidrResult<()> {
    if !x.is_finite() || !y.is_finite() || !(0.0..=1.0).contains(&x) || !(0.0..=1.0).contains(&y) {
        return Err(JidrError::usage(format!(
            "event {index}: touch coordinates must be numbers between 0 and 1 (found {x}, {y})"
        )));
    }
    Ok(())
}

fn validate_key(key: &str, index: usize) -> JidrResult<()> {
    if key.is_empty() || key.len() > MAX_KEY_BYTES {
        return Err(JidrError::usage(format!(
            "event {index}: a key must be 1…{MAX_KEY_BYTES} bytes"
        )));
    }
    Ok(())
}

fn validate_tool_key(key: &str, index: usize) -> JidrResult<()> {
    if key.is_empty() || key.len() > MAX_KEY_BYTES {
        return Err(JidrError::usage(format!(
            "event {index}: a tool key must be 1…{MAX_KEY_BYTES} bytes"
        )));
    }
    Ok(())
}

fn validate_text(text: &str, index: usize) -> JidrResult<()> {
    if text.len() > MAX_TEXT_BYTES {
        return Err(JidrError::usage(format!(
            "event {index}: text is larger than {MAX_TEXT_BYTES} bytes"
        )));
    }
    Ok(())
}

impl PlaybackOptions {
    /// Validates the ranges the playback engine accepts.
    pub fn validate(&self) -> JidrResult<()> {
        if !self.speed.is_finite() || !(MIN_SPEED..=MAX_SPEED).contains(&self.speed) {
            return Err(JidrError::usage(format!(
                "playback speed must be between ×{MIN_SPEED} and ×{MAX_SPEED}"
            )));
        }
        if self.count > MAX_COUNT {
            return Err(JidrError::usage(format!(
                "playback count must be at most {MAX_COUNT}"
            )));
        }
        if self.mode == PlaybackMode::Count && self.count == 0 {
            return Err(JidrError::usage(
                "playback count mode needs a count of at least 1",
            ));
        }
        if self.duration_ms > MAX_SCRIPT_MS {
            return Err(JidrError::usage(
                "playback duration must be at most 24 hours",
            ));
        }
        if self.mode == PlaybackMode::Duration && self.duration_ms == 0 {
            return Err(JidrError::usage(
                "playback duration mode needs a duration of at least 1 ms",
            ));
        }
        if self.interval_ms > MAX_INTERVAL_MS {
            return Err(JidrError::usage(
                "the loop interval must be at most 24 hours",
            ));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{Event, PlaybackMode, TimedEvent};
    use crate::test_support::{fixture, timed};

    fn error(script: &Script) -> String {
        validate(script)
            .expect_err("script should be rejected")
            .message
    }

    #[test]
    fn accepts_the_documented_fixture() {
        let mut script = fixture();
        script.events = vec![
            TimedEvent {
                t: 0,
                event: Event::Touch {
                    x: 0.5,
                    y: 0.4,
                    down: true,
                },
            },
            TimedEvent {
                t: 80,
                event: Event::Touch {
                    x: 0.5,
                    y: 0.4,
                    down: false,
                },
            },
        ];
        validate(&script).expect("valid script");
    }

    #[test]
    fn rejects_bad_headers_and_names() {
        let mut script = fixture();
        script.format = "something.else".to_owned();
        assert!(error(&script).contains("format"));

        let mut script = fixture();
        script.version = 2;
        assert!(error(&script).contains("version"));

        let mut script = fixture();
        script.name = "   ".to_owned();
        assert!(error(&script).contains("name"));

        let mut script = fixture();
        script.name = "x".repeat(MAX_NAME_CHARS + 1);
        assert!(error(&script).contains("name"));

        let mut script = fixture();
        script.name = "名".repeat(MAX_NAME_CHARS); // 80 characters, 240 bytes
        validate(&script).expect("character count, not byte count, bounds the name");
    }

    #[test]
    fn rejects_bad_display_and_empty_or_huge_event_lists() {
        let mut script = fixture();
        script.display = DisplayInfo {
            width: 0,
            height: 1280,
        };
        assert!(error(&script).contains("display"));

        let mut script = fixture();
        script.display = DisplayInfo {
            width: MAX_DISPLAY + 1,
            height: 1280,
        };
        assert!(error(&script).contains("display"));

        let mut script = fixture();
        script.events.clear();
        assert!(error(&script).contains("no events"));

        let mut script = fixture();
        script.events = vec![
            timed(
                0,
                Event::Text {
                    text: String::new()
                }
            );
            MAX_EVENTS + 1
        ];
        assert!(error(&script).contains("events"));
    }

    #[test]
    fn rejects_non_monotonic_timestamps_and_bad_coordinates() {
        let mut script = fixture();
        script.events = vec![
            timed(
                100,
                Event::Text {
                    text: "a".to_owned(),
                },
            ),
            timed(
                90,
                Event::Text {
                    text: "b".to_owned(),
                },
            ),
        ];
        assert!(error(&script).contains("timestamp"));

        let mut script = fixture();
        script.events = vec![timed(
            MAX_SCRIPT_MS + 1,
            Event::Text {
                text: "a".to_owned(),
            },
        )];
        assert!(error(&script).contains("24 hour"));

        for (x, y) in [
            (1.5, 0.5),
            (-0.1, 0.5),
            (0.5, f64::NAN),
            (0.5, f64::INFINITY),
        ] {
            let mut script = fixture();
            script.events = vec![timed(0, Event::Touch { x, y, down: true })];
            assert!(
                error(&script).contains("coordinates"),
                "must reject {x},{y}"
            );
        }
    }

    #[test]
    fn rejects_bad_mapped_ids_keys_and_text() {
        let mut script = fixture();
        script.events = vec![timed(
            0,
            Event::MappedTouch {
                id: MAPPED_ID_MIN - 1,
                x: 0.5,
                y: 0.5,
                down: true,
            },
        )];
        assert!(error(&script).contains("mapped touch id"));

        for key in [String::new(), "k".repeat(MAX_KEY_BYTES + 1)] {
            let mut script = fixture();
            script.events = vec![timed(
                0,
                Event::Key {
                    key: key.clone(),
                    down: true,
                },
            )];
            assert!(error(&script).contains("key"), "must reject {key:?}");

            let mut script = fixture();
            script.events = vec![timed(0, Event::ToolKey { key: key.clone() })];
            assert!(error(&script).contains("tool key"), "must reject {key:?}");
        }

        let mut script = fixture();
        script.events = vec![timed(
            0,
            Event::Paste {
                text: "x".repeat(MAX_TEXT_BYTES + 1),
            },
        )];
        assert!(error(&script).contains("text"));
    }

    #[test]
    fn validates_playback_option_ranges() {
        let cases = [
            PlaybackOptions {
                speed: 0.1,
                ..PlaybackOptions::default()
            },
            PlaybackOptions {
                speed: 5.0,
                ..PlaybackOptions::default()
            },
            PlaybackOptions {
                speed: f64::NAN,
                ..PlaybackOptions::default()
            },
            PlaybackOptions {
                count: 0,
                ..PlaybackOptions::default()
            },
            PlaybackOptions {
                count: MAX_COUNT + 1,
                ..PlaybackOptions::default()
            },
            PlaybackOptions {
                mode: PlaybackMode::Duration,
                duration_ms: 0,
                ..PlaybackOptions::default()
            },
            PlaybackOptions {
                duration_ms: MAX_SCRIPT_MS + 1,
                ..PlaybackOptions::default()
            },
            PlaybackOptions {
                interval_ms: MAX_INTERVAL_MS + 1,
                ..PlaybackOptions::default()
            },
        ];
        for options in cases {
            let mut script = fixture();
            script.playback = options;
            assert!(validate(&script).is_err(), "must reject {options:?}");
        }

        let mut script = fixture();
        script.playback = PlaybackOptions {
            mode: PlaybackMode::Infinite,
            count: 0,
            duration_ms: 0,
            interval_ms: 500,
            speed: 4.0,
        };
        validate(&script).expect("infinite mode ignores count/duration");
    }
}
