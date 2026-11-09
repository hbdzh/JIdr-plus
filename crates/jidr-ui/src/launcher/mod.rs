//! Launcher wiring: selection, tabs, lifecycle actions, the create/edit
//! sheet, the command palette and the confirmation dialog.

use std::rc::Rc;

use jidr_core::{HardwareProfile, SystemImage};
use serde_json::{Value, json};
use slint::{ComponentHandle, ModelRc, VecModel};
use uuid::Uuid;

use crate::app::{Ctx, report, toast};
use crate::device_form;
use crate::{DeviceForm, PaletteItem, RootChoice};

fn models<T: Clone + 'static>(v: Vec<T>) -> ModelRc<T> {
    ModelRc::new(VecModel::from(v))
}

fn choose_apk() -> Result<Option<std::path::PathBuf>, String> {
    #[cfg(target_os = "macos")]
    {
        let out = std::process::Command::new("osascript")
            .args([
                "-e",
                "POSIX path of (choose file with prompt \"Choose an APK to install\")",
            ])
            .output()
            .map_err(|e| e.to_string())?;
        if !out.status.success() {
            let error = String::from_utf8_lossy(&out.stderr);
            if error.contains("-128") {
                return Ok(None);
            }
            return Err(format!(
                "{} {error}",
                crate::i18n::text("Can't choose an APK:", "无法选择 APK：")
            ));
        }
        let path = std::path::PathBuf::from(
            String::from_utf8(out.stdout)
                .map_err(|e| e.to_string())?
                .trim_end_matches(['\r', '\n']),
        );
        if !path
            .extension()
            .is_some_and(|ext| ext.eq_ignore_ascii_case("apk"))
        {
            return Err(crate::i18n::text("Choose an APK file.", "请选择 APK 文件。").into());
        }
        Ok(Some(path))
    }
    #[cfg(not(target_os = "macos"))]
    Err(crate::i18n::text(
        "The file picker is only available on macOS.",
        "文件选择器仅支持 macOS。",
    )
    .into())
}

fn choose_file() -> Result<Option<std::path::PathBuf>, String> {
    #[cfg(target_os = "macos")]
    {
        let prompt = crate::i18n::text(
            "Choose a file to send to the device",
            "选择要发送到设备的文件",
        );
        let out = std::process::Command::new("osascript")
            .args([
                "-e",
                "on run argv",
                "-e",
                "POSIX path of (choose file with prompt (item 1 of argv))",
                "-e",
                "end run",
                prompt,
            ])
            .output()
            .map_err(|e| e.to_string())?;
        if !out.status.success() {
            let error = String::from_utf8_lossy(&out.stderr);
            if error.contains("-128") {
                return Ok(None);
            }
            return Err(error.trim().to_owned());
        }
        let path = std::path::PathBuf::from(
            String::from_utf8(out.stdout)
                .map_err(|e| e.to_string())?
                .trim_end_matches(['\r', '\n']),
        );
        if !path.is_file() {
            return Err(crate::i18n::text("Choose a local file.", "请选择本地文件。").into());
        }
        Ok(Some(path))
    }
    #[cfg(not(target_os = "macos"))]
    Err(crate::i18n::text(
        "The file picker is only available on macOS.",
        "文件选择器仅支持 macOS。",
    )
    .into())
}

