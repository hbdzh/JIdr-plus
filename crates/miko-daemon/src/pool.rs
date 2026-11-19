//! Bases and the pool (D42, Phase 13d): an agent gets a throwaway
//! copy-on-write clone of a snapshotted base with `pool.get`, uses it, and
//! gives it back with `pool.release`. Leases end with the client connection
//! (plus grace) or a TTL; a reaper stops and deletes expired clones. How many
//! clones run at once comes from the host RAM budget (13a): a full pool makes
//! `pool.get` wait, then fail with `resource_exhausted`. Persistent agent
//! devices stay on `device.create`.

use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use chrono::Utc;
use miko_adb::Adb;
use miko_core::provider::{CallCtx, CommandProvider, CommandSpec, DaemonContext, parse_params};
use miko_core::{Device, ErrorCode, LaunchPrefs, MikoError, MikoResult, RootMode};
use schemars::JsonSchema;
use serde::Deserialize;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::core_provider::move_device_files;
use crate::leases::{Holder, Lease};
use crate::state::{State, lock};

/// The snapshot a base keeps and its clones resume.
pub const BASE_SNAPSHOT: &str = "miko-base";
/// A TTL lease's default lifetime (the CLI's).
pub const DEFAULT_TTL: Duration = Duration::from_secs(2 * 60 * 60);
/// How long `pool.get` waits for room in the budget by default.
pub const DEFAULT_WAIT: Duration = Duration::from_secs(120);
const ANIMATION_SCALES: [&str; 3] = [
    "window_animation_scale",
    "transition_animation_scale",
    "animator_duration_scale",
];

