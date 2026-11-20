//! Private SwiftUI device-center bridge over the existing control protocol.

use anyhow::Result;
use miko_core::MikoPaths;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    io::{BufRead, Write},
    sync::Arc,
};
use tokio::sync::mpsc;

#[derive(Deserialize)]
struct Request {
    id: u64,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Default)]
struct LocalStateLocks {
    preferences: Arc<tokio::sync::Mutex<()>>,
    storage: Arc<tokio::sync::Mutex<()>>,
}

#[derive(Default)]
struct LogBatch {
    lines: VecDeque<String>,
    dropped: u64,
}

impl LogBatch {
    fn push(&mut self, line: String) {
        if self.lines.len() == 1000 {
            self.lines.pop_front();
            self.dropped += 1;
        }
        self.lines.push_back(line);
    }
}

/// A user-visible local failure with a stable code for the Swift client. Bridge
/// diagnostics stay English; the center UI can translate the code instead of
/// leaking a Chinese string into English mode.
#[derive(Debug)]
struct DiagnosticError {
    code: &'static str,
    message: std::borrow::Cow<'static, str>,
}

impl DiagnosticError {
    const fn new(code: &'static str, message: &'static str) -> Self {
        Self {
            code,
            message: std::borrow::Cow::Borrowed(message),
        }
    }

    fn with_detail(code: &'static str, message: String) -> Self {
        Self {
            code,
            message: std::borrow::Cow::Owned(message),
        }
    }
}

impl std::fmt::Display for DiagnosticError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for DiagnosticError {}

/// An error reply that carries the code for typed local failures and falls back
/// to the readable diagnostic chain for daemon and I/O errors.
fn error_reply(id: u64, error: &anyhow::Error) -> Value {
    match error.downcast_ref::<DiagnosticError>() {
        Some(diagnostic) => {
            json!({"id":id,"type":"error","code":diagnostic.code,"message":diagnostic.message})
        }
        None => json!({"id":id,"type":"error","message":format!("{error:#}")}),
    }
}

fn daemon_error_reply(id: u64, error: &miko_core::MikoError) -> Value {
    json!({"id":id,"type":"error","code":error.code.as_str(),"message":error.message,"data":error.data})
}

fn apply_gui_prefs_update(
    prefs: &mut serde_json::Map<String, Value>,
    params: &Value,
) -> Result<()> {
    for (field, max) in [("language", 1), ("appearance", 2)] {
        if let Some(value) = params.get(field) {
            let number = value.as_u64().filter(|n| *n <= max).ok_or_else(|| {
                DiagnosticError::new("prefs.invalid_setting", "The interface setting is invalid")
            })?;
            prefs.insert(field.into(), json!(number));
        }
    }
    if let Some(value) = params.get("tile_url") {
        let tile = value
            .as_str()
            .ok_or_else(|| anyhow::anyhow!("Invalid map tile URL"))?;
        if !tile.is_empty()
            && (tile.len() > 2048
                || !tile.starts_with("https://")
                || !["{z}", "{x}", "{y}"].iter().all(|v| tile.contains(v))
                || tile.contains('@')
                || tile.chars().any(char::is_whitespace))
        {
            anyhow::bail!("Map tile URL must use HTTPS and contain {{z}}, {{x}} and {{y}}");
        }
        prefs.insert("tile_url".into(), json!(tile));
    }
    if let Some(value) = params.get("record_audio") {
        let enabled = value.as_bool().ok_or_else(|| {
            DiagnosticError::new("prefs.invalid_setting", "The interface setting is invalid")
        })?;
        prefs.insert("record_audio".into(), json!(enabled));
    }
    Ok(())
}

fn classify_storage_io_error(error: std::io::Error) -> anyhow::Error {
    let text = error.to_string();
    let code = if text.contains("destination already exists") {
        "storage.destination_exists"
    } else if text.contains("source and destination must not overlap") {
        "storage.destination_overlap"
    } else if text.contains("insufficient destination space") {
        "storage.insufficient_space"
    } else if text.contains("qemu-img not found") {
        "storage.missing_qemu_img"
    } else if text.contains("AVD may still be running") || text.contains("AVD files are still open")
    {
        "storage.devices_active"
    } else if text.contains("snapshot") {
        "storage.incomplete_snapshot"
    } else if text.contains("symbolic link") {
        "storage.symlink_unsupported"
    } else {
        "storage.migration_failed"
    };
    DiagnosticError::with_detail(code, text).into()
}

