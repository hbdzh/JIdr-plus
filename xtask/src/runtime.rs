//! Reconstruct the pinned runtime from upstream archives and the reviewed core.
use std::collections::HashSet;
use std::fs::{self, File};
use std::io::{self, Read};
use std::path::{Component, Path, PathBuf};

use anyhow::{Context, Result, ensure};
use clap::Parser;
use serde::Deserialize;
use sha1::Sha1;
use sha2::{Digest, Sha256};
use zip::ZipArchive;

const CORE: &str = "emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless";

#[derive(Parser)]
#[command(
    name = "cargo xtask prepare-runtime",
    about = "Reconstruct the pinned local runtime"
)]
struct Args {
    #[arg(long)]
    emulator_zip: PathBuf,
    #[arg(long)]
    platform_tools_zip: PathBuf,
    #[arg(long)]
    core: PathBuf,
    #[arg(long)]
    output: PathBuf,
}

#[derive(Deserialize)]
struct Pins {
    emulator_sha1: String,
    platform_tools_sha1: String,
}

pub(crate) fn hash_file<D: Digest>(path: &Path) -> Result<String> {
    let mut file = File::open(path).with_context(|| format!("opening {}", path.display()))?;
    let mut hash = D::new();
    let mut buffer = [0u8; 1024 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hash.update(&buffer[..count]);
    }
    Ok(hex::encode(hash.finalize()))
}

pub(crate) fn parse_manifest(contents: &str) -> Result<Vec<(&str, &str)>> {
    let mut entries = Vec::new();
    let mut names = HashSet::new();
    for line in contents.lines() {
        let (hash, name) = line
            .split_once("  ")
            .context("invalid runtime manifest entry")?;
        ensure!(
            hash.len() == 64 && hash.bytes().all(|c| c.is_ascii_hexdigit()),
            "invalid runtime checksum: {name}"
        );
        let path = Path::new(name);
        ensure!(
            !name.contains('\\')
                && path.components().all(|c| matches!(c, Component::Normal(_)))
                && (name.starts_with("emulator/") || name.starts_with("platform-tools/")),
            "unsafe manifest path: {name}"
        );
        ensure!(names.insert(name), "duplicate runtime entry: {name}");
        entries.push((hash, name));
    }
    ensure!(
        !entries.is_empty() && names.contains(CORE),
        "runtime manifest is empty or missing the core"
    );
    Ok(entries)
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: u32) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(path, fs::Permissions::from_mode(mode & 0o777))?;
    Ok(())
}

#[cfg(not(unix))]
fn set_mode(_path: &Path, _mode: u32) -> Result<()> {
    Ok(())
}

