//! Shared test fixtures (built only for `cfg(test)`).

use chrono::DateTime;
use uuid::Uuid;

use crate::model::{DisplayInfo, Event, FORMAT, PlaybackOptions, Script, TimedEvent, VERSION};

/// Builds one timed event.
pub(crate) fn timed(t: u64, event: Event) -> TimedEvent {
    TimedEvent { t, event }
}

/// A minimal valid script used as a base for the unit tests.
pub(crate) fn fixture() -> Script {
    Script {
        format: FORMAT.to_owned(),
        version: VERSION,
        id: Uuid::from_u128(1),
        name: "每日签到".to_owned(),
        created_at: DateTime::from_timestamp_millis(1_700_000_000_000)
            .expect("valid fixture timestamp"),
        device: "Phone 6.1 FHD+".to_owned(),
        display: DisplayInfo {
            width: 576,
            height: 1280,
        },
        playback: PlaybackOptions::default(),
        events: vec![timed(
            0,
            Event::Text {
                text: "hello".to_owned(),
            },
        )],
    }
}