struct StoragePreflight {
    source: MikoPaths,
    destination: std::path::PathBuf,
    estimate: miko_sdk::migration::SpaceEstimate,
    qemu_img: Option<std::path::PathBuf>,
}

fn check_storage_preflight(params: &Value) -> Result<StoragePreflight> {
    if std::env::var_os(miko_core::paths::MIKO_HOME_ENV).is_some_and(|v| !v.is_empty()) {
        return Err(DiagnosticError::new(
            "storage.env_override",
            "MIKO_HOME is set; unset MIKO_HOME before changing the data location",
        )
        .into());
    }
    let destination = params
        .get("destination")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(std::path::PathBuf::from)
        .ok_or_else(|| {
            DiagnosticError::new(
                "storage.invalid_destination",
                "The target data location is missing",
            )
        })?;
    let source = MikoPaths::discover()?;
    let (final_path, estimate) = miko_sdk::migration::validate_destination(&source, &destination)
        .map_err(classify_storage_io_error)?;
    let qemu_img = miko_sdk::migration::find_qemu_img(&source);
    if qemu_img.is_none()
        && miko_sdk::migration::contains_qcow_images(&source.data)
            .map_err(classify_storage_io_error)?
    {
        return Err(DiagnosticError::new(
            "storage.missing_qemu_img",
            "qemu-img was not found; install or configure an Android SDK before migrating device disks",
        )
        .into());
    }
    Ok(StoragePreflight {
        source,
        destination: final_path,
        estimate,
        qemu_img,
    })
}

fn acquire_storage_lease_with_retry(
    data: &std::path::Path,
) -> std::io::Result<miko_core::storage_lease::StorageLease> {
    let mut last = None;
    for _ in 0..20 {
        match miko_core::storage_lease::StorageLease::acquire(data) {
            Ok(lease) => return Ok(lease),
            Err(error) => {
                last = Some(error);
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
        }
    }
    Err(last.unwrap_or_else(|| std::io::Error::other("could not acquire source storage lease")))
}

/// Reads `gui-prefs.json`. A missing file is the defaults (an empty object);
/// malformed JSON or a non-object root is reported so the file is never
/// overwritten with a lossy rewrite.
fn read_gui_prefs(path: &std::path::Path) -> Result<serde_json::Map<String, Value>> {
    let prefs: Value = match std::fs::read(path) {
        Ok(data) => serde_json::from_slice(&data)?,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            Value::Object(serde_json::Map::new())
        }
        Err(error) => return Err(error.into()),
    };
    match prefs {
        Value::Object(object) => Ok(object),
        _ => Err(DiagnosticError::new(
            "prefs.invalid",
            "The preferences file is not a JSON object",
        )
        .into()),
    }
}

fn send(value: Value) {
    let mut output = std::io::stdout().lock();
    let _ = writeln!(output, "{value}");
    let _ = output.flush();
}

/// Fixed responses for the snapshot renderer. Only `MIKO_CENTER_FIXTURE` turns
/// this on: when it is unset the normal daemon path below is untouched.
fn fixture_case() -> Option<String> {
    std::env::var("MIKO_CENTER_FIXTURE")
        .ok()
        .map(|case| case.trim().to_owned())
        .filter(|case| !case.is_empty())
}

fn fixture_device(id: &str, name: &str, state: &str, api: i64, tag: &str) -> Value {
    json!({
        "root": {"mode": "none", "health": "ok"},
        "runtime": {"adb_serial": format!("emulator-{}", id.strip_prefix("fixture-").unwrap_or(id))},
        "profile": "pixel_7",
        "sdk_root": "/tmp/miko-fixture/sdk",
        "launch": {"audio": true, "quick_boot": true, "camera_back": "none", "camera_front": "none"},
        "auto_hibernate_minutes": 30,
        "id": id,
        "name": name,
        "status": {"state": state},
        "image": {"api": api, "tag": tag},
    })
}

fn fixture_devices(case: &str) -> Vec<Value> {
    match case {
        "disconnect" | "populated" => vec![
            fixture_device(
                "fixture-running",
                "Fixture Running Device",
                "running",
                35,
                "google_apis_playstore",
            ),
            fixture_device(
                "fixture-stopped",
                "Fixture Stopped Device",
                "stopped",
                33,
                "google_apis",
            ),
        ],
        "long-task" => vec![fixture_device(
            "fixture-long-task",
            "Fixture Long Task Device",
            "stopped",
            35,
            "google_apis",
        )],
        _ => Vec::new(),
    }
}

