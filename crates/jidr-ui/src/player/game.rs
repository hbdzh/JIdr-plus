//! Independent compact game windows. Each window is permanently bound to
//! one device; changing the workbench selection cannot redirect its input.

use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use jidr_core::{ConnectInfo, DeviceStatus};
use serde_json::json;
use slint::{ComponentHandle, ModelRc, VecModel};
use uuid::Uuid;

use crate::GameWindow;
use crate::app::{Ctx, report, toast};
use crate::player::game_shortcuts::{self, Binding, Shortcuts};
use crate::player::input::{self, Gesture, Screen};
use crate::player::keymap::{self, Held, Scheme};
use crate::player::session::{self, FrameTarget, Session};
use crate::player::window_state::{self, WindowState};

pub struct Game {
    window: GameWindow,
    session: RefCell<Option<Session>>,
    gesture: Cell<Gesture>,
    touch_down: Cell<bool>,
    visible: Cell<bool>,
    logical: Cell<(f32, f32)>,
    alive: Arc<AtomicBool>,
    shortcut_lock: Arc<tokio::sync::Mutex<()>>,
    scheme: RefCell<Scheme>,
    draft: RefCell<Option<Scheme>>,
    pending: Cell<Option<(f32, f32, u32)>>,
    held: RefCell<Held>,
    previous_enabled: Cell<bool>,
    load_error: Option<String>,
    window_load_error: Option<String>,
    stats_timer: RefCell<Option<slint::Timer>>,
    shortcuts: RefCell<Shortcuts>,
    shortcuts_load_error: Option<String>,
}

impl Drop for Game {
    fn drop(&mut self) {
        self.alive.store(false, Ordering::Release);
    }
}

impl Game {
    pub(crate) fn set_quality(&self, quality: i32) {
        self.window.invoke_quality_changed(quality);
    }
    fn update_shortcut_labels(&self) {
        let shortcuts = self.shortcuts.borrow();
        if let [a, b, c, d, e] = shortcuts.bindings.as_slice() {
            self.window.set_shortcut_screenshot(a.display().into());
            self.window.set_shortcut_fullscreen(b.display().into());
            self.window.set_shortcut_sidebar(c.display().into());
            self.window.set_shortcut_performance(d.display().into());
            self.window.set_shortcut_text(e.display().into());
        }
    }
    fn release_touch(&self) {
        if !self.touch_down.replace(false) {
            return;
        }
        if let Some(s) = self.session.borrow().as_ref() {
            let points =
                input::panel_touches(self.gesture.get(), s.native, s.native, 0, (0.5, 0.5));
            s.send(input::touch_event(&points, false), false);
        }
    }

    fn close_session(&self, ctx: &Ctx) {
        self.release_touch();
        self.release_mapped();
        if let Some(session) = self.session.borrow_mut().take() {
            session.stop_frames();
            ctx.bridge.handle().spawn(session.shutdown());
        }
    }

    pub(crate) fn prepare_for_quit(&self, ctx: &Ctx) {
        self.close_session(ctx);
    }

    fn release_mapped(&self) {
        let points = self.held.borrow_mut().drain();
        if !points.is_empty()
            && let Some(s) = self.session.borrow().as_ref()
        {
            s.send(input::touch_event(&points, false), false);
        }
    }

    fn save_window(&self, ctx: &Ctx, id: Uuid) {
        let w = self.window.window();
        if self.window_load_error.is_some() || w.is_fullscreen() || w.is_maximized() {
            return;
        }
        let size = w.size();
        let scale = w.scale_factor();
        let position = w.position();
        let state = WindowState {
            version: 1,
            width: size.width as f32 / scale,
            height: size.height as f32 / scale,
            x: position.x,
            y: position.y,
            sidebar: self.window.get_sidebar_visible(),
            on_top: self.window.get_window_pinned(),
            landscape: self.window.get_frame_w() > self.window.get_frame_h(),
            quality: self.window.get_quality().clamp(0, 2) as u8,
        };
        if let Err(e) = window_state::save(&ctx.paths.data, id, &state) {
            toast(&ctx.app.as_weak(), e);
        }
    }

    fn markers(&self) {
        let rotation = self.window.get_frame_quarter().rem_euclid(4) as u32;
        let draft = self.draft.borrow();
        let saved = self.scheme.borrow();
        let scheme = draft.as_ref().unwrap_or(&saved);
        let markers = scheme
            .bindings
            .iter()
            .filter(|b| b.rotation == rotation)
            .map(|b| crate::KeyMarker {
                label: if b.key == "SPACE" {
                    "SPC".into()
                } else {
                    b.key.clone().into()
                },
                x: b.x,
                y: b.y,
            })
            .collect::<Vec<_>>();
        self.window
            .set_mapping_markers(ModelRc::new(VecModel::from(markers)));
    }
}

fn notice(window: &GameWindow, text: String) {
    notice_with_tone(window, text, false);
}

fn notice_with_tone(window: &GameWindow, text: String, error: bool) {
    window.set_notice_error(error);
    window.set_notice(text.clone().into());
    let weak = window.as_weak();
    slint::Timer::single_shot(
        std::time::Duration::from_secs(if error { 9 } else { 4 }),
        move || {
            if let Some(window) = weak.upgrade()
                && window.get_notice() == text.as_str()
            {
                window.set_notice("".into());
            }
        },
    );
}

/// Route to the window's own device, independent of the workbench selection.
fn game_drop(ctx: &Rc<Ctx>, game: &Rc<Game>, id: Uuid, path: PathBuf) {
    if game.window.get_drop_busy() {
        notice(
            &game.window,
            crate::i18n::text(
                "Please wait for the current file operation to finish",
                "请等待当前文件操作完成",
            )
            .into(),
        );
        return;
    }
    if !ctx
        .info(id)
        .is_some_and(|d| matches!(d.device.status, DeviceStatus::Running))
    {
        notice(
            &game.window,
            crate::i18n::text(
                "The device is not running and cannot receive files",
                "设备未运行，无法接收文件",
            )
            .into(),
        );
        return;
    }
    if !path.is_file() {
        notice(
            &game.window,
            crate::i18n::text(
                "Choose a local file; folders are not supported",
                "请选择本地文件，不支持文件夹",
            )
            .into(),
        );
        return;
    }
    let name = crate::recording::file_name(&path.to_string_lossy());
    let install = matches!(
        super::drop::classify_game(&path),
        super::drop::DropAction::InstallApk(_)
    );
    let (method, params, prefix) = if install {
        (
            "file.install",
            json!({"device": id, "apk": path, "replace": true}),
            crate::i18n::text("Installing", "正在安装"),
        )
    } else {
        (
            "file.push",
            json!({"device": id, "local": path}),
            crate::i18n::text("Copying", "正在复制"),
        )
    };
    game.window.set_drop_busy(true);
    game.window
        .set_drop_status(format!("{prefix} {name}…").into());
    let progress_window = game.window.as_weak();
    let progress_name = name.clone();
    let result_window = game.window.as_weak();
    ctx.bridge.run(
        method,
        params,
        move |job| {
            let text = match job.progress {
                Some(p) if p.is_finite() => format!(
                    "{prefix} {progress_name} · {:.0}%",
                    p.clamp(0.0, 1.0) * 100.0
                ),
                _ => format!("{prefix} {progress_name}…"),
            };
            let window = progress_window.clone();
            let _ = slint::invoke_from_event_loop(move || {
                if let Some(window) = window.upgrade() {
                    window.set_drop_status(text.into());
                }
            });
        },
        move |result| {
            let _ = slint::invoke_from_event_loop(move || {
                if let Some(window) = result_window.upgrade() {
                    window.set_drop_busy(false);
                    window.set_drop_status("".into());
                    let failed = result.is_err();
                    if install && !failed && let Some(ctx) = crate::app::ctx() {
                        crate::game_library::refresh(&ctx);
                    }
                    let text = match result {
                        Ok(_) if install => format!("{} {name}", crate::i18n::text("Installed", "已安装")),
                        Ok(_) => format!("{} {name} {}", crate::i18n::text("Copied", "已复制"), crate::i18n::text("to Download", "到 Download")),
                        Err(e) if install && super::drop::is_signature_mismatch(&e.message) => {
                            crate::i18n::text("Installation failed: signatures do not match; the original app and its data were preserved", "安装失败：签名不一致，原应用及数据未删除").into()
                        }
                        Err(e) if install => super::drop::install_error_message(&e.message),
                        Err(e) => format!("{} {}", crate::i18n::text("File operation failed:", "文件操作失败："), e.message),
                    };
                    notice_with_tone(&window, text, failed);
                }
            });
        },
    );
}

