//! Per-library paths to independently installed developer tools.
//! Existing (external) Android SDKs are always treated as read-only; the
//! optional `jidr_sdk` is a Jidr-owned writable root Jidr may install into.
//!
//! Jidr used to persist a `jdk_home` selection. It has no JDK setting any more,
//! so [`ToolPaths::load`] drops that legacy key from older `tool-paths.json`
//! files instead of failing on it; saves never write it again.
use serde::{Deserialize, Serialize};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ToolPaths {
    pub android_sdk: Option<PathBuf>,
    /// A Jidr-owned, writable SDK root used as the install target for tools
    /// and system images instead of the private SDK. Unlike `android_sdk` it
    /// need not be a complete SDK: it is where Jidr puts what it installs.
    pub jidr_sdk: Option<PathBuf>,
}

impl ToolPaths {
    pub fn path(paths: &crate::JidrPaths) -> PathBuf {
        paths.data.join("tool-paths.json")
    }
    pub fn load(paths: &crate::JidrPaths) -> io::Result<Self> {
        match std::fs::read(Self::path(paths)) {
            Ok(data) => {
                // Older Jidr versions stored a `jdk_home` selection. The field
                // is gone, and the struct denies unknown fields: drop the
                // legacy key here so existing homes keep loading, then resolve
                // the current shape strictly.
                let mut value: serde_json::Value = serde_json::from_slice(&data)?;
                if let Some(object) = value.as_object_mut() {
                    object.remove("jdk_home");
                }
                Ok(serde_json::from_value(value)?)
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(Self::default()),
            Err(e) => Err(e),
        }
    }
    pub fn validate_sdk(path: &Path) -> io::Result<()> {
        if !path.is_absolute()
            || !path.join("emulator/emulator").is_file()
            || !path.join("platform-tools/adb").is_file()
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Android SDK must contain emulator/emulator and platform-tools/adb",
            ));
        }
        Ok(())
    }
    /// Validates a user-selected Jidr install root: an absolute, existing
    /// directory. It does not need to contain emulator/platform-tools yet —
    /// it is often an empty directory chosen as a future install target.
    pub fn validate_jidr_sdk(path: &Path) -> io::Result<()> {
        if !path.is_absolute() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "the Jidr SDK install root must be an absolute path",
            ));
        }
        if !path.is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "the Jidr SDK install root must be an existing directory",
            ));
        }
        Ok(())
    }
    pub fn save(&self, paths: &crate::JidrPaths) -> io::Result<()> {
        let previous = Self::load(paths)?;
        if self.android_sdk != previous.android_sdk
            && let Some(sdk) = &self.android_sdk
        {
            Self::validate_sdk(sdk)?;
        }
        if self.jidr_sdk != previous.jidr_sdk
            && let Some(root) = &self.jidr_sdk
        {
            Self::validate_jidr_sdk(root)?;
        }
        // Never recreate a missing selected volume under an empty mountpoint.
        if !paths.data.is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "Jidr data directory is unavailable",
            ));
        }
        let tmp = paths
            .data
            .join(format!(".tool-paths-{}.tmp", uuid::Uuid::new_v4()));
        let result = (|| {
            let mut file = std::fs::OpenOptions::new()
                .create_new(true)
                .write(true)
                .open(&tmp)?;
            serde_json::to_writer_pretty(&mut file, self)?;
            file.write_all(b"\n")?;
            file.sync_all()?;
            std::fs::rename(&tmp, Self::path(paths))?;
            std::fs::File::open(&paths.data)?.sync_all()
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(tmp);
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn selected_tools_are_validated_and_persisted() {
        let root = std::env::temp_dir().join(format!("jidr-tools-{}", uuid::Uuid::new_v4()));
        let paths = crate::JidrPaths::under(&root);
        std::fs::create_dir_all(&paths.data).unwrap();
        let sdk = root.join("sdk");
        std::fs::create_dir_all(sdk.join("emulator")).unwrap();
        std::fs::create_dir_all(sdk.join("platform-tools")).unwrap();
        for file in [
            sdk.join("emulator/emulator"),
            sdk.join("platform-tools/adb"),
        ] {
            std::fs::write(file, b"x").unwrap();
        }
        let selected = ToolPaths {
            android_sdk: Some(sdk.clone()),
            jidr_sdk: None,
        };
        selected.save(&paths).unwrap();
        assert_eq!(ToolPaths::load(&paths).unwrap(), selected);
        std::fs::remove_file(sdk.join("platform-tools/adb")).unwrap();
        assert!(ToolPaths::validate_sdk(&sdk).is_err());
        let mut invalid = selected.clone();
        invalid.android_sdk = Some(root.join("missing"));
        assert!(invalid.save(&paths).is_err());
        assert_eq!(ToolPaths::load(&paths).unwrap(), selected);
        ToolPaths::default().save(&paths).unwrap();
        assert_eq!(ToolPaths::load(&paths).unwrap(), ToolPaths::default());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn jidr_install_root_roundtrips_and_is_validated() {
        let root = std::env::temp_dir().join(format!("jidr-jidr-sdk-{}", uuid::Uuid::new_v4()));
        let paths = crate::JidrPaths::under(&root);
        std::fs::create_dir_all(&paths.data).unwrap();
        // An empty existing directory is a valid future install target.
        let install_root = root.join("custom");
        std::fs::create_dir_all(&install_root).unwrap();

        let selected = ToolPaths {
            android_sdk: None,
            jidr_sdk: Some(install_root.clone()),
        };
        selected.save(&paths).unwrap();
        assert_eq!(ToolPaths::load(&paths).unwrap(), selected);
        assert_eq!(
            ToolPaths::load(&paths).unwrap().jidr_sdk,
            Some(install_root.clone())
        );

        // Relative and missing directories are refused.
        let relative = ToolPaths {
            jidr_sdk: Some(PathBuf::from("relative/sdk")),
            ..ToolPaths::default()
        };
        assert!(relative.save(&paths).is_err());
        let missing = ToolPaths {
            jidr_sdk: Some(root.join("missing")),
            ..ToolPaths::default()
        };
        assert!(missing.save(&paths).is_err());
        // The refused saves did not overwrite the persisted selection.
        assert_eq!(
            ToolPaths::load(&paths).unwrap().jidr_sdk,
            Some(install_root.clone())
        );

        // Resetting to the default private SDK is allowed.
        ToolPaths::default().save(&paths).unwrap();
        assert_eq!(ToolPaths::load(&paths).unwrap(), ToolPaths::default());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn legacy_jdk_home_key_is_ignored_and_dropped() {
        let root = std::env::temp_dir().join(format!("jidr-legacy-{}", uuid::Uuid::new_v4()));
        let paths = crate::JidrPaths::under(&root);
        std::fs::create_dir_all(&paths.data).unwrap();
        let sdk = root.join("sdk");
        std::fs::create_dir_all(sdk.join("emulator")).unwrap();
        std::fs::create_dir_all(sdk.join("platform-tools")).unwrap();
        for file in [
            sdk.join("emulator/emulator"),
            sdk.join("platform-tools/adb"),
        ] {
            std::fs::write(file, b"x").unwrap();
        }

        // A tool-paths.json written before the JDK setting was removed.
        let legacy = serde_json::json!({
            "android_sdk": sdk,
            "jdk_home": "/Library/Java/JavaVirtualMachines/temurin-21.jdk/Contents/Home"
        });
        std::fs::write(
            ToolPaths::path(&paths),
            serde_json::to_vec(&legacy).unwrap(),
        )
        .unwrap();
        let loaded = ToolPaths::load(&paths).unwrap();
        assert_eq!(loaded.android_sdk, Some(sdk.clone()));
        assert_eq!(
            loaded,
            ToolPaths {
                android_sdk: Some(sdk),
                jidr_sdk: None
            }
        );

        // Saving rewrites the configuration without the removed key.
        loaded.save(&paths).unwrap();
        let saved = std::fs::read_to_string(ToolPaths::path(&paths)).unwrap();
        assert!(
            !saved.contains("jdk_home"),
            "legacy key must not be re-written: {saved}"
        );
        assert!(saved.contains("android_sdk"));

        // A legacy-only file is simply the default configuration.
        std::fs::write(ToolPaths::path(&paths), br#"{"jdk_home":"/other/jdk"}"#).unwrap();
        assert_eq!(ToolPaths::load(&paths).unwrap(), ToolPaths::default());

        // Compatibility is scoped to the removed key: other unknown keys still fail.
        std::fs::write(ToolPaths::path(&paths), br#"{"bogus":true}"#).unwrap();
        assert!(ToolPaths::load(&paths).is_err());

        std::fs::remove_dir_all(root).unwrap();
    }
}
