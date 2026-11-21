//! Collect source-review candidates; this does not certify corresponding source.
use std::fs::{self, File};
use std::io::{self, Write};
use std::path::{Component, Path, PathBuf};
use std::process::{Command, Stdio};

use anyhow::{Context, Result, bail, ensure};
use clap::Parser;
use serde::Serialize;
use sha2::Sha256;
use walkdir::WalkDir;

const SOURCE_ARCHIVE: &str = "prebuilts/android-emulator-build/archive";
const RECORDS: &[&str] = &[
    "qemu-local.patch",
    "aosp-checked-out.xml",
    "checkout-revisions.txt",
    "NOTICE-core.txt",
    "NOTICE-core.csv",
    "LICENSE-qemu.txt",
    "COPYING-GPL-2.0",
    "COPYING-LGPL-2.1",
    "runtime-sha256.txt",
    "NOTICE-build-addendum.txt",
    "LICENSE-FFmpeg-4.4.2.md",
    "COPYING-FFmpeg-GPLv2",
    "COPYING-x264-GPLv2",
];

#[derive(Parser)]
#[command(
    name = "cargo xtask collect-runtime-source",
    about = "Collect a pinned source review candidate"
)]
struct Args {
    #[arg(long)]
    aosp_root: PathBuf,
    #[arg(long, required_unless_present = "verify_only")]
    output: Option<PathBuf>,
    #[arg(long)]
    verify_only: bool,
}

#[derive(Serialize)]
struct Project {
    path: String,
    revision: String,
    archive: String,
    sha256: String,
}

fn git(path: &Path, args: &[&str]) -> Result<Vec<u8>> {
    let output = Command::new("git")
        .args(args)
        .current_dir(path)
        .output()
        .with_context(|| format!("running git in {}", path.display()))?;
    ensure!(
        output.status.success(),
        "git failed in {}: {}",
        path.display(),
        String::from_utf8_lossy(&output.stderr)
    );
    Ok(output.stdout)
}

fn selected_revisions(contents: &str) -> Result<Vec<(&str, &str)>> {
    let mut projects = Vec::new();
    for row in contents.lines() {
        if row.starts_with("MISSING ") {
            continue;
        }
        let fields: Vec<_> = row.split_whitespace().collect();
        ensure!(fields.len() == 2, "invalid revision entry: {row}");
        let (name, revision) = (fields[0], fields[1]);
        ensure!(
            Path::new(name)
                .components()
                .all(|c| matches!(c, Component::Normal(_)))
                && !name.contains('\\')
                && revision.len() == 40
                && revision.bytes().all(|c| c.is_ascii_hexdigit()),
            "invalid source revision entry: {row}"
        );
        if name.starts_with("prebuilts/") && name != SOURCE_ARCHIVE {
            continue;
        }
        projects.push((name, revision));
    }
    ensure!(!projects.is_empty(), "source revision list is empty");
    Ok(projects)
}

fn collect(args: &Args, records: &Path) -> Result<()> {
    let root = args
        .aosp_root
        .canonicalize()
        .context("opening AOSP checkout")?;
    let output = args
        .output
        .as_ref()
        .map(|path| -> Result<PathBuf> {
            if path.is_absolute() {
                Ok(path.clone())
            } else {
                Ok(std::env::current_dir()?.join(path))
            }
        })
        .transpose()?;
    if let Some(path) = &output {
        ensure!(
            fs::symlink_metadata(path).is_err_and(|e| e.kind() == io::ErrorKind::NotFound),
            "output already exists or cannot be inspected: {}",
            path.display()
        );
        ensure!(
            path.parent().is_some_and(Path::is_dir),
            "output parent does not exist"
        );
    }
    let revisions = fs::read_to_string(records.join("checkout-revisions.txt"))?;
    let projects = selected_revisions(&revisions)?;
    let patch = fs::read(records.join("qemu-local.patch"))?;
    for (name, revision) in &projects {
        let path = root.join(name);
        let actual = git(&path, &["rev-parse", "HEAD"])?;
        ensure!(
            std::str::from_utf8(&actual)?.trim() == *revision,
            "wrong revision: {name}"
        );
        let diff = git(&path, &["diff", "--binary", "HEAD", "--"])?;
        if *name == "external/qemu" {
            ensure!(
                diff == patch,
                "QEMU modifications differ from the recorded patch"
            );
        } else {
            ensure!(
                diff.is_empty(),
                "tracked source modifications must be recorded: {name}"
            );
        }
    }
    if args.verify_only {
        println!(
            "Pinned tracked source verified: {} projects",
            projects.len()
        );
        return Ok(());
    }
    let output = output.context("--output is required unless --verify-only is used")?;
    let tmp = tempfile::Builder::new()
        .prefix(".miko-source-review-")
        .tempdir_in(output.parent().context("output has no parent")?)?;
    let stage = tmp.path().join("source-review");
    fs::create_dir_all(stage.join("projects"))?;
    let mut entries = Vec::new();
    for (name, revision) in &projects {
        let filename = format!("{}.tar.gz", name.replace('/', "__"));
        let archive = format!("projects/{filename}");
        let target = stage.join(&archive);
        println!("Archiving {name}");
        let status = Command::new("git")
            .current_dir(root.join(name))
            .args([
                "archive",
                "--format=tar.gz",
                &format!("--prefix={name}/"),
                revision,
            ])
            .stdout(Stdio::from(File::create(&target)?))
            .status()?;
        ensure!(status.success(), "git archive failed for {name}");
        entries.push(Project {
            path: (*name).to_owned(),
            revision: (*revision).to_owned(),
            archive,
            sha256: crate::runtime::hash_file::<Sha256>(&target)?,
        });
    }
    for name in RECORDS {
        fs::copy(records.join(name), stage.join(name))?;
    }
    let mut json = serde_json::to_vec_pretty(&entries)?;
    json.push(b'\n');
    fs::write(stage.join("PROJECTS.json"), json)?;
    fs::write(
        stage.join("README.txt"),
        "Source REVIEW CANDIDATE only; not verified complete corresponding source.\nArchives contain Git-tracked source at the recorded revisions; apply qemu-local.patch to external/qemu. The archive project contains dependency source candidates.\nStock Google binary/source mapping, untracked build inputs, clean build, licences, and public source distribution remain unverified.\n",
    )?;
    let mut files = Vec::new();
    for entry in WalkDir::new(&stage).follow_links(false) {
        let entry = entry?;
        if entry.file_type().is_file() {
            files.push(entry.into_path());
        }
    }
    files.sort();
    let mut sums = File::create(stage.join("SHA256SUMS.txt"))?;
    for file in files {
        writeln!(
            sums,
            "{}  {}",
            crate::runtime::hash_file::<Sha256>(&file)?,
            file.strip_prefix(&stage)?.display()
        )?;
    }
    drop(sums);
    fs::create_dir(&output).with_context(|| format!("reserving output {}", output.display()))?;
    if let Err(error) = fs::rename(&stage, &output) {
        let _ = fs::remove_dir(&output);
        bail!("publishing source review: {error}");
    }
    println!(
        "Source review candidate: {} ({} projects)",
        output.display(),
        entries.len()
    );
    Ok(())
}

