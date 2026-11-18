//! The device registry (`devices.json`): Jidr's metadata for every AVD it owns.

use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use jidr_core::{
    Device, DeviceStatus, ErrorCode, ImageRef, JidrError, JidrResult, LaunchPrefs, NetworkShaping,
    ResultExt, RootState,
};
use serde::{Serialize, Serializer};
use uuid::Uuid;

/// Same fields/order as Device, with runtime state removed, borrowing payloads.
#[derive(Serialize)]
struct PersistedDevice<'a> {
    id: Uuid,
    name: &'a str,
    avd: &'a str,
    profile: &'a str,
    image: &'a ImageRef,
    sdk_root: &'a Path,
    root: &'a RootState,
    agent_owned: bool,
    created_at: &'a DateTime<Utc>,
    launch: &'a LaunchPrefs,
    status: &'a DeviceStatus,
    #[serde(skip_serializing_if = "Option::is_none")]
    footprint_mb: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    auto_hibernate_minutes: Option<u32>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    base: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pool_base: Option<Uuid>,
    #[serde(skip_serializing_if = "NetworkShaping::is_off")]
    network_shaping: &'a NetworkShaping,
}

impl<'a> From<&'a Device> for PersistedDevice<'a> {
    fn from(device: &'a Device) -> Self {
        // Exhaustive so adding a Device field requires reviewing persistence.
        let Device {
            id,
            name,
            avd,
            profile,
            image,
            sdk_root,
            root,
            agent_owned,
            created_at,
            launch,
            status,
            runtime: _,
            footprint_mb,
            auto_hibernate_minutes,
            base,
            pool_base,
            network_shaping,
        } = device;
        Self {
            id: *id,
            name,
            avd,
            profile,
            image,
            sdk_root,
            root,
            agent_owned: *agent_owned,
            created_at,
            launch,
            status: if status.is_active() {
                &DeviceStatus::Stopped
            } else {
                status
            },
            footprint_mb: *footprint_mb,
            auto_hibernate_minutes: *auto_hibernate_minutes,
            base: *base,
            pool_base: *pool_base,
            network_shaping,
        }
    }
}

struct PersistedDevices<'a>(&'a [Device]);

impl Serialize for PersistedDevices<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_seq(self.0.iter().map(PersistedDevice::from))
    }
}

#[derive(Debug)]
pub struct DeviceStore {
    path: PathBuf,
    devices: Vec<Device>,
}

