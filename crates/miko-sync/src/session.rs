//! The sync session: who takes part, who leads, and the options.

use chrono::{DateTime, Utc};
use miko_core::{MikoError, MikoResult};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::adapt::Adaptation;

/// The most devices one session may hold (leader included).
pub const MAX_MEMBERS: usize = 16;
/// The largest per-follower random delay, in milliseconds.
pub const MAX_JITTER_MS: u8 = 20;

/// The shown-screen size of a device in pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct DisplaySize {
    pub width: u32,
    pub height: u32,
}

impl DisplaySize {
    /// A positive size within the same bound the recording format uses.
    pub fn is_valid(self) -> bool {
        (1..=miko_automation::MAX_DISPLAY).contains(&self.width)
            && (1..=miko_automation::MAX_DISPLAY).contains(&self.height)
    }
}

/// What a session forwards and how.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(default)]
pub struct SyncOptions {
    /// Coordinate mapping between screens of different shapes.
    pub adaptation: Adaptation,
    /// Forward key presses and releases.
    pub sync_keyboard: bool,
    /// Forward committed text and paste.
    pub sync_text: bool,
    /// Forward back, home, recents, volume and power.
    pub sync_tool_keys: bool,
    /// Ignore direct input on followers while the session is active.
    pub lock_followers: bool,
    /// Random extra delay per follower, 0 to 20 ms.
    pub jitter_ms: u8,
}

impl Default for SyncOptions {
    fn default() -> Self {
        Self {
            adaptation: Adaptation::Stretch,
            sync_keyboard: true,
            sync_text: true,
            sync_tool_keys: true,
            lock_followers: true,
            jitter_ms: 0,
        }
    }
}

impl SyncOptions {
    pub fn validate(&self) -> MikoResult<()> {
        if self.jitter_ms > MAX_JITTER_MS {
            return Err(MikoError::usage(format!(
                "jitter_ms must be at most {MAX_JITTER_MS}"
            )));
        }
        Ok(())
    }

    /// The options with `patch` applied, validated.
    pub fn patched(&self, patch: &SyncOptionsPatch) -> MikoResult<Self> {
        let next = Self {
            adaptation: patch.adaptation.unwrap_or(self.adaptation),
            sync_keyboard: patch.sync_keyboard.unwrap_or(self.sync_keyboard),
            sync_text: patch.sync_text.unwrap_or(self.sync_text),
            sync_tool_keys: patch.sync_tool_keys.unwrap_or(self.sync_tool_keys),
            lock_followers: patch.lock_followers.unwrap_or(self.lock_followers),
            jitter_ms: patch.jitter_ms.unwrap_or(self.jitter_ms),
        };
        next.validate()?;
        Ok(next)
    }
}

/// A partial change to [`SyncOptions`]; omitted fields stay as they are.
#[derive(Debug, Clone, Default, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SyncOptionsPatch {
    #[serde(default)]
    pub adaptation: Option<Adaptation>,
    #[serde(default)]
    pub sync_keyboard: Option<bool>,
    #[serde(default)]
    pub sync_text: Option<bool>,
    #[serde(default)]
    pub sync_tool_keys: Option<bool>,
    #[serde(default)]
    pub lock_followers: Option<bool>,
    #[serde(default)]
    pub jitter_ms: Option<u8>,
}

/// How one follower is doing.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case", tag = "state")]
pub enum FollowerStatus {
    /// Receiving events in step with the leader.
    Ready,
    /// Its queue is filling up; some moves may be dropped.
    Lagging,
    /// It lost events or its bridge failed; the leader and the other
    /// followers are not affected.
    Error { message: String },
    /// Its player is gone; it receives nothing until it is ready again.
    Detached,
}

/// Running totals for one follower.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct FollowerCounters {
    pub forwarded: u64,
    pub dropped: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Follower {
    pub device: Uuid,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display: Option<DisplaySize>,
    pub status: FollowerStatus,
    pub counters: FollowerCounters,
}