fn quality_request_size(
    logical: (f32, f32),
    scale: f32,
    screen: Screen,
    quality: i32,
) -> (u32, u32) {
    let factor = match quality {
        0 => 0.65,
        2 => 0.45,
        _ => 1.0,
    };
    session::request_size(logical, scale * factor, screen)
}

fn measured_memory(value: &serde_json::Value, id: Uuid) -> Option<u64> {
    value.get("devices")?.as_array()?.iter().find_map(|device| {
        (device.get("id")?.as_str()? == id.to_string())
            .then(|| device.get("measured_mb")?.as_u64())?
    })
}

/// Keep the screen's long side fixed across rotations, with a narrow toolbar.
fn window_size(screen: Screen, long_side: f32, sidebar_visible: bool) -> (f32, f32) {
    let longest = screen.width.max(screen.height).max(1) as f32;
    let factor = long_side.clamp(240.0, 840.0) / longest;
    (
        screen.width as f32 * factor + if sidebar_visible { 48.0 } else { 0.0 },
        screen.height as f32 * factor + 32.0,
    )
}

fn restored_size(saved: &WindowState, screen: Screen) -> (f32, f32) {
    if saved.landscape == (screen.width > screen.height) {
        (saved.width, saved.height)
    } else {
        let long = (saved.width - if saved.sidebar { 48.0 } else { 0.0 }).max(saved.height - 32.0);
        window_size(screen, long, saved.sidebar)
    }
}

fn resize_sidebar(window: &GameWindow, visible: bool) {
    let native = window.window();
    if native.is_fullscreen() {
        return;
    }
    let scale = native.scale_factor();
    let size = native.size();
    let width = size.width as f32 / scale + if visible { 48.0 } else { -48.0 };
    native.set_size(slint::LogicalSize::new(
        width.max(180.0),
        size.height as f32 / scale,
    ));
}

/// Called on the UI thread by this window's frame stream.
pub fn present(window: &GameWindow, image: slint::Image, screen: Screen, quarter: u32) {
    let old = Screen {
        width: window.get_frame_w().max(1) as u32,
        height: window.get_frame_h().max(1) as u32,
    };
    let rotated = (old.width > old.height) != (screen.width > screen.height);
    if rotated && !window.window().is_fullscreen() {
        let scale = window.window().scale_factor();
        let size = window.window().size();
        let sidebar = window.get_sidebar_visible();
        let long = (size.width as f32 / scale - if sidebar { 48.0 } else { 0.0 })
            .max(size.height as f32 / scale - 32.0);
        let (w, h) = window_size(screen, long, sidebar);
        window.window().set_size(slint::LogicalSize::new(w, h));
    }
    window.set_frame_w(screen.width as i32);
    window.set_frame_h(screen.height as i32);
    if window.get_frame_quarter() != quarter as i32 {
        window.set_frame_quarter(quarter as i32);
        window.invoke_map_rotation_changed();
    }
    window.set_frame(image);
    window.set_has_frame(true);
}

pub fn open(ctx: &Rc<Ctx>, id: Uuid) {
    let existing = ctx.game_windows.borrow().get(&id).cloned();
    if let Some(game) = existing {
        match game.window.show() {
            Ok(()) => crate::launcher::remove_device_tab(ctx, id),
            Err(e) => toast(&ctx.app.as_weak(), format!("Can't show game window: {e}")),
        }
        return;
    }
    let Some(info) = ctx.info(id) else { return };
    if !matches!(info.device.status, DeviceStatus::Running) {
        toast(
            &ctx.app.as_weak(),
            crate::i18n::text(
                "Start the device before opening its game window",
                "请先启动设备，再打开游戏窗口",
            )
            .into(),
        );
        return;
    }
    if info.width == 0 || info.height == 0 {
        toast(
            &ctx.app.as_weak(),
            crate::i18n::text(
                "Device display details are still loading; try again in a moment",
                "设备显示信息正在加载，请稍后重试",
            )
            .into(),
        );
        return;
    }
    let window = match GameWindow::new() {
        Ok(w) => w,
        Err(e) => {
            toast(&ctx.app.as_weak(), format!("Can't open game window: {e}"));
            return;
        }
    };
    let native = Screen {
        width: info.width.max(1),
        height: info.height.max(1),
    };
    window.set_device_name(info.device.name.into());
    window.set_frame_w(native.width as i32);
    window.set_frame_h(native.height as i32);
    let (saved_window, window_load_error) = match window_state::load(&ctx.paths.data, id) {
        Ok(state) => (state, None),
        Err(e) => (None, Some(e)),
    };
    if let Some(saved) = &saved_window {
        window.set_sidebar_visible(saved.sidebar);
        window.set_window_pinned(saved.on_top);
        window.set_quality(i32::from(saved.quality));
    }
    match window_state::load_quality(&ctx.paths.data, id) {
        Ok(quality) => window.set_quality(i32::from(quality)),
        Err(error) => toast(&ctx.app.as_weak(), error),
    }
    let (w, h) = saved_window
        .as_ref()
        .map(|s| restored_size(s, native))
        .unwrap_or_else(|| window_size(native, 720.0, true));
    window.window().set_size(slint::LogicalSize::new(w, h));
    let (scheme, load_error) = match keymap::load(&ctx.paths.data, id) {
        Ok(scheme) => (scheme, None),
        Err(e) => (Scheme::default(), Some(e)),
    };
    let (shortcuts, shortcuts_load_error) = match game_shortcuts::load(&ctx.paths.data, id) {
        Ok(value) => (value, None),
        Err(e) => (Shortcuts::default(), Some(e)),
    };
    let sidebar_visible = window.get_sidebar_visible();
    let game = Rc::new(Game {
        window,
        session: RefCell::new(None),
        gesture: Cell::new(Gesture::Single),
        touch_down: Cell::new(false),
        visible: Cell::new(true),
        logical: Cell::new((w - if sidebar_visible { 48.0 } else { 0.0 }, h - 32.0)),
        alive: Arc::new(AtomicBool::new(true)),
        shortcut_lock: Arc::default(),
        scheme: RefCell::new(scheme),
        draft: RefCell::new(None),
        pending: Cell::new(None),
        held: RefCell::default(),
        previous_enabled: Cell::new(false),
        load_error,
        window_load_error,
        stats_timer: RefCell::new(None),
        shortcuts: RefCell::new(shortcuts),
        shortcuts_load_error,
    });
    wire(ctx, id, &game);
    game.markers();
    game.update_shortcut_labels();
    ctx.game_windows.borrow_mut().insert(id, game.clone());
    if let Err(e) = game.window.show() {
        ctx.game_windows.borrow_mut().remove(&id);
        toast(&ctx.app.as_weak(), format!("Can't show game window: {e}"));
        return;
    }
    crate::launcher::remove_device_tab(ctx, id);
    {
        use slint::winit_030::{WinitWindowAccessor, winit::window::WindowLevel};
        let pinned = game.window.get_window_pinned();
        let saved = saved_window.clone();
        game.window.window().with_winit_window(|window| {
            window.set_window_level(if pinned {
                WindowLevel::AlwaysOnTop
            } else {
                WindowLevel::Normal
            });
            if let Some(saved) = saved {
                let monitors: Vec<_> = window
                    .available_monitors()
                    .map(|m| {
                        let p = m.position();
                        let s = m.size();
                        (p.x, p.y, s.width, s.height)
                    })
                    .collect();
                let scale = window.scale_factor();
                if window_state::visible(saved.x, saved.y, (f64::from(w) * scale) as u32, &monitors)
                {
                    window.set_outer_position(slint::winit_030::winit::dpi::PhysicalPosition::new(
                        saved.x, saved.y,
                    ));
                }
            }
        });
    }
    if let Some(e) = &game.load_error {
        notice(&game.window, e.clone());
    }
    if let Some(e) = &game.window_load_error {
        notice(&game.window, e.clone());
    }
    if let Some(e) = &game.shortcuts_load_error {
        notice(&game.window, e.clone());
    }
    let target = FrameTarget::Game(game.window.as_weak());
    let weak = Rc::downgrade(&game);
    let handle = ctx.bridge.handle();
    let app = ctx.app.as_weak();
    let weak_ctx = Rc::downgrade(ctx);
    let scale = game.window.window().scale_factor();
    let wanted = quality_request_size(game.logical.get(), scale, native, game.window.get_quality());
    let token = crate::app::defer(move |result: jidr_core::JidrResult<Session>| {
        let Some(game) = weak.upgrade() else { return };
        match result {
            Ok(s) => {
                s.set_visible(game.visible.get());
                s.resize(quality_request_size(
                    game.logical.get(),
                    game.window.window().scale_factor(),
                    native,
                    game.window.get_quality(),
                ));
                *game.session.borrow_mut() = Some(s);
            }
            Err(e) => {
                toast(&app, format!("Can't show game screen: {}", e.message));
                if let Some(ctx) = weak_ctx.upgrade() {
                    let same_window = ctx
                        .game_windows
                        .borrow()
                        .get(&id)
                        .is_some_and(|g| Rc::ptr_eq(g, &game));
                    if same_window {
                        ctx.game_windows.borrow_mut().remove(&id);
                        let _ = game.window.hide();
                    }
                }
            }
        }
    });
    ctx.bridge.call(
        "device.connect_info",
        json!({"device": id}),
        move |result| {
            let info = result.and_then(|v| {
                serde_json::from_value::<ConnectInfo>(v)
                    .map_err(|e| jidr_core::JidrError::unexpected(e.to_string()))
            });
            handle.spawn(async move {
                let result = match info {
                    Ok(info) => Session::open(id, info, native, wanted, target).await,
                    Err(e) => Err(e),
                };
                crate::app::fire(token, result);
            });
        },
    );
}

