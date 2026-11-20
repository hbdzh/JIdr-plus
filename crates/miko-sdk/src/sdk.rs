//! Android SDK locations. Miko installs into its own writable root — the
//! private SDK by default or a user-configured custom install root; Android
//! Studio's SDK (and any explicitly configured external SDK) is only ever read
//! (D3).

use std::path::{Path, PathBuf};

use miko_core::{ImageRef, MikoError, MikoPaths, MikoResult};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum SdkKind {
    /// A Miko-owned writable SDK: `~/Library/Application Support/miko/sdk`
    /// (private) or a custom install root.
    Private,
    /// Android Studio's SDK: read-only.
    StudioReadOnly,
    /// A previously selected external SDK, protected from writes.
    ConfiguredReadOnly,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
pub struct Sdk {
    pub root: PathBuf,
    pub kind: SdkKind,
}

impl Sdk {
    pub fn private(paths: &MikoPaths) -> Self {
        Self {
            root: paths.sdk(),
            kind: SdkKind::Private,
        }
    }

    /// A Miko-owned writable SDK outside the private default, configured in
    /// `tool-paths.json` as `miko_sdk`. It reuses [`SdkKind::Private`], so
    /// [`Sdk::ensure_writable`] allows installations into it.
    pub fn custom_writable(root: impl Into<PathBuf>) -> Self {
        Self {
            root: root.into(),
            kind: SdkKind::Private,
        }
    }

    /// Any SDK root, read-only.
    pub fn read_only(root: impl Into<PathBuf>) -> Self {
        Self {
            root: root.into(),
            kind: SdkKind::StudioReadOnly,
        }
    }

    pub fn configured(root: impl Into<PathBuf>) -> Self {
        Self {
            root: root.into(),
            kind: SdkKind::ConfiguredReadOnly,
        }
    }

    pub fn emulator(&self) -> PathBuf {
        self.root.join("emulator/emulator")
    }

    pub fn adb(&self) -> PathBuf {
        self.root.join("platform-tools/adb")
    }

    pub fn has_emulator(&self) -> bool {
        self.emulator().is_file()
    }

    pub fn has_adb(&self) -> bool {
        self.adb().is_file()
    }

    /// Emulator version from `emulator/source.properties`.
    pub fn emulator_version(&self) -> Option<String> {
        read_properties(&self.root.join("emulator/source.properties"))
            .into_iter()
            .find(|(k, _)| k == "Pkg.Revision")
            .map(|(_, v)| v)
    }

    pub fn image_dir(&self, image: &ImageRef) -> PathBuf {
        self.root.join(image.sysdir())
    }

    /// True if the image directory is complete (not an empty or partial install).
    pub fn has_image(&self, image: &ImageRef) -> bool {
        is_complete_image(&self.image_dir(image))
    }

    /// All complete system images in this SDK.
    pub fn installed_images(&self) -> Vec<ImageRef> {
        let mut out = Vec::new();
        let Ok(apis) = std::fs::read_dir(self.root.join("system-images")) else {
            return out;
        };
        for api_dir in apis.flatten() {
            let name = api_dir.file_name().to_string_lossy().into_owned();
            let Some(api) = name.strip_prefix("android-").and_then(|a| a.parse().ok()) else {
                continue;
            };
            for tag in read_dirs(&api_dir.path()) {
                for abi in read_dirs(&tag) {
                    if !is_complete_image(&abi) {
                        continue;
                    }
                    if let (Some(t), Some(a)) = (file_name(&tag), file_name(&abi)) {
                        out.push(ImageRef {
                            api,
                            tag: t,
                            abi: a,
                        });
                    }
                }
            }
        }
        out.sort();
        out
    }

    /// Refuses writes to an SDK Miko doesn't own.
    pub fn ensure_writable(&self) -> MikoResult<()> {
        match self.kind {
            SdkKind::Private => Ok(()),
            SdkKind::StudioReadOnly | SdkKind::ConfiguredReadOnly => Err(MikoError::sdk(format!(
                "{} is an external SDK; Miko never writes to it",
                self.root.display()
            ))),
        }
    }
}

/// The SDKs Miko can use: its own writable root (the private SDK or a custom
/// install root), plus Studio's or an explicitly configured read-only SDK.
#[derive(Debug, Clone)]
pub struct SdkSet {
    /// Miko's private SDK (`<data>/sdk`); the default install root.
    pub private: Sdk,
    /// An optional Miko-owned writable install root (`ToolPaths.miko_sdk`).
    pub custom: Option<Sdk>,
    /// Android Studio's SDK or an explicitly configured external SDK; read-only.
    pub studio: Option<Sdk>,
    /// Former writable roots remain available for existing images, read-only.
    pub legacy: Vec<Sdk>,
    /// Read-only runtime shipped inside the application bundle.
    pub bundled: Option<Sdk>,
}

impl SdkSet {
    /// Locate a packaged runtime only relative to the running app helper.
    fn bundled_sdk_from_executable(executable: &Path) -> Option<Sdk> {
        let contents = executable.parent()?.parent()?;
        if contents.file_name()? != "Contents" || executable.parent()?.file_name()? != "Helpers" {
            return None;
        }
        let resources = contents.join("Resources");
        resources
            .join(".miko-runtime-required")
            .is_file()
            .then(|| Sdk::read_only(resources.join("sdk")))
    }

    fn bundled_sdk() -> Option<Sdk> {
        Self::bundled_sdk_from_executable(&std::env::current_exe().ok()?)
    }

    /// Discovers the SDK set from `tool-paths.json` and the host defaults.
    pub fn discover(paths: &MikoPaths) -> Self {
        Self::discover_with(paths, None)
    }

    /// Discovers managed SDKs with an optional read-only fixture for tests.
    pub fn discover_with(paths: &MikoPaths, studio: Option<Sdk>) -> Self {
        match miko_core::tool_paths::ToolPaths::load(paths) {
            Ok(config) => {
                let private = Sdk::private(paths);
                let custom = config.miko_sdk.map(Sdk::custom_writable);
                let studio = config.android_sdk.map(Sdk::configured).or(studio);
                let legacy = miko_core::tool_paths::ToolPaths::previous_miko_sdks(paths)
                    .unwrap_or_default()
                    .into_iter()
                    .filter(|path| {
                        path.is_absolute()
                            && *path != private.root
                            && custom.as_ref().is_none_or(|sdk| *path != sdk.root)
                            && studio.as_ref().is_none_or(|sdk| *path != sdk.root)
                    })
                    .map(Sdk::read_only)
                    .collect();
                Self {
                    private,
                    custom,
                    studio,
                    legacy,
                    bundled: Self::bundled_sdk(),
                }
            }
            // Preserve a fail-closed selection if the configuration is unreadable.
            Err(_) => Self {
                private: Sdk::private(paths),
                custom: None,
                studio: Some(Sdk::configured(PathBuf::new())),
                legacy: Vec::new(),
                bundled: Self::bundled_sdk(),
            },
        }
    }

    /// The writable SDK root Miko installs packages and images into: the custom
    /// root when configured, else the private SDK. Read-only SDKs are never
    /// install targets.
    pub fn install_root(&self) -> &Sdk {
        self.custom.as_ref().unwrap_or(&self.private)
    }

    /// A read-only fixture injected by the daemon's integration tests. A
    /// legacy external selection is retained only for ownership checks.
    pub fn fixture(&self) -> Option<&Sdk> {
        self.studio
            .as_ref()
            .filter(|sdk| sdk.kind == SdkKind::StudioReadOnly)
    }

    /// The managed SDK that provides `emulator` and `adb`.
    pub fn tools(&self) -> MikoResult<&Sdk> {
        if let Some(bundled) = &self.bundled {
            return if bundled.has_emulator()
                && bundled.has_adb()
                && crate::runtime::installed(&bundled.root.join("emulator"))
            {
                Ok(bundled)
            } else {
                Err(MikoError::sdk(
                    "the bundled emulator runtime is missing or incomplete; reinstall miko",
                ))
            };
        }
        self.custom
            .as_ref()
            .into_iter()
            .chain(std::iter::once(&self.private))
            .chain(self.fixture())
            .find(|s| s.has_emulator() && s.has_adb())
            .ok_or_else(|| MikoError::sdk("no Android emulator installed; run `miko sdk install`"))
    }

    /// Finds an image in a current or former managed SDK.
    pub fn find_image(&self, image: &ImageRef) -> Option<&Sdk> {
        self.custom
            .as_ref()
            .into_iter()
            .chain(std::iter::once(&self.private))
            .chain(self.fixture())
            .chain(self.legacy.iter())
            .find(|s| s.has_image(image))
    }
}

fn is_complete_image(dir: &Path) -> bool {
    ["source.properties", "system.img", "ramdisk.img"]
        .iter()
        .all(|f| std::fs::metadata(dir.join(f)).is_ok_and(|m| m.is_file() && m.len() > 0))
}

fn read_dirs(dir: &Path) -> Vec<PathBuf> {
    std::fs::read_dir(dir)
        .map(|rd| {
            rd.flatten()
                .map(|e| e.path())
                .filter(|p| p.is_dir())
                .collect()
        })
        .unwrap_or_default()
}

fn file_name(p: &Path) -> Option<String> {
    p.file_name().map(|n| n.to_string_lossy().into_owned())
}

/// Reads a Java-style `key=value` properties file; missing file → empty.
pub fn read_properties(path: &Path) -> Vec<(String, String)> {
    std::fs::read_to_string(path)
        .map(|t| {
            t.lines()
                .filter(|l| !l.trim_start().starts_with('#'))
                .filter_map(|l| l.split_once('='))
                .map(|(k, v)| (k.trim().to_string(), v.trim().to_string()))
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_runtime_requires_complete_app_relative_sdk_and_takes_priority() {
        let temp = tempfile::tempdir().unwrap();
        let contents = temp.path().join("Example.app/Contents");
        let executable = contents.join("Helpers/miko");
        let sdk = contents.join("Resources/sdk");
        std::fs::create_dir_all(sdk.join("emulator/qemu/darwin-aarch64")).unwrap();
        std::fs::create_dir_all(sdk.join("platform-tools")).unwrap();
        for name in [
            "emulator/emulator",
            "emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless",
            "emulator/.miko-runtime-37.3.10",
        ] {
            std::fs::write(sdk.join(name), b"x").unwrap();
        }
        assert!(SdkSet::bundled_sdk_from_executable(&executable).is_none());
        std::fs::write(contents.join("Resources/.miko-runtime-required"), b"1").unwrap();
        let bundled = SdkSet::bundled_sdk_from_executable(&executable).unwrap();
        let private = Sdk::private(&MikoPaths::under(temp.path().join("home")));
        let broken = SdkSet {
            bundled: Some(bundled),
            private,
            custom: None,
            studio: None,
            legacy: vec![],
        };
        assert!(broken.tools().is_err());
        std::fs::write(sdk.join("platform-tools/adb"), b"x").unwrap();
        let bundled = SdkSet::bundled_sdk_from_executable(&executable).unwrap();
        let private = Sdk::private(&MikoPaths::under(temp.path().join("home")));
        let set = SdkSet {
            bundled: Some(bundled),
            private,
            custom: None,
            studio: None,
            legacy: vec![],
        };
        assert_eq!(set.tools().unwrap().root, sdk);
        assert!(set.tools().unwrap().ensure_writable().is_err());
        assert!(SdkSet::bundled_sdk_from_executable(&temp.path().join("miko")).is_none());
    }

    fn fake_image(root: &Path, image: &ImageRef, complete: bool) {
        let dir = root.join(image.sysdir());
        std::fs::create_dir_all(&dir).unwrap();
        if complete {
            for f in ["source.properties", "system.img", "ramdisk.img"] {
                std::fs::write(dir.join(f), b"x").unwrap();
            }
        }
    }

    fn img(api: u32, tag: &str) -> ImageRef {
        ImageRef {
            api,
            tag: tag.into(),
            abi: "arm64-v8a".into(),
        }
    }

    #[test]
    fn empty_image_files_are_not_installed() {
        let dir = tempfile::tempdir().unwrap();
        let image = img(36, "google_apis");
        fake_image(dir.path(), &image, true);
        std::fs::write(dir.path().join(image.sysdir()).join("system.img"), b"").unwrap();
        let sdk = Sdk::read_only(dir.path());
        assert!(!sdk.has_image(&image));
        assert!(sdk.installed_images().is_empty());
    }

    #[test]
    fn lists_only_complete_images() {
        let dir = tempfile::tempdir().unwrap();
        fake_image(dir.path(), &img(31, "google_apis"), true);
        fake_image(dir.path(), &img(36, "google_apis"), false);
        let sdk = Sdk::read_only(dir.path());
        assert_eq!(sdk.installed_images(), vec![img(31, "google_apis")]);
        assert!(sdk.has_image(&img(31, "google_apis")));
        assert!(!sdk.has_image(&img(36, "google_apis")));
    }

    #[test]
    fn studio_sdk_is_never_writable() {
        let dir = tempfile::tempdir().unwrap();
        assert!(Sdk::read_only(dir.path()).ensure_writable().is_err());
        let paths = MikoPaths::under(dir.path());
        assert!(Sdk::private(&paths).ensure_writable().is_ok());
    }

    #[test]
    fn saved_external_sdk_is_not_used_for_tools_or_images() {
        let dir = tempfile::tempdir().unwrap();
        let paths = MikoPaths::under(dir.path().join("miko"));
        let selected = dir.path().join("sdk");
        let image = img(31, "google_apis");
        write_tools(&selected);
        fake_image(&selected, &image, true);
        std::fs::create_dir_all(&paths.data).unwrap();
        miko_core::tool_paths::ToolPaths {
            android_sdk: Some(selected),
            miko_sdk: None,
        }
        .save(&paths)
        .unwrap();
        let sdks = SdkSet::discover(&paths);
        assert!(sdks.tools().is_err());
        assert!(sdks.find_image(&image).is_none());

        write_tools(&paths.sdk());
        fake_image(&paths.sdk(), &image, true);
        let sdks = SdkSet::discover(&paths);
        assert_eq!(sdks.tools().unwrap().root, paths.sdk());
        assert_eq!(sdks.find_image(&image).unwrap().root, paths.sdk());
    }

    #[test]
    fn find_image_prefers_private() {
        let dir = tempfile::tempdir().unwrap();
        let paths = MikoPaths::under(dir.path().join("miko"));
        let studio = dir.path().join("studio");
        fake_image(&studio, &img(31, "google_apis"), true);
        let set = SdkSet {
            bundled: None,
            legacy: Vec::new(),
            private: Sdk::private(&paths),
            custom: None,
            studio: Some(Sdk::read_only(&studio)),
        };
        assert_eq!(
            set.find_image(&img(31, "google_apis")).map(|s| s.kind),
            Some(SdkKind::StudioReadOnly)
        );
        fake_image(&paths.sdk(), &img(31, "google_apis"), true);
        assert_eq!(
            set.find_image(&img(31, "google_apis")).map(|s| s.kind),
            Some(SdkKind::Private)
        );
        assert!(set.tools().is_err());
    }

    fn write_tools(root: &Path) {
        std::fs::create_dir_all(root.join("emulator")).unwrap();
        std::fs::create_dir_all(root.join("platform-tools")).unwrap();
        std::fs::write(root.join("emulator/emulator"), b"x").unwrap();
        std::fs::write(root.join("platform-tools/adb"), b"x").unwrap();
    }

    fn save_custom_root(paths: &MikoPaths, root: &Path) {
        std::fs::create_dir_all(&paths.data).unwrap();
        miko_core::tool_paths::ToolPaths {
            android_sdk: None,
            miko_sdk: Some(root.to_path_buf()),
        }
        .save(paths)
        .unwrap();
    }

    #[test]
    fn custom_writable_root_is_the_install_target_and_is_searched_first() {
        let dir = tempfile::tempdir().unwrap();
        let paths = MikoPaths::under(dir.path().join("miko"));
        let custom = dir.path().join("custom-sdk");
        std::fs::create_dir_all(&custom).unwrap();
        save_custom_root(&paths, &custom);
        // Both roots are complete, with the same image; the custom one wins.
        for root in [&custom, &paths.sdk()] {
            write_tools(root);
            fake_image(root, &img(31, "google_apis"), true);
        }

        let sdks = SdkSet::discover(&paths);
        let custom_sdk = sdks.custom.as_ref().expect("custom SDK discovered");
        assert_eq!(custom_sdk.root, custom);
        assert_eq!(custom_sdk.kind, SdkKind::Private);
        assert!(
            custom_sdk.ensure_writable().is_ok(),
            "the custom root is writable"
        );
        assert_eq!(sdks.install_root().root, custom);
        assert_eq!(sdks.tools().unwrap().root, custom);
        assert_eq!(
            sdks.find_image(&img(31, "google_apis")).map(|s| &s.root),
            Some(&custom)
        );
    }

    #[test]
    fn an_empty_custom_root_is_still_the_install_target() {
        let dir = tempfile::tempdir().unwrap();
        let paths = MikoPaths::under(dir.path().join("miko"));
        let custom = dir.path().join("custom-sdk");
        std::fs::create_dir_all(&custom).unwrap();
        save_custom_root(&paths, &custom);
        // The private SDK is complete; the custom root is empty and is where
        // new packages and images must be installed.
        write_tools(&paths.sdk());
        fake_image(&paths.sdk(), &img(31, "google_apis"), true);

        let mut sdks = SdkSet::discover(&paths);
        // The host's Studio SDK (if any) must not make this test environment-dependent.
        sdks.studio = None;
        assert_eq!(sdks.install_root().root, custom);
        assert!(!sdks.install_root().has_emulator());
        // Runtime keeps working from the private SDK until the custom root is complete.
        assert_eq!(sdks.tools().unwrap().root, paths.sdk());
        assert_eq!(
            sdks.find_image(&img(31, "google_apis")).map(|s| &s.root),
            Some(&paths.sdk())
        );
        assert!(sdks.find_image(&img(36, "google_apis")).is_none());
    }

    #[test]
    fn the_install_root_defaults_to_the_private_sdk() {
        let dir = tempfile::tempdir().unwrap();
        let paths = MikoPaths::under(dir.path().join("miko"));
        let sdks = SdkSet {
            bundled: None,
            legacy: Vec::new(),
            private: Sdk::private(&paths),
            custom: None,
            studio: None,
        };
        assert_eq!(sdks.install_root().root, paths.sdk());
        assert!(sdks.install_root().ensure_writable().is_ok());
    }
}
