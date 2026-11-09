//! Settings: GUI preferences (pure view state, kept in `gui-prefs.json`),
//! storage rows from daemon data, the "Add Jidr to Claude" config merge and
//! the update check.

pub mod update;

use std::path::{Path, PathBuf};

use jidr_core::SystemImage;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use slint::ComponentHandle;

use crate::model::{self, DeviceInfo};
use crate::{OptionVm, RootChoice, UsageRow};

/// The OpenStreetMap tile server (D14); attribution is always shown.
pub const OSM_TILES: &str = "https://tile.openstreetmap.org/{z}/{x}/{y}.png";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Prefs {
    /// 0 English, 1 Simplified Chinese.
    pub language: u8,
    /// 0 System, 1 Light, 2 Dark.
    pub appearance: u8,
    /// `none` | `adb` | `magisk`. A copy of the daemon's `default_root_mode`
    /// (gap B4: the daemon owns it, so the CLI and agents agree), refreshed on
    /// connect; the create sheet and Setup read it.
    pub default_root: String,
    /// Empty = OpenStreetMap.
    pub tile_url: String,
    /// A copy of the daemon's `quick_boot` setting (D29, gap B4).
    pub quick_boot: bool,
    /// A planned destination only; setting it never moves or activates data.
    pub migration_target: String,
}

impl Default for Prefs {
    fn default() -> Self {
        Self {
            language: 1,
            appearance: 0,
            default_root: "adb".into(),
            tile_url: String::new(),
            quick_boot: true,
            migration_target: String::new(),
        }
    }
}

impl Prefs {
    pub fn path(data_dir: &Path) -> PathBuf {
        data_dir.join("gui-prefs.json")
    }

    pub fn load(data_dir: &Path) -> Self {
        std::fs::read_to_string(Self::path(data_dir))
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default()
    }

    pub fn save(&self, data_dir: &Path) -> std::io::Result<()> {
        use std::io::Write as _;
        std::fs::create_dir_all(data_dir)?;
        let temp = data_dir.join(format!(".gui-prefs-{}.tmp", uuid::Uuid::new_v4()));
        let result = (|| {
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&temp)?;
            serde_json::to_writer_pretty(&mut file, self)?;
            file.write_all(b"\n")?;
            file.sync_all()?;
            std::fs::rename(&temp, Self::path(data_dir))?;
            std::fs::File::open(data_dir)?.sync_all()
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(temp);
        }
        result
    }

    /// Takes the daemon's settings (`settings.get` / `settings.set` result).
    pub fn apply_daemon_settings(&mut self, v: &Value) {
        if let Some(m) = v
            .get("default_root_mode")
            .and_then(Value::as_str)
            .filter(|m| matches!(*m, "none" | "adb" | "magisk"))
        {
            self.default_root = m.to_string();
        }
        if let Some(q) = v.get("quick_boot").and_then(Value::as_bool) {
            self.quick_boot = q;
        }
    }

    pub fn root_choice(&self) -> RootChoice {
        match self.default_root.as_str() {
            "none" => RootChoice::None,
            "magisk" => RootChoice::Full,
            _ => RootChoice::Shell,
        }
    }

    pub fn tiles(&self) -> &str {
        if self.tile_url.is_empty() {
            OSM_TILES
        } else {
            &self.tile_url
        }
    }
}

pub fn tile_options() -> Vec<OptionVm> {
    vec![
        OptionVm {
            id: "osm".into(),
            label: crate::i18n::text("OpenStreetMap (default)", "OpenStreetMap（默认）").into(),
        },
        OptionVm {
            id: "custom".into(),
            label: crate::i18n::text("Custom", "自定义").into(),
        },
    ]
}

/// Per-device disk use, largest first, plus a total row (`fraction` −1).
pub fn device_usage(
    devices: &[DeviceInfo],
    snapshot_counts: &[(uuid::Uuid, usize)],
) -> Vec<UsageRow> {
    let mut v: Vec<(&DeviceInfo, u64)> = devices
        .iter()
        .map(|d| (d, d.disk_bytes.unwrap_or(0)))
        .collect();
    v.sort_by_key(|x| std::cmp::Reverse(x.1));
    let max = v.first().map(|x| x.1).unwrap_or(0).max(1);
    let total: u64 = v.iter().map(|x| x.1).sum();
    let mut rows: Vec<UsageRow> = v
        .iter()
        .map(|(d, bytes)| {
            let snaps = snapshot_counts
                .iter()
                .find(|(id, _)| *id == d.device.id)
                .map(|(_, n)| *n)
                .unwrap_or(0);
            UsageRow {
                name: d.device.name.clone().into(),
                sub: match snaps {
                    0 => String::new(),
                    1 => crate::i18n::text("1 snapshot", "1 个快照").into(),
                    n => format!("{n} {}", crate::i18n::text("snapshots", "个快照")),
                }
                .into(),
                fraction: *bytes as f32 / max as f32,
                size: model::gb(*bytes).into(),
            }
        })
        .collect();
    if !rows.is_empty() {
        rows.push(UsageRow {
            name: crate::i18n::text("Total", "合计").into(),
            sub: "".into(),
            fraction: -1.0,
            size: model::gb(total).into(),
        });
    }
    rows
}

