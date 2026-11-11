//! Per-library paths to independently installed developer tools.
//! Existing (external) Android SDKs are always treated as read-only; the
//! optional `jidr_sdk` is a Jidr-owned writable root Jidr may install into.
use serde::{Deserialize, Serialize};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct ToolPaths {
    pub android_sdk: Option<PathBuf>,
    pub jdk_home: Option<PathBuf>,
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
            Ok(data) => Ok(serde_json::from_slice(&data)?),
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
    pub fn validate_jdk(path: &Path) -> io::Result<()> {
        if !path.is_absolute()
            || !path.join("bin/java").is_file()
            || !path.join("bin/javac").is_file()
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "JDK must contain bin/java and bin/javac",
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
        if self.jdk_home != previous.jdk_home
            && let Some(jdk) = &self.jdk_home
        {
            Self::validate_jdk(jdk)?;
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
        let jdk = root.join("jdk");
        std::fs::create_dir_all(sdk.join("emulator")).unwrap();
        std::fs::create_dir_all(sdk.join("platform-tools")).unwrap();
        std::fs::create_dir_all(jdk.join("bin")).unwrap();
        for file in [
            sdk.join("emulator/emulator"),
            sdk.join("platform-tools/adb"),
            jdk.join("bin/java"),
            jdk.join("bin/javac"),
        ] {
            std::fs::write(file, b"x").unwrap();
        }
        let selected = ToolPaths {
            android_sdk: Some(sdk.clone()),
            jdk_home: Some(jdk),
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
        let mut reset = selected.clone();
        reset.jdk_home = None;
        reset.save(&paths).unwrap();
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
            jdk_home: None,
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
}
