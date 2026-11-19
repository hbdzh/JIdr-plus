//! The on-disk operation-recording format (v1), playback options and summaries.
//!
//! A script is portable JSON: a normalized input timeline that the player
//! bridge replays locally. See `docs/player-scripts.md` for the contract.

use chrono::{DateTime, SecondsFormat, Utc};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::collections::HashSet;
use uuid::Uuid;

/// Magic value of the operation-recording JSON format.
pub const FORMAT: &str = "jidr.operation-recording";
/// Current format version; a script with another version is rejected.
pub const VERSION: u32 = 1;

/// Script name limit, in `char`s (the UI counts characters, not bytes).
pub const MAX_NAME_CHARS: usize = 80;
/// Device-name snapshot limit, in `char`s. May be empty.
pub const MAX_DEVICE_CHARS: usize = 120;
/// Maximum events in one script.
pub const MAX_EVENTS: usize = 200_000;
/// Longest recording or playback payload: 24 h of event timestamps.
pub const MAX_SCRIPT_MS: u64 = 24 * 60 * 60 * 1000;
/// Maximum key string length, in bytes (same bound the bridge enforces).
pub const MAX_KEY_BYTES: usize = 64;
/// Maximum text/paste payload, in bytes (same bound the bridge enforces).
pub const MAX_TEXT_BYTES: usize = 1024 * 1024;
/// Slowest and fastest playback speeds.
pub const MIN_SPEED: f64 = 0.25;
pub const MAX_SPEED: f64 = 4.0;
/// Maximum loop count for the `count` playback mode.
pub const MAX_COUNT: u32 = 1000;
/// Loop interval limit: one day (values are real time, never sped up).
pub const MAX_INTERVAL_MS: u64 = 24 * 60 * 60 * 1000;
/// Display-size bounds used by the compatibility warning.
pub const MAX_DISPLAY: u32 = 8192;
/// Valid `mapped_touch` identifiers.
pub const MAPPED_ID_MIN: i32 = 3;
pub const MAPPED_ID_MAX: i32 = 9;

/// One recorded display size (shown-screen pixels).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct DisplayInfo {
    pub width: u32,
    pub height: u32,
}

/// A timed input event: `t` is milliseconds from the recording start.
///
/// The event payload is flattened into the same JSON object
/// (`{"t": 80, "type": "touch", ...}`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TimedEvent {
    pub t: u64,
    #[serde(flatten)]
    pub event: Event,
}

/// The recorded input events. Deliberately has no `rotate` variant: rotation is
/// not recorded in v1 and a script containing it is invalid.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    /// A normalised single-finger touch (0…1 shown-screen coordinates).
    Touch { x: f64, y: f64, down: bool },
    /// A mapped-touch input (the player's key-mapping touch ids 3…9).
    MappedTouch { id: i32, x: f64, y: f64, down: bool },
    /// A key press or release (`ENTER`, `SPACE`, `A`, …).
    Key { key: String, down: bool },
    /// Committed text input.
    Text { text: String },
    /// Clipboard paste input.
    Paste { text: String },
    /// A player tool key (`back`, `home`, `volume_up`, …).
    ToolKey { key: String },
}

impl Event {
    /// Whether the event is within the v1 format bounds (finite 0…1
    /// coordinates, valid mapped-touch id, non-empty key within the size
    /// limit, text within the size limit). Recording and input sync share this
    /// check, so one malformed UI command can never poison a stream.
    pub fn fits_format(&self) -> bool {
        let unit = |v: f64| v.is_finite() && (0.0..=1.0).contains(&v);
        match self {
            Event::Touch { x, y, .. } => unit(*x) && unit(*y),
            Event::MappedTouch { id, x, y, .. } => {
                (MAPPED_ID_MIN..=MAPPED_ID_MAX).contains(id) && unit(*x) && unit(*y)
            }
            Event::Key { key, .. } | Event::ToolKey { key } => {
                !key.is_empty() && key.len() <= MAX_KEY_BYTES
            }
            Event::Text { text } | Event::Paste { text } => text.len() <= MAX_TEXT_BYTES,
        }
    }
}

/// How many times (or how long) a script plays.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum PlaybackMode {
    /// Play `count` times.
    #[default]
    Count,
    /// Keep replaying for `duration_ms` of real time.
    Duration,
    /// Loop until stopped.
    Infinite,
}

/// Last-used playback defaults, also used for a single run with overrides.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PlaybackOptions {
    pub mode: PlaybackMode,
    pub count: u32,
    pub duration_ms: u64,
    pub interval_ms: u64,
    pub speed: f64,
}

