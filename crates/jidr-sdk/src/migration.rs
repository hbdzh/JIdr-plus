//! Building blocks for an offline storage migration.
//!
//! A staged copy is deliberately not activated here: callers must first stop
//! all emulators and the daemon, verify references and only then switch the
//! durable location. No function in this module removes or edits the source.
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

#[derive(Debug, Default, PartialEq, Eq)]
pub struct CopyReport {
    pub files: u64,
    pub bytes: u64,
    pub skipped_sockets: u64,
}

/// Conservative space estimate: the copy routine writes logical file sizes,
/// including holes in sparse images. A reserve allows for metadata and other
/// activity on the destination volume.
#[derive(Debug, PartialEq, Eq)]
pub struct SpaceEstimate {
    pub source_bytes: u64,
    pub required_bytes: u64,
    pub available_bytes: u64,
}

fn tree_bytes(dir: &Path) -> io::Result<u64> {
    let mut total = 0u64;
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let metadata = fs::symlink_metadata(entry.path())?;
        let kind = metadata.file_type();
        let bytes = if kind.is_dir() {
            tree_bytes(&entry.path())?
        } else if kind.is_file() {
            metadata.len()
        } else {
            #[cfg(unix)]
            {
                use std::os::unix::fs::FileTypeExt;
                if kind.is_socket() {
                    continue;
                }
            }
            return Err(invalid(
                "source contains a symbolic link or unsupported special file",
            ));
        };
        total = total
            .checked_add(bytes)
            .ok_or_else(|| invalid("source size overflow"))?;
    }
    Ok(total)
}

fn estimate_with_available(
    source: &jidr_core::JidrPaths,
    available: u64,
) -> io::Result<SpaceEstimate> {
    if !fs::symlink_metadata(&source.data)?.file_type().is_dir() {
        return Err(invalid("source data directory is missing"));
    }
    let mut bytes = tree_bytes(&source.data)?;
    for dir in [&source.cache, &source.logs] {
        match fs::symlink_metadata(dir) {
            Ok(metadata) if metadata.file_type().is_dir() => {
                bytes = bytes
                    .checked_add(tree_bytes(dir)?)
                    .ok_or_else(|| invalid("source size overflow"))?;
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {}
            Ok(_) => return Err(invalid("source cache or log directory is not a directory")),
            Err(e) => return Err(e),
        }
    }
    let required = bytes
        .checked_add(bytes / 20)
        .and_then(|n| n.checked_add(256 * 1024 * 1024))
        .ok_or_else(|| invalid("required space overflow"))?;
    if available < required {
        return Err(io::Error::other(format!(
            "insufficient destination space: need {required} bytes, have {available} bytes"
        )));
    }
    Ok(SpaceEstimate {
        source_bytes: bytes,
        required_bytes: required,
        available_bytes: available,
    })
}

/// Read-only capacity and source-format preflight. The source must still be
/// quiesced before this estimate can be used for a migration.
pub fn estimate_space(
    source: &jidr_core::JidrPaths,
    destination_parent: &Path,
) -> io::Result<SpaceEstimate> {
    estimate_with_available(source, fs4::available_space(destination_parent)?)
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}

/// Check every owned AVD lock, including directories absent from the device
/// registry. This is an additional guard: missing lock files are not proof
/// that no emulator process or other writer is active.
fn ensure_avd_locks_inactive(paths: &jidr_core::JidrPaths) -> io::Result<()> {
    let home = paths.avd_home();
    let entries = match fs::read_dir(&home) {
        Ok(entries) => entries,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e),
    };
    for entry in entries {
        let entry = entry?;
        let path = entry.path();
        if path.extension().is_some_and(|ext| ext == "avd") {
            if !entry.file_type()?.is_dir() {
                return Err(invalid("invalid AVD directory"));
            }
            if crate::avd::is_locked(&path) {
                return Err(io::Error::other(format!(
                    "AVD may still be running: {}",
                    path.display()
                )));
            }
        }
    }
    Ok(())
}

/// Check saved snapshot files before copying. The emulator can leave an
/// incomplete `default_boot` directory even while it reports no snapshot.
/// File presence is only a prerequisite; loading a copied snapshot must still
/// be tested separately before activation.
fn ensure_snapshot_files_complete(paths: &jidr_core::JidrPaths) -> io::Result<()> {
    let home = paths.avd_home();
    let entries = match fs::read_dir(&home) {
        Ok(entries) => entries,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e),
    };
    for entry in entries {
        let entry = entry?;
        let avd = entry.path();
        if !avd.extension().is_some_and(|ext| ext == "avd") {
            continue;
        }
        if !entry.file_type()?.is_dir() {
            return Err(invalid("invalid AVD directory"));
        }
        let snapshots = avd.join("snapshots");
        let entries = match fs::read_dir(&snapshots) {
            Ok(entries) => entries,
            Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
            Err(e) => return Err(e),
        };
        let mut complete_count = 0usize;
        let mut incomplete_quick_boot = false;
        for snapshot in entries {
            let snapshot = snapshot?;
            if !snapshot.file_type()?.is_dir() {
                return Err(invalid("invalid snapshot directory"));
            }
            let name = snapshot
                .file_name()
                .into_string()
                .map_err(|_| invalid("invalid snapshot name"))?;
            match crate::avd::check_snapshot(&avd, &name) {
                Ok(()) => complete_count += 1,
                Err(_) if name == "default_boot" => incomplete_quick_boot = true,
                Err(error) => {
                    return Err(io::Error::other(format!(
                        "snapshot requires review: {error}"
                    )));
                }
            }
        }
        if incomplete_quick_boot && complete_count == 0 {
            return Err(io::Error::other(format!(
                "incomplete quick-boot snapshot and no complete alternative: {}",
                avd.display()
            )));
        }
    }
    Ok(())
}

/// An extra read-only check for emulator processes that still have files open
/// even if their lock file is absent or stale. A missing or failing `lsof`
/// is an error, never evidence that the device is stopped.
fn ensure_avd_files_closed(paths: &jidr_core::JidrPaths) -> io::Result<()> {
    let home = paths.avd_home();
    match fs::symlink_metadata(&home) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e),
        Ok(m) if !m.file_type().is_dir() => return Err(invalid("invalid AVD home")),
        Ok(_) => {}
    }
    let output = std::process::Command::new("lsof")
        .args(["-nP", "+D"])
        .arg(&home)
        .args(["-F", "p"])
        .output()?;
    if !output.stderr.is_empty() || !matches!(output.status.code(), Some(0 | 1)) {
        return Err(io::Error::other(
            "could not reliably inspect open AVD files",
        ));
    }
    if !output.stdout.is_empty() {
        return Err(io::Error::other("one or more AVD files are still open"));
    }
    if output.status.code() == Some(1) {
        Ok(())
    } else {
        Err(io::Error::other(
            "open-file inspection produced an ambiguous result",
        ))
    }
}

/// Conservative, read-only check for still-running owned AVDs. This does not
/// replace coordinating with the daemon and any other clients.
pub fn ensure_avds_quiescent(paths: &jidr_core::JidrPaths) -> io::Result<()> {
    ensure_avd_locks_inactive(paths)?;
    ensure_avd_files_closed(paths)
}