fn fixture_result(request: &Request, case: &str) -> Value {
    let id = request.id;
    let device = || {
        let id = request.params.get("device").and_then(Value::as_str);
        fixture_devices(case)
            .into_iter()
            .find(|entry| id.is_none_or(|wanted| entry["id"] == wanted))
            .unwrap_or_else(|| {
                fixture_device(
                    "fixture-running",
                    "Fixture Device",
                    "running",
                    35,
                    "google_apis",
                )
            })
    };
    match request.method.as_str() {
        "center.prefs.get" => {
            json!({"id":id,"type":"result","result":{"language":1,"appearance":0,"tile_url":"","record_audio":true}})
        }
        "center.paths" => json!({"id":id,"type":"result","result":{
            "data":"/tmp/miko-fixture/data","cache":"/tmp/miko-fixture/cache","logs":"/tmp/miko-fixture/logs"
        }}),
        "center.about" => json!({"id":id,"type":"result","result":{
            "version":env!("CARGO_PKG_VERSION"),"repository":"https://github.com/hbdzh/miko-simulator"
        }}),
        "center.quit" => json!({"id":id,"type":"result","result":null}),
        "device.list" => {
            if case == "load-failure" {
                json!({"id":id,"type":"error","message":"Unable to read devices: the daemon is not running (fixture: load-failure)"})
            } else {
                json!({"id":id,"type":"result","result":fixture_devices(case)})
            }
        }
        "device.details" => {
            let device = device();
            json!({"id":id,"type":"result","result":{
                "device": device,
                "config": {
                    "hw.cpu.ncore":"8",
                    "hw.ramSize":"4096",
                    "hw.lcd.width": if device["status"]["state"] == "running" { "1080" } else { "1600" },
                    "hw.lcd.height": if device["status"]["state"] == "running" { "2400" } else { "2560" },
                    "hw.lcd.density":"420"
                },
                "disk_usage": 2147483648u64
            }})
        }
        "app.list" => json!({"id":id,"type":"result","result":{"apps":[
            {"package":"com.fixture.sample","name":"Fixture Sample Game","icon":null}
        ]}}),
        "settings.get" => json!({"id":id,"type":"result","result":{
            "default_root_mode":"none","quick_boot":true,"budget_percent":80,"auto_hibernate_minutes":0
        }}),
        "profile.list" => json!({"id":id,"type":"result","result":[{
            "id":"fixture-phone","name":"Phone 6.1 FHD+","ram_mb":4096,"cpus":4,"data_mb":8192,"audio":true
        }]}),
        "image.list" => json!({"id":id,"type":"result","result":[{
            "api":35,"tag":"google_apis","abi":"arm64-v8a","installed_in":"/tmp/miko-fixture/sdk"
        }]}),
        "snapshot.list" => json!({"id":id,"type":"result","result":{"snapshots":[
            {"name":"fixture-snapshot","quick_boot":true,"restorable":true,"root_mode":null,"size_bytes":1048576u64}
        ]}}),
        "jobs.list" => {
            let result = if case == "long-task" {
                json!([{
                    "id":"fixture-long-task","kind":"device.start","device":"fixture-long-task",
                    "progress":0.6,"message":"Rebooting","bytes":null,"state":"running",
                    "error":null,"created_at":"2026-11-11T00:00:00Z"
                }])
            } else {
                json!([])
            };
            json!({"id":id,"type":"result","result":result})
        }
        _ => {
            json!({"id":id,"type":"error","message":format!("fixture case {case}: no response for {}", request.method)})
        }
    }
}

