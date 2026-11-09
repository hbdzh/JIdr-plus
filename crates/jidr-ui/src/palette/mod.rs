//! Command palette (⌘K): every launcher action plus one entry per device,
//! fuzzy-filtered (letters in order, case-insensitive).

use crate::{DevState, DeviceVm, PaletteItem, PaletteKind};

fn item(kind: PaletteKind, title: &str, subtitle: &str, kbd: &str, action: String) -> PaletteItem {
    PaletteItem {
        kind,
        title: palette_text(title).into(),
        subtitle: palette_text(subtitle).into(),
        kbd: kbd.into(),
        action: action.into(),
        state: DevState::Stopped,
    }
}

fn palette_text(value: &str) -> String {
    if crate::i18n::text("en", "zh") == "en" {
        return value.to_owned();
    }
    for (en, zh) in [
        (
            "Find or install the emulator and an image",
            "查找或安装模拟器和镜像",
        ),
        ("Create a device from a profile", "根据配置创建设备"),
        ("Saves a quick-boot snapshot", "保存快速启动快照"),
        ("Name, RAM, CPU, screen", "名称、内存、CPU、屏幕"),
        ("SDK, storage, agents, about", "SDK、存储、智能体、关于"),
        ("Set up Android SDK", "设置 Android SDK"),
        ("New device", "新建设备"),
        ("Add Jidr to Claude", "将 Jidr 添加到 Claude"),
        ("MCP setup", "MCP 设置"),
        ("Toggle light and dark", "切换浅色和深色"),
        ("Appearance", "外观"),
        ("Settings", "设置"),
        ("Open ", "打开 "),
        ("Start ", "启动 "),
        ("Stop ", "停止 "),
        ("Edit ", "编辑 "),
        ("Restart ", "重启 "),
        ("Delete ", "删除 "),
        ("Stop and start the device", "停止并重新启动设备"),
        (
            "Deletes the device, apps and snapshots",
            "删除设备、应用和快照",
        ),
    ] {
        if value.starts_with(en) {
            return value.replacen(en, zh, 1);
        }
    }
    value.to_owned()
}

/// All entries for the current devices.
pub fn items(devices: &[DeviceVm], sdk_ready: bool) -> Vec<PaletteItem> {
    let mut v = Vec::new();
    for d in devices {
        let mut open = item(
            PaletteKind::Device,
            &format!("Open {}", d.name),
            &d.status,
            "",
            format!("open:{}", d.id),
        );
        open.state = d.state;
        v.push(open);
    }
    if !sdk_ready {
        v.push(item(
            PaletteKind::Action,
            "Set up Android SDK",
            "Find or install the emulator and an image",
            "⌘↵",
            "setup".into(),
        ));
    }
    v.push(item(
        PaletteKind::Action,
        "New device",
        "Create a device from a profile",
        "⌘N",
        "new".into(),
    ));
    for d in devices {
        match d.state {
            DevState::Stopped | DevState::Crashed => v.push(item(
                PaletteKind::Action,
                &format!("Start {}", d.name),
                &d.android,
                "",
                format!("start:{}", d.id),
            )),
            DevState::Running | DevState::Booting | DevState::Starting => v.push(item(
                PaletteKind::Action,
                &format!("Stop {}", d.name),
                "Saves a quick-boot snapshot",
                "",
                format!("stop:{}", d.id),
            )),
            _ => {}
        }
        if d.state == DevState::Stopped {
            v.push(item(
                PaletteKind::Action,
                &format!("Edit {}", d.name),
                "Name, RAM, CPU, screen",
                "",
                format!("edit:{}", d.id),
            ));
        }
        if d.state == DevState::Running {
            v.push(item(
                PaletteKind::Action,
                &format!("Restart {}", d.name),
                "Stop and start the device",
                "",
                format!("restart:{}", d.id),
            ));
        }
        if matches!(d.state, DevState::Stopped | DevState::Crashed) {
            v.push(item(
                PaletteKind::Action,
                &format!("Delete {}", d.name),
                "Deletes the device, apps and snapshots",
                "",
                format!("delete:{}", d.id),
            ));
        }
    }
    v.push(item(
        PaletteKind::Setting,
        "Settings",
        "SDK, storage, agents, about",
        "⌘,",
        "settings".into(),
    ));
    v.push(item(
        PaletteKind::Setting,
        "Add Jidr to Claude",
        "MCP setup",
        "",
        "settings:agents".into(),
    ));
    v.push(item(
        PaletteKind::Setting,
        "Toggle light and dark",
        "Appearance",
        "",
        "appearance".into(),
    ));
    v
}

/// Letters of `query` appear in `text` in order (case-insensitive).
pub fn matches(text: &str, query: &str) -> bool {
    let mut t = text.chars().flat_map(char::to_lowercase);
    query
        .chars()
        .filter(|c| !c.is_whitespace())
        .flat_map(char::to_lowercase)
        .all(|q| t.any(|c| c == q))
}

/// Entries matching `query`; contiguous matches first.
pub fn filter(all: &[PaletteItem], query: &str) -> Vec<PaletteItem> {
    let q = query.trim().to_lowercase();
    if q.is_empty() {
        return all.to_vec();
    }
    let mut v: Vec<(bool, PaletteItem)> = all
        .iter()
        .filter(|i| matches(&i.title, &q) || matches(&i.subtitle, &q))
        .map(|i| (!i.title.to_lowercase().contains(&q), i.clone()))
        .collect();
    v.sort_by_key(|(rank, _)| *rank);
    v.into_iter().map(|(_, i)| i).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fuzzy_matching_is_ordered_and_case_insensitive() {
        assert!(matches("Open Pixel-ish 6.1", "pix61"));
        assert!(matches("New device", "nd"));
        assert!(!matches("New device", "dn"));
    }

    #[test]
    fn devices_get_open_and_lifecycle_entries() {
        let devices = crate::fixtures::devices();
        let all = items(&devices, true);
        assert!(
            all.iter()
                .any(|i| i.action == format!("open:{}", devices[0].id).as_str())
        );
        assert!(all.iter().any(|i| i.title == "Stop Pixel-ish 6.1"));
        assert!(all.iter().any(|i| i.title == "Start Tablet 11"));
        assert!(
            all.iter()
                .any(|i| i.action == format!("restart:{}", devices[0].id).as_str())
        );
        assert!(
            !all.iter()
                .any(|i| i.action == format!("delete:{}", devices[0].id).as_str())
        );
        assert!(
            all.iter()
                .any(|i| i.action == format!("delete:{}", devices[1].id).as_str())
        );
        let f = filter(&all, "tablet");
        assert!(f.iter().all(|i| i.title.to_lowercase().contains("tablet")
            || i.subtitle.to_lowercase().contains("tablet")));
        assert_eq!(filter(&all, "").len(), all.len());
    }
}