/// Validate the JSON produced by `qemu-img info --output=json` for an offline
/// staged image. Absolute or parent-relative backing paths require a separate
/// explicit rebasing workflow and must never be activated by a simple copy.
pub fn validate_qcow_info(info: &serde_json::Value) -> io::Result<()> {
    if info.get("format").and_then(serde_json::Value::as_str) != Some("qcow2") {
        return Err(invalid("expected a QCOW2 image"));
    }
    if info.get("dirty-flag").and_then(serde_json::Value::as_bool) != Some(false)
        || info
            .pointer("/format-specific/data/corrupt")
            .and_then(serde_json::Value::as_bool)
            != Some(false)
    {
        return Err(invalid("QCOW2 is dirty, corrupt or lacks integrity status"));
    }
    if let Some(backing) = info.get("backing-filename") {
        let name = backing
            .as_str()
            .ok_or_else(|| invalid("invalid QCOW2 backing path"))?;
        let path = Path::new(name);
        if name.is_empty()
            || path.is_absolute()
            || path
                .components()
                .any(|part| !matches!(part, std::path::Component::Normal(_)))
        {
            return Err(invalid("QCOW2 backing path must be relative and contained"));
        }
    }
    Ok(())
}

/// Checks the complete backing chain of each staged QCOW2 disk using the
/// emulator's own qemu-img. This only reads the staged copy and must run
/// after all writers have stopped.
pub fn validate_qcow_tree(staging: &Path, qemu_img: &Path) -> io::Result<usize> {
    let root = staging.canonicalize()?;
    if !qemu_img.is_file() {
        return Err(invalid("qemu-img not found"));
    }
    let mut count = 0;
    inspect_qcow_dir(&root, &root, qemu_img, &mut count)?;
    Ok(count)
}

fn inspect_qcow_dir(root: &Path, dir: &Path, tool: &Path, count: &mut usize) -> io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let ty = entry.file_type()?;
        let path = entry.path();
        if ty.is_symlink() {
            return Err(invalid("symbolic link in staged data"));
        }
        if ty.is_dir() {
            inspect_qcow_dir(root, &path, tool, count)?;
        } else if ty.is_file()
            && (path.extension().is_some_and(|ext| ext == "qcow2") || has_qcow_magic(&path)?)
        {
            let output = std::process::Command::new(tool)
                .args(["info", "--backing-chain", "--output=json"])
                .arg(&path)
                .output()?;
            if !output.status.success() {
                return Err(io::Error::other(format!(
                    "qemu-img info failed: {}",
                    path.display()
                )));
            }
            let info: serde_json::Value = serde_json::from_slice(&output.stdout)?;
            let chain = info
                .as_array()
                .filter(|a| !a.is_empty())
                .ok_or_else(|| invalid("empty QCOW2 backing chain"))?;
            for (index, image) in chain.iter().enumerate() {
                let image_path = image
                    .get("filename")
                    .and_then(serde_json::Value::as_str)
                    .ok_or_else(|| invalid("QCOW2 chain filename missing"))?;
                let image_path = Path::new(image_path).canonicalize()?;
                if !image_path.starts_with(root) || !image_path.is_file() {
                    return Err(invalid("QCOW2 backing image is outside staged data"));
                }
                let next_path = chain
                    .get(index + 1)
                    .map(|next| {
                        next.get("filename")
                            .and_then(serde_json::Value::as_str)
                            .ok_or_else(|| invalid("QCOW2 chain filename missing"))
                            .and_then(|name| Path::new(name).canonicalize())
                    })
                    .transpose()?;
                let backing = image
                    .get("backing-filename")
                    .and_then(serde_json::Value::as_str);
                match (backing, next_path) {
                    (Some(name), Some(next)) => {
                        let expected = image_path
                            .parent()
                            .ok_or_else(|| invalid("invalid image path"))?
                            .join(name)
                            .canonicalize()?;
                        if expected != next {
                            return Err(invalid("inconsistent QCOW2 backing chain"));
                        }
                    }
                    (None, None) => {}
                    _ => return Err(invalid("incomplete QCOW2 backing chain")),
                }
                match image.get("format").and_then(serde_json::Value::as_str) {
                    Some("raw") if image.get("backing-filename").is_none() => {}
                    Some("qcow2") => {
                        validate_qcow_info(image)?;
                        let check = std::process::Command::new(tool)
                            .args(["check", "-f", "qcow2", "--output=json"])
                            .arg(&image_path)
                            .output()?;
                        if !check.status.success() {
                            return Err(qcow_check_error(check.status.code(), &image_path));
                        }
                        let result: serde_json::Value = serde_json::from_slice(&check.stdout)?;
                        for key in ["check-errors", "corruptions", "leaks"] {
                            if result
                                .get(key)
                                .and_then(serde_json::Value::as_u64)
                                .unwrap_or(0)
                                != 0
                            {
                                return Err(io::Error::other(format!(
                                    "QCOW2 {key} reported: {}",
                                    image_path.display()
                                )));
                            }
                        }
                    }
                    _ => return Err(invalid("unsupported backing image format")),
                }
            }
            *count += 1;
        }
    }
    Ok(())
}

fn qcow_check_error(status: Option<i32>, path: &Path) -> io::Error {
    let message = match status {
        Some(3) => "qemu-img found leaked clusters; no repair was attempted",
        Some(2) => "qemu-img reported image corruption",
        _ => "qemu-img integrity check failed or did not complete",
    };
    io::Error::other(format!("{message}: {}", path.display()))
}

/// Android emulator disks may use `.img` despite containing QCOW2 data. The
/// suffix remains a reason to validate too, so a damaged header fails closed.
fn has_qcow_magic(path: &Path) -> io::Result<bool> {
    let mut file = File::open(path)?;
    let mut magic = [0u8; 4];
    match file.read_exact(&mut magic) {
        Ok(()) => Ok(magic == *b"QFI\xfb"),
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => Ok(false),
        Err(e) => Err(e),
    }
}

/// Copies into a new, empty staging directory and verifies every byte. The
/// caller is responsible for keeping the source quiescent throughout the copy.
/// Symlinks and special files are refused, except Unix sockets, which cannot
/// be copied and do not contain persistent data.
pub fn copy_verified(source: &Path, destination: &Path) -> io::Result<CopyReport> {
    let source = source.canonicalize()?;
    if !source.is_dir() {
        return Err(invalid("source must be a directory"));
    }
    let parent = destination
        .parent()
        .ok_or_else(|| invalid("destination must have a parent"))?
        .canonicalize()?;
    let name = destination
        .file_name()
        .ok_or_else(|| invalid("destination must have a name"))?;
    let destination = parent.join(name);
    if destination.starts_with(&source) || source.starts_with(&destination) {
        return Err(invalid("source and destination must not overlap"));
    }
    fs::create_dir(&destination)?;
    let mut report = CopyReport::default();
    copy_dir(&source, &destination, &mut report)?;
    File::open(&destination)?.sync_all()?;
    Ok(report)
}