/// Switch back to the workbench without stopping the emulator.
pub fn close(ctx: &Rc<Ctx>, id: Uuid) {
    let game = ctx.game_windows.borrow_mut().remove(&id);
    if let Some(game) = game {
        game.save_window(ctx, id);
        game.close_session(ctx);
        let _ = game.window.hide();
    }
}

fn wire(ctx: &Rc<Ctx>, id: Uuid, game: &Rc<Game>) {
    let weak_shortcuts = Rc::downgrade(game);
    let data_shortcuts = ctx.paths.data.clone();
    game.window
        .on_command_shortcut(move |text, command, control, shift, alt| {
            let Some(game) = weak_shortcuts.upgrade() else {
                return false;
            };
            let capture = game.window.get_shortcut_capture();
            if capture >= 0 && text.as_str() == char::from(slint::platform::Key::Escape).to_string()
            {
                game.window.set_shortcut_capture(-1);
                return true;
            }
            let Some(binding) = Binding::new(&text, command, control, shift, alt) else {
                if capture >= 0 && text.len() == 1 && text.as_bytes()[0].is_ascii_alphanumeric() {
                    notice(&game.window, crate::i18n::text("Use a shortcut with a modifier that does not conflict with another shortcut", "请使用带修饰键且不冲突的组合键").into());
                }
                // Modifier keys and IME composition events are not complete chords.
                return capture >= 0;
            };
            if capture >= 0 {
                if game.shortcuts_load_error.is_some() {
                    notice(&game.window, crate::i18n::text("Could not read shortcuts; the original file was not overwritten", "快捷键配置无法读取，未覆盖原文件").into());
                    game.window.set_shortcut_capture(-1);
                    return true;
                }
                let mut updated = game.shortcuts.borrow().clone();
                let result = updated
                    .assign(capture as usize, binding)
                    .map_err(str::to_string)
                    .and_then(|()| game_shortcuts::save(&data_shortcuts, id, &updated));
                match result {
                    Ok(()) => {
                        *game.shortcuts.borrow_mut() = updated;
                        game.update_shortcut_labels();
                        game.window.set_shortcut_capture(-1);
                    }
                    Err(e) => notice(&game.window, e),
                }
                return true;
            }
            let action = game.shortcuts.borrow().lookup(&binding);
            match action {
                Some(0) => game.window.invoke_tool("screenshot".into()),
                Some(1) => game.window.invoke_tool(
                    if game.window.get_game_fullscreen() {
                        "exit-fullscreen"
                    } else {
                        "fullscreen"
                    }
                    .into(),
                ),
                Some(2) => {
                    let visible = !game.window.get_sidebar_visible();
                    game.window.set_sidebar_visible(visible);
                    game.window.invoke_sidebar_changed(visible);
                }
                Some(3) => {
                    let show = !game.window.get_performance_panel();
                    game.window.set_text_panel(false);
                    game.window.set_mapping_panel(false);
                    game.window.set_window_panel(false);
                    game.window.set_shortcut_panel(false);
                    game.window.set_performance_panel(show);
                }
                Some(4) if !game.window.get_text_sending() && !game.window.get_mapping_edit() => {
                    let show = !game.window.get_text_panel();
                    game.window.set_mapping_panel(false);
                    game.window.set_window_panel(false);
                    game.window.set_performance_panel(false);
                    game.window.set_shortcut_panel(false);
                    game.window.set_text_panel(show);
                }
                _ => return false,
            }
            true
        });
    let timer = slint::Timer::default();
    let weak_stats = Rc::downgrade(game);
    let stats_bridge = ctx.bridge.clone();
    let mut memory_tick = 0u32;
    timer.start(
        slint::TimerMode::Repeated,
        std::time::Duration::from_secs(1),
        move || {
            let Some(game) = weak_stats.upgrade() else {
                return;
            };
            if !game.window.get_performance_panel() {
                memory_tick = 0;
                return;
            }
            if memory_tick == 0 {
                let window = game.window.as_weak();
                stats_bridge.call("host.budget", json!({}), move |result| {
                    let memory = result.ok().and_then(|v| measured_memory(&v, id));
                    let text = memory
                        .map(|mb| {
                            format!(
                                "{} {mb} MB {}",
                                crate::i18n::text("Device memory:", "设备内存："),
                                crate::i18n::text("(sampled about every 30 s)", "（约 30 秒采样）")
                            )
                        })
                        .unwrap_or_else(|| {
                            crate::i18n::text("Device memory: no sample", "设备内存：暂无采样")
                                .into()
                        });
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(window) = window.upgrade() {
                            window.set_performance_memory(text.into());
                        }
                    });
                });
            }
            memory_tick = (memory_tick + 1) % 30;
            let session = game.session.borrow();
            let text = if let Some(session) = session.as_ref() {
                let stats = &session.stats;
                let (width, height) = *session::lock(&stats.frame);
                let latency = stats
                    .median_latency()
                    .map(|v| format!("{v:.0} ms"))
                    .unwrap_or_else(|| "—".into());
                format!(
                    "{} {:.0} {} · {} {width}×{height}\n{} {latency} {}",
                    crate::i18n::text("Receiving", "接收"),
                    stats.fps(std::time::Duration::from_secs(2)),
                    crate::i18n::text("fps", "帧/秒"),
                    crate::i18n::text("frame", "画面"),
                    crate::i18n::text("Touch to next frame", "触摸至下一帧"),
                    crate::i18n::text("(estimate)", "（估计）")
                )
            } else {
                crate::i18n::text("Connecting to device…", "正在连接设备…").into()
            };
            game.window.set_performance_text(text.into());
        },
    );
    *game.stats_timer.borrow_mut() = Some(timer);
    let weak_quality = Rc::downgrade(game);
    let weak_ctx_quality = Rc::downgrade(ctx);
    game.window.on_quality_changed(move |quality| {
        let (Some(game), Some(ctx)) = (weak_quality.upgrade(), weak_ctx_quality.upgrade()) else {
            return;
        };
        if !(0..=2).contains(&quality) {
            return;
        }
        if let Err(error) = window_state::save_quality(&ctx.paths.data, id, quality as u8) {
            toast(&ctx.app.as_weak(), error);
            return;
        }
        game.window.set_quality(quality);
        if let Some(s) = game.session.borrow().as_ref() {
            let frame = *session::lock(&s.stats.frame);
            let screen = if frame.0 == 0 {
                s.native
            } else {
                session::oriented(s.native, frame)
            };
            s.resize(quality_request_size(
                game.logical.get(),
                game.window.window().scale_factor(),
                screen,
                quality,
            ));
        }
        game.save_window(&ctx, id);
    });
    let weak = Rc::downgrade(game);
    let weak_ctx = Rc::downgrade(ctx);
    game.window.on_window_action(move |action| {
        let (Some(game), Some(ctx)) = (weak.upgrade(), weak_ctx.upgrade()) else {
            return;
        };
        if action == "pin" {
            use slint::winit_030::{WinitWindowAccessor, winit::window::WindowLevel};
            let pinned = !game.window.get_window_pinned();
            game.window.window().with_winit_window(|w| {
                w.set_window_level(if pinned {
                    WindowLevel::AlwaysOnTop
                } else {
                    WindowLevel::Normal
                });
            });
            game.window.set_window_pinned(pinned);
            game.save_window(&ctx, id);
            return;
        }
        if game.window.window().is_fullscreen() {
            notice(
                &game.window,
                crate::i18n::text(
                    "Exit fullscreen before resizing the window",
                    "请先退出全屏再调整窗口大小",
                )
                .into(),
            );
            return;
        }
        let long = match action.as_str() {
            "small" => 480.0,
            "medium" => 720.0,
            "large" => 840.0,
            _ => return,
        };
        let screen = Screen {
            width: game.window.get_frame_w().max(1) as u32,
            height: game.window.get_frame_h().max(1) as u32,
        };
        let (w, h) = window_size(screen, long, game.window.get_sidebar_visible());
        game.window.window().set_size(slint::LogicalSize::new(w, h));
    });
    let weak = Rc::downgrade(game);
    let handle = ctx.bridge.handle();
    game.window.on_paste_text(move || {
        let Some(game) = weak.upgrade() else { return };
        if game.window.get_text_sending() {
            return;
        }
        let original = game.window.get_composed_text();
        let window = game.window.as_weak();
        handle.spawn(async move {
            let result = super::edit_shortcuts::host_clipboard().await;
            let _ = slint::invoke_from_event_loop(move || {
                if let Some(window) = window.upgrade() {
                    if !window.get_text_panel() || window.get_composed_text() != original {
                        return;
                    }
                    match result {
                        Ok(text) => window.set_composed_text(text.into()),
                        Err(e) => notice(&window, e),
                    }
                }
            });
        });
    });
    let weak = Rc::downgrade(game);
    let handle = ctx.bridge.handle();
    game.window.on_send_text(move |text| {
        let Some(game) = weak.upgrade() else { return };
        if game.window.get_text_sending() || text.is_empty() {
            return;
        }
        let session = game.session.borrow();
        let Some(session) = session.as_ref() else {
            notice(
                &game.window,
                crate::i18n::text("Device is disconnected", "设备未连接").into(),
            );
            return;
        };
        let ctl = session.ctl.clone();
        let lock = game.shortcut_lock.clone();
        let alive = game.alive.clone();
        let window = game.window.as_weak();
        game.window.set_text_sending(true);
        let text = text.to_string();
        handle.spawn(async move {
            let _guard = lock.lock().await;
            let result = super::edit_shortcuts::send_text(ctl, text.clone(), &alive).await;
            let _ = slint::invoke_from_event_loop(move || {
                if let Some(window) = window.upgrade() {
                    window.set_text_sending(false);
                    match result {
                        Ok(()) => {
                            if window.get_composed_text() == text.as_str() {
                                window.set_composed_text("".into());
                            }
                            window.set_text_panel(false);
                        }
                        Err(e) => notice(&window, e),
                    }
                }
            });
        });
    });
    let weak = Rc::downgrade(game);
    let data = ctx.paths.data.clone();
    game.window.on_map_action(move |action| {
        let Some(game) = weak.upgrade() else { return };
        match action.as_str() {
            "edit" if !game.window.get_mapping_edit() => {
                if let Some(error) = &game.load_error {
                    notice(&game.window, error.clone());
                    return;
                }
                game.release_touch();
                game.release_mapped();
                game.previous_enabled.set(game.window.get_mapping_enabled());
                game.window.set_mapping_enabled(false);
                *game.draft.borrow_mut() = Some(game.scheme.borrow().clone());
                game.pending.set(None);
                game.window.set_mapping_pending(false);
                game.window.set_mapping_edit(true);
                game.markers();
            }
            "cancel" => {
                *game.draft.borrow_mut() = None;
                game.pending.set(None);
                game.window.set_mapping_pending(false);
                game.window.set_mapping_edit(false);
                game.window.set_mapping_enabled(game.previous_enabled.get());
                game.markers();
            }
            "clear" => {
                if let Some(draft) = game.draft.borrow_mut().as_mut() {
                    draft.bindings.clear();
                }
                game.pending.set(None);
                game.window.set_mapping_pending(false);
                game.markers();
            }
            "save" => {
                if game.pending.get().is_some() {
                    notice(
                        &game.window,
                        crate::i18n::text(
                            "Press a key for the selected position first",
                            "请先为选中的位置设置按键",
                        )
                        .into(),
                    );
                    return;
                }
                let draft = game.draft.borrow().clone();
                if let Some(draft) = draft {
                    match keymap::save(&data, id, &draft) {
                        Ok(()) => {
                            let has_bindings = !draft.bindings.is_empty();
                            *game.scheme.borrow_mut() = draft;
                            *game.draft.borrow_mut() = None;
                            game.pending.set(None);
                            game.window.set_mapping_pending(false);
                            game.window.set_mapping_edit(false);
                            game.window.set_mapping_enabled(has_bindings);
                            game.markers();
                            notice(
                                &game.window,
                                crate::i18n::text("Key mapping saved", "键位映射已保存").into(),
                            );
                        }
                        Err(e) => notice(&game.window, e),
                    }
                }
            }
            "toggle" => {
                if game.window.get_mapping_enabled() {
                    game.release_mapped();
                    game.window.set_mapping_enabled(false);
                } else if game.scheme.borrow().bindings.is_empty() {
                    notice(
                        &game.window,
                        crate::i18n::text("Add and save a key mapping first", "请先添加并保存键位")
                            .into(),
                    );
                } else {
                    game.window.set_mapping_enabled(true);
                }
            }
            "hints" => game
                .window
                .set_mapping_hints(!game.window.get_mapping_hints()),
            _ => {}
        }
    });
    let weak = Rc::downgrade(game);
    game.window.on_map_place(move |x, y| {
        let Some(game) = weak.upgrade() else { return };
        if game.window.get_mapping_edit()
            && x.is_finite()
            && y.is_finite()
            && (0.0..=1.0).contains(&x)
            && (0.0..=1.0).contains(&y)
        {
            let quarter = game.window.get_frame_quarter().rem_euclid(4) as u32;
            game.pending.set(Some((x, y, quarter)));
            game.window.set_pending_x(x);
            game.window.set_pending_y(y);
            game.window.set_mapping_pending(true);
        }
    });
    let weak = Rc::downgrade(game);
    game.window.on_map_remove(move |x, y, width, height| {
        let Some(game) = weak.upgrade() else { return };
        if !game.window.get_mapping_edit() {
            return;
        }
        let quarter = game.window.get_frame_quarter().rem_euclid(4) as u32;
        if let Some(draft) = game.draft.borrow_mut().as_mut() {
            draft.remove_at(x, y, width, height, quarter);
        }
        game.markers();
    });
    let weak = Rc::downgrade(game);
    game.window.on_map_key(move |text| {
        let Some(game) = weak.upgrade() else { return };
        let Some((x, y, quarter)) = game.pending.get() else {
            notice(
                &game.window,
                crate::i18n::text("Click a position on the screen first", "请先点击屏幕位置")
                    .into(),
            );
            return;
        };
        let result = game
            .draft
            .borrow_mut()
            .as_mut()
            .map(|draft| draft.assign(&text, x, y, quarter));
        match result {
            Some(Ok(())) => {
                game.pending.set(None);
                game.window.set_mapping_pending(false);
                game.markers();
            }
            Some(Err(e)) => notice(&game.window, e),
            None => {}
        }
    });
    let weak = Rc::downgrade(game);
    game.window.on_mapped_key(move |text, down| {
        let Some(game) = weak.upgrade() else {
            return false;
        };
        let session = game.session.borrow();
        let Some(s) = session.as_ref() else {
            return false;
        };
        let quarter = game.window.get_frame_quarter().rem_euclid(4) as u32;
        let shown = Screen {
            width: game.window.get_frame_w().max(1) as u32,
            height: game.window.get_frame_h().max(1) as u32,
        };
        let (handled, event) = game.held.borrow_mut().dispatch(
            &game.scheme.borrow(),
            &text,
            down,
            game.window.get_mapping_enabled() && !game.window.get_mapping_edit(),
            (quarter, s.native, shown),
        );
        if let Some(event) = event {
            s.send(event, down);
        }
        handled
    });
    let weak = Rc::downgrade(game);
    game.window.on_map_rotation_changed(move || {
        if let Some(game) = weak.upgrade() {
            game.release_mapped();
            game.pending.set(None);
            game.window.set_mapping_pending(false);
            game.markers();
        }
    });
    let weak = Rc::downgrade(game);
    game.window.on_sidebar_changed(move |visible| {
        if let Some(game) = weak.upgrade() {
            resize_sidebar(&game.window, visible);
        }
    });
    let weak = Rc::downgrade(game);
    game.window.on_drag_window(move || {
        use slint::winit_030::WinitWindowAccessor;
        if let Some(game) = weak.upgrade() {
            game.window.window().with_winit_window(|window| {
                let _ = window.drag_window();
            });
        }
    });
    let weak = Rc::downgrade(game);
    game.window.on_pointer(move |kind, x, y, alt, shift| {
        let Some(game) = weak.upgrade() else { return };
        if kind == 0 {
            game.gesture.set(Gesture::from_mods(alt, shift));
        }
        let session = game.session.borrow();
        let Some(s) = session.as_ref() else { return };
        if kind == 0 {
            game.touch_down.set(true);
        } else if kind == 2 {
            game.touch_down.set(false);
        }
        let frame = *session::lock(&s.stats.frame);
        let shown = if frame.0 == 0 {
            s.native
        } else {
            session::oriented(s.native, frame)
        };
        let quarter = s.stats.quarter.load(Ordering::Relaxed);
        let points = input::panel_touches(game.gesture.get(), s.native, shown, quarter, (x, y));
        s.send(input::touch_event(&points, kind != 2), kind != 2);
    });
    let weak = Rc::downgrade(game);
    let handle = ctx.bridge.handle();
    game.window.on_key(move |text, down| {
        let Some(game) = weak.upgrade() else { return };
        let session = game.session.borrow();
        if let (Some(s), Some(event)) = (session.as_ref(), input::key_event(&text, down)) {
            let mut ctl = s.ctl.clone();
            handle.spawn(async move {
                let _ = ctl.send_key(event).await;
            });
        }
    });
    let weak = Rc::downgrade(game);
    let handle = ctx.bridge.handle();
    let window = game.window.as_weak();
    game.window.on_edit_shortcut(move |text, shift| {
        let Some(game) = weak.upgrade() else { return };
        let Some(shortcut) = super::edit_shortcuts::Shortcut::parse(&text, shift) else {
            return;
        };
        let session = game.session.borrow();
        let Some(session) = session.as_ref() else {
            return;
        };
        let ctl = session.ctl.clone();
        let lock = game.shortcut_lock.clone();
        let alive = game.alive.clone();
        let window = window.clone();
        handle.spawn(async move {
            let _guard = lock.lock().await;
            if let Err(e) = super::edit_shortcuts::run(ctl, shortcut, &alive).await {
                let _ = slint::invoke_from_event_loop(move || {
                    if let Some(window) = window.upgrade() {
                        window.set_notice(e.clone().into());
                        let weak = window.as_weak();
                        slint::Timer::single_shot(std::time::Duration::from_secs(4), move || {
                            if let Some(window) = weak.upgrade()
                                && window.get_notice() == e.as_str()
                            {
                                window.set_notice("".into());
                            }
                        });
                    }
                });
            }
        });
    });
    let weak = Rc::downgrade(game);
    let handle = ctx.bridge.handle();
    game.window.on_wheel(move |x, y| {
        let Some(game) = weak.upgrade() else { return };
        let session = game.session.borrow();
        if let Some(s) = session.as_ref() {
            let mut ctl = s.ctl.clone();
            let event = input::wheel(x, y);
            handle.spawn(async move {
                let _ = ctl.inject_wheel(tokio_stream::iter(vec![event])).await;
            });
        }
    });
    let weak = Rc::downgrade(game);
    game.window.on_screen_resized(move |w, h| {
        let Some(game) = weak.upgrade() else { return };
        game.logical.set((w, h));
        if let Some(s) = game.session.borrow().as_ref() {
            let frame = *session::lock(&s.stats.frame);
            let shown = if frame.0 == 0 {
                s.native
            } else {
                session::oriented(s.native, frame)
            };
            s.resize(quality_request_size(
                (w, h),
                game.window.window().scale_factor(),
                shown,
                game.window.get_quality(),
            ));
        }
    });
    let weak_game = Rc::downgrade(game);
    let weak_ctx = Rc::downgrade(ctx);
    game.window.on_tool(move |tool| {
        let (Some(game), Some(ctx)) = (weak_game.upgrade(), weak_ctx.upgrade()) else {
            return;
        };
        let tool = tool.as_str();
        if let Some(key) = input::tool_key(tool) {
            ctx.bridge.call(
                "key.press",
                json!({"device": id, "key": key}),
                report(&ctx.app.as_weak(), ""),
            );
        } else if tool == "rotate-left" || tool == "rotate-right" {
            let current = game
                .session
                .borrow()
                .as_ref()
                .map_or(0, |s| s.stats.quarter.load(Ordering::Relaxed) as i32);
            let q = (current + if tool == "rotate-left" { 1 } else { 3 }) % 4;
            ctx.bridge.call(
                "sensor.rotate",
                json!({"device": id, "angle": q * 90}),
                report(&ctx.app.as_weak(), ""),
            );
        } else if tool == "screenshot" {
            crate::recording::screenshot(&ctx, id);
        } else if tool == "fullscreen" || tool == "exit-fullscreen" {
            let window = game.window.window();
            let on = tool == "fullscreen" && !window.is_fullscreen();
            window.set_fullscreen(on);
            game.window.set_game_fullscreen(on);
        }
    });
    let weak_ctx = Rc::downgrade(ctx);
    game.window.window().on_close_requested(move || {
        if let Some(ctx) = weak_ctx.upgrade()
            && let Some(game) = ctx.game_windows.borrow_mut().remove(&id)
        {
            game.save_window(&ctx, id);
            game.close_session(&ctx);
        }
        slint::CloseRequestResponse::HideWindow
    });
    {
        let (ime_tx, mut ime_rx) =
            tokio::sync::mpsc::unbounded_channel::<(jidr_proto::Controller, String)>();
        let ime_lock = game.shortcut_lock.clone();
        let ime_alive = game.alive.clone();
        let ime_window = game.window.as_weak();
        ctx.bridge.handle().spawn(async move {
            while let Some((ctl, text)) = ime_rx.recv().await {
                let _guard = ime_lock.lock().await;
                if let Err(e) =
                    super::edit_shortcuts::send_text(ctl, text.clone(), &ime_alive).await
                {
                    let window = ime_window.clone();
                    let _ = slint::invoke_from_event_loop(move || {
                        if let Some(window) = window.upgrade() {
                            // Preserve unsent text for a manual retry without
                            // replacing text already being edited in the panel.
                            let existing = window.get_composed_text().to_string();
                            window.set_composed_text(format!("{existing}{text}").into());
                            window.set_text_panel(true);
                            notice(
                                &window,
                                format!(
                                    "{} {e}",
                                    crate::i18n::text(
                                        "Text input failed; text was preserved:",
                                        "中文输入失败，文字已保留："
                                    )
                                ),
                            );
                        }
                    });
                }
            }
        });
        let weak = Rc::downgrade(game);
        game.window.on_inline_text(move |text| {
            let Some(game) = weak.upgrade() else { return };
            if text.is_empty() {
                return;
            }
            if let Some(session) = game.session.borrow().as_ref()
                && ime_tx.send((session.ctl.clone(), text.to_string())).is_ok()
            {
                return;
            }
            let existing = game.window.get_composed_text();
            game.window
                .set_composed_text(format!("{existing}{text}").into());
            game.window.set_text_panel(true);
            notice(
                &game.window,
                crate::i18n::text(
                    "Device disconnected; text remains in the input panel",
                    "设备未连接，文字已保留在输入面板",
                )
                .into(),
            );
        });
    }
    {
        use slint::winit_030::{EventResult, WinitWindowAccessor, winit::event::WindowEvent};
        let weak = Rc::downgrade(game);
        let weak_ctx = Rc::downgrade(ctx);
        // On macOS, flagsChanged can have no physical key code (for example
        // accessibility-generated shortcuts). Winit then emits only
        // ModifiersChanged, which Slint's winit backend does not consume.
        // Use that aggregate state as the source of truth for modifier keys.
        #[cfg(target_os = "macos")]
        let modifiers = std::cell::Cell::new([false; 4]);
        game.window.window().on_winit_window_event(move |_, event| {
            if let WindowEvent::Occluded(occluded) = event
                && let Some(game) = weak.upgrade()
            {
                game.visible.set(!occluded);
                if let Some(session) = game.session.borrow().as_ref() {
                    session.set_visible(!occluded);
                }
            }
            #[cfg(target_os = "macos")]
            {
                use slint::winit_030::winit::keyboard::{Key as WinitKey, NamedKey};
                if let WindowEvent::KeyboardInput { event, .. } = event
                    && matches!(
                        event.logical_key,
                        WinitKey::Named(
                            NamedKey::Super | NamedKey::Control | NamedKey::Shift | NamedKey::Alt
                        )
                    )
                {
                    return EventResult::PreventDefault;
                }
                let next = match event {
                    WindowEvent::ModifiersChanged(value) => {
                        let state = value.state();
                        Some([
                            state.super_key(),
                            state.control_key(),
                            state.shift_key(),
                            state.alt_key(),
                        ])
                    }
                    WindowEvent::Focused(false) => Some([false; 4]),
                    _ => None,
                };
                if let Some(next) = next {
                    let previous = modifiers.replace(next);
                    if let Some(game) = weak.upgrade() {
                        dispatch_modifiers(game.window.window(), previous, next);
                    }
                }
            }
            if matches!(event, WindowEvent::Focused(false))
                && let Some(game) = weak.upgrade()
            {
                game.release_touch();
                game.release_mapped();
                if let Some(ctx) = weak_ctx.upgrade() {
                    game.save_window(&ctx, id);
                }
            }
            if let Some(game) = weak.upgrade() {
                match event {
                    WindowEvent::HoveredFile(path) => {
                        let name = crate::recording::file_name(&path.to_string_lossy());
                        let action = super::drop::classify_game(path);
                        let verb = if matches!(action, super::drop::DropAction::InstallApk(_)) {
                            crate::i18n::text("install", "安装")
                        } else {
                            crate::i18n::text("copy to Download", "复制到 Download")
                        };
                        game.window.set_drop_title(
                            format!("{} {verb} {name}", crate::i18n::text("Drop to", "松开以"))
                                .into(),
                        );
                        game.window.set_drop_hover(true);
                    }
                    WindowEvent::HoveredFileCancelled => game.window.set_drop_hover(false),
                    WindowEvent::DroppedFile(path) => {
                        game.window.set_drop_hover(false);
                        if let Some(ctx) = weak_ctx.upgrade() {
                            game_drop(&ctx, &game, id, path.clone());
                        }
                    }
                    _ => {}
                }
            }
            if matches!(event, WindowEvent::Resized(_)) {
                let weak = weak.clone();
                slint::Timer::single_shot(std::time::Duration::ZERO, move || {
                    if let Some(game) = weak.upgrade() {
                        game.window
                            .set_game_fullscreen(game.window.window().is_fullscreen());
                    }
                });
            }
            EventResult::Propagate
        });
    }
}

