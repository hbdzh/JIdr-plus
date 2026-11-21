//! Download pinned source-review archives without treating them as complete source.
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail, ensure};
use clap::Parser;
use sha2::Sha256;

const BASE: &str = "https://github.com/hbdzh/miko-simulator/releases/download/v0.10.0";
const FILES: [(&str, &str); 3] = [
    (
        "miko-runtime-source-review-0.10.0.tar.gz",
        "2c97d0aa0be2833243c36f414e92ce55d05bea4605c03d068353164353f8299a",
    ),
    (
        "miko-runtime-source-projects-0.10.0.tar",
        "7ac094b68991d5fa8bf7074a4bbfe695ecc33c73acc32ad6fb49011adc80d13c",
    ),
    (
        "miko-runtime-dependency-sources-0.10.0.tar.gz",
        "76db58aa626bd6e4eb86309ded4c91ce68abbfc0305788ba24356a86fe9357d2",
    ),
];

#[derive(Parser)]
#[command(
    name = "cargo xtask prepare-runtime-sources",
    about = "Prepare pinned source-review archives"
)]
struct Args {
    #[arg(long)]
    out: PathBuf,
}

fn entry(archive: &Path, name: &str) -> Result<Vec<u8>> {
    let result = Command::new("tar")
        .arg("-xOf")
        .arg(archive)
        .arg(name)
        .output()?;
    ensure!(
        result.status.success(),
        "cannot read {name} from {}: {}",
        archive.display(),
        String::from_utf8_lossy(&result.stderr)
    );
    Ok(result.stdout)
}

fn prepare<F>(out: &Path, records: &Path, files: &[(&str, &str)], mut fetch: F) -> Result<()>
where
    F: FnMut(&str, &Path) -> Result<()>,
{
    ensure!(
        out.is_dir(),
        "output directory does not exist: {}",
        out.display()
    );
    for (name, _) in files {
        ensure!(
            Path::new(name).file_name().and_then(|v| v.to_str()) == Some(*name),
            "invalid archive name"
        );
        ensure!(
            fs::symlink_metadata(out.join(name))
                .is_err_and(|e| e.kind() == io::ErrorKind::NotFound),
            "output already exists: {}",
            out.join(name).display()
        );
    }
    let stage = tempfile::Builder::new()
        .prefix(".miko-source-prep-")
        .tempdir_in(out)?;
    for (index, (name, expected)) in files.iter().enumerate() {
        let target = stage.path().join(name);
        fetch(name, &target)?;
        ensure!(
            crate::runtime::hash_file::<Sha256>(&target)? == *expected,
            "checksum mismatch: {name}"
        );
        if index == 0 {
            for name in ["runtime-sha256.txt", "qemu-local.patch"] {
                ensure!(
                    entry(&target, &format!("miko-runtime-source/{name}"))?
                        == fs::read(records.join(name))?,
                    "source review does not match current {name}"
                );
            }
        }
    }
    // Hard links publish without replacing an existing path, and all staging
    // files live on the output filesystem. Roll back files from this invocation.
    let mut published: Vec<PathBuf> = Vec::new();
    for (name, _) in files {
        let destination = out.join(name);
        if let Err(error) = fs::hard_link(stage.path().join(name), &destination) {
            for path in &published {
                let _ = fs::remove_file(path);
            }
            bail!("publishing {}: {error}", destination.display());
        }
        published.push(destination);
    }
    println!(
        "Prepared incomplete source-review materials; the separate release review gate still applies."
    );
    Ok(())
}

pub fn run(args: &[String]) -> Result<()> {
    let args = match Args::try_parse_from(
        std::iter::once("prepare-runtime-sources").chain(args.iter().map(String::as_str)),
    ) {
        Ok(args) => args,
        Err(error) if error.kind() == clap::error::ErrorKind::DisplayHelp => {
            error.print()?;
            return Ok(());
        }
        Err(error) => return Err(error.into()),
    };
    let records = crate::workspace_root().join("packaging/runtime-source");
    prepare(&args.out, &records, &FILES, |name, target| {
        let status = Command::new("curl")
            .args([
                "--fail",
                "--silent",
                "--show-error",
                "--location",
                "--retry",
                "3",
                "--proto",
                "=https",
                "--proto-redir",
                "=https",
            ])
            .arg(format!("{BASE}/{name}"))
            .arg("--output")
            .arg(target)
            .status()
            .context("running curl")?;
        ensure!(status.success(), "download failed: {name}");
        Ok(())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn checks_archives_before_publishing_and_never_overwrites() {
        let temp = tempfile::tempdir().unwrap();
        let records = temp.path().join("records");
        let source = temp.path().join("source");
        let out = temp.path().join("out");
        let inner = source.join("miko-runtime-source");
        fs::create_dir_all(&inner).unwrap();
        fs::create_dir(&records).unwrap();
        fs::create_dir(&out).unwrap();
        for name in ["runtime-sha256.txt", "qemu-local.patch"] {
            fs::write(inner.join(name), name).unwrap();
            fs::write(records.join(name), name).unwrap();
        }
        let fixture = temp.path().join("review.tar.gz");
        assert!(
            Command::new("tar")
                .current_dir(&source)
                .arg("-czf")
                .arg(&fixture)
                .arg("miko-runtime-source")
                .status()
                .unwrap()
                .success()
        );
        let other = temp.path().join("other");
        fs::write(&other, b"archive fixture").unwrap();
        let review_hash = crate::runtime::hash_file::<Sha256>(&fixture).unwrap();
        let other_hash = crate::runtime::hash_file::<Sha256>(&other).unwrap();
        let files = [
            ("review.tar.gz", review_hash.as_str()),
            ("projects.tar", other_hash.as_str()),
            ("dependencies.tar.gz", other_hash.as_str()),
        ];
        let fetch = |name: &str, target: &Path| -> Result<()> {
            fs::copy(
                if name == "review.tar.gz" {
                    &fixture
                } else {
                    &other
                },
                target,
            )?;
            Ok(())
        };
        let wrong = [
            ("review.tar.gz", review_hash.as_str()),
            ("projects.tar", "incorrect"),
            ("dependencies.tar.gz", other_hash.as_str()),
        ];
        assert!(prepare(&out, &records, &wrong, fetch).is_err());
        assert!(!out.join("review.tar.gz").exists());
        fs::write(records.join("runtime-sha256.txt"), "changed").unwrap();
        assert!(prepare(&out, &records, &files, fetch).is_err());
        assert!(!out.join("review.tar.gz").exists());
        fs::write(records.join("runtime-sha256.txt"), "runtime-sha256.txt").unwrap();
        prepare(&out, &records, &files, fetch).unwrap();
        assert_eq!(
            fs::read(out.join("projects.tar")).unwrap(),
            b"archive fixture"
        );
        assert!(prepare(&out, &records, &files, fetch).is_err());
        assert_eq!(
            fs::read(out.join("projects.tar")).unwrap(),
            b"archive fixture"
        );
    }
}
