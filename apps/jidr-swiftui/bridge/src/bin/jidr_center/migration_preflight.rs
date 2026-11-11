//! Read-only destination checks. Success does not authorise moving data.
use jidr_core::JidrPaths;
use std::{
    io,
    path::{Path, PathBuf},
};

pub struct Preflight {
    pub target: PathBuf,
    pub space: jidr_sdk::migration::SpaceEstimate,
    pub incomplete_snapshots: Vec<String>,
}

pub fn check(paths: &JidrPaths, parent: &Path, sdk: &Path) -> io::Result<Preflight> {
    if !parent.is_absolute() || !sdk.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "paths must be absolute",
        ));
    }
    let parent = parent.canonicalize()?;
    if !parent.is_dir() || !sdk.join("emulator/qemu-img").is_file() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "destination or qemu-img unavailable",
        ));
    }
    let target = parent.join("Jidr");
    match std::fs::symlink_metadata(&target) {
        Ok(_) => {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "destination already exists",
            ));
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    for source in [&paths.data, &paths.cache, &paths.logs] {
        match std::fs::symlink_metadata(source) {
            Ok(_) => {
                let source = source.canonicalize()?;
                if source.starts_with(&target) || target.starts_with(&source) {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "destination overlaps source",
                    ));
                }
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Err(e) => return Err(e),
        }
    }
    let space = jidr_sdk::migration::estimate_space(paths, &parent)?;
    let incomplete_snapshots = incomplete_snapshots(&paths.avd_home())?;
    Ok(Preflight {
        target,
        space,
        incomplete_snapshots,
    })
}

fn incomplete_snapshots(home: &Path) -> io::Result<Vec<String>> {
    let entries = match std::fs::read_dir(home) {
        Ok(entries) => entries,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(e),
    };
    let mut issues = Vec::new();
    for entry in entries {
        let entry = entry?;
        let avd = entry.path();
        if avd.extension().is_none_or(|ext| ext != "avd") {
            continue;
        }
        if !entry.file_type()?.is_dir() {
            return Err(io::Error::other("invalid AVD directory"));
        }
        let snapshots = match std::fs::read_dir(avd.join("snapshots")) {
            Ok(entries) => entries,
            Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
            Err(e) => return Err(e),
        };
        for snapshot in snapshots {
            let snapshot = snapshot?;
            if !snapshot.file_type()?.is_dir() {
                return Err(io::Error::other("invalid snapshot directory"));
            }
            let name = snapshot
                .file_name()
                .into_string()
                .map_err(|_| io::Error::other("invalid snapshot name"))?;
            if jidr_sdk::avd::check_snapshot(&avd, &name).is_err() {
                issues.push(format!("{} / {name}", entry.file_name().to_string_lossy()));
            }
        }
    }
    issues.sort();
    Ok(issues)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn checks_are_read_only_and_reject_overlapping_or_existing_targets() {
        let temp = tempfile::tempdir().unwrap();
        let paths = JidrPaths::under(temp.path().join("source"));
        std::fs::create_dir_all(&paths.data).unwrap();
        std::fs::write(paths.data.join("guest"), b"do not change").unwrap();
        let sdk = temp.path().join("sdk");
        std::fs::create_dir_all(sdk.join("emulator")).unwrap();
        std::fs::write(sdk.join("emulator/qemu-img"), b"test").unwrap();
        let parent = temp.path().join("destination");
        std::fs::create_dir(&parent).unwrap();
        let result = check(&paths, &parent, &sdk).unwrap();
        assert_eq!(result.target, parent.canonicalize().unwrap().join("Jidr"));
        assert!(!result.target.exists());
        assert!(result.incomplete_snapshots.is_empty());
        let snap = paths.avd_home().join("test.avd/snapshots/default_boot");
        std::fs::create_dir_all(&snap).unwrap();
        std::fs::write(snap.join("snapshot.pb"), b"metadata").unwrap();
        let result = check(&paths, &parent, &sdk).unwrap();
        assert_eq!(result.incomplete_snapshots, ["test.avd / default_boot"]);
        assert!(!snap.join("ram.bin").exists());
        assert_eq!(
            std::fs::read(paths.data.join("guest")).unwrap(),
            b"do not change"
        );
        assert!(check(&paths, &paths.data, &sdk).is_err());
        std::fs::create_dir(parent.join("Jidr")).unwrap();
        assert!(check(&paths, &parent, &sdk).is_err());
    }
}
