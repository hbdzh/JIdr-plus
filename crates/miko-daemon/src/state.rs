//! Daemon state: devices, running instances, crash watchers. Implements the
//! `DaemonContext` providers use.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, Weak};

use async_trait::async_trait;
use miko_backend::{Backend, BootStage, InstanceInfo, LaunchOptions, LaunchSpec};
use miko_core::provider::{CallCtx, CommandProvider, DaemonContext, DeviceUpdate};
use miko_core::{
    Cancel, ConnectInfo, Device, DeviceStatus, MikoError, MikoPaths, MikoResult, RootMode, Settings,
};
use miko_sdk::host::HostMemory;
use miko_sdk::{AvdManager, Sdk, SdkSet};
use serde_json::{Value, json};
use tokio::sync::broadcast;
use tokio::task::JoinHandle;
use uuid::Uuid;

use crate::budget::{Budget, DeviceUse};
use crate::locks::DeviceLocks;
use crate::store::DeviceStore;
use miko_adb::Adb;
use miko_core::rpc::Event;

/// How long the guest `sync` before a stop may take; the stop goes ahead
/// after it either way.
const STOP_SYNC_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

#[derive(Debug, Clone)]
pub struct DaemonConfig {
    pub paths: MikoPaths,
    /// Android Studio's SDK (read-only). `None` = auto-detect.
    pub studio_sdk: Option<PathBuf>,
    /// Exit after this long idle (D4: 10 min). `None` = never.
    pub idle_timeout: Option<std::time::Duration>,
    /// SDK repository base URL (mirrors, tests). `None` = `$MIKO_SDK_REPO`
    /// or Google's.
    pub sdk_repo: Option<String>,
}

impl DaemonConfig {
    /// Product defaults: auto-detected Studio SDK, 10-minute idle exit (D4).
    pub fn new(paths: MikoPaths) -> Self {
        Self {
            paths,
            studio_sdk: None,
            idle_timeout: Some(crate::lifecycle::IDLE_TIMEOUT),
            sdk_repo: None,
        }
    }
}

pub struct State {
    pub(crate) paths: MikoPaths,
    /// Held while this state or any request using it is alive. Older daemon
    /// versions do not honor this cooperative lease.
    pub(crate) storage_lease: OnceLock<miko_core::storage_lease::StorageLease>,
    studio_sdk: Option<PathBuf>,
    pub(crate) sdk_repo: Option<String>,
    pub(crate) backend: Arc<dyn Backend>,
    store: Mutex<DeviceStore>,
    settings: Mutex<Settings>,
    pub(crate) instances: Mutex<HashMap<Uuid, InstanceInfo>>,
    pub(crate) watchers: Mutex<HashMap<Uuid, JoinHandle<()>>>,
    pub(crate) locks: DeviceLocks,
    /// Serialises image removal against device creation and SDK installation.
    pub(crate) image_gate: tokio::sync::RwLock<()>,
    // The registry owns providers. Weak references prevent a cycle through
    // providers that themselves own the daemon state.
    providers: OnceLock<Vec<Weak<dyn CommandProvider>>>,
    events: broadcast::Sender<Event>,
    me: Weak<State>,
    pub(crate) started_at: std::time::Instant,
    /// Host RAM override (tests); `None` probes the host.
    host_memory: Option<HostMemory>,
    /// Footprint samples of running devices (D42 cost model).
    footprints: Mutex<HashMap<Uuid, Footprint>>,
    /// Serialises budget admission so parallel starts can't both slip in.
    budget_gate: Mutex<()>,
    /// When each running device last saw activity (auto-hibernate).
    pub(crate) activity: Mutex<HashMap<Uuid, std::time::Instant>>,
    /// Pool leases (D42, Phase 13d).
    pub(crate) leases: Mutex<crate::leases::Leases>,
    /// Running devices launched from a named snapshot (`-no-snapshot-save`):
    /// their stop saves `default_boot` explicitly.
    resumed: Mutex<std::collections::HashSet<Uuid>>,
    /// Re-adopted processes may have been launched by an older daemon with
    /// automatic exit saving enabled; do not let it overwrite our save.
    adopted: Mutex<std::collections::HashSet<Uuid>>,
}

/// Latest and peak footprint of a device's current run, in MB.
#[derive(Debug, Clone, Copy, Default)]
struct Footprint {
    current: u64,
    peak: u64,
}

