//! The optional, locally built Apple Silicon runtime. Google SDK files are
//! downloaded by the package installer after licence consent.

use std::path::{Path, PathBuf};

use miko_core::{ErrorCode, MikoError, MikoResult, ResultExt};

use crate::repo::{Archive, RemotePackage, Repository, Revision};

const ARCHIVE_SHA1: &str = "3ec739595d44092e835f006d806dd380bc8d6dd7";
const HEADLESS: &str = "qemu/darwin-aarch64/qemu-system-aarch64-headless";
const MARKER: &str = ".miko-runtime-37.3.10";

fn local_engine() -> Option<PathBuf> {
    if !cfg!(all(target_os = "macos", target_arch = "aarch64")) {
        return None;
    }
    let exe = std::env::current_exe().ok()?;
    let contents = exe.parent()?.parent()?;
    let engine = contents.join("Resources/runtime/qemu-system-aarch64-headless");
    (contents.file_name()? == "Contents" && engine.is_file()).then_some(engine)
}

pub fn available() -> bool {
    local_engine().is_some()
}

/// Match the Google libraries used to validate the locally built executable.
pub fn package(repo: &Repository, name: &str) -> Option<RemotePackage> {
    if name == "emulator" && available() {
        return Some(RemotePackage {
            path: name.into(),
            display: "Android Emulator".into(),
            revision: Revision { major: 37, minor: 3, micro: 10, preview: None },
            license: Some("android-sdk-license".into()),
            channel: 0,
            archives: vec![Archive {
                url: "https://redirector.gvt1.com/edgedl/android/repository/emulator-darwin_aarch64-16970787.zip".into(),
                sha1: ARCHIVE_SHA1.into(),
                size: 420_629_851,
                host_os: Some("macosx".into()),
                host_arch: Some("aarch64".into()),
            }],
            image: None,
        });
    }
    repo.latest(name, 0).cloned()
}

pub fn installed(emulator_dir: &Path) -> bool {
    emulator_dir.join(MARKER).is_file() && emulator_dir.join(HEADLESS).is_file()
}

pub(crate) fn prepare(emulator_dir: &Path, package: &str, sha1: &str) -> MikoResult<()> {
    if package == "emulator"
        && let Some(engine) = local_engine()
    {
        if sha1 != ARCHIVE_SHA1 {
            return Err(MikoError::sdk(
                "the local emulator requires Android Emulator 37.3.10",
            ));
        }
        stage(emulator_dir, &engine)?;
    }
    Ok(())
}

fn stage(emulator_dir: &Path, engine: &Path) -> MikoResult<()> {
    let target = emulator_dir.join(HEADLESS);
    if !target.is_file() || target.is_symlink() {
        return Err(MikoError::sdk(
            "the emulator archive is missing the Apple Silicon headless runtime",
        ));
    }
    std::fs::copy(engine, target).ctx(ErrorCode::Sdk, "installing the miko emulator executable")?;
    for path in [
        "lib64/qt",
        "qemu/darwin-aarch64/qemu-system-aarch64",
        "qemu/darwin-aarch64/qemu-system-armel",
        "qemu/darwin-aarch64/qemu-system-armel-headless",
    ] {
        let path = emulator_dir.join(path);
        let result = if path.is_dir() {
            std::fs::remove_dir_all(&path)
        } else {
            std::fs::remove_file(&path)
        };
        match result {
            Err(err) if err.kind() != std::io::ErrorKind::NotFound => {
                return Err(MikoError::sdk(format!(
                    "removing {}: {err}",
                    path.display()
                )));
            }
            _ => {}
        }
    }
    std::fs::write(emulator_dir.join(MARKER), b"37.3.10\n")
        .ctx(ErrorCode::Sdk, "marking the miko runtime")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stage_replaces_only_the_engine_and_prunes_unused_components() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("emulator");
        let engine = temp.path().join("custom");
        std::fs::write(&engine, b"custom engine").unwrap();
        std::fs::create_dir_all(root.join("qemu/darwin-aarch64")).unwrap();
        std::fs::create_dir_all(root.join("lib64/qt")).unwrap();
        std::fs::write(root.join(HEADLESS), b"stock").unwrap();
        std::fs::write(root.join("lib64/dependency"), b"keep").unwrap();
        std::fs::write(root.join("qemu/darwin-aarch64/qemu-system-aarch64"), b"gui").unwrap();
        stage(&root, &engine).unwrap();
        assert!(installed(&root));
        assert_eq!(
            std::fs::read(root.join(HEADLESS)).unwrap(),
            b"custom engine"
        );
        assert!(root.join("lib64/dependency").is_file());
        assert!(!root.join("lib64/qt").exists());
        assert!(
            !root
                .join("qemu/darwin-aarch64/qemu-system-aarch64")
                .exists()
        );
    }
}