fn copy_dir(source: &Path, destination: &Path, report: &mut CopyReport) -> io::Result<()> {
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let src = entry.path();
        let dst = destination.join(entry.file_name());
        let metadata = fs::symlink_metadata(&src)?;
        let ty = metadata.file_type();
        if ty.is_symlink() {
            return Err(invalid("symbolic links require manual review"));
        }
        if ty.is_dir() {
            fs::create_dir(&dst)?;
            copy_dir(&src, &dst, report)?;
            fs::set_permissions(&dst, metadata.permissions())?;
            preserve_times(&dst, &metadata)?;
        } else if ty.is_file() {
            copy_file(&src, &dst, &metadata, report)?;
            fs::set_permissions(&dst, metadata.permissions())?;
        } else {
            #[cfg(unix)]
            {
                use std::os::unix::fs::FileTypeExt;
                if ty.is_socket() {
                    report.skipped_sockets += 1;
                    continue;
                }
            }
            return Err(invalid("unsupported special file in source"));
        }
    }
    Ok(())
}

/// Check the whole copied tree again after copying completes. Per-file checks
/// alone cannot detect a file changed after its initial copy. This still does
/// not replace stopping all writers or holding the storage lease.
fn verify_tree(source: &Path, destination: &Path) -> io::Result<()> {
    let mut source_names = Vec::new();
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let metadata = fs::symlink_metadata(entry.path())?;
        let kind = metadata.file_type();
        #[cfg(unix)]
        {
            use std::os::unix::fs::FileTypeExt;
            if kind.is_socket() {
                continue;
            }
        }
        let dst = destination.join(entry.file_name());
        let dst_metadata = fs::symlink_metadata(&dst)?;
        if kind.is_dir() && dst_metadata.file_type().is_dir() {
            verify_tree(&entry.path(), &dst)?;
        } else if kind.is_file() && dst_metadata.file_type().is_file() {
            if metadata.len() != dst_metadata.len()
                || metadata.modified()? != dst_metadata.modified()?
                || hash(&entry.path())? != hash(&dst)?
            {
                return Err(io::Error::other(format!(
                    "source changed after copying: {}",
                    entry.path().display()
                )));
            }
        } else {
            return Err(invalid("source or copy contains an unsupported file"));
        }
        source_names.push(entry.file_name());
    }
    let mut destination_names = fs::read_dir(destination)?
        .map(|entry| entry.map(|entry| entry.file_name()))
        .collect::<io::Result<Vec<_>>>()?;
    source_names.sort_unstable();
    destination_names.sort_unstable();
    if source_names != destination_names {
        return Err(io::Error::other("source tree changed after copying"));
    }
    Ok(())
}

fn hash(path: &Path) -> io::Result<([u8; 32], u64)> {
    let mut input = File::open(path)?;
    let mut digest = Sha256::new();
    let mut buf = vec![0u8; 1024 * 1024];
    let mut total = 0u64;
    loop {
        let n = input.read(&mut buf)?;
        if n == 0 {
            break;
        }
        digest.update(&buf[..n]);
        total += n as u64;
    }
    Ok((digest.finalize().into(), total))
}

fn preserve_times(path: &Path, metadata: &fs::Metadata) -> io::Result<()> {
    let mut times = fs::FileTimes::new();
    if let Ok(modified) = metadata.modified() {
        times = times.set_modified(modified);
    }
    if let Ok(accessed) = metadata.accessed() {
        times = times.set_accessed(accessed);
    }
    let file = File::open(path)?;
    file.set_times(times)?;
    file.sync_all()
}

fn copy_file(
    source: &Path,
    destination: &Path,
    metadata: &fs::Metadata,
    report: &mut CopyReport,
) -> io::Result<()> {
    let mut input = File::open(source)?;
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(destination)?;
    let mut digest = Sha256::new();
    let mut buf = vec![0u8; 1024 * 1024];
    let mut total = 0u64;
    loop {
        let n = input.read(&mut buf)?;
        if n == 0 {
            break;
        }
        output.write_all(&buf[..n])?;
        digest.update(&buf[..n]);
        total += n as u64;
    }
    output.sync_all()?;
    let expected: [u8; 32] = digest.finalize().into();
    let copied = hash(destination)?;
    // Re-read the source too: detecting concurrent writes is a prerequisite,
    // although only stopping its writers can guarantee a consistent snapshot.
    let source_hash_after_copy = hash(source)?;
    let final_metadata = fs::metadata(source)?;
    if copied != (expected, total)
        || source_hash_after_copy != (expected, total)
        || metadata.len() != final_metadata.len()
        || metadata.modified()? != final_metadata.modified()?
    {
        return Err(io::Error::other(format!(
            "verification failed: {}",
            source.display()
        )));
    }
    preserve_times(destination, metadata)?;
    report.files += 1;
    report.bytes += total;
    Ok(())
}

/// Paths used for staging must be separate from both source and destination.
pub fn staging_path(destination: &Path, id: uuid::Uuid) -> io::Result<PathBuf> {
    let parent = destination
        .parent()
        .ok_or_else(|| invalid("destination must have a parent"))?;
    let name = destination
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| invalid("invalid destination"))?;
    Ok(parent.join(format!(".{name}.jidr-stage-{id}")))
}

/// A prepared but deliberately inactive copy. This is not proof that Android
/// snapshots will resume or that all concurrent writers were stopped.
#[derive(Debug)]
pub struct PreparedCopy {
    pub staging: PathBuf,
    pub journal: PathBuf,
    /// The paths in the copy have already been rewritten for this destination.
    destination: PathBuf,
    lease_token: uuid::Uuid,
    #[cfg(unix)]
    barrier_token: uuid::Uuid,
    pub marker: uuid::Uuid,
    pub data: CopyReport,
    pub cache: Option<CopyReport>,
    pub logs: Option<CopyReport>,
    pub qcow_disks: usize,
}

