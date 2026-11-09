//! Create / edit device form: options from `profile.list` and `image.list`,
//! defaults (D7), validation, and the `device.create` / `device.edit` params.

use jidr_core::{HardwareProfile, Job, Support, SystemImage};
use serde_json::{Map, Value, json};

use crate::model::{self, DeviceInfo};
use crate::{DeviceForm, ImageRowVm, OptionVm, RootChoice};

/// Images users can pick: supported or best-effort API levels (D23),
/// newest first, Google APIs before Play Store before AOSP.
pub fn sorted_images(images: &[SystemImage]) -> Vec<SystemImage> {
    let mut v: Vec<SystemImage> = images
        .iter()
        .filter(|i| i.support != Support::Unsupported)
        .cloned()
        .collect();
    let tag_rank = |t: &str| match t {
        "google_apis" => 0,
        "google_apis_playstore" => 1,
        "default" => 2,
        _ => 3,
    };
    v.sort_by(|a, b| {
        b.image
            .api
            .cmp(&a.image.api)
            .then(tag_rank(&a.image.tag).cmp(&tag_rank(&b.image.tag)))
    });
    v
}

/// A running `image.install` job for this package, if any.
fn install_job<'a>(img: &SystemImage, jobs: &'a [Job]) -> Option<&'a Job> {
    jobs.iter().find(|j| {
        !j.state.is_terminal()
            && (j.kind == "image.install" || j.kind == "sdk.install")
            && j.message.contains(&img.image.package())
    })
}

pub fn image_label(img: &SystemImage) -> String {
    format!(
        "{} · {}",
        model::android_label(img.image.api),
        model::image_tag(&img.image)
    )
}

pub fn image_rows(images: &[SystemImage], jobs: &[Job]) -> Vec<ImageRowVm> {
    images
        .iter()
        .map(|img| {
            let installed = img.installed_in.is_some();
            let job = install_job(img, jobs);
            let status = match (installed, job) {
                (true, _) => format!(
                    "{} · {}",
                    crate::i18n::text("Installed", "已安装"),
                    size_or_dash(img.size)
                ),
                (false, Some(j)) => match j.progress {
                    Some(p) if img.size > 0 => format!(
                        "{} · {:.1} / {}",
                        crate::i18n::text("Downloading", "下载中"),
                        f64::from(p) * img.size as f64 / 1e9,
                        model::gb(img.size)
                    ),
                    _ => crate::i18n::text("Downloading…", "下载中…").into(),
                },
                (false, None) => format!(
                    "{} · {}",
                    crate::i18n::text("Download", "下载"),
                    size_or_dash(img.size)
                ),
            };
            ImageRowVm {
                package: img.image.package().into(),
                label: image_label(img).into(),
                status: status.into(),
                installed,
                enabled: job.is_none(),
                play_store: !img.image.allows_adb_root(),
            }
        })
        .collect()
}

fn size_or_dash(bytes: u64) -> String {
    if bytes > 0 {
        model::gb(bytes)
    } else {
        crate::i18n::text("size unknown", "大小未知").into()
    }
}

pub fn profile_options(profiles: &[HardwareProfile]) -> Vec<OptionVm> {
    profiles
        .iter()
        .map(|p| OptionVm {
            id: p.id.clone().into(),
            label: format!("{} · {}×{}", p.name, p.width, p.height).into(),
        })
        .collect()
}

/// A free "Pixel-ish 6.1"-style name: the profile name, numbered if taken.
pub fn free_name(base: &str, taken: &[String]) -> String {
    let base = base.replace('″', "");
    if !taken.iter().any(|t| t.eq_ignore_ascii_case(&base)) {
        return base;
    }
    (2..)
        .map(|n| format!("{base} {n}"))
        .find(|n| !taken.iter().any(|t| t.eq_ignore_ascii_case(n)))
        .unwrap_or(base)
}

/// Root choice for an image: Shell root where adb root works, else None (D7).
pub fn default_root(img: Option<&SystemImage>, preferred: RootChoice) -> RootChoice {
    let shell_ok = img.is_none_or(|i| i.image.allows_adb_root());
    match preferred {
        RootChoice::Shell if !shell_ok => RootChoice::None,
        other => other,
    }
}

