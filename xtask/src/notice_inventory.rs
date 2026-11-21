//! Filename-based review leads, not proof of licence or source correspondence.
use std::collections::HashMap;
use std::fs::File;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, ensure};
use clap::Parser;
use serde::Serialize;
use serde_json::Value;
use sha2::Sha256;
use walkdir::WalkDir;

const CORE: &str = "emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless";
const STATUS: &str = "review leads only; source and licence correspondence not established";
const BINARIES: &str = "Binaries using the license";

#[derive(Parser)]
#[command(
    name = "cargo xtask inventory-runtime-notices",
    about = "List pinned runtime notice review leads"
)]
struct Args {
    #[arg(long)]
    sdk: PathBuf,
}

#[derive(Serialize)]
struct Entry {
    path: String,
    sha256: String,
    modified_core: bool,
    notice_entry_indexes: Vec<usize>,
}

#[derive(Serialize)]
struct Inventory {
    status: &'static str,
    notices: Vec<HashMap<String, String>>,
    executables: Vec<Entry>,
}

fn notice_matches(relative: &str, notices: &[HashMap<String, String>]) -> Vec<usize> {
    let filename = relative.rsplit('/').next().unwrap_or(relative);
    let stripped = filename.strip_prefix("lib").unwrap_or(filename);
    let dot_path = format!("./{relative}");
    notices
        .iter()
        .enumerate()
        .filter_map(|(index, row)| {
            let binaries = row.get(BINARIES)?;
            binaries
                .split_whitespace()
                .any(|item| [relative, dot_path.as_str(), filename, stripped].contains(&item))
                .then_some(index)
        })
        .collect()
}

fn inventory(sdk: &Path, records: &Path) -> Result<Inventory> {
    let sdk = sdk
        .canonicalize()
        .with_context(|| format!("opening {}", sdk.display()))?;
    let manifest = std::fs::read_to_string(records.join("runtime-sha256.txt"))?;
    let expected: HashMap<_, _> = crate::runtime::parse_manifest(&manifest)?
        .into_iter()
        .map(|(hash, name)| (name, hash))
        .collect();
    let notice = sdk.join("emulator/NOTICE.csv");
    ensure!(
        crate::runtime::hash_file::<Sha256>(&notice)?
            == *expected
                .get("emulator/NOTICE.csv")
                .context("NOTICE.csv absent from manifest")?,
        "NOTICE.csv differs from the pinned runtime"
    );
    let mut reader = csv::Reader::from_reader(File::open(&notice)?);
    let headers = reader.headers()?.clone();
    ensure!(
        headers.iter().any(|s| s.trim() == BINARIES),
        "NOTICE.csv has no binaries column"
    );
    let mut notices = Vec::new();
    for row in reader.records() {
        let row = row?;
        notices.push(
            headers
                .iter()
                .zip(row.iter())
                .map(|(key, value)| (key.trim().to_owned(), value.trim().to_owned()))
                .collect(),
        );
    }
    let emulator = sdk.join("emulator");
    let mut files = Vec::new();
    for entry in WalkDir::new(&emulator).follow_links(false) {
        let entry = entry?;
        if entry.file_type().is_file() {
            files.push(entry.into_path());
        }
    }
    files.sort();
    let mut executables = Vec::new();
    for path in files {
        let output = Command::new("file")
            .arg("-b")
            .arg(&path)
            .output()
            .with_context(|| format!("inspecting {}", path.display()))?;
        ensure!(
            output.status.success(),
            "file failed for {}",
            path.display()
        );
        if !String::from_utf8_lossy(&output.stdout).contains("Mach-O") {
            continue;
        }
        let name = path
            .strip_prefix(&sdk)?
            .to_str()
            .context("non-UTF8 runtime path")?
            .replace(std::path::MAIN_SEPARATOR, "/");
        let digest = crate::runtime::hash_file::<Sha256>(&path)?;
        ensure!(
            expected.get(name.as_str()) == Some(&digest.as_str()),
            "unknown or modified executable: {name}"
        );
        let relative = name
            .strip_prefix("emulator/")
            .context("unexpected executable path")?;
        executables.push(Entry {
            notice_entry_indexes: notice_matches(relative, &notices),
            modified_core: name == CORE,
            path: name,
            sha256: digest,
        });
    }
    ensure!(
        executables.iter().any(|entry| entry.modified_core),
        "pinned headless core is missing"
    );
    Ok(Inventory {
        status: STATUS,
        notices,
        executables,
    })
}

pub fn run(args: &[String]) -> Result<()> {
    let args = match Args::try_parse_from(
        std::iter::once("inventory-runtime-notices").chain(args.iter().map(String::as_str)),
    ) {
        Ok(args) => args,
        Err(error) if error.kind() == clap::error::ErrorKind::DisplayHelp => {
            error.print()?;
            return Ok(());
        }
        Err(error) => return Err(error.into()),
    };
    let value: Value = serde_json::to_value(inventory(
        &args.sdk,
        &crate::workspace_root().join("packaging/runtime-source"),
    )?)?;
    println!("{}", serde_json::to_string_pretty(&value)?);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn matches_only_declared_filename_variants() {
        let rows = vec![
            HashMap::from([(
                BINARIES.to_owned(),
                "./qemu/libthing.dylib other".to_owned(),
            )]),
            HashMap::from([(BINARIES.to_owned(), "thing.dylib".to_owned())]),
            HashMap::from([(BINARIES.to_owned(), "otherthing.dylib".to_owned())]),
        ];
        assert_eq!(notice_matches("qemu/libthing.dylib", &rows), vec![0, 1]);
        assert!(notice_matches("qemu/missing", &rows).is_empty());
    }
}