/// Configure only the throwaway clone. The source and its snapshot retain
/// their settings even if creation is interrupted or the daemon stops.
async fn prepare_clone_animations(adb: &Adb, cancel: &miko_core::Cancel) -> MikoResult<()> {
    for key in ANIMATION_SCALES {
        cancel.check()?;
        adb.shell(&format!("settings put global {key} 0"))
            .await
            .map_err(|mut error| {
                error.message = format!("cannot disable clone animations: {}", error.message);
                error
            })?;
    }
    cancel.check()
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BaseCreateParams {
    /// A running source; Magisk requires a patched ramdisk and shell su grant.
    /// It is stopped; the base is a copy of it.
    pub from_device: String,
    /// The base's name.
    pub name: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct BaseParams {
    /// Base name or id.
    pub base: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PoolGetParams {
    /// Base name or id.
    pub base: String,
    /// Lease lifetime in seconds from delivery. Without it the lease lasts as
    /// long as this client connection, plus 2 minutes.
    #[serde(default)]
    pub ttl_s: Option<u64>,
    /// How long to wait for room in the RAM budget (default 120 s).
    #[serde(default)]
    pub timeout_s: Option<u64>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PoolReleaseParams {
    /// The lease id from `pool.get`.
    #[serde(default)]
    pub lease: Option<Uuid>,
    /// Or the pool device's name or id.
    #[serde(default)]
    pub device: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PoolRenewParams {
    pub lease: Uuid,
    /// New lifetime from now, in seconds (default 2 h).
    #[serde(default)]
    pub ttl_s: Option<u64>,
}

pub struct PoolProvider {
    state: Arc<State>,
}

/// Reject external, mismatched, or symlinked ramdisks: every copy must own
/// the exact file whose bytes are used with its snapshot.
fn magisk_ramdisk(device: &Device, dir: &Path) -> MikoResult<PathBuf> {
    let invalid = || {
        MikoError::usage(format!(
            "{} has no valid per-device patched ramdisk; run `root set {} magisk` again first",
            device.name, device.name
        ))
    };
    let path = device.launch.ramdisk.as_ref().ok_or_else(invalid)?;
    if device.root.patched_ramdisk_path.as_ref() != Some(path) {
        return Err(invalid());
    }
    let rel = path.strip_prefix(dir.join("miko")).map_err(|_| invalid())?;
    if rel.as_os_str().is_empty() || rel.components().any(|c| !matches!(c, Component::Normal(_))) {
        return Err(invalid());
    }
    let mut current = dir.join("miko");
    for component in rel.components() {
        current.push(component);
        let meta = std::fs::symlink_metadata(&current).map_err(|_| invalid())?;
        if meta.file_type().is_symlink() {
            return Err(invalid());
        }
    }
    if std::fs::symlink_metadata(dir.join("miko"))
        .map_err(|_| invalid())?
        .file_type()
        .is_symlink()
        || !path.is_file()
    {
        return Err(invalid());
    }
    Ok(path.clone())
}

async fn check_magisk_source(src: &Device, adb: &Adb, dir: &Path) -> MikoResult<()> {
    magisk_ramdisk(src, dir)?;
    let root = adb
        .clone()
        .with_timeout(Duration::from_secs(20))
        .shell_status("su -c id")
        .await
        .is_ok_and(|(status, output)| {
            status == 0 && output.split_whitespace().any(|s| s.starts_with("uid=0("))
        });
    if root {
        return Ok(());
    }
    let hint = if src.image.allows_adb_root() {
        "check it with `root verify`"
    } else {
        "on a Play Store image, tap Grant in Magisk's prompt and choose Forever"
    };
    Err(MikoError::root_failed(format!(
        "{}'s shell `su -c id` isn't root, so its clones wouldn't be either; {hint}",
        src.name
    )))
}

impl PoolProvider {
    pub fn new(state: Arc<State>) -> Self {
        Self { state }
    }
}

fn json<T: serde::Serialize>(v: T) -> MikoResult<Value> {
    serde_json::to_value(v).map_err(|e| MikoError::unexpected(format!("encoding result: {e}")))
}

fn short_id() -> String {
    Uuid::new_v4().simple().to_string()[..6].to_string()
}

impl State {
    pub fn lease_count(&self) -> usize {
        lock(&self.leases).len()
    }

    pub(crate) fn connection_opened(&self, conn: u64) {
        lock(&self.leases).connected(conn);
    }

    /// A client connection closed: its leases expire after the grace period.
    pub fn connection_closed(&self, conn: u64) {
        // Keep the disconnection in memory even if storage is temporarily
        // unavailable; recovery treats an open connection as disconnected.
        let mut leases = lock(&self.leases);
        if leases.disconnected(conn, Utc::now())
            && let Err(error) = leases.save(&self.paths.data.join("pool-leases.json"))
        {
            tracing::error!(%error, "cannot persist disconnected pool leases");
        }
    }

    fn base(&self, selector: &str) -> MikoResult<Device> {
        let d = self.with_store(|s| s.find(selector).cloned())?;
        if !d.base {
            return Err(MikoError::usage(format!(
                "{} is not a base; make one with base.create",
                d.name
            )));
        }
        Ok(d)
    }

    /// Stops (without saving) and deletes a device: a pool clone or a base.
    async fn remove_device(&self, id: Uuid) -> MikoResult<Device> {
        let d = self.with_store(|s| s.get(id).cloned())?;
        if d.status.is_active() {
            self.stop_device(id).await?;
        }
        let avds = self.avds();
        if avds.exists(&d.avd) {
            avds.delete(&d.avd)?;
        }
        let d = self.with_store(|s| s.remove(id))?;
        self.emit("device.deleted", json!({ "device": d.id, "name": d.name }));
        Ok(d)
    }

    async fn clean_failed_clone(&self, device: Uuid, lease: Uuid) {
        let removed = match self.remove_device(device).await {
            Ok(_) => true,
            Err(error) => {
                tracing::warn!(%error, %device, "failed to remove pool clone; scheduling retry");
                false
            }
        };
        if let Err(error) = self.update_leases(|leases| {
            if removed {
                leases.remove(lease);
            } else {
                leases.abandon(lease, Utc::now());
            }
            Ok(())
        }) {
            // Avoid leaving an unreapable pending lease in this process. The
            // persisted pending record also recovers into grace on restart.
            let mut leases = lock(&self.leases);
            if removed {
                leases.remove(lease);
            } else {
                leases.abandon(lease, Utc::now());
            }
            tracing::error!(%error, %device, "cannot persist failed clone cleanup");
        }
    }

    /// Ends a lease: its clone is stopped and deleted.
    pub async fn release(&self, lease: Uuid) -> MikoResult<Value> {
        self.release_checked(lease, None)
            .await?
            .ok_or_else(|| MikoError::not_found(format!("no lease {lease}")))
    }

    async fn release_checked(
        &self,
        lease: Uuid,
        expired_at: Option<chrono::DateTime<Utc>>,
    ) -> MikoResult<Option<Value>> {
        let l = lock(&self.leases)
            .get(lease)
            .cloned()
            .ok_or_else(|| MikoError::not_found(format!("no lease {lease}")))?;
        let name = self
            .with_store(|s| s.get(l.device).map(|d| d.name.clone()))
            .unwrap_or_default();
        let _guard = self.locks.try_lock(l.device, &name, "pool.release", None)?;
        // Renewal takes the same device lock. Check again after taking it so
        // a lease renewed since the reaper's scan cannot be deleted.
        {
            let leases = lock(&self.leases);
            let Some(current) = leases.get(lease) else {
                return Ok(None);
            };
            if expired_at.is_some_and(|now| {
                leases.is_pending(lease) || !current.expires_at.is_some_and(|t| t <= now)
            }) {
                return Ok(None);
            }
        }
        if self.with_store(|s| s.get(l.device).is_ok()) {
            self.remove_device(l.device).await?;
        }
        self.update_leases(|leases| {
            leases.remove(lease);
            Ok(())
        })?;
        self.emit(
            "pool.released",
            json!({ "lease": lease, "device": l.device }),
        );
        Ok(Some(
            json!({ "released": lease, "device": l.device, "name": name }),
        ))
    }

    /// One reaper pass as of `now`: releases every expired lease. Returns
    /// the leases it released (busy ones wait for the next pass).
    pub async fn reap(&self, now: chrono::DateTime<Utc>) -> Vec<Uuid> {
        let due = lock(&self.leases).expired(now);
        let mut done = Vec::new();
        for l in due {
            match self.release_checked(l.id, Some(now)).await {
                Ok(Some(_)) => done.push(l.id),
                Ok(None) => {}
                Err(e) => tracing::warn!(lease = %l.id, "reaping failed: {e}"),
            }
        }
        done
    }
}

impl PoolProvider {
    async fn base_create(&self, ctx: &CallCtx, p: BaseCreateParams) -> MikoResult<Value> {
        let st = &self.state;
        let src = st.device(&p.from_device).await?;
        let _guard = st.locks.try_lock(src.id, &src.name, "base.create", None)?;
        let src = st.device(&src.id.to_string()).await?;
        if src.base || src.pool_base.is_some() {
            return Err(MikoError::usage(format!(
                "{} is already a base or a pool device",
                src.name
            )));
        }
        if src.root.writable_system {
            // #25: the writable system copy isn't part of the base snapshot.
            return Err(MikoError::usage(format!(
                "{} has a writable /system; turn it off first (root.writable_system false)",
                src.name
            )));
        }
        let info = st.connect_info(src.id).await.map_err(|_| {
            MikoError::not_found(format!(
                "start {} first: a base is saved from a running device",
                src.name
            ))
        })?;
        let name = p.name.trim().to_string();
        crate::core_provider::validate_device_name(&name)?;
        if st.with_store(|s| s.name_taken(&name, None)) {
            return Err(MikoError::usage(format!(
                "a device named {name:?} already exists"
            )));
        }
        let adb = Adb::new(info.adb_path.clone()).device(info.adb_serial.clone());
        if src.root.mode == RootMode::Magisk {
            ctx.report(Some(0.05), "Checking Magisk root");
            check_magisk_source(&src, &adb, &st.avds().dir(&src.avd)).await?;
        }
        ctx.cancel.check()?;
        ctx.report(Some(0.3), "Saving the base snapshot");
        let inst = st
            .instance(src.id)
            .ok_or_else(|| MikoError::not_found(format!("{} is not running", src.name)))?;
        let src_dir = st.avds().dir(&src.avd);
        st.backend
            .save_snapshot(&inst, BASE_SNAPSHOT, &src_dir)
            .await?;
        miko_sdk::avd::check_snapshot(&src_dir, BASE_SNAPSHOT)?;
        ctx.cancel.check()?;
        ctx.report(Some(0.6), "Stopping the source");
        st.stop_device(src.id).await?;

        ctx.report(Some(0.8), "Copying");
        let avds = st.avds();
        let avd = st.with_store(|s| s.avd_id_for(&name, |id| avds.exists(id)));
        avds.clone_with_snapshot(&src.avd, &avd, &name, BASE_SNAPSHOT)?;
        // The stopped source remains an ordinary device; its copy of the
        // snapshot isn't needed.
        let _ = std::fs::remove_dir_all(src_dir.join("snapshots").join(BASE_SNAPSHOT));
        let mut launch = LaunchPrefs {
            force_cold_boot: false,
            resume_snapshot: None,
            ..src.launch.clone()
        };
        let mut root = src.root.clone();
        if root.mode == RootMode::Magisk {
            move_device_files(&mut launch, &mut root, &src_dir, &avds.dir(&avd));
        } else {
            launch.ramdisk = None;
        }
        let base = Device {
            id: Uuid::new_v4(),
            name,
            avd: avd.clone(),
            created_at: Utc::now(),
            launch,
            root,
            status: Default::default(),
            runtime: None,
            agent_owned: false,
            base: true,
            pool_base: None,
            auto_hibernate_minutes: None,
            ..src.clone()
        };
        if base.root.mode == RootMode::Magisk && magisk_ramdisk(&base, &avds.dir(&avd)).is_err() {
            let _ = avds.delete(&avd);
            return Err(MikoError::sdk("copying the base's patched ramdisk failed"));
        }
        if let Err(e) = st.with_store(|s| s.insert(base.clone())) {
            let _ = avds.delete(&avd);
            return Err(e);
        }
        st.emit(
            "device.created",
            json!({ "device": base.id, "name": base.name }),
        );
        json(base)
    }

    async fn base_list(&self) -> MikoResult<Value> {
        let leases = lock(&self.state.leases).all();
        let bases: Vec<Value> = self
            .state
            .devices()
            .await
            .into_iter()
            .filter(|d| d.base)
            .map(|d| {
                let n = leases.iter().filter(|l| l.base == d.id).count();
                json!({ "id": d.id, "name": d.name, "image": d.image, "profile": d.profile, "root": d.root.mode, "leases": n, "created_at": d.created_at })
            })
            .collect();
        Ok(Value::Array(bases))
    }

    async fn base_delete(&self, p: BaseParams) -> MikoResult<Value> {
        let b = self.state.base(&p.base)?;
        let _guard = self
            .state
            .locks
            .try_lock(b.id, &b.name, "base.delete", None)?;
        let n = lock(&self.state.leases).of_base(b.id);
        if n > 0 {
            return Err(MikoError::busy(format!(
                "{} has {n} leased clone(s); release them first",
                b.name
            ))
            .with_data(json!({ "leases": n })));
        }
        let d = self.state.remove_device(b.id).await?;
        Ok(json!({ "deleted": d.id, "name": d.name }))
    }

    async fn pool_get(&self, ctx: &CallCtx, p: PoolGetParams) -> MikoResult<Value> {
        let st = &self.state;
        let base = st.base(&p.base)?;
        // Copying a base and deleting it must not race, but concurrent pool
        // requests are expected to wait briefly rather than fail as busy.
        let base_guard = loop {
            ctx.cancel.check()?;
            match st.locks.try_lock(base.id, &base.name, "pool.get", None) {
                Ok(guard) => break guard,
                Err(error) if error.code == ErrorCode::Busy => {
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
                Err(error) => return Err(error),
            }
        };
        let base = st.base(&base.id.to_string())?;
        let now = Utc::now();
        let holder = match (p.ttl_s, ctx.connection) {
            (None, Some(id)) => Holder::Connection { id },
            _ => Holder::Ttl,
        };
        let ttl = p.ttl_s.map(Duration::from_secs).unwrap_or(DEFAULT_TTL);
        crate::leases::expiry(now, ttl)?;
        if tokio::time::Instant::now()
            .checked_add(p.timeout_s.map(Duration::from_secs).unwrap_or(DEFAULT_WAIT))
            .is_none()
        {
            return Err(MikoError::usage("timeout_s is too large"));
        }

        ctx.report(Some(0.05), "Cloning the base");
        let name = format!("{}-{}", base.name, short_id());
        let avds = st.avds();
        let avd = st.with_store(|s| s.avd_id_for(&name, |id| avds.exists(id)));
        avds.clone_with_snapshot(&base.avd, &avd, &name, BASE_SNAPSHOT)?;
        let mut launch = LaunchPrefs {
            resume_snapshot: Some(BASE_SNAPSHOT.into()),
            force_cold_boot: false,
            ..base.launch.clone()
        };
        let mut root = base.root.clone();
        move_device_files(
            &mut launch,
            &mut root,
            &avds.dir(&base.avd),
            &avds.dir(&avd),
        );
        let device = Device {
            id: Uuid::new_v4(),
            name,
            avd: avd.clone(),
            created_at: now,
            launch,
            root,
            status: Default::default(),
            runtime: None,
            agent_owned: true,
            base: false,
            pool_base: Some(base.id),
            // Throwaway: never hibernated, never resumed from its own state.
            auto_hibernate_minutes: Some(0),
            ..base.clone()
        };
        let device_guard = st
            .locks
            .try_lock(device.id, &device.name, "pool.get", None)?;
        if device.root.mode == RootMode::Magisk && magisk_ramdisk(&device, &avds.dir(&avd)).is_err()
        {
            let _ = avds.delete(&avd);
            return Err(MikoError::not_found(format!(
                "{} lost its patched ramdisk; make the base again",
                base.name
            )));
        }
        if let Err(e) = st.with_store(|s| s.insert(device.clone())) {
            let _ = avds.delete(&avd);
            return Err(e);
        }
        let lease = Lease {
            id: Uuid::new_v4(),
            base: base.id,
            device: device.id,
            holder,
            expires_at: None,
            created_at: now,
        };
        // Registered before the boot, so a client that disconnects mid-boot
        // still gets its clone reaped.
        if let Err(error) = st.update_leases(|leases| {
            leases.insert_pending(lease.clone(), Utc::now());
            Ok(())
        }) {
            if let Err(cleanup_error) = st.remove_device(device.id).await {
                // Keep a retryable in-memory lease even if neither persistence
                // nor the immediate clone cleanup is possible.
                let mut leases = lock(&st.leases);
                leases.insert_pending(lease.clone(), Utc::now());
                leases.abandon(lease.id, Utc::now());
                tracing::warn!(%cleanup_error, "cannot remove unleased pool clone");
            }
            return Err(error);
        }
        drop(base_guard);

        let result = self.boot_clone(ctx, &device, &p).await;
        match result {
            Ok(d) => {
                let info = match st.connect_info(d.id).await {
                    Ok(info) => info,
                    Err(error) => {
                        st.clean_failed_clone(device.id, lease.id).await;
                        return Err(error);
                    }
                };
                ctx.report(Some(0.9), "Preparing clone animations");
                let adb = Adb::new(info.adb_path.clone()).device(info.adb_serial.clone());
                if let Err(error) = prepare_clone_animations(&adb, &ctx.cancel).await {
                    st.clean_failed_clone(device.id, lease.id).await;
                    return Err(error);
                }
                let lease =
                    match st.update_leases(|leases| leases.activate(lease.id, ttl, Utc::now())) {
                        Ok(lease) => lease,
                        Err(error) => {
                            st.clean_failed_clone(device.id, lease.id).await;
                            return Err(error);
                        }
                    };
                drop(device_guard);
                st.emit(
                    "pool.leased",
                    json!({ "lease": lease.id, "device": d.id, "base": base.id }),
                );
                Ok(json!({
                    "lease": lease,
                    "device": d,
                    "serial": info.adb_serial,
                    "connect": info,
                }))
            }
            Err(e) => {
                st.clean_failed_clone(device.id, lease.id).await;
                Err(e)
            }
        }
    }

    /// Waits for room in the budget, then resumes the clone.
    async fn boot_clone(&self, ctx: &CallCtx, d: &Device, p: &PoolGetParams) -> MikoResult<Device> {
        let st = &self.state;
        let wait = p.timeout_s.map(Duration::from_secs).unwrap_or(DEFAULT_WAIT);
        let deadline = tokio::time::Instant::now() + wait;
        let mut waiting = false;
        loop {
            ctx.cancel.check()?;
            match st.admit(d.id, false) {
                Ok(()) => break,
                Err(e) if e.code == ErrorCode::ResourceExhausted => {
                    if tokio::time::Instant::now() >= deadline {
                        let mut e = e;
                        e.message = format!(
                            "the pool is full: no room in the RAM budget after {} s; {}",
                            wait.as_secs(),
                            e.message
                        );
                        return Err(e);
                    }
                    if !waiting {
                        ctx.report(Some(0.1), "Waiting for room in the RAM budget");
                        waiting = true;
                    }
                    tokio::time::sleep(Duration::from_millis(500)).await;
                }
                Err(e) => return Err(e),
            }
        }
        ctx.report(Some(0.2), "Resuming the base snapshot");
        st.start_device(d.id, false, &ctx.cancel).await
    }
}

#[async_trait]
impl CommandProvider for PoolProvider {
    fn name(&self) -> &str {
        "pool"
    }

    fn commands(&self) -> Vec<CommandSpec> {
        vec![
            CommandSpec::new::<BaseCreateParams>(
                "base.create",
                "Save a running device as a read-only base for pool clones (snapshot miko-base; clone animations off)",
            )
            .long_running(),
            CommandSpec::new::<miko_core::provider::NoParams>("base.list", "Bases and how many clones each has leased"),
            CommandSpec::new::<BaseParams>("base.delete", "Delete a base (none of its clones may be leased)")
                .destructive(),
            CommandSpec::new::<PoolGetParams>(
                "pool.get",
                "Lease a throwaway clone of a base, booted from its snapshot; returns its serial. Release it when done",
            )
            .long_running(),
            CommandSpec::new::<PoolReleaseParams>("pool.release", "Give a leased clone back: it is stopped and deleted"),
            CommandSpec::new::<PoolRenewParams>("pool.renew", "Extend a lease (TTL leases, or one in its grace period)"),
            CommandSpec::new::<miko_core::provider::NoParams>("pool.list", "Current leases"),
        ]
    }

    async fn call(&self, ctx: &CallCtx, method: &str, params: Value) -> MikoResult<Value> {
        match method {
            "base.create" => self.base_create(ctx, parse_params(params)?).await,
            "base.list" => {
                parse_params::<miko_core::provider::NoParams>(params)?;
                self.base_list().await
            }
            "base.delete" => self.base_delete(parse_params(params)?).await,
            "pool.get" => self.pool_get(ctx, parse_params(params)?).await,
            "pool.release" => {
                let p: PoolReleaseParams = parse_params(params)?;
                let lease = match (p.lease, p.device) {
                    (Some(l), None) => l,
                    (None, Some(sel)) => {
                        let d = self.state.device(&sel).await?;
                        lock(&self.state.leases)
                            .for_device(d.id)
                            .map(|l| l.id)
                            .ok_or_else(|| {
                                MikoError::not_found(format!(
                                    "{} is not a leased pool device",
                                    d.name
                                ))
                            })?
                    }
                    _ => return Err(MikoError::usage("give either lease or device")),
                };
                self.state.release(lease).await
            }
            "pool.renew" => {
                let p: PoolRenewParams = parse_params(params)?;
                let ttl = p.ttl_s.map(Duration::from_secs).unwrap_or(DEFAULT_TTL);
                crate::leases::expiry(Utc::now(), ttl)?;
                let lease = lock(&self.state.leases)
                    .get(p.lease)
                    .cloned()
                    .ok_or_else(|| MikoError::not_found(format!("no lease {}", p.lease)))?;
                let name = self
                    .state
                    .with_store(|s| s.get(lease.device).map(|d| d.name.clone()))
                    .unwrap_or_default();
                let _guard = self
                    .state
                    .locks
                    .try_lock(lease.device, &name, "pool.renew", None)?;
                let l = self
                    .state
                    .update_leases(|leases| leases.renew(p.lease, ttl, Utc::now()))?;
                json(l)
            }
            "pool.list" => {
                parse_params::<miko_core::provider::NoParams>(params)?;
                let leases = lock(&self.state.leases).all();
                let devices = self.state.devices().await;
                let rows: Vec<Value> = leases
                    .into_iter()
                    .map(|l| {
                        let d = devices.iter().find(|d| d.id == l.device);
                        let base = devices.iter().find(|d| d.id == l.base);
                        json!({
                            "lease": l,
                            "device": d.map(|d| d.name.clone()),
                            "base": base.map(|d| d.name.clone()),
                            "status": d.map(|d| d.status.clone()),
                            "serial": d.and_then(|d| d.runtime.as_ref().map(|r| r.adb_serial.clone())),
                        })
                    })
                    .collect();
                Ok(Value::Array(rows))
            }
            other => Err(MikoError::usage(format!(
                "pool provider has no command {other}"
            ))),
        }
    }
}
