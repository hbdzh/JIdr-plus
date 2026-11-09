//! Where Jidr keeps its files. Everything Jidr writes lives under these
//! directories; the Android Studio SDK and `~/.android/avd` are never written (D3).

use std::path::{Path, PathBuf};

use crate::error::{JidrError, JidrResult};
use serde::{Deserialize, Serialize};

/// Set to put every Jidr directory under one root (tests, portable installs).
pub const JIDR_HOME_ENV: &str = "JIDR_HOME";

/// Kept outside the movable Jidr data directory so startup can find it.
pub fn default_location_file() -> JidrResult<PathBuf> {
    Ok(dirs::config_dir()
        .ok_or_else(|| JidrError::unexpected("no configuration directory for this user"))?
        .join("Jidr-storage-location.json"))
}

/// A portable root is identified by a marker as well as its path. This avoids
/// mistaking an empty directory for a missing external drive after unplugging.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PortableLocation {
    pub root: PathBuf,
    pub marker: uuid::Uuid,
}

impl PortableLocation {
    pub const MARKER_FILE: &'static str = ".jidr-storage-id";

    /// Called only on a freshly prepared staging directory, before activation.
    /// Refuses to overwrite an existing marker.
    pub fn write_marker(&self) -> std::io::Result<()> {
        use std::io::Write as _;
        if !self.root.is_absolute() || !self.root.is_dir() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "storage root must be an existing absolute directory",
            ));
        }
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(self.root.join(Self::MARKER_FILE))?;
        writeln!(file, "{}", self.marker)?;
        file.sync_all()
    }

    /// Never fall back to an empty default when the selected root is missing
    /// or has a different identity.
    pub fn resolve(&self) -> JidrResult<JidrPaths> {
        if !self.root.is_absolute() || !self.root.is_dir() {
            return Err(JidrError::unexpected(format!(
                "selected Jidr storage is unavailable: {}",
                self.root.display()
            )));
        }
        let marker_path = self.root.join(Self::MARKER_FILE);
        let metadata = std::fs::symlink_metadata(&marker_path).map_err(|_| {
            JidrError::unexpected(format!(
                "Jidr storage marker is missing: {}",
                marker_path.display()
            ))
        })?;
        if !metadata.file_type().is_file() {
            return Err(JidrError::unexpected("invalid Jidr storage marker"));
        }
        let text = std::fs::read_to_string(&marker_path)
            .map_err(|e| JidrError::unexpected(format!("reading Jidr storage marker: {e}")))?;
        if text.trim().parse::<uuid::Uuid>().ok() != Some(self.marker) {
            return Err(JidrError::unexpected(
                "selected Jidr storage has a different identity",
            ));
        }
        let paths = JidrPaths::under(&self.root);
        if !paths.data.is_dir() {
            return Err(JidrError::unexpected(
                "selected Jidr storage has no data directory",
            ));
        }
        Ok(paths)
    }
}

/// Reads a stable location pointer. A missing pointer means the platform
/// default, but malformed or unavailable configured storage is an error.
pub fn read_location_file(path: &Path) -> JidrResult<Option<PortableLocation>> {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => {
            return Err(JidrError::unexpected(format!(
                "reading storage location: {e}"
            )));
        }
    };
    let location: PortableLocation = serde_json::from_slice(&bytes)
        .map_err(|e| JidrError::unexpected(format!("invalid storage location: {e}")))?;
    location.resolve()?;
    Ok(Some(location))
}

