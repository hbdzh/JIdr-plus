//! Synced folders (#27): `file.sync.start`, `file.sync.stop`, `file.sync.list`,
//! `file.sync.resolve`.
//!
//! Supports both one-way (`one_way`, host to device) and two-way
//! (`bidirectional`, host <-> device) folder synchronization.
//!
//! - **One-way**: copies the host folder to the device once, then watches it
//!   (`notify`: FSEvents on macOS, inotify on Linux) and mirrors each debounced
//!   batch of changes with `adb push` and `rm`. Deleting on the host deletes
//!   previously synced files on the device; device-only files and directories
//!   are left alone.
//! - **Bidirectional**: reconciles both trees against a per-session SHA-256
//!   content baseline using host `notify` events and periodic device scans
//!   (`adb shell find`/`stat` + lazy `sha256sum`), pushing, pulling, and
//!   propagating deletions while preserving conflicts for explicit resolution
//!   (`file.sync.resolve`).
//!
//! A sync lives as long as its device runs: when the device stops,
//! hibernates, crashes or is deleted, the sync ends with
//! `file.sync.stopped`. It isn't resumed at the next boot, nor kept across
//! a daemon restart.

pub mod plan;
mod reconcile;

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::path::{Component, Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use jidr_adb::Adb;
use jidr_core::provider::{CallCtx, CommandProvider, CommandSpec, DaemonContext, parse_params};
use jidr_core::{JidrError, JidrResult};
use notify::Watcher;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::{broadcast, mpsc, oneshot};
use tokio::task::JoinHandle;
use uuid::Uuid;

use crate::state::{State, lock};
use plan::{Batch, Debouncer, Ignore, Mirror, Op};
pub use reconcile::SyncConflict;
use reconcile::{FileEntry, ReconcilePlan};

/// adb pushes/pulls of one batch and the shell scripts.
const ADB_TIMEOUT: Duration = Duration::from_secs(600);

/// How often bidirectional sync polls the device for remote changes.
const BIDI_POLL_INTERVAL: Duration = Duration::from_secs(2);

// ---- params and results -------------------------------------------------

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum SyncDirection {
    #[default]
    OneWay,
    Bidirectional,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ConflictChoice {
    KeepLocal,
    KeepRemote,
    KeepBoth,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct StartParams {
    /// Device name or id (must be running).
    pub device: String,
    /// Folder on this machine (an absolute path).
    pub local: PathBuf,
    /// Folder on the device; default `/sdcard/Download/<the local folder's name>`.
    #[serde(default)]
    pub remote: Option<String>,
    /// Sync direction: `one_way` (host to device, default) or `bidirectional`.
    #[serde(default)]
    pub direction: SyncDirection,
    /// More file or folder names to skip at any depth (exact names, not
    /// patterns), besides `.git`, `node_modules` and `.DS_Store`.
    #[serde(default)]
    pub ignore: Vec<String>,
    /// Sync `.git`, `node_modules` and `.DS_Store` too.
    #[serde(default)]
    pub no_default_ignore: bool,
    /// Refuse a folder with more files than this, after skips (default 10000).
    #[serde(default)]
    pub max_files: Option<u64>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct StopParams {
    /// Sync id (`file.sync.list`), or its first characters when they name one sync.
    pub id: String,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ListParams {
    /// Only this device's syncs (name or id).
    #[serde(default)]
    pub device: Option<String>,
}

#[derive(Debug, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ResolveParams {
    /// Sync id (`file.sync.list`), or its first characters when they name one sync.
    pub id: String,
    /// Relative path of the conflicted file inside the synced folder.
    pub path: PathBuf,
    /// How to resolve the conflict (`keep_local`, `keep_remote`, or `keep_both`).
    pub resolution: ConflictChoice,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum SyncState {
    /// The first full copy/reconciliation is running.
    Mirroring,
    /// Copying a batch of changes.
    Syncing,
    /// Up to date, waiting for changes.
    Watching,
}

/// A sync, as `file.sync.start` and `file.sync.list` return it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, JsonSchema)]
pub struct SyncInfo {
    pub id: Uuid,
    pub device: Uuid,
    /// The device's name when the sync started.
    pub name: String,
    pub local: PathBuf,
    pub remote: String,
    #[serde(default)]
    pub direction: SyncDirection,
    pub state: SyncState,
    /// Files in the folder, after skips.
    pub files: u64,
    pub bytes: u64,
    /// Names skipped at any depth.
    pub ignore: Vec<String>,
    /// Files copied to the device so far, the first copy included.
    pub pushed: u64,
    /// Files copied from the device to this machine so far (bidirectional sync).
    #[serde(default)]
    pub pulled: u64,
    /// Paths deleted on the device so far.
    pub removed: u64,
    /// Paths deleted on this machine so far (bidirectional sync).
    #[serde(default)]
    pub removed_local: u64,
    /// Unresolved conflicts in bidirectional sync.
    #[serde(default)]
    pub conflicts: Vec<SyncConflict>,
    pub started_at: DateTime<Utc>,
    #[serde(default)]
    pub last_synced_at: Option<DateTime<Utc>>,
    /// The last failure; cleared by the next batch that goes through.
    #[serde(default)]
    pub last_error: Option<String>,
}

/// Why a sync ended (`file.sync.stopped`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum StopReason {
    Requested,
    DeviceStopped,
    DeviceDeleted,
    FolderGone,
    WatchFailed,
}

// ---- provider -----------------------------------------------------------

enum SyncCommand {
    Resolve {
        path: PathBuf,
        resolution: ConflictChoice,
        reply: oneshot::Sender<JidrResult<SyncInfo>>,
    },
}

struct Entry {
    info: Arc<Mutex<SyncInfo>>,
    task: JoinHandle<()>,
    cmd_tx: Option<mpsc::UnboundedSender<SyncCommand>>,
}

type Syncs = Mutex<HashMap<Uuid, Entry>>;

pub struct SyncProvider {
    state: Arc<State>,
    syncs: Arc<Syncs>,
    listening: AtomicBool,
}

impl SyncProvider {
    pub fn new(state: Arc<State>) -> Self {
        Self {
            state,
            syncs: Arc::new(Mutex::new(HashMap::new())),
            listening: AtomicBool::new(false),
        }
    }

    /// Ends syncs whose device stops or goes away, from the daemon's own
    /// events. Started by the first `file.sync.start`.
    fn listen(&self) {
        if self.listening.swap(true, Ordering::SeqCst) {
            return;
        }
        let rx = self.state.subscribe();
        let syncs = Arc::downgrade(&self.syncs);
        let state = Arc::downgrade(&self.state);
        tokio::spawn(watch_devices(rx, syncs, state));
    }

    async fn start(&self, p: StartParams) -> JidrResult<Value> {
        self.listen();
        let d = self.state.device(&p.device).await?;
        let info = self.state.connect_info(d.id).await?;
        let local = host_folder(&p.local)?;
        let remote = device_folder(p.remote.as_deref(), &local)?;
        taken(&lock(&self.syncs), d.id, &d.name, &remote)?;
        let ignore = Ignore::new(!p.no_default_ignore, &p.ignore);
        let max = p.max_files.unwrap_or(plan::DEFAULT_MAX_FILES);

        let (tx, rx) = mpsc::unbounded_channel();
        let (watcher, mirror) = {
            let (local_watch, local_scan, ignore_scan) =
                (local.clone(), local.clone(), ignore.clone());
            tokio::task::spawn_blocking(move || -> JidrResult<_> {
                let mut watcher = notify::recommended_watcher(move |ev| {
                    let _ = tx.send(ev);
                })
                .map_err(|e| {
                    JidrError::unexpected(format!("can't watch {}: {e}", local_watch.display()))
                })?;
                watcher
                    .watch(&local_watch, notify::RecursiveMode::Recursive)
                    .map_err(|e| {
                        JidrError::unexpected(format!("can't watch {}: {e}", local_watch.display()))
                    })?;
                let mirror = plan::scan(&local_scan, Path::new(""), &ignore_scan, max)?;
                Ok((watcher, mirror))
            })
            .await
            .map_err(|e| JidrError::unexpected(format!("scanning the folder: {e}")))??
        };

        let sync = SyncInfo {
            id: Uuid::new_v4(),
            device: d.id,
            name: d.name.clone(),
            local: local.clone(),
            remote,
            direction: p.direction,
            state: SyncState::Mirroring,
            files: mirror.files,
            bytes: mirror.bytes,
            ignore: ignore.names(),
            pushed: 0,
            pulled: 0,
            removed: 0,
            removed_local: 0,
            conflicts: Vec::new(),
            started_at: Utc::now(),
            last_synced_at: None,
            last_error: None,
        };
        let shared = Arc::new(Mutex::new(sync.clone()));
        let run = Run {
            id: sync.id,
            device: d.id,
            root: local,
            remote: sync.remote.clone(),
            ignore,
            max_files: max,
            adb: Adb::new(info.adb_path)
                .device(info.adb_serial)
                .with_timeout(ADB_TIMEOUT),
            info: shared.clone(),
            state: Arc::downgrade(&self.state),
            syncs: Arc::downgrade(&self.syncs),
        };
        {
            // Checked again under the lock: another start may have won
            // while this one scanned.
            let mut syncs = lock(&self.syncs);
            taken(&syncs, d.id, &d.name, &sync.remote)?;
            self.state.emit("file.sync.started", to_value(&sync)?);
            let (cmd_tx, task) = match p.direction {
                SyncDirection::OneWay => {
                    let task = tokio::spawn(async move {
                        let _watcher = watcher;
                        run.run_one_way(mirror, rx).await;
                    });
                    (None, task)
                }
                SyncDirection::Bidirectional => {
                    let (cmd_tx, cmd_rx) = mpsc::unbounded_channel();
                    let task = tokio::spawn(async move {
                        let _watcher = watcher;
                        run.run_bidirectional(rx, cmd_rx).await;
                    });
                    (Some(cmd_tx), task)
                }
            };
            syncs.insert(
                sync.id,
                Entry {
                    info: shared,
                    task,
                    cmd_tx,
                },
            );
        }
        // The device may have stopped before the listener saw it.
        if self.state.instance(d.id).is_none() {
            end(&self.syncs, &self.state, sync.id, StopReason::DeviceStopped);
            return Err(JidrError::not_found(format!("{} stopped", d.name)));
        }
        to_value(&sync)
    }

    fn find(&self, sel: &str) -> JidrResult<Uuid> {
        let sel = sel.trim().to_ascii_lowercase();
        let syncs = lock(&self.syncs);
        let hits: Vec<Uuid> = syncs
            .keys()
            .filter(|id| !sel.is_empty() && id.to_string().starts_with(&sel))
            .copied()
            .collect();
        match hits.as_slice() {
            [id] => Ok(*id),
            [] => Err(JidrError::not_found(format!("no sync {sel}"))),
            _ => Err(JidrError::usage(format!(
                "{sel} names {} syncs; give more of the id",
                hits.len()
            ))),
        }
    }

    async fn list(&self, p: ListParams) -> JidrResult<Value> {
        let device = match &p.device {
            Some(sel) => Some(self.state.device(sel).await?.id),
            None => None,
        };
        let mut all: Vec<SyncInfo> = lock(&self.syncs)
            .values()
            .map(|e| lock(&e.info).clone())
            .filter(|s| device.is_none_or(|d| s.device == d))
            .collect();
        all.sort_by_key(|s| s.started_at);
        to_value(&all)
    }

    async fn resolve(&self, p: ResolveParams) -> JidrResult<Value> {
        let path = validate_rel_path(&p.path)?;
        let id = self.find(&p.id)?;
        let tx = {
            let syncs = lock(&self.syncs);
            let entry = syncs
                .get(&id)
                .ok_or_else(|| JidrError::not_found(format!("no sync {id}")))?;
            entry.cmd_tx.clone().ok_or_else(|| {
                JidrError::usage("only bidirectional syncs have conflicts to resolve")
            })?
        };
        let (reply_tx, reply_rx) = oneshot::channel();
        tx.send(SyncCommand::Resolve {
            path,
            resolution: p.resolution,
            reply: reply_tx,
        })
        .map_err(|_| JidrError::not_found(format!("sync {id} ended")))?;
        let updated = reply_rx
            .await
            .map_err(|_| JidrError::not_found(format!("sync {id} ended")))??;
        to_value(&updated)
    }
}

#[async_trait]
impl CommandProvider for SyncProvider {
    fn name(&self) -> &str {
        "sync"
    }

    fn commands(&self) -> Vec<CommandSpec> {
        vec![
            CommandSpec::new::<StartParams>(
                "file.sync.start",
                "Keep a folder on this machine synced with a running device (one-way or bidirectional)",
            ),
            CommandSpec::new::<StopParams>("file.sync.stop", "Stop a folder sync"),
            CommandSpec::new::<ListParams>("file.sync.list", "Folder syncs and their state"),
            CommandSpec::new::<ResolveParams>(
                "file.sync.resolve",
                "Resolve a conflict in a bidirectional folder sync",
            ),
        ]
    }

    async fn call(&self, _ctx: &CallCtx, method: &str, params: Value) -> JidrResult<Value> {
        match method {
            "file.sync.start" => self.start(parse_params(params)?).await,
            "file.sync.stop" => {
                let p: StopParams = parse_params(params)?;
                let id = self.find(&p.id)?;
                let info = end(&self.syncs, &self.state, id, StopReason::Requested)
                    .ok_or_else(|| JidrError::not_found(format!("no sync {id}")))?;
                to_value(&info)
            }
            "file.sync.list" => self.list(parse_params(params)?).await,
            "file.sync.resolve" => self.resolve(parse_params(params)?).await,
            other => Err(JidrError::usage(format!(
                "sync provider has no command {other}"
            ))),
        }
    }
}

fn validate_rel_path(path: &Path) -> JidrResult<PathBuf> {
    if path.as_os_str().is_empty()
        || path
            .components()
            .any(|c| !matches!(c, Component::Normal(_)))
    {
        return Err(JidrError::usage(format!(
            "path must be a relative path inside the synced folder (got {})",
            path.display()
        )));
    }
    Ok(path.to_path_buf())
}

fn to_value<T: Serialize>(v: &T) -> JidrResult<Value> {
    serde_json::to_value(v).map_err(|e| JidrError::unexpected(format!("encoding result: {e}")))
}

/// The host folder, canonical (FSEvents reports `/private/var/…` for
/// `/var/…`, so event paths only match a canonical root).
fn host_folder(local: &Path) -> JidrResult<PathBuf> {
    if !local.is_absolute() {
        return Err(JidrError::usage(format!(
            "local must be an absolute path, not {}",
            local.display()
        )));
    }
    let dir = std::fs::canonicalize(local)
        .map_err(|e| JidrError::usage(format!("can't open {}: {e}", local.display())))?;
    if !dir.is_dir() {
        return Err(JidrError::usage(format!(
            "{} is not a folder; use file.push for a file",
            local.display()
        )));
    }
    Ok(dir)
}

/// The device folder: absolute, without `.`/`..` parts or a trailing `/`,
/// and not `/` itself.
pub fn device_folder(remote: Option<&str>, local: &Path) -> JidrResult<String> {
    let remote = match remote {
        Some(r) => r.trim().to_string(),
        None => {
            let name = local
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .ok_or_else(|| JidrError::usage("name the device folder with remote"))?;
            format!("/sdcard/Download/{name}")
        }
    };
    let bad = !remote.starts_with('/')
        || remote.contains(['\n', '\r', '\0'])
        || remote.split('/').any(|p| p == "." || p == "..");
    let trimmed = remote.trim_end_matches('/');
    if bad || trimmed.is_empty() {
        return Err(JidrError::usage(format!(
            "remote must be an absolute device folder other than /, without . or .. (got {remote:?})"
        )));
    }
    Ok(trimmed.to_string())
}

/// `usage` when `remote` on `device` is already synced, or holds or sits in
/// a synced folder.
fn taken(syncs: &HashMap<Uuid, Entry>, device: Uuid, name: &str, remote: &str) -> JidrResult<()> {
    let hit = syncs.values().find_map(|e| {
        let s = lock(&e.info);
        (s.device == device && overlaps(&s.remote, remote)).then(|| (s.id, s.remote.clone()))
    });
    match hit {
        Some((id, other)) => Err(JidrError::usage(format!(
            "{other} on {name} is already synced (sync {id}); stop it first"
        ))
        .with_data(json!({ "id": id }))),
        None => Ok(()),
    }
}

/// Whether two device folders are the same or one holds the other.
pub fn overlaps(a: &str, b: &str) -> bool {
    let inside = |x: &str, y: &str| x.strip_prefix(y).is_some_and(|r| r.starts_with('/'));
    a == b || inside(a, b) || inside(b, a)
}

/// Removes a sync, stops its task and announces it. `None` if it was gone.
fn end(syncs: &Syncs, state: &State, id: Uuid, reason: StopReason) -> Option<SyncInfo> {
    let entry = lock(syncs).remove(&id)?;
    entry.task.abort();
    let info = lock(&entry.info).clone();
    state.emit(
        "file.sync.stopped",
        json!({ "id": id, "device": info.device, "reason": reason }),
    );
    Some(info)
}

/// Ends the syncs of devices that stop running (`device.status`) or are
/// deleted. After missed events it checks every sync's device.
async fn watch_devices(
    mut rx: broadcast::Receiver<jidr_core::rpc::Event>,
    syncs: Weak<Syncs>,
    state: Weak<State>,
) {
    loop {
        let ev = rx.recv().await;
        let (Some(syncs), Some(state)) = (syncs.upgrade(), state.upgrade()) else {
            return;
        };
        let device_of = |e: &Entry| lock(&e.info).device;
        let ended: Vec<(Uuid, StopReason)> = match ev {
            Ok(ev) => {
                let reason = match ev.topic.as_str() {
                    "device.status" if ev.data["status"]["state"] != "running" => {
                        StopReason::DeviceStopped
                    }
                    "device.deleted" => StopReason::DeviceDeleted,
                    _ => continue,
                };
                let device = ev.data["device"].as_str().unwrap_or_default().to_string();
                lock(&syncs)
                    .iter()
                    .filter(|(_, e)| device_of(e).to_string() == device)
                    .map(|(id, _)| (*id, reason))
                    .collect()
            }
            Err(broadcast::error::RecvError::Lagged(_)) => lock(&syncs)
                .iter()
                .filter(|(_, e)| state.instance(device_of(e)).is_none())
                .map(|(id, _)| (*id, StopReason::DeviceStopped))
                .collect(),
            Err(broadcast::error::RecvError::Closed) => return,
        };
        for (id, reason) in ended {
            end(&syncs, &state, id, reason);
        }
    }
}

// ---- one sync -----------------------------------------------------------

/// Which copy a `file.sync.progress` event is about.
#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
enum Phase {
    Mirror,
    Change,
}

#[derive(Debug, Clone, Copy, Default)]
struct BidiStats {
    pushed: u64,
    pulled: u64,
    removed: u64,
    removed_local: u64,
}

impl BidiStats {
    fn any(self) -> bool {
        self.pushed > 0 || self.pulled > 0 || self.removed > 0 || self.removed_local > 0
    }
}

struct BidiState {
    baseline: BTreeMap<PathBuf, String>,
    local_cache: HashMap<PathBuf, FileEntry>,
    remote_cache: HashMap<PathBuf, FileEntry>,
    last_local: BTreeMap<PathBuf, FileEntry>,
    last_conflicts: Vec<SyncConflict>,
    initial_done: bool,
}

impl BidiState {
    fn new() -> Self {
        Self {
            baseline: BTreeMap::new(),
            local_cache: HashMap::new(),
            remote_cache: HashMap::new(),
            last_local: BTreeMap::new(),
            last_conflicts: Vec::new(),
            initial_done: false,
        }
    }
}

struct Run {
    id: Uuid,
    device: Uuid,
    root: PathBuf,
    remote: String,
    ignore: Ignore,
    max_files: u64,
    adb: Adb,
    info: Arc<Mutex<SyncInfo>>,
    state: Weak<State>,
    syncs: Weak<Syncs>,
}

impl Run {
    async fn run_one_way(
        self,
        mirror: Mirror,
        mut rx: mpsc::UnboundedReceiver<notify::Result<notify::Event>>,
    ) {
        let mut pending = Debouncer::default();
        let mut known = BTreeSet::new();
        let mut first = Some(mirror);
        loop {
            if let Some(mirror) = first.take() {
                match self.mirror(&mirror).await {
                    Ok(pushed) => {
                        known = mirror.paths;
                        self.finish_one_way(Ok((pushed, 0)));
                    }
                    Err(e) => {
                        self.finish_one_way(Err(e));
                        loop {
                            tokio::time::sleep(Duration::from_secs(2)).await;
                            if !self.root.is_dir() {
                                self.stop(StopReason::FolderGone);
                                return;
                            }
                            let (root, ignore, max) =
                                (self.root.clone(), self.ignore.clone(), self.max_files);
                            match tokio::task::spawn_blocking(move || {
                                plan::scan(&root, Path::new(""), &ignore, max)
                            })
                            .await
                            {
                                Ok(Ok(m)) => {
                                    first = Some(m);
                                    break;
                                }
                                Ok(Err(e)) => {
                                    self.error(&e.message);
                                }
                                Err(e) => {
                                    self.error(&format!("scanning: {e}"));
                                }
                            }
                        }
                        continue;
                    }
                }
            }
            let due = pending
                .deadline()
                .unwrap_or_else(|| Instant::now() + Duration::from_secs(3600));
            tokio::select! {
                ev = rx.recv() => match ev {
                    Some(Ok(ev)) => self.note(&ev, &mut pending),
                    Some(Err(e)) => self.error(&format!("watching {}: {e}", self.root.display())),
                    None => {
                        self.stop(StopReason::WatchFailed);
                        return;
                    }
                },
                () = tokio::time::sleep_until(tokio::time::Instant::from_std(due)) => {
                    if let Some(paths) = pending.take(Instant::now()) {
                        if !self.root.is_dir() {
                            self.stop(StopReason::FolderGone);
                            return;
                        }
                        match self.apply(&paths, &mut known).await {
                            Ok(None) => {}
                            Ok(Some(done)) => self.finish_one_way(Ok(done)),
                            Err(e) => {
                                self.finish_one_way(Err(e));
                                tokio::time::sleep(Duration::from_secs(2)).await;
                                for path in paths { pending.add(path, Instant::now()); }
                            },
                        }
                    }
                }
            }
        }
    }

    async fn run_bidirectional(
        self,
        mut rx: mpsc::UnboundedReceiver<notify::Result<notify::Event>>,
        mut cmd_rx: mpsc::UnboundedReceiver<SyncCommand>,
    ) {
        let mut pending = Debouncer::default();
        let mut bidi = BidiState::new();
        let mut next_poll = Instant::now();
        let mut need_local_only = false;

        loop {
            let now = Instant::now();
            if now >= next_poll || need_local_only {
                if !self.root.is_dir() {
                    self.stop(StopReason::FolderGone);
                    return;
                }
                let force_remote = now >= next_poll || !bidi.initial_done;
                match self.reconcile_cycle(&mut bidi, force_remote).await {
                    Ok(()) => {
                        need_local_only = false;
                        next_poll = Instant::now() + BIDI_POLL_INTERVAL;
                    }
                    Err(e) => {
                        self.set_state(SyncState::Watching);
                        self.error(&e.message);
                        need_local_only = false;
                        next_poll = Instant::now() + BIDI_POLL_INTERVAL;
                    }
                }
            }

            let due = pending.deadline().map_or(next_poll, |d| d.min(next_poll));
            tokio::select! {
                ev = rx.recv() => match ev {
                    Some(Ok(ev)) => self.note(&ev, &mut pending),
                    Some(Err(e)) => self.error(&format!("watching {}: {e}", self.root.display())),
                    None => {
                        self.stop(StopReason::WatchFailed);
                        return;
                    }
                },
                cmd = cmd_rx.recv() => match cmd {
                    Some(SyncCommand::Resolve { path, resolution, reply }) => {
                        let res = self.resolve_conflict(&mut bidi, &path, resolution).await;
                        let _ = reply.send(res);
                    }
                    None => {}
                },
                () = tokio::time::sleep_until(tokio::time::Instant::from_std(due)) => {
                    if pending.take(Instant::now()).is_some() {
                        need_local_only = true;
                    }
                }
            }
        }
    }

    async fn reconcile_cycle(&self, bidi: &mut BidiState, force_remote: bool) -> JidrResult<()> {
        let local_files = self.scan_local(&mut bidi.local_cache).await?;
        if !force_remote && bidi.initial_done && local_files == bidi.last_local {
            return Ok(());
        }
        let remote_files = self.scan_remote(&mut bidi.remote_cache).await?;
        let plan = reconcile::reconcile_trees(&bidi.baseline, &local_files, &remote_files);

        for (path, hash) in &plan.agreed {
            bidi.baseline.insert(path.clone(), hash.clone());
        }
        for path in &plan.both_gone {
            bidi.baseline.remove(path);
        }

        if !plan.has_transfers() {
            let (files, bytes) = tree_totals(&local_files);
            self.update_conflicts(bidi, plan.conflicts);
            if !bidi.initial_done {
                self.ensure_remote_dir().await?;
                bidi.initial_done = true;
                self.finish_bidi(BidiStats::default(), files, bytes, true);
            } else {
                let mut info = lock(&self.info);
                info.files = files;
                info.bytes = bytes;
                info.state = SyncState::Watching;
                info.last_error = None;
            }
            bidi.last_local = local_files;
            return Ok(());
        }

        let phase = if bidi.initial_done {
            self.set_state(SyncState::Syncing);
            Phase::Change
        } else {
            Phase::Mirror
        };

        let stats = self
            .execute_bidi_plan(bidi, &plan, &local_files, &remote_files, phase)
            .await?;

        let post_local = self
            .scan_local(&mut bidi.local_cache)
            .await
            .unwrap_or(local_files);
        let (files, bytes) = tree_totals(&post_local);
        bidi.last_local = post_local;
        let first = !bidi.initial_done;
        bidi.initial_done = true;
        self.update_conflicts(bidi, plan.conflicts);
        self.finish_bidi(stats, files, bytes, first || stats.any());
        Ok(())
    }

    async fn execute_bidi_plan(
        &self,
        bidi: &mut BidiState,
        plan: &ReconcilePlan,
        local_files: &BTreeMap<PathBuf, FileEntry>,
        remote_files: &BTreeMap<PathBuf, FileEntry>,
        phase: Phase,
    ) -> JidrResult<BidiStats> {
        let mut stats = BidiStats::default();
        let total = (plan.pushes.len()
            + plan.pulls.len()
            + plan.delete_remote.len()
            + plan.delete_local.len()) as u64;
        let mut done = 0u64;

        // 1. Delete files on remote + create remote folders / type checks.
        let mut ops = Vec::new();
        for p in &plan.delete_remote {
            ops.push(Op::Remove(p.clone()));
        }
        for p in &plan.pushes {
            ops.push(Op::PushFile(p.clone()));
        }
        let mut prepare = Vec::new();
        prepare.push(format!("mkdir -p {}", jidr_adb::shell_quote(&self.remote)));
        prepare.extend(plan::prepare(&self.remote, &ops, &[]));
        for script in plan::scripts(&prepare, plan::SCRIPT_LIMIT) {
            let (code, out) = self.adb.shell_status(&script).await?;
            if code != 0 {
                return Err(JidrError::sdk(format!(
                    "preparing {} on the device failed: {}",
                    self.remote,
                    out.trim()
                )));
            }
        }
        for p in &plan.delete_remote {
            bidi.baseline.remove(p);
            bidi.remote_cache.remove(p);
            stats.removed += 1;
        }
        done += plan.delete_remote.len() as u64;
        if !plan.delete_remote.is_empty() {
            self.emit_progress(phase, done, total);
        }

        // 2. Push local files in batches.
        let batches = plan::file_batches(&self.root, &ops);
        for b in &batches {
            let dest = format!("{}/", plan::remote_path(&self.remote, &b.dir));
            for chunk in b.sources.chunks(plan::PUSH_CHUNK) {
                self.adb.push_many(chunk, &dest, false).await?;
                for src in chunk {
                    if let Ok(rel) = src.strip_prefix(&self.root)
                        && let Some(expected) = local_files.get(rel)
                    {
                        bidi.remote_cache.remove(rel);
                        // Advance baseline only if local file stayed unchanged during push.
                        if matches!(reconcile::local_file_stat(src), Ok(Some(st)) if st == expected.stat())
                        {
                            bidi.baseline
                                .insert(rel.to_path_buf(), expected.sha256.clone());
                        }
                    }
                }
            }
            stats.pushed += b.files;
            done += b.files;
            self.emit_progress(phase, done, total);
        }

        // 3. Delete local files (only if unchanged since scan).
        for rel in &plan.delete_local {
            let local_path = self.root.join(rel);
            let unchanged = local_files
                .get(rel)
                .is_some_and(|e| matches!(reconcile::local_file_stat(&local_path), Ok(Some(st)) if st == e.stat()));
            if !unchanged {
                continue;
            }
            match std::fs::remove_file(&local_path) {
                Ok(()) => {
                    bidi.baseline.remove(rel);
                    bidi.local_cache.remove(rel);
                    stats.removed_local += 1;
                }
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                    bidi.baseline.remove(rel);
                    bidi.local_cache.remove(rel);
                }
                Err(e) => {
                    return Err(JidrError::sdk(format!(
                        "removing {}: {e}",
                        local_path.display()
                    )));
                }
            }
            done += 1;
        }
        if !plan.delete_local.is_empty() {
            self.emit_progress(phase, done, total);
        }

        // 4. Pull remote files and verify each pulled hash against remote.
        for rel in &plan.pulls {
            let remote_entry = remote_files
                .get(rel)
                .ok_or_else(|| JidrError::unexpected("missing remote entry for pull"))?;
            self.pull_and_verify(rel, &remote_entry.sha256, bidi)
                .await?;
            stats.pulled += 1;
            done += 1;
            self.emit_progress(phase, done, total);
        }

        Ok(stats)
    }

    async fn pull_and_verify(
        &self,
        rel: &Path,
        expected_sha256: &str,
        bidi: &mut BidiState,
    ) -> JidrResult<()> {
        let local_path = self.root.join(rel);
        if let Some(parent) = local_path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| JidrError::sdk(format!("creating {}: {e}", parent.display())))?;
        }
        if let Ok(meta) = std::fs::symlink_metadata(&local_path)
            && meta.is_dir()
        {
            std::fs::remove_dir(&local_path).map_err(|e| {
                JidrError::sdk(format!(
                    "cannot replace non-empty folder {} with file: {e}",
                    local_path.display()
                ))
            })?;
        }
        let remote_file = plan::remote_path(&self.remote, rel);
        self.adb.pull(&remote_file, &local_path).await?;
        let path_for_hash = local_path.clone();
        let (stat, pulled_hash) = tokio::task::spawn_blocking(move || -> JidrResult<_> {
            let st = reconcile::local_file_stat(&path_for_hash)
                .map_err(|e| JidrError::sdk(format!("reading {}: {e}", path_for_hash.display())))?
                .ok_or_else(|| {
                    JidrError::sdk(format!(
                        "pulled file {} is missing",
                        path_for_hash.display()
                    ))
                })?;
            let hash = reconcile::hash_file(&path_for_hash)
                .map_err(|e| JidrError::sdk(format!("hashing {}: {e}", path_for_hash.display())))?;
            Ok((st, hash))
        })
        .await
        .map_err(|e| JidrError::unexpected(format!("verifying pull: {e}")))??;

        bidi.local_cache.insert(
            rel.to_path_buf(),
            FileEntry {
                size: stat.size,
                modified: stat.modified,
                sha256: pulled_hash.clone(),
            },
        );
        if pulled_hash == expected_sha256 {
            bidi.baseline.insert(rel.to_path_buf(), pulled_hash);
        }
        Ok(())
    }

    async fn resolve_conflict(
        &self,
        bidi: &mut BidiState,
        path: &Path,
        resolution: ConflictChoice,
    ) -> JidrResult<SyncInfo> {
        if !bidi.last_conflicts.iter().any(|c| c.path == path) {
            return Err(JidrError::not_found(format!(
                "{} has no active conflict",
                path.display()
            )));
        }

        let local_files = self.scan_local(&mut bidi.local_cache).await?;
        let remote_files = self.scan_remote(&mut bidi.remote_cache).await?;
        let local_entry = local_files.get(path);
        let remote_entry = remote_files.get(path);

        let mut stats = BidiStats::default();
        match (resolution, local_entry, remote_entry) {
            (ConflictChoice::KeepLocal, Some(le), _)
            | (ConflictChoice::KeepBoth, Some(le), None) => {
                self.push_single(path, &le.sha256, bidi).await?;
                stats.pushed = 1;
            }
            (ConflictChoice::KeepLocal, None, Some(_)) => {
                self.delete_remote_single(path, bidi).await?;
                stats.removed = 1;
            }
            (ConflictChoice::KeepRemote, _, Some(re))
            | (ConflictChoice::KeepBoth, None, Some(re)) => {
                self.pull_and_verify(path, &re.sha256, bidi).await?;
                stats.pulled = 1;
            }
            (ConflictChoice::KeepRemote, Some(_), None) => {
                self.delete_local_single(path, bidi)?;
                stats.removed_local = 1;
            }
            (ConflictChoice::KeepBoth, Some(le), Some(re)) => {
                let copy_rel =
                    reconcile::conflict_copy_rel(&self.root, path, Utc::now().timestamp());
                let src = self.root.join(path);
                let dst = self.root.join(&copy_rel);
                if let Some(parent) = dst.parent() {
                    std::fs::create_dir_all(parent).map_err(|e| {
                        JidrError::sdk(format!("creating {}: {e}", parent.display()))
                    })?;
                }
                std::fs::rename(&src, &dst)
                    .map_err(|e| JidrError::sdk(format!("renaming {}: {e}", src.display())))?;
                if let Some(moved_stat) = reconcile::local_file_stat(&dst)
                    .map_err(|e| JidrError::sdk(format!("reading {}: {e}", dst.display())))?
                {
                    bidi.local_cache.insert(
                        copy_rel.clone(),
                        FileEntry {
                            size: moved_stat.size,
                            modified: moved_stat.modified,
                            sha256: le.sha256.clone(),
                        },
                    );
                }
                self.push_single(&copy_rel, &le.sha256, bidi).await?;
                self.pull_and_verify(path, &re.sha256, bidi).await?;
                stats.pushed = 1;
                stats.pulled = 1;
            }
            (_, None, None) => {
                bidi.baseline.remove(path);
            }
        }

        let post_local = self
            .scan_local(&mut bidi.local_cache)
            .await
            .unwrap_or(local_files);
        let (files, bytes) = tree_totals(&post_local);
        bidi.last_local = post_local;
        let remaining: Vec<SyncConflict> = bidi
            .last_conflicts
            .iter()
            .filter(|c| c.path != path)
            .cloned()
            .collect();
        self.update_conflicts(bidi, remaining);
        self.finish_bidi(stats, files, bytes, stats.any());
        Ok(lock(&self.info).clone())
    }

    async fn push_single(&self, rel: &Path, sha256: &str, bidi: &mut BidiState) -> JidrResult<()> {
        let ops = vec![Op::PushFile(rel.to_path_buf())];
        let mut prepare = vec![format!("mkdir -p {}", jidr_adb::shell_quote(&self.remote))];
        prepare.extend(plan::prepare(&self.remote, &ops, &[]));
        for script in plan::scripts(&prepare, plan::SCRIPT_LIMIT) {
            let (code, out) = self.adb.shell_status(&script).await?;
            if code != 0 {
                return Err(JidrError::sdk(format!(
                    "preparing {} on the device failed: {}",
                    self.remote,
                    out.trim()
                )));
            }
        }
        let parent_dir = rel.parent().unwrap_or(Path::new(""));
        let dest = format!("{}/", plan::remote_path(&self.remote, parent_dir));
        self.adb
            .push_many(&[self.root.join(rel)], &dest, false)
            .await?;
        bidi.remote_cache.remove(rel);
        bidi.baseline.insert(rel.to_path_buf(), sha256.to_string());
        Ok(())
    }

    async fn delete_remote_single(&self, rel: &Path, bidi: &mut BidiState) -> JidrResult<()> {
        let cmd = format!(
            "rm -f {}",
            jidr_adb::shell_quote(&plan::remote_path(&self.remote, rel))
        );
        let (code, out) = self.adb.shell_status(&cmd).await?;
        if code != 0 {
            return Err(JidrError::sdk(format!(
                "removing {} on the device failed: {}",
                rel.display(),
                out.trim()
            )));
        }
        bidi.baseline.remove(rel);
        bidi.remote_cache.remove(rel);
        Ok(())
    }

    fn delete_local_single(&self, rel: &Path, bidi: &mut BidiState) -> JidrResult<()> {
        let local_path = self.root.join(rel);
        match std::fs::remove_file(&local_path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                return Err(JidrError::sdk(format!(
                    "removing {}: {e}",
                    local_path.display()
                )));
            }
        }
        bidi.baseline.remove(rel);
        bidi.local_cache.remove(rel);
        Ok(())
    }

    async fn ensure_remote_dir(&self) -> JidrResult<()> {
        let cmd = format!("mkdir -p {}", jidr_adb::shell_quote(&self.remote));
        let (code, out) = self.adb.shell_status(&cmd).await?;
        if code != 0 {
            return Err(JidrError::sdk(format!(
                "creating {} on the device failed: {}",
                self.remote,
                out.trim()
            )));
        }
        Ok(())
    }

    async fn scan_local(
        &self,
        cache: &mut HashMap<PathBuf, FileEntry>,
    ) -> JidrResult<BTreeMap<PathBuf, FileEntry>> {
        let root = self.root.clone();
        let ignore = self.ignore.clone();
        let max = self.max_files;
        let mut moved_cache = std::mem::take(cache);
        let (returned_cache, res) = tokio::task::spawn_blocking(move || {
            let res = reconcile::scan_local_with_cache(&root, &ignore, max, &mut moved_cache);
            (moved_cache, res)
        })
        .await
        .map_err(|e| JidrError::unexpected(format!("scanning local folder: {e}")))?;
        *cache = returned_cache;
        res
    }

    async fn scan_remote(
        &self,
        cache: &mut HashMap<PathBuf, FileEntry>,
    ) -> JidrResult<BTreeMap<PathBuf, FileEntry>> {
        let script = reconcile::build_remote_scan_script(&self.remote, &self.ignore);
        let (code, stdout) = self.adb.shell_status(&script).await?;
        if code != 0 {
            return Err(JidrError::sdk(format!(
                "scanning {} on the device failed: {}",
                self.remote,
                stdout.trim()
            )));
        }
        let stats = reconcile::parse_remote_scan_output(
            &self.remote,
            &stdout,
            &self.ignore,
            self.max_files,
        )?;
        let mut need_hash = Vec::new();
        for (rel, st) in &stats {
            let hit = cache
                .get(rel)
                .is_some_and(|c| c.size == st.size && c.modified == st.modified);
            if !hit {
                need_hash.push(plan::remote_path(&self.remote, rel));
            }
        }
        let mut fresh_hashes = HashMap::new();
        if !need_hash.is_empty() {
            let cmds = plan::pack("sha256sum", &need_hash, plan::SCRIPT_LIMIT / 2);
            for script in plan::scripts(&cmds, plan::SCRIPT_LIMIT) {
                let (code, out) = self.adb.shell_status(&script).await?;
                if code != 0 {
                    return Err(JidrError::sdk(format!(
                        "hashing files in {} on the device failed: {}",
                        self.remote,
                        out.trim()
                    )));
                }
                fresh_hashes.extend(reconcile::parse_sha256sum_output(&self.remote, &out)?);
            }
        }

        let mut out = BTreeMap::new();
        for (rel, st) in stats {
            let sha256 = if let Some(h) = fresh_hashes.remove(&rel) {
                h
            } else if let Some(c) = cache.get(&rel)
                && c.size == st.size
                && c.modified == st.modified
            {
                c.sha256.clone()
            } else {
                return Err(JidrError::sdk(format!(
                    "device did not return checksum for {}",
                    rel.display()
                )));
            };
            let entry = FileEntry {
                size: st.size,
                modified: st.modified,
                sha256,
            };
            cache.insert(rel.clone(), entry.clone());
            out.insert(rel, entry);
        }
        cache.retain(|k, _| out.contains_key(k));
        Ok(out)
    }

    fn update_conflicts(&self, bidi: &mut BidiState, conflicts: Vec<SyncConflict>) {
        if conflicts == bidi.last_conflicts {
            return;
        }
        bidi.last_conflicts = conflicts.clone();
        lock(&self.info).conflicts = conflicts.clone();
        if !conflicts.is_empty() {
            self.emit("file.sync.conflict", json!({ "conflicts": conflicts }));
        }
    }

    /// Adds an event's paths to the pending batch (a rescan request
    /// re-copies the whole folder).
    fn note(&self, ev: &notify::Event, pending: &mut Debouncer) {
        if matches!(ev.kind, notify::EventKind::Access(_)) {
            return;
        }
        let now = Instant::now();
        if ev.need_rescan() {
            pending.add(PathBuf::new(), now);
        }
        for path in &ev.paths {
            // The folder itself only counts through a rescan: re-copying
            // everything for its own metadata would be a waste.
            if let Ok(rel) = path.strip_prefix(&self.root)
                && !rel.as_os_str().is_empty()
                && !self.ignore.skips(rel)
            {
                pending.add(rel.to_path_buf(), now);
            }
        }
    }

    /// Mirrors a batch of changed paths → (files pushed, paths removed);
    /// `None` when there was nothing to do (a temporary file came and went).
    async fn apply(
        &self,
        changed: &BTreeSet<PathBuf>,
        known: &mut BTreeSet<PathBuf>,
    ) -> JidrResult<Option<(u64, u64)>> {
        let probes: HashMap<_, _> = changed
            .iter()
            .map(|p| (p.clone(), plan::probe(&self.root, p)))
            .collect();
        if probes.values().any(|p| *p == plan::Now::Unavailable) {
            return Err(JidrError::sdk("cannot inspect a changed path"));
        }
        let mut ops = plan::plan(changed, &self.ignore, |r| {
            probes.get(r).copied().unwrap_or(plan::Now::Unavailable)
        });
        // Delete only individual files previously copied by this sync. A
        // removed directory can contain device-only or ignored files.
        ops = ops
            .into_iter()
            .flat_map(|op| match op {
                Op::Remove(path) => known
                    .iter()
                    .filter(|p| p.starts_with(&path))
                    .cloned()
                    .map(Op::Remove)
                    .collect::<Vec<_>>(),
                other => vec![other],
            })
            .collect();
        if ops.is_empty() {
            return Ok(None);
        }
        self.set_state(SyncState::Syncing);
        let removed = ops.iter().filter(|o| matches!(o, Op::Remove(_))).count() as u64;
        let mut mkdirs = Vec::new();
        let mut scanned = BTreeSet::new();
        let mut batches = plan::file_batches(&self.root, &ops);
        for o in &ops {
            if let Op::PushDir(rel) = o {
                let (root, rel, ignore, max) = (
                    self.root.clone(),
                    rel.clone(),
                    self.ignore.clone(),
                    self.max_files,
                );
                let m = tokio::task::spawn_blocking(move || plan::scan(&root, &rel, &ignore, max))
                    .await
                    .map_err(|e| JidrError::unexpected(format!("scanning: {e}")))??;
                mkdirs.extend(m.mkdirs);
                scanned.extend(m.paths);
                // Do not use --sync here: a skipped, newer device file was
                // never copied by us and must not become a tracked deletion.
                batches.extend(m.batches);
            }
        }
        let prepare = plan::prepare(&self.remote, &ops, &mkdirs);
        let pushed = self.run_batches(&prepare, &batches, Phase::Change).await?;
        for op in &ops {
            match op {
                Op::Remove(p) => {
                    known.remove(p);
                }
                Op::PushFile(p) => {
                    known.insert(p.clone());
                }
                Op::PushDir(_) => {}
            }
        }
        known.extend(scanned);
        Ok(Some((pushed, removed)))
    }

    /// The first copy.
    async fn mirror(&self, m: &Mirror) -> JidrResult<u64> {
        let dirs: Vec<String> = m
            .mkdirs
            .iter()
            .map(|d| plan::remote_path(&self.remote, d))
            .collect();
        let commands = plan::pack("mkdir -p", &dirs, plan::SCRIPT_LIMIT / 2);
        self.run_batches(&commands, &m.batches, Phase::Mirror).await
    }

    /// Runs the shell commands, then the pushes, reporting progress.
    async fn run_batches(
        &self,
        commands: &[String],
        batches: &[Batch],
        phase: Phase,
    ) -> JidrResult<u64> {
        for script in plan::scripts(commands, plan::SCRIPT_LIMIT) {
            let (code, out) = self.adb.shell_status(&script).await?;
            if code != 0 {
                return Err(JidrError::sdk(format!(
                    "preparing {} on the device failed: {}",
                    self.remote,
                    out.trim()
                )));
            }
        }
        let total: u64 = batches.iter().map(|b| b.files).sum();
        let mut done = 0;
        for b in batches {
            let dest = format!("{}/", plan::remote_path(&self.remote, &b.dir));
            for chunk in b.sources.chunks(plan::PUSH_CHUNK) {
                self.adb.push_many(chunk, &dest, b.newer_only).await?;
            }
            done += b.files;
            self.emit_progress(phase, done, total);
        }
        Ok(done)
    }

    fn emit_progress(&self, phase: Phase, done: u64, total: u64) {
        self.emit(
            "file.sync.progress",
            json!({ "phase": phase, "done": done, "total": total }),
        );
    }

    fn set_state(&self, s: SyncState) {
        lock(&self.info).state = s;
    }

    fn finish_one_way(&self, result: JidrResult<(u64, u64)>) {
        match result {
            Ok((pushed, removed)) => {
                let mut info = lock(&self.info);
                info.state = SyncState::Watching;
                info.pushed += pushed;
                info.removed += removed;
                info.last_synced_at = Some(Utc::now());
                info.last_error = None;
                drop(info);
                self.emit(
                    "file.sync.synced",
                    json!({ "pushed": pushed, "removed": removed }),
                );
            }
            Err(e) => {
                self.set_state(SyncState::Watching);
                self.error(&e.message);
            }
        }
    }

    fn finish_bidi(&self, stats: BidiStats, files: u64, bytes: u64, emit_synced: bool) {
        let conflicts_len = {
            let mut info = lock(&self.info);
            info.state = SyncState::Watching;
            info.files = files;
            info.bytes = bytes;
            info.pushed += stats.pushed;
            info.pulled += stats.pulled;
            info.removed += stats.removed;
            info.removed_local += stats.removed_local;
            info.last_synced_at = Some(Utc::now());
            info.last_error = None;
            info.conflicts.len() as u64
        };
        if emit_synced {
            self.emit(
                "file.sync.synced",
                json!({
                    "pushed": stats.pushed,
                    "pulled": stats.pulled,
                    "removed": stats.removed,
                    "removed_local": stats.removed_local,
                    "conflicts": conflicts_len,
                }),
            );
        }
    }

    /// Reports a failure; the sync keeps watching.
    fn error(&self, message: &str) {
        tracing::warn!(sync = %self.id, "file.sync: {message}");
        lock(&self.info).last_error = Some(message.to_string());
        self.emit("file.sync.error", json!({ "error": message }));
    }

    fn emit(&self, topic: &str, mut data: Value) {
        if let Some(state) = self.state.upgrade() {
            data["id"] = json!(self.id);
            data["device"] = json!(self.device);
            state.emit(topic, data);
        }
    }

    /// Ends this sync from inside its task (the task isn't aborted: it
    /// returns right after).
    fn stop(&self, reason: StopReason) {
        let (Some(syncs), Some(state)) = (self.syncs.upgrade(), self.state.upgrade()) else {
            return;
        };
        if lock(&syncs).remove(&self.id).is_some() {
            state.emit(
                "file.sync.stopped",
                json!({ "id": self.id, "device": self.device, "reason": reason }),
            );
        }
    }
}

