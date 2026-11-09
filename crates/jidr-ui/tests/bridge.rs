//! The GUI's daemon bridge against an in-process daemon: initial load,
//! event-driven reload, and reconnect after the daemon goes away.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::sync::mpsc;
use std::time::{Duration, Instant};

use jidr_client::{Client, SpawnOptions};
use jidr_daemon::testing::TestDaemon;
use jidr_ui::bridge::{Bridge, Conn, Update};
use serde_json::json;

#[test]
fn device_list_appears_before_slow_sdk_and_details() {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    let tmp = tempfile::tempdir().unwrap();
    let paths = jidr_core::JidrPaths::under(tmp.path());
    std::fs::create_dir_all(&paths.data).unwrap();
    let rt = tokio::runtime::Runtime::new().unwrap();
    let listener = rt.block_on(async { tokio::net::UnixListener::bind(paths.socket()).unwrap() });
    let device = jidr_ui::fixtures::device_infos().remove(0).device;
    let server = rt.spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (reader, writer) = stream.into_split();
        let writer = std::sync::Arc::new(tokio::sync::Mutex::new(writer));
        let mut lines = BufReader::new(reader).lines();
        while let Some(line) = lines.next_line().await.unwrap() {
            let request: serde_json::Value = serde_json::from_str(&line).unwrap();
            let id = request["id"].clone();
            let method = request["method"].as_str().unwrap();
            let (result, delay) = match method {
                "hello" => (json!({"version":jidr_client::VERSION,"protocol":"0.1","pid":1}), 0),
                "events.subscribe" => (json!({}), 0),
                "device.list" => (json!([device]), 0),
                "jobs.list" => (json!([]), 0),
                "sdk.status" => (json!({"tools_sdk":"/sdk","installed_images":[]}), 2500),
                "profile.list" => (json!([]), 0),
                "device.details" => (json!({"config":{"hw.lcd.width":"1080","hw.lcd.height":"2400","hw.lcd.density":"320","hw.ramSize":"4096","hw.cpu.ncore":"4"},"disk_usage":42}), 300),
                "daemon.status" => (json!({}), 0),
                other => panic!("unexpected {other}"),
            };
            let writer = writer.clone();
            tokio::spawn(async move {
                if delay > 0 { tokio::time::sleep(Duration::from_millis(delay)).await; }
                let line = format!("{}\n", json!({"jsonrpc":"2.0","id":id,"result":result}));
                writer.lock().await.write_all(line.as_bytes()).await.unwrap();
            });
        }
    });
    let (tx, rx) = mpsc::channel();
    let bridge = Bridge::new().unwrap();
    bridge.connect_with(
        paths,
        SpawnOptions {
            program: Some("/nonexistent/jidr".into()),
            ..Default::default()
        },
        move |u| {
            let _ = tx.send(u);
        },
    );
    let started = Instant::now();
    loop {
        let update = rx
            .recv_timeout(Duration::from_secs(1))
            .expect("initial device list");
        if let Update::Data(data) = update {
            assert_eq!(data.devices.len(), 1);
            assert_eq!(
                data.devices[0].width, 0,
                "unknown details must not be guessed"
            );
            assert!(started.elapsed() < Duration::from_secs(1));
            println!("initial device list: {:?}", started.elapsed());
            break;
        }
    }
    wait_for(
        &rx,
        "loaded details",
        |u| matches!(u, Update::Data(d) if d.devices.first().is_some_and(|i| i.width == 1080 && i.disk_bytes == Some(42))),
    );
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "details should not wait for SDK detection"
    );
    println!("device details: {:?}; SDK delayed 2.5s", started.elapsed());
    server.abort();
}

fn wait_for(rx: &mpsc::Receiver<Update>, what: &str, f: impl Fn(&Update) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if let Ok(u) = rx.recv_timeout(Duration::from_millis(200))
            && f(&u)
        {
            return;
        }
    }
    panic!("timed out waiting for {what}");
}

#[test]
fn loads_follows_events_and_reconnects() {
    let tmp = tempfile::tempdir().unwrap();
    let rt = tokio::runtime::Runtime::new().unwrap();
    let td = rt.block_on(TestDaemon::start(tmp.path())).unwrap();
    let paths = td.paths.clone();

    let (tx, rx) = mpsc::channel();
    let bridge = Bridge::new().unwrap();
    let no_spawn = SpawnOptions {
        program: Some("/nonexistent/jidr".into()),
        timeout: Some(Duration::from_millis(200)),
        ..Default::default()
    };
    bridge.connect_with(paths.clone(), no_spawn, move |u| {
        let _ = tx.send(u);
    });

    wait_for(&rx, "online", |u| matches!(u, Update::Conn(Conn::Online)));
    wait_for(
        &rx,
        "empty device list",
        |u| matches!(u, Update::Data(d) if d.devices.is_empty()),
    );

    // A device created by another client shows up through events.
    rt.block_on(async {
        let c = Client::connect(&paths.socket(), "test").await.unwrap();
        c.call(
            "device.create",
            json!({"name": "Pixel-ish 6.1", "image": "35"}),
        )
        .await
        .unwrap();
    });
    wait_for(
        &rx,
        "the new device",
        |u| matches!(u, Update::Data(d) if d.devices.iter().any(|i| i.device.name == "Pixel-ish 6.1")),
    );

    // The daemon goes away: the bridge notices and keeps retrying.
    rt.block_on(td.stop());
    wait_for(&rx, "reconnecting", |u| {
        matches!(u, Update::Conn(Conn::Reconnecting(_)))
    });

    // A new daemon on the same socket: back online with the same device.
    let td = rt.block_on(TestDaemon::start(tmp.path())).unwrap();
    wait_for(&rx, "online again", |u| {
        matches!(u, Update::Conn(Conn::Online))
    });
    wait_for(
        &rx,
        "the device after reconnect",
        |u| matches!(u, Update::Data(d) if d.devices.len() == 1),
    );
    rt.block_on(td.stop());
}