pub fn wire(ctx: &Rc<Ctx>) {
    let app = &ctx.app;
    let weak = app.as_weak();

    let c = ctx.clone();
    app.on_select_device(move |i| {
        let Some(id) = c.device_id(i) else { return };
        if c.state.borrow().selected == Some(id) {
            return;
        }
        c.state.borrow_mut().selected = Some(id);
        // Keep the device model intact: replacing it between clicks destroys
        // the row that must receive the second click of a double-click.
        c.app.set_selected(i);
        crate::snapshots::load(&c);
        crate::game_library::sync(&c);
        crate::recording::show(&c, crate::player::active_id(&c));
        crate::root::sync(&c);
    });

    let c = ctx.clone();
    app.on_open_device(move |i| {
        if let Some(id) = c.device_id(i) {
            crate::player::game::open(&c, id);
        }
    });

    let c = ctx.clone();
    app.on_game_device(move |i| {
        if let Some(id) = c.device_id(i) {
            crate::player::game::open(&c, id);
        }
    });

    let c = ctx.clone();
    app.on_refresh_games(move || crate::game_library::refresh(&c));
    let c = ctx.clone();
    app.on_launch_game(move |package| crate::game_library::launch(&c, package.as_str()));

    let c = ctx.clone();
    app.on_install_apk(move |i| {
        let Some(id) = c.device_id(i) else { return };
        if !c
            .info(id)
            .is_some_and(|info| matches!(info.device.status, jidr_core::DeviceStatus::Running))
        {
            toast(
                &c.app.as_weak(),
                crate::i18n::text(
                    "Start the device before installing an APK.",
                    "请先启动设备，再安装 APK。",
                )
                .into(),
            );
            return;
        }
        std::thread::spawn(move || {
            let result = choose_apk();
            let _ = slint::invoke_from_event_loop(move || {
                let Some(ctx) = crate::app::ctx() else { return };
                match result {
                    Ok(Some(path)) => {
                        if ctx.info(id).is_some_and(|info| {
                            matches!(info.device.status, jidr_core::DeviceStatus::Running)
                        }) {
                            crate::player::install_apk(&ctx, id, path, false);
                        } else {
                            toast(
                                &ctx.app.as_weak(),
                                crate::i18n::text(
                                    "The device is no longer running.",
                                    "设备已停止运行。",
                                )
                                .into(),
                            );
                        }
                    }
                    Ok(None) => {}
                    Err(error) => toast(&ctx.app.as_weak(), error),
                }
            });
        });
    });

    let c = ctx.clone();
    app.on_screenshots_folder(move || {
        let Some(home) = dirs::home_dir() else {
            toast(
                &c.app.as_weak(),
                crate::i18n::text("Can't find the screenshots folder.", "无法找到截图目录。")
                    .into(),
            );
            return;
        };
        let path = home.join("Pictures").join("Jidr");
        let result = std::fs::create_dir_all(&path).and_then(|()| {
            std::process::Command::new("open")
                .arg(&path)
                .spawn()
                .map(|_| ())
        });
        if let Err(error) = result {
            toast(
                &c.app.as_weak(),
                format!(
                    "{} {error}",
                    crate::i18n::text("Can't open screenshots:", "无法打开截图目录：")
                ),
            );
        }
    });

    let c = ctx.clone();
    app.on_send_file(move |i| {
        let Some(id) = c.device_id(i) else { return };
        if !c
            .info(id)
            .is_some_and(|info| matches!(info.device.status, jidr_core::DeviceStatus::Running))
        {
            return;
        }
        std::thread::spawn(move || {
            let result = choose_file();
            let _ = slint::invoke_from_event_loop(move || {
                let Some(ctx) = crate::app::ctx() else { return };
                match result {
                    Ok(Some(path))
                        if ctx.info(id).is_some_and(|info| {
                            matches!(info.device.status, jidr_core::DeviceStatus::Running)
                        }) =>
                    {
                        let name = crate::recording::file_name(&path.to_string_lossy());
                        let text = format!(
                            "{} {name} {}",
                            crate::i18n::text("Sent", "已发送"),
                            crate::i18n::text("to device Downloads", "到设备下载目录")
                        );
                        ctx.bridge.call(
                            "file.push",
                            json!({"device": id, "local": path}),
                            report(&ctx.app.as_weak(), text),
                        );
                    }
                    Ok(Some(_)) => crate::app::toast_error(
                        &ctx.app.as_weak(),
                        crate::i18n::text("The device is no longer running.", "设备已停止运行。")
                            .into(),
                    ),
                    Ok(None) => {}
                    Err(error) => crate::app::toast_error(&ctx.app.as_weak(), error),
                }
            });
        });
    });
    let c = ctx.clone();
    app.on_center_screenshot(move |i| {
        if let Some(id) = c.device_id(i)
            && c.info(id)
                .is_some_and(|info| matches!(info.device.status, jidr_core::DeviceStatus::Running))
        {
            crate::recording::screenshot(&c, id);
        }
    });
    let c = ctx.clone();
    app.on_center_record(move |i| {
        if let Some(id) = c.device_id(i)
            && c.info(id)
                .is_some_and(|info| matches!(info.device.status, jidr_core::DeviceStatus::Running))
        {
            crate::recording::toggle(&c, id);
        }
    });

    let c = ctx.clone();
    app.on_edit_device(move |i| {
        if let Some(id) = c.device_id(i) {
            edit_device(&c, id);
        }
    });

    let c = ctx.clone();
    app.on_shortcut(move |s| {
        crate::player::shortcut(&c, s.as_str());
    });

    let c = ctx.clone();
    app.on_start_device(move |i| {
        if let Some(id) = c.device_id(i) {
            start(&c, id);
        }
    });

    let c = ctx.clone();
    app.on_stop_device(move |i| {
        if let Some(id) = c.device_id(i) {
            stop(&c, id);
        }
    });

    let c = ctx.clone();
    let w = weak.clone();
    app.on_cancel_job(move |i| {
        let job = {
            let st = c.state.borrow();
            usize::try_from(i)
                .ok()
                .and_then(|i| st.data.jobs.get(i))
                .map(|j| j.id)
        };
        if let Some(job) = job {
            c.bridge.call(
                "jobs.cancel",
                json!({ "job": job }),
                report(&w, crate::i18n::text("Cancelled", "已取消")),
            );
        }
    });

    let c = ctx.clone();
    let w = weak.clone();
    app.on_verify_root(move |i| {
        if let Some(id) = c.device_id(i) {
            c.bridge.run(
                "root.verify",
                json!({ "device": id }),
                |_| {},
                report(&w, crate::i18n::text("Root verified", "Root 已验证")),
            );
        }
    });

    let c = ctx.clone();
    app.on_revert_root(move |i| {
        let Some(id) = c.device_id(i) else { return };
        let name = c.info(id).map(|d| d.device.name).unwrap_or_default();
        let c2 = c.clone();
        confirm(
            &c,
            &format!("{} {name}{}", crate::i18n::text("Revert", "将"), crate::i18n::text(" to unrooted?", "恢复为未 root 状态？")),
            crate::i18n::text("Removes root and cold boots the device (about 40 s). Apps and data stay. Snapshots taken with root can't be restored until root is set up again.", "移除 root 并冷启动设备（约 40 秒），应用和数据会保留。重新设置 root 前无法恢复 root 状态下创建的快照。"),
            crate::i18n::text("Revert", "恢复"),
            move || {
                let w = c2.app.as_weak();
                c2.bridge.run(
                    "root.set",
                    json!({ "device": id, "mode": "none" }),
                    |_| {},
                    report(&w, &format!("Reverted {name} to unrooted")),
                );
            },
        );
    });

    let c = ctx.clone();
    app.on_restart_device(move |i| {
        if let Some(id) = c.device_id(i) {
            run_named_device_action(&c, "restart", id);
        }
    });

    let c = ctx.clone();
    app.on_delete_device(move |i| {
        if let Some(id) = c.device_id(i) {
            run_named_device_action(&c, "delete", id);
        }
    });

    let c = ctx.clone();
    app.on_new_device(move || new_device(&c));

    let c = ctx.clone();
    app.on_cancel_form(move || {
        c.app.set_sheet_open(false);
        c.catalog.borrow_mut().editing = None;
    });

    let c = ctx.clone();
    app.on_form_image_changed(move |i| {
        let mut form = c.app.get_form();
        let preferred = c.prefs.borrow().root_choice();
        let cat = c.catalog.borrow();
        if let Some(img) = usize::try_from(i).ok().and_then(|i| cat.images.get(i)) {
            if !img.image.allows_adb_root() && form.root == RootChoice::Shell {
                form.root = RootChoice::None;
            } else if img.image.allows_adb_root() && form.root == RootChoice::None {
                form.root = device_form::default_root(Some(img), preferred);
            }
        }
        form.image = i;
        c.app.set_form(form);
    });

    let c = ctx.clone();
    app.on_form_profile_changed(move |i| {
        let Ok(index) = usize::try_from(i) else {
            return;
        };
        let mut form = c.app.get_form();
        if form.edit {
            return;
        }
        let catalog = c.catalog.borrow();
        if index >= catalog.profiles.len() {
            return;
        }
        device_form::apply_profile(&mut form, &catalog.profiles, index);
        c.app.set_form(form);
    });

    let c = ctx.clone();
    app.on_form_cold_start(move || {
        let Some(id) = c.catalog.borrow().editing else { return };
        if !c.app.get_form().can_cold_start {
            return;
        }
        let next = c.clone();
        confirm(
            &c,
            crate::i18n::text("Cold boot this device?", "立即冷启动设备？"),
            crate::i18n::text(
                "Unsaved settings will be discarded. The old quick-boot snapshot is copied before startup; unsaved game state may be lost.",
                "本页未保存的设置将丢弃。启动前会复制原快速启动快照，游戏中未保存的进度可能丢失。",
            ),
            crate::i18n::text("Cold boot", "冷启动"),
            move || {
                next.app.set_sheet_open(false);
                next.catalog.borrow_mut().editing = None;
                let weak = next.app.as_weak();
                next.bridge.run("device.start", json!({"device": id, "cold_boot": true}), |_| {}, report(&weak, ""));
            },
        );
    });

    let c = ctx.clone();
    app.on_form_manage_snapshots(move || {
        let next = c.clone();
        confirm(
            &c,
            crate::i18n::text("Open snapshots?", "打开快照管理？"),
            crate::i18n::text(
                "Unsaved settings will be discarded.",
                "本页未保存的设置将丢弃。",
            ),
            crate::i18n::text("Open snapshots", "打开快照"),
            move || {
                next.app.set_sheet_open(false);
                next.catalog.borrow_mut().editing = None;
                next.app.invoke_manage_snapshots(next.app.get_selected());
            },
        );
    });

    let c = ctx.clone();
    app.on_submit_form(move |form| submit(&c, form));

    let c = ctx.clone();
    app.on_open_palette(move || open_palette(&c, ""));

    let c = ctx.clone();
    app.on_palette_query_changed(move |q| {
        let all = palette_items(&c);
        c.app
            .set_palette_items(models(crate::palette::filter(&all, &q)));
    });

    let c = ctx.clone();
    app.on_palette_run(move |item| run_palette(&c, &item));

    let c = ctx.clone();
    app.on_confirm_ok(move || {
        if let Some(f) = c.pending_confirm.borrow_mut().take() {
            f();
        }
    });

    let c = ctx.clone();
    app.on_open_settings(move || crate::settings::open(&c, 0));

    let c = ctx.clone();
    app.on_setup_sdk(move || crate::wizard::open(&c));
    let c = ctx.clone();
    app.on_use_existing_sdk(move || crate::wizard::open(&c));

    let w = weak.clone();
    app.on_drag_window(move || {
        if let Some(app) = w.upgrade() {
            use slint::winit_030::WinitWindowAccessor;
            app.window().with_winit_window(|win| {
                let _ = win.drag_window();
            });
        }
    });
}

