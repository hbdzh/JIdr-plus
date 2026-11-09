//! Device-scoped installed application list. Late responses never replace a
//! newly selected device's list.
use std::cell::{Cell, RefCell};
use std::rc::Rc;

use jidr_core::DeviceStatus;
use serde_json::{Value, json};
use slint::{ComponentHandle, Image, ModelRc, VecModel};
use uuid::Uuid;

use crate::GameVm;
use crate::app::{Ctx, toast_error};

thread_local! {
    static REQUEST: Cell<u64> = const { Cell::new(0) };
    static SEEN: RefCell<Option<(Uuid, bool)>> = const { RefCell::new(None) };
}

fn selected(ctx: &Ctx) -> Option<Uuid> {
    ctx.device_id(ctx.app.get_selected())
}
fn running(ctx: &Ctx, id: Uuid) -> bool {
    ctx.info(id)
        .is_some_and(|info| matches!(info.device.status, DeviceStatus::Running))
}
fn invalidate() -> u64 {
    REQUEST.with(|request| {
        let next = request.get().wrapping_add(1);
        request.set(next);
        next
    })
}

fn is_current(
    request: u64,
    current: u64,
    requested: Uuid,
    selected: Option<Uuid>,
    running: bool,
) -> bool {
    request == current && selected == Some(requested) && running
}

pub fn sync(ctx: &Rc<Ctx>) {
    let key = selected(ctx).map(|id| (id, running(ctx, id)));
    let changed = SEEN.with(|seen| {
        let mut seen = seen.borrow_mut();
        if *seen == key {
            false
        } else {
            *seen = key;
            true
        }
    });
    if changed {
        refresh(ctx);
    }
}

pub fn refresh(ctx: &Rc<Ctx>) {
    let token = invalidate();
    ctx.app.set_games(ModelRc::default());
    ctx.app.set_games_note("".into());
    let Some(id) = selected(ctx) else {
        ctx.app.set_games_message("".into());
        return;
    };
    if !running(ctx, id) {
        ctx.app.set_games_message(
            crate::i18n::text(
                "Start the device to view installed apps.",
                "启动设备后查看已安装的游戏和应用。",
            )
            .into(),
        );
        return;
    }
    ctx.app.set_games_message(
        crate::i18n::text("Loading installed apps…", "正在读取已安装的游戏和应用…").into(),
    );
    let ui = ctx.clone();
    let done = crate::app::defer(move |result: jidr_core::JidrResult<Value>| {
        if !is_current(
            token,
            REQUEST.with(Cell::get),
            id,
            selected(&ui),
            running(&ui, id),
        ) {
            return;
        }
        match result {
            Ok(value) => {
                let apps: Vec<GameVm> = value
                    .get("apps")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|app| {
                        let package = app.get("package")?.as_str()?;
                        let name = app.get("name")?.as_str()?;
                        let icon = app
                            .get("icon")
                            .and_then(Value::as_str)
                            .and_then(|p| Image::load_from_path(std::path::Path::new(p)).ok());
                        Some(GameVm {
                            name: name.into(),
                            package: package.into(),
                            has_icon: icon.is_some(),
                            icon: icon.unwrap_or_default(),
                        })
                    })
                    .collect();
                ui.app.set_games_message(
                    if apps.is_empty() {
                        crate::i18n::text(
                            "No launchable apps installed yet.",
                            "尚未安装可启动的游戏或应用。",
                        )
                    } else {
                        ""
                    }
                    .into(),
                );
                if !apps.is_empty()
                    && value.get("metadata_available").and_then(Value::as_bool) == Some(false)
                {
                    ui.app.set_games_note(crate::i18n::text("App names and icons need Android build tools; package names are shown.", "未找到 Android 构建工具，暂以包名显示应用。").into());
                } else if !apps.is_empty()
                    && value.get("incomplete_metadata").and_then(Value::as_bool) == Some(true)
                {
                    ui.app.set_games_note(
                        crate::i18n::text(
                            "Some app names or icons are unavailable.",
                            "部分应用名称或图标暂不可用。",
                        )
                        .into(),
                    );
                }
                ui.app.set_games(ModelRc::new(VecModel::from(apps)));
            }
            Err(error) => ui.app.set_games_message(
                format!(
                    "{} {}",
                    crate::i18n::text("Could not load apps:", "无法读取应用列表："),
                    error.message
                )
                .into(),
            ),
        }
    });
    ctx.bridge
        .call("app.list", json!({"device": id}), move |result| {
            crate::app::fire(done, result)
        });
}

pub fn launch(ctx: &Rc<Ctx>, package: &str) {
    let Some(id) = selected(ctx) else { return };
    if !running(ctx, id) {
        toast_error(
            &ctx.app.as_weak(),
            crate::i18n::text("Start the device first.", "请先启动设备。").into(),
        );
        return;
    }
    crate::player::game::open(ctx, id);
    let window = ctx.app.as_weak();
    ctx.bridge.call(
        "app.launch",
        json!({"device": id, "package": package}),
        move |result| match result {
            Ok(value) if value.get("focused").and_then(Value::as_bool) == Some(false) => {
                toast_error(
                    &window,
                    crate::i18n::text(
                        "The app started, but its window could not be confirmed.",
                        "已发送启动请求，但未确认游戏已打开。",
                    )
                    .into(),
                )
            }
            Ok(_) => {}
            Err(error) => toast_error(&window, error.message),
        },
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn late_responses_never_replace_another_device_or_refresh() {
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        assert!(is_current(3, 3, a, Some(a), true));
        assert!(!is_current(3, 4, a, Some(a), true));
        assert!(!is_current(3, 3, a, Some(b), true));
        assert!(!is_current(3, 3, a, Some(a), false));
    }
}