/// Prepares an inactive copy in a unique sibling of `destination`. Callers
/// must stop every source writer and prevent daemon restarts for the entire
/// operation. On error, the partial stage is retained for diagnosis; source
/// and destination are never removed or overwritten.
pub fn prepare_copy(
    source: &jidr_core::JidrPaths,
    destination: &Path,
    qemu_img: &Path,
    lease: &jidr_core::storage_lease::StorageLease,
    #[cfg(unix)] barrier: &crate::legacy_barrier::LegacySocketBarrier,
) -> io::Result<PreparedCopy> {
    if !lease.covers(&source.data)? {
        return Err(invalid("storage lease does not cover the source"));
    }
    ensure_avd_locks_inactive(source)?;
    ensure_avd_files_closed(source)?;
    ensure_snapshot_files_complete(source)?;
    #[cfg(unix)]
    if !barrier.covers(&source.socket()) {
        return Err(invalid("legacy daemon socket is not protected"));
    }
    if !destination.is_absolute()
        || destination
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err(invalid("destination must be a new absolute path"));
    }
    match fs::symlink_metadata(destination) {
        Ok(_) => return Err(invalid("destination already exists")),
        Err(e) if e.kind() == io::ErrorKind::NotFound => {}
        Err(e) => return Err(e),
    }
    if !qemu_img.is_file() {
        return Err(invalid("qemu-img not found"));
    }
    let parent = destination
        .parent()
        .ok_or_else(|| invalid("destination must have a parent"))?
        .canonicalize()?;
    let final_path = parent.join(
        destination
            .file_name()
            .ok_or_else(|| invalid("destination must have a name"))?,
    );
    for source_dir in [&source.data, &source.cache, &source.logs] {
        if source_dir.exists() {
            let existing = source_dir.canonicalize()?;
            if final_path.starts_with(&existing) || existing.starts_with(&final_path) {
                return Err(invalid("source and destination must not overlap"));
            }
        }
    }
    estimate_space(source, &parent)?;
    let transaction_id = uuid::Uuid::new_v4();
    let staging = staging_path(&final_path, transaction_id)?;
    let journal_path = parent.join(format!(".jidr-migration-{transaction_id}.json"));
    let mut journal = crate::migration_journal::Journal::create(
        &journal_path,
        &source.data.canonicalize()?,
        &final_path,
        &staging,
    )?;
    fs::create_dir(&staging)?;
    let staged_data = staging.join("data");
    let data = copy_verified(&source.data, &staged_data)?;
    let cache = if source.cache.is_dir() {
        Some(copy_verified(&source.cache, &staging.join("cache"))?)
    } else {
        fs::create_dir(staging.join("cache"))?;
        None
    };
    let logs = if source.logs.is_dir() {
        Some(copy_verified(&source.logs, &staging.join("logs"))?)
    } else {
        fs::create_dir(staging.join("logs"))?;
        None
    };
    verify_tree(&source.data, &staged_data)?;
    if cache.is_some() {
        verify_tree(&source.cache, &staging.join("cache"))?;
    }
    if logs.is_some() {
        verify_tree(&source.logs, &staging.join("logs"))?;
    }
    rewrite_known_references(&staged_data, &source.data, &final_path.join("data"))?;
    reject_stale_metadata(&staged_data, &source.data)?;
    let qcow_disks = validate_qcow_tree(&staged_data, qemu_img)?;
    ensure_avd_locks_inactive(source)?;
    ensure_avd_files_closed(source)?;
    ensure_snapshot_files_complete(source)?;
    #[cfg(unix)]
    if !barrier.covers(&source.socket()) {
        return Err(invalid(
            "legacy daemon socket protection was lost during copying",
        ));
    }
    let marker = uuid::Uuid::new_v4();
    jidr_core::paths::PortableLocation {
        root: staging.clone(),
        marker,
    }
    .write_marker()?;
    File::open(&staging)?.sync_all()?;
    journal.advance(
        &journal_path,
        crate::migration_journal::Phase::Prepared,
        Some(marker),
    )?;
    Ok(PreparedCopy {
        staging,
        journal: journal_path,
        destination: final_path,
        lease_token: lease.token(),
        #[cfg(unix)]
        barrier_token: barrier.token(),
        marker,
        data,
        cache,
        logs,
        qcow_disks,
    })
}

/// Move a prepared copy to its intended path without replacing anything that
/// appeared there in the meantime. This does not switch the active location:
/// the caller must still verify the actual devices and guard every writer.
/// On a synchronization error after rename, inspect both paths before retrying.
pub fn publish_copy(
    prepared: &PreparedCopy,
    source: &jidr_core::JidrPaths,
    lease: &jidr_core::storage_lease::StorageLease,
    #[cfg(unix)] barrier: &crate::legacy_barrier::LegacySocketBarrier,
) -> io::Result<jidr_core::paths::PortableLocation> {
    if !lease.covers(&source.data)? || prepared.lease_token != lease.token() {
        return Err(invalid("storage lease does not cover the source"));
    }
    ensure_avd_locks_inactive(source)?;
    ensure_avd_files_closed(source)?;
    ensure_snapshot_files_complete(source)?;
    #[cfg(unix)]
    if !barrier.covers(&source.socket()) || prepared.barrier_token != barrier.token() {
        return Err(invalid("legacy daemon socket protection was lost"));
    }
    if prepared.staging.parent() != prepared.destination.parent() {
        return Err(invalid("staging and destination must share a parent"));
    }
    jidr_core::paths::PortableLocation {
        root: prepared.staging.clone(),
        marker: prepared.marker,
    }
    .resolve()
    .map_err(|e| io::Error::other(e.to_string()))?;
    let mut journal = crate::migration_journal::Journal::read(&prepared.journal)?;
    if journal.source_data != source.data.canonicalize()?
        || journal.destination != prepared.destination
        || journal.staging != prepared.staging
        || journal.marker != Some(prepared.marker)
    {
        return Err(invalid("migration journal does not match prepared copy"));
    }
    journal.advance(
        &prepared.journal,
        crate::migration_journal::Phase::Publishing,
        Some(prepared.marker),
    )?;
    #[cfg(any(target_os = "macos", target_os = "linux", target_os = "android"))]
    rustix::fs::renameat_with(
        rustix::fs::CWD,
        &prepared.staging,
        rustix::fs::CWD,
        &prepared.destination,
        rustix::fs::RenameFlags::NOREPLACE,
    )
    .map_err(io::Error::from)?;
    #[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "android")))]
    return Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "atomic no-replace rename is unavailable",
    ));
    #[cfg(any(target_os = "macos", target_os = "linux", target_os = "android"))]
    {
        let parent = prepared
            .destination
            .parent()
            .ok_or_else(|| invalid("missing destination parent"))?;
        File::open(parent)?.sync_all()?;
        journal.advance(
            &prepared.journal,
            crate::migration_journal::Phase::Published,
            Some(prepared.marker),
        )?;
        Ok(jidr_core::paths::PortableLocation {
            root: prepared.destination.clone(),
            marker: prepared.marker,
        })
    }
}

/// Fail closed if known metadata formats still contain an old absolute data
/// path. Binary snapshot metadata is inspected, never modified blindly.
pub fn reject_stale_metadata(staging: &Path, old: &Path) -> io::Result<()> {
    let old_canonical = old.canonicalize()?;
    let mut needles = vec![old.to_string_lossy().into_owned().into_bytes()];
    let canonical = old_canonical.to_string_lossy().into_owned().into_bytes();
    if !needles.contains(&canonical) {
        needles.push(canonical);
    }
    scan_metadata(staging, &needles)
}

fn scan_metadata(dir: &Path, needles: &[Vec<u8>]) -> io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let ty = entry.file_type()?;
        if ty.is_symlink() {
            return Err(invalid("symbolic link in staged data"));
        }
        if ty.is_dir() {
            scan_metadata(&path, needles)?;
        } else if ty.is_file()
            && path
                .extension()
                .and_then(|e| e.to_str())
                .is_some_and(|ext| matches!(ext, "ini" | "json" | "txt" | "pb" | "xml"))
            && contains_stale_reference(&path, needles)?
        {
            return Err(io::Error::other(format!(
                "old path remains in metadata: {}",
                path.display()
            )));
        }
    }
    Ok(())
}

/// Stream potentially large metadata without overlooking references spanning
/// read boundaries. Memory use is bounded by the longest path plus one chunk.
fn contains_stale_reference(path: &Path, needles: &[Vec<u8>]) -> io::Result<bool> {
    let overlap = needles
        .iter()
        .map(Vec::len)
        .max()
        .unwrap_or(0)
        .saturating_sub(1);
    let mut file = File::open(path)?;
    let mut data = Vec::with_capacity(64 * 1024 + overlap);
    let mut chunk = [0u8; 64 * 1024];
    loop {
        let n = file.read(&mut chunk)?;
        if n == 0 {
            return Ok(false);
        }
        data.extend_from_slice(&chunk[..n]);
        if needles.iter().any(|needle| {
            !needle.is_empty() && data.windows(needle.len()).any(|part| part == needle)
        }) {
            return Ok(true);
        }
        let keep = overlap.min(data.len());
        data.drain(..data.len() - keep);
    }
}