impl Follower {
    fn new(device: Uuid) -> Self {
        Self {
            device,
            display: None,
            status: FollowerStatus::Ready,
            counters: FollowerCounters::default(),
        }
    }
}

/// What removing a device did to the session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Removed {
    NotMember,
    Follower,
    /// The leader left; the session cannot continue.
    Leader,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SyncSession {
    pub id: Uuid,
    pub leader: Uuid,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub leader_display: Option<DisplaySize>,
    pub followers: Vec<Follower>,
    pub options: SyncOptions,
    pub started_at: DateTime<Utc>,
}

/// Checks a member list: a leader, 1 or more followers, no duplicates, at
/// most [`MAX_MEMBERS`] devices in all.
pub fn validate_members(leader: Uuid, followers: &[Uuid]) -> MikoResult<()> {
    if followers.is_empty() {
        return Err(MikoError::usage(
            "sync needs a leader and at least one follower",
        ));
    }
    if followers.len() + 1 > MAX_MEMBERS {
        return Err(MikoError::usage(format!(
            "a sync session holds at most {MAX_MEMBERS} devices"
        )));
    }
    if followers.contains(&leader) {
        return Err(MikoError::usage("the leader cannot also be a follower"));
    }
    for (i, device) in followers.iter().enumerate() {
        if followers[..i].contains(device) {
            return Err(MikoError::usage("a device is listed twice"));
        }
    }
    Ok(())
}

impl SyncSession {
    pub fn new(
        leader: Uuid,
        followers: &[Uuid],
        options: SyncOptions,
        now: DateTime<Utc>,
    ) -> MikoResult<Self> {
        validate_members(leader, followers)?;
        options.validate()?;
        Ok(Self {
            id: Uuid::new_v4(),
            leader,
            leader_display: None,
            followers: followers.iter().copied().map(Follower::new).collect(),
            options,
            started_at: now,
        })
    }

    /// The leader first, then the followers in join order.
    pub fn members(&self) -> Vec<Uuid> {
        std::iter::once(self.leader)
            .chain(self.followers.iter().map(|f| f.device))
            .collect()
    }

    pub fn contains(&self, device: Uuid) -> bool {
        self.leader == device || self.followers.iter().any(|f| f.device == device)
    }

    /// A session needs at least one follower to mean anything.
    pub fn is_viable(&self) -> bool {
        !self.followers.is_empty()
    }

    pub fn add_follower(&mut self, device: Uuid) -> MikoResult<()> {
        if self.contains(device) {
            return Err(MikoError::usage("the device is already in the session"));
        }
        if self.followers.len() + 1 >= MAX_MEMBERS {
            return Err(MikoError::usage(format!(
                "a sync session holds at most {MAX_MEMBERS} devices"
            )));
        }
        self.followers.push(Follower::new(device));
        Ok(())
    }

    /// Removes a follower. The leader cannot be removed this way: pick
    /// another leader first, or stop the session.
    pub fn remove_follower(&mut self, device: Uuid) -> MikoResult<()> {
        if self.leader == device {
            return Err(MikoError::usage(
                "the leader cannot be removed: set another leader or stop the session",
            ));
        }
        let before = self.followers.len();
        self.followers.retain(|f| f.device != device);
        if self.followers.len() == before {
            return Err(MikoError::not_found("the device is not in the session"));
        }
        Ok(())
    }

    /// Drops a device because it stopped or was deleted.
    pub fn remove_member(&mut self, device: Uuid) -> Removed {
        if self.leader == device {
            return Removed::Leader;
        }
        let before = self.followers.len();
        self.followers.retain(|f| f.device != device);
        if self.followers.len() == before {
            Removed::NotMember
        } else {
            Removed::Follower
        }
    }

    /// Makes a member the leader; the old leader becomes a follower at the
    /// new leader's former place.
    pub fn set_leader(&mut self, device: Uuid) -> MikoResult<()> {
        if self.leader == device {
            return Ok(());
        }
        let Some(index) = self.followers.iter().position(|f| f.device == device) else {
            return Err(MikoError::not_found("the device is not in the session"));
        };
        let promoted = std::mem::replace(&mut self.followers[index], Follower::new(self.leader));
        self.followers[index].display = self.leader_display;
        self.leader = promoted.device;
        self.leader_display = promoted.display;
        Ok(())
    }