fn prepare(args: &Args, records: &Path) -> Result<()> {
    let pins: Pins = serde_json::from_reader(File::open(records.join("runtime-inputs.json"))?)?;
    for (label, path, expected) in [
        ("emulator", &args.emulator_zip, pins.emulator_sha1),
        (
            "platform-tools",
            &args.platform_tools_zip,
            pins.platform_tools_sha1,
        ),
    ] {
        ensure!(
            hash_file::<Sha1>(path)? == expected,
            "{label} archive checksum does not match the pinned release"
        );
    }
    let output = if args.output.is_absolute() {
        args.output.clone()
    } else {
        std::env::current_dir()?.join(&args.output)
    };
    ensure!(
        fs::symlink_metadata(&output).is_err_and(|e| e.kind() == io::ErrorKind::NotFound),
        "output already exists or cannot be inspected: {}",
        output.display()
    );
    let parent = output.parent().context("output must have a parent")?;
    ensure!(
        parent.is_dir(),
        "output parent does not exist: {}",
        parent.display()
    );
    let manifest = fs::read_to_string(records.join("runtime-sha256.txt"))?;
    let entries = parse_manifest(&manifest)?;
    let mut emulator = ZipArchive::new(File::open(&args.emulator_zip)?)?;
    let mut platform = ZipArchive::new(File::open(&args.platform_tools_zip)?)?;
    let tmp = tempfile::Builder::new()
        .prefix(".miko-runtime-")
        .tempdir_in(parent)?;
    let staging = tmp.path().join("sdk");
    fs::create_dir(&staging)?;
    for (expected, name) in entries {
        let relative = Path::new(name);
        let destination = staging.join(relative);
        fs::create_dir_all(destination.parent().context("invalid runtime path")?)?;
        let mode = if name == CORE {
            fs::copy(&args.core, &destination)?;
            0o755
        } else if relative
            .file_name()
            .and_then(|n| n.to_str())
            .is_some_and(|n| n.starts_with(".miko-"))
        {
            fs::copy(records.join("metadata").join(relative), &destination)?;
            0o644
        } else {
            let archive = if name.starts_with("emulator/") {
                &mut emulator
            } else {
                &mut platform
            };
            let mut entry = archive
                .by_name(name)
                .with_context(|| format!("missing archive entry: {name}"))?;
            let mode = entry.unix_mode().unwrap_or(0o644) & 0o777;
            let mut file = File::create(&destination)?;
            io::copy(&mut entry, &mut file)?;
            mode
        };
        set_mode(&destination, mode)?;
        ensure!(
            hash_file::<Sha256>(&destination)? == expected,
            "runtime file checksum mismatch: {name}"
        );
    }
    // Reserve the name without overwriting an existing file or directory. Rename
    // then replaces only the empty directory created by this invocation.
    fs::create_dir(&output).with_context(|| format!("reserving output {}", output.display()))?;
    if let Err(error) = fs::rename(&staging, &output) {
        let _ = fs::remove_dir(&output);
        return Err(error).context("publishing prepared runtime");
    }
    println!("Pinned runtime prepared: {}", output.display());
    println!(
        "Local candidate only: review distribution rights and corresponding source before publication."
    );
    Ok(())
}

pub fn run(args: &[String]) -> Result<()> {
    let args = match Args::try_parse_from(
        std::iter::once("prepare-runtime").chain(args.iter().map(String::as_str)),
    ) {
        Ok(args) => args,
        Err(error) if error.kind() == clap::error::ErrorKind::DisplayHelp => {
            error.print()?;
            return Ok(());
        }
        Err(error) => return Err(error.into()),
    };
    prepare(
        &args,
        &crate::workspace_root().join("packaging/runtime-source"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_rejects_unsafe_or_duplicate_paths() {
        let hash = "a".repeat(64);
        let core = format!("{hash}  {CORE}\n");
        assert!(parse_manifest(&core).is_ok());
        for path in [
            "../escape",
            "emulator/../escape",
            "/emulator/file",
            "emulator/evil\\path",
            "unknown/file",
        ] {
            assert!(
                parse_manifest(&format!("{core}{hash}  {path}\n")).is_err(),
                "{path}"
            );
        }
        assert!(parse_manifest(&(core.clone() + &core)).is_err());
        assert!(parse_manifest(&format!("bad  {CORE}\n")).is_err());
    }

    #[test]
    fn wrong_archive_is_rejected_without_creating_output() {
        let temp = tempfile::tempdir().unwrap();
        let archive = temp.path().join("wrong.zip");
        fs::write(&archive, b"wrong").unwrap();
        let records = temp.path().join("records");
        fs::create_dir(&records).unwrap();
        fs::write(
            records.join("runtime-inputs.json"),
            r#"{"emulator_sha1":"not-the-hash","platform_tools_sha1":"bad"}"#,
        )
        .unwrap();
        let args = Args {
            emulator_zip: archive.clone(),
            platform_tools_zip: archive.clone(),
            core: archive,
            output: temp.path().join("output"),
        };
        assert!(prepare(&args, &records).is_err());
        assert!(!args.output.exists());
    }
}