impl std::fmt::Debug for State {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("State")
            .field("paths", &self.paths)
            .finish_non_exhaustive()
    }
}

pub(crate) fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// `settings.json`, or the defaults when it is missing or unreadable.
fn load_settings(path: &std::path::Path) -> Settings {
    match std::fs::read_to_string(path) {
        Ok(text) => serde_json::from_str(&text).unwrap_or_else(|e| {
            tracing::warn!("{}: {e}; using the default settings", path.display());
            Settings::default()
        }),
        Err(_) => Settings::default(),
    }
}

fn save_settings(path: &std::path::Path, s: &Settings) -> MikoResult<()> {
    let text = serde_json::to_string_pretty(s).map_err(|e| MikoError::unexpected(e.to_string()))?;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)
            .map_err(|e| MikoError::unexpected(format!("{}: {e}", dir.display())))?;
    }
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, text)
        .and_then(|()| std::fs::rename(&tmp, path))
        .map_err(|e| MikoError::unexpected(format!("{}: {e}", path.display())))
}

impl State {
    /// Preserve the old automatic snapshot before an explicit cold boot.
    pub(crate) fn backup_quick_boot(&self, device: &Device) -> MikoResult<()> {
        let avd = self.paths.avd_home().join(format!("{}.avd", device.avd));
        let quick = avd.join("snapshots/default_boot");
        if !quick.exists() {
            return Ok(());
        }
        let backup = avd
            .join("miko/display-backups")
            .join(Uuid::new_v4().to_string());
        std::fs::create_dir_all(&backup)
            .map_err(|e| MikoError::sdk(format!("cannot create snapshot backup: {e}")))?;
        miko_sdk::cow_copy(&quick, &backup.join("default_boot"))?;
        std::fs::copy(avd.join("config.ini"), backup.join("config.ini"))
            .map_err(|e| MikoError::sdk(format!("cannot back up device configuration: {e}")))?;
        Ok(())
    }

    fn session_marker(&self, device: &Device) -> PathBuf {
        self.avds().dir(&device.avd).join("miko/session-running")
    }

    pub(crate) fn clear_session_marker(&self, device: &Device) {
        let path = self.session_marker(device);
        if let Err(error) = std::fs::remove_file(&path)
            && error.kind() != std::io::ErrorKind::NotFound
        {
            tracing::warn!(path = %path.display(), %error, "could not clear session marker");
        }
    }

    async fn save_stop_snapshot(&self, device: &Device, info: &InstanceInfo) -> MikoResult<()> {
        let avd = self.avds().dir(&device.avd);
        let low_disk = miko_sdk::host::free_space(&avd).is_ok_and(|n| n < 1024 * 1024 * 1024);
        let low_memory = miko_sdk::host::memory().is_ok_and(|m| m.available_mb < 512);
        if low_disk || low_memory {
            self.emit("device.snapshot_warning", json!({"device": device.id, "reason": "low_resources", "low_disk": low_disk, "low_memory": low_memory}));
        }
        let result = async {
            let avd = self.avds().dir(&device.avd);
            self.backend
                .save_quick_boot(info, &avd, &self.adb_path()?)
                .await?;
            miko_sdk::avd::check_snapshot(&avd, "default_boot")
        }
        .await;
        result.map_err(|mut error| {
            tracing::warn!(device = %device.name, error = %error, "quick-boot snapshot save failed");
            error.data = Some(json!({"operation": "quick_boot_save", "cause": error.data.take(), "low_disk": low_disk, "low_memory": low_memory}));
            error
        })
    }
    fn mark_failed_stop_snapshot(&self, device: &Device) -> bool {
        // Never resume a snapshot that may have been partially overwritten.
        // A removed or unavailable data directory must not prevent shutdown.
        if let Err(error) = self.with_store(|store| {
            store.update(device.id, |d| {
                d.launch.force_cold_boot = true;
                d.launch.resume_snapshot = None;
            })
        }) {
            tracing::warn!(device = %device.name, %error, "could not persist cold-boot requirement");
            return false;
        }
        true
    }
    /// Flush the guest and save its state when possible, then stop the device.
    pub(crate) async fn stop_for_quit(&self, id: Uuid) -> MikoResult<()> {
        let device = self.with_store(|store| store.get(id).cloned())?;
        let info = self.instance(id).ok_or_else(|| {
            MikoError::unexpected(format!("{} has no running instance", device.name))
        })?;
        self.flush_guest_storage(&device.name, &info).await;
        let verify_quick_boot = device
            .launch
            .quick_boot
            .unwrap_or(self.settings().quick_boot)
            && device.pool_base.is_none();
        let snapshot_failed =
            verify_quick_boot && self.save_stop_snapshot(&device, &info).await.is_err();
        let cold_boot_persisted = !snapshot_failed || self.mark_failed_stop_snapshot(&device);
        if let Some(watcher) = lock(&self.watchers).remove(&id) {
            watcher.abort();
        }
        lock(&self.instances).remove(&id);
        self.set_status(id, DeviceStatus::Stopping, None);
        let adopted = lock(&self.adopted).contains(&id);
        let result = if snapshot_failed {
            self.backend.stop(&info).await
        } else if adopted && verify_quick_boot {
            self.backend.stop_without_save(&info).await
        } else {
            self.backend.stop_for_quit(&info).await
        };
        if let Err(error) = result {
            lock(&self.instances).insert(id, info.clone());
            self.set_status(id, DeviceStatus::Running, Some(Some(info.runtime())));
            self.watch_crash(id, info);
            return Err(error);
        }
        if cold_boot_persisted {
            self.clear_session_marker(&device);
        }
        lock(&self.resumed).remove(&id);
        lock(&self.adopted).remove(&id);
        self.finish_footprint(id);
        lock(&self.activity).remove(&id);
        self.set_status(id, DeviceStatus::Stopped, Some(None));
        if snapshot_failed {
            self.emit(
                "device.snapshot_warning",
                json!({"device": id, "reason": "stop_save_failed", "cold_boot_persisted": cold_boot_persisted}),
            );
        }
        Ok(())
    }