/// Remove only this device's tab, retaining the selection of other tabs.
pub(crate) fn remove_device_tab(c: &Rc<Ctx>, id: Uuid) {
    let removed = remove_tab_for_device(&mut c.state.borrow_mut(), id);
    if removed {
        c.rerender();
    }
}

fn remove_tab_for_device(st: &mut crate::app::State, id: Uuid) -> bool {
    let Some(index) = st.tabs.iter().position(|device| *device == id) else {
        return false;
    };
    st.tabs.remove(index);
    st.active = match st.active {
        Some(active) if active == index => None,
        Some(active) if active > index => Some(active - 1),
        active => active,
    };
    true
}

pub fn start(c: &Rc<Ctx>, id: Uuid) {
    if !c.pending_window_opens.borrow_mut().insert(id) {
        return;
    }
    let token = crate::app::defer(move |result: jidr_core::JidrResult<Value>| {
        let Some(c) = crate::app::ctx() else { return };
        match result {
            Ok(_) => open_ready_devices(&c),
            Err(error) => {
                c.pending_window_opens.borrow_mut().remove(&id);
                crate::app::toast_error(&c.app.as_weak(), error.message);
            }
        }
    });
    c.bridge.run(
        "device.start",
        json!({ "device": id }),
        |_| {},
        move |result| crate::app::fire(token, result),
    );
}

