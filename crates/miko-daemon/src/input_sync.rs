//! The input synchronizer's control plane (D45): one session at a time, with a
//! leader whose input other running devices mirror. The daemon owns *who*
//! takes part and *how*; the input events themselves travel between the
//! player bridges (see `docs/sync.md`), which report back with `sync.report`.
//!
//! A session ends on its own when the leader stops, crashes, hibernates or is
//! deleted, or when no follower is left. A follower that stops is dropped.

use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use chrono::Utc;
use miko_core::provider::{
    CallCtx, CommandProvider, CommandSpec, DaemonContext, NoParams, parse_params,
};
use miko_core::{Device, DeviceStatus, ErrorCode, MikoError, MikoResult};
use miko_sync::session::Removed;
use miko_sync::{
    DisplaySize, FollowerCounters, FollowerStatus, SyncOptions, SyncOptionsPatch, SyncSession,
};
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::broadcast::error::RecvError;
use uuid::Uuid;

use crate::state::{State, lock};

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SyncStartParams {
    /// The device whose input is mirrored (name or id). It must be running.
    pub leader: String,
    /// The devices that mirror it (names or ids). All must be running.
    pub followers: Vec<String>,
    /// Options; omitted fields take their defaults.
    #[serde(default)]
    pub options: Option<SyncOptionsPatch>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SyncDeviceParams {
    /// Device name or id.
    pub device: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SyncOptionsParams {
    /// The fields to change; omitted fields stay as they are.
    pub options: SyncOptionsPatch,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SyncReportParams {
    /// Device name or id of a session member.
    pub device: String,
    /// The follower's health (not accepted for the leader).
    #[serde(default)]
    pub status: Option<FollowerStatus>,
    /// The member's shown-screen size in pixels.
    #[serde(default)]
    pub display: Option<DisplaySize>,
    /// The follower's running totals (not accepted for the leader).
    #[serde(default)]
    pub counters: Option<FollowerCounters>,
}

struct Inner {
    state: Arc<State>,
    session: Mutex<Option<SyncSession>>,
}

pub struct InputSyncProvider {
    inner: Arc<Inner>,
}

fn to_json<T: serde::Serialize>(value: &T) -> MikoResult<Value> {
    serde_json::to_value(value).map_err(|e| MikoError::new(ErrorCode::Unexpected, e.to_string()))
}

fn not_active() -> MikoError {
    MikoError::not_found("no sync session is active")
}

fn require_running(device: &Device) -> MikoResult<()> {
    if matches!(device.status, DeviceStatus::Running) {
        Ok(())
    } else {
        Err(MikoError::usage(format!(
            "{} is not running; start it before syncing",
            device.name
        )))
    }
}

impl InputSyncProvider {
    pub fn new(state: Arc<State>) -> Self {
        Self {
            inner: Arc::new(Inner {
                state,
                session: Mutex::new(None),
            }),
        }
    }
}

impl Inner {
    fn publish(&self, session: Option<&SyncSession>, reason: Option<&str>) {
        let mut data = json!({ "session": session });
        if let Some(reason) = reason {
            data["reason"] = json!(reason);
        }
        self.state.emit("sync.state", data);
    }

    fn snapshot(&self) -> MikoResult<SyncSession> {
        lock(&self.session).clone().ok_or_else(not_active)
    }

    async fn device_display(&self, device: &Device) -> Option<DisplaySize> {
        let avds = self.state.avds();
        let avd = device.avd.clone();
        tokio::task::spawn_blocking(move || {
            let config = avds.config(&avd).ok()?;
            let width: u32 = config.get("hw.lcd.width")?.parse().ok()?;
            let height: u32 = config.get("hw.lcd.height")?.parse().ok()?;
            let size = DisplaySize { width, height };
            size.is_valid().then_some(size)
        })
        .await
        .ok()
        .flatten()
    }

    /// Runs `f` on the active session; publishes and returns the result.
    fn update(&self, f: impl FnOnce(&mut SyncSession) -> MikoResult<()>) -> MikoResult<Value> {
        let session = {
            let mut guard = lock(&self.session);
            let session = guard.as_mut().ok_or_else(not_active)?;
            f(session)?;
            session.clone()
        };
        self.publish(Some(&session), None);
        to_json(&session)
    }

    /// Ends session `id` if it is still the active one.
    fn end(&self, id: Uuid, reason: &str) {
        let ended = {
            let mut guard = lock(&self.session);
            match guard.as_ref() {
                Some(s) if s.id == id => guard.take(),
                _ => None,
            }
        };
        if ended.is_some() {
            self.publish(None, Some(reason));
        }
    }

    /// Drops members that are no longer running. Returns whether session
    /// `id` is still active afterwards.
    async fn reconcile(&self, id: Uuid) -> bool {
        let running: Vec<Uuid> = self
            .state
            .devices()
            .await
            .into_iter()
            .filter(|d| matches!(d.status, DeviceStatus::Running))
            .map(|d| d.id)
            .collect();
        let (changed, ended, session) = {
            let mut guard = lock(&self.session);
            let Some(session) = guard.as_mut().filter(|s| s.id == id) else {
                return false;
            };
            let mut changed = false;
            let mut leader_gone = false;
            for member in session.members() {
                if running.contains(&member) {
                    continue;
                }
                match session.remove_member(member) {
                    Removed::Leader => leader_gone = true,
                    Removed::Follower => changed = true,
                    Removed::NotMember => {}
                }
            }
            let reason = if leader_gone {
                Some("the leader stopped")
            } else if !session.is_viable() {
                Some("no follower is left")
            } else {
                None
            };
            let snapshot = session.clone();
            if reason.is_some() {
                guard.take();
            }
            (changed, reason, snapshot)
        };
        match ended {
            Some(reason) => {
                self.publish(None, Some(reason));
                false
            }
            None => {
                if changed {
                    self.publish(Some(&session), None);
                }
                true
            }
        }
    }
}

/// Watches device lifecycle events for as long as session `id` is active.
fn spawn_watcher(inner: Arc<Inner>, id: Uuid) {
    let mut events = inner.state.subscribe();
    tokio::spawn(async move {
        // Anything that happened between validation and subscribing.
        if !inner.reconcile(id).await {
            return;
        }
        loop {
            match events.recv().await {
                Ok(event) => {
                    let relevant = matches!(
                        event.topic.as_str(),
                        "device.status" | "device.crashed" | "device.deleted" | "device.hibernated"
                    );
                    if !relevant {
                        continue;
                    }
                }
                Err(RecvError::Lagged(_)) => {}
                Err(RecvError::Closed) => return,
            }
            if !inner.reconcile(id).await {
                return;
            }
        }
    });
}

#[async_trait]
impl CommandProvider for InputSyncProvider {
    fn name(&self) -> &str {
        "input-sync"
    }

    fn commands(&self) -> Vec<CommandSpec> {
        vec![
            CommandSpec::new::<SyncStartParams>(
                "sync.start",
                "Start mirroring the input of a leader device on follower devices (one session at a time)",
            ),
            CommandSpec::new::<NoParams>("sync.stop", "End the input sync session"),
            CommandSpec::new::<NoParams>("sync.status", "The active input sync session, or null"),
            CommandSpec::new::<SyncDeviceParams>(
                "sync.add_follower",
                "Add a running device to the active sync session as a follower",
            ),
            CommandSpec::new::<SyncDeviceParams>(
                "sync.remove_follower",
                "Remove a follower from the active sync session",
            ),
            CommandSpec::new::<SyncDeviceParams>(
                "sync.set_leader",
                "Make a session member the leader; the old leader becomes a follower",
            ),
            CommandSpec::new::<SyncOptionsParams>(
                "sync.set_options",
                "Change the active session's options (only the given fields)",
            ),
            CommandSpec::new::<SyncReportParams>(
                "sync.report",
                "Relay-side report of a member's health, screen size and counters",
            ),
        ]
    }

    async fn call(&self, _ctx: &CallCtx, method: &str, params: Value) -> MikoResult<Value> {
        let inner = &self.inner;
        match method {
            "sync.start" => {
                let p: SyncStartParams = parse_params(params)?;
                let options = match &p.options {
                    Some(patch) => SyncOptions::default().patched(patch)?,
                    None => SyncOptions::default(),
                };
                let leader = inner.state.device(&p.leader).await?;
                require_running(&leader)?;
                let mut follower_devices = Vec::with_capacity(p.followers.len());
                let mut followers = Vec::with_capacity(p.followers.len());
                for selector in &p.followers {
                    let device = inner.state.device(selector).await?;
                    require_running(&device)?;
                    followers.push(device.id);
                    follower_devices.push(device);
                }
                let mut session = SyncSession::new(leader.id, &followers, options, Utc::now())?;
                session.leader_display = inner.device_display(&leader).await;
                for (device, follower) in follower_devices.iter().zip(session.followers.iter_mut())
                {
                    follower.display = inner.device_display(device).await;
                }
                {
                    let mut guard = lock(&inner.session);
                    if guard.is_some() {
                        return Err(MikoError::busy("a sync session is already active"));
                    }
                    *guard = Some(session.clone());
                }
                inner.publish(Some(&session), None);
                spawn_watcher(inner.clone(), session.id);
                to_json(&session)
            }
            "sync.stop" => {
                parse_params::<NoParams>(params)?;
                let id = lock(&inner.session).as_ref().map(|s| s.id);
                if let Some(id) = id {
                    inner.end(id, "stopped");
                }
                Ok(json!({ "stopped": id.is_some() }))
            }
            "sync.status" => {
                parse_params::<NoParams>(params)?;
                to_json(&*lock(&inner.session))
            }
            "sync.add_follower" => {
                let p: SyncDeviceParams = parse_params(params)?;
                inner.snapshot()?;
                let device = inner.state.device(&p.device).await?;
                require_running(&device)?;
                let display = inner.device_display(&device).await;
                inner.update(|s| {
                    s.add_follower(device.id)?;
                    if let Some(display) = display {
                        let _ = s.report(device.id, None, Some(display), None);
                    }
                    Ok(())
                })
            }
            "sync.remove_follower" => {
                let p: SyncDeviceParams = parse_params(params)?;
                inner.snapshot()?;
                let device = inner.state.device(&p.device).await?;
                enum Outcome {
                    Updated(SyncSession),
                    Ended,
                }
                let outcome = {
                    let mut guard = lock(&inner.session);
                    let session = guard.as_mut().ok_or_else(not_active)?;
                    session.remove_follower(device.id)?;
                    if session.is_viable() {
                        Outcome::Updated(session.clone())
                    } else {
                        guard.take();
                        Outcome::Ended
                    }
                };
                match outcome {
                    Outcome::Updated(session) => {
                        inner.publish(Some(&session), None);
                        to_json(&session)
                    }
                    Outcome::Ended => {
                        inner.publish(None, Some("no follower is left"));
                        Ok(Value::Null)
                    }
                }
            }
            "sync.set_leader" => {
                let p: SyncDeviceParams = parse_params(params)?;
                inner.snapshot()?;
                let device = inner.state.device(&p.device).await?;
                inner.update(|s| s.set_leader(device.id))
            }
            "sync.set_options" => {
                let p: SyncOptionsParams = parse_params(params)?;
                inner.update(|s| s.set_options(&p.options))
            }
            "sync.report" => {
                let p: SyncReportParams = parse_params(params)?;
                inner.snapshot()?;
                let device = inner.state.device(&p.device).await?;
                let failed = match &p.status {
                    Some(FollowerStatus::Error { message }) => Some(message.clone()),
                    _ => None,
                };
                let result =
                    inner.update(|s| s.report(device.id, p.status, p.display, p.counters))?;
                if let Some(message) = failed {
                    inner.state.emit(
                        "sync.follower_error",
                        json!({ "device": device.id, "name": device.name, "message": message }),
                    );
                }
                Ok(result)
            }
            other => Err(MikoError::usage(format!("unknown sync command {other}"))),
        }
    }
}