    pub fn new(
        config: DaemonConfig,
        backend: Arc<dyn Backend>,
        host_memory: Option<HostMemory>,
    ) -> MikoResult<Arc<Self>> {
        let store = DeviceStore::load(config.paths.devices_file())?;
        let leases = crate::leases::Leases::load(
            &config.paths.data.join("pool-leases.json"),
            store.all(),
            chrono::Utc::now(),
        )?;
        let settings = load_settings(&config.paths.settings_file());
        let (events, _) = broadcast::channel(1024);
        Ok(Arc::new_cyclic(|me| Self {
            paths: config.paths,
            storage_lease: OnceLock::new(),
            studio_sdk: config.studio_sdk,
            sdk_repo: config.sdk_repo,
            backend,
            store: Mutex::new(store),
            settings: Mutex::new(settings),
            instances: Mutex::new(HashMap::new()),
            watchers: Mutex::new(HashMap::new()),
            locks: DeviceLocks::default(),
            image_gate: tokio::sync::RwLock::new(()),
            providers: OnceLock::new(),
            events,
            me: me.clone(),
            started_at: std::time::Instant::now(),
            host_memory,
            footprints: Mutex::new(HashMap::new()),
            budget_gate: Mutex::new(()),
            activity: Mutex::new(HashMap::new()),
            leases: Mutex::new(leases),
            resumed: Mutex::new(std::collections::HashSet::new()),
            adopted: Mutex::new(std::collections::HashSet::new()),
        }))
    }

    pub(crate) fn save_leases(&self) -> MikoResult<()> {
        lock(&self.leases).save(&self.paths.data.join("pool-leases.json"))
    }

    pub(crate) fn update_leases<T>(
        &self,
        f: impl FnOnce(&mut crate::leases::Leases) -> MikoResult<T>,
    ) -> MikoResult<T> {
        let mut current = lock(&self.leases);
        let mut next = current.clone();
        let result = f(&mut next)?;
        next.save(&self.paths.data.join("pool-leases.json"))?;
        *current = next;
        Ok(result)
    }

    pub fn host_memory(&self) -> MikoResult<HostMemory> {
        match self.host_memory {
            Some(m) => Ok(m),
            None => miko_sdk::host::memory(),
        }
    }

    /// Guest RAM of a device: `hw.ramSize` in its `config.ini`, else its
    /// profile's.
    fn ram_mb(&self, d: &Device) -> u32 {
        self.avds()
            .config(&d.avd)
            .ok()
            .and_then(|c| c.get("hw.ramSize").and_then(|v| v.trim().parse().ok()))
            .or_else(|| miko_sdk::profiles::find(&d.profile).ok().map(|p| p.ram_mb))
            .unwrap_or(4096)
    }