pub fn run(args: &[String]) -> Result<()> {
    let args = match Args::try_parse_from(
        std::iter::once("collect-runtime-source").chain(args.iter().map(String::as_str)),
    ) {
        Ok(args) => args,
        Err(error) if error.kind() == clap::error::ErrorKind::DisplayHelp => {
            error.print()?;
            return Ok(());
        }
        Err(error) => return Err(error.into()),
    };
    collect(
        &args,
        &crate::workspace_root().join("packaging/runtime-source"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn collects_clean_sources_and_rejects_unrecorded_changes() {
        let temp = tempfile::tempdir().unwrap();
        let aosp = temp.path().join("aosp");
        let project = aosp.join("external/qemu");
        fs::create_dir_all(&project).unwrap();
        let run = |args: &[&str]| {
            let status = Command::new("git")
                .args(args)
                .current_dir(&project)
                .status()
                .unwrap();
            assert!(status.success());
        };
        run(&["init", "-q"]);
        run(&["config", "user.email", "test@example.invalid"]);
        run(&["config", "user.name", "Test"]);
        fs::write(project.join("source.txt"), "original\n").unwrap();
        run(&["add", "source.txt"]);
        run(&["commit", "-qm", "fixture"]);
        let head = String::from_utf8(git(&project, &["rev-parse", "HEAD"]).unwrap()).unwrap();
        fs::write(project.join("source.txt"), "changed\n").unwrap();
        let patch = git(&project, &["diff", "--binary", "HEAD", "--"]).unwrap();
        let records = temp.path().join("records");
        fs::create_dir(&records).unwrap();
        for name in RECORDS {
            fs::write(records.join(name), b"fixture").unwrap();
        }
        fs::write(
            records.join("checkout-revisions.txt"),
            format!("external/qemu {}\n", head.trim()),
        )
        .unwrap();
        fs::write(records.join("qemu-local.patch"), patch).unwrap();
        let output = temp.path().join("review");
        let args = Args {
            aosp_root: aosp,
            output: Some(output.clone()),
            verify_only: false,
        };
        collect(&args, &records).unwrap();
        let project_json: serde_json::Value =
            serde_json::from_slice(&fs::read(output.join("PROJECTS.json")).unwrap()).unwrap();
        let archive = output.join(project_json[0]["archive"].as_str().unwrap());
        assert_eq!(
            project_json[0]["sha256"],
            crate::runtime::hash_file::<Sha256>(&archive).unwrap()
        );
        assert!(
            fs::read_to_string(output.join("SHA256SUMS.txt"))
                .unwrap()
                .contains("projects/external__qemu.tar.gz")
        );
        assert!(collect(&args, &records).is_err());
        fs::write(project.join("source.txt"), "unrecorded\n").unwrap();
        let bad = Args {
            output: Some(temp.path().join("bad")),
            ..args
        };
        assert!(collect(&bad, &records).is_err());
        assert!(!bad.output.unwrap().exists());
    }

    #[test]
    fn revisions_exclude_other_prebuilts_and_reject_bad_paths() {
        let hash = "a".repeat(40);
        let list = format!(
            "external/qemu {hash}\nprebuilts/clang {hash}\n{SOURCE_ARCHIVE} {hash}\nMISSING other\n"
        );
        let result = selected_revisions(&list).unwrap();
        assert_eq!(result.len(), 2);
        assert_eq!(result[1].0, SOURCE_ARCHIVE);
        assert!(selected_revisions(&format!("../bad {hash}\n")).is_err());
        assert!(selected_revisions("external/qemu invalid\n").is_err());
    }
}
