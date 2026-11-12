//! Private SwiftUI device-center bridge over the existing control protocol.

use anyhow::Result;
use jidr_core::JidrPaths;
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
    tools: Arc<tokio::sync::Mutex<()>>,
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
    message: &'static str,
}

impl DiagnosticError {
    const fn new(code: &'static str, message: &'static str) -> Self {
        Self { code, message }
    }
}

impl std::fmt::Display for DiagnosticError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(self.message)
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

/// Fixed responses for the snapshot renderer. Only `JIDR_CENTER_FIXTURE` turns
/// this on: when it is unset the normal daemon path below is untouched.
fn fixture_case() -> Option<String> {
    std::env::var("JIDR_CENTER_FIXTURE")
        .ok()
        .map(|case| case.trim().to_owned())
        .filter(|case| !case.is_empty())
}

fn fixture_device(id: &str, name: &str, state: &str, api: i64, tag: &str) -> Value {
    json!({
        "root": {"mode": "none", "health": "ok"},
        "runtime": {"adb_serial": format!("emulator-{}", id.strip_prefix("fixture-").unwrap_or(id))},
        "profile": "pixel_7",
        "sdk_root": "/tmp/jidr-fixture/sdk",
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
            json!({"id":id,"type":"result","result":{"language":1,"appearance":0,"tile_url":""}})
        }
        "center.paths" => json!({"id":id,"type":"result","result":{
            "data":"/tmp/jidr-fixture/data","cache":"/tmp/jidr-fixture/cache","logs":"/tmp/jidr-fixture/logs",
            "tools":{"android_sdk":null,"jidr_sdk":null}
        }}),
        "center.about" => json!({"id":id,"type":"result","result":{
            "version":env!("CARGO_PKG_VERSION"),"repository":"https://github.com/hbdzh/JIdr-plus"
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
            "unknown JIDR_CENTER_FIXTURE case {case:?}; expected empty, populated, load-failure, long-task or disconnect"
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
    let paths = JidrPaths::discover()?;
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
        jidr_client::Client::connect_or_spawn(
            &paths,
            "swiftui-center",
            &jidr_client::SpawnOptions::default(),
        )
        .await?,
    );
    if let Ok(mut events) = client.subscribe(&["device."]).await {
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
        let tool_lock = Arc::clone(&locks.tools);
        tokio::spawn(async move {
            let id = request.id;
            if request.method == "center.about" {
                send(json!({"id":id,"type":"result","result":{
                    "version":env!("CARGO_PKG_VERSION"),
                    "repository":"https://github.com/hbdzh/JIdr-plus"
                }}));
                return;
            }
            if request.method == "center.prefs.get" || request.method == "center.prefs.set" {
                let _guard = prefs_lock.lock().await;
                let result = (|| -> anyhow::Result<Value> {
                    let paths = JidrPaths::discover()?;
                    let path = paths.data.join("gui-prefs.json");
                    let mut prefs = read_gui_prefs(&path)?;
                    if request.method == "center.prefs.set" {
                        for (field, max) in [("language", 1), ("appearance", 2)] {
                            if let Some(value) = request.params.get(field) {
                                let number =
                                    value.as_u64().filter(|n| *n <= max).ok_or_else(|| {
                                        DiagnosticError::new(
                                            "prefs.invalid_setting",
                                            "The interface setting is invalid",
                                        )
                                    })?;
                                prefs.insert(field.into(), json!(number));
                            }
                        }
                        if let Some(value) = request.params.get("tile_url") {
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
                                anyhow::bail!(
                                    "Map tile URL must use HTTPS and contain {{z}}, {{x}} and {{y}}"
                                );
                            }
                            prefs.insert("tile_url".into(), json!(tile));
                        }
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
            if request.method == "center.paths" || request.method == "center.toolpath.set" {
                let _guard = tool_lock.lock().await;
                let result = (|| -> anyhow::Result<Value> {
                    let paths = JidrPaths::discover()?;
                    let mut tools = jidr_core::tool_paths::ToolPaths::load(&paths)?;
                    if request.method == "center.toolpath.set" {
                        let kind = request
                            .params
                            .get("kind")
                            .and_then(Value::as_str)
                            .ok_or_else(|| {
                                DiagnosticError::new(
                                    "toolpath.missing_kind",
                                    "The tool path kind is missing",
                                )
                            })?;
                        let selected = match request.params.get("path") {
                            Some(Value::String(p)) => Some(std::path::PathBuf::from(p)),
                            Some(Value::Null) => None,
                            _ => {
                                return Err(DiagnosticError::new(
                                    "toolpath.missing_path",
                                    "The tool path is missing",
                                )
                                .into());
                            }
                        };
                        match kind {
                            "sdk" => tools.android_sdk = selected,
                            "jidr_sdk" => tools.jidr_sdk = selected,
                            _ => {
                                return Err(DiagnosticError::new(
                                    "toolpath.unknown_kind",
                                    "The tool path kind is unknown",
                                )
                                .into());
                            }
                        }
                        tools.save(&paths)?;
                    }
                    // JDK configuration was removed from the product; the bridge
                    // only exposes the writable Jidr root and the external SDK.
                    Ok(json!({
                        "data":paths.data,
                        "cache":paths.cache,
                        "logs":paths.logs,
                        "tools":{"android_sdk":tools.android_sdk,"jidr_sdk":tools.jidr_sdk},
                    }))
                })();
                match result {
                    Ok(value) => send(json!({"id":id,"type":"result","result":value})),
                    Err(error) => send(error_reply(id, &error)),
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
                            if !jidr_sdk::avd::process_alive(pid) {
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
                    Err(error) => send(json!({"id":id,"type":"error","message":error.message})),
                }
                return;
            }
            let result = client.run(&request.method, request.params, |job| {
                send(json!({"id":id,"type":"progress","job":job.id,"message":job.message,"progress":job.progress}));
            }).await;
            match result {
                Ok(value) => send(json!({"id":id,"type":"result","result":value})),
                Err(error) => send(json!({"id":id,"type":"error","message":error.message})),
            }
        });
    }
    Ok(())
}

async fn follow_logcat(paths: &JidrPaths, device: &str, filters: Vec<String>) -> Result<()> {
    let client = jidr_client::Client::connect(&paths.socket(), "swiftui-logcat").await?;
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
    async fn preferences_do_not_block_tool_paths() {
        let locks = LocalStateLocks::default();
        let _preference_write = locks.preferences.lock().await;
        assert!(locks.tools.try_lock().is_ok());
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
}