/// Defaults for a new device: first profile (`phone-6.1-fhd` if present),
/// newest installed Google APIs image, Shell root where allowed.
pub fn new_form(
    profiles: &[HardwareProfile],
    images: &[SystemImage],
    taken: &[String],
    preferred_root: RootChoice,
) -> DeviceForm {
    let profile = profiles
        .iter()
        .position(|p| p.id == "phone-6.1-fhd")
        .unwrap_or(0);
    let image = images
        .iter()
        .position(|i| i.installed_in.is_some() && i.image.allows_adb_root())
        .or_else(|| images.iter().position(|i| i.installed_in.is_some()))
        .unwrap_or(0);
    let mut form = DeviceForm {
        start_after: true,
        audio: true,
        image: image as i32,
        root: default_root(images.get(image), preferred_root),
        ..Default::default()
    };
    apply_profile(&mut form, profiles, profile);
    form.name = free_name(
        profiles
            .get(profile)
            .map(|p| p.name.as_str())
            .unwrap_or("Phone"),
        taken,
    )
    .into();
    form
}

/// Fills RAM, CPU and screen from a profile.
pub fn apply_profile(form: &mut DeviceForm, profiles: &[HardwareProfile], index: usize) {
    form.profile = index as i32;
    if let Some(p) = profiles.get(index) {
        form.ram_gb = format_gb(p.ram_mb).into();
        form.cpus = p.cpus.to_string().into();
        form.screen = format!("{}×{}", p.width, p.height).into();
        form.density = p.density.to_string().into();
        form.data_gb = format_gb(p.data_mb).into();
    }
}

fn format_gb(mb: u32) -> String {
    if mb.is_multiple_of(1024) {
        (mb / 1024).to_string()
    } else {
        format!("{:.1}", f64::from(mb) / 1024.0)
    }
}

/// The edit form for an existing device.
pub fn edit_form(info: &DeviceInfo, profiles: &[HardwareProfile]) -> DeviceForm {
    DeviceForm {
        edit: true,
        saving: false,
        name: info.device.name.clone().into(),
        profile: profiles
            .iter()
            .position(|p| p.id == info.device.profile)
            .unwrap_or(0) as i32,
        image: -1,
        root: match info.device.root.mode {
            jidr_core::RootMode::None => RootChoice::None,
            jidr_core::RootMode::Adb => RootChoice::Shell,
            jidr_core::RootMode::Magisk => RootChoice::Full,
        },
        ram_gb: format_gb(info.ram_mb).into(),
        cpus: info.cpus.to_string().into(),
        screen: format!("{}×{}", info.width, info.height).into(),
        resolution_preset: match (info.width, info.height) {
            (720, 1280) => 1,
            (1080, 1920) => 2,
            (1080, 2400) => 3,
            (1280, 720) => 4,
            (1920, 1080) => 5,
            _ => 0,
        },
        custom_width: info.width.to_string().into(),
        custom_height: info.height.to_string().into(),
        density: info.density.to_string().into(),
        data_gb: Default::default(),
        audio: info.device.launch.audio.unwrap_or(true),
        quick_boot_mode: match info.device.launch.quick_boot {
            None => 0,
            Some(true) => 1,
            Some(false) => 2,
        },
        hibernate_global: info.device.auto_hibernate_minutes.is_none(),
        hibernate_minutes: info
            .device
            .auto_hibernate_minutes
            .unwrap_or(0)
            .to_string()
            .into(),
        can_cold_start: matches!(
            info.device.status,
            jidr_core::DeviceStatus::Stopped | jidr_core::DeviceStatus::Crashed { .. }
        ) && info.device.launch.resume_snapshot.is_none(),
        camera_back: camera_index(camera_of(&info.device, "-camera-back").as_deref()),
        camera_front: camera_index(camera_of(&info.device, "-camera-front").as_deref()),
        data_path: Default::default(),
        disk_usage: info
            .disk_bytes
            .map(model::gb)
            .unwrap_or_else(|| "—".into())
            .into(),
        stream_quality: 1,
        start_after: false,
        error: Default::default(),
        play_store: !info.device.image.allows_adb_root(),
    }
}

