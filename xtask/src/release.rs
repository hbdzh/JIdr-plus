//! `cargo xtask release`: build the sole SwiftUI/AppKit GUI, Rust helpers,
//! Jidr.app, the arm64 DMG, MCP bundle and checksums.
//!
//! `--rehearsal` signs ad-hoc, scans and verifies an isolated install, and
//! writes evidence without publishing or touching real user data. Developer ID
//! signing/notarization remain explicitly unverified until wired for all helpers.

use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime};

use anyhow::{Context, Result, bail};
use serde_json::Value;

use crate::{cargo, workspace_root};

const USAGE: &str = "\
usage: cargo xtask release [--dry-run] [--scan] [--out <dir>] [--rehearsal]

  --dry-run    build and package locally; never sign, even if secrets exist
  --scan       fail if the artifacts contain Google SDK binaries, system images or Magisk
  --out DIR    output directory (default: <target>/release-artifacts; with
               --rehearsal: <target>/release-rehearsal)
  --rehearsal  local rehearsal of the SwiftUI release chain: implies --scan,
               signs ad-hoc only, runs the mount/signature/scan/CLI/
               isolated-launch/uninstall checks and writes report.md;
               nothing is published";

/// Env var with the Developer ID identity, e.g.
/// `Developer ID Application: Name (TEAMID)` (Phase 12b).
const SIGNING_IDENTITY_ENV: &str = "JIDR_SIGNING_IDENTITY";

#[derive(Debug, Default, PartialEq)]
struct Options {
    dry_run: bool,
    scan: bool,
    out: Option<PathBuf>,
    rehearsal: bool,
    help: bool,
}

fn parse_args(args: &[String]) -> Result<Options> {
    let mut opts = Options::default();
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--dry-run" => opts.dry_run = true,
            "--scan" => opts.scan = true,
            "--out" => {
                let dir = it.next().context("--out needs a directory")?;
                opts.out = Some(PathBuf::from(dir));
            }
            "--rehearsal" => opts.rehearsal = true,
            "-h" | "--help" => opts.help = true,
            other => bail!("unknown argument `{other}`\n{USAGE}"),
        }
    }
    Ok(opts)
}

pub fn run(args: &[String]) -> Result<()> {
    let mut opts = parse_args(args)?;
    if opts.help {
        println!("{USAGE}");
        return Ok(());
    }
    if !cfg!(target_os = "macos") {
        bail!("release builds the macOS app and DMG; run it on macOS (D15)");
    }
    if opts.rehearsal {
        opts.scan = true;
    }
    let root = workspace_root();
    let version = workspace_version()?;
    let target = target_dir(&root);
    let out = output_dir(&root, &target, &opts);
    println!("xtask: release {version} → {}", out.display());
    println!("xtask: GUI: SwiftUI device center");
    if opts.rehearsal {
        println!(
            "xtask: rehearsal: implies --scan, signs ad-hoc only, writes only under the output directory and publishes nothing"
        );
    }
    run_swiftui(&root, &target, &out, &version, &opts)
}

/// The SwiftUI release path (`cargo xtask release`), and its local rehearsal.
fn run_swiftui(
    root: &Path,
    target: &Path,
    out: &Path,
    version: &str,
    opts: &Options,
) -> Result<()> {
    let bin = target.join("release");
    crate::run(
        &cargo(),
        &[
            "build",
            "--release",
            "--locked",
            "-p",
            "jidr",
            "-p",
            "jidr-swiftui-bridge",
        ],
    )?;
    for helper in ["jidr", "jidr-center-bridge", "jidr-swiftui-bridge"] {
        let path = bin.join(helper);
        if !path.is_file() {
            bail!("cargo build did not produce {}", path.display());
        }
    }
    println!("xtask: building the SwiftUI center with `swiftc -O`");
    crate::run(
        "bash",
        &[&path_str(&root.join("apps/jidr-swiftui/build-release.sh"))?],
    )?;
    let center = target.join("swiftui-center-release/Jidr");
    if !center.is_file() {
        bail!(
            "apps/jidr-swiftui/build-release.sh did not produce {}",
            center.display()
        );
    }

    if out.exists() {
        std::fs::remove_dir_all(out).with_context(|| format!("clearing {}", out.display()))?;
    }
    let staging = out.join("staging");
    let app = staging.join("Jidr.app");
    assemble_swiftui_app(root, &bin, &center, &app, version)?;
    let identity = std::env::var(SIGNING_IDENTITY_ENV).ok();
    let signing = signing_mode(identity.as_deref(), opts.dry_run, opts.rehearsal);
    sign_swiftui(&app, &signing)?;

    let mcpb_name = format!("jidr-mcp-{version}-darwin-arm64.mcpb");
    let mcpb_dir = out.join("mcpb");
    pack_mcpb(
        root,
        &app.join("Contents/Helpers/jidr"),
        &mcpb_dir,
        &out.join(&mcpb_name),
        version,
    )?;
    std::os::unix::fs::symlink("/Applications", staging.join("Applications"))
        .context("linking /Applications into the DMG")?;
    let dmg_name = format!("Jidr-{version}-arm64.dmg");
    let dmg = out.join(&dmg_name);
    create_dmg(&dmg, &staging, version)?;

    let mut findings = Vec::new();
    if opts.scan {
        findings.extend(scan_tree(&app)?);
        findings.extend(scan_tree(&mcpb_dir)?);
    }
    // The mounted image is the artifact a user installs; check it there, and
    // in rehearsal also install/launch/uninstall it from an isolated home.
    let mountpoint = PathBuf::from("/tmp").join(format!("jidr-release-mnt-{}", std::process::id()));
    let evidence = verify_swiftui_dmg(&dmg, &mountpoint, version, opts.scan, opts.rehearsal)?;
    if !findings.is_empty() {
        for f in &findings {
            println!("xtask: scan: {}: {}", f.path.display(), f.reason);
        }
        bail!(
            "{} forbidden file(s) in the release artifacts (Google SDK, system images or Magisk)",
            findings.len()
        );
    }
    std::fs::remove_dir_all(&staging).ok();
    std::fs::remove_dir_all(&mcpb_dir).ok();

    let sums = tool_output("shasum", &["-a", "256", &dmg_name, &mcpb_name], out)?;
    std::fs::write(out.join("SHA256SUMS.txt"), &sums)?;
    std::fs::write(out.join("VERSION"), format!("{version}\n"))?;
    print!("{sums}");
    if opts.scan {
        println!("xtask: scan ok: no Google SDK binaries, system images or Magisk");
    }
    if opts.rehearsal {
        let artifacts = artifacts_from_sums(out, &sums)?;
        let report = out.join("report.md");
        write_rehearsal_report(out, version, &artifacts, &evidence)?;
        println!("xtask: rehearsal ok: report {}", report.display());
    } else {
        for (title, lines) in &evidence.blocks {
            println!("xtask: {title}: {} check(s) passed", lines.len());
        }
    }
    println!("xtask: release ok: {}", dmg.display());
    Ok(())
}

fn output_dir(root: &Path, target: &Path, opts: &Options) -> PathBuf {
    if let Some(out) = &opts.out {
        return if out.is_absolute() {
            out.clone()
        } else {
            root.join(out)
        };
    }
    if opts.rehearsal {
        target.join("release-rehearsal")
    } else {
        target.join("release-artifacts")
    }
}

fn create_dmg(dmg: &Path, staging: &Path, version: &str) -> Result<()> {
    let volume = format!("Jidr {version}");
    let srcfolder = path_str(staging)?;
    let dmg_path = path_str(dmg)?;
    // `hdiutil create` sometimes fails with "Resource busy" on GitHub's macOS
    // runners (v0.3.0's release did), while something briefly holds the new
    // image. It succeeds when run again.
    retry(3, Duration::from_secs(10), || {
        tool(
            "hdiutil",
            &[
                "create",
                "-volname",
                &volume,
                "-srcfolder",
                &srcfolder,
                "-fs",
                "APFS",
                "-format",
                "UDZO",
                "-ov",
                &dmg_path,
            ],
        )
    })
}

fn path_str(p: &Path) -> Result<String> {
    p.to_str()
        .map(str::to_owned)
        .with_context(|| format!("non-UTF-8 path {}", p.display()))
}

fn target_dir(root: &Path) -> PathBuf {
    match std::env::var_os("CARGO_TARGET_DIR").map(PathBuf::from) {
        Some(dir) if dir.is_absolute() => dir,
        Some(dir) => root.join(dir),
        None => root.join("target"),
    }
}

/// The version of the `jidr` package (the workspace version).
fn workspace_version() -> Result<String> {
    let out = Command::new(cargo())
        .args(["metadata", "--no-deps", "--format-version", "1"])
        .current_dir(workspace_root())
        .output()
        .context("running cargo metadata")?;
    if !out.status.success() {
        bail!("cargo metadata failed");
    }
    let meta: serde_json::Value = serde_json::from_slice(&out.stdout)?;
    meta["packages"]
        .as_array()
        .and_then(|pkgs| pkgs.iter().find(|p| p["name"] == "jidr"))
        .and_then(|p| p["version"].as_str())
        .map(str::to_owned)
        .context("package `jidr` not found in cargo metadata")
}