/// Installed images with how many devices use them.
pub fn image_usage(images: &[SystemImage], devices: &[DeviceInfo]) -> Vec<UsageRow> {
    images
        .iter()
        .filter(|i| i.installed_in.is_some())
        .map(|i| {
            let n = devices.iter().filter(|d| d.device.image == i.image).count();
            UsageRow {
                name: crate::device_form::image_label(i).into(),
                sub: match n {
                    0 => crate::i18n::text("No devices", "没有设备").to_string(),
                    1 => crate::i18n::text("1 device", "1 台设备").to_string(),
                    n => format!("{n} {}", crate::i18n::text("devices", "台设备")),
                }
                .into(),
                fraction: 0.0,
                size: if i.size > 0 {
                    model::gb(i.size)
                } else {
                    "—".into()
                }
                .into(),
            }
        })
        .collect()
}

/// Claude Desktop's config file.
pub fn claude_config_path() -> Option<PathBuf> {
    dirs::config_dir().map(|d| d.join("Claude/claude_desktop_config.json"))
}

/// Adds (or replaces) the `jidr` MCP server, keeping everything else.
pub fn merge_claude_config(existing: Option<&str>, jidr_bin: &str) -> Result<String, String> {
    let mut root: Value = match existing.map(str::trim) {
        Some(t) if !t.is_empty() => serde_json::from_str(t)
            .map_err(|e| format!("claude_desktop_config.json isn't valid JSON: {e}"))?,
        _ => json!({}),
    };
    let obj = root
        .as_object_mut()
        .ok_or("claude_desktop_config.json isn't a JSON object")?;
    let servers = obj
        .entry("mcpServers")
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or("mcpServers isn't a JSON object")?;
    servers.insert(
        "jidr".into(),
        json!({ "command": jidr_bin, "args": ["mcp"] }),
    );
    serde_json::to_string_pretty(&root).map_err(|e| e.to_string())
}

/// Writes the merged config.
pub fn add_to_claude(path: &Path, jidr_bin: &str) -> Result<(), String> {
    let existing = std::fs::read_to_string(path).ok();
    let merged = merge_claude_config(existing.as_deref(), jidr_bin)?;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    std::fs::write(path, merged).map_err(|e| e.to_string())
}

/// Copies text to the macOS pasteboard.
pub fn copy_text(text: &str) {
    use std::io::Write as _;
    if let Ok(mut child) = std::process::Command::new("pbcopy")
        .stdin(std::process::Stdio::piped())
        .spawn()
    {
        if let Some(stdin) = child.stdin.as_mut() {
            let _ = stdin.write_all(text.as_bytes());
        }
        let _ = child.wait();
    }
}

/// Opens a URL or reveals a path with macOS `open`.
pub fn open_external(args: &[&str]) {
    let _ = std::process::Command::new("open").args(args).spawn();
}

fn models<T: Clone + 'static>(v: Vec<T>) -> slint::ModelRc<T> {
    slint::ModelRc::new(slint::VecModel::from(v))
}

fn refresh_usage(win: &crate::SettingsWindow, devices: &[DeviceInfo], images: &[SystemImage]) {
    win.set_device_usage(models(device_usage(devices, &[])));
    win.set_image_usage(models(image_usage(images, devices)));
}

#[derive(Clone, Copy)]
enum ToolChoice {
    Sdk,
    Jdk,
}

static TOOL_PATH_WRITE_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn choose_folder(prompt: &str) -> std::io::Result<Option<PathBuf>> {
    #[cfg(target_os = "macos")]
    {
        let output = std::process::Command::new("osascript")
            .args([
                "-e",
                "on run argv",
                "-e",
                "POSIX path of (choose folder with prompt (item 1 of argv))",
                "-e",
                "end run",
                prompt,
            ])
            .output()?;
        if output.status.success() {
            let path = String::from_utf8(output.stdout).map_err(std::io::Error::other)?;
            Ok(Some(PathBuf::from(path.trim_end_matches(['\r', '\n']))))
        } else if String::from_utf8_lossy(&output.stderr).contains("-128") {
            Ok(None)
        } else {
            Err(std::io::Error::other(
                String::from_utf8_lossy(&output.stderr).trim().to_owned(),
            ))
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = prompt;
        Err(std::io::Error::other(
            "folder selection is not supported on this platform",
        ))
    }
}

/// Choose a new Jidr directory inside an existing parent, without touching
/// either location. The actual migration must recheck all conditions.
fn migration_destination(parent: &Path, paths: &jidr_core::JidrPaths) -> std::io::Result<PathBuf> {
    let data = paths.data.canonicalize()?;
    let parent = parent.canonicalize()?;
    if !parent.is_dir() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "destination parent is not a directory",
        ));
    }
    let target = parent.join("Jidr");
    match std::fs::symlink_metadata(&target) {
        Ok(_) => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::AlreadyExists,
                "destination Jidr already exists",
            ));
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    for source in [
        Some(data),
        optional_directory(&paths.cache)?,
        optional_directory(&paths.logs)?,
    ]
    .into_iter()
    .flatten()
    {
        if target.starts_with(&source) || source.starts_with(&target) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "destination overlaps Jidr data",
            ));
        }
    }
    Ok(target)
}