/// Open only the devices that this window asked to start, once their details arrive.
pub fn open_ready_devices(c: &Rc<Ctx>) {
    let ready: Vec<_> = c
        .pending_window_opens
        .borrow()
        .iter()
        .copied()
        .filter(|id| {
            c.info(*id).is_some_and(|info| {
                matches!(info.device.status, jidr_core::DeviceStatus::Running)
                    && info.width > 0
                    && info.height > 0
            })
        })
        .collect();
    for id in ready {
        c.pending_window_opens.borrow_mut().remove(&id);
        crate::player::game::open(c, id);
    }
}

pub fn stop(c: &Rc<Ctx>, id: Uuid) {
    let w = c.app.as_weak();
    c.bridge
        .call("device.stop", json!({ "device": id }), report(&w, ""));
}

/// Shows the confirmation dialog; `ok` runs on confirm.
pub fn confirm(c: &Rc<Ctx>, title: &str, body: &str, action: &str, ok: impl Fn() + 'static) {
    *c.pending_confirm.borrow_mut() = Some(Box::new(ok));
    c.app.set_confirm_title(title.into());
    c.app.set_confirm_body(body.into());
    c.app.set_confirm_action(action.into());
    c.app.set_confirm_open(true);
}

/// Loads profiles and images, then calls `then` on the UI thread.
fn load_catalog(c: &Rc<Ctx>, then: impl FnOnce(&Rc<Ctx>) + 'static) {
    let bridge = c.bridge.clone();
    let b2 = bridge.clone();
    let c2 = c.clone();
    let token = crate::app::defer(
        move |(profiles, images): (Vec<HardwareProfile>, Vec<SystemImage>)| {
            {
                let mut cat = c2.catalog.borrow_mut();
                cat.profiles = profiles;
                cat.images = device_form::sorted_images(&images);
            }
            then(&c2);
        },
    );
    bridge.call("profile.list", json!({}), move |p| {
        let profiles: Vec<HardwareProfile> = p
            .ok()
            .and_then(|v| serde_json::from_value(v).ok())
            .unwrap_or_default();
        b2.call("image.list", json!({}), move |i| {
            let images: Vec<SystemImage> = i
                .ok()
                .and_then(|v| serde_json::from_value(v).ok())
                .unwrap_or_default();
            crate::app::fire(token, (profiles, images));
        });
    });
}

