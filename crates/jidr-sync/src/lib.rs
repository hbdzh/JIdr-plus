//! Pure logic of the multi-device input synchronizer (D45).
//!
//! No I/O lives here: the daemon owns the session (`sync.*` commands), the
//! player bridges inject input. This crate holds what both sides must agree
//! on:
//!
//! - [`session`]: the session model, its options and membership rules;
//! - [`adapt`]: which events are forwarded and how coordinates map between
//!   screens of different shapes;
//! - [`queue`]: the bounded per-follower queue that coalesces touch moves
//!   under load and never drops a down, an up, a key or text;
//! - [`seq`]: ordering checks for the relayed event stream.

pub mod adapt;
pub mod queue;
pub mod seq;
pub mod session;

pub use adapt::{Adaptation, adapt, allows, forward};
pub use queue::{FollowerQueue, OVERFLOW_LIMIT, PushOutcome, Queued};
pub use seq::{SeqCheck, SeqTracker};
pub use session::{
    DisplaySize, Follower, FollowerCounters, FollowerStatus, MAX_JITTER_MS, MAX_MEMBERS,
    SyncOptions, SyncOptionsPatch, SyncSession, validate_members,
};