fn optional_directory(path: &Path) -> std::io::Result<Option<PathBuf>> {
    match std::fs::symlink_metadata(path) {
        Ok(_) => path.canonicalize().map(Some),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

/// Read-only preliminary checks; they never imply that activation or guest
/// recovery is safe. Every condition is rechecked by the eventual migration.
fn migration_preflight(
    paths: &jidr_core::JidrPaths,
    target: &Path,
    sdk_status: &Value,
) -> std::io::Result<jidr_sdk::migration::SpaceEstimate> {
    let parent = target.parent().ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::InvalidInput, "invalid destination")
    })?;
    if migration_destination(parent, paths)? != target {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "destination changed",
        ));
    }
    let sdk = sdk_status
        .get("tools_sdk")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::NotFound,
                "Android SDK tools unavailable",
            )
        })?;
    if !Path::new(sdk).is_absolute() || !Path::new(sdk).join("emulator/qemu-img").is_file() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "qemu-img unavailable",
        ));
    }
    jidr_sdk::migration::estimate_space(paths, parent)
}

fn check_migration(ctx: &std::rc::Rc<crate::app::Ctx>, win: &crate::SettingsWindow) {
    let target = win.get_migration_target().to_string();
    if target.is_empty() {
        win.set_migration_status(
            crate::i18n::text("Choose a destination first.", "请先选择目标位置。").into(),
        );
        return;
    }
    win.set_migration_status(crate::i18n::text("Checking…", "正在检查…").into());
    win.set_migration_checking(true);
    let paths = ctx.paths.clone();
    let weak = win.as_weak();
    let bridge = ctx.bridge.clone();
    ctx.bridge.call("device.list", json!({}), move |devices| {
        bridge.call("sdk.status", json!({}), move |sdk| {
            std::thread::spawn(move || {
                let result = (|| -> Result<bool, String> {
                    let devices: Vec<jidr_core::Device> =
                        serde_json::from_value(devices.map_err(|e| e.to_string())?)
                            .map_err(|e| e.to_string())?;
                    let sdk = sdk.map_err(|e| e.to_string())?;
                    migration_preflight(&paths, Path::new(&target), &sdk)
                        .map_err(|e| e.to_string())?;
                    Ok(devices.iter().any(|d| d.status.is_active()))
                })();
                let _ = slint::invoke_from_event_loop(move || {
                    let Some(win) = weak.upgrade() else { return };
                    win.set_migration_checking(false);
                    if win.get_migration_target().as_str() != target {
                        return;
                    }
                    let message = match result {
                        Ok(true) => crate::i18n::text(
                            "Preliminary check: devices are running; no data moved.",
                            "初步检查：设备运行中，数据未迁移。",
                        ),
                        Ok(false) => crate::i18n::text(
                            "Preliminary check passed; migration is not yet available.",
                            "初步检查通过；迁移尚未开放。",
                        ),
                        Err(e) => {
                            tracing::warn!("migration preliminary check failed: {e}");
                            crate::i18n::text(
                                "Check failed; review the SDK, destination and free space.",
                                "检查失败，请检查 SDK、目标目录及剩余空间。",
                            )
                        }
                    };
                    win.set_migration_status(message.into());
                });
            });
        });
    });
}

fn choose_migration_target(paths: jidr_core::JidrPaths, weak: slint::Weak<crate::SettingsWindow>) {
    let prompt = crate::i18n::text(
        "Choose the parent folder for the new Jidr data folder",
        "选择新 Jidr 数据文件夹的上级目录",
    )
    .to_owned();
    std::thread::spawn(move || {
        let result = choose_folder(&prompt).and_then(|selection| {
            selection
                .map(|p| migration_destination(&p, &paths))
                .transpose()
        });
        let _ = slint::invoke_from_event_loop(move || {
            let Some(win) = weak.upgrade() else { return };
            match result {
                Ok(None) => {}
                Ok(Some(path)) => {
                    let Some(ctx) = crate::app::ctx() else { return };
                    if !ctx.paths.data.is_dir() {
                        win.set_migration_status(
                            crate::i18n::text(
                                "Current data folder is unavailable.",
                                "当前数据目录不可用。",
                            )
                            .into(),
                        );
                        return;
                    }
                    let mut prefs = ctx.prefs.borrow().clone();
                    let Some(target) = path.to_str() else {
                        win.set_migration_status(
                            crate::i18n::text(
                                "The destination path cannot be represented as text.",
                                "无法表示目标目录路径。",
                            )
                            .into(),
                        );
                        return;
                    };
                    prefs.migration_target = target.to_owned();
                    match prefs.save(&ctx.paths.data) {
                        Ok(()) => {
                            win.set_migration_target(prefs.migration_target.clone().into());
                            *ctx.prefs.borrow_mut() = prefs;
                            win.set_migration_status(
                                crate::i18n::text(
                                    "Destination saved; data has not been moved.",
                                    "目标位置已保存；数据尚未迁移。",
                                )
                                .into(),
                            );
                        }
                        Err(e) => {
                            tracing::warn!("saving migration destination: {e}");
                            win.set_migration_status(
                                crate::i18n::text(
                                    "Could not save destination.",
                                    "无法保存目标位置。",
                                )
                                .into(),
                            );
                        }
                    }
                }
                Err(e) => {
                    tracing::warn!("selecting migration destination: {e}");
                    let message = match e.kind() {
                        std::io::ErrorKind::AlreadyExists => crate::i18n::text(
                            "The destination Jidr folder already exists.",
                            "目标 Jidr 文件夹已存在。",
                        ),
                        std::io::ErrorKind::InvalidInput => crate::i18n::text(
                            "The destination overlaps existing data.",
                            "目标位置与现有数据重叠。",
                        ),
                        _ => crate::i18n::text(
                            "Could not select the destination.",
                            "无法选择目标位置。",
                        ),
                    };
                    win.set_migration_status(message.into());
                }
            }
        });
    });
}