    pub fn expected_mb(&self, d: &Device) -> u64 {
        // A valid measured peak wins regardless of configured guest RAM.
        // Avoid reading config.ini when its value cannot affect the result.
        if let Some(mb) = d.footprint_mb.filter(|mb| *mb > 0) {
            return u64::from(mb);
        }
        crate::budget::expected_mb(self.ram_mb(d), d.footprint_mb)
    }

    /// The budget with every active device except `except` counted.
    fn budget_except(&self, except: Option<Uuid>) -> MikoResult<Budget> {
        let mem = self.host_memory()?;
        let devices = self.with_store(|s| s.all().to_vec());
        let samples = lock(&self.footprints).clone();
        let used = devices
            .iter()
            .filter(|d| d.status.is_active() && Some(d.id) != except)
            .map(|d| DeviceUse {
                id: d.id,
                name: d.name.clone(),
                expected_mb: self.expected_mb(d),
                measured_mb: samples.get(&d.id).map(|f| f.current).filter(|m| *m > 0),
            })
            .collect();
        Ok(Budget::new(mem, self.settings().budget_percent, used))
    }

    /// `host.budget`.
    pub fn budget(&self) -> MikoResult<Budget> {
        self.budget_except(None)
    }

    /// Admits a start: past the budget it fails with `resource_exhausted`
    /// unless `force`. Marks the device `starting` under the gate, so it
    /// counts for the next admission at once.
    pub fn admit(&self, id: Uuid, force: bool) -> MikoResult<()> {
        let _gate = lock(&self.budget_gate);
        let d = self.with_store(|s| s.get(id).cloned())?;
        if d.status.is_active() {
            return Ok(());
        }
        if !force {
            let budget = self.budget_except(Some(id))?;
            let need = self.expected_mb(&d);
            if !budget.fits(need) {
                let mut e = budget.refusal(&d.name, need);
                if let Some(Value::Object(data)) = e.data.as_mut() {
                    // The longest-idle running devices first: hibernating
                    // one frees all of its RAM (D42).
                    data.insert("hibernate_candidates".into(), json!(self.idle_devices()));
                }
                return Err(e);
            }
        }
        self.set_status(id, DeviceStatus::Starting, None);
        Ok(())
    }

    /// [`admit`](Self::admit), then start. A start that fails before the
    /// emulator runs puts the device back to `stopped`.
    pub async fn start_admitted(
        &self,
        id: Uuid,
        cold_boot: bool,
        force: bool,
        cancel: &Cancel,
    ) -> MikoResult<Device> {
        self.start_admitted_with_progress(id, cold_boot, force, cancel, None)
            .await
    }

    /// [`admit`](Self::admit), then start while forwarding [`BootStage`]
    /// transitions to `on_stage` for job progress reporting.
    pub async fn start_admitted_with_progress(
        &self,
        id: Uuid,
        cold_boot: bool,
        force: bool,
        cancel: &Cancel,
        on_stage: Option<&(dyn Fn(BootStage) + Send + Sync)>,
    ) -> MikoResult<Device> {
        cancel.check()?;
        let d = self.with_store(|s| s.get(id).cloned())?;
        if d.base {
            return Err(MikoError::usage(format!(
                "{} is a base (read-only); lease a clone of it with pool.get",
                d.name
            )));
        }
        self.admit(id, force)?;
        let r = self
            .start_device_with_progress(id, cold_boot, cancel, on_stage)
            .await;
        if r.is_err() && self.instance(id).is_none() {
            let starting = self.with_store(|s| {
                s.get(id)
                    .is_ok_and(|d| matches!(d.status, DeviceStatus::Starting))
            });
            if starting {
                self.set_status(id, DeviceStatus::Stopped, Some(None));
            }
        }
        r
    }