fn camera_of(device: &jidr_core::Device, flag: &str) -> Option<String> {
    device
        .launch
        .extra_args
        .iter()
        .rposition(|arg| arg == flag)
        .and_then(|index| device.launch.extra_args.get(index + 1))
        .cloned()
        .or_else(|| match flag {
            "-camera-back" => device.launch.camera_back.clone(),
            "-camera-front" => device.launch.camera_front.clone(),
            _ => None,
        })
}

fn camera_index(value: Option<&str>) -> i32 {
    match value {
        None => 0,
        Some("emulated") => 1,
        Some("virtualscene") => 2,
        Some("webcam0") => 3,
        Some("webcam1") => 4,
        Some("none") => 5,
        _ => -1,
    }
}

fn camera_value(index: i32) -> Option<&'static str> {
    match index {
        0 => Some("default"),
        1 => Some("emulated"),
        2 => Some("virtualscene"),
        3 => Some("webcam0"),
        4 => Some("webcam1"),
        5 => Some("none"),
        _ => None,
    }
}

struct Hardware {
    ram_mb: u32,
    cpus: u32,
    width: u32,
    height: u32,
    density: u32,
}

fn parse_hardware(form: &DeviceForm) -> Result<Hardware, String> {
    let ram: f64 = form.ram_gb.trim().parse().map_err(|_| {
        crate::i18n::text(
            "RAM must be a number of GB, like 4.",
            "内存必须是以 GB 为单位的数字，例如 4。",
        )
        .to_string()
    })?;
    if !(0.5..=64.0).contains(&ram) {
        return Err(crate::i18n::text(
            "RAM must be between 0.5 and 64 GB.",
            "内存必须介于 0.5 到 64 GB 之间。",
        )
        .into());
    }
    let cpus: u32 = form.cpus.trim().parse().map_err(|_| {
        crate::i18n::text(
            "CPU cores must be a whole number.",
            "CPU 核心数必须是整数。",
        )
        .to_string()
    })?;
    if !(1..=16).contains(&cpus) {
        return Err(crate::i18n::text(
            "CPU cores must be between 1 and 16.",
            "CPU 核心数必须介于 1 到 16 之间。",
        )
        .into());
    }
    let (w, h) = form
        .screen
        .split(['×', 'x', 'X'])
        .map(|s| s.trim().parse::<u32>())
        .collect::<Result<Vec<_>, _>>()
        .ok()
        .and_then(|v| match v.as_slice() {
            [w, h] => Some((*w, *h)),
            _ => None,
        })
        .ok_or_else(|| {
            crate::i18n::text(
                "Screen must look like 1080×2400.",
                "屏幕尺寸格式应为 1080×2400。",
            )
            .to_string()
        })?;
    if !(240..=4096).contains(&w) || !(240..=4096).contains(&h) {
        return Err(crate::i18n::text(
            "Screen sides must be between 240 and 4096 pixels.",
            "屏幕每边必须介于 240 到 4096 像素之间。",
        )
        .into());
    }
    let density: u32 = form.density.trim().parse().map_err(|_| {
        crate::i18n::text("DPI must be a whole number.", "DPI 必须是整数。").to_string()
    })?;
    if !(72..=1000).contains(&density) {
        return Err(crate::i18n::text(
            "DPI must be between 72 and 1000.",
            "DPI 必须介于 72 到 1000 之间。",
        )
        .into());
    }
    Ok(Hardware {
        ram_mb: (ram * 1024.0).round() as u32,
        cpus,
        width: w,
        height: h,
        density,
    })
}

fn check_name(name: &str) -> Result<String, String> {
    let name = name.trim();
    if name.is_empty() {
        return Err(crate::i18n::text("Give the device a name.", "请为设备输入名称。").into());
    }
    Ok(name.to_string())
}

pub fn root_mode(c: RootChoice) -> &'static str {
    match c {
        RootChoice::None => "none",
        RootChoice::Shell => "adb",
        RootChoice::Full => "magisk",
    }
}

