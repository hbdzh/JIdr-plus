//! Shared setup for emulator tests: a temp Miko home with one AVD built from
//! the `MIKO_TEST_SDK` image (read-only).
#![allow(dead_code)]

use std::path::PathBuf;

use miko_backend::LaunchSpec;
use miko_core::{ImageRef, MikoPaths};
use miko_sdk::{AvdManager, AvdSpec, Sdk, SdkSet, profiles};

pub fn test_sdk() -> PathBuf {
    std::env::var_os("MIKO_TEST_SDK")
        .map(PathBuf::from)
        .unwrap_or_else(|| dirs::home_dir().unwrap().join("Library/Android/sdk"))
}

pub fn test_image() -> ImageRef {
    let pkg = std::env::var("MIKO_TEST_IMAGE").unwrap_or_else(|_| {
        format!(
            "system-images;android-31;google_apis;{}",
            miko_sdk::host::host_abi()
        )
    });
    ImageRef::parse_package(&pkg).unwrap()
}

pub struct Fixture {
    pub tmp: tempfile::TempDir,
    pub paths: MikoPaths,
    pub avds: AvdManager,
    pub image_sdk: Sdk,
    pub spec: LaunchSpec,
    /// Kills the emulator however the test ends (drop, or the reaper if the
    /// test process is killed).
    pub _guard: miko_backend::testing::AvdGuard,
}

/// Creates AVD `<base>-<pid>` and a launch spec for it. Orphaned emulators
/// of earlier, killed runs are cleaned up first.
pub fn fixture(base: &str) -> Fixture {
    miko_backend::testing::kill_orphans(&format!("{base}-"));
    let name_owned = miko_backend::testing::unique_avd(base);
    let name = name_owned.as_str();
    let guard = miko_backend::testing::AvdGuard::new(name);
    let tmp = tempfile::tempdir().unwrap();
    let paths = MikoPaths::under(tmp.path());
    let sdks = SdkSet {
        bundled: None,
        legacy: Vec::new(),
        private: Sdk::private(&paths),
        custom: None,
        studio: Some(Sdk::read_only(test_sdk())),
    };
    let image = test_image();
    let image_sdk = sdks
        .find_image(&image)
        .expect("test image installed")
        .clone();
    let tools = sdks.tools().unwrap().clone();
    let avds = AvdManager::new(paths.avd_home());
    avds.create(&AvdSpec {
        name: name.into(),
        display_name: name.into(),
        profile: profiles::find("small-phone-5").unwrap(),
        image,
        overrides: Default::default(),
    })
    .unwrap();
    let spec = LaunchSpec {
        avd: name.into(),
        avd_home: paths.avd_home(),
        sdk_root: image_sdk.root.clone(),
        sysdir: image_sdk.image_dir(&test_image()),
        emulator: tools.emulator(),
        adb: tools.adb(),
        log_dir: paths.device_logs(name),
    };
    Fixture {
        tmp,
        paths,
        avds,
        image_sdk,
        spec,
        _guard: guard,
    }
}
