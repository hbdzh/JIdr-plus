//! Android SDK locations. Jidr installs into its own writable root — the
//! private SDK by default or a user-configured custom install root; Android
//! Studio's SDK (and any explicitly configured external SDK) is only ever read
//! (D3).

use std::path::{Path, PathBuf};

use jidr_core::{ImageRef, JidrError, JidrPaths, JidrResult};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum SdkKind {
    /// A Jidr-owned writable SDK: `~/Library/Application Support/Jidr/sdk`
    /// (private) or a custom install root.
    Private,
    /// Android Studio's SDK: read-only.
    StudioReadOnly,
    /// An explicitly selected external SDK; never modified by Jidr.
    ConfiguredReadOnly,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
pub struct Sdk {
    pub root: PathBuf,
    pub kind: SdkKind,
}

impl Sdk {
    pub fn private(paths: &JidrPaths) -> Self {
        Self {
            root: paths.sdk(),
            kind: SdkKind::Private,
        }
    }

    /// A Jidr-owned writable SDK outside the private default, configured in
    /// `tool-paths.json` as `jidr_sdk`. It reuses [`SdkKind::Private`], so
    /// [`Sdk::ensure_writable`] allows installations into it.
    pub fn custom_writable(root: impl Into<PathBuf>) -> Self {
        Self {
            root: root.into(),
            kind: SdkKind::Private,
        }
    }

    /// Android Studio's SDK, if present: `ANDROID_HOME`, `ANDROID_SDK_ROOT`,
    /// then the platform default.
    pub fn studio() -> Option<Self> {
        let candidates = ["ANDROID_HOME", "ANDROID_SDK_ROOT"]
            .iter()
            .filter_map(std::env::var_os)
            .map(PathBuf::from)
            .chain(dirs::home_dir().map(|h| {
                if cfg!(target_os = "macos") {
                    h.join("Library/Android/sdk")
                } else {
                    h.join("Android/Sdk")
                }
            }));
        candidates
            .into_iter()
            .find(|p| p.is_dir())
            .map(Self::read_only)
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

    /// Refuses writes to an SDK Jidr doesn't own.
    pub fn ensure_writable(&self) -> JidrResult<()> {
        match self.kind {
            SdkKind::Private => Ok(()),
            SdkKind::StudioReadOnly | SdkKind::ConfiguredReadOnly => Err(JidrError::sdk(format!(
                "{} is an external SDK; Jidr never writes to it",
                self.root.display()
            ))),
        }
    }
}

/// The SDKs Jidr can use: its own writable root (the private SDK or a custom
/// install root), plus Studio's or an explicitly configured read-only SDK.
#[derive(Debug, Clone)]
pub struct SdkSet {
    /// Jidr's private SDK (`<data>/sdk`); the default install root.
    pub private: Sdk,
    /// An optional Jidr-owned writable install root (`ToolPaths.jidr_sdk`).
    pub custom: Option<Sdk>,
    /// Android Studio's SDK or an explicitly configured external SDK; read-only.
    pub studio: Option<Sdk>,
}

impl SdkSet {
    /// Discovers the SDK set from `tool-paths.json` and the host defaults.
    pub fn discover(paths: &JidrPaths) -> Self {
        Self::discover_with(paths, None)
    }

    /// Like [`discover`](Self::discover), but keeps a caller-supplied Studio
    /// SDK (used by the daemon's tests) when none is explicitly configured.
    pub fn discover_with(paths: &JidrPaths, studio: Option<Sdk>) -> Self {
        match jidr_core::tool_paths::ToolPaths::load(paths) {
            Ok(config) => Self {
                private: Sdk::private(paths),
                custom: config.jidr_sdk.map(Sdk::custom_writable),
                studio: config
                    .android_sdk
                    .map(Sdk::configured)
                    .or(studio)
                    .or_else(Sdk::studio),
            },
            // Preserve a fail-closed selection if the configuration is unreadable.
            Err(_) => Self {
                private: Sdk::private(paths),
                custom: None,
                studio: Some(Sdk::configured(PathBuf::new())),
            },
        }
    }

    pub fn configured_or_studio(paths: &JidrPaths) -> Option<Sdk> {
        Self::configured_or(paths, None)
    }

    pub fn configured_or(paths: &JidrPaths, fallback: Option<Sdk>) -> Option<Sdk> {
        match jidr_core::tool_paths::ToolPaths::load(paths) {
            Ok(config) => config
                .android_sdk
                .map(Sdk::configured)
                .or(fallback)
                .or_else(Sdk::studio),
            // Preserve a fail-closed selection if the configuration is unreadable.
            Err(_) => Some(Sdk::configured(PathBuf::new())),
        }
    }

    /// The writable SDK root Jidr installs packages and images into: the custom
    /// root when configured, else the private SDK. Read-only SDKs are never
    /// install targets.
    pub fn install_root(&self) -> &Sdk {
        self.custom.as_ref().unwrap_or(&self.private)
    }

    /// The SDK that provides `emulator` and `adb`. An explicitly configured
    /// read-only SDK fails closed when incomplete; otherwise the first complete
    /// SDK wins: custom → private → Studio.
    pub fn tools(&self) -> JidrResult<&Sdk> {
        if let Some(selected) = self
            .studio
            .as_ref()
            .filter(|sdk| sdk.kind == SdkKind::ConfiguredReadOnly)
        {
            return if selected.root.is_absolute() && selected.has_emulator() && selected.has_adb() {
                Ok(selected)
            } else {
                Err(JidrError::sdk(format!(
                    "configured Android SDK is unavailable or incomplete: {}",
                    selected.root.display()
                )))
            };
        }
        self.custom
            .as_ref()
            .into_iter()
            .chain(std::iter::once(&self.private))
            .chain(self.studio.as_ref())
            .find(|s| s.has_emulator() && s.has_adb())
            .ok_or_else(|| JidrError::sdk("no Android emulator installed; run `jidr sdk install`"))
    }

    /// The SDK holding `image`: custom → private → Studio.
    pub fn find_image(&self, image: &ImageRef) -> Option<&Sdk> {
        self.custom
            .as_ref()
            .into_iter()
            .chain(std::iter::once(&self.private))
            .chain(self.studio.as_ref())
            .find(|s| s.has_image(image))
    }
}

fn is_complete_image(dir: &Path) -> bool {
    ["source.properties", "system.img", "ramdisk.img"]
        .iter()
        .all(|f| dir.join(f).is_file())
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
        let paths = JidrPaths::under(dir.path());
        assert!(Sdk::private(&paths).ensure_writable().is_ok());
    }

    #[test]
    fn explicitly_selected_sdk_takes_priority_and_fails_closed() {
        let dir = tempfile::tempdir().unwrap();
        let paths = JidrPaths::under(dir.path().join("jidr"));
        let selected = dir.path().join("sdk");
        for root in [paths.sdk(), selected.clone()] {
            std::fs::create_dir_all(root.join("emulator")).unwrap();
            std::fs::create_dir_all(root.join("platform-tools")).unwrap();
            std::fs::write(root.join("emulator/emulator"), b"x").unwrap();
            std::fs::write(root.join("platform-tools/adb"), b"x").unwrap();
        }
        jidr_core::tool_paths::ToolPaths {
            android_sdk: Some(selected.clone()),
            jdk_home: None,
            jidr_sdk: None,
        }
        .save(&paths)
        .unwrap();
        let sdks = SdkSet::discover(&paths);
        assert_eq!(sdks.tools().unwrap().root, selected);
        assert!(sdks.tools().unwrap().ensure_writable().is_err());
        std::fs::remove_file(selected.join("platform-tools/adb")).unwrap();
        assert!(SdkSet::discover(&paths).tools().is_err());
    }

    #[test]
    fn find_image_prefers_private() {
        let dir = tempfile::tempdir().unwrap();
        let paths = JidrPaths::under(dir.path().join("jidr"));
        let studio = dir.path().join("studio");
        fake_image(&studio, &img(31, "google_apis"), true);
        let set = SdkSet {
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

    fn save_custom_root(paths: &JidrPaths, root: &Path) {
        std::fs::create_dir_all(&paths.data).unwrap();
        jidr_core::tool_paths::ToolPaths {
            android_sdk: None,
            jdk_home: None,
            jidr_sdk: Some(root.to_path_buf()),
        }
        .save(paths)
        .unwrap();
    }

    #[test]
    fn custom_writable_root_is_the_install_target_and_is_searched_first() {
        let dir = tempfile::tempdir().unwrap();
        let paths = JidrPaths::under(dir.path().join("jidr"));
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
        let paths = JidrPaths::under(dir.path().join("jidr"));
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
        let paths = JidrPaths::under(dir.path().join("jidr"));
        let sdks = SdkSet {
            private: Sdk::private(&paths),
            custom: None,
            studio: None,
        };
        assert_eq!(sdks.install_root().root, paths.sdk());
        assert!(sdks.install_root().ensure_writable().is_ok());
    }
}