/// `device.create` params; only values that differ from the profile are sent.
pub fn create_params(
    form: &DeviceForm,
    profiles: &[HardwareProfile],
    images: &[SystemImage],
) -> Result<Value, String> {
    let name = check_name(&form.name)?;
    let img = usize::try_from(form.image)
        .ok()
        .and_then(|i| images.get(i))
        .ok_or_else(|| {
            crate::i18n::text("Pick an Android version.", "请选择 Android 版本。").to_string()
        })?;
    if form.root == RootChoice::Shell && !img.image.allows_adb_root() {
        return Err(crate::i18n::text(
            "Play Store images don't allow adb root.",
            "Play 商店镜像不允许 adb root。",
        )
        .into());
    }
    let hw = parse_hardware(form)?;
    let data_gb: u32 = form.data_gb.trim().parse().map_err(|_| {
        crate::i18n::text(
            "Storage must be a whole number of GB.",
            "存储容量必须是整数 GB。",
        )
    })?;
    if !(2..=256).contains(&data_gb) {
        return Err(crate::i18n::text(
            "Storage must be between 2 and 256 GB.",
            "存储容量必须介于 2 到 256 GB 之间。",
        )
        .into());
    }
    let data_mb = data_gb * 1024;
    let profile = usize::try_from(form.profile)
        .ok()
        .and_then(|i| profiles.get(i));
    let mut p = Map::new();
    p.insert("name".into(), json!(name));
    p.insert("image".into(), json!(img.image.package()));
    if profile.is_none_or(|prof| prof.data_mb != data_mb) {
        p.insert("data_mb".into(), json!(data_mb));
    }
    if form.audio != profile.map(|p| p.audio).unwrap_or(true) {
        p.insert("audio".into(), json!(form.audio));
    }
    p.insert("root_mode".into(), json!(root_mode(form.root)));
    if let Some(prof) = profile {
        p.insert("profile".into(), json!(prof.id));
        if prof.ram_mb != hw.ram_mb {
            p.insert("ram_mb".into(), json!(hw.ram_mb));
        }
        if prof.cpus != hw.cpus {
            p.insert("cpus".into(), json!(hw.cpus));
        }
        if (prof.width, prof.height) != (hw.width, hw.height) {
            p.insert("width".into(), json!(hw.width));
            p.insert("height".into(), json!(hw.height));
        }
        if prof.density != hw.density {
            p.insert("density".into(), json!(hw.density));
        }
    }
    Ok(Value::Object(p))
}

/// `device.edit` params for the fields that changed.
pub fn edit_params(form: &DeviceForm, info: &DeviceInfo) -> Result<Value, String> {
    let name = check_name(&form.name)?;
    let hw = parse_hardware(form)?;
    let mut p = Map::new();
    p.insert("device".into(), json!(info.device.id));
    let quick_boot = match form.quick_boot_mode {
        0 => None,
        1 => Some(true),
        2 => Some(false),
        _ => {
            return Err(
                crate::i18n::text("Invalid quick-boot option.", "快速启动选项无效。").into(),
            );
        }
    };
    let auto_hibernate = if form.hibernate_global {
        None
    } else {
        let value: u32 = form.hibernate_minutes.trim().parse().map_err(|_| {
            crate::i18n::text(
                "Idle minutes must be a whole number.",
                "空闲时间必须为整数分钟。",
            )
        })?;
        if value > 1440 {
            return Err(crate::i18n::text(
                "Idle minutes must be 0–1440.",
                "空闲时间必须介于 0 到 1440 分钟。",
            )
            .into());
        }
        Some(value)
    };
    if quick_boot != info.device.launch.quick_boot {
        if info.device.status.is_active() {
            return Err(crate::i18n::text(
                "Stop the device before changing quick boot.",
                "请先停止设备，再修改快速启动。",
            )
            .into());
        }
        p.insert("quick_boot".into(), json!(quick_boot));
    }
    if auto_hibernate != info.device.auto_hibernate_minutes {
        p.insert("auto_hibernate_minutes".into(), json!(auto_hibernate));
    }
    if form.audio != info.device.launch.audio.unwrap_or(true) {
        p.insert("audio".into(), json!(form.audio));
    }
    for (key, flag, index) in [
        ("camera_back", "-camera-back", form.camera_back),
        ("camera_front", "-camera-front", form.camera_front),
    ] {
        let old = camera_index(camera_of(&info.device, flag).as_deref());
        if index != old {
            let value = camera_value(index)
                .ok_or_else(|| crate::i18n::text("Invalid camera source.", "摄像头来源无效。"))?;
            if key == "camera_front" && value == "virtualscene" {
                return Err(crate::i18n::text(
                    "Virtual scene is only available for the back camera.",
                    "虚拟场景仅支持后置摄像头。",
                )
                .into());
            }
            p.insert(key.into(), json!(value));
        }
    }
    if name != info.device.name {
        p.insert("name".into(), json!(name));
    }
    if hw.ram_mb != info.ram_mb {
        p.insert("ram_mb".into(), json!(hw.ram_mb));
    }
    if hw.cpus != info.cpus {
        p.insert("cpus".into(), json!(hw.cpus));
    }
    if (hw.width, hw.height) != (info.width, info.height) {
        p.insert("width".into(), json!(hw.width));
        p.insert("height".into(), json!(hw.height));
    }
    if hw.density != info.density {
        p.insert("density".into(), json!(hw.density));
    }
    let hardware_changed = ["ram_mb", "cpus", "width", "height", "density"]
        .iter()
        .any(|field| p.contains_key(*field));
    let root_changed = crate::root::mode_of(form.root) != info.device.root.mode;
    if info.device.status.is_active() && (hardware_changed || root_changed) {
        return Err(crate::i18n::text(
            "Stop the device before changing RAM, CPU, screen or root mode.",
            "请先停止设备，再修改内存、CPU、屏幕或 Root 模式。",
        )
        .into());
    }
    Ok(Value::Object(p))
}