fn save_tool_selection(
    paths: &jidr_core::JidrPaths,
    choice: ToolChoice,
    selected: Option<PathBuf>,
) -> std::io::Result<()> {
    let _lock = TOOL_PATH_WRITE_LOCK
        .lock()
        .map_err(|_| std::io::Error::other("tool path lock is poisoned"))?;
    let mut config = jidr_core::tool_paths::ToolPaths::load(paths)?;
    match choice {
        ToolChoice::Sdk => config.android_sdk = selected,
        ToolChoice::Jdk => config.jdk_home = selected,
    }
    config.save(paths)
}

fn choose_tool(
    paths: jidr_core::JidrPaths,
    weak: slint::Weak<crate::SettingsWindow>,
    choice: ToolChoice,
) {
    let prompt = match choice {
        ToolChoice::Sdk => {
            crate::i18n::text("Choose an Android SDK folder", "选择 Android SDK 文件夹")
        }
        ToolChoice::Jdk => crate::i18n::text("Choose a JDK home folder", "选择 JDK 主目录"),
    }
    .to_owned();
    let success = match choice {
        ToolChoice::Sdk => crate::i18n::text(
            "Saved. SDK changes apply to the next device launch.",
            "已保存；SDK 更改在设备下次启动时生效。",
        ),
        ToolChoice::Jdk => crate::i18n::text(
            "JDK path saved; Jidr does not currently use Java.",
            "JDK 路径已保存；Jidr 当前不使用 Java。",
        ),
    }
    .to_owned();
    let failure = crate::i18n::text("Could not save tool path:", "无法保存工具路径：").to_owned();
    std::thread::spawn(move || {
        let selection = choose_folder(&prompt);
        let mut selected = match selection {
            Ok(Some(path)) => path,
            Ok(None) => return,
            Err(e) => {
                let _ = slint::invoke_from_event_loop(move || {
                    if let Some(win) = weak.upgrade() {
                        win.set_tool_status(format!("{failure} {e}").into());
                    }
                });
                return;
            }
        };
        if matches!(choice, ToolChoice::Jdk) && selected.join("Contents/Home/bin/java").is_file() {
            selected = selected.join("Contents/Home");
        }
        let result = save_tool_selection(&paths, choice, Some(selected.clone()));
        let _ = slint::invoke_from_event_loop(move || {
            if let Some(win) = weak.upgrade() {
                match result {
                    Ok(()) => {
                        match choice {
                            ToolChoice::Sdk => {
                                win.set_sdk_path(selected.to_string_lossy().into_owned().into())
                            }
                            ToolChoice::Jdk => {
                                win.set_jdk_path(selected.to_string_lossy().into_owned().into())
                            }
                        }
                        win.set_tool_status(success.into());
                    }
                    Err(e) => win.set_tool_status(format!("{failure} {e}").into()),
                }
            }
        });
    });
}

fn reset_tool(
    paths: jidr_core::JidrPaths,
    weak: slint::Weak<crate::SettingsWindow>,
    choice: ToolChoice,
) {
    std::thread::spawn(move || {
        let result = save_tool_selection(&paths, choice, None);
        let _ = slint::invoke_from_event_loop(move || {
            let Some(win) = weak.upgrade() else { return };
            if let Err(e) = result {
                win.set_tool_status(
                    format!(
                        "{} {e}",
                        crate::i18n::text("Could not save tool path:", "无法保存工具路径：")
                    )
                    .into(),
                );
                return;
            }
            win.set_tool_status(
                crate::i18n::text("Automatic selection restored.", "已恢复自动选择。").into(),
            );
            match choice {
                ToolChoice::Jdk => {
                    win.set_jdk_path(crate::i18n::text("System default", "系统默认").into())
                }
                ToolChoice::Sdk => {
                    let Some(ctx) = crate::app::ctx() else { return };
                    let weak = win.as_weak();
                    ctx.bridge.call("sdk.status", json!({}), move |result| {
                        let sdk = result
                            .ok()
                            .and_then(|v| {
                                v.get("tools_sdk")
                                    .and_then(Value::as_str)
                                    .map(str::to_owned)
                            })
                            .unwrap_or_default();
                        let _ = slint::invoke_from_event_loop(move || {
                            if let Some(win) = weak.upgrade() {
                                win.set_sdk_path(sdk.into());
                            }
                        });
                    });
                }
            }
        });
    });
}