/// Atomically installs a pointer after the complete target has been checked.
/// This does not stop devices or perform a migration. If an error occurs
/// after the rename, callers must re-read the pointer before retrying because
/// the rename may already have committed.
pub fn write_location_file(path: &Path, location: &PortableLocation) -> JidrResult<()> {
    use std::io::Write as _;
    location.resolve()?;
    let parent = path
        .parent()
        .ok_or_else(|| JidrError::unexpected("invalid location pointer path"))?;
    let tmp = parent.join(format!(".jidr-location-{}.tmp", uuid::Uuid::new_v4()));
    let result = (|| -> std::io::Result<()> {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)?;
        serde_json::to_writer_pretty(&mut file, location)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        std::fs::rename(&tmp, path)?;
        std::fs::File::open(parent)?.sync_all()
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result.map_err(|e| JidrError::unexpected(format!("saving storage location: {e}")))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JidrPaths {
    /// `~/Library/Application Support/Jidr`
    pub data: PathBuf,
    /// `~/Library/Caches/Jidr`
    pub cache: PathBuf,
    /// `~/Library/Logs/Jidr`
    pub logs: PathBuf,
}

impl JidrPaths {
    /// Platform defaults, or everything under `$JIDR_HOME` when set.
    pub fn discover() -> JidrResult<Self> {
        if let Some(home) = std::env::var_os(JIDR_HOME_ENV).filter(|h| !h.is_empty()) {
            return Ok(Self::under(PathBuf::from(home)));
        }
        if let Some(location) = read_location_file(&default_location_file()?)? {
            return location.resolve();
        }
        let data = dirs::data_dir()
            .ok_or_else(|| JidrError::unexpected("no data directory for this user"))?
            .join("Jidr");
        let cache = dirs::cache_dir()
            .ok_or_else(|| JidrError::unexpected("no cache directory for this user"))?
            .join("Jidr");
        let logs = if cfg!(target_os = "macos") {
            dirs::home_dir()
                .ok_or_else(|| JidrError::unexpected("no home directory"))?
                .join("Library/Logs/Jidr")
        } else {
            data.join("logs")
        };
        Ok(Self { data, cache, logs })
    }

    /// All directories under one root.
    pub fn under(root: impl Into<PathBuf>) -> Self {
        let root = root.into();
        Self {
            data: root.join("data"),
            cache: root.join("cache"),
            logs: root.join("logs"),
        }
    }

    /// Jidr's private Android SDK.
    pub fn sdk(&self) -> PathBuf {
        self.data.join("sdk")
    }

    /// Jidr's AVD home (`ANDROID_AVD_HOME` for every emulator we launch).
    pub fn avd_home(&self) -> PathBuf {
        self.data.join("avd")
    }

    /// The device registry.
    pub fn devices_file(&self) -> PathBuf {
        self.data.join("devices.json")
    }

    /// Daemon-wide settings (gap B4).
    pub fn settings_file(&self) -> PathBuf {
        self.data.join("settings.json")
    }

    /// License consent records (D8).
    pub fn consent_file(&self) -> PathBuf {
        self.data.join("consent.json")
    }

    /// The daemon's Unix socket.
    pub fn socket(&self) -> PathBuf {
        self.data.join("daemon.sock")
    }

    /// Download cache (SDK archives, Magisk APKs by SHA-256).
    pub fn downloads(&self) -> PathBuf {
        self.cache.join("downloads")
    }

    /// Per-device log directory.
    pub fn device_logs(&self, device: &str) -> PathBuf {
        self.logs.join("devices").join(device)
    }

    /// True if `path` is inside one of Jidr's own directories.
    pub fn owns(&self, path: &Path) -> bool {
        [&self.data, &self.cache, &self.logs]
            .iter()
            .any(|root| path.starts_with(root))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn under_root_layout() {
        let p = JidrPaths::under("/tmp/j");
        assert_eq!(p.sdk(), PathBuf::from("/tmp/j/data/sdk"));
        assert_eq!(p.avd_home(), PathBuf::from("/tmp/j/data/avd"));
        assert_eq!(p.socket(), PathBuf::from("/tmp/j/data/daemon.sock"));
        assert!(p.owns(Path::new("/tmp/j/cache/downloads/x")));
        assert!(!p.owns(Path::new("/Users/me/Library/Android/sdk")));
    }

    #[test]
    fn portable_root_requires_matching_marker_and_data() {
        let root =
            std::env::temp_dir().join(format!("jidr-location-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let location = PortableLocation {
            root: root.clone(),
            marker: uuid::Uuid::new_v4(),
        };
        assert!(location.resolve().is_err());
        location.write_marker().unwrap();
        assert!(location.write_marker().is_err());
        assert!(location.resolve().is_err());
        std::fs::create_dir(root.join("data")).unwrap();
        assert_eq!(location.resolve().unwrap().data, root.join("data"));
        let wrong = PortableLocation {
            root: root.clone(),
            marker: uuid::Uuid::new_v4(),
        };
        assert!(wrong.resolve().is_err());
        std::fs::remove_dir_all(&root).unwrap();
        assert!(location.resolve().is_err());
    }

    #[test]
    fn location_pointer_fails_closed_if_volume_disappears() {
        let root = std::env::temp_dir().join(format!("jidr-pointer-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let volume = root.join("volume");
        std::fs::create_dir_all(volume.join("data")).unwrap();
        let location = PortableLocation {
            root: volume.clone(),
            marker: uuid::Uuid::new_v4(),
        };
        location.write_marker().unwrap();
        let pointer = root.join("location.json");
        assert_eq!(read_location_file(&pointer).unwrap(), None);
        write_location_file(&pointer, &location).unwrap();
        assert_eq!(read_location_file(&pointer).unwrap(), Some(location));
        std::fs::rename(&volume, root.join("disconnected")).unwrap();
        assert!(read_location_file(&pointer).is_err());
        std::fs::write(&pointer, b"corrupt").unwrap();
        assert!(read_location_file(&pointer).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }
}