/// Rewrites recognized path references in a verified *copy*. The final
/// destination need not exist yet. Binary snapshots and QCOW backing chains
/// must be checked separately before this copy can be activated.
pub fn rewrite_known_references(staging: &Path, old: &Path, new: &Path) -> io::Result<()> {
    let staging = staging.canonicalize()?;
    let old_canonical = old.canonicalize()?;
    if staging.starts_with(&old_canonical)
        || old_canonical.starts_with(&staging)
        || !old.is_absolute()
        || !new.is_absolute()
        || new.starts_with(old)
        || old.starts_with(new)
        || new.starts_with(&staging)
        || staging.starts_with(new)
        || new
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err(invalid("unsafe migration paths"));
    }
    let devices = staging.join("devices.json");
    if devices.exists() {
        let mut values: serde_json::Value = serde_json::from_slice(&fs::read(&devices)?)?;
        let devices_list = values
            .as_array_mut()
            .ok_or_else(|| invalid("invalid device registry"))?;
        for device in devices_list {
            for pointer in ["/sdk_root", "/root/patched_ramdisk_path", "/launch/ramdisk"] {
                if let Some(value) = device.pointer_mut(pointer)
                    && let Some(path) = value.as_str()
                    && let Some(rewritten) = relocate_path(path, old, new)?
                {
                    *value = serde_json::Value::String(rewritten);
                }
            }
        }
        write_changed(&devices, &serde_json::to_vec_pretty(&values)?)?;
    }
    let tools = staging.join("tool-paths.json");
    if tools.exists() {
        let mut values: serde_json::Value = serde_json::from_slice(&fs::read(&tools)?)?;
        if !values.is_object() {
            return Err(invalid("invalid tool path configuration"));
        }
        for pointer in ["/android_sdk", "/jdk_home"] {
            if let Some(value) = values.pointer_mut(pointer)
                && let Some(path) = value.as_str()
                && let Some(rewritten) = relocate_path(path, old, new)?
            {
                *value = serde_json::Value::String(rewritten);
            }
        }
        write_changed(&tools, &serde_json::to_vec_pretty(&values)?)?;
    }
    let avd = staging.join("avd");
    if avd.is_dir() {
        rewrite_ini_tree(&avd, old, new)?;
    }
    Ok(())
}

fn relocate_path(path: &str, old: &Path, new: &Path) -> io::Result<Option<String>> {
    let path = Path::new(path);
    let canonical_old = old.canonicalize()?;
    let Ok(relative) = path
        .strip_prefix(old)
        .or_else(|_| path.strip_prefix(&canonical_old))
    else {
        return Ok(None);
    };
    let mut normalized = PathBuf::new();
    for part in relative.components() {
        match part {
            std::path::Component::Normal(name) => normalized.push(name),
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir if normalized.pop() => {}
            _ => return Err(invalid("path escapes the old data directory")),
        }
    }
    let updated = new.join(normalized);
    Ok(Some(
        updated
            .to_str()
            .ok_or_else(|| invalid("path is not UTF-8"))?
            .to_owned(),
    ))
}

fn rewrite_ini_tree(dir: &Path, old: &Path, new: &Path) -> io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let ty = entry.file_type()?;
        if ty.is_symlink() {
            return Err(invalid("symbolic link in staged data"));
        }
        if ty.is_dir() {
            rewrite_ini_tree(&path, old, new)?;
        } else if ty.is_file() && path.file_name().is_some_and(|name| name == "snapshot.pb") {
            let bytes = fs::read(&path)?;
            let rewritten = rewrite_snapshot_message(&bytes, old, new, false)?;
            if rewritten != bytes {
                write_changed(&path, &rewritten)?;
            }
        } else if ty.is_file()
            && path
                .file_name()
                .is_some_and(|name| name == "emu-launch-params.txt")
        {
            let text = fs::read_to_string(&path)?;
            let mut out = String::with_capacity(text.len());
            for line in text.split_inclusive('\n') {
                let (body, end) = line.strip_suffix('\n').map_or((line, ""), |s| (s, "\n"));
                if let Some(relocated) = relocate_path(body, old, new)? {
                    out.push_str(&relocated);
                    out.push_str(end);
                } else {
                    out.push_str(line);
                }
            }
            if out != text {
                write_changed(&path, out.as_bytes())?;
            }
        } else if ty.is_file() && path.extension().is_some_and(|ext| ext == "ini") {
            let text = fs::read_to_string(&path)?;
            let mut out = String::with_capacity(text.len());
            for line in text.split_inclusive('\n') {
                let (body, end) = line.strip_suffix('\n').map_or((line, ""), |s| (s, "\n"));
                if let Some((key, value)) = body.split_once('=') {
                    let trimmed = value.trim();
                    if let Some(relocated) = relocate_path(trimmed, old, new)? {
                        let leading = value.len() - value.trim_start().len();
                        let trailing = value.len() - value.trim_end().len();
                        out.push_str(key);
                        out.push('=');
                        out.push_str(&value[..leading]);
                        out.push_str(&relocated);
                        if trailing > 0 {
                            out.push_str(&value[value.len() - trailing..]);
                        }
                        out.push_str(end);
                        continue;
                    }
                }
                out.push_str(line);
            }
            if out != text {
                write_changed(&path, out.as_bytes())?;
            }
        }
    }
    Ok(())
}

// snapshot.proto (AOSP): Snapshot.images = 3, Image.path = 2, and
// Snapshot.launch_parameters = 17. Preserve every other encoded byte rather
// than decoding/re-encoding the entire message (which would drop unknown
// fields added by newer emulator versions).
fn rewrite_snapshot_message(
    input: &[u8],
    old: &Path,
    new: &Path,
    image: bool,
) -> io::Result<Vec<u8>> {
    let mut output = Vec::with_capacity(input.len());
    let mut cursor = 0;
    while cursor < input.len() {
        let start = cursor;
        let key = read_varint(input, &mut cursor)?;
        let field = key >> 3;
        let wire = key & 7;
        if field == 0 {
            return Err(invalid("invalid snapshot protobuf field"));
        }
        let key_end = cursor;
        match wire {
            0 => {
                read_varint(input, &mut cursor)?;
            }
            1 => {
                cursor = cursor
                    .checked_add(8)
                    .filter(|n| *n <= input.len())
                    .ok_or_else(|| invalid("truncated snapshot protobuf"))?;
            }
            2 => {
                let len = usize::try_from(read_varint(input, &mut cursor)?)
                    .map_err(|_| invalid("snapshot field too large"))?;
                let end = cursor
                    .checked_add(len)
                    .filter(|n| *n <= input.len())
                    .ok_or_else(|| invalid("truncated snapshot protobuf"))?;
                let value = &input[cursor..end];
                let rewritten = if !image && field == 3 {
                    Some(rewrite_snapshot_message(value, old, new, true)?)
                } else if (image && field == 2) || (!image && field == 17) {
                    let text = std::str::from_utf8(value)
                        .map_err(|_| invalid("invalid snapshot path encoding"))?;
                    relocate_path(text, old, new)?.map(String::into_bytes)
                } else {
                    None
                };
                if let Some(value) = rewritten.filter(|v| v.as_slice() != &input[cursor..end]) {
                    output.extend_from_slice(&input[start..key_end]);
                    write_varint(&mut output, value.len() as u64);
                    output.extend_from_slice(&value);
                    cursor = end;
                    continue;
                }
                cursor = end;
            }
            5 => {
                cursor = cursor
                    .checked_add(4)
                    .filter(|n| *n <= input.len())
                    .ok_or_else(|| invalid("truncated snapshot protobuf"))?;
            }
            _ => return Err(invalid("unsupported snapshot protobuf wire type")),
        }
        output.extend_from_slice(&input[start..cursor]);
    }
    Ok(output)
}