    async fn start_device_with_progress(
        &self,
        id: Uuid,
        cold_boot: bool,
        cancel: &Cancel,
        on_stage: Option<&(dyn Fn(BootStage) + Send + Sync)>,
    ) -> MikoResult<Device> {
        let device = self.with_store(|s| s.get(id).cloned())?;
        if let Some(info) = self.instance(id) {
            if self.backend.is_alive(&info).await {
                return Ok(device);
            }
            lock(&self.instances).remove(&id);
        }
        let marker = self.session_marker(&device);
        let unclean = marker.exists() || matches!(device.status, DeviceStatus::Crashed { .. });
        let quick = self.avds().dir(&device.avd).join("snapshots/default_boot");
        let incomplete = !cold_boot
            && quick.exists()
            && miko_sdk::avd::check_snapshot(&self.avds().dir(&device.avd), "default_boot")
                .is_err();
        if unclean || incomplete {
            self.emit("device.snapshot_warning", json!({"device": id, "reason": if unclean { "unclean_exit" } else { "incomplete_snapshot" }}));
        }
        if cold_boot {
            if matches!(device.status, DeviceStatus::Hibernated)
                || device.launch.resume_snapshot.is_some()
            {
                return Err(MikoError::busy(
                    "resume and stop the saved session before cold booting",
                ));
            }
            let state = self.arc()?;
            let backup_device = device.clone();
            tokio::task::spawn_blocking(move || state.backup_quick_boot(&backup_device))
                .await
                .map_err(|e| MikoError::unexpected(format!("snapshot backup failed: {e}")))??;
        }
        let (spec, _) = self.launch_spec(&device)?;
        for cam in [&device.launch.camera_back, &device.launch.camera_front]
            .into_iter()
            .flatten()
        {
            if !miko_backend::valid_camera(cam) {
                return Err(MikoError::usage(format!(
                    "invalid camera {cam:?}: use emulated, virtualscene, none or webcamN"
                )));
            }
        }
        let resume = device
            .launch
            .resume_snapshot
            .clone()
            .filter(|_| !cold_boot && !device.launch.force_cold_boot);
        let mut extra_args = Vec::new();
        if spec
            .emulator
            .parent()
            .is_some_and(miko_sdk::runtime::installed)
        {
            extra_args.extend(["-feature".into(), "VulkanSnapshots".into()]);
        }
        extra_args.extend(device.launch.extra_args.iter().cloned());
        let opts = LaunchOptions {
            ramdisk: device.launch.ramdisk.clone(),
            camera_back: device.launch.camera_back.clone(),
            camera_front: device.launch.camera_front.clone(),
            extra_args,
            gpu: device.launch.gpu.clone(),
            audio: device.launch.audio.unwrap_or(true),
            cold_boot: cold_boot
                || device.launch.force_cold_boot
                || (!device
                    .launch
                    .quick_boot
                    .unwrap_or(self.settings().quick_boot)
                    && resume.is_none()),
            snapshot: resume.clone(),
            // Save explicitly before stopping. The headless emulator's exit
            // save can stall and leave default_boot without a memory image.
            snapshot_save: false,
            // #25: only adb-root devices boot a writable system image.
            writable_system: device.root.writable_system && device.root.mode == RootMode::Adb,
            ..LaunchOptions::default()
        };
        self.set_status(id, DeviceStatus::Starting, None);
        let progress = |stage: BootStage| {
            if stage == BootStage::Spawned {
                self.set_status(id, DeviceStatus::Booting, None);
            }
            self.emit(
                "device.boot",
                json!({ "device": id, "stage": stage, "progress": stage.progress() }),
            );
            if let Some(cb) = on_stage {
                cb(stage);
            }
        };
        let info = match self.backend.start(&spec, &opts, &progress, cancel).await {
            Ok(info) => info,
            Err(e) => {
                self.set_status(id, DeviceStatus::Stopped, Some(None));
                self.emit("device.boot_failed", json!({ "device": id, "error": e }));
                return Err(e);
            }
        };
        if let Some(parent) = marker.parent()
            && let Err(error) =
                std::fs::create_dir_all(parent).and_then(|()| std::fs::write(&marker, b"running"))
        {
            tracing::warn!(path = %marker.display(), %error, "could not write session marker");
        }
        lock(&self.instances).insert(id, info.clone());
        lock(&self.adopted).remove(&id);
        self.set_status(id, DeviceStatus::Running, Some(Some(info.runtime())));
        if device.launch.force_cold_boot || device.launch.resume_snapshot.is_some() {
            self.with_store(|s| {
                s.update(id, |d| {
                    d.launch.force_cold_boot = false;
                    d.launch.resume_snapshot = None;
                })
            })?;
        }
        self.watch_crash(id, info);
        self.touch(id);
        if resume.is_some() {
            lock(&self.resumed).insert(id);
        } else {
            lock(&self.resumed).remove(&id);
        }
        let device = self.with_store(|s| s.get(id).cloned())?;
        self.run_boot_hooks(&device).await;
        Ok(device)
    }