impl Default for PlaybackOptions {
    fn default() -> Self {
        Self {
            mode: PlaybackMode::Count,
            count: 1,
            duration_ms: 0,
            interval_ms: 0,
            speed: 1.0,
        }
    }
}

/// A stored operation recording.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Script {
    /// Always [`FORMAT`]; validated on load.
    pub format: String,
    /// Always [`VERSION`]; validated on load.
    pub version: u32,
    pub id: Uuid,
    pub name: String,
    #[serde(
        serialize_with = "serialize_time",
        deserialize_with = "deserialize_time"
    )]
    pub created_at: DateTime<Utc>,
    /// Device name snapshot; used for display only.
    pub device: String,
    pub display: DisplayInfo,
    /// Last-used defaults; the UI may override them for a run.
    pub playback: PlaybackOptions,
    pub events: Vec<TimedEvent>,
}

impl Script {
    /// Total playback length: the timestamp of the last event.
    pub fn duration_ms(&self) -> u64 {
        self.events.last().map_or(0, |event| event.t)
    }

    /// The compact form sent to the UI in list/notification payloads.
    pub fn summary(&self) -> ScriptSummary {
        ScriptSummary {
            id: self.id,
            name: self.name.clone(),
            duration_ms: self.duration_ms(),
            event_count: self.events.len(),
            action_count: self.action_count(),
            created_at: self.created_at,
            display: self.display,
        }
    }

    /// Count touch gestures, key presses and discrete commands for display.
    fn action_count(&self) -> usize {
        let mut count = 0;
        let mut touch = false;
        let mut mapped = HashSet::new();
        let mut keys = HashSet::new();
        for timed in &self.events {
            match &timed.event {
                Event::Touch { down, .. } => {
                    if *down && !touch && mapped.is_empty() {
                        count += 1;
                    }
                    touch = *down;
                }
                Event::MappedTouch { id, down, .. } => {
                    if *down {
                        if !touch && mapped.is_empty() {
                            count += 1;
                        }
                        mapped.insert(*id);
                    } else {
                        mapped.remove(id);
                    }
                }
                Event::Key { key, down } => {
                    if *down {
                        if keys.insert(key) {
                            count += 1;
                        }
                    } else {
                        keys.remove(key);
                    }
                }
                Event::Text { .. } | Event::Paste { .. } | Event::ToolKey { .. } => count += 1,
            }
        }
        count
    }
}

/// One script as listed by the player's operation-recording window.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ScriptSummary {
    pub id: Uuid,
    pub name: String,
    pub duration_ms: u64,
    pub event_count: usize,
    /// Display count; the underlying event timeline remains unchanged.
    #[serde(default)]
    pub action_count: usize,
    #[serde(
        serialize_with = "serialize_time",
        deserialize_with = "deserialize_time"
    )]
    pub created_at: DateTime<Utc>,
    pub display: DisplayInfo,
}

/// Serialises timestamps as UTC RFC 3339 with millisecond precision
/// (`2026-11-12T01:00:00.000Z`), the documented script format.
fn serialize_time<S: Serializer>(value: &DateTime<Utc>, serializer: S) -> Result<S::Ok, S::Error> {
    serializer.serialize_str(&value.to_rfc3339_opts(SecondsFormat::Millis, true))
}