/// Serve the embedded fixture state instead of connecting to a daemon. The
/// `disconnect` case answers a few messages and then closes stdout.
async fn run_fixture(case: &str) -> Result<()> {
    if ![
        "empty",
        "populated",
        "load-failure",
        "long-task",
        "disconnect",
    ]
    .contains(&case)
    {
        anyhow::bail!(
            "unknown MIKO_CENTER_FIXTURE case {case:?}; expected empty, populated, load-failure, long-task or disconnect"
        );
    }
    let (tx, mut rx) = mpsc::channel::<String>(64);
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            if line.len() > 1024 * 1024 || tx.blocking_send(line).is_err() {
                break;
            }
        }
    });
    while let Some(line) = rx.recv().await {
        let Ok(request) = serde_json::from_str::<Request>(&line) else {
            continue;
        };
        if case == "long-task" && request.method == "device.start" {
            let id = request.id;
            tokio::spawn(async move {
                // English daemon diagnostics; OperationMessages translates
                // them for the Chinese UI, matching a real device.start job.
                for (fraction, message) in [(0.25, "Cold booting"), (0.6, "Rebooting")] {
                    tokio::time::sleep(std::time::Duration::from_millis(40)).await;
                    send(
                        json!({"id":id,"type":"progress","job":"fixture-long-task","message":message,"progress":fraction}),
                    );
                }
                // A long task deliberately never completes: the renderer captures
                // the UI while the operation is still in flight.
            });
            continue;
        }
        send(fixture_result(&request, case));
        if case == "disconnect" && request.method == "device.list" {
            tokio::time::sleep(std::time::Duration::from_millis(80)).await;
            return Ok(());
        }
    }
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if let Some(case) = fixture_case() {
        return run_fixture(&case).await;
    }
    let paths = MikoPaths::discover()?;
    if args.get(1).is_some_and(|arg| arg == "--logcat") {
        let device = args
            .get(2)
            .ok_or_else(|| anyhow::anyhow!("missing device"))?;
        let filters: Vec<String> = serde_json::from_str(
            args.get(3)
                .ok_or_else(|| anyhow::anyhow!("missing filters"))?,
        )?;
        return follow_logcat(&paths, device, filters).await;
    }
    let client = Arc::new(
        miko_client::Client::connect_or_spawn(
            &paths,
            "swiftui-center",
            &miko_client::SpawnOptions::default(),
        )
        .await?,
    );
    if let Ok(mut events) = client.subscribe(&["device.", "sync."]).await {
        tokio::spawn(async move {
            while let Ok(event) = events.recv().await {
                send(json!({"type":"device_event", "event":event}));
            }
        });
    }
    // Preferences and tool paths are separate files. An unavailable volume or
    // slow preference sync must not serialize unrelated tool-path requests.
    let locks = LocalStateLocks::default();
    let (tx, mut rx) = mpsc::channel::<String>(64);
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            if line.len() > 1024 * 1024 || tx.blocking_send(line).is_err() {
                break;
            }
        }
    });
    while let Some(line) = rx.recv().await {
        let Ok(request) = serde_json::from_str::<Request>(&line) else {
            continue;
        };
        let client = Arc::clone(&client);
        let prefs_lock = Arc::clone(&locks.preferences);
        let storage_lock = Arc::clone(&locks.storage);
        tokio::spawn(async move {
            let id = request.id;
            if request.method == "center.about" {
                send(json!({"id":id,"type":"result","result":{
                    "version":env!("CARGO_PKG_VERSION"),
                    "repository":"https://github.com/hbdzh/miko-simulator"
                }}));
                return;
            }
            if request.method == "center.prefs.get" || request.method == "center.prefs.set" {
                let _guard = prefs_lock.lock().await;
                let result = (|| -> anyhow::Result<Value> {
                    let paths = MikoPaths::discover()?;
                    let path = paths.data.join("gui-prefs.json");
                    let mut prefs = read_gui_prefs(&path)?;
                    if request.method == "center.prefs.set" {
                        apply_gui_prefs_update(&mut prefs, &request.params)?;
                        if !paths.data.is_dir() {
                            return Err(DiagnosticError::new(
                                "prefs.data_unavailable",
                                "The data directory is unavailable",
                            )
                            .into());
                        }
                        let temp = paths
                            .data
                            .join(format!(".swiftui-prefs-{}-{id}.tmp", std::process::id()));
                        let result = (|| -> std::io::Result<()> {
                            let mut file = std::fs::OpenOptions::new()
                                .write(true)
                                .create_new(true)
                                .open(&temp)?;
                            serde_json::to_writer_pretty(&mut file, &prefs)?;
                            file.write_all(b"\n")?;
                            file.sync_all()?;
                            std::fs::rename(&temp, &path)?;
                            std::fs::File::open(&paths.data)?.sync_all()
                        })();
                        if result.is_err() {
                            let _ = std::fs::remove_file(&temp);
                        }
                        result?;
                    }
                    Ok(Value::Object(prefs))
                })();
                match result {
                    Ok(value) => send(json!({"id":id,"type":"result","result":value})),
                    Err(error) => send(error_reply(id, &error)),
                }
                return;
            }
            if request.method == "center.paths" {
                match MikoPaths::discover() {
                    Ok(paths) => send(json!({"id":id,"type":"result","result":{
                        "data":paths.data, "cache":paths.cache, "logs":paths.logs
                    }})),
                    Err(error) => send(error_reply(id, &error.into())),
                }
                return;
            }
            if request.method == "center.quit" {
                let pid = client.daemon().pid;
                let result = client.call("daemon.quit", json!({})).await;
                match result {
                    Ok(_) => {
                        let mut exited = false;
                        for _ in 0..100 {
                            if !miko_sdk::avd::process_alive(pid) {
                                exited = true;
                                break;
                            }
                            tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                        }
                        if exited {
                            send(json!({"id":id,"type":"result","result":null}));
                        } else {
                            send(
                                json!({"id":id,"type":"error","code":"quit.timeout","message":"The background process did not exit cleanly"}),
                            );
                        }
                    }
                    Err(error) => send(daemon_error_reply(id, &error)),
                }
                return;
            }
            if request.method == "center.storage.estimate" {
                let params = request.params;
                let result = tokio::task::spawn_blocking(move || check_storage_preflight(&params))
                    .await
                    .map_err(|e| anyhow::anyhow!("storage preflight failed: {e}"))
                    .and_then(|res| res);
                match result {
                    Ok(pre) => send(json!({
                        "id": id,
                        "type": "result",
                        "result": {
                            "source_data": pre.source.data,
                            "destination": pre.destination,
                            "source_bytes": pre.estimate.source_bytes,
                            "required_bytes": pre.estimate.required_bytes,
                            "available_bytes": pre.estimate.available_bytes,
                        }
                    })),
                    Err(error) => send(error_reply(id, &error)),
                }
                return;
            }
            if request.method == "center.storage.migrate" {
                let _guard = storage_lock.lock().await;
                let params = request.params;
                let pre =
                    match tokio::task::spawn_blocking(move || check_storage_preflight(&params))
                        .await
                        .map_err(|e| anyhow::anyhow!("storage preflight failed: {e}"))
                        .and_then(|res| res)
                    {
                        Ok(pre) => pre,
                        Err(error) => {
                            send(error_reply(id, &error));
                            return;
                        }
                    };
                send(json!({
                    "id": id,
                    "type": "progress",
                    "job": null,
                    "message": "Stopping background service",
                    "progress": 0.1
                }));
                let pid = client.daemon().pid;
                if let Err(error) = client.call("daemon.quit", json!({})).await {
                    send(daemon_error_reply(id, &error));
                    return;
                }
                let mut exited = false;
                for _ in 0..150 {
                    if !miko_sdk::avd::process_alive(pid) {
                        exited = true;
                        break;
                    }
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                }
                if !exited {
                    send(error_reply(
                        id,
                        &anyhow::Error::new(DiagnosticError::new(
                            "storage.quit_timeout",
                            "The background process did not exit cleanly",
                        )),
                    ));
                    return;
                }
                send(json!({
                    "id": id,
                    "type": "progress",
                    "job": null,
                    "message": "Copying and verifying device data",
                    "progress": 0.35
                }));
                let result = tokio::task::spawn_blocking(move || -> Result<Value> {
                    let lease = acquire_storage_lease_with_retry(&pre.source.data)
                        .map_err(classify_storage_io_error)?;
                    miko_sdk::migration::ensure_avds_quiescent(&pre.source)
                        .map_err(classify_storage_io_error)?;
                    let socket_path = pre.source.socket();
                    for _ in 0..10 {
                        if !socket_path.exists() {
                            break;
                        }
                        std::thread::sleep(std::time::Duration::from_millis(50));
                    }
                    let barrier =
                        miko_sdk::legacy_barrier::LegacySocketBarrier::acquire(&socket_path)
                            .map_err(classify_storage_io_error)?;
                    let prepared = miko_sdk::migration::prepare_copy_flexible(
                        &pre.source,
                        &pre.destination,
                        pre.qemu_img.as_deref(),
                        &lease,
                        &barrier,
                    )
                    .map_err(classify_storage_io_error)?;
                    send(json!({
                        "id": id,
                        "type": "progress",
                        "job": null,
                        "message": "Switching data location",
                        "progress": 0.85
                    }));
                    let location =
                        miko_sdk::migration::publish_copy(&prepared, &pre.source, &lease, &barrier)
                            .map_err(classify_storage_io_error)?;
                    let pointer = miko_core::paths::default_location_file()?;
                    miko_core::paths::write_location_file(&pointer, &location)?;
                    drop(barrier);
                    drop(lease);
                    send(json!({
                        "id": id,
                        "type": "progress",
                        "job": null,
                        "message": "Cleaning up previous data",
                        "progress": 0.95
                    }));
                    let cleanup_error = miko_sdk::migration::cleanup_source_after_activation(
                        &pre.source,
                        &location,
                        &pointer,
                    )
                    .err()
                    .map(|error| error.to_string());
                    let next_paths = MikoPaths::under(&location.root);
                    Ok(json!({
                        "root": location.root,
                        "data": next_paths.data,
                        "cache": next_paths.cache,
                        "logs": next_paths.logs,
                        "previous_data": pre.source.data,
                        "files": prepared.data.files,
                        "bytes": prepared.data.bytes,
                        "qcow_disks": prepared.qcow_disks,
                        "source_cleaned": cleanup_error.is_none(),
                        "cleanup_error": cleanup_error,
                    }))
                })
                .await
                .map_err(|e| anyhow::anyhow!("storage migration failed: {e}"))
                .and_then(|res| res);
                match result {
                    Ok(value) => send(json!({"id": id, "type": "result", "result": value})),
                    Err(error) => send(error_reply(id, &error)),
                }
                return;
            }
            let report_start = request.method == "device.start";
            let result = client.run_with_started(&request.method, request.params, |job| {
                if report_start {
                    send(json!({"id":id,"type":"progress","job":job,"message":"","progress":null}));
                }
            }, |job| {
                send(json!({"id":id,"type":"progress","job":job.id,"message":job.message,"progress":job.progress}));
            }).await;
            match result {
                Ok(value) => send(json!({"id":id,"type":"result","result":value})),
                Err(error) => send(daemon_error_reply(id, &error)),
            }
        });
    }
    Ok(())
}

