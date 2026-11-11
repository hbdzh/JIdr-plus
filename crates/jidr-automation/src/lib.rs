//! Jidr operation recordings: the player's MuMu-style input recorder.
//!
//! A recording is a portable JSON timeline of normalised input events
//! ([`Script`]) that the player bridge records and replays locally. This crate
//! is pure Rust (no UI, daemon or protocol dependency) so the bridge, the
//! SwiftUI player and later clients share one format and one validator.
//!
//! - Model types: [`Script`], [`Event`], [`TimedEvent`], [`DisplayInfo`],
//!   [`PlaybackOptions`], [`PlaybackMode`], [`ScriptSummary`].
//! - [`validate`] checks the v1 rules (version, limits, monotonic timestamps,
//!   coordinates, playback ranges).
//! - [`Recorder`] builds a script from live events, corrects timestamps across
//!   pauses and releases anything still held when the recording ends.
//! - [`ScriptStore`] is the `<Jidr data>/scripts/` library: list, load, save,
//!   delete, rename, import and export.
//!
//! ```no_run
//! use std::time::Instant;
//!
//! use jidr_automation::{DisplayInfo, Event, PlaybackOptions, Recorder};
//!
//! # fn main() -> Result<(), jidr_core::JidrError> {
//! let start = Instant::now();
//! let mut recorder = Recorder::new(start);
//! recorder.record(Event::ToolKey { key: "back".to_owned() }, start)?;
//! let script = recorder.finish(
//!     "Daily check-in",
//!     "Phone 6.1 FHD+",
//!     DisplayInfo { width: 576, height: 1280 },
//!     PlaybackOptions::default(),
//!     start,
//! )?;
//! assert_eq!(script.events.len(), 1);
//! # Ok(())
//! # }
//! ```

mod model;
mod recorder;
mod store;
mod validate;

#[cfg(test)]
pub(crate) mod test_support;

pub use model::{
    DisplayInfo, Event, FORMAT, MAPPED_ID_MAX, MAPPED_ID_MIN, MAX_COUNT, MAX_DEVICE_CHARS,
    MAX_DISPLAY, MAX_EVENTS, MAX_INTERVAL_MS, MAX_KEY_BYTES, MAX_NAME_CHARS, MAX_SCRIPT_MS,
    MAX_SPEED, MAX_TEXT_BYTES, MIN_SPEED, PlaybackMode, PlaybackOptions, Script, ScriptSummary,
    TimedEvent, VERSION,
};
pub use recorder::Recorder;
pub use store::{MAX_SCRIPT_BYTES, ScriptStore};
pub use validate::validate;