fn deserialize_time<'de, D: Deserializer<'de>>(deserializer: D) -> Result<DateTime<Utc>, D::Error> {
    let text = String::deserialize(deserializer)?;
    DateTime::parse_from_rfc3339(&text)
        .map(|value| value.with_timezone(&Utc))
        .map_err(serde::de::Error::custom)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::{fixture, timed};

    #[test]
    fn summaries_count_gestures_without_changing_the_event_timeline() {
        let mut script = fixture();
        script.events.clear();
        let touch = |down| Event::Touch {
            x: 0.5,
            y: 0.5,
            down,
        };
        script.events.push(timed(0, touch(true)));
        script.events.push(timed(1, touch(false)));
        for _ in 0..16 {
            script.events.push(timed(2, touch(true)));
        }
        script.events.push(timed(3, touch(false)));
        for _ in 0..14 {
            script.events.push(timed(4, touch(true)));
        }
        script.events.push(timed(5, touch(false)));
        script.events.push(timed(6, touch(true)));
        script.events.push(timed(7, touch(false)));
        let before = serde_json::to_value(&script).expect("serialize script");
        let summary = script.summary();
        assert_eq!(summary.event_count, 36);
        assert_eq!(summary.action_count, 4);
        assert_eq!(
            serde_json::to_value(&script).expect("serialize script"),
            before
        );
    }

    #[test]
    fn summaries_group_multitouch_and_count_keys_and_discrete_commands() {
        let mut script = fixture();
        let mapped = |id, down| Event::MappedTouch {
            id,
            x: 0.5,
            y: 0.5,
            down,
        };
        let touch = |down| Event::Touch {
            x: 0.5,
            y: 0.5,
            down,
        };
        let key = |name: &str, down| Event::Key {
            key: name.to_owned(),
            down,
        };
        script.events = vec![
            timed(0, mapped(3, true)),
            timed(1, touch(true)),
            timed(2, mapped(3, true)),
            timed(3, mapped(3, false)),
            timed(4, touch(false)),
            timed(5, mapped(4, true)),
            timed(6, mapped(4, false)),
            timed(7, key("A", true)),
            timed(8, key("A", true)),
            timed(9, key("B", true)),
            timed(10, key("A", false)),
            timed(11, key("B", false)),
            timed(
                12,
                Event::Text {
                    text: "hello".into(),
                },
            ),
            timed(
                13,
                Event::Paste {
                    text: "world".into(),
                },
            ),
            timed(14, Event::ToolKey { key: "home".into() }),
        ];
        assert_eq!(script.summary().action_count, 7);
        assert_eq!(script.summary().event_count, 15);
    }

    #[test]
    fn round_trips_every_event_variant_through_json() {
        let mut script = fixture();
        script.events = vec![
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
                Event::MappedTouch {
                    id: 4,
                    x: 0.25,
                    y: 0.75,
                    down: true,
                },
            ),
            timed(
                120,
                Event::Key {
                    key: "ENTER".to_owned(),
                    down: true,
                },
            ),
            timed(
                140,
                Event::Text {
                    text: "hello".to_owned(),
                },
            ),
            timed(
                160,
                Event::Paste {
                    text: "pasted".to_owned(),
                },
            ),
            timed(
                180,
                Event::ToolKey {
                    key: "back".to_owned(),
                },
            ),
        ];
        let value = serde_json::to_value(&script).expect("serialise");
        assert_eq!(value["format"], FORMAT);
        assert_eq!(value["version"], VERSION);
        assert_eq!(value["events"][0]["type"], "touch");
        assert_eq!(value["events"][0]["t"], 0);
        assert_eq!(value["events"][1]["type"], "mapped_touch");
        assert_eq!(value["events"][1]["id"], 4);
        assert_eq!(value["events"][2]["type"], "key");
        assert_eq!(value["events"][3]["type"], "text");
        assert_eq!(value["events"][4]["type"], "paste");
        assert_eq!(value["events"][5]["type"], "tool_key");
        let created = value["created_at"].as_str().expect("created_at string");
        assert!(created.ends_with('Z'), "created_at is UTC: {created}");
        assert!(
            created.contains(".000Z"),
            "millisecond precision: {created}"
        );
        let back: Script = serde_json::from_value(value).expect("deserialise");
        assert_eq!(back, script);
    }

    #[test]
    fn rejects_unknown_event_types_such_as_rotate() {
        let json = serde_json::json!({
            "format": FORMAT,
            "version": VERSION,
            "id": Uuid::nil(),
            "name": "rotate",
            "created_at": "2026-11-12T01:00:00.000Z",
            "device": "Phone",
            "display": {"width": 576, "height": 1280},
            "playback": {"mode": "count", "count": 1, "duration_ms": 0, "interval_ms": 0, "speed": 1.0},
            "events": [{"t": 0, "type": "rotate", "direction": 1}],
        });
        let error = serde_json::from_value::<Script>(json).expect_err("rotate is not an event");
        assert!(
            error.to_string().contains("rotate"),
            "the error names the offending type: {error}"
        );
    }

    #[test]
    fn playback_options_default_when_the_payload_omits_fields() {
        let options: PlaybackOptions =
            serde_json::from_value(serde_json::json!({"speed": 2.0})).expect("partial options");
        assert_eq!(options.mode, PlaybackMode::Count);
        assert_eq!(options.count, 1);
        assert_eq!(options.interval_ms, 0);
        assert!((options.speed - 2.0).abs() < f64::EPSILON);
    }

    #[test]
    fn summary_reports_the_last_timestamp() {
        let mut script = fixture();
        script.events = vec![
            timed(
                100,
                Event::Text {
                    text: "a".to_owned(),
                },
            ),
            timed(
                900,
                Event::Text {
                    text: "b".to_owned(),
                },
            ),
        ];
        let summary = script.summary();
        assert_eq!(summary.duration_ms, 900);
        assert_eq!(summary.event_count, 2);
        assert_eq!(summary.id, script.id);
        assert_eq!(summary.name, script.name);
        assert_eq!(summary.display, script.display);
        assert_eq!(summary.created_at, script.created_at);
    }
}