fn read_varint(input: &[u8], cursor: &mut usize) -> io::Result<u64> {
    let mut result = 0u64;
    for shift in (0..70).step_by(7) {
        let byte = *input
            .get(*cursor)
            .ok_or_else(|| invalid("truncated snapshot protobuf"))?;
        *cursor += 1;
        if shift == 63 && byte > 1 {
            return Err(invalid("snapshot protobuf varint overflow"));
        }
        result |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Ok(result);
        }
    }
    Err(invalid("invalid snapshot protobuf varint"))
}

fn write_varint(output: &mut Vec<u8>, mut value: u64) {
    while value >= 0x80 {
        output.push((value as u8) | 0x80);
        value >>= 7;
    }
    output.push(value as u8);
}

fn write_changed(path: &Path, content: &[u8]) -> io::Result<()> {
    let metadata = fs::metadata(path)?;
    let mut file = OpenOptions::new().write(true).truncate(true).open(path)?;
    file.write_all(content)?;
    file.sync_all()?;
    preserve_times(path, &metadata)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migration_rejects_live_and_ambiguous_avd_locks() {
        let temp = tempfile::tempdir().unwrap();
        let paths = jidr_core::JidrPaths::under(temp.path());
        let avd = paths.avd_home().join("unregistered.avd");
        fs::create_dir_all(&avd).unwrap();
        let lock = avd.join("hardware-qemu.ini.lock");
        fs::write(&lock, std::process::id().to_string()).unwrap();
        assert!(ensure_avd_locks_inactive(&paths).is_err());
        fs::write(&lock, b"\0").unwrap();
        assert!(ensure_avd_locks_inactive(&paths).is_err());
        fs::remove_file(&lock).unwrap();
        assert!(ensure_avd_locks_inactive(&paths).is_ok());
    }

    #[test]
    fn incomplete_snapshot_blocks_copy_but_absent_snapshots_do_not() {
        let temp = tempfile::tempdir().unwrap();
        let paths = jidr_core::JidrPaths::under(temp.path());
        let avd = paths.avd_home().join("phone.avd");
        fs::create_dir_all(&avd).unwrap();
        assert!(ensure_snapshot_files_complete(&paths).is_ok());
        let snapshot = avd.join("snapshots/default_boot");
        fs::create_dir_all(&snapshot).unwrap();
        fs::write(snapshot.join("snapshot.pb"), b"metadata").unwrap();
        assert!(ensure_snapshot_files_complete(&paths).is_err());
        fs::write(snapshot.join("ram.bin"), b"").unwrap();
        assert!(ensure_snapshot_files_complete(&paths).is_err());
        let named = avd.join("snapshots/safety");
        fs::create_dir_all(&named).unwrap();
        fs::write(named.join("snapshot.pb"), b"metadata").unwrap();
        fs::write(named.join("ram.bin"), b"memory").unwrap();
        assert!(ensure_snapshot_files_complete(&paths).is_ok());
        fs::write(named.join("snapshot.pb"), b"").unwrap();
        assert!(ensure_snapshot_files_complete(&paths).is_err());
        fs::write(named.join("snapshot.pb"), b"metadata").unwrap();
        fs::write(named.join("ram.bin"), b"").unwrap();
        assert!(ensure_snapshot_files_complete(&paths).is_err());
        fs::write(named.join("ram.bin"), b"memory").unwrap();
        fs::write(snapshot.join("ram.bin"), b"memory").unwrap();
        assert!(ensure_snapshot_files_complete(&paths).is_ok());
    }

    #[test]
    fn migration_detects_open_avd_file_when_lsof_is_available() {
        if std::env::var_os("JIDR_TEST_LSOF").is_none() {
            return;
        }
        let temp = tempfile::tempdir().unwrap();
        let paths = jidr_core::JidrPaths::under(temp.path());
        let avd = paths.avd_home().join("device.avd");
        fs::create_dir_all(&avd).unwrap();
        let disk = avd.join("userdata.img");
        fs::write(&disk, b"game data").unwrap();
        let open = File::open(&disk).unwrap();
        assert!(ensure_avd_files_closed(&paths).is_err());
        drop(open);
        assert!(ensure_avd_files_closed(&paths).is_ok());
    }

    #[test]
    fn space_preflight_counts_logical_bytes_and_rejects_insufficient_space() {
        let temp = tempfile::tempdir().unwrap();
        let paths = jidr_core::JidrPaths::under(temp.path().join("source"));
        fs::create_dir_all(&paths.data).unwrap();
        fs::create_dir_all(&paths.cache).unwrap();
        let sparse = File::create(paths.data.join("sparse.img")).unwrap();
        sparse.set_len(1024 * 1024).unwrap();
        fs::write(paths.cache.join("file"), b"cache").unwrap();
        let estimate = estimate_with_available(&paths, u64::MAX).unwrap();
        assert_eq!(estimate.source_bytes, 1024 * 1024 + 5);
        assert!(estimate.required_bytes > estimate.source_bytes);
        assert!(estimate_with_available(&paths, estimate.required_bytes - 1).is_err());
        assert!(estimate_with_available(&paths, estimate.required_bytes).is_ok());
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink("missing", paths.data.join("link")).unwrap();
            assert!(estimate_with_available(&paths, u64::MAX).is_err());
        }
    }

    #[test]
    fn copy_preserves_data_and_leaves_source_untouched() {
        let t = tempfile::tempdir().unwrap();
        let source = t.path().join("old");
        fs::create_dir_all(source.join("avd/snapshots/default_boot")).unwrap();
        fs::write(source.join("avd/userdata.qcow2"), b"game data\0").unwrap();
        let stamp = std::time::UNIX_EPOCH + std::time::Duration::from_secs(1_600_000_000);
        File::open(source.join("avd/userdata.qcow2"))
            .unwrap()
            .set_times(fs::FileTimes::new().set_modified(stamp))
            .unwrap();
        fs::write(
            source.join("avd/snapshots/default_boot/ram.bin"),
            b"snapshot",
        )
        .unwrap();
        let target = t.path().join("staging");
        let report = copy_verified(&source, &target).unwrap();
        assert_eq!(report.files, 2);
        assert_eq!(
            fs::read(target.join("avd/userdata.qcow2")).unwrap(),
            b"game data\0"
        );
        assert_eq!(
            fs::metadata(target.join("avd/userdata.qcow2"))
                .unwrap()
                .modified()
                .unwrap(),
            stamp
        );
        assert_eq!(
            fs::read(source.join("avd/snapshots/default_boot/ram.bin")).unwrap(),
            b"snapshot"
        );
        assert!(copy_verified(&source, &target).is_err());
        assert!(verify_tree(&source, &target).is_ok());
        fs::write(source.join("avd/userdata.qcow2"), b"changed!!").unwrap();
        assert!(verify_tree(&source, &target).is_err());
        fs::copy(
            target.join("avd/userdata.qcow2"),
            source.join("avd/userdata.qcow2"),
        )
        .unwrap();
        preserve_times(
            &source.join("avd/userdata.qcow2"),
            &fs::metadata(target.join("avd/userdata.qcow2")).unwrap(),
        )
        .unwrap();
        fs::write(source.join("avd/new-file"), b"new").unwrap();
        assert!(verify_tree(&source, &target).is_err());
    }

    #[test]
    fn refuses_recursive_destination_and_symlinks() {
        let t = tempfile::tempdir().unwrap();
        let source = t.path().join("old");
        fs::create_dir(&source).unwrap();
        assert!(copy_verified(&source, &source.join("nested")).is_err());
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink("missing", source.join("link")).unwrap();
            assert!(copy_verified(&source, &t.path().join("staging")).is_err());
            assert!(source.join("link").is_symlink());
        }
    }

    #[test]
    fn rewrites_only_owned_references_in_staged_copy() {
        let t = tempfile::tempdir().unwrap();
        let source = t.path().join("old");
        let avd = source.join("avd/phone.avd/snapshots/saved");
        fs::create_dir_all(&avd).unwrap();
        let old = source.to_str().unwrap();
        let ini = format!("path = {old}/avd/phone.avd/userdata.img\nexternal = /other/sdk\n");
        fs::write(avd.join("hardware.ini"), &ini).unwrap();
        let launch = format!("-sysdir\n{old}/sdk/system-images/android-35\n");
        fs::write(source.join("avd/phone.avd/emu-launch-params.txt"), &launch).unwrap();
        fs::write(source.join("devices.json"), format!(r#"[{{"sdk_root":"{old}/sdk","root":{{"patched_ramdisk_path":null}},"launch":{{"ramdisk":"/other/ramdisk"}}}}]"#)).unwrap();
        fs::write(
            source.join("tool-paths.json"),
            format!(r#"{{"android_sdk":"{old}/sdk","jdk_home":"/other/jdk"}}"#),
        )
        .unwrap();
        let stage = t.path().join("stage");
        copy_verified(&source, &stage).unwrap();
        let target = t.path().join("new/data");
        rewrite_known_references(&stage, &source, &target).unwrap();
        let rewritten =
            fs::read_to_string(stage.join("avd/phone.avd/snapshots/saved/hardware.ini")).unwrap();
        assert!(rewritten.contains(&format!(
            "path = {}/avd/phone.avd/userdata.img",
            target.display()
        )));
        assert!(rewritten.contains("external = /other/sdk"));
        assert_eq!(
            fs::read_to_string(stage.join("avd/phone.avd/emu-launch-params.txt")).unwrap(),
            format!(
                "-sysdir\n{}/sdk/system-images/android-35\n",
                target.display()
            )
        );
        let registry: serde_json::Value =
            serde_json::from_slice(&fs::read(stage.join("devices.json")).unwrap()).unwrap();
        assert_eq!(registry[0]["sdk_root"], format!("{}/sdk", target.display()));
        assert_eq!(registry[0]["launch"]["ramdisk"], "/other/ramdisk");
        let tools: serde_json::Value =
            serde_json::from_slice(&fs::read(stage.join("tool-paths.json")).unwrap()).unwrap();
        assert_eq!(tools["android_sdk"], format!("{}/sdk", target.display()));
        assert_eq!(tools["jdk_home"], "/other/jdk");
        assert_eq!(fs::read_to_string(avd.join("hardware.ini")).unwrap(), ini);
    }

    #[test]
    fn normalizes_references_and_rejects_parent_escape() {
        let t = tempfile::tempdir().unwrap();
        let old = t.path().join("old");
        let new = t.path().join("new");
        fs::create_dir(&old).unwrap();
        let source = old.join("avd/../avd/device.img");
        assert_eq!(
            relocate_path(source.to_str().unwrap(), &old, &new).unwrap(),
            Some(new.join("avd/device.img").to_string_lossy().into_owned())
        );
        let escaping = old.join("../../outside");
        assert!(relocate_path(escaping.to_str().unwrap(), &old, &new).is_err());
    }

    #[test]
    fn remaining_binary_snapshot_path_blocks_activation() {
        let root = tempfile::tempdir().unwrap();
        let old = root.path().join("old");
        let stage = root.path().join("stage");
        fs::create_dir(&old).unwrap();
        fs::create_dir(&stage).unwrap();
        fs::write(
            stage.join("snapshot.pb"),
            [b"\0".as_slice(), old.to_str().unwrap().as_bytes()].concat(),
        )
        .unwrap();
        assert!(reject_stale_metadata(&stage, &old).is_err());
        fs::write(stage.join("snapshot.pb"), b"independent metadata").unwrap();
        assert!(reject_stale_metadata(&stage, &old).is_ok());
    }

    #[test]
    fn qcow_check_failure_reports_leaks_without_claiming_repair() {
        let path = Path::new("/test/disk.qcow2");
        assert!(
            qcow_check_error(Some(3), path)
                .to_string()
                .contains("leaked clusters")
        );
        assert!(
            qcow_check_error(Some(2), path)
                .to_string()
                .contains("corruption")
        );
        assert!(
            qcow_check_error(None, path)
                .to_string()
                .contains("did not complete")
        );
    }

    #[test]
    fn scans_large_metadata_and_matches_across_chunk_boundaries() {
        let root = tempfile::tempdir().unwrap();
        let old = root.path().join("old");
        let stage = root.path().join("stage");
        fs::create_dir(&old).unwrap();
        fs::create_dir(&stage).unwrap();
        let file = stage.join("large.txt");
        let mut content = vec![b'x'; 17 * 1024 * 1024];
        fs::write(&file, &content).unwrap();
        assert!(reject_stale_metadata(&stage, &old).is_ok());
        let needle = old.to_string_lossy();
        let start = 64 * 1024 - needle.len() / 2;
        content[start..start + needle.len()].copy_from_slice(needle.as_bytes());
        fs::write(&file, &content).unwrap();
        assert!(reject_stale_metadata(&stage, &old).is_err());
    }

    #[test]
    fn snapshot_paths_are_rewritten_without_losing_unknown_fields() {
        let temp = tempfile::tempdir().unwrap();
        let old = temp.path().join("old");
        let new = temp.path().join("new");
        fs::create_dir(&old).unwrap();
        let original_path = old.join("avd/disk.img").to_string_lossy().into_owned();
        let mut image = vec![0x08, 0x05, 0x12];
        write_varint(&mut image, original_path.len() as u64);
        image.extend_from_slice(original_path.as_bytes());
        image.extend_from_slice(&[0xf8, 0x01, 0x2a]); // unknown field 31
        let mut snapshot = vec![0x08, 0x01, 0x1a];
        write_varint(&mut snapshot, image.len() as u64);
        snapshot.extend_from_slice(&image);
        snapshot.extend_from_slice(&[0xf8, 0x01, 0x63]); // unknown top-level field
        let out = rewrite_snapshot_message(&snapshot, &old, &new, false).unwrap();
        assert!(out.windows(3).any(|w| w == [0xf8, 0x01, 0x2a]));
        assert!(out.ends_with(&[0xf8, 0x01, 0x63]));
        assert!(
            out.windows(new.to_str().unwrap().len())
                .any(|w| w == new.to_str().unwrap().as_bytes())
        );
        assert!(
            !out.windows(original_path.len())
                .any(|w| w == original_path.as_bytes())
        );
        assert!(rewrite_snapshot_message(&[0x1a, 0x80], &old, &new, false).is_err());
    }

    #[test]
    fn refuses_unsafe_or_damaged_qcow_backing_info() {
        let safe = serde_json::json!({"format":"qcow2", "dirty-flag":false, "format-specific":{"data":{"corrupt":false}}, "backing-filename":"userdata-qemu.img"});
        assert!(validate_qcow_info(&safe).is_ok());
        let mut bad = safe.clone();
        bad["backing-filename"] = "../outside.img".into();
        assert!(validate_qcow_info(&bad).is_err());
        bad["backing-filename"] = "/outside.img".into();
        assert!(validate_qcow_info(&bad).is_err());
        bad = safe.clone();
        bad["dirty-flag"] = true.into();
        assert!(validate_qcow_info(&bad).is_err());
        bad = safe;
        bad["format-specific"]["data"]["corrupt"] = true.into();
        assert!(validate_qcow_info(&bad).is_err());
    }

    #[test]
    fn real_qcow_validation_when_tool_is_available() {
        let Some(tool) = std::env::var_os("JIDR_TEST_QEMU_IMG") else {
            return;
        };
        let tool = PathBuf::from(tool);
        let root = tempfile::tempdir().unwrap();
        fs::write(root.path().join("base.img"), vec![0u8; 65536]).unwrap();
        let status = std::process::Command::new(&tool)
            .current_dir(root.path())
            .args([
                "create",
                "-f",
                "qcow2",
                "-F",
                "raw",
                "-b",
                "base.img",
                "test.qcow2",
            ])
            .output()
            .unwrap();
        assert!(
            status.status.success(),
            "{}",
            String::from_utf8_lossy(&status.stderr)
        );
        let status = std::process::Command::new(&tool)
            .current_dir(root.path())
            .args([
                "create",
                "-f",
                "qcow2",
                "-F",
                "qcow2",
                "-b",
                "test.qcow2",
                "nested.qcow2",
            ])
            .output()
            .unwrap();
        assert!(
            status.status.success(),
            "{}",
            String::from_utf8_lossy(&status.stderr)
        );
        fs::copy(
            root.path().join("test.qcow2"),
            root.path().join("userdata-qemu.img"),
        )
        .unwrap();
        assert_eq!(validate_qcow_tree(root.path(), &tool).unwrap(), 3);
        let staging_parent = tempfile::tempdir().unwrap();
        let staging = staging_parent.path().join("copy");
        let report = copy_verified(root.path(), &staging).unwrap();
        assert_eq!(report.files, 4);
        assert_eq!(validate_qcow_tree(&staging, &tool).unwrap(), 3);
        let source_parent = tempfile::tempdir().unwrap();
        let source = jidr_core::JidrPaths::under(source_parent.path().join("source"));
        fs::create_dir_all(source.data.join("avd/device.avd")).unwrap();
        for name in [
            "base.img",
            "test.qcow2",
            "nested.qcow2",
            "userdata-qemu.img",
        ] {
            fs::copy(
                root.path().join(name),
                source.data.join("avd/device.avd").join(name),
            )
            .unwrap();
        }
        fs::write(source.data.join("devices.json"), b"[]").unwrap();
        let final_parent = tempfile::tempdir().unwrap();
        let destination = final_parent.path().join("Jidr");
        let lease = jidr_core::storage_lease::StorageLease::acquire(&source.data).unwrap();
        #[cfg(unix)]
        let barrier =
            crate::legacy_barrier::LegacySocketBarrier::acquire(&source.socket()).unwrap();
        let prepared = prepare_copy(
            &source,
            &destination,
            &tool,
            &lease,
            #[cfg(unix)]
            &barrier,
        )
        .unwrap();
        assert!(!destination.exists());
        assert_eq!(prepared.qcow_disks, 3);
        let location = jidr_core::paths::PortableLocation {
            root: prepared.staging.clone(),
            marker: prepared.marker,
        };
        assert!(location.resolve().is_ok());
        assert!(source.data.join("avd/device.avd/nested.qcow2").exists());
        #[cfg(unix)]
        let barrier = {
            fs::remove_file(source.socket()).unwrap();
            assert!(publish_copy(&prepared, &source, &lease, &barrier).is_err());
            assert!(!destination.exists());
            drop(barrier);
            crate::legacy_barrier::LegacySocketBarrier::acquire(&source.socket()).unwrap()
        };
        #[cfg(unix)]
        assert!(publish_copy(&prepared, &source, &lease, &barrier).is_err());
        #[cfg(unix)]
        let prepared = prepare_copy(&source, &destination, &tool, &lease, &barrier).unwrap();
        drop(lease);
        let lease = jidr_core::storage_lease::StorageLease::acquire(&source.data).unwrap();
        assert!(
            publish_copy(
                &prepared,
                &source,
                &lease,
                #[cfg(unix)]
                &barrier
            )
            .is_err()
        );
        let prepared = prepare_copy(
            &source,
            &destination,
            &tool,
            &lease,
            #[cfg(unix)]
            &barrier,
        )
        .unwrap();
        assert!(
            prepare_copy(
                &source,
                &source.data.join("nested"),
                &tool,
                &lease,
                #[cfg(unix)]
                &barrier
            )
            .is_err()
        );
        fs::create_dir(&destination).unwrap();
        fs::write(destination.join("existing"), b"keep").unwrap();
        assert!(
            publish_copy(
                &prepared,
                &source,
                &lease,
                #[cfg(unix)]
                &barrier
            )
            .is_err()
        );
        assert_eq!(fs::read(destination.join("existing")).unwrap(), b"keep");
        assert!(prepared.staging.exists());
        assert_eq!(
            crate::migration_journal::Journal::read(&prepared.journal)
                .unwrap()
                .phase,
            crate::migration_journal::Phase::Publishing
        );
        fs::remove_dir_all(&destination).unwrap();
        assert!(
            publish_copy(
                &prepared,
                &source,
                &lease,
                #[cfg(unix)]
                &barrier
            )
            .is_err()
        );
        let prepared = prepare_copy(
            &source,
            &destination,
            &tool,
            &lease,
            #[cfg(unix)]
            &barrier,
        )
        .unwrap();
        let published = publish_copy(
            &prepared,
            &source,
            &lease,
            #[cfg(unix)]
            &barrier,
        )
        .unwrap();
        assert_eq!(
            crate::migration_journal::Journal::read(&prepared.journal)
                .unwrap()
                .phase,
            crate::migration_journal::Phase::Published
        );
        assert_eq!(published.root, destination.canonicalize().unwrap());
        assert!(published.resolve().is_ok());
        assert!(!prepared.staging.exists());
        assert!(source.data.join("avd/device.avd/nested.qcow2").exists());
        let absolute_backing = root.path().join("base.img");
        let output = std::process::Command::new(&tool)
            .current_dir(root.path())
            .args(["create", "-f", "qcow2", "-F", "raw", "-b"])
            .arg(&absolute_backing)
            .arg("absolute.qcow2")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(validate_qcow_tree(root.path(), &tool).is_err());
        fs::remove_file(root.path().join("absolute.qcow2")).unwrap();
        fs::remove_file(root.path().join("base.img")).unwrap();
        assert!(validate_qcow_tree(root.path(), &tool).is_err());
    }
}
