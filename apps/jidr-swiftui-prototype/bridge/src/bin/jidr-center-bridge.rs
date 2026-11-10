//! Private SwiftUI device-center bridge over the existing control protocol.
#[path = "jidr_center/migration_preflight.rs"]
mod migration_preflight;

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
            "tools":{"android_sdk":null,"jdk_home":null}
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
                for (fraction, message) in [
                    (0.25, "Preparing to start the device…"),
                    (0.6, "Starting the device…"),
                ] {
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
                    let mut prefs: Value = match std::fs::read(&path) {
                        Ok(data) => serde_json::from_slice(&data)?,
                        Err(error) if error.kind() == std::io::ErrorKind::NotFound => json!({}),
                        Err(error) => return Err(error.into()),
                    };
                    let object = prefs
                        .as_object_mut()
                        .ok_or_else(|| anyhow::anyhow!("偏好设置格式错误"))?;
                    if request.method == "center.prefs.set" {
                        for (field, max) in [("language", 1), ("appearance", 2)] {
                            if let Some(value) = request.params.get(field) {
                                let number = value
                                    .as_u64()
                                    .filter(|n| *n <= max)
                                    .ok_or_else(|| anyhow::anyhow!("无效的界面设置"))?;
                                object.insert(field.into(), json!(number));
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
                            object.insert("tile_url".into(), json!(tile));
                        }
                        if !paths.data.is_dir() {
                            anyhow::bail!("数据目录不可用");
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
                    Ok(prefs)
                })();
                match result {
                    Ok(value) => send(json!({"id":id,"type":"result","result":value})),
                    Err(error) => {
                        send(json!({"id":id,"type":"error","message":format!("{error:#}")}))
                    }
                }
                return;
            }
            if request.method == "center.migration.preflight" {
                let parent = request
                    .params
                    .get("parent")
                    .and_then(Value::as_str)
                    .map(std::path::PathBuf::from);
                let sdk = request
                    .params
                    .get("sdk")
                    .and_then(Value::as_str)
                    .map(std::path::PathBuf::from);
                let result = tokio::task::spawn_blocking(move || -> anyhow::Result<Value> {
                    let paths = JidrPaths::discover()?;
                    let parent = parent.ok_or_else(|| anyhow::anyhow!("missing destination"))?;
                    let sdk = sdk.ok_or_else(|| anyhow::anyhow!("missing SDK path"))?;
                    let result = migration_preflight::check(&paths, &parent, &sdk)?;
                    Ok(json!({"target":result.target,"source_bytes":result.space.source_bytes,"required_bytes":result.space.required_bytes,"available_bytes":result.space.available_bytes,"incomplete_snapshots":result.incomplete_snapshots}))
                }).await;
                match result {
                    Ok(Ok(value)) => send(json!({"id":id,"type":"result","result":value})),
                    Ok(Err(error)) => {
                        send(json!({"id":id,"type":"error","message":format!("{error:#}")}))
                    }
                    Err(error) => send(
                        json!({"id":id,"type":"error","message":format!("preflight worker failed: {error}")}),
                    ),
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
                            .ok_or_else(|| anyhow::anyhow!("缺少工具类型"))?;
                        let selected = match request.params.get("path") {
                            Some(Value::String(p)) => Some(std::path::PathBuf::from(p)),
                            Some(Value::Null) => None,
                            _ => anyhow::bail!("缺少路径"),
                        };
                        match kind {
                            "sdk" => tools.android_sdk = selected,
                            "jdk" => {
                                tools.jdk_home = selected.map(|p| {
                                    if p.join("Contents/Home/bin/java").is_file() {
                                        p.join("Contents/Home")
                                    } else {
                                        p
                                    }
                                })
                            }
                            _ => anyhow::bail!("未知工具类型"),
                        }
                        tools.save(&paths)?;
                    }
                    Ok(
                        json!({"data":paths.data,"cache":paths.cache,"logs":paths.logs,"tools":tools}),
                    )
                })();
                match result {
                    Ok(value) => send(json!({"id":id,"type":"result","result":value})),
                    Err(error) => {
                        send(json!({"id":id,"type":"error","message":format!("{error:#}")}))
                    }
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
                            send(json!({"id":id,"type":"error","message":"后台进程没有正常退出"}));
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
    use super::LocalStateLocks;

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