fn new_device(c: &Rc<Ctx>) {
    load_catalog(c, |c| {
        let taken: Vec<String> = c
            .state
            .borrow()
            .data
            .devices
            .iter()
            .map(|d| d.device.name.clone())
            .collect();
        let preferred = c.prefs.borrow().root_choice();
        let jobs = c.state.borrow().data.jobs.clone();
        let cat = c.catalog.borrow();
        let form = device_form::new_form(&cat.profiles, &cat.images, &taken, preferred);
        c.app
            .set_profiles(models(device_form::profile_options(&cat.profiles)));
        c.app
            .set_images(models(device_form::image_rows(&cat.images, &jobs)));
        c.app.set_form(form);
        c.app.set_sheet_open(true);
        drop(cat);
        c.catalog.borrow_mut().editing = None;
    });
}

pub fn edit_device(c: &Rc<Ctx>, id: Uuid) {
    if !c.info(id).is_some_and(|info| {
        info.width > 0 && info.height > 0 && info.density > 0 && info.ram_mb > 0 && info.cpus > 0
    }) {
        toast(
            &c.app.as_weak(),
            crate::i18n::text(
                "Device settings are still loading; try again shortly.",
                "设备设置仍在加载，请稍后重试。",
            )
            .into(),
        );
        return;
    }
    load_catalog(c, move |c| {
        let Some(info) = c.info(id) else { return };
        let cat = c.catalog.borrow();
        c.app
            .set_profiles(models(device_form::profile_options(&cat.profiles)));
        let mut form = device_form::edit_form(&info, &cat.profiles);
        match crate::player::window_state::load_quality(&c.paths.data, id) {
            Ok(quality) => form.stream_quality = i32::from(quality),
            Err(error) => {
                form.stream_quality = -1;
                form.error = error.into();
            }
        }
        form.data_path = c
            .paths
            .avd_home()
            .join(format!("{}.avd", info.device.avd))
            .to_string_lossy()
            .into_owned()
            .into();
        c.app.set_form(form);
        c.app.set_device_edit_page(0);
        c.app.set_sheet_open(true);
        drop(cat);
        c.catalog.borrow_mut().editing = Some(id);
    });
}

fn set_form_error(c: &Rc<Ctx>, msg: String) {
    let mut f = c.app.get_form();
    f.error = msg.into();
    c.app.set_form(f);
}