#[cfg(any(target_os = "macos", test))]
fn modifier_changes(previous: [bool; 4], next: [bool; 4]) -> Vec<(slint::platform::Key, bool)> {
    use slint::platform::Key;
    // Slint swaps Command and Control on Apple platforms.
    [Key::Control, Key::Meta, Key::Shift, Key::Alt]
        .into_iter()
        .enumerate()
        .filter_map(|(i, key)| (previous[i] != next[i]).then_some((key, next[i])))
        .collect()
}

#[cfg(any(target_os = "macos", test))]
fn dispatch_modifiers(window: &slint::Window, previous: [bool; 4], next: [bool; 4]) {
    use slint::platform::WindowEvent;
    for (key, pressed) in modifier_changes(previous, next) {
        let text = key.into();
        window.dispatch_event(if pressed {
            WindowEvent::KeyPressed { text }
        } else {
            WindowEvent::KeyReleased { text }
        });
    }
}

/// Stop streaming as soon as the bound device is no longer running.
pub fn sync(ctx: &Rc<Ctx>) {
    let dead: Vec<_> = ctx
        .game_windows
        .borrow()
        .keys()
        .copied()
        .filter(|id| {
            !ctx.info(*id)
                .is_some_and(|info| matches!(info.device.status, DeviceStatus::Running))
        })
        .collect();
    for id in dead {
        if let Some(game) = ctx.game_windows.borrow_mut().remove(&id) {
            game.close_session(ctx);
            let _ = game.window.hide();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mapping_edit_cancel_save_and_rotation_are_isolated_per_device() {
        use slint::Model;
        crate::offscreen::init().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let paths = jidr_core::JidrPaths::under(dir.path());
        let ctx = Rc::new(Ctx {
            app: crate::AppWindow::new().unwrap(),
            bridge: crate::bridge::Bridge::new().unwrap(),
            state: Rc::default(),
            paths: paths.clone(),
            prefs: RefCell::default(),
            windows: RefCell::default(),
            catalog: RefCell::default(),
            pending_confirm: RefCell::default(),
            player: RefCell::default(),
            game_windows: RefCell::default(),
            pending_window_opens: RefCell::default(),
            quitting: Cell::new(false),
        });
        let game = Rc::new(Game {
            window: GameWindow::new().unwrap(),
            session: RefCell::new(None),
            gesture: Cell::new(Gesture::Single),
            touch_down: Cell::new(false),
            visible: Cell::new(true),
            logical: Cell::new((324.0, 720.0)),
            alive: Arc::new(AtomicBool::new(true)),
            shortcut_lock: Arc::default(),
            scheme: RefCell::new(Scheme::default()),
            draft: RefCell::new(None),
            pending: Cell::new(None),
            held: RefCell::default(),
            previous_enabled: Cell::new(false),
            load_error: None,
            window_load_error: None,
            stats_timer: RefCell::new(None),
            shortcuts: RefCell::new(Shortcuts::default()),
            shortcuts_load_error: None,
        });
        let id = Uuid::new_v4();
        wire(&ctx, id, &game);
        game.window.invoke_map_action("edit".into());
        game.window.invoke_map_place(0.25, 0.75);
        game.window.invoke_map_key("a".into());
        assert_eq!(game.window.get_mapping_markers().row_count(), 1);
        game.window.invoke_map_action("cancel".into());
        assert!(game.scheme.borrow().bindings.is_empty());
        assert_eq!(game.window.get_mapping_markers().row_count(), 0);
        game.window.invoke_map_action("edit".into());
        game.window.invoke_map_place(0.25, 0.75);
        game.window.invoke_map_key("a".into());
        game.window.invoke_map_action("save".into());
        assert!(game.window.get_mapping_enabled());
        assert_eq!(keymap::load(&paths.data, id).unwrap().bindings.len(), 1);
        assert!(
            keymap::load(&paths.data, Uuid::new_v4())
                .unwrap()
                .bindings
                .is_empty()
        );
        game.window.invoke_map_action("edit".into());
        game.window.invoke_map_action("clear".into());
        assert_eq!(game.window.get_mapping_markers().row_count(), 0);
        game.window.invoke_map_action("cancel".into());
        assert_eq!(game.window.get_mapping_markers().row_count(), 1);
        game.window.invoke_map_action("edit".into());
        game.window.invoke_map_remove(0.25, 0.75, 324.0, 720.0);
        assert_eq!(game.window.get_mapping_markers().row_count(), 0);
        game.window.invoke_map_action("cancel".into());
        assert_eq!(game.window.get_mapping_markers().row_count(), 1);
        game.window.set_frame_quarter(1);
        game.window.invoke_map_rotation_changed();
        assert_eq!(game.window.get_mapping_markers().row_count(), 0);
        assert!(!game.window.invoke_mapped_key("a".into(), true));
        game.window.set_frame_quarter(0);
        game.window.invoke_map_rotation_changed();
        assert_eq!(game.window.get_mapping_markers().row_count(), 1);
        // Without a live device session, no input is consumed or sent.
        assert!(!game.window.invoke_mapped_key("a".into(), true));
        game.window.invoke_map_action("toggle".into());
        assert!(!game.window.get_mapping_enabled());
        assert!(!game.window.invoke_mapped_key("a".into(), true));
        game.window.set_shortcut_capture(2);
        assert!(
            game.window
                .invoke_command_shortcut("k".into(), true, false, true, false)
        );
        assert_eq!(game.window.get_shortcut_capture(), -1);
        assert_eq!(game.window.get_shortcut_sidebar(), "⇧⌘K");
        assert_eq!(
            game_shortcuts::load(&paths.data, id).unwrap().bindings[2].key,
            "K"
        );
        // Changing a host shortcut does not mutate the saved game mapping.
        assert_eq!(keymap::load(&paths.data, id).unwrap().bindings.len(), 1);

        // Reopening an existing game window raises it and removes a legacy tab.
        ctx.state.borrow_mut().tabs.push(id);
        ctx.state.borrow_mut().active = Some(0);
        ctx.game_windows.borrow_mut().insert(id, game.clone());
        open(&ctx, id);
        assert!(!ctx.state.borrow().tabs.contains(&id));
        assert!(ctx.game_windows.borrow().contains_key(&id));
        open(&ctx, id);
        assert!(ctx.game_windows.borrow().contains_key(&id));
        assert!(ctx.state.borrow().tabs.is_empty());
    }

    #[test]
    fn editing_captures_position_and_key_without_touching_android() {
        use slint::platform::{PointerEventButton, WindowEvent};
        crate::offscreen::init().unwrap();
        let window = GameWindow::new().unwrap();
        window.show().unwrap();
        window.set_mapping_edit(true);
        crate::offscreen::render(window.window(), 372, 752).unwrap();
        let places = Rc::new(RefCell::new(Vec::new()));
        let captured = places.clone();
        window.on_map_place(move |x, y| captured.borrow_mut().push((x, y)));
        let edits = Rc::new(RefCell::new(Vec::new()));
        let captured = edits.clone();
        window.on_map_key(move |key| captured.borrow_mut().push(key.to_string()));
        let touches = Rc::new(Cell::new(0));
        let captured = touches.clone();
        window.on_pointer(move |_, _, _, _, _| captured.set(captured.get() + 1));
        let position = slint::LogicalPosition::new(81.0, 212.0);
        window.window().dispatch_event(WindowEvent::PointerPressed {
            position,
            button: PointerEventButton::Left,
        });
        window
            .window()
            .dispatch_event(WindowEvent::PointerReleased {
                position,
                button: PointerEventButton::Left,
            });
        window
            .window()
            .dispatch_event(WindowEvent::KeyPressed { text: "a".into() });
        window
            .window()
            .dispatch_event(WindowEvent::KeyReleased { text: "a".into() });
        assert_eq!(touches.get(), 0);
        assert_eq!(edits.borrow().as_slice(), ["a"]);
        assert!((places.borrow()[0].0 - 0.25).abs() < 0.01);
        assert!((places.borrow()[0].1 - 0.25).abs() < 0.01);
        window.set_mapping_markers(ModelRc::new(VecModel::from(vec![crate::KeyMarker {
            label: "A".into(),
            x: 0.25,
            y: 0.25,
        }])));
        crate::offscreen::render(window.window(), 372, 752).unwrap();
        let removed = Rc::new(Cell::new(0));
        let captured = removed.clone();
        window.on_map_remove(move |_, _, _, _| captured.set(captured.get() + 1));
        window.window().dispatch_event(WindowEvent::PointerPressed {
            position,
            button: PointerEventButton::Right,
        });
        window
            .window()
            .dispatch_event(WindowEvent::PointerReleased {
                position,
                button: PointerEventButton::Right,
            });
        assert_eq!(removed.get(), 1);
        assert_eq!(touches.get(), 0);
    }

    #[test]
    fn text_panel_accepts_unicode_without_triggering_game_mapping() {
        use slint::platform::WindowEvent;
        crate::offscreen::init().unwrap();
        let window = GameWindow::new().unwrap();
        window.show().unwrap();
        window.set_mapping_enabled(true);
        window.set_text_panel(true);
        crate::offscreen::render(window.window(), 372, 752).unwrap();
        let mapped = Rc::new(Cell::new(0));
        let captured = mapped.clone();
        window.on_mapped_key(move |_, _| {
            captured.set(captured.get() + 1);
            true
        });
        window.window().dispatch_event(WindowEvent::KeyPressed {
            text: "你好".into(),
        });
        assert_eq!(window.get_composed_text(), "你好");
        assert_eq!(mapped.get(), 0);
    }

    #[test]
    fn inline_input_focus_forwards_hardware_keys() {
        use slint::platform::{PointerEventButton, WindowEvent};
        crate::offscreen::init().unwrap();
        let window = GameWindow::new().unwrap();
        window.show().unwrap();
        crate::offscreen::render(window.window(), 372, 752).unwrap();
        let events = Rc::new(RefCell::new(Vec::new()));
        let captured = events.clone();
        window.on_key(move |key, down| captured.borrow_mut().push((key.to_string(), down)));
        let position = slint::LogicalPosition::new(100.0, 400.0);
        window.window().dispatch_event(WindowEvent::PointerPressed {
            position,
            button: PointerEventButton::Left,
        });
        window
            .window()
            .dispatch_event(WindowEvent::PointerReleased {
                position,
                button: PointerEventButton::Left,
            });
        window
            .window()
            .dispatch_event(WindowEvent::KeyPressed { text: "a".into() });
        window
            .window()
            .dispatch_event(WindowEvent::KeyReleased { text: "a".into() });
        assert_eq!(
            &*events.borrow(),
            &[("a".to_string(), true), ("a".to_string(), false)]
        );
    }

    #[test]
    fn smooth_quality_requests_fewer_pixels_in_both_orientations() {
        for screen in [
            Screen {
                width: 1080,
                height: 2400,
            },
            Screen {
                width: 2400,
                height: 1080,
            },
        ] {
            let logical = (screen.width as f32 / 2.0, screen.height as f32 / 2.0);
            let clear = quality_request_size(logical, 2.0, screen, 1);
            let smooth = quality_request_size(logical, 2.0, screen, 0);
            let economy = quality_request_size(logical, 2.0, screen, 2);
            assert!(smooth.0 < clear.0 && smooth.1 < clear.1);
            assert!(economy.0 < smooth.0 && economy.1 < smooth.1);
        }
    }

    #[test]
    fn memory_measurement_uses_bound_device_and_does_not_guess() {
        let id = Uuid::new_v4();
        let other = Uuid::new_v4();
        let sample = json!({"devices": [{"id": other, "measured_mb": 200}, {"id": id, "measured_mb": 4096}]});
        assert_eq!(measured_memory(&sample, id), Some(4096));
        assert_eq!(measured_memory(&sample, Uuid::new_v4()), None);
        assert_eq!(
            measured_memory(&json!({"devices": [{"id": id, "expected_mb": 4096}]}), id),
            None
        );
    }

    #[test]
    fn aggregate_command_state_drives_text_shortcuts_and_releases_cleanly() {
        use slint::platform::WindowEvent;
        crate::offscreen::init().unwrap();
        let window = GameWindow::new().unwrap();
        window.show().unwrap();
        window.set_text_panel(true);
        crate::offscreen::render(window.window(), 372, 752).unwrap();
        window
            .window()
            .dispatch_event(WindowEvent::KeyPressed { text: "abc".into() });
        let none = [false; 4];
        let command = [true, false, false, false];
        dispatch_modifiers(window.window(), none, command);
        window
            .window()
            .dispatch_event(WindowEvent::KeyPressed { text: "a".into() });
        window
            .window()
            .dispatch_event(WindowEvent::KeyReleased { text: "a".into() });
        dispatch_modifiers(window.window(), command, none);
        window
            .window()
            .dispatch_event(WindowEvent::KeyPressed { text: "z".into() });
        assert_eq!(window.get_composed_text(), "z");
        assert!(modifier_changes(none, none).is_empty());
    }

    #[test]
    fn open_text_panel_never_sends_screen_key_presses_to_android() {
        use slint::platform::{PointerEventButton, WindowEvent};
        crate::offscreen::init().unwrap();
        let window = GameWindow::new().unwrap();
        window.show().unwrap();
        window.set_text_panel(true);
        crate::offscreen::render(window.window(), 372, 752).unwrap();
        let presses = Rc::new(Cell::new(0));
        let captured = presses.clone();
        window.on_key(move |_, down| {
            if down {
                captured.set(captured.get() + 1);
            }
        });
        let position = slint::LogicalPosition::new(100.0, 400.0);
        window.window().dispatch_event(WindowEvent::PointerPressed {
            position,
            button: PointerEventButton::Left,
        });
        window
            .window()
            .dispatch_event(WindowEvent::PointerReleased {
                position,
                button: PointerEventButton::Left,
            });
        window
            .window()
            .dispatch_event(WindowEvent::KeyPressed { text: "a".into() });
        assert_eq!(presses.get(), 0);
    }
    #[test]
    fn portrait_and_landscape_keep_long_side_and_toolbar() {
        let portrait = window_size(
            Screen {
                width: 1080,
                height: 2400,
            },
            720.0,
            true,
        );
        let landscape = window_size(
            Screen {
                width: 2400,
                height: 1080,
            },
            720.0,
            true,
        );
        assert_eq!(portrait, (372.0, 752.0));
        assert_eq!(landscape, (768.0, 356.0));
        assert_eq!(
            window_size(
                Screen {
                    width: 1080,
                    height: 2400
                },
                720.0,
                false
            ),
            (324.0, 752.0)
        );
        let saved = WindowState {
            version: 1,
            width: 768.0,
            height: 356.0,
            x: 0,
            y: 0,
            sidebar: true,
            on_top: false,
            landscape: true,
            quality: 1,
        };
        assert_eq!(
            restored_size(
                &saved,
                Screen {
                    width: 1080,
                    height: 2400
                }
            ),
            (372.0, 752.0)
        );
    }

    #[test]
    fn game_window_maps_pointer_inside_screen_in_both_orientations() {
        use slint::platform::{PointerEventButton, WindowEvent};
        use std::cell::RefCell;
        crate::offscreen::init().unwrap();
        let window = GameWindow::new().unwrap();
        window.show().unwrap();
        let events = Rc::new(RefCell::new(Vec::new()));
        let captured = events.clone();
        window.on_pointer(move |kind, x, y, _, _| captured.borrow_mut().push((kind, x, y)));
        for (width, height, frame_w, frame_h, x, y) in [
            (372, 752, 1080, 2400, 81.0, 212.0),
            (768, 356, 2400, 1080, 180.0, 113.0),
        ] {
            window.set_frame_w(frame_w);
            window.set_frame_h(frame_h);
            crate::offscreen::render(window.window(), width, height).unwrap();
            let position = slint::LogicalPosition::new(x, y);
            window.window().dispatch_event(WindowEvent::PointerPressed {
                position,
                button: PointerEventButton::Left,
            });
            window
                .window()
                .dispatch_event(WindowEvent::PointerReleased {
                    position,
                    button: PointerEventButton::Left,
                });
            let captured = events.borrow();
            let down = captured[captured.len() - 2];
            assert_eq!(down.0, 0);
            assert!((down.1 - 0.25).abs() < 0.01, "x = {}", down.1);
            assert!((down.2 - 0.25).abs() < 0.01, "y = {}", down.2);
        }
        window.set_frame_w(1080);
        window.set_frame_h(2400);
        crate::offscreen::render(window.window(), 800, 752).unwrap();
        let before = events.borrow().len();
        let margin = slint::LogicalPosition::new(20.0, 250.0);
        window.window().dispatch_event(WindowEvent::PointerPressed {
            position: margin,
            button: PointerEventButton::Left,
        });
        window
            .window()
            .dispatch_event(WindowEvent::PointerReleased {
                position: margin,
                button: PointerEventButton::Left,
            });
        assert_eq!(
            events.borrow().len(),
            before,
            "letterbox must not forward touches"
        );
        // A second device window must never send input to the first one.
        let first_count = events.borrow().len();
        let other = GameWindow::new().unwrap();
        other.show().unwrap();
        let second_events = Rc::new(RefCell::new(Vec::new()));
        let captured = second_events.clone();
        other.on_pointer(move |kind, x, y, _, _| captured.borrow_mut().push((kind, x, y)));
        crate::offscreen::render(other.window(), 372, 752).unwrap();
        let position = slint::LogicalPosition::new(81.0, 212.0);
        other.window().dispatch_event(WindowEvent::PointerPressed {
            position,
            button: PointerEventButton::Left,
        });
        other.window().dispatch_event(WindowEvent::PointerReleased {
            position,
            button: PointerEventButton::Left,
        });
        assert_eq!(events.borrow().len(), first_count);
        assert_eq!(second_events.borrow().len(), 2);
    }

    #[test]
    fn sidebar_starts_at_top_and_can_be_hidden_and_restored() {
        use slint::platform::{PointerEventButton, WindowEvent};
        crate::offscreen::init().unwrap();
        let window = GameWindow::new().unwrap();
        window.show().unwrap();
        let tools = Rc::new(RefCell::new(Vec::new()));
        let captured = tools.clone();
        window.on_tool(move |tool| captured.borrow_mut().push(tool.to_string()));
        let weak = window.as_weak();
        window.on_sidebar_changed(move |visible| {
            if let Some(window) = weak.upgrade() {
                resize_sidebar(&window, visible);
            }
        });
        crate::offscreen::render(window.window(), 372, 752).unwrap();
        let click = |x, y| {
            let position = slint::LogicalPosition::new(x, y);
            window.window().dispatch_event(WindowEvent::PointerPressed {
                position,
                button: PointerEventButton::Left,
            });
            window
                .window()
                .dispatch_event(WindowEvent::PointerReleased {
                    position,
                    button: PointerEventButton::Left,
                });
        };
        click(348.0, 52.0);
        assert_eq!(tools.borrow().as_slice(), ["back"]);
        click(348.0, 16.0);
        assert!(!window.get_sidebar_visible());
        assert_eq!(window.window().size().width, 324);
        crate::offscreen::render(window.window(), 324, 752).unwrap();
        click(300.0, 16.0);
        assert!(window.get_sidebar_visible());
        assert_eq!(window.window().size().width, 372);
        window.set_game_fullscreen(true);
        crate::offscreen::render(window.window(), 372, 720).unwrap();
        click(348.0, 52.0);
        assert_eq!(tools.borrow().as_slice(), ["back", "back"]);
        click(348.0, 16.0);
        assert!(!window.get_sidebar_visible());
        crate::offscreen::render(window.window(), 324, 720).unwrap();
        click(300.0, 16.0);
        assert!(window.get_sidebar_visible());
    }

    #[test]
    fn command_editing_shortcuts_reach_only_the_game_shortcut_handler() {
        use slint::platform::{Key, PointerEventButton, WindowEvent};
        crate::offscreen::init().unwrap();
        let window = GameWindow::new().unwrap();
        window.show().unwrap();
        crate::offscreen::render(window.window(), 372, 752).unwrap();
        let shortcuts = Rc::new(RefCell::new(Vec::new()));
        let captured = shortcuts.clone();
        window.on_edit_shortcut(move |text, shift| {
            captured.borrow_mut().push((text.to_string(), shift))
        });
        let keys = Rc::new(RefCell::new(Vec::new()));
        let captured = keys.clone();
        window.on_key(move |text, down| captured.borrow_mut().push((text.to_string(), down)));
        let pos = slint::LogicalPosition::new(81.0, 212.0);
        window.window().dispatch_event(WindowEvent::PointerPressed {
            position: pos,
            button: PointerEventButton::Left,
        });
        window
            .window()
            .dispatch_event(WindowEvent::PointerReleased {
                position: pos,
                button: PointerEventButton::Left,
            });
        let cmd: slint::SharedString = Key::Control.into();
        window
            .window()
            .dispatch_event(WindowEvent::KeyPressed { text: cmd.clone() });
        window
            .window()
            .dispatch_event(WindowEvent::KeyPressed { text: "c".into() });
        window
            .window()
            .dispatch_event(WindowEvent::KeyReleased { text: "c".into() });
        window
            .window()
            .dispatch_event(WindowEvent::KeyReleased { text: cmd });
        assert_eq!(shortcuts.borrow().as_slice(), [("c".to_string(), false)]);
        assert!(!keys.borrow().iter().any(|(text, _)| text == "c"));
        let cmd: slint::SharedString = Key::Control.into();
        let shift: slint::SharedString = Key::Shift.into();
        window
            .window()
            .dispatch_event(WindowEvent::KeyPressed { text: cmd.clone() });
        window.window().dispatch_event(WindowEvent::KeyPressed {
            text: shift.clone(),
        });
        window
            .window()
            .dispatch_event(WindowEvent::KeyPressed { text: "Z".into() });
        window
            .window()
            .dispatch_event(WindowEvent::KeyReleased { text: "Z".into() });
        window
            .window()
            .dispatch_event(WindowEvent::KeyReleased { text: shift });
        window
            .window()
            .dispatch_event(WindowEvent::KeyReleased { text: cmd });
        assert_eq!(
            shortcuts.borrow().as_slice(),
            [("c".to_string(), false), ("Z".to_string(), true)]
        );
    }
}