/// Opens the Settings window on `tab` (0 General, 1 Storage, 2 Agents, 3 About).
pub fn open(ctx: &std::rc::Rc<crate::app::Ctx>, tab: i32) {
    let Ok(win) = crate::SettingsWindow::new() else {
        return;
    };
    let theme = ctx.app.global::<crate::Theme>();
    let wt = win.global::<crate::Theme>();
    wt.set_dark(theme.get_dark());
    wt.set_rtl(theme.get_rtl());
    wt.set_reduce_motion(theme.get_reduce_motion());
    win.set_draw_lights(false);
    win.set_tab(tab);
    win.set_version(env!("CARGO_PKG_VERSION").into());
    win.set_data_path(ctx.paths.data.to_string_lossy().into_owned().into());
    let prefs = ctx.prefs.borrow().clone();
    win.set_migration_target(prefs.migration_target.clone().into());
    win.set_default_root(prefs.root_choice());
    win.set_tile_options(models(tile_options()));
    win.set_tile_choice(if prefs.tile_url.is_empty() { 0 } else { 1 });
    win.set_tile_url(prefs.tile_url.clone().into());
    win.set_appearance(i32::from(prefs.appearance));
    win.set_language(i32::from(prefs.language.min(1)));
    win.set_quick_boot(prefs.quick_boot);
    match jidr_core::tool_paths::ToolPaths::load(&ctx.paths) {
        Ok(tools) => win.set_jdk_path(
            tools
                .jdk_home
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_else(|| crate::i18n::text("System default", "系统默认").into())
                .into(),
        ),
        Err(e) => win.set_tool_status(
            format!(
                "{} {e}",
                crate::i18n::text("Could not read tool paths:", "无法读取工具路径：")
            )
            .into(),
        ),
    }
    let devices = ctx.state.borrow().data.devices.clone();
    win.set_device_usage(models(device_usage(&devices, &[])));
    let cache = dir_size(&ctx.paths.cache);
    win.set_cache_size(model::gb(cache).into());

    // SDK state and images come from the daemon.
    let image_cache = std::rc::Rc::new(std::cell::RefCell::new(Vec::<SystemImage>::new()));
    let image_cache_loaded = image_cache.clone();
    let weak = win.as_weak();
    let b2 = ctx.bridge.clone();
    let tool_paths = ctx.paths.clone();
    let token = crate::app::defer(move |(status, images): (Value, Vec<SystemImage>)| {
        let Some(win) = weak.upgrade() else { return };
        let sdk = jidr_core::tool_paths::ToolPaths::load(&tool_paths)
            .ok()
            .and_then(|p| p.android_sdk)
            .map(|p| p.to_string_lossy().into_owned())
            .or_else(|| {
                status
                    .get("tools_sdk")
                    .or_else(|| status.get("private_sdk"))
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
            .unwrap_or_default();
        let ready = crate::bridge::sdk_has_tools(&status);
        win.set_sdk_path(sdk.into());
        win.set_sdk_ready(ready);
        win.set_sdk_state(
            if ready {
                crate::i18n::text("Ready", "就绪")
            } else {
                crate::i18n::text("Not installed", "未安装")
            }
            .into(),
        );
        win.set_sdk_note(
            status
                .get("emulator_version")
                .and_then(Value::as_str)
                .map(|v| format!("Emulator {v}"))
                .unwrap_or_default()
                .into(),
        );
        win.set_image_usage(models(image_usage(&images, &devices)));
        *image_cache_loaded.borrow_mut() = images;
    });
    ctx.bridge.call("sdk.status", json!({}), move |s| {
        let status = s.unwrap_or(Value::Null);
        b2.call("image.list", json!({ "available": false }), move |i| {
            let images: Vec<SystemImage> = i
                .ok()
                .and_then(|v| serde_json::from_value(v).ok())
                .unwrap_or_default();
            crate::app::fire(token, (status, images));
        });
    });

    // The daemon's settings may have changed (CLI, an agent): show them.
    let weak = win.as_weak();
    let token = crate::app::defer(move |v: Option<Value>| {
        let (Some(v), Some(c), Some(win)) = (v, crate::app::ctx(), weak.upgrade()) else {
            return;
        };
        c.prefs.borrow_mut().apply_daemon_settings(&v);
        let prefs = c.prefs.borrow();
        win.set_default_root(prefs.root_choice());
        win.set_quick_boot(prefs.quick_boot);
    });
    ctx.bridge.call("settings.get", json!({}), move |r| {
        crate::app::fire(token, r.ok());
    });

    let c = ctx.clone();
    win.on_default_root_changed(move |choice| {
        let mode = crate::device_form::root_mode(choice);
        c.prefs.borrow_mut().default_root = mode.into();
        let _ = c.prefs.borrow().save(&c.paths.data);
        set_daemon_setting(&c, json!({ "default_root_mode": mode }));
    });
    let c = ctx.clone();
    win.on_tiles_changed(move |choice, url| {
        c.prefs.borrow_mut().tile_url = if choice == 0 {
            String::new()
        } else {
            url.to_string()
        };
        let _ = c.prefs.borrow().save(&c.paths.data);
    });
    let c = ctx.clone();
    let language_window = win.as_weak();
    win.on_language_changed(move |i| {
        let language = if i == 0 { 0 } else { 1 };
        if crate::i18n::select(language != 0).is_ok() {
            c.prefs.borrow_mut().language = language;
            let _ = c.prefs.borrow().save(&c.paths.data);
            crate::app::render(&c.app, &c.state.borrow());
            if let Some(win) = language_window.upgrade() {
                win.set_tile_options(models(tile_options()));
                let devices = c.state.borrow().data.devices.clone();
                refresh_usage(&win, &devices, &image_cache.borrow());
                win.set_sdk_state(
                    if win.get_sdk_ready() {
                        crate::i18n::text("Ready", "就绪")
                    } else {
                        crate::i18n::text("Not installed", "未安装")
                    }
                    .into(),
                );
            }
        }
    });
    let data_path = ctx.paths.data.clone();
    win.on_show_data(move || open_external(&["-R", &data_path.to_string_lossy()]));
    let paths = ctx.paths.clone();
    let w = win.as_weak();
    win.on_choose_migration_target(move || choose_migration_target(paths.clone(), w.clone()));
    let c = ctx.clone();
    let w = win.as_weak();
    win.on_check_migration(move || {
        if let Some(win) = w.upgrade() {
            check_migration(&c, &win);
        }
    });
    let c = ctx.clone();
    let w = win.as_weak();
    win.on_appearance_changed(move |i| {
        c.prefs.borrow_mut().appearance = u8::try_from(i).unwrap_or(0);
        let _ = c.prefs.borrow().save(&c.paths.data);
        c.apply_appearance();
        if let Some(win) = w.upgrade() {
            win.global::<crate::Theme>()
                .set_dark(c.app.global::<crate::Theme>().get_dark());
        }
    });
    let c = ctx.clone();
    win.on_quick_boot_changed(move |v| {
        c.prefs.borrow_mut().quick_boot = v;
        let _ = c.prefs.borrow().save(&c.paths.data);
        set_daemon_setting(&c, json!({ "quick_boot": v }));
    });
    let w = win.as_weak();
    win.on_show_sdk(move || {
        if let Some(win) = w.upgrade() {
            open_external(&["-R", win.get_sdk_path().as_str()]);
        }
    });
    let paths = ctx.paths.clone();
    let w = win.as_weak();
    win.on_change_sdk(move || choose_tool(paths.clone(), w.clone(), ToolChoice::Sdk));
    let paths = ctx.paths.clone();
    let w = win.as_weak();
    win.on_change_jdk(move || choose_tool(paths.clone(), w.clone(), ToolChoice::Jdk));
    let paths = ctx.paths.clone();
    let w = win.as_weak();
    win.on_reset_sdk(move || reset_tool(paths.clone(), w.clone(), ToolChoice::Sdk));
    let paths = ctx.paths.clone();
    let w = win.as_weak();
    win.on_reset_jdk(move || reset_tool(paths.clone(), w.clone(), ToolChoice::Jdk));
    let c = ctx.clone();
    let cache_dir = ctx.paths.cache.clone();
    let w = win.as_weak();
    win.on_clear_cache(move || {
        let _ = std::fs::remove_dir_all(&cache_dir);
        if let Some(win) = w.upgrade() {
            win.set_cache_size(model::gb(0).into());
        }
        crate::app::toast(&c.app.as_weak(), "Cleared the download cache".into());
    });
    let c = ctx.clone();
    win.on_add_to_claude(move || {
        // The CLI that serves MCP, never the GUI itself (see bundled_jidr).
        let bin = jidr_client::SpawnOptions::default()
            .program()
            .to_string_lossy()
            .into_owned();
        let msg = match claude_config_path() {
            Some(path) => match add_to_claude(&path, &bin) {
                Ok(()) => "Added Jidr to Claude Desktop. Restart Claude to use it.".to_string(),
                Err(e) => e,
            },
            None => "Can't find Claude Desktop's settings folder".to_string(),
        };
        crate::app::toast(&c.app.as_weak(), msg);
    });
    let c = ctx.clone();
    win.on_copy(move |t| {
        copy_text(&t);
        crate::app::toast(&c.app.as_weak(), "Copied".into());
    });
    let repo = env!("CARGO_PKG_REPOSITORY");
    win.on_open_source(move || open_external(&[repo]));
    win.on_sponsor(move || open_external(&[repo]));
    let c = ctx.clone();
    let w = win.as_weak();
    win.on_check_updates(move || check_updates(&c, w.clone()));
    let w = win.as_weak();
    win.on_update_action(move || {
        let Some(win) = w.upgrade() else { return };
        let url = win.get_update_url().to_string();
        if !url.is_empty() {
            open_external(&[&url]);
        }
    });
    win.on_show_licences(move || open_external(&[&format!("{repo}/blob/main/NOTICE")]));

    let _ = win.show();
    ctx.windows.borrow_mut().push(Box::new(win));
}

/// Bytes under `dir` (cache size).
pub fn dir_size(dir: &Path) -> u64 {
    let Ok(rd) = std::fs::read_dir(dir) else {
        return 0;
    };
    rd.filter_map(Result::ok)
        .map(|e| match e.file_type() {
            Ok(t) if t.is_dir() => dir_size(&e.path()),
            Ok(_) => e.metadata().map(|m| m.len()).unwrap_or(0),
            Err(_) => 0,
        })
        .sum()
}

/// Gap B4: refreshes the cached default root mode and quick boot from the
/// daemon (on connect, so the create sheet follows `jidr settings`).
pub fn sync_from_daemon(ctx: &crate::app::Ctx) {
    let token = crate::app::defer(move |v: Option<Value>| {
        if let (Some(v), Some(c)) = (v, crate::app::ctx()) {
            c.prefs.borrow_mut().apply_daemon_settings(&v);
        }
    });
    ctx.bridge.call("settings.get", json!({}), move |r| {
        crate::app::fire(token, r.ok());
    });
}

/// Settings › About: asks GitHub for the latest release (IO thread) and shows
/// the answer under the version line.
fn check_updates(ctx: &crate::app::Ctx, weak: slint::Weak<crate::SettingsWindow>) {
    let current = env!("CARGO_PKG_VERSION");
    let repo = env!("CARGO_PKG_REPOSITORY");
    if let Some(win) = weak.upgrade() {
        win.set_update_checking(true);
        win.set_update_status("Checking…".into());
        win.set_update_label("".into());
    }
    let token = crate::app::defer(move |check: update::Check| {
        let Some(win) = weak.upgrade() else { return };
        let (status, action, url) = update::view(&check, current, repo);
        win.set_update_checking(false);
        win.set_update_status(status.into());
        win.set_update_label(action.into());
        win.set_update_url(url.into());
    });
    ctx.bridge.handle().spawn(async move {
        crate::app::fire(token, update::check(repo, current).await);
    });
}

/// `settings.set`; a failure is shown as a toast.
fn set_daemon_setting(ctx: &crate::app::Ctx, params: Value) {
    let weak = ctx.app.as_weak();
    ctx.bridge.call("settings.set", params, move |r| {
        if let Err(e) = r {
            crate::app::toast(&weak, format!("Couldn't save the setting: {}", e.message));
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefs_round_trip_and_default() {
        let tmp = tempfile::tempdir().unwrap();
        assert_eq!(Prefs::load(tmp.path()), Prefs::default());
        let p = Prefs {
            language: 0,
            appearance: 2,
            default_root: "magisk".into(),
            tile_url: "https://t.example/{z}/{x}/{y}.png".into(),
            quick_boot: false,
            migration_target: "/Volumes/External/Jidr".into(),
        };
        p.save(tmp.path()).unwrap();
        let back = Prefs::load(tmp.path());
        assert_eq!(back, p);
        assert_eq!(back.root_choice(), RootChoice::Full);
        assert_eq!(Prefs::default().tiles(), OSM_TILES);
    }

    #[test]
    fn old_preferences_keep_working_and_default_to_chinese() {
        let prefs: Prefs = serde_json::from_str(r#"{"appearance":2}"#).unwrap();
        assert_eq!(prefs.language, 1);
        assert_eq!(prefs.appearance, 2);
        assert!(prefs.migration_target.is_empty());
    }

    #[test]
    fn migration_target_rejects_existing_and_overlapping_directories() {
        let temp = tempfile::tempdir().unwrap();
        let paths = jidr_core::JidrPaths::under(temp.path().join("source"));
        std::fs::create_dir_all(&paths.data).unwrap();
        let parent = temp.path().join("external");
        std::fs::create_dir(&parent).unwrap();
        let expected = parent.canonicalize().unwrap().join("Jidr");
        assert_eq!(migration_destination(&parent, &paths).unwrap(), expected);
        assert!(!expected.exists());
        assert!(migration_destination(&paths.data, &paths).is_err());
        std::fs::create_dir(&expected).unwrap();
        assert!(migration_destination(&parent, &paths).is_err());
    }

    #[test]
    fn migration_preflight_is_read_only_and_checks_tools_and_destination() {
        let temp = tempfile::tempdir().unwrap();
        let paths = jidr_core::JidrPaths::under(temp.path().join("source"));
        std::fs::create_dir_all(&paths.data).unwrap();
        let parent = temp.path().join("destination");
        std::fs::create_dir(&parent).unwrap();
        let target = migration_destination(&parent, &paths).unwrap();
        let sdk = temp.path().join("sdk");
        std::fs::create_dir_all(sdk.join("emulator")).unwrap();
        let status = json!({"tools_sdk": sdk});
        assert!(migration_preflight(&paths, &target, &status).is_err());
        std::fs::write(sdk.join("emulator/qemu-img"), b"test").unwrap();
        assert!(migration_preflight(&paths, &target, &status).is_ok());
        assert!(!target.exists());
        std::fs::create_dir(&target).unwrap();
        assert!(migration_preflight(&paths, &target, &status).is_err());
    }

    #[test]
    fn sdk_and_jdk_selection_can_be_saved_and_reset_independently() {
        let temp = tempfile::tempdir().unwrap();
        let paths = jidr_core::JidrPaths::under(temp.path().join("data-root"));
        std::fs::create_dir_all(&paths.data).unwrap();
        let sdk = temp.path().join("sdk");
        let jdk = temp.path().join("jdk");
        std::fs::create_dir_all(sdk.join("emulator")).unwrap();
        std::fs::create_dir_all(sdk.join("platform-tools")).unwrap();
        std::fs::create_dir_all(jdk.join("bin")).unwrap();
        for path in [
            sdk.join("emulator/emulator"),
            sdk.join("platform-tools/adb"),
            jdk.join("bin/java"),
            jdk.join("bin/javac"),
        ] {
            std::fs::write(path, b"x").unwrap();
        }
        save_tool_selection(&paths, ToolChoice::Sdk, Some(sdk.clone())).unwrap();
        save_tool_selection(&paths, ToolChoice::Jdk, Some(jdk.clone())).unwrap();
        save_tool_selection(&paths, ToolChoice::Sdk, None).unwrap();
        let config = jidr_core::tool_paths::ToolPaths::load(&paths).unwrap();
        assert_eq!(config.android_sdk, None);
        assert_eq!(config.jdk_home, Some(jdk));
        assert!(
            save_tool_selection(&paths, ToolChoice::Sdk, Some(temp.path().join("missing")))
                .is_err()
        );
        assert_eq!(
            jidr_core::tool_paths::ToolPaths::load(&paths).unwrap(),
            config
        );
    }

    #[test]
    fn refreshing_usage_keeps_installed_image_rows() {
        use slint::Model as _;
        let _ = crate::offscreen::init();
        let window = crate::SettingsWindow::new().unwrap();
        let images = crate::fixtures::system_images();
        let devices = crate::fixtures::device_infos();
        refresh_usage(&window, &devices, &images);
        let before = window.get_image_usage().row_count();
        assert!(before > 0);
        refresh_usage(&window, &devices, &images);
        assert_eq!(window.get_image_usage().row_count(), before);
    }

    #[test]
    fn bundled_language_switch_updates_existing_window() {
        let _ = crate::offscreen::init();
        let window = crate::SettingsWindow::new().unwrap();
        slint::select_bundled_translation("en").unwrap();
        let _ = crate::offscreen::render(window.window(), 820, 640).unwrap();
        assert_eq!(window.get_localized_title(), "Settings");
        slint::select_bundled_translation("zh_CN").unwrap();
        let _ = crate::offscreen::render(window.window(), 820, 640).unwrap();
        assert_eq!(window.get_localized_title(), "设置");
        slint::select_bundled_translation("en").unwrap();
        let _ = crate::offscreen::render(window.window(), 820, 640).unwrap();
        assert_eq!(window.get_localized_title(), "Settings");
    }

    #[test]
    fn claude_config_keeps_other_servers() {
        let merged = merge_claude_config(
            Some(r#"{"mcpServers":{"other":{"command":"x"}},"theme":"dark"}"#),
            "/Applications/Jidr.app/Contents/MacOS/jidr",
        )
        .unwrap();
        let v: Value = serde_json::from_str(&merged).unwrap();
        assert_eq!(v["mcpServers"]["other"]["command"], "x");
        assert_eq!(v["mcpServers"]["jidr"]["args"][0], "mcp");
        assert_eq!(v["theme"], "dark");
        assert!(merge_claude_config(Some("[1]"), "jidr").is_err());
        assert!(merge_claude_config(None, "jidr").is_ok());
    }

    #[test]
    fn usage_rows_sort_and_total() {
        let rows = device_usage(
            &crate::fixtures::device_infos(),
            &[(uuid::Uuid::from_u128(1), 3)],
        );
        assert_eq!(rows[0].name, "Pixel-ish 6.1");
        assert_eq!(rows[0].sub, "3 snapshots");
        assert_eq!(rows.last().unwrap().size, "19.2 GB");
    }

    /// Gap B4: the daemon's settings replace the cached copy; unknown or
    /// missing values leave it alone.
    #[test]
    fn daemon_settings_update_the_cached_prefs() {
        let mut p = Prefs::default();
        p.apply_daemon_settings(&json!({ "default_root_mode": "magisk", "quick_boot": false }));
        assert_eq!(p.root_choice(), RootChoice::Full);
        assert!(!p.quick_boot);
        p.apply_daemon_settings(&json!({ "default_root_mode": "bogus" }));
        assert_eq!(p.default_root, "magisk");
        assert!(!p.quick_boot);
    }
}