#[cfg(test)]
mod tests {
    use super::*;
    use jidr_core::ImageRef;

    fn img(api: u32, tag: &str, installed: bool) -> SystemImage {
        SystemImage {
            image: ImageRef {
                api,
                tag: tag.into(),
                abi: "arm64-v8a".into(),
            },
            display: String::new(),
            revision: "1".into(),
            support: Support::for_api(api),
            size: 2_000_000_000,
            license: None,
            installed_in: installed.then(|| "/sdk".into()),
            pristine_ramdisk_sha256: None,
        }
    }

    fn profiles() -> Vec<HardwareProfile> {
        jidr_core::provider::parse_params(serde_json::json!([
            {"id": "small-phone-5", "name": "Small phone 5″", "width": 720, "height": 1280, "density": 320, "ram_mb": 2048, "cpus": 2},
            {"id": "phone-6.1-fhd", "name": "Phone 6.1″ FHD+", "width": 1080, "height": 2400, "density": 420, "ram_mb": 4096, "cpus": 4}
        ]))
        .unwrap()
    }

    #[test]
    fn images_sort_newest_first_and_drop_unsupported() {
        let v = sorted_images(&[
            img(33, "google_apis_playstore", true),
            img(35, "google_apis", true),
            img(26, "google_apis", true),
            img(35, "google_apis_playstore", false),
        ]);
        let labels: Vec<_> = v.iter().map(image_label).collect();
        assert_eq!(
            labels,
            [
                "Android 15 · API 35 · Google APIs",
                "Android 15 · API 35 · Play Store",
                "Android 13 · API 33 · Play Store"
            ]
        );
    }

    #[test]
    fn defaults_follow_d7() {
        let images = sorted_images(&[
            img(35, "google_apis", true),
            img(33, "google_apis_playstore", true),
        ]);
        let f = new_form(
            &profiles(),
            &images,
            &["Phone 6.1 FHD+".into()],
            RootChoice::Shell,
        );
        assert_eq!(f.profile, 1);
        assert_eq!(f.image, 0);
        assert_eq!(f.root, RootChoice::Shell);
        assert_eq!(f.name, "Phone 6.1 FHD+ 2");
        assert_eq!(
            (f.ram_gb.as_str(), f.cpus.as_str(), f.screen.as_str()),
            ("4", "4", "1080×2400")
        );
        assert_eq!(
            default_root(images.get(1), RootChoice::Shell),
            RootChoice::None
        );
    }