    /// Samples every running device's footprint (the daemon does this every
    /// 30 s while serving).
    pub async fn sample_footprints(&self) {
        let running: Vec<(Uuid, InstanceInfo)> = lock(&self.instances)
            .iter()
            .map(|(id, i)| (*id, i.clone()))
            .collect();
        for (id, info) in running {
            let Some(mb) = self.backend.footprint_mb(&info).await else {
                continue;
            };
            let mut f = lock(&self.footprints);
            let e = f.entry(id).or_default();
            e.current = mb;
            e.peak = e.peak.max(mb);
        }
    }

    /// Ends a run's sampling: its peak becomes the device's `footprint_mb`.
    pub(crate) fn finish_footprint(&self, id: Uuid) {
        let Some(f) = lock(&self.footprints).remove(&id) else {
            return;
        };
        if f.peak > 0 {
            let peak = u32::try_from(f.peak).unwrap_or(u32::MAX);
            let _ = self.with_store(|s| s.update(id, |d| d.footprint_mb = Some(peak)));
        }
    }

    /// Daemon-wide settings (gap B4).
    pub fn settings(&self) -> Settings {
        *lock(&self.settings)
    }

    /// Changes the settings and saves them to `settings.json`.
    pub fn update_settings(&self, f: impl FnOnce(&mut Settings)) -> MikoResult<Settings> {
        let mut current = lock(&self.settings);
        let mut next = *current;
        f(&mut next);
        save_settings(&self.paths.settings_file(), &next)?;
        *current = next;
        Ok(next)
    }

    pub(crate) fn set_providers(&self, providers: Vec<Arc<dyn CommandProvider>>) {
        let _ = self
            .providers
            .set(providers.iter().map(Arc::downgrade).collect());
    }

    fn arc(&self) -> MikoResult<Arc<State>> {
        self.me
            .upgrade()
            .ok_or_else(|| MikoError::unexpected("daemon is shutting down"))
    }

    pub fn sdks(&self) -> SdkSet {
        SdkSet::discover_with(&self.paths, self.studio_sdk.as_ref().map(Sdk::read_only))
    }

    pub fn avds(&self) -> AvdManager {
        AvdManager::new(self.paths.avd_home())
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.events.subscribe()
    }

    /// Runs `f` on the device store.
    pub fn with_store<T>(&self, f: impl FnOnce(&mut DeviceStore) -> T) -> T {
        f(&mut lock(&self.store))
    }

    pub fn instance(&self, id: Uuid) -> Option<InstanceInfo> {
        lock(&self.instances).get(&id).cloned()
    }

    pub fn running_count(&self) -> usize {
        lock(&self.instances).len()
    }

    pub(crate) fn set_status(
        &self,
        id: Uuid,
        status: DeviceStatus,
        runtime: Option<Option<miko_core::DeviceRuntime>>,
    ) {
        let updated = self.with_store(|s| {
            s.set_runtime(id, |d| {
                d.status = status;
                if let Some(rt) = runtime {
                    d.runtime = rt;
                }
            })
        });
        if let Some(d) = updated {
            self.emit(
                "device.status",
                json!({ "device": d.id, "name": d.name, "status": d.status }),
            );
        }
    }

    /// Re-adopts emulators that kept running across a daemon restart.
    pub async fn adopt_running(&self) {
        for info in self.backend.adopt(&self.paths.avd_home()).await {
            let id = self.with_store(|s| s.all().iter().find(|d| d.avd == info.avd).map(|d| d.id));
            let Some(id) = id else { continue };
            lock(&self.instances).insert(id, info.clone());
            lock(&self.adopted).insert(id);
            self.set_status(id, DeviceStatus::Running, Some(Some(info.runtime())));
            self.watch_crash(id, info);
            self.touch(id);
        }
    }

    pub(crate) fn watch_crash(&self, id: Uuid, info: InstanceInfo) {
        let Ok(me) = self.arc() else { return };
        let handle = tokio::spawn(async move {
            let log_dir = me.paths.device_logs(&info.avd);
            let report = me.backend.wait_for_crash(&info, &log_dir).await;
            let still_ours = lock(&me.instances)
                .get(&id)
                .is_some_and(|i| i.pid == info.pid);
            if !still_ours {
                return;
            }
            lock(&me.instances).remove(&id);
            lock(&me.watchers).remove(&id);
            me.finish_footprint(id);
            // Releases ports; the process is already gone.
            let _ = me.backend.stop(&info).await;
            me.set_status(
                id,
                DeviceStatus::Crashed {
                    reason: report.reason.clone(),
                    log: report.log.clone(),
                },
                Some(None),
            );
            me.emit("device.crashed", json!({ "device": id, "report": report }));
        });
        if let Some(old) = lock(&self.watchers).insert(id, handle) {
            old.abort();
        }
    }