async fn follow_logcat(paths: &MikoPaths, device: &str, filters: Vec<String>) -> Result<()> {
    let client = miko_client::Client::connect(&paths.socket(), "swiftui-logcat").await?;
    let mut events = client.events();
    client
        .call("logcat.follow", json!({"device":device,"filter":filters}))
        .await?;
    send(json!({"type":"ready"}));
    let mut batch = LogBatch::default();
    let mut tick = tokio::time::interval(std::time::Duration::from_millis(250));
    loop {
        tokio::select! {
            event = events.recv() => match event {
                Ok(event) if event.topic == "logcat" => {
                    if let Some(line) = event.data.get("line").and_then(Value::as_str) {
                        batch.push(line.to_owned());
                    }
                }
                Ok(_) => {}
                Err(tokio::sync::broadcast::error::RecvError::Lagged(count)) => {
                    send(json!({"type":"dropped","count":count}));
                }
                Err(_) => break,
            },
            _ = tick.tick() => {
                if batch.dropped > 0 { send(json!({"type":"dropped","count":std::mem::take(&mut batch.dropped)})); }
                if !batch.lines.is_empty() { send(json!({"type":"lines","lines":std::mem::take(&mut batch.lines)})); }
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn daemon_error_keeps_code_and_budget_details() {
        let error = miko_core::MikoError::resource_exhausted("full")
            .with_data(json!({"needed_mb": 4096, "used_mb": 8192, "budget_mb": 12288}));
        let reply = daemon_error_reply(7, &error);
        assert_eq!(reply["code"], "resource_exhausted");
        assert_eq!(reply["data"]["needed_mb"], 4096);
        assert_eq!(reply["message"], "full");
    }

    #[test]
    fn daemon_error_keeps_snapshot_failure_marker() {
        let error = miko_core::MikoError::sdk("save failed")
            .with_data(json!({"operation": "quick_boot_save"}));
        let reply = daemon_error_reply(8, &error);
        assert_eq!(reply["code"], "sdk");
        assert_eq!(reply["data"]["operation"], "quick_boot_save");
    }

    /// Old Slint/pre-M2 `gui-prefs.json` is still a JSON object with these
    /// fields; a missing file means defaults and a corrupt file is reported
    /// instead of being rewritten.
    #[test]
    fn legacy_gui_prefs_are_read_and_corrupt_files_are_kept() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("gui-prefs.json");
        assert!(read_gui_prefs(&path).unwrap().is_empty());

        let legacy = br#"{"language":1,"appearance":0,"tile_url":""}"#;
        std::fs::write(&path, legacy).unwrap();
        let prefs = read_gui_prefs(&path).unwrap();
        assert_eq!(prefs.get("language"), Some(&json!(1)));
        assert_eq!(prefs.get("appearance"), Some(&json!(0)));
        assert_eq!(prefs.get("record_audio"), None);
        assert_eq!(std::fs::read(&path).unwrap(), legacy);

        let corrupt = b"{ not json";
        std::fs::write(&path, corrupt).unwrap();
        assert!(read_gui_prefs(&path).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), corrupt);

        std::fs::write(&path, b"[1,2,3]").unwrap();
        let error = read_gui_prefs(&path).unwrap_err();
        assert_eq!(
            error
                .downcast_ref::<DiagnosticError>()
                .map(|entry| entry.code),
            Some("prefs.invalid")
        );
        let reply = error_reply(7, &error);
        assert_eq!(reply["id"], 7);
        assert_eq!(reply["type"], "error");
        assert_eq!(reply["code"], "prefs.invalid");
        assert_eq!(
            reply["message"],
            "The preferences file is not a JSON object"
        );
    }

    /// The center UI maps codes; the bridge must never ship Chinese UI text.
    #[test]
    fn local_diagnostics_use_ascii_codes_and_english() {
        for diagnostic in [
            DiagnosticError::new("prefs.invalid", "x"),
            DiagnosticError::new("prefs.invalid_setting", "x"),
            DiagnosticError::new("prefs.data_unavailable", "x"),
            DiagnosticError::new("toolpath.missing_kind", "x"),
            DiagnosticError::new("toolpath.missing_path", "x"),
            DiagnosticError::new("toolpath.unknown_kind", "x"),
        ] {
            assert!(diagnostic.code.is_ascii() && diagnostic.code.contains('.'));
            assert!(diagnostic.message.is_ascii());
        }
        let (code, message) = (
            "quit.timeout",
            "The background process did not exit cleanly",
        );
        assert!(code.is_ascii() && code.contains('.'));
        assert!(message.is_ascii());
    }

    #[tokio::test]
    async fn preferences_do_not_block_storage() {
        let locks = LocalStateLocks::default();
        let _preference_write = locks.preferences.lock().await;
        assert!(locks.storage.try_lock().is_ok());
        assert!(locks.preferences.try_lock().is_err());
    }

    #[test]
    fn log_batch_stays_bounded_and_keeps_latest_lines() {
        let mut batch = super::LogBatch::default();
        for n in 0..1002 {
            batch.push(n.to_string());
        }
        assert_eq!(batch.lines.len(), 1000);
        assert_eq!(batch.lines.front().map(String::as_str), Some("2"));
        assert_eq!(batch.dropped, 2);
    }

    #[test]
    fn record_audio_preference_requires_bool() {
        let mut prefs = serde_json::Map::new();
        super::apply_gui_prefs_update(&mut prefs, &json!({"record_audio": false})).unwrap();
        assert_eq!(prefs.get("record_audio"), Some(&json!(false)));
        super::apply_gui_prefs_update(&mut prefs, &json!({"record_audio": true})).unwrap();
        assert_eq!(prefs.get("record_audio"), Some(&json!(true)));

        let err =
            super::apply_gui_prefs_update(&mut prefs, &json!({"record_audio": "no"})).unwrap_err();
        assert_eq!(
            err.downcast_ref::<DiagnosticError>()
                .map(|entry| entry.code),
            Some("prefs.invalid_setting")
        );
    }

    #[test]
    fn storage_errors_classify_cleanly() {
        for (raw, expected) in [
            ("destination already exists", "storage.destination_exists"),
            (
                "source and destination must not overlap",
                "storage.destination_overlap",
            ),
            (
                "insufficient destination space: need 10 bytes, have 5 bytes",
                "storage.insufficient_space",
            ),
            ("qemu-img not found", "storage.missing_qemu_img"),
            (
                "AVD may still be running: /tmp/a.avd",
                "storage.devices_active",
            ),
        ] {
            let err = super::classify_storage_io_error(std::io::Error::other(raw));
            assert_eq!(
                err.downcast_ref::<DiagnosticError>().map(|e| e.code),
                Some(expected)
            );
        }
    }
}
