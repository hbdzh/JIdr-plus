//! Read-only live display benchmark. Opens a separate window but never sends input.
//! `cargo run -p jidr-ui --release --example display_bench -- 'device name'`
use jidr_ui::GameWindow;
use jidr_ui::player::{
    input::Screen,
    session::{FrameTarget, Session},
};
use serde_json::json;
use slint::ComponentHandle;
use slint::winit_030::{EventResult, WinitWindowAccessor, winit::event::WindowEvent};
use std::cell::Cell;
use std::rc::Rc;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

fn cpu_seconds() -> Option<f64> {
    let out = std::process::Command::new("ps")
        .args(["-o", "time=", "-p", &std::process::id().to_string()])
        .output()
        .ok()?;
    let text = String::from_utf8(out.stdout).ok()?;
    text.trim()
        .split(':')
        .try_fold(0.0, |n, p| p.parse::<f64>().ok().map(|v| n * 60.0 + v))
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let device = std::env::args()
        .nth(1)
        .ok_or("supply an already-running device name")?;
    slint::BackendSelector::new()
        .backend_name("winit".into())
        .select()?;
    let window = GameWindow::new()?;
    window.set_device_name("Display benchmark (read only)".into());
    window
        .window()
        .set_size(slint::LogicalSize::new(340.0, 752.0));
    window.show()?;
    let rt = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?;
    let paths = jidr_core::JidrPaths::discover()?;
    let session = rt.block_on(async {
        let client = jidr_client::Client::connect(&paths.socket(), "display-benchmark").await?;
        let details = client
            .call("device.details", json!({"device": &device}))
            .await?;
        let dimension = |key: &str| -> Result<u32, Box<dyn std::error::Error>> {
            Ok(details["config"][key]
                .as_str()
                .ok_or("device dimensions unavailable")?
                .parse()?)
        };
        let native = Screen {
            width: dimension("hw.lcd.width")?,
            height: dimension("hw.lcd.height")?,
        };
        let value = client
            .call("device.connect_info", json!({"device": device}))
            .await?;
        let info: jidr_core::ConnectInfo = serde_json::from_value(value)?;
        let id = info.device;
        Session::open(
            id,
            info,
            native,
            (native.width.div_ceil(2), native.height.div_ceil(2)),
            FrameTarget::Game(window.as_weak()),
        )
        .await
        .map_err(Into::<Box<dyn std::error::Error>>::into)
    })?;
    let session = Rc::new(session);
    let weak_session = Rc::downgrade(&session);
    window.window().on_winit_window_event(move |_, event| {
        if let WindowEvent::Occluded(occluded) = event
            && let Some(session) = weak_session.upgrade()
        {
            session.set_visible(!occluded);
        }
        EventResult::Propagate
    });
    let stats = session.stats.clone();
    let phase = Cell::new(0);
    let start = Cell::new(Instant::now());
    let cpu = Cell::new(cpu_seconds());
    let received = Cell::new(0u64);
    let shown = Cell::new(0u64);
    let bytes = Cell::new(0u64);
    let interval = std::env::var("JIDR_DISPLAY_BENCH_SECS")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(10)
        .clamp(3, 60);
    let timer = slint::Timer::default();
    timer.start(slint::TimerMode::Repeated, Duration::from_secs(interval), {
        let window = window.as_weak();
        move || {
            let n = phase.get();
            let dt = start.replace(Instant::now()).elapsed().as_secs_f64();
            let r = stats.received.load(Ordering::Relaxed);
            let s = stats.shown.load(Ordering::Relaxed);
            let b = stats.bytes.load(Ordering::Relaxed);
            let end_cpu = cpu_seconds();
            let cpu_pct = end_cpu.zip(cpu.replace(end_cpu)).map(|(a,b)| (a-b)/dt*100.0);
            println!("{}: seconds={dt:.2} received_fps={:.2} shown_fps={:.2} MB_per_s={:.2} cpu_percent={}", ["visible", "paused", "resumed"][n], (r-received.replace(r)) as f64/dt, (s-shown.replace(s)) as f64/dt, (b-bytes.replace(b)) as f64/1e6/dt, cpu_pct.map(|v| format!("{v:.1}")).unwrap_or_else(|| "unavailable".into()));
            match n {
                0 | 1 => {
                    if let Some(window) = window.upgrade() {
                        window.window().with_winit_window(|native| native.set_minimized(n == 0));
                    }
                }
                _ => { let _ = slint::quit_event_loop(); }
            }
            phase.set(n + 1);
        }
    });
    slint::run_event_loop()?;
    drop(timer);
    drop(session);
    drop(rt);
    Ok(())
}