fn submit(c: &Rc<Ctx>, form: DeviceForm) {
    let editing = c.catalog.borrow().editing;
    let w = c.app.as_weak();
    if let Some(id) = editing {
        let Some(info) = c.info(id) else { return };
        match device_form::edit_params(&form, &info) {
            Err(e) => set_form_error(c, e),
            Ok(params) => {
                if form.saving {
                    return;
                }
                let quality = match u8::try_from(form.stream_quality) {
                    Ok(value) if value <= 2 => value,
                    _ => {
                        return set_form_error(
                            c,
                            crate::i18n::text(
                                "Invalid game quality settings.",
                                "游戏画质设置无效。",
                            )
                            .into(),
                        );
                    }
                };
                let old_quality = match crate::player::window_state::load_quality(&c.paths.data, id)
                {
                    Ok(value) => value,
                    Err(error) => return set_form_error(c, error),
                };
                // 9e: a changed root mode runs `root.set` (Full root opens
                // the Root sheet).
                let mode = crate::root::mode_of(form.root);
                let changed = mode != info.device.root.mode;
                let mut pending = form.clone();
                pending.saving = true;
                pending.error = Default::default();
                c.app.set_form(pending);
                let c2 = c.clone();
                let name = form.name.to_string();
                let token = crate::app::defer(move |result: jidr_core::JidrResult<Value>| {
                    let current = c2.app.get_sheet_open()
                        && c2.catalog.borrow().editing == Some(id)
                        && c2.app.get_form().saving;
                    match result {
                        Ok(_) => {
                            if quality != old_quality {
                                if let Err(error) = crate::player::window_state::save_quality(
                                    &c2.paths.data,
                                    id,
                                    quality,
                                ) {
                                    if current {
                                        let mut form = c2.app.get_form();
                                        form.saving = false;
                                        form.error = format!("{} {error}", crate::i18n::text("Device settings saved; game quality could not be saved:", "设备设置已保存，但游戏画质保存失败：")).into();
                                        c2.app.set_form(form);
                                    } else {
                                        toast(&c2.app.as_weak(), error);
                                    }
                                    return;
                                }
                                if let Some(game) = c2.game_windows.borrow().get(&id) {
                                    game.set_quality(i32::from(quality));
                                }
                            }
                            if current {
                                c2.app.set_sheet_open(false);
                                c2.catalog.borrow_mut().editing = None;
                            }
                            toast(
                                &c2.app.as_weak(),
                                format!("{} {name}", crate::i18n::text("Saved", "已保存")),
                            );
                            if changed {
                                crate::root::start_later(id, mode);
                            }
                        }
                        Err(error) if current => {
                            let mut form = c2.app.get_form();
                            form.saving = false;
                            form.error = error.message.into();
                            c2.app.set_form(form);
                        }
                        Err(error) => toast(&c2.app.as_weak(), error.message),
                    }
                });
                c.bridge.call("device.edit", params, move |r| {
                    crate::app::fire(token, r);
                });
            }
        }
        return;
    }
    let cat = c.catalog.borrow();
    let params = match device_form::create_params(&form, &cat.profiles, &cat.images) {
        Ok(p) => p,
        Err(e) => {
            drop(cat);
            return set_form_error(c, e);
        }
    };
    let image = usize::try_from(form.image)
        .ok()
        .and_then(|i| cat.images.get(i))
        .cloned();
    drop(cat);
    c.app.set_sheet_open(false);
    let bridge = c.bridge.clone();
    let start = form.start_after;
    let name = form.name.to_string();
    // 9e: Full root runs `root.set magisk` after create (it boots the
    // device and opens the Root sheet) instead of a plain start.
    let full_root = crate::root::mode_of(form.root) == jidr_core::RootMode::Magisk;
    // A missing image is downloaded first and appears in the task list.
    let create = move |bridge: std::sync::Arc<crate::bridge::Bridge>,
                       w: slint::Weak<crate::AppWindow>| {
        let b2 = bridge.clone();
        bridge.call("device.create", params, move |r| match r {
            Ok(dev) => {
                toast(
                    &w,
                    format!("{} {name}", crate::i18n::text("Created", "已创建")),
                );
                if full_root
                    && let Some(id) = dev
                        .get("id")
                        .and_then(|v| v.as_str())
                        .and_then(|s| uuid::Uuid::parse_str(s).ok())
                {
                    crate::root::start_later(id, jidr_core::RootMode::Magisk);
                } else if start && let Some(id) = dev.get("id").cloned() {
                    b2.run(
                        "device.start",
                        json!({ "device": id }),
                        |_| {},
                        report(&w, ""),
                    );
                }
            }
            Err(e) => toast(&w, e.message),
        });
    };
    match image {
        Some(img) if img.installed_in.is_none() => {
            let b = bridge.clone();
            let w2 = w.clone();
            bridge.run(
                "image.install",
                json!({ "image": img.image.package() }),
                |_| {},
                move |r| match r {
                    Ok(_) => create(b, w2),
                    Err(e) => toast(&w2, e.message),
                },
            );
        }
        _ => create(bridge, w),
    }
}