    pub fn set_options(&mut self, patch: &SyncOptionsPatch) -> MikoResult<()> {
        self.options = self.options.patched(patch)?;
        Ok(())
    }

    /// Records what the relay reports about a member. The leader accepts only
    /// a display size.
    pub fn report(
        &mut self,
        device: Uuid,
        status: Option<FollowerStatus>,
        display: Option<DisplaySize>,
        counters: Option<FollowerCounters>,
    ) -> MikoResult<()> {
        if let Some(display) = display
            && !display.is_valid()
        {
            return Err(MikoError::usage("display size is out of range"));
        }
        if self.leader == device {
            if status.is_some() || counters.is_some() {
                return Err(MikoError::usage("the leader has no follower status"));
            }
            if display.is_some() {
                self.leader_display = display;
            }
            return Ok(());
        }
        let Some(follower) = self.followers.iter_mut().find(|f| f.device == device) else {
            return Err(MikoError::not_found("the device is not in the session"));
        };
        if let Some(status) = status {
            follower.status = status;
        }
        if display.is_some() {
            follower.display = display;
        }
        if let Some(counters) = counters {
            follower.counters = counters;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;
    use miko_core::ErrorCode;

    fn ids(n: usize) -> Vec<Uuid> {
        (0..n).map(|_| Uuid::new_v4()).collect()
    }

    fn session(n: usize) -> (SyncSession, Vec<Uuid>) {
        let d = ids(n);
        let s = SyncSession::new(d[0], &d[1..], SyncOptions::default(), Utc::now()).unwrap();
        (s, d)
    }

    #[test]
    fn members_need_a_leader_and_a_follower() {
        let d = ids(3);
        assert_eq!(
            validate_members(d[0], &[]).unwrap_err().code,
            ErrorCode::Usage
        );
        assert!(validate_members(d[0], &d[1..]).is_ok());
    }

    #[test]
    fn members_reject_duplicates_and_leader_as_follower() {
        let d = ids(3);
        assert!(validate_members(d[0], &[d[1], d[1]]).is_err());
        assert!(validate_members(d[0], &[d[0], d[1]]).is_err());
    }

    #[test]
    fn members_are_capped() {
        let d = ids(MAX_MEMBERS + 1);
        assert!(validate_members(d[0], &d[1..MAX_MEMBERS]).is_ok());
        assert!(validate_members(d[0], &d[1..]).is_err());
    }

    #[test]
    fn jitter_is_bounded() {
        let d = ids(2);
        let options = SyncOptions {
            jitter_ms: MAX_JITTER_MS + 1,
            ..SyncOptions::default()
        };
        assert!(SyncSession::new(d[0], &d[1..], options, Utc::now()).is_err());
    }

    #[test]
    fn patch_changes_only_the_given_fields() {
        let base = SyncOptions::default();
        let patch = SyncOptionsPatch {
            sync_text: Some(false),
            jitter_ms: Some(5),
            ..SyncOptionsPatch::default()
        };
        let next = base.patched(&patch).unwrap();
        assert!(!next.sync_text);
        assert_eq!(next.jitter_ms, 5);
        assert!(next.sync_keyboard && next.lock_followers);
        let bad = SyncOptionsPatch {
            jitter_ms: Some(MAX_JITTER_MS + 1),
            ..SyncOptionsPatch::default()
        };
        assert!(base.patched(&bad).is_err());
    }

    #[test]
    fn patch_rejects_unknown_keys() {
        let err = serde_json::from_str::<SyncOptionsPatch>(r#"{"jiter_ms": 3}"#);
        assert!(err.is_err());
    }

    #[test]
    fn options_default_when_keys_are_missing() {
        let o: SyncOptions = serde_json::from_str(r#"{"sync_text": false}"#).unwrap();
        assert!(!o.sync_text && o.sync_keyboard && o.lock_followers);
    }

    #[test]
    fn add_and_remove_followers() {
        let (mut s, d) = session(2);
        let extra = Uuid::new_v4();
        s.add_follower(extra).unwrap();
        assert!(s.add_follower(extra).is_err());
        assert!(s.add_follower(d[0]).is_err());
        s.remove_follower(extra).unwrap();
        assert_eq!(
            s.remove_follower(extra).unwrap_err().code,
            ErrorCode::NotFound
        );
        assert_eq!(s.remove_follower(d[0]).unwrap_err().code, ErrorCode::Usage);
    }

    #[test]
    fn a_full_session_rejects_another_follower() {
        let (mut s, _) = session(MAX_MEMBERS);
        assert!(s.add_follower(Uuid::new_v4()).is_err());
    }

    #[test]
    fn removing_the_leader_or_last_follower_is_reported() {
        let (mut s, d) = session(2);
        assert_eq!(s.remove_member(Uuid::new_v4()), Removed::NotMember);
        assert_eq!(s.remove_member(d[1]), Removed::Follower);
        assert!(!s.is_viable());
        assert_eq!(s.remove_member(d[0]), Removed::Leader);
    }

    #[test]
    fn set_leader_swaps_roles_and_displays() {
        let (mut s, d) = session(3);
        let big = DisplaySize {
            width: 1080,
            height: 2400,
        };
        let small = DisplaySize {
            width: 720,
            height: 1280,
        };
        s.report(d[0], None, Some(big), None).unwrap();
        s.report(d[1], None, Some(small), None).unwrap();
        s.set_leader(d[1]).unwrap();
        assert_eq!(s.leader, d[1]);
        assert_eq!(s.leader_display, Some(small));
        assert_eq!(s.followers[0].device, d[0]);
        assert_eq!(s.followers[0].display, Some(big));
        assert_eq!(s.followers[1].device, d[2]);
        assert_eq!(s.members().len(), 3);
        assert!(s.set_leader(Uuid::new_v4()).is_err());
        s.set_leader(d[1]).unwrap();
    }

    #[test]
    fn promoting_resets_the_old_leaders_follower_state() {
        let (mut s, d) = session(2);
        s.report(
            d[1],
            Some(FollowerStatus::Lagging),
            None,
            Some(FollowerCounters {
                forwarded: 9,
                dropped: 1,
            }),
        )
        .unwrap();
        s.set_leader(d[1]).unwrap();
        assert_eq!(s.followers[0].status, FollowerStatus::Ready);
        assert_eq!(s.followers[0].counters, FollowerCounters::default());
    }

    #[test]
    fn report_updates_followers_and_guards_the_leader() {
        let (mut s, d) = session(2);
        s.report(
            d[1],
            Some(FollowerStatus::Error {
                message: "gone".into(),
            }),
            None,
            Some(FollowerCounters {
                forwarded: 5,
                dropped: 2,
            }),
        )
        .unwrap();
        assert_eq!(s.followers[0].counters.forwarded, 5);
        assert!(matches!(
            s.followers[0].status,
            FollowerStatus::Error { .. }
        ));
        assert!(
            s.report(d[0], Some(FollowerStatus::Ready), None, None)
                .is_err()
        );
        assert!(
            s.report(
                d[1],
                None,
                Some(DisplaySize {
                    width: 0,
                    height: 10
                }),
                None
            )
            .is_err()
        );
        assert_eq!(
            s.report(Uuid::new_v4(), None, None, None).unwrap_err().code,
            ErrorCode::NotFound
        );
    }

    #[test]
    fn follower_status_wire_shape() {
        let v = serde_json::to_value(FollowerStatus::Error {
            message: "x".into(),
        })
        .unwrap();
        assert_eq!(v, serde_json::json!({"state":"error","message":"x"}));
        let r: FollowerStatus = serde_json::from_str(r#"{"state":"lagging"}"#).unwrap();
        assert_eq!(r, FollowerStatus::Lagging);
    }
}
