//! Language selection shared by the Slint catalog and dynamically built labels.
use std::sync::atomic::{AtomicBool, Ordering};

static CHINESE: AtomicBool = AtomicBool::new(false);

pub fn select(chinese: bool) -> Result<(), slint::SelectBundledTranslationError> {
    slint::select_bundled_translation(if chinese { "zh_CN" } else { "en" })?;
    CHINESE.store(chinese, Ordering::Relaxed);
    Ok(())
}

pub fn text<'a>(en: &'a str, zh: &'a str) -> &'a str {
    if CHINESE.load(Ordering::Relaxed) {
        zh
    } else {
        en
    }
}

/// Translate the fixed parts of a dynamic device status or badge.
pub fn device_label(value: &str) -> String {
    if !CHINESE.load(Ordering::Relaxed) {
        return value.to_owned();
    }
    let mut result = value.to_owned();
    for (en, zh) in [
        ("Busy · in use by", "忙碌 · 正由以下对象使用："),
        ("Booting Android…", "正在启动 Android…"),
        ("Setting up root…", "正在设置 root…"),
        ("Shell root (adb)", "Shell root（adb）"),
        ("Root unverified", "Root 未验证"),
        ("Root failed", "Root 失败"),
        ("Not rooted", "未 root"),
        ("No root", "无 root"),
        ("Full root", "完整 root"),
        ("Hibernated", "已休眠"),
        ("Starting…", "正在启动…"),
        ("Stopping…", "正在停止…"),
        ("Stopped", "已停止"),
        ("Running", "运行中"),
        ("Crashed", "已崩溃"),
        ("Rooted", "已 root"),
        ("Unverified", "未验证"),
        ("Not needed", "不需要"),
        ("Not yet", "尚未验证"),
        ("Failed", "失败"),
        ("Setup", "设置中"),
        ("Full", "完整"),
        ("just now", "刚刚"),
        (" min ago", " 分钟前"),
        (" h ago", " 小时前"),
        (" days ago", " 天前"),
    ] {
        result = result.replace(en, zh);
    }
    result
}