fn palette_items(c: &Rc<Ctx>) -> Vec<PaletteItem> {
    use slint::Model;
    let devices: Vec<_> = c.app.get_devices().iter().collect();
    crate::palette::items(
        &devices,
        c.app.get_sdk_ready() || c.app.get_library_loading(),
    )
}

fn open_palette(c: &Rc<Ctx>, query: &str) {
    let all = palette_items(c);
    c.app.set_palette_query(query.into());
    c.app
        .set_palette_items(models(crate::palette::filter(&all, query)));
    c.app.set_palette_open(true);
}

fn run_named_device_action(c: &Rc<Ctx>, verb: &str, id: Uuid) {
    let action = format!("{verb}:{id}");
    if let Some(item) = palette_items(c)
        .into_iter()
        .find(|item| item.action == action)
    {
        run_palette(c, &item);
    }
}

fn run_palette(c: &Rc<Ctx>, item: &PaletteItem) {
    let action = item.action.to_string();
    let (verb, arg) = action.split_once(':').unwrap_or((action.as_str(), ""));
    let id = Uuid::parse_str(arg).ok();
    match (verb, id) {
        ("open", Some(id)) => {
            if let Some(info) = c.info(id) {
                match info.device.status {
                    jidr_core::DeviceStatus::Running => crate::player::game::open(c, id),
                    jidr_core::DeviceStatus::Stopped
                    | jidr_core::DeviceStatus::Hibernated
                    | jidr_core::DeviceStatus::Crashed { .. } => start(c, id),
                    _ => {}
                }
            }
        }
        ("start", Some(id)) => start(c, id),
        ("stop", Some(id)) => stop(c, id),
        ("restart", Some(id)) => {
            let next = c.clone();
            let token =
                crate::app::defer(move |result: jidr_core::JidrResult<Value>| match result {
                    Ok(_) => start(&next, id),
                    Err(error) => crate::app::toast_error(&next.app.as_weak(), error.message),
                });
            c.bridge
                .call("device.stop", json!({"device": id}), move |result| {
                    crate::app::fire(token, result);
                });
        }
        ("delete", Some(id)) => {
            let name = c.info(id).map(|info| info.device.name).unwrap_or_default();
            let next = c.clone();
            confirm(
                c,
                &format!("{} {name}？", crate::i18n::text("Delete", "删除")),
                crate::i18n::text(
                    "This permanently deletes the device, its apps, game data and snapshots.",
                    "这会永久删除设备、应用、游戏数据和快照。",
                ),
                crate::i18n::text("Delete device", "删除设备"),
                move || {
                    if !next.info(id).is_some_and(|info| {
                        matches!(
                            info.device.status,
                            jidr_core::DeviceStatus::Stopped
                                | jidr_core::DeviceStatus::Hibernated
                                | jidr_core::DeviceStatus::Crashed { .. }
                        )
                    }) {
                        toast(
                            &next.app.as_weak(),
                            crate::i18n::text(
                                "Stop the device before deleting it.",
                                "请先停止设备，再删除。",
                            )
                            .into(),
                        );
                        return;
                    }
                    next.bridge.call(
                        "device.delete",
                        json!({"device": id}),
                        report(
                            &next.app.as_weak(),
                            crate::i18n::text("Device deleted", "设备已删除"),
                        ),
                    );
                },
            );
        }
        ("edit", Some(id)) => edit_device(c, id),
        ("new", _) => new_device(c),
        ("setup", _) => crate::wizard::open(c),
        ("settings", _) => crate::settings::open(c, if arg == "agents" { 2 } else { 0 }),
        ("appearance", _) => {
            let dark = c.app.global::<crate::Theme>().get_dark();
            c.prefs.borrow_mut().appearance = if dark { 1 } else { 2 };
            let _ = c.prefs.borrow().save(&c.paths.data);
            c.apply_appearance();
        }
        _ => {}
    }
}