    #[test]
    fn create_params_send_only_overrides_and_validate() {
        let images = sorted_images(&[
            img(35, "google_apis", true),
            img(33, "google_apis_playstore", true),
        ]);
        let mut f = new_form(&profiles(), &images, &[], RootChoice::Shell);
        let p = create_params(&f, &profiles(), &images).unwrap();
        assert_eq!(p["profile"], "phone-6.1-fhd");
        assert_eq!(p["root_mode"], "adb");
        assert!(p.get("audio").is_none());
        f.audio = false;
        assert_eq!(
            create_params(&f, &profiles(), &images).unwrap()["audio"],
            false
        );
        assert!(p.get("ram_mb").is_none());
        assert!(p.get("data_mb").is_none());
        f.data_gb = "16".into();
        assert_eq!(
            create_params(&f, &profiles(), &images).unwrap()["data_mb"],
            16384
        );
        f.data_gb = "1".into();
        assert!(create_params(&f, &profiles(), &images).is_err());
        f.data_gb = "16".into();
        f.ram_gb = "6".into();
        f.screen = "1440x3120".into();
        let p = create_params(&f, &profiles(), &images).unwrap();
        assert_eq!(p["ram_mb"], 6144);
        assert_eq!(
            (p["width"].as_u64(), p["height"].as_u64()),
            (Some(1440), Some(3120))
        );
        f.image = 1;
        assert!(
            create_params(&f, &profiles(), &images)
                .unwrap_err()
                .contains("Play Store")
        );
        f.root = RootChoice::Full;
        f.cpus = "x".into();
        assert!(
            create_params(&f, &profiles(), &images)
                .unwrap_err()
                .contains("CPU")
        );
        f.cpus = "4".into();
        f.name = "  ".into();
        assert!(
            create_params(&f, &profiles(), &images)
                .unwrap_err()
                .contains("name")
        );
    }

    #[test]
    fn audio_edit_preserves_existing_setting_unless_changed() {
        let mut info = crate::fixtures::device_infos().remove(0);
        info.device.launch.audio = Some(false);
        let mut form = edit_form(&info, &profiles());
        assert!(!form.audio);
        assert!(edit_params(&form, &info).unwrap().get("audio").is_none());
        form.audio = true;
        assert_eq!(edit_params(&form, &info).unwrap()["audio"], true);
    }

    #[test]
    fn camera_edit_respects_legacy_arguments_and_validates_front_source() {
        let mut info = crate::fixtures::device_infos().remove(0);
        info.device.launch.camera_back = Some("emulated".into());
        info.device.launch.extra_args = vec!["-camera-back".into(), "webcam0".into()];
        let mut form = edit_form(&info, &profiles());
        assert_eq!(form.camera_back, 3);
        assert!(
            edit_params(&form, &info)
                .unwrap()
                .get("camera_back")
                .is_none()
        );
        form.camera_back = 1;
        assert_eq!(
            edit_params(&form, &info).unwrap()["camera_back"],
            "emulated"
        );
        form.camera_front = 2;
        assert!(edit_params(&form, &info).is_err());
    }

    #[test]
    fn startup_settings_keep_inherited_and_explicit_values_distinct() {
        let mut info = crate::fixtures::device_infos().remove(0);
        info.device.status = jidr_core::DeviceStatus::Stopped;
        let mut form = edit_form(&info, &profiles());
        let unchanged = edit_params(&form, &info).unwrap();
        assert!(unchanged.get("quick_boot").is_none());
        assert!(unchanged.get("auto_hibernate_minutes").is_none());
        form.quick_boot_mode = 2;
        form.hibernate_global = false;
        form.hibernate_minutes = "30".into();
        let changed = edit_params(&form, &info).unwrap();
        assert_eq!(changed["quick_boot"], false);
        assert_eq!(changed["auto_hibernate_minutes"], 30);
        info.device.status = jidr_core::DeviceStatus::Running;
        assert!(edit_params(&form, &info).is_err());
        info.device.status = jidr_core::DeviceStatus::Stopped;
        form.hibernate_minutes = "1441".into();
        assert!(edit_params(&form, &info).is_err());
        info.device.launch.quick_boot = Some(false);
        info.device.auto_hibernate_minutes = Some(30);
        form.quick_boot_mode = 0;
        form.hibernate_global = true;
        let inherit = edit_params(&form, &info).unwrap();
        assert!(inherit["quick_boot"].is_null());
        assert!(inherit["auto_hibernate_minutes"].is_null());
    }