    fn launch_spec(&self, d: &Device) -> MikoResult<(LaunchSpec, Sdk)> {
        let sdks = self.sdks();
        // A device must keep using the image copy it was created with, even
        // when the selected SDK location changes or another copy exists.
        let image_sdk = Sdk::read_only(&d.sdk_root);
        if !image_sdk.has_image(&d.image) {
            return Err(MikoError::sdk(format!(
                "system image {} is unavailable in {}; restore the original SDK location",
                d.image.package(),
                d.sdk_root.display()
            )));
        }
        let tools = sdks.tools()?.clone();
        Ok((
            LaunchSpec {
                avd: d.avd.clone(),
                avd_home: self.paths.avd_home(),
                sdk_root: image_sdk.root.clone(),
                sysdir: image_sdk.image_dir(&d.image),
                emulator: tools.emulator(),
                adb: tools.adb(),
                log_dir: self.paths.device_logs(&d.avd),
            },
            image_sdk,
        ))
    }

    async fn run_boot_hooks(&self, device: &Device) {
        let Ok(me) = self.arc() else { return };
        let providers = self.providers.get().cloned().unwrap_or_default();
        let ctx = CallCtx::new(me);
        for p in providers.into_iter().filter_map(|p| p.upgrade()) {
            if let Err(e) = p.on_booted(&ctx, device).await {
                tracing::warn!(provider = p.name(), device = %device.name, "boot hook failed: {e}");
                self.emit(
                    "device.hook_failed",
                    json!({ "device": device.id, "provider": p.name(), "error": e }),
                );
            }
        }
    }

    /// Best-effort `sync` in the guest before a graceful stop. The emulator's
    /// `Shutdown` VM state ends the VM without flushing the guest's page
    /// cache, so recent `/data` writes (a `settings put` from `proxy clear`)
    /// could be lost at the next cold boot (#79). A device adb can't reach
    /// still stops; this only logs.
    async fn flush_guest_storage(&self, name: &str, info: &InstanceInfo) {
        let adb = match self.adb_path() {
            Ok(path) => Adb::new(path)
                .device(info.adb_serial.clone())
                .with_timeout(STOP_SYNC_TIMEOUT),
            Err(e) => {
                tracing::warn!(device = %name, "no adb to flush guest storage before stop: {e}");
                return;
            }
        };
        if let Err(e) = adb.sync().await {
            tracing::warn!(device = %name, "flushing guest storage before stop failed: {e}");
        }
    }
}

#[async_trait]
impl DaemonContext for State {
    fn paths(&self) -> &MikoPaths {
        &self.paths
    }

    fn adb_path(&self) -> MikoResult<PathBuf> {
        Ok(self.sdks().tools()?.adb())
    }

    async fn device(&self, selector: &str) -> MikoResult<Device> {
        self.with_store(|s| s.find(selector).cloned())
    }

    async fn devices(&self) -> Vec<Device> {
        self.with_store(|s| s.all().to_vec())
    }

    async fn connect_info(&self, device: Uuid) -> MikoResult<ConnectInfo> {
        let info = self
            .instance(device)
            .ok_or_else(|| MikoError::not_found("device is not running; start it first"))?;
        Ok(ConnectInfo {
            device,
            grpc_endpoint: format!("127.0.0.1:{}", info.grpc_port),
            grpc_port: info.grpc_port,
            grpc_token: info.grpc_token.clone(),
            adb_serial: info.adb_serial.clone(),
            adb_path: self.adb_path()?,
            console_port: info.console_port,
        })
    }

    async fn update_device(&self, device: Uuid, f: DeviceUpdate) -> MikoResult<Device> {
        let d = self.with_store(|s| s.update(device, f))?;
        self.emit("device.updated", json!({ "device": d.id, "name": d.name }));
        Ok(d)
    }

    async fn start_device(&self, id: Uuid, cold_boot: bool, cancel: &Cancel) -> MikoResult<Device> {
        self.start_device_with_progress(id, cold_boot, cancel, None)
            .await
    }