impl DeviceStore {
    pub fn load(path: impl Into<PathBuf>) -> JidrResult<Self> {
        let path = path.into();
        let devices = match std::fs::read(&path) {
            Ok(b) => serde_json::from_slice(&b)
                .ctx(ErrorCode::Unexpected, format!("reading {}", path.display()))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => {
                return Err(JidrError::unexpected(format!(
                    "reading {}: {e}",
                    path.display()
                )));
            }
        };
        Ok(Self { path, devices })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    fn save(&self) -> JidrResult<()> {
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir)
                .ctx(ErrorCode::Unexpected, format!("creating {}", dir.display()))?;
        }
        // Runtime fields are not persisted: a restart re-adopts running devices.
        let json = serde_json::to_vec_pretty(&PersistedDevices(&self.devices))
            .ctx(ErrorCode::Unexpected, "encoding devices")?;
        let tmp = self.path.with_extension("json.tmp");
        std::fs::write(&tmp, json)
            .ctx(ErrorCode::Unexpected, format!("writing {}", tmp.display()))?;
        std::fs::rename(&tmp, &self.path).ctx(
            ErrorCode::Unexpected,
            format!("writing {}", self.path.display()),
        )
    }

    pub fn all(&self) -> &[Device] {
        &self.devices
    }

    /// By id, or by name (case-insensitive).
    pub fn find(&self, selector: &str) -> JidrResult<&Device> {
        let by_id = Uuid::parse_str(selector).ok();
        self.devices
            .iter()
            .find(|d| Some(d.id) == by_id || d.name.eq_ignore_ascii_case(selector))
            .ok_or_else(|| JidrError::not_found(format!("no device named {selector:?}")))
    }

    pub fn get(&self, id: Uuid) -> JidrResult<&Device> {
        self.devices
            .iter()
            .find(|d| d.id == id)
            .ok_or_else(|| JidrError::not_found(format!("no device {id}")))
    }

    pub fn name_taken(&self, name: &str, except: Option<Uuid>) -> bool {
        self.devices
            .iter()
            .any(|d| d.name.eq_ignore_ascii_case(name) && Some(d.id) != except)
    }

    /// A free AVD id derived from a display name: `My Phone` → `My_Phone`.
    pub fn avd_id_for(&self, name: &str, exists: impl Fn(&str) -> bool) -> String {
        let base: String = name
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_') {
                    c
                } else {
                    '_'
                }
            })
            .collect::<String>()
            .trim_start_matches('.')
            .chars()
            .take(48)
            .collect();
        let base = if base.is_empty() {
            "device".to_string()
        } else {
            base
        };
        let taken = |id: &str| exists(id) || self.devices.iter().any(|d| d.avd == id);
        if !taken(&base) {
            return base;
        }
        (2..)
            .map(|n| format!("{base}_{n}"))
            .find(|c| !taken(c))
            .unwrap_or(base)
    }

    pub fn insert(&mut self, device: Device) -> JidrResult<()> {
        if self.name_taken(&device.name, None) {
            return Err(JidrError::usage(format!(
                "a device named {:?} already exists",
                device.name
            )));
        }
        self.devices.push(device);
        self.save()
    }

    /// Updates a device in memory and on disk.
    pub fn update(&mut self, id: Uuid, f: impl FnOnce(&mut Device)) -> JidrResult<Device> {
        let d = self
            .devices
            .iter_mut()
            .find(|d| d.id == id)
            .ok_or_else(|| JidrError::not_found(format!("no device {id}")))?;
        f(d);
        let out = d.clone();
        self.save()?;
        Ok(out)
    }

    /// Runtime-only change (status, runtime): not written to disk.
    pub fn set_runtime(&mut self, id: Uuid, f: impl FnOnce(&mut Device)) -> Option<Device> {
        let d = self.devices.iter_mut().find(|d| d.id == id)?;
        f(d);
        Some(d.clone())
    }

    pub fn remove(&mut self, id: Uuid) -> JidrResult<Device> {
        let i = self
            .devices
            .iter()
            .position(|d| d.id == id)
            .ok_or_else(|| JidrError::not_found(format!("no device {id}")))?;
        let d = self.devices.remove(i);
        self.save()?;
        Ok(d)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use jidr_core::{DeviceRuntime, RootHealth, RootMode};

    fn device(name: &str) -> Device {
        Device {
            id: Uuid::new_v4(),
            name: name.into(),
            avd: name.replace(' ', "_"),
            profile: "phone-6.1-fhd".into(),
            image: ImageRef {
                api: 35,
                tag: "google_apis".into(),
                abi: "arm64-v8a".into(),
            },
            sdk_root: "/sdk".into(),
            root: Default::default(),
            agent_owned: false,
            created_at: chrono::Utc::now(),
            launch: Default::default(),
            status: Default::default(),
            runtime: None,
            footprint_mb: None,
            auto_hibernate_minutes: None,
            base: false,
            pool_base: None,
            network_shaping: Default::default(),
        }
    }

    #[test]
    fn borrowed_persistence_matches_previous_bytes_and_preserves_live_state() {
        let dir = tempfile::tempdir().unwrap();
        let mut populated = device("设备 العربية 🙂\n");
        populated.root = RootState {
            mode: RootMode::Magisk,
            writable_system: true,
            magisk_version: Some("30.0".into()),
            patched_ramdisk_path: Some("/tmp/设备/ramdisk.img".into()),
            verified_at: Some(Utc::now()),
            health: RootHealth::Ok,
            auto_grant_all: true,
        };
        populated.agent_owned = true;
        populated.launch = LaunchPrefs {
            ramdisk: Some("/tmp/设备/ramdisk.img".into()),
            extra_args: vec!["-verbose".into(), "argument\nwith quotes \"".repeat(4096)],
            gpu: Some("host".into()),
            force_cold_boot: true,
            quick_boot: Some(false),
            camera_back: Some("webcam0".into()),
            camera_front: Some("none".into()),
            audio: Some(false),
            resume_snapshot: Some("saved".into()),
        };
        populated.footprint_mb = Some(7800);
        populated.auto_hibernate_minutes = Some(0);
        populated.base = true;
        populated.pool_base = Some(Uuid::new_v4());
        populated.network_shaping = jidr_core::NetworkShaping {
            loss_pct: 12.5,
            dns: jidr_core::DnsMode::Slow,
            dns_delay_ms: Some(3000),
        };
        let runtime = DeviceRuntime {
            pid: 123,
            console_port: 5554,
            adb_serial: "emulator-5554".into(),
            grpc_port: 8554,
            started_at: Utc::now(),
        };
        let mut devices = Vec::new();
        for template in [device("default"), populated] {
            for status in [
                DeviceStatus::Stopped,
                DeviceStatus::Starting,
                DeviceStatus::Booting,
                DeviceStatus::Running,
                DeviceStatus::Stopping,
                DeviceStatus::Hibernated,
                DeviceStatus::Crashed {
                    reason: "失去连接\n\"error\"".into(),
                    log: Some("/tmp/设备/emulator.log".into()),
                },
            ] {
                for runtime in [None, Some(runtime.clone())] {
                    let mut d = template.clone();
                    d.status = status.clone();
                    d.runtime = runtime;
                    devices.push(d);
                }
            }
        }

        let path = dir.path().join("devices.json");
        let mut store = DeviceStore {
            path: path.clone(),
            devices: devices.clone(),
        };
        // Keep the original cloning path as the byte-for-byte reference.
        let previous: Vec<Device> = devices
            .iter()
            .cloned()
            .map(|mut d| {
                d.runtime = None;
                if d.status.is_active() {
                    d.status = DeviceStatus::Stopped;
                }
                d
            })
            .collect();
        store.save().unwrap();
        assert_eq!(
            std::fs::read(&path).unwrap(),
            serde_json::to_vec_pretty(&previous).unwrap()
        );
        assert_eq!(store.devices, devices, "live state must not be modified");
        assert_eq!(DeviceStore::load(&path).unwrap().devices, previous);
        assert!(!path.with_extension("json.tmp").exists());
        store.devices.clear();
        store.save().unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"[]");
    }

    #[test]
    fn insert_find_update_remove_persist() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("devices.json");
        let mut s = DeviceStore::load(&path).unwrap();
        let a = device("My Phone");
        s.insert(a.clone()).unwrap();
        assert_eq!(
            s.insert(device("my phone")).unwrap_err().code,
            ErrorCode::Usage,
            "names are unique, case-insensitive"
        );
        assert_eq!(s.find("MY PHONE").unwrap().id, a.id);
        assert_eq!(s.find(&a.id.to_string()).unwrap().name, "My Phone");
        assert_eq!(s.find("nope").unwrap_err().code, ErrorCode::NotFound);

        s.update(a.id, |d| d.agent_owned = true).unwrap();
        s.set_runtime(a.id, |d| {
            d.status = DeviceStatus::Running;
            d.runtime = Some(DeviceRuntime {
                pid: 1,
                console_port: 5554,
                adb_serial: "emulator-5554".into(),
                grpc_port: 1,
                started_at: chrono::Utc::now(),
            });
        });
        s.update(a.id, |_| {}).unwrap();
        let reloaded = DeviceStore::load(&path).unwrap();
        let d = reloaded.find("My Phone").unwrap();
        assert!(d.agent_owned);
        assert_eq!(
            d.status,
            DeviceStatus::Stopped,
            "runtime state is not persisted"
        );
        assert!(d.runtime.is_none());

        s.remove(a.id).unwrap();
        assert!(DeviceStore::load(&path).unwrap().all().is_empty());
    }

    #[test]
    fn avd_ids_are_sanitized_and_unique() {
        let dir = tempfile::tempdir().unwrap();
        let mut s = DeviceStore::load(dir.path().join("d.json")).unwrap();
        assert_eq!(s.avd_id_for("My Phone 6.1″", |_| false), "My_Phone_6.1_");
        assert_eq!(s.avd_id_for(".hidden", |_| false), "hidden");
        assert_eq!(s.avd_id_for("ü", |_| false), "_");
        s.insert(device("Pixel")).unwrap();
        assert_eq!(s.avd_id_for("Pixel", |_| false), "Pixel_2");
        assert_eq!(s.avd_id_for("Other", |id| id == "Other"), "Other_2");
    }
}