fn tree_totals(files: &BTreeMap<PathBuf, FileEntry>) -> (u64, u64) {
    let count = files.len() as u64;
    let bytes = files.values().map(|e| e.size).sum();
    (count, bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn device_folders_are_absolute_and_tidy() {
        let local = Path::new("/Users/me/My Site");
        assert_eq!(
            device_folder(None, local).unwrap(),
            "/sdcard/Download/My Site"
        );
        assert_eq!(
            device_folder(Some(" /sdcard/www/ "), local).unwrap(),
            "/sdcard/www"
        );
        for bad in [
            "sdcard/x",
            "/",
            "///",
            "/sdcard/../data",
            "/sdcard/./x",
            "/a\nb",
        ] {
            assert!(device_folder(Some(bad), local).is_err(), "{bad:?}");
        }
        assert!(device_folder(None, Path::new("/")).is_err());
    }

    #[test]
    fn overlapping_device_folders() {
        assert!(overlaps("/sdcard/a", "/sdcard/a"));
        assert!(overlaps("/sdcard/a", "/sdcard/a/b"));
        assert!(overlaps("/sdcard/a/b", "/sdcard/a"));
        assert!(!overlaps("/sdcard/a", "/sdcard/ab"));
        assert!(!overlaps("/sdcard/a", "/sdcard/b"));
    }

    #[test]
    fn host_folder_must_be_an_absolute_folder() {
        let t = tempfile::tempdir().unwrap();
        std::fs::write(t.path().join("f"), b"x").unwrap();
        assert!(host_folder(Path::new("relative")).is_err());
        assert!(host_folder(&t.path().join("f")).is_err());
        assert!(host_folder(&t.path().join("missing")).is_err());
        assert_eq!(
            host_folder(t.path()).unwrap(),
            std::fs::canonicalize(t.path()).unwrap()
        );
    }

    #[test]
    fn validate_rel_path_rejects_escape_and_empty() {
        assert!(validate_rel_path(Path::new("")).is_err());
        assert!(validate_rel_path(Path::new("/abs")).is_err());
        assert!(validate_rel_path(Path::new("../out")).is_err());
        assert_eq!(
            validate_rel_path(Path::new("sub/a.txt")).unwrap(),
            PathBuf::from("sub/a.txt")
        );
    }
}