    async fn stop_device(&self, id: Uuid) -> MikoResult<Device> {
        let current = self.with_store(|s| s.get(id).cloned())?;
        if matches!(current.status, DeviceStatus::Hibernated) {
            // Already stopped, with its state saved for the next start.
            return Ok(current);
        }
        let info = self.instance(id);
        if let Some(info) = info {
            self.flush_guest_storage(&current.name, &info).await;
            let resumed = lock(&self.resumed).contains(&id);
            let quick_boot = current
                .launch
                .quick_boot
                .unwrap_or(self.settings().quick_boot)
                && current.pool_base.is_none();
            let snapshot_failed =
                quick_boot && self.save_stop_snapshot(&current, &info).await.is_err();
            let cold_boot_persisted = !snapshot_failed || self.mark_failed_stop_snapshot(&current);
            if let Some(w) = lock(&self.watchers).remove(&id) {
                w.abort();
            }
            lock(&self.instances).remove(&id);
            lock(&self.resumed).remove(&id);
            self.set_status(id, DeviceStatus::Stopping, None);
            let adopted = lock(&self.adopted).contains(&id);
            let result = if adopted && quick_boot && !snapshot_failed {
                self.backend.stop_without_save(&info).await
            } else {
                self.backend.stop(&info).await
            };
            if let Err(e) = result {
                // Put it back: we don't know its state.
                lock(&self.instances).insert(id, info.clone());
                if resumed {
                    lock(&self.resumed).insert(id);
                }
                self.set_status(id, DeviceStatus::Running, Some(Some(info.runtime())));
                self.watch_crash(id, info);
                return Err(e);
            }
            lock(&self.adopted).remove(&id);
            if cold_boot_persisted {
                self.clear_session_marker(&current);
            }
            if snapshot_failed {
                self.emit(
                    "device.snapshot_warning",
                    json!({"device": id, "reason": "stop_save_failed", "cold_boot_persisted": cold_boot_persisted}),
                );
            }
        }
        self.finish_footprint(id);
        crate::state::lock(&self.activity).remove(&id);
        self.set_status(id, DeviceStatus::Stopped, Some(None));
        self.with_store(|s| s.get(id).cloned())
    }

    async fn shut_down_device(&self, id: Uuid) -> MikoResult<Device> {
        let current = self.with_store(|s| s.get(id).cloned())?;
        let Some(info) = self.instance(id) else {
            return self.stop_device(id).await;
        };
        // A guest shutdown can make the emulator exit. Prevent the crash
        // watcher from treating that expected exit as a crash.
        if let Some(w) = lock(&self.watchers).remove(&id) {
            w.abort();
        }
        let powered_off = if let Ok(path) = self.adb_path() {
            let adb = Adb::new(path)
                .device(&info.adb_serial)
                .with_timeout(std::time::Duration::from_secs(30));
            if adb.shell("true").await.is_ok() {
                // adbd usually disconnects while the command is in flight;
                // its result does not establish whether shutdown succeeded.
                let _ = adb.shell("svc power shutdown").await;
                self.backend
                    .wait_powered_off(&info, std::time::Duration::from_secs(90))
                    .await
            } else {
                false
            }
        } else {
            false
        };
        if !powered_off {
            tracing::warn!(device = %current.name, "Android shutdown unconfirmed; falling back to normal stop");
            self.watch_crash(id, info);
            return self.stop_device(id).await;
        }

        lock(&self.instances).remove(&id);
        let resumed = lock(&self.resumed).remove(&id);
        self.set_status(id, DeviceStatus::Stopping, None);
        if let Err(e) = self.backend.stop_without_save(&info).await {
            lock(&self.instances).insert(id, info.clone());
            if resumed {
                lock(&self.resumed).insert(id);
            }
            self.set_status(id, DeviceStatus::Running, Some(Some(info.runtime())));
            self.watch_crash(id, info);
            return Err(e);
        }
        self.clear_session_marker(&current);
        self.finish_footprint(id);
        lock(&self.activity).remove(&id);
        self.set_status(id, DeviceStatus::Stopped, Some(None));
        self.with_store(|s| s.get(id).cloned())
    }

    fn emit(&self, topic: &str, data: Value) {
        // No listeners is fine.
        let _ = self.events.send(Event {
            topic: topic.to_string(),
            data,
        });
    }
}
