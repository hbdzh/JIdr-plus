//! Hibernate (D42, Phase 13c): save a running device's whole state under a
//! name, check it really holds memory, then end the emulator without the
//! quick-boot save. The device uses no host RAM until `device.start` resumes
//! it from that snapshot, in seconds. Pausing alone would only free CPU.

use chrono::Utc;
use jidr_core::provider::DaemonContext;
use jidr_core::{Device, DeviceStatus, JidrError, JidrResult};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::state::{State, lock};

/// The snapshot a hibernated device resumes from.
pub const SNAPSHOT: &str = "jidr-hibernate";

impl State {
    /// `device.hibernate`. Callers hold the device lock. When the save fails
    /// or leaves an empty `ram.bin`, the device keeps running.
    pub async fn hibernate(&self, id: Uuid) -> JidrResult<Device> {
        let d = self.with_store(|s| s.get(id).cloned())?;
        let info = self
            .instance(id)
            .ok_or_else(|| JidrError::not_found(format!("{} is not running", d.name)))?;
        let avd_dir = self.avds().dir(&d.avd);
        // Never overwrite unreadable snapshot metadata with an empty map.
        let tags = read_snapshot_tags(&avd_dir)?;
        self.backend
            .save_snapshot(&info, SNAPSHOT, &avd_dir)
            .await?;
        jidr_sdk::avd::check_snapshot(&avd_dir, SNAPSHOT)
            .map_err(|e| JidrError::sdk(format!("hibernating {}: {}", d.name, e.message)))?;
        tag_snapshot(&avd_dir, &d, tags)?;

        if let Some(w) = lock(&self.watchers).remove(&id) {
            w.abort();
        }
        lock(&self.instances).remove(&id);
        self.set_status(id, DeviceStatus::Stopping, None);
        if let Err(e) = self.backend.stop_without_save(&info).await {
            lock(&self.instances).insert(id, info.clone());
            self.set_status(id, DeviceStatus::Running, None);
            self.watch_crash(id, info);
            return Err(e);
        }
        self.finish_footprint(id);
        lock(&self.activity).remove(&id);
        self.with_store(|s| s.update(id, |d| d.launch.resume_snapshot = Some(SNAPSHOT.into())))?;
        self.set_status(id, DeviceStatus::Hibernated, Some(None));
        self.emit("device.hibernated", json!({ "device": id, "name": d.name }));
        self.with_store(|s| s.get(id).cloned())
    }
}

/// Records the device's root mode on the snapshot, in the snapshot
/// manager's `jidr/snapshots.json`, so the root tag travels with it (D29).
fn read_snapshot_tags(avd_dir: &std::path::Path) -> JidrResult<serde_json::Map<String, Value>> {
    let path = avd_dir.join("jidr").join("snapshots.json");
    match std::fs::read(&path) {
        Ok(data) => serde_json::from_slice(&data).map_err(|e| {
            JidrError::sdk(format!(
                "invalid snapshot metadata at {}: {e}",
                path.display()
            ))
        }),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Default::default()),
        Err(e) => Err(JidrError::sdk(format!(
            "cannot read snapshot metadata at {}: {e}",
            path.display()
        ))),
    }
}

fn tag_snapshot(
    avd_dir: &std::path::Path,
    d: &Device,
    mut tags: serde_json::Map<String, Value>,
) -> JidrResult<()> {
    let path = avd_dir.join("jidr").join("snapshots.json");
    let mut tag = json!({
        "label": "Hibernated",
        "root_mode": d.root.mode,
        "created_at": Utc::now(),
    });
    if let Some(v) = &d.root.magisk_version {
        tag["magisk_version"] = json!(v);
    }
    tags.insert(SNAPSHOT.into(), tag);
    let text =
        serde_json::to_string_pretty(&tags).map_err(|e| JidrError::unexpected(e.to_string()))?;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)
            .map_err(|e| JidrError::unexpected(format!("{}: {e}", dir.display())))?;
    }
    use std::io::Write as _;
    let tmp = path.with_file_name(format!(".snapshots-{}.tmp", Uuid::new_v4()));
    let result = (|| -> std::io::Result<()> {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)?;
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        std::fs::rename(&tmp, &path)?;
        if let Some(dir) = path.parent() {
            std::fs::File::open(dir)?.sync_all()?;
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result.map_err(|e| JidrError::unexpected(format!("{}: {e}", path.display())))
}

#[cfg(test)]
mod tests {
    #[test]
    fn malformed_snapshot_metadata_is_not_replaced() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("jidr/snapshots.json");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, b"not json").unwrap();
        assert!(super::read_snapshot_tags(root.path()).is_err());
        assert_eq!(std::fs::read(path).unwrap(), b"not json");
    }
}