fn tool(program: &str, args: &[&str]) -> Result<()> {
    crate::run(program, args)
}

/// Runs `f` up to `attempts` times, waiting `delay` between tries, and
/// returns the first success or the last error.
fn retry<T>(
    attempts: u32,
    delay: std::time::Duration,
    mut f: impl FnMut() -> Result<T>,
) -> Result<T> {
    let mut tried = 1;
    loop {
        match f() {
            Ok(v) => return Ok(v),
            Err(e) if tried >= attempts => return Err(e),
            Err(e) => {
                eprintln!("xtask: attempt {tried} of {attempts} failed ({e:#}); retrying");
                std::thread::sleep(delay);
                tried += 1;
            }
        }
    }
}

fn tool_output(program: &str, args: &[&str], dir: &Path) -> Result<String> {
    let out = Command::new(program)
        .args(args)
        .current_dir(dir)
        .output()
        .with_context(|| format!("running {program}"))?;
    if !out.status.success() {
        bail!(
            "`{program} {}` failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

fn copy(from: &Path, to: &Path) -> Result<()> {
    if let Some(dir) = to.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::copy(from, to)
        .with_context(|| format!("copying {} to {}", from.display(), to.display()))?;
    Ok(())
}

/// `Jidr.app` layout for the SwiftUI device center (ADR-0003). It keeps the
/// existing `ly.jidr.Jidr` bundle identity, puts the device center in
/// `Contents/MacOS/Jidr`, the three Rust helpers in `Contents/Helpers/`, and
/// the Workbench fonts (Geist + Noto Kufi Arabic and their OFL texts) in
/// `Contents/Resources/fonts/` for `ATSApplicationFontsPath`. The standalone
/// player app is a development/test entry and is deliberately absent.
fn assemble_swiftui_app(
    root: &Path,
    bin: &Path,
    center: &Path,
    app: &Path,
    version: &str,
) -> Result<()> {
    let contents = app.join("Contents");
    copy(center, &contents.join("MacOS/Jidr"))?;
    for helper in ["jidr", "jidr-center-bridge", "jidr-swiftui-bridge"] {
        copy(&bin.join(helper), &contents.join("Helpers").join(helper))?;
    }
    let resources = contents.join("Resources");
    copy(
        &root.join("apps/jidr-swiftui/Resources/Jidr.icns"),
        &resources.join("Jidr.icns"),
    )?;
    for (from, name) in [
        (
            "apps/jidr-swiftui/Resources/device-list-generated.png",
            "device-list.png",
        ),
        (
            "apps/jidr-swiftui/Resources/device-detail-generated.png",
            "device-detail.png",
        ),
        (
            "apps/jidr-swiftui/Resources/device-stopped.png",
            "device-stopped.png",
        ),
    ] {
        copy(&root.join(from), &resources.join(name))?;
    }
    let fonts = root.join("apps/jidr-swiftui/Resources/fonts");
    let mut font_count = 0;
    for entry in std::fs::read_dir(&fonts)
        .with_context(|| format!("reading the Workbench fonts in {}", fonts.display()))?
    {
        let entry = entry?;
        let name = entry.file_name();
        let lower = name.to_string_lossy().to_lowercase();
        let wanted =
            lower.ends_with(".ttf") || (lower.starts_with("ofl-") && lower.ends_with(".txt"));
        if !wanted {
            continue;
        }
        copy(&entry.path(), &resources.join("fonts").join(&name))?;
        if lower.ends_with(".ttf") {
            font_count += 1;
        }
    }
    if font_count != 8 {
        bail!(
            "expected 8 Workbench TTF fonts in {}, found {font_count}",
            fonts.display()
        );
    }
    for lproj in ["en", "zh-Hans"] {
        copy(
            &root.join(format!(
                "apps/jidr-swiftui/Resources/{lproj}.lproj/Localizable.strings"
            )),
            &resources.join(format!("{lproj}.lproj/Localizable.strings")),
        )?;
    }
    for (from, name) in [
        ("LICENSE-APACHE", "LICENSE-APACHE"),
        ("apps/jidr-swiftui/LICENSE-GPL", "LICENSE-GPL"),
        ("NOTICE", "NOTICE"),
    ] {
        copy(&root.join(from), &resources.join("licenses").join(name))?;
    }
    let template = std::fs::read_to_string(root.join("packaging/swiftui/Jidr-Info.plist.in"))
        .context("reading packaging/swiftui/Jidr-Info.plist.in")?;
    let plist = contents.join("Info.plist");
    std::fs::write(
        &plist,
        render_version(&template, version, "Jidr-Info.plist.in")?,
    )?;
    std::fs::write(contents.join("PkgInfo"), "APPL????")?;
    tool("plutil", &["-lint", &path_str(&plist)?])
}

/// An MCPB bundle (a zip: `manifest.json`, `server/jidr`, icon, licences)
/// for Claude Desktop and the MCP registries.
fn pack_mcpb(root: &Path, jidr: &Path, dir: &Path, mcpb: &Path, version: &str) -> Result<()> {
    copy(jidr, &dir.join("server/jidr"))?;
    for (from, name) in [
        ("assets/brand/app-icon-512.png", "icon.png"),
        ("LICENSE-APACHE", "LICENSE-APACHE"),
        ("NOTICE", "NOTICE"),
    ] {
        copy(&root.join(from), &dir.join(name))?;
    }
    let template = std::fs::read_to_string(root.join("packaging/mcp/manifest.json"))
        .context("reading packaging/mcp/manifest.json")?;
    let manifest = render_version(&template, version, "manifest.json")?;
    serde_json::from_str::<serde_json::Value>(&manifest).context("manifest.json is not JSON")?;
    std::fs::write(dir.join("manifest.json"), manifest)?;
    tool_output("zip", &["-X", "-r", "-q", &path_str(mcpb)?, "."], dir)?;
    Ok(())
}

/// Fills `@VERSION@` in a packaging template.
fn render_version(template: &str, version: &str, file: &str) -> Result<String> {
    if !template.contains("@VERSION@") {
        bail!("{file} has no @VERSION@ placeholder");
    }
    if version.is_empty()
        || !version
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-')
    {
        bail!("invalid version `{version}`");
    }
    Ok(template.replace("@VERSION@", version))
}

/// How the release is signed.
#[derive(Debug, PartialEq)]
enum Signing {
    /// Hardened runtime with the Developer ID identity, then notarization.
    DeveloperId,
    /// Ad-hoc only, with the reason shown as a warning.
    AdHoc(&'static str),
}

fn signing_mode(identity: Option<&str>, dry_run: bool, rehearsal: bool) -> Signing {
    match (identity.filter(|s| !s.is_empty()), dry_run, rehearsal) {
        (_, _, true) => Signing::AdHoc(
            "rehearsal: the app is ad-hoc signed only; Developer ID signing and notarization are NOT verified",
        ),
        (_, true, _) => Signing::AdHoc("dry run: the app is ad-hoc signed only"),
        (Some(_), false, false) => Signing::DeveloperId,
        (None, false, false) => Signing::AdHoc(
            "Apple Developer ID secrets are missing; this release is unsigned (ad-hoc). Users open it from System Settings › Privacy & Security › Open Anyway (D32)",
        ),
    }
}

fn warn_ad_hoc(message: &str) {
    if std::env::var_os("GITHUB_ACTIONS").is_some() && !message.starts_with("dry run") {
        println!("::warning::{message}");
    } else {
        println!("xtask: warning: {message}");
    }
}

/// Signs the SwiftUI app inside-out; there is no `--deep`. The Developer ID
/// path deliberately refuses for now: `packaging/macos/sign.sh` only signs
/// `Helpers/jidr`, `MacOS/Jidr` and the bundle, so a signed SwiftUI release
/// would ship two ad-hoc/unsigned bridge helpers. Extending `sign.sh` and
/// notarizing is M5b work; until then the rehearsal reports it as unverified
/// instead of claiming a passing signature.
fn sign_swiftui(app: &Path, signing: &Signing) -> Result<()> {
    match signing {
        Signing::DeveloperId => bail!(
            "SwiftUI Developer ID signing is not wired yet: packaging/macos/sign.sh signs \
             `Contents/Helpers/jidr`, `Contents/MacOS/Jidr` and the bundle, not the two bridge \
             helpers. Extend sign.sh (and then notarization) before signing a `cargo xtask release` \
             release with {SIGNING_IDENTITY_ENV}; the rehearsal uses ad-hoc signing and says so"
        ),
        Signing::AdHoc(message) => {
            warn_ad_hoc(message);
            let contents = app.join("Contents");
            let nested = vec![
                contents.join("Helpers/jidr"),
                contents.join("Helpers/jidr-center-bridge"),
                contents.join("Helpers/jidr-swiftui-bridge"),
                contents.join("MacOS/Jidr"),
            ];
            for path in &nested {
                tool(
                    "codesign",
                    &[
                        "--force",
                        "--options",
                        "runtime",
                        "--timestamp=none",
                        "--sign",
                        "-",
                        &path_str(path)?,
                    ],
                )?;
            }
            tool(
                "codesign",
                &[
                    "--force",
                    "--options",
                    "runtime",
                    "--timestamp=none",
                    "--sign",
                    "-",
                    &path_str(app)?,
                ],
            )?;
            tool("codesign", &["--verify", "--strict", &path_str(app)?])
        }
    }
}

fn path_is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .map(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

fn require_file(path: &Path, what: &str) -> Result<()> {
    if !path.is_file() {
        bail!("missing {what}: {}", path.display());
    }
    Ok(())
}

fn check_macho_arm64(path: &Path) -> Result<()> {
    let out = Command::new("file")
        .arg(path)
        .output()
        .with_context(|| format!("running file on {}", path.display()))?;
    let text = String::from_utf8_lossy(&out.stdout);
    if !text.contains("arm64") {
        bail!(
            "{} is not an arm64 Mach-O ({})",
            path.display(),
            text.trim()
        );
    }
    Ok(())
}

fn plist_json(path: &Path) -> Result<Value> {
    let out = Command::new("plutil")
        .args(["-convert", "json", "-o", "-"])
        .arg(path)
        .output()
        .with_context(|| format!("running plutil on {}", path.display()))?;
    if !out.status.success() {
        bail!(
            "plutil cannot read {}: {}",
            path.display(),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    serde_json::from_slice(&out.stdout)
        .with_context(|| format!("{} is not a JSON plist", path.display()))
}

struct Captured {
    success: bool,
    /// stdout and stderr, for error messages and human-readable verdicts.
    output: String,
    /// stdout only, for commands that print JSON.
    stdout: String,
}

fn capture_command(mut command: Command, label: &str) -> Result<Captured> {
    let out = command
        .output()
        .with_context(|| format!("running {label}"))?;
    let mut text = String::from_utf8_lossy(&out.stdout).trim_end().to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).trim_end().to_string();
    if !stderr.is_empty() {
        if !text.is_empty() {
            text.push('\n');
        }
        text.push_str(&stderr);
    }
    Ok(Captured {
        success: out.status.success(),
        output: text,
        stdout: String::from_utf8_lossy(&out.stdout).into_owned(),
    })
}

fn capture(program: &str, args: &[&str]) -> Result<Captured> {
    let mut command = Command::new(program);
    command.args(args);
    capture_command(command, program)
}

fn capture_env(
    program: &str,
    args: &[&str],
    envs: &[(&str, &Path)],
    remove: &[&str],
) -> Result<Captured> {
    let mut command = Command::new(program);
    command.args(args);
    for (key, value) in envs {
        command.env(key, value);
    }
    for key in remove {
        command.env_remove(key);
    }
    capture_command(command, program)
}

fn modified(path: &Path) -> Option<SystemTime> {
    std::fs::metadata(path)
        .ok()
        .and_then(|meta| meta.modified().ok())
}

fn count_tree(root: &Path) -> Result<(usize, usize)> {
    let mut files = 0;
    let mut directories = 0;
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        directories += 1;
        for entry in
            std::fs::read_dir(&dir).with_context(|| format!("reading {}", dir.display()))?
        {
            let entry = entry?;
            let meta = std::fs::symlink_metadata(entry.path())?;
            if meta.is_dir() {
                stack.push(entry.path());
            } else if meta.is_file() {
                files += 1;
            }
        }
    }
    Ok((files, directories))
}

fn log_tail(path: &Path) -> String {
    match std::fs::read_to_string(path) {
        Ok(text) => {
            let lines: Vec<&str> = text.lines().rev().take(15).collect();
            lines.into_iter().rev().collect::<Vec<_>>().join("\n")
        }
        Err(_) => "<no log>".to_owned(),
    }
}

/// Evidence collected by the mounted-DMG checks; rendered into `report.md`
/// during a rehearsal.
#[derive(Debug, Default)]
struct Evidence {
    blocks: Vec<(&'static str, Vec<String>)>,
    unverified: Vec<String>,
}

impl Evidence {
    fn line(&mut self, section: &'static str, text: impl Into<String>) {
        match self.blocks.last_mut() {
            Some((title, lines)) if *title == section => lines.push(text.into()),
            _ => self.blocks.push((section, vec![text.into()])),
        }
    }

    fn unverified(&mut self, text: impl Into<String>) {
        self.unverified.push(text.into());
    }
}

fn verify_swiftui_dmg(
    dmg: &Path,
    mountpoint: &Path,
    version: &str,
    scan: bool,
    rehearsal: bool,
) -> Result<Evidence> {
    std::fs::create_dir_all(mountpoint)?;
    let mut evidence = Evidence::default();
    let integrity = capture("hdiutil", &["verify", &path_str(dmg)?])?;
    if !integrity.success {
        bail!(
            "`hdiutil verify` failed for {}: {}",
            dmg.display(),
            integrity.output
        );
    }
    evidence.line(
        "DMG image",
        "- PASS `hdiutil verify` reports a valid checksum for the compressed image",
    );
    attach_dmg(dmg, mountpoint, tool)?;
    let result = (|| -> Result<()> {
        let app = mountpoint.join("Jidr.app");
        let applications = mountpoint.join("Applications");
        if std::fs::read_link(&applications).ok().as_deref() != Some(Path::new("/Applications")) {
            bail!("the mounted DMG has no /Applications symlink for drag-and-drop install");
        }
        evidence.line(
            "Bundle structure (mounted DMG)",
            "- PASS the DMG volume has the `Jidr.app` bundle and an `/Applications` symlink",
        );
        check_swiftui_bundle(&app, version, &mut evidence)?;
        check_swiftui_signature(&app, &mut evidence)?;
        check_cli_from_dmg(&app, version, &mut evidence)?;
        if scan {
            let found = scan_tree(mountpoint)?;
            if !found.is_empty() {
                for finding in &found {
                    eprintln!(
                        "xtask: scan: {}: {}",
                        finding.path.display(),
                        finding.reason
                    );
                }
                bail!(
                    "{} forbidden file(s) in the mounted DMG (Google SDK, system images or Magisk)",
                    found.len()
                );
            }
            let (files, directories) = count_tree(mountpoint)?;
            evidence.line(
                "Forbidden-content scan",
                format!(
                    "- PASS {files} files / {directories} directories: no Google SDK binary, \
                     system image or Magisk. The rules are the same `classify_name`/\
                     `classify_content` set that `cargo xtask release --scan` uses."
                ),
            );
        } else {
            evidence.line(
                "Forbidden-content scan",
                "- SKIPPED (--scan was not requested)",
            );
        }
        if rehearsal {
            rehearse_install(&app, version, &mut evidence)?;
            add_unverified(&mut evidence);
        }
        Ok(())
    })();
    let detached = tool("hdiutil", &["detach", &path_str(mountpoint)?]);
    std::fs::remove_dir(mountpoint).ok();
    result?;
    detached?;
    Ok(evidence)
}

fn check_swiftui_bundle(app: &Path, version: &str, evidence: &mut Evidence) -> Result<()> {
    let contents = app.join("Contents");
    for (relative, what) in [
        ("MacOS/Jidr", "SwiftUI device center"),
        ("Helpers/jidr", "CLI, daemon and MCP server"),
        ("Helpers/jidr-center-bridge", "center bridge"),
        ("Helpers/jidr-swiftui-bridge", "player bridge"),
    ] {
        let path = contents.join(relative);
        if !path_is_executable(&path) {
            bail!("missing or not executable in the app bundle: {relative} ({what})");
        }
        check_macho_arm64(&path)?;
        evidence.line(
            "Bundle structure (mounted DMG)",
            format!("- PASS `Contents/{relative}` present, executable, arm64 ({what})"),
        );
    }
    for (relative, why) in [
        (
            "Helpers/JidrSwiftUIPrototype.app",
            "ADR-0003: the production bundle must not ship the standalone player app",
        ),
        (
            "Resources/test-package",
            "the production bundle must not carry the M1 test-package sentinel",
        ),
    ] {
        if contents.join(relative).exists() {
            bail!("unexpected {relative} in the production bundle: {why}");
        }
    }
    evidence.line(
        "Bundle structure (mounted DMG)",
        "- PASS no `Helpers/JidrSwiftUIPrototype.app` (ADR-0003) and no M1 test-package sentinel",
    );
    let pkginfo = std::fs::read_to_string(contents.join("PkgInfo")).context("reading PkgInfo")?;
    if pkginfo.trim() != "APPL????" {
        bail!("unexpected PkgInfo content: {:?}", pkginfo.trim());
    }
    let resources = contents.join("Resources");
    let icon = resources.join("Jidr.icns");
    require_file(&icon, "the app icon")?;
    let icon_bytes = std::fs::read(&icon)?;
    if !icon_bytes.starts_with(b"icns") {
        bail!("Jidr.icns has no `icns` magic");
    }
    for name in ["device-list.png", "device-detail.png", "device-stopped.png"] {
        let path = resources.join(name);
        require_file(&path, "the center device art")?;
        if std::fs::metadata(&path)?.len() == 0 {
            bail!("{} is empty", path.display());
        }
    }
    evidence.line(
        "Bundle structure (mounted DMG)",
        "- PASS `Resources/Jidr.icns` (icns magic), `device-list.png`, `device-detail.png`, `device-stopped.png`",
    );
    let fonts = resources.join("fonts");
    let mut ttf = 0;
    let mut ofl = 0;
    for entry in
        std::fs::read_dir(&fonts).with_context(|| format!("reading {}", fonts.display()))?
    {
        let entry = entry?;
        let name = entry.file_name().to_string_lossy().to_lowercase();
        if name.ends_with(".ttf") {
            ttf += 1;
        } else if name.starts_with("ofl-") && name.ends_with(".txt") {
            ofl += 1;
        }
    }
    if ttf != 8 {
        bail!("expected 8 bundled TTF fonts in Resources/fonts, found {ttf}");
    }
    if ofl == 0 {
        bail!("Resources/fonts has no OFL licence text for the bundled fonts");
    }
    evidence.line(
        "Bundle structure (mounted DMG)",
        format!(
            "- PASS `Resources/fonts/` has 8 TTF files and {ofl} OFL licence text(s) \
             (`ATSApplicationFontsPath=fonts`)"
        ),
    );
    for (lproj, language) in [("en", "English"), ("zh-Hans", "Simplified Chinese")] {
        let table = resources.join(format!("{lproj}.lproj/Localizable.strings"));
        require_file(&table, "a localisation table")?;
        let text = std::fs::read_to_string(&table)
            .with_context(|| format!("reading {}", table.display()))?;
        if !text.contains('=') {
            bail!("{} has no key/value entries", table.display());
        }
        evidence.line(
            "Bundle structure (mounted DMG)",
            format!(
                "- PASS `Resources/{lproj}.lproj/Localizable.strings` ({language}, {} lines)",
                text.lines().count()
            ),
        );
    }
    let licences = resources.join("licenses");
    for name in ["LICENSE-APACHE", "LICENSE-GPL", "NOTICE"] {
        require_file(&licences.join(name), "a licence file")?;
    }
    let apache = std::fs::read_to_string(licences.join("LICENSE-APACHE"))?;
    if !apache.contains("Apache License") {
        bail!("Resources/licenses/LICENSE-APACHE does not look like the Apache licence");
    }
    let gpl = std::fs::read_to_string(licences.join("LICENSE-GPL"))?;
    if !gpl.contains("GNU GENERAL PUBLIC LICENSE") {
        bail!("Resources/licenses/LICENSE-GPL does not look like the GNU GPL");
    }
    evidence.line(
        "Bundle structure (mounted DMG)",
        "- PASS `Resources/licenses/` has LICENSE-APACHE, LICENSE-GPL and NOTICE",
    );

    let plist_path = contents.join("Info.plist");
    let plist = plist_json(&plist_path)?;
    let text_field = |key: &str| plist.get(key).and_then(Value::as_str).map(str::to_owned);
    let expected = [
        ("CFBundleIdentifier", "ly.jidr.Jidr"),
        ("CFBundleExecutable", "Jidr"),
        ("CFBundleIconFile", "Jidr"),
        ("CFBundleShortVersionString", version),
        ("CFBundleVersion", version),
        ("LSMinimumSystemVersion", "13.0"),
        ("ATSApplicationFontsPath", "fonts"),
    ];
    for (key, want) in expected {
        let got = text_field(key);
        if got.as_deref() != Some(want) {
            bail!("Info.plist {key} is {got:?}, expected {want:?}");
        }
    }
    if plist
        .get("NSHighResolutionCapable")
        .and_then(Value::as_bool)
        != Some(true)
    {
        bail!("Info.plist NSHighResolutionCapable is not true");
    }
    let localizations: Vec<&str> = plist
        .get("CFBundleLocalizations")
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    for language in ["en", "zh-Hans"] {
        if !localizations.contains(&language) {
            bail!("Info.plist CFBundleLocalizations is missing {language}");
        }
    }
    evidence.line(
        "Bundle structure (mounted DMG)",
        format!(
            "- PASS `Info.plist`: `ly.jidr.Jidr` {version}, LSMinimumSystemVersion 13.0, \
             NSHighResolutionCapable, ATSApplicationFontsPath=fonts, CFBundleIconFile=Jidr, \
             en + zh-Hans localisations"
        ),
    );
    Ok(())
}

fn check_swiftui_signature(app: &Path, evidence: &mut Evidence) -> Result<()> {
    let verify = capture(
        "codesign",
        &["--verify", "--strict", "--verbose=2", &path_str(app)?],
    )?;
    if !verify.success {
        bail!(
            "`codesign --verify --strict` failed on the mounted Jidr.app:\n{}",
            verify.output
        );
    }
    for relative in [
        "Helpers/jidr",
        "Helpers/jidr-center-bridge",
        "Helpers/jidr-swiftui-bridge",
        "MacOS/Jidr",
    ] {
        let path = app.join("Contents").join(relative);
        let check = capture("codesign", &["--verify", "--strict", &path_str(&path)?])?;
        if !check.success {
            bail!(
                "nested signature does not verify: {relative}\n{}",
                check.output
            );
        }
    }
    let display = capture("codesign", &["-dv", &path_str(app)?])?;
    if !display.output.contains("Signature=adhoc") || !display.output.contains("runtime") {
        bail!(
            "expected an ad-hoc hardened-runtime signature on the mounted app:\n{}",
            display.output
        );
    }
    evidence.line(
        "Signature (inside-out)",
        "- PASS order: `Helpers/jidr`, `jidr-center-bridge`, `jidr-swiftui-bridge`, \
         `MacOS/Jidr`, then `Jidr.app`; no `--deep` in the signing step",
    );
    evidence.line(
        "Signature (inside-out)",
        "- PASS `codesign --verify --strict`: valid on disk, satisfies its Designated Requirement; \
         every nested executable verifies too",
    );
    evidence.line(
        "Signature (inside-out)",
        "- PASS `codesign -dv` reports an ad-hoc hardened-runtime signature \
         (`--options runtime --timestamp=none --sign -`)",
    );
    Ok(())
}

fn check_cli_from_dmg(app: &Path, version: &str, evidence: &mut Evidence) -> Result<()> {
    let cli = app.join("Contents/Helpers/jidr");
    let mut command = Command::new(&cli);
    command
        .arg("--version")
        .env_remove("JIDR_HOME")
        .env_remove("JIDR_DAEMON_BIN");
    let captured = capture_command(command, "jidr --version from the DMG")?;
    let expected = format!("jidr {version}");
    if !captured.success || captured.output.trim() != expected {
        bail!(
            "the bundled CLI does not run from the mounted DMG (expected {expected:?}): {}",
            captured.output
        );
    }
    evidence.line(
        "CLI from the DMG",
        format!(
            "- PASS `Contents/Helpers/jidr --version` → `{expected}` (read-only mounted image)"
        ),
    );
    Ok(())
}

/// Installs the mounted app into a temporary directory, launches it with an
/// isolated `JIDR_HOME`, checks the daemon auto-start and `daemon status`,
/// verifies the real user home and `/Applications` were untouched, then runs
/// `jidr uninstall --purge` in the isolated environment. Everything is
/// best-effort cleaned up; the checks themselves are hard requirements.
fn rehearse_install(mounted_app: &Path, version: &str, evidence: &mut Evidence) -> Result<()> {
    // `/tmp` (not `temp_dir()`, which is `/var/folders/...` on macOS): the
    // daemon Unix socket path must stay below SUN_LEN, and the isolated home
    // lives under this directory.
    let root = PathBuf::from("/tmp").join(format!("jidr-release-rehearsal-{}", std::process::id()));
    let result = rehearse_install_inner(mounted_app, version, evidence, &root);
    kill_leftovers(&root).ok();
    let _ = std::fs::remove_dir_all(&root);
    result
}

fn rehearse_install_inner(
    mounted_app: &Path,
    version: &str,
    evidence: &mut Evidence,
    root: &Path,
) -> Result<()> {
    std::fs::create_dir_all(root.join("user-home"))?;
    let install_app = root.join("install/Jidr.app");
    tool(
        "ditto",
        &[&path_str(mounted_app)?, &path_str(&install_app)?],
    )?;
    let verify = capture(
        "codesign",
        &["--verify", "--strict", &path_str(&install_app)?],
    )?;
    if !verify.success {
        bail!("the ad-hoc signature does not verify after copying the app out of the DMG");
    }
    evidence.line(
        "Isolated install (rehearsal)",
        format!(
            "- PASS copied the mounted app to `{}` (an install directory independent of \
             /Applications) and the signature still verifies",
            install_app.display()
        ),
    );

    // Gatekeeper is expected to reject an ad-hoc, unnotarized build; report the
    // observed verdict instead of claiming it passed.
    let gate = capture(
        "spctl",
        &[
            "--assess",
            "--type",
            "execute",
            "--verbose=4",
            &path_str(&install_app)?,
        ],
    )?;
    let first_line = gate.output.lines().next().unwrap_or("").trim().to_owned();
    if gate.success {
        evidence.line(
            "Gatekeeper",
            format!("- ACCEPTED by `spctl --assess`: {first_line}"),
        );
    } else {
        evidence.line(
            "Gatekeeper",
            format!(
                "- EXPECTED REJECTION (`spctl --assess`, ad-hoc and not notarized): `{first_line}`"
            ),
        );
    }

    let home = root.join("jidr-home");
    let fake_home = root.join("user-home");
    std::fs::create_dir_all(&home)?;
    let real_home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute());
    let real_data = real_home
        .as_ref()
        .map(|path| path.join("Library/Application Support/Jidr"));
    let real_mcp: Vec<(String, Option<SystemTime>)> = real_home
        .as_ref()
        .map(|path| {
            [".claude.json", ".cursor/mcp.json"]
                .into_iter()
                .map(|name| (name.to_owned(), modified(&path.join(name))))
                .collect()
        })
        .unwrap_or_default();
    let before_data = real_data.as_deref().and_then(modified);
    let before_app = modified(Path::new("/Applications/Jidr.app"));

    let log_path = root.join("center.log");
    let log = std::fs::File::create(&log_path)?;
    let log_err = log.try_clone()?;
    let mut launched = LaunchedApp::spawn(&install_app, &home, &fake_home, log, log_err)?;
    let socket = home.join("data/daemon.sock");
    let started = Instant::now();
    let mut ready = false;
    for _ in 0..240 {
        // A Unix domain socket is not a regular file, so `is_file()` would
        // never become true here.
        if socket.exists() {
            ready = true;
            break;
        }
        if launched.exited()? {
            bail!(
                "the packaged center exited during startup; {}\nlog:\n{}",
                version,
                log_tail(&log_path)
            );
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    if !ready {
        bail!(
            "the isolated daemon socket {} did not appear; log:\n{}",
            socket.display(),
            log_tail(&log_path)
        );
    }
    evidence.line(
        "Isolated launch (rehearsal)",
        format!(
            "- PASS launched `Contents/MacOS/Jidr` with `JIDR_HOME={}` and no `JIDR_DAEMON_BIN`; \
             the daemon socket appeared after {:.1}s",
            home.display(),
            started.elapsed().as_secs_f64()
        ),
    );

    let ps = capture("ps", &["-axo", "pid=,command="])?;
    let helpers = install_app.join("Contents/Helpers");
    let bridge_marker = format!("{}/jidr-center-bridge", helpers.display());
    let daemon_marker = format!("{}/jidr daemon", helpers.display());
    if !ps.output.lines().any(|line| line.contains(&bridge_marker)) {
        bail!("the center bridge is not running from Contents/Helpers");
    }
    if !ps.output.lines().any(|line| line.contains(&daemon_marker)) {
        bail!("the daemon was not auto-started from Contents/Helpers/jidr");
    }
    evidence.line(
        "Isolated launch (rehearsal)",
        "- PASS both the center bridge and the daemon run from `Contents/Helpers` \
         (bundle-relative discovery, no development paths or `JIDR_DAEMON_BIN`)",
    );

    let cli = install_app.join("Contents/Helpers/jidr");
    let status = capture_env(
        &path_str(&cli)?,
        &["--json", "daemon", "status"],
        &[("JIDR_HOME", &home)],
        &["JIDR_DAEMON_BIN"],
    )?;
    if !status.success {
        bail!("`jidr --json daemon status` failed: {}", status.output);
    }
    let status_json: Value =
        serde_json::from_str(&status.stdout).context("daemon status is not JSON")?;
    if status_json.get("ok").and_then(Value::as_bool) != Some(true) {
        bail!("daemon status is not ok: {}", status.output);
    }
    let result = status_json.get("result").cloned().unwrap_or(Value::Null);
    let reported_socket = result
        .get("socket")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let reported_version = result
        .get("version")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if !reported_socket.contains(&home.display().to_string()) {
        bail!(
            "the daemon reports socket {reported_socket:?}, which is not under the isolated home"
        );
    }
    evidence.line(
        "Isolated launch (rehearsal)",
        format!(
            "- PASS bundled `jidr --json daemon status` → ok, version {reported_version}, \
             socket `{reported_socket}`"
        ),
    );

    launched.stop();
    drop(launched);
    kill_leftovers(root)?;

    let after_data = real_data.as_deref().and_then(modified);
    if before_data != after_data {
        bail!("the real ~/Library/Application Support/Jidr changed during the rehearsal");
    }
    evidence.line(
        "Isolation",
        if before_data.is_some() {
            "- PASS real `~/Library/Application Support/Jidr` untouched (mtime unchanged)"
        } else {
            "- PASS no real `~/Library/Application Support/Jidr` was created or touched"
        },
    );
    if before_app != modified(Path::new("/Applications/Jidr.app")) {
        bail!("/Applications/Jidr.app changed during the rehearsal");
    }
    evidence.line(
        "Isolation",
        if before_app.is_some() {
            "- PASS `/Applications/Jidr.app` untouched (mtime unchanged)"
        } else {
            "- PASS no `/Applications/Jidr.app` was installed or touched"
        },
    );
    let mcp_changed: Vec<&str> = real_mcp
        .iter()
        .filter(|(name, before)| {
            modified(&real_home.as_ref().map(|h| h.join(name)).unwrap_or_default()) != *before
        })
        .map(|(name, _)| name.as_str())
        .collect();
    if !mcp_changed.is_empty() {
        bail!("real MCP client config(s) changed during the rehearsal: {mcp_changed:?}");
    }
    evidence.line(
        "Isolation",
        "- PASS real `~/.claude.json` and `~/.cursor/mcp.json` untouched (the uninstall rehearsal \
         uses its own HOME)",
    );

    uninstall_rehearsal(&cli, &home, &fake_home, evidence)?;
    Ok(())
}

fn uninstall_rehearsal(
    cli: &Path,
    home: &Path,
    fake_home: &Path,
    evidence: &mut Evidence,
) -> Result<()> {
    // Seed an MCP client config in the isolated HOME: the rehearsal should
    // remove Jidr's entry, keep unrelated ones and write a backup. The real
    // MCP configs are never opened because HOME is isolated.
    let fake_config = fake_home.join(".cursor/mcp.json");
    if let Some(parent) = fake_config.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(
        &fake_config,
        r#"{"mcpServers":{"jidr":{"command":"jidr","args":["mcp"]},"keep":{"command":"other"}}}"#,
    )?;
    let captured = capture_env(
        &path_str(cli)?,
        &["--json", "uninstall", "--purge", "--yes"],
        &[("JIDR_HOME", home), ("HOME", fake_home)],
        &["JIDR_DAEMON_BIN"],
    )?;
    if !captured.success {
        bail!("`jidr uninstall --purge --yes` failed: {}", captured.output);
    }
    let json: Value = serde_json::from_str(&captured.stdout)
        .context("uninstall output is not JSON; expected --json")?;
    if json.get("ok").and_then(Value::as_bool) != Some(true) {
        bail!("uninstall did not report ok: {}", captured.output);
    }
    let report = json.get("result").cloned().unwrap_or(Value::Null);
    if report.get("purged").and_then(Value::as_bool) != Some(true) {
        bail!("uninstall did not report purged=true: {}", captured.output);
    }
    for part in ["data", "cache", "logs"] {
        let path = home.join(part);
        if path.exists() {
            bail!("uninstall --purge left {} behind", path.display());
        }
    }
    let cleaned: Value = serde_json::from_str(
        &std::fs::read_to_string(&fake_config)
            .with_context(|| format!("reading {}", fake_config.display()))?,
    )
    .with_context(|| format!("{} is not JSON after uninstall", fake_config.display()))?;
    if cleaned
        .get("mcpServers")
        .and_then(|servers| servers.get("jidr"))
        .is_some()
    {
        bail!("uninstall --purge did not remove Jidr's MCP entry from the isolated HOME");
    }
    if cleaned
        .get("mcpServers")
        .and_then(|servers| servers.get("keep"))
        .is_none()
    {
        bail!("uninstall --purge removed an unrelated MCP entry");
    }
    if !fake_home.join(".cursor/mcp.json.jidr-backup").is_file() {
        bail!("uninstall --purge did not back up the MCP config it changed");
    }
    evidence.line(
        "Uninstall (rehearsal)",
        format!(
            "- PASS `jidr --json uninstall --purge --yes` on the isolated HOME: ok, purged=true; \
             removed `{}/data`, `cache` and `logs`",
            home.display()
        ),
    );
    evidence.line(
        "Uninstall (rehearsal)",
        "- PASS removed only Jidr's seeded MCP entry from the isolated `~/.cursor/mcp.json`, kept \
         the unrelated entry and wrote the `.jidr-backup` file",
    );
    Ok(())
}

fn add_unverified(evidence: &mut Evidence) {
    evidence.unverified(
        "- **Developer ID signing, notarization and stapling: NOT VERIFIED.** No signing \
         credentials are present in this environment, so the rehearsal uses an ad-hoc \
         hardened-runtime signature and Gatekeeper rejects it as expected. `cargo xtask release` \
         deliberately refuses the Developer ID path until `packaging/macos/sign.sh` also signs \
         `Contents/Helpers/jidr-center-bridge` and `jidr-swiftui-bridge` and the DMG branch runs \
         `notarytool`; until then sign.sh + notarization stay M5b work (D32: whether to ship an \
         unnotarized build is the maintainer's decision, never assumed here).",
    );
    evidence.unverified(
        "- **Upgrade/downgrade between installs: NOT VERIFIED.** It needs a previous signed Jidr \
         installer; this rehearsal installs, launches and uninstalls one fresh build only.",
    );
    evidence.unverified(
        "- **Real-device acceptance: NOT RE-RUN here.** M4 covers the 11/11 isolated real-device \
         acceptance and the performance measurements; this rehearsal checks the package only.",
    );
}

struct LaunchedApp {
    child: std::process::Child,
    cli: PathBuf,
    home: PathBuf,
    stopped: bool,
}

impl LaunchedApp {
    fn spawn(
        app: &Path,
        home: &Path,
        fake_home: &Path,
        stdout: std::fs::File,
        stderr: std::fs::File,
    ) -> Result<Self> {
        let executable = app.join("Contents/MacOS/Jidr");
        let child = Command::new(&executable)
            .env("JIDR_HOME", home)
            .env("HOME", fake_home)
            .env_remove("JIDR_DAEMON_BIN")
            .stdout(Stdio::from(stdout))
            .stderr(Stdio::from(stderr))
            .spawn()
            .with_context(|| format!("launching {}", executable.display()))?;
        Ok(Self {
            child,
            cli: app.join("Contents/Helpers/jidr"),
            home: home.to_path_buf(),
            stopped: false,
        })
    }

    fn exited(&mut self) -> Result<bool> {
        Ok(self
            .child
            .try_wait()
            .context("checking the launched center")?
            .is_some())
    }

    fn stop(&mut self) {
        if self.stopped {
            return;
        }
        self.stopped = true;
        // The daemon is detached from the app, so stop it for this isolated
        // home first; a failure here is only best-effort cleanup.
        let _ = Command::new(&self.cli)
            .args(["--json", "daemon", "stop"])
            .env("JIDR_HOME", &self.home)
            .output();
        let pid = self.child.id().to_string();
        let _ = Command::new("kill").args(["-TERM", &pid]).status();
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            match self.child.try_wait() {
                Ok(Some(_)) => break,
                Ok(None) if Instant::now() >= deadline => {
                    let _ = self.child.kill();
                    let _ = self.child.wait();
                    break;
                }
                Ok(None) => std::thread::sleep(Duration::from_millis(100)),
                Err(_) => break,
            }
        }
    }
}

impl Drop for LaunchedApp {
    fn drop(&mut self) {
        self.stop();
    }
}

/// Kills any process whose command line still mentions the rehearsal directory
/// (the app, its bridge and the isolated daemon). Only used on the temporary
/// install directory this run created.
fn kill_leftovers(root: &Path) -> Result<()> {
    let needle = root.display().to_string();
    if needle.is_empty() {
        return Ok(());
    }
    let ps = capture("ps", &["-axo", "pid=,command="])?;
    let mut pids: Vec<String> = Vec::new();
    for line in ps.output.lines() {
        if !line.contains(&needle) {
            continue;
        }
        if let Some(pid) = line.split_whitespace().next()
            && pid.chars().all(|c| c.is_ascii_digit())
        {
            pids.push(pid.to_owned());
        }
    }
    for pid in &pids {
        let _ = capture("kill", &["-TERM", pid]);
    }
    if !pids.is_empty() {
        std::thread::sleep(Duration::from_millis(500));
    }
    for pid in &pids {
        let _ = capture("kill", &["-KILL", pid]);
    }
    Ok(())
}

#[derive(Debug)]
struct Artifact {
    name: String,
    bytes: u64,
    sha256: String,
}

fn artifacts_from_sums(out: &Path, sums: &str) -> Result<Vec<Artifact>> {
    let mut artifacts = Vec::new();
    for line in sums.lines().filter(|line| !line.trim().is_empty()) {
        let (sha, name) = line
            .split_once("  ")
            .with_context(|| format!("unexpected shasum line: {line}"))?;
        let path = out.join(name.trim());
        let bytes = std::fs::metadata(&path)
            .with_context(|| format!("reading {}", path.display()))?
            .len();
        artifacts.push(Artifact {
            name: name.trim().to_owned(),
            bytes,
            sha256: sha.to_owned(),
        });
    }
    Ok(artifacts)
}

fn write_rehearsal_report(
    out: &Path,
    version: &str,
    artifacts: &[Artifact],
    evidence: &Evidence,
) -> Result<()> {
    let mut md = String::new();
    md.push_str("# Jidr M5 release rehearsal\n\n");
    md.push_str(
        "Local rehearsal of the SwiftUI production release chain. It builds, assembles, signs \
         (ad-hoc, because no Developer ID credentials are present), packs, mounts and checks the \
         same `Jidr.app` + DMG that `cargo xtask release` would produce, then \
         installs, launches and uninstalls it with an isolated `JIDR_HOME`. It writes only under \
         the output directory and `/tmp`, and never touches `/Applications` or the user's real \
         Jidr data.\n\n",
    );
    md.push_str("- Command: `cargo xtask release --rehearsal`\n");
    md.push_str(&format!(
        "- Version: `{version}` (workspace Cargo version, rendered into `Info.plist` and checked \
         from the mounted DMG)\n"
    ));
    md.push_str(
        "- GUI: SwiftUI device center (`Contents/MacOS/Jidr`); the production bundle contains no \
         standalone player app (ADR-0003)\n",
    );
    md.push_str(&format!("- Output directory: `{}`\n\n", out.display()));
    md.push_str("## Artifacts\n\n| artifact | bytes | sha256 |\n|---|---:|---|\n");
    for artifact in artifacts {
        md.push_str(&format!(
            "| `{}` | {} | `{}` |\n",
            artifact.name, artifact.bytes, artifact.sha256
        ));
    }
    md.push('\n');
    for (title, lines) in &evidence.blocks {
        md.push_str(&format!("## {title}\n\n"));
        for line in lines {
            md.push_str(line);
            md.push('\n');
        }
        md.push('\n');
    }
    md.push_str("## Not verified in this rehearsal\n\n");
    for line in &evidence.unverified {
        md.push_str(line);
        md.push('\n');
    }
    md.push('\n');
    md.push_str("## Re-run\n\n```bash\n");
    md.push_str(
        "PATH=\"$PWD/target/tools/bin:$PATH\" PROTOC=\"$PWD/target/tools/protoc/bin/protoc\" \\\n  \
         cargo xtask release --rehearsal\n",
    );
    md.push_str("```\n\n");
    md.push_str(
        "The rehearsal needs macOS on Apple Silicon, Xcode `swiftc`, the workspace Rust toolchain, \
         `protoc` for `jidr-proto` (the command above points at the workspace copy) and the system \
         `codesign`/`hdiutil`/`plutil`/`ditto`/`shasum` tools. Expect a few minutes for the release \
         Rust helpers plus the optimised SwiftUI center.\n\n",
    );
    md.push_str("## Release notes\n\n");
    md.push_str(
        "- **GUI:** SwiftUI/AppKit is the only GUI; no toolkit selection or legacy bundle.\n",
    );
    md.push_str(
        "- **Production home:** a plain Finder launch uses the standard Jidr data directory. \
         Rehearsal launches set an isolated `JIDR_HOME`; no separate test-package policy remains.\n",
    );
    md.push_str(
        "- **Signing:** extend `packaging/macos/sign.sh` to sign and verify \
         `Contents/Helpers/jidr-center-bridge` and `jidr-swiftui-bridge` before the first \
         Developer ID SwiftUI release, then reuse its DMG notarization/staple branch. Until then \
         `cargo xtask release` refuses Developer ID signing rather than shipping an unverified bundle.\n",
    );
    md.push_str(
        "- **MCP bundle:** unchanged; it ships the same `Helpers/jidr` and stays part of the \
         SwiftUI release artifacts so the CLI/MCP distribution does not regress at the switch.\n",
    );
    std::fs::write(out.join("report.md"), md)
        .with_context(|| format!("writing {}", out.join("report.md").display()))?;
    Ok(())
}

// Newer macOS releases can reject the deprecated hdiutil attach while
// accepting the same read-only request through diskutil image.
fn attach_dmg(
    dmg: &Path,
    mountpoint: &Path,
    mut run: impl FnMut(&str, &[&str]) -> Result<()>,
) -> Result<()> {
    let mountpoint = path_str(mountpoint)?;
    let dmg = path_str(dmg)?;
    match run(
        "hdiutil",
        &[
            "attach",
            "-readonly",
            "-nobrowse",
            "-noautoopen",
            "-mountpoint",
            &mountpoint,
            &dmg,
        ],
    ) {
        Ok(()) => Ok(()),
        Err(first) => run(
            "diskutil",
            &[
                "image",
                "attach",
                "--readOnly",
                "--mountOptions",
                "nobrowse",
                "--mountPoint",
                &mountpoint,
                &dmg,
            ],
        )
        .with_context(|| format!("hdiutil attach also failed: {first}")),
    }
}

#[derive(Debug, PartialEq)]
struct Finding {
    path: PathBuf,
    reason: &'static str,
}

/// Walks `root` without following symlinks and classifies every file.
fn scan_tree(root: &Path) -> Result<Vec<Finding>> {
    let mut findings = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in
            std::fs::read_dir(&dir).with_context(|| format!("reading {}", dir.display()))?
        {
            let entry = entry?;
            let path = entry.path();
            let meta = std::fs::symlink_metadata(&path)?;
            let name = entry.file_name().to_string_lossy().to_lowercase();
            if meta.is_dir() {
                if let Some(reason) = classify_name(&name) {
                    findings.push(Finding {
                        path: path.clone(),
                        reason,
                    });
                }
                stack.push(path);
            } else if meta.is_file() {
                let reason = classify_name(&name).or_else(|| {
                    read_head(&path)
                        .ok()
                        .and_then(|head| classify_content(&head))
                });
                if let Some(reason) = reason {
                    findings.push(Finding { path, reason });
                }
            }
        }
    }
    findings.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(findings)
}

/// Enough of a file to see its magic numbers and an APK's first entries.
fn read_head(path: &Path) -> std::io::Result<Vec<u8>> {
    use std::io::Read;
    let mut head = Vec::new();
    std::fs::File::open(path)?
        .take(64 * 1024)
        .read_to_end(&mut head)?;
    Ok(head)
}

/// Forbidden by file name (lowercased).
fn classify_name(name: &str) -> Option<&'static str> {
    const SDK_TOOLS: &[&str] = &[
        "emulator",
        "emulator-check",
        "adb",
        "fastboot",
        "sdkmanager",
        "avdmanager",
        "aapt",
        "aapt2",
        "mksdcard",
    ];
    const IMAGE_WORDS: &[&str] = &[
        "system",
        "vendor",
        "ramdisk",
        "userdata",
        "boot",
        "cache",
        "encryptionkey",
        "product",
    ];
    if name.contains("magisk") {
        return Some("Magisk (GPL-3.0, downloaded at runtime, never bundled)");
    }
    if SDK_TOOLS.contains(&name) || name.starts_with("qemu-system") || name.starts_with("libqemu") {
        return Some(
            "Android SDK / emulator binary (downloaded on the user's machine, never bundled)",
        );
    }
    if name.starts_with("kernel-ranchu") || name == "kernel-qemu" {
        return Some("emulator kernel (system image component)");
    }
    if name.ends_with(".img") && IMAGE_WORDS.iter().any(|w| name.contains(w)) {
        return Some("Android system image");
    }
    if name == "source.properties" || name == "package.xml" {
        return Some("Android SDK package metadata");
    }
    None
}

/// Forbidden by content: formats that only Android payloads use. Jidr's own
/// binaries are Mach-O, so any ELF in a macOS bundle is foreign.
fn classify_content(head: &[u8]) -> Option<&'static str> {
    let starts = |magic: &[u8]| head.starts_with(magic);
    if starts(b"\x7fELF") {
        return Some("ELF binary (Android/Linux code has no place in the macOS app)");
    }
    if starts(b"ANDROID!") || starts(b"VNDRBOOT") {
        return Some("Android boot image");
    }
    if starts(&[0x3a, 0xff, 0x26, 0xed]) {
        return Some("Android sparse image");
    }
    if head.get(1080..1082) == Some(&[0x53, 0xef]) {
        return Some("ext4 filesystem image");
    }
    if starts(&[0x02, 0x21, 0x4c, 0x18]) || starts(b"070701") || starts(b"070702") {
        return Some("ramdisk (lz4-legacy or cpio)");
    }
    if starts(b"dex\n") {
        return Some("Android dex bytecode");
    }
    if starts(b"PK\x03\x04") && contains(head, b"AndroidManifest.xml") {
        return Some("Android APK");
    }
    None
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|w| w == needle)
}

#[cfg(test)]
mod tests {
    #[test]
    fn mount_falls_back_to_read_only_diskutil_when_hdiutil_fails() {
        let mut calls = Vec::new();
        let result = super::attach_dmg(
            std::path::Path::new("/tmp/test image.dmg"),
            std::path::Path::new("/tmp/test mount"),
            |program, args| {
                calls.push((
                    program.to_owned(),
                    args.iter().map(|arg| (*arg).to_owned()).collect::<Vec<_>>(),
                ));
                if program == "hdiutil" {
                    anyhow::bail!("attach denied")
                }
                Ok(())
            },
        );
        assert!(result.is_ok());
        assert_eq!(calls.len(), 2);
        assert_eq!(calls[1].0, "diskutil");
        assert!(calls[1].1.contains(&"--readOnly".to_owned()));
        assert!(calls[1].1.contains(&"/tmp/test image.dmg".to_owned()));
        assert!(calls[1].1.contains(&"/tmp/test mount".to_owned()));
    }

    #[test]
    fn signing_follows_the_identity_dry_run_and_rehearsal() {
        use super::{Signing, signing_mode};
        assert_eq!(
            signing_mode(Some("Developer ID Application: A (T)"), false, false),
            Signing::DeveloperId
        );
        assert!(
            matches!(signing_mode(Some("Developer ID Application: A (T)"), true, false), Signing::AdHoc(m) if m.starts_with("dry run"))
        );
        assert!(matches!(
            signing_mode(None, false, false),
            Signing::AdHoc(m) if m.contains("missing")
        ));
        assert!(matches!(
            signing_mode(Some(""), false, false),
            Signing::AdHoc(_)
        ));
        assert!(
            matches!(signing_mode(Some("Developer ID Application: A (T)"), false, true), Signing::AdHoc(m) if m.starts_with("rehearsal"))
        );
        assert!(matches!(
            signing_mode(None, true, true),
            Signing::AdHoc(m) if m.starts_with("rehearsal")
        ));
    }

    use super::*;

    #[test]
    fn retry_returns_the_first_success_or_the_last_error() {
        let no_wait = std::time::Duration::ZERO;
        let mut calls = 0;
        let ok = retry(3, no_wait, || {
            calls += 1;
            if calls < 3 {
                bail!("Resource busy")
            } else {
                Ok(calls)
            }
        });
        assert_eq!(ok.unwrap(), 3);

        let mut calls = 0;
        let err = retry(3, no_wait, || -> Result<()> {
            calls += 1;
            bail!("busy {calls}")
        });
        assert_eq!(calls, 3);
        assert_eq!(err.unwrap_err().to_string(), "busy 3");
    }

    #[test]
    fn parses_flags() {
        let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let o = parse_args(&args(&["--dry-run", "--scan", "--out", "dist"])).unwrap();
        assert_eq!(
            o,
            Options {
                dry_run: true,
                scan: true,
                out: Some(PathBuf::from("dist")),
                rehearsal: false,
                help: false,
            }
        );
        assert!(parse_args(&args(&["--out"])).is_err());
        assert!(parse_args(&args(&["--sign"])).is_err());
        assert!(parse_args(&args(&["-h"])).unwrap().help);
    }

    #[test]
    fn rejects_retired_gui_selection() {
        let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        for choice in ["slint", "swiftui"] {
            assert!(parse_args(&args(&["--gui", choice])).is_err());
        }
        assert!(parse_args(&args(&["--rehearsal"])).unwrap().rehearsal);
    }

    #[test]
    fn output_dir_defaults_to_artifacts_or_rehearsal() {
        let root = Path::new("/repo");
        let target = Path::new("/repo/target");
        assert_eq!(
            output_dir(root, target, &Options::default()),
            PathBuf::from("/repo/target/release-artifacts")
        );
        let rehearsal = Options {
            rehearsal: true,
            ..Options::default()
        };
        assert_eq!(
            output_dir(root, target, &rehearsal),
            PathBuf::from("/repo/target/release-rehearsal")
        );
        let relative = Options {
            out: Some(PathBuf::from("dist")),
            ..Options::default()
        };
        assert_eq!(
            output_dir(root, target, &relative),
            PathBuf::from("/repo/dist")
        );
        let absolute = Options {
            out: Some(PathBuf::from("/tmp/out")),
            ..Options::default()
        };
        assert_eq!(
            output_dir(root, target, &absolute),
            PathBuf::from("/tmp/out")
        );
        let rehearsal_out = Options {
            out: Some(PathBuf::from("/tmp/out")),
            rehearsal: true,
            ..Options::default()
        };
        assert_eq!(
            output_dir(root, target, &rehearsal_out),
            PathBuf::from("/tmp/out")
        );
    }

    #[test]
    fn forbidden_names() {
        for name in [
            "magisk.apk",
            "magiskinit",
            "libmagisk64.so",
            "emulator",
            "adb",
            "qemu-system-aarch64-headless",
            "kernel-ranchu",
            "system.img",
            "ramdisk.img",
            "userdata-qemu.img",
            "source.properties",
        ] {
            assert!(classify_name(name).is_some(), "{name}");
        }
        for name in [
            "jidr",
            "jidr.icns",
            "info.plist",
            "license-gpl",
            "notice",
            "disk.img",
        ] {
            assert_eq!(classify_name(name), None, "{name}");
        }
    }

    #[test]
    fn forbidden_content() {
        assert!(classify_content(b"\x7fELF\x02\x01\x01").is_some());
        assert!(classify_content(b"ANDROID!....").is_some());
        assert!(classify_content(&[0x3a, 0xff, 0x26, 0xed, 0, 0]).is_some());
        assert!(classify_content(&[0x02, 0x21, 0x4c, 0x18, 1, 2, 3, 4]).is_some());
        assert!(classify_content(b"070701000493e0").is_some());
        assert!(classify_content(b"dex\n035\0").is_some());
        let mut ext4 = vec![0u8; 2048];
        ext4[1080] = 0x53;
        ext4[1081] = 0xef;
        assert!(classify_content(&ext4).is_some());
        let mut apk = b"PK\x03\x04".to_vec();
        apk.extend_from_slice(b"....AndroidManifest.xml....");
        assert!(classify_content(&apk).is_some());
        // Ours: Mach-O (arm64), a plain zip, plists, text.
        assert_eq!(
            classify_content(&[0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0, 0, 1]),
            None
        );
        assert_eq!(classify_content(b"PK\x03\x04plain.txt"), None);
        assert_eq!(classify_content(b"<?xml version"), None);
        assert_eq!(classify_content(b""), None);
    }

    #[test]
    fn scan_finds_planted_payloads_and_ignores_symlinks() {
        let tmp = std::env::temp_dir().join(format!("jidr-scan-{}", std::process::id()));
        let app = tmp.join("Jidr.app/Contents");
        std::fs::create_dir_all(app.join("MacOS")).unwrap();
        std::fs::write(app.join("MacOS/Jidr"), [0xcf, 0xfa, 0xed, 0xfe]).unwrap();
        std::fs::write(app.join("Info.plist"), "<?xml").unwrap();
        assert!(scan_tree(&tmp).unwrap().is_empty());

        std::fs::create_dir_all(app.join("Resources/sdk/platform-tools")).unwrap();
        std::fs::write(app.join("Resources/sdk/platform-tools/adb"), b"x").unwrap();
        std::fs::write(app.join("Resources/payload.bin"), b"\x7fELF\x02").unwrap();
        std::os::unix::fs::symlink("/Applications", tmp.join("Applications")).unwrap();
        let found = scan_tree(&tmp).unwrap();
        std::fs::remove_dir_all(&tmp).unwrap();
        let names: Vec<_> = found
            .iter()
            .map(|f| f.path.file_name().unwrap().to_string_lossy().into_owned())
            .collect();
        // Sorted by path; the /Applications symlink is not followed or flagged.
        assert_eq!(names, ["payload.bin", "adb"]);
    }

    #[test]
    fn templates_get_the_version() {
        let p = render_version("<string>@VERSION@</string>", "0.1.0", "t").unwrap();
        assert_eq!(p, "<string>0.1.0</string>");
        assert!(render_version("<string/>", "0.1.0", "t").is_err());
        assert!(render_version("@VERSION@", "0.1.0<x>", "t").is_err());
        let manifest = include_str!("../../packaging/mcp/manifest.json");
        assert!(render_version(manifest, "0.1.0", "manifest.json").is_ok());
        // The production SwiftUI template must carry the fields the release
        // bundle is verified for.
        let template = include_str!("../../packaging/swiftui/Jidr-Info.plist.in");
        let rendered = render_version(template, "0.3.1", "Jidr-Info.plist.in").unwrap();
        for needle in [
            "ly.jidr.Jidr",
            "ATSApplicationFontsPath",
            "<string>fonts</string>",
            "LSMinimumSystemVersion",
            "NSHighResolutionCapable",
            "CFBundleIconFile",
            "<string>0.3.1</string>",
        ] {
            assert!(rendered.contains(needle), "{needle}");
        }
    }

    #[test]
    fn swiftui_release_resources_exist() {
        let root = workspace_root();
        let mut required = vec![
            "apps/jidr-swiftui/Resources/Jidr.icns".to_owned(),
            "apps/jidr-swiftui/Resources/device-list-generated.png".to_owned(),
            "apps/jidr-swiftui/Resources/device-detail-generated.png".to_owned(),
            "apps/jidr-swiftui/Resources/device-stopped.png".to_owned(),
            "apps/jidr-swiftui/Resources/en.lproj/Localizable.strings".to_owned(),
            "apps/jidr-swiftui/Resources/zh-Hans.lproj/Localizable.strings".to_owned(),
            "apps/jidr-swiftui/build-release.sh".to_owned(),
            "packaging/swiftui/Jidr-Info.plist.in".to_owned(),
            "LICENSE-APACHE".to_owned(),
            "apps/jidr-swiftui/LICENSE-GPL".to_owned(),
            "NOTICE".to_owned(),
        ];
        for path in required.drain(..) {
            assert!(
                root.join(&path).is_file(),
                "missing release resource {path}"
            );
        }
        let fonts = root.join("apps/jidr-swiftui/Resources/fonts");
        let mut ttf = 0;
        let mut ofl = 0;
        for entry in std::fs::read_dir(&fonts).unwrap() {
            let name = entry.unwrap().file_name().to_string_lossy().to_lowercase();
            if name.ends_with(".ttf") {
                ttf += 1;
            } else if name.starts_with("ofl-") && name.ends_with(".txt") {
                ofl += 1;
            }
        }
        assert_eq!(ttf, 8, "the Workbench fonts must stay bundled");
        assert!(ofl >= 1, "the OFL licence text must stay bundled");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn swiftui_release_bundles_stopped_device_art() {
        let root = workspace_root();
        let temp = std::env::temp_dir().join(format!(
            "jidr-release-art-test-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let bin = temp.join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        for helper in [
            "jidr",
            "jidr-center-bridge",
            "jidr-swiftui-bridge",
            "center",
        ] {
            std::fs::write(bin.join(helper), b"test executable").unwrap();
        }
        let app = temp.join("Jidr.app");
        assemble_swiftui_app(&root, &bin, &bin.join("center"), &app, "0.3.1").unwrap();
        assert_eq!(
            std::fs::read(app.join("Contents/Resources/device-stopped.png")).unwrap(),
            std::fs::read(root.join("apps/jidr-swiftui/Resources/device-stopped.png")).unwrap()
        );
        std::fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn native_gui_is_the_only_ui_source_and_release_entry() {
        let root = workspace_root();
        for retired in [
            "crates/jidr-ui",
            "apps/jidr-gui",
            "apps/jidr-swiftui-prototype",
            "apps/jidr-swiftui/Player/main.swift",
            "packaging/macos/Info.plist.in",
        ] {
            assert!(
                !root.join(retired).exists(),
                "retired UI source returned: {retired}"
            );
        }
        let manifest = std::fs::read_to_string(root.join("Cargo.toml")).unwrap();
        assert!(!manifest.contains("crates/jidr-ui") && !manifest.contains("apps/jidr-gui"));
        assert!(!manifest.lines().any(|line| line.starts_with("slint =")));
        let license = std::fs::read_to_string(root.join("apps/jidr-swiftui/LICENSE-GPL")).unwrap();
        assert!(license.contains("GNU GENERAL PUBLIC LICENSE"));
        let entry =
            std::fs::read_to_string(root.join("apps/jidr-swiftui/Center/main.swift")).unwrap();
        assert!(entry.contains("Contents/Helpers") && !entry.contains("test-package"));
    }

    #[test]
    fn evidence_groups_consecutive_sections() {
        let mut evidence = Evidence::default();
        evidence.line("A", "- one");
        evidence.line("A", "- two");
        evidence.line("B", "- three");
        evidence.line("A", "- four");
        assert_eq!(evidence.blocks.len(), 3);
        assert_eq!(evidence.blocks[0].1, ["- one", "- two"]);
        assert_eq!(evidence.blocks[2].1, ["- four"]);
    }
}