    #[test]
    fn active_device_allows_name_and_audio_but_rejects_hardware_and_root() {
        let mut info = crate::fixtures::device_infos().remove(0);
        info.device.status = jidr_core::DeviceStatus::Running;
        let mut form = edit_form(&info, &profiles());
        form.name = "New name".into();
        form.audio = !form.audio;
        assert!(edit_params(&form, &info).is_ok());
        let original = form.clone();
        form.cpus = (info.cpus + 1).to_string().into();
        assert!(edit_params(&form, &info).is_err());
        form = original;
        form.root = RootChoice::None;
        assert!(edit_params(&form, &info).is_err());
        info.device.status = jidr_core::DeviceStatus::Stopped;
        assert!(edit_params(&form, &info).is_ok());
    }

    #[test]
    fn resolution_edits_are_validated_and_sent_for_stopped_devices() {
        let mut info = crate::fixtures::device_infos().remove(0);
        info.device.status = jidr_core::DeviceStatus::Stopped;
        let mut form = edit_form(&info, &profiles());
        form.screen = "720 x 1280".into();
        let params = edit_params(&form, &info).unwrap();
        assert_eq!(params["width"], 720);
        assert_eq!(params["height"], 1280);
        form.screen = "1×1280".into();
        assert!(edit_params(&form, &info).is_err());
        form.screen = "720×1280".into();
        info.device.status = jidr_core::DeviceStatus::Running;
        assert!(edit_params(&form, &info).is_err());
    }

    #[test]
    fn edit_form_initializes_presets_and_custom_dimensions() {
        let mut info = crate::fixtures::device_infos().remove(0);
        info.width = 1080;
        info.height = 2400;
        let form = edit_form(&info, &profiles());
        assert_eq!(form.resolution_preset, 3);
        assert_eq!(form.custom_width, "1080");
        assert_eq!(form.custom_height, "2400");
        info.width = 1111;
        info.height = 2222;
        let form = edit_form(&info, &profiles());
        assert_eq!(form.resolution_preset, 0);
        assert_eq!(form.custom_width, "1111");
        assert_eq!(form.custom_height, "2222");
    }

    #[test]
    fn density_is_validated_and_only_changes_when_requested() {
        let mut info = crate::fixtures::device_infos().remove(0);
        info.device.status = jidr_core::DeviceStatus::Stopped;
        let mut form = edit_form(&info, &profiles());
        assert!(edit_params(&form, &info).unwrap().get("density").is_none());
        form.density = "280".into();
        assert_eq!(edit_params(&form, &info).unwrap()["density"], 280);
        info.device.status = jidr_core::DeviceStatus::Running;
        assert!(edit_params(&form, &info).is_err());
        info.device.status = jidr_core::DeviceStatus::Stopped;
        for bad in ["", "0", "71", "1001", "1.5", "NaN"] {
            form.density = bad.into();
            assert!(edit_params(&form, &info).is_err(), "{bad}");
        }
    }

    #[test]
    fn image_rows_show_install_state() {
        let images = [img(35, "google_apis", true), img(36, "google_apis", false)];
        let rows = image_rows(&images, &[]);
        assert_eq!(rows[0].status, "Installed · 2.0 GB");
        assert_eq!(rows[1].status, "Download · 2.0 GB");
        assert!(rows[1].enabled);
    }

    /// The edit sheet shows root-mode cards (9e); a Play Store device must
    /// keep Shell root disabled there, so the form carries the image kind.
    #[test]
    fn edit_form_knows_play_store_devices() {
        let profiles = profiles();
        let mut info = crate::fixtures::device_infos()[1].clone();
        assert!(!edit_form(&info, &profiles).play_store);
        info.device.image.tag = "google_apis_playstore".into();
        info.device.root.mode = jidr_core::RootMode::Magisk;
        let form = edit_form(&info, &profiles);
        assert!(form.play_store && form.edit);
        assert_eq!(form.root, RootChoice::Full);
    }
}