/// Exposed for tests: the params the sheet would send.
pub fn create_params_for(
    form: &DeviceForm,
    profiles: &[HardwareProfile],
    images: &[SystemImage],
) -> Result<Value, String> {
    device_form::create_params(form, profiles, images)
}

#[cfg(test)]
mod tab_tests {
    use super::*;

    #[test]
    fn selecting_a_device_keeps_the_row_model_for_double_clicks() {
        use std::cell::{Cell, RefCell};
        crate::offscreen::init().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let app = crate::AppWindow::new().unwrap();
        let ctx = Rc::new(Ctx {
            app: app.clone_strong(),
            bridge: crate::bridge::Bridge::new().unwrap(),
            state: Rc::default(),
            paths: jidr_core::JidrPaths::under(dir.path()),
            prefs: RefCell::default(),
            windows: RefCell::default(),
            catalog: RefCell::default(),
            pending_confirm: RefCell::default(),
            player: RefCell::default(),
            game_windows: RefCell::default(),
            pending_window_opens: RefCell::default(),
            quitting: Cell::new(false),
        });
        ctx.state.borrow_mut().data.devices = crate::fixtures::device_infos();
        let first = ctx.state.borrow().data.devices[0].device.id;
        ctx.state.borrow_mut().selected = Some(first);
        crate::app::render(&app, &ctx.state.borrow());
        wire(&ctx);
        let original = app.get_devices();
        app.invoke_select_device(1);
        assert_eq!(app.get_selected(), 1);
        assert!(app.get_devices() == original);
        app.invoke_select_device(1);
        assert!(app.get_devices() == original);
    }

    #[test]
    fn direct_delete_requires_a_stopped_device_and_confirmation() {
        use std::cell::{Cell, RefCell};
        crate::offscreen::init().unwrap();
        let dir = tempfile::tempdir().unwrap();
        let app = crate::AppWindow::new().unwrap();
        let ctx = Rc::new(Ctx {
            app: app.clone_strong(),
            bridge: crate::bridge::Bridge::new().unwrap(),
            state: Rc::default(),
            paths: jidr_core::JidrPaths::under(dir.path()),
            prefs: RefCell::default(),
            windows: RefCell::default(),
            catalog: RefCell::default(),
            pending_confirm: RefCell::default(),
            player: RefCell::default(),
            game_windows: RefCell::default(),
            pending_window_opens: RefCell::default(),
            quitting: Cell::new(false),
        });
        let device = crate::fixtures::device_infos().remove(1);
        ctx.state.borrow_mut().selected = Some(device.device.id);
        ctx.state.borrow_mut().data.devices.push(device);
        crate::app::render(&app, &ctx.state.borrow());
        wire(&ctx);
        app.invoke_delete_device(0);
        assert!(app.get_confirm_open());
        assert!(ctx.pending_confirm.borrow().is_some());
        assert!(
            app.get_confirm_body().contains("snapshots") || app.get_confirm_body().contains("快照")
        );

        app.set_confirm_open(false);
        ctx.pending_confirm.borrow_mut().take();
        ctx.state.borrow_mut().data.devices[0].device.status = jidr_core::DeviceStatus::Running;
        crate::app::render(&app, &ctx.state.borrow());
        app.invoke_delete_device(0);
        assert!(!app.get_confirm_open());
        assert!(ctx.pending_confirm.borrow().is_none());
    }

    #[test]
    fn switching_one_device_preserves_other_tab_selection() {
        let first = Uuid::new_v4();
        let second = Uuid::new_v4();
        let mut state = crate::app::State {
            tabs: vec![first, second],
            active: Some(1),
            ..Default::default()
        };
        assert!(remove_tab_for_device(&mut state, first));
        assert_eq!(state.tabs, vec![second]);
        assert_eq!(state.active, Some(0));
        assert!(!remove_tab_for_device(&mut state, first));
        assert!(remove_tab_for_device(&mut state, second));
        assert_eq!(state.active, None);
    }
}
