//! Read-only listing of launchable user apps. Metadata is extracted without
//! pulling entire, potentially multi-gigabyte APKs from the guest.
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use jidr_core::provider::{CallCtx, DeviceParams};
use jidr_core::{ConnectInfo, JidrResult};
use serde_json::{Value, json};
use tokio::io::AsyncReadExt;

use crate::device::target;

const META_LIMIT: usize = 8 * 1024 * 1024;
const ICON_LIMIT: usize = 512 * 1024;

fn safe_remote_path(path: &str) -> bool {
    path.starts_with('/')
        && !path.contains("..")
        && path
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"/._-+=~".contains(&c))
}

fn safe_entry(path: &str) -> bool {
    !path.starts_with('/')
        && !path.contains("..")
        && path
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"/._-".contains(&c))
}

async fn unzip_entry(info: &ConnectInfo, path: &str, entry: &str, limit: usize) -> Option<Vec<u8>> {
    if !safe_remote_path(path) || !safe_entry(entry) {
        return None;
    }
    let mut child = tokio::process::Command::new(&info.adb_path)
        .args([
            "-s",
            &info.adb_serial,
            "exec-out",
            "unzip",
            "-p",
            path,
            entry,
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .ok()?;
    let stdout = child.stdout.take()?;
    let mut bytes = Vec::new();
    let read = tokio::time::timeout(
        Duration::from_secs(15),
        stdout.take((limit + 1) as u64).read_to_end(&mut bytes),
    )
    .await
    .ok()?
    .ok()?;
    if read > limit {
        let _ = child.kill().await;
        return None;
    }
    let status = tokio::time::timeout(Duration::from_secs(5), child.wait())
        .await
        .ok()?
        .ok()?;
    (status.success() && !bytes.is_empty()).then_some(bytes)
}

fn find_aapt_root(sdk: &Path) -> Option<PathBuf> {
    let root = sdk.join("build-tools");
    let mut versions: Vec<_> = std::fs::read_dir(root)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .collect();
    versions.sort_by_cached_key(|path| {
        path.file_name()
            .and_then(|v| v.to_str())
            .unwrap_or_default()
            .split('.')
            .map(|part| part.parse::<u32>().unwrap_or(0))
            .collect::<Vec<_>>()
    });
    versions
        .into_iter()
        .rev()
        .map(|p| p.join("aapt"))
        .find(|p| p.is_file())
}

fn find_aapt(adb: &Path) -> Option<PathBuf> {
    find_aapt_root(adb.parent()?.parent()?)
}

fn metadata_apk(manifest: &[u8], resources: &[u8]) -> Option<tempfile::NamedTempFile> {
    let file = tempfile::Builder::new().suffix(".apk").tempfile().ok()?;
    let mut zip = zip::ZipWriter::new(file.reopen().ok()?);
    let opts = zip::write::SimpleFileOptions::default();
    zip.start_file("AndroidManifest.xml", opts).ok()?;
    zip.write_all(manifest).ok()?;
    zip.start_file("resources.arsc", opts).ok()?;
    zip.write_all(resources).ok()?;
    zip.finish().ok()?;
    Some(file)
}

fn badging_value<'a>(output: &'a str, prefix: &str) -> Option<&'a str> {
    output
        .lines()
        .find_map(|line| {
            line.strip_prefix(prefix)?
                .strip_prefix('\'')?
                .split('\'')
                .next()
        })
        .filter(|s| !s.is_empty())
}

async fn metadata(
    info: &ConnectInfo,
    path: &str,
    aapt: &Path,
    cache: &Path,
    package: &str,
) -> Option<(String, Option<String>)> {
    let manifest = unzip_entry(info, path, "AndroidManifest.xml", META_LIMIT).await?;
    let resources = unzip_entry(info, path, "resources.arsc", META_LIMIT).await?;
    let archive = metadata_apk(&manifest, &resources)?;
    let output = tokio::time::timeout(
        Duration::from_secs(15),
        tokio::process::Command::new(aapt)
            .args(["dump", "badging"])
            .arg(archive.path())
            .kill_on_drop(true)
            .output(),
    )
    .await
    .ok()?
    .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8(output.stdout).ok()?;
    let label = badging_value(&text, "application-label:")?.to_string();
    let icon = text
        .lines()
        .filter_map(|line| {
            line.split_once(":'")
                .filter(|(k, _)| k.starts_with("application-icon-"))
                .and_then(|(_, v)| v.split('\'').next())
        })
        .rfind(|v| v.ends_with(".png") && safe_entry(v));
    let icon_path = if let Some(icon) = icon {
        if let Some(bytes) = unzip_entry(info, path, icon, ICON_LIMIT).await {
            if bytes.starts_with(b"\x89PNG\r\n\x1a\n") && std::fs::create_dir_all(cache).is_ok() {
                let target = cache.join(format!("{package}.png"));
                let temp = cache.join(format!(".{}.tmp", uuid::Uuid::new_v4()));
                if std::fs::write(&temp, bytes)
                    .and_then(|()| std::fs::rename(&temp, &target))
                    .is_ok()
                {
                    Some(target.to_string_lossy().into_owned())
                } else {
                    let _ = std::fs::remove_file(temp);
                    None
                }
            } else {
                None
            }
        } else {
            None
        }
    } else {
        None
    };
    Some((label, icon_path))
}

fn launchable_packages(packages: &str, launchers: &str) -> Vec<String> {
    let launchable: std::collections::HashSet<_> = launchers
        .lines()
        .filter_map(|line| line.trim().split_once('/').map(|(pkg, _)| pkg))
        .collect();
    let mut seen = std::collections::HashSet::new();
    packages
        .lines()
        .filter_map(|line| line.trim().strip_prefix("package:"))
        .filter(|package| {
            crate::apps::check_package(package).is_ok()
                && launchable.contains(package)
                && seen.insert(*package)
        })
        .map(str::to_owned)
        .collect()
}

pub async fn list(ctx: &CallCtx, p: DeviceParams) -> JidrResult<Value> {
    let t = target(ctx, &p.device).await?;
    let adb = t.adb();
    let packages = adb.shell("pm list packages -3").await?;
    let launchers = adb.shell("cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER").await?;
    let aapt = find_aapt(&t.info.adb_path)
        .or_else(|| {
            jidr_core::tool_paths::ToolPaths::load(ctx.daemon.paths())
                .ok()
                .and_then(|p| p.android_sdk)
                .and_then(|sdk| find_aapt_root(&sdk))
        })
        .or_else(|| find_aapt_root(&t.device.sdk_root));
    let cache = ctx
        .daemon
        .paths()
        .cache
        .join("game-icons")
        .join(t.device.id.to_string());
    let mut apps = Vec::new();
    let mut incomplete_metadata = false;
    for package in launchable_packages(&packages, &launchers) {
        ctx.cancel.check()?;
        let paths = adb
            .shell(&format!("pm path {package}"))
            .await
            .unwrap_or_default();
        let apk = paths
            .lines()
            .filter_map(|line| line.trim().strip_prefix("package:"))
            .find(|path| path.ends_with("/base.apk") && safe_remote_path(path));
        let data = if let (Some(aapt), Some(apk)) = (&aapt, apk) {
            metadata(&t.info, apk, aapt, &cache, &package).await
        } else {
            None
        };
        let (label, icon) = data.unwrap_or_else(|| (package.to_string(), None));
        incomplete_metadata |= icon.is_none() || label == package;
        apps.push(json!({"package": package, "name": label, "icon": icon}));
    }
    apps.sort_by_key(|entry| entry["name"].as_str().unwrap_or_default().to_lowercase());
    Ok(
        json!({"device": t.device.id, "apps": apps, "metadata_available": aapt.is_some(), "incomplete_metadata": incomplete_metadata}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn remote_paths_and_badging_are_restricted() {
        assert!(safe_remote_path("/data/app/~~abc==/com.test-123/base.apk"));
        assert!(!safe_remote_path("/data/app/a;touch/x"));
        assert!(!safe_entry("../../data"));
        assert_eq!(
            badging_value("application-label:'游戏'\n", "application-label:"),
            Some("游戏")
        );
    }

    #[test]
    fn lists_only_distinct_launchable_third_party_packages() {
        assert_eq!(
            launchable_packages(
                "package:com.game.one\npackage:com.game.one\npackage:com.tool.hidden\npackage:bad;rm\n",
                "com.game.one/.Main\ncom.android.settings/.Settings\nbad;rm/.Main\n"
            ),
            ["com.game.one"]
        );
    }

    #[tokio::test]
    #[ignore = "requires a running Android device and JIDR_TEST_APP_PACKAGE"]
    async fn installed_app_metadata_can_be_read_without_copying_the_apk() {
        let package = std::env::var("JIDR_TEST_APP_PACKAGE").unwrap();
        let serial = std::env::var("JIDR_TEST_SERIAL").unwrap();
        let adb_path = PathBuf::from(std::env::var("JIDR_TEST_ADB").unwrap());
        let adb = jidr_adb::Adb::new(adb_path.clone()).device(serial.clone());
        let paths = adb.shell(&format!("pm path {package}")).await.unwrap();
        let path = paths
            .lines()
            .find_map(|line| line.strip_prefix("package:"))
            .unwrap();
        let info = ConnectInfo {
            device: uuid::Uuid::nil(),
            grpc_endpoint: String::new(),
            grpc_port: 0,
            grpc_token: String::new(),
            adb_serial: serial,
            adb_path: adb_path.clone(),
            console_port: 0,
        };
        let cache = tempfile::tempdir().unwrap();
        let (label, icon) = metadata(
            &info,
            path,
            &find_aapt(&adb_path).unwrap(),
            cache.path(),
            &package,
        )
        .await
        .unwrap();
        assert!(!label.is_empty());
        assert!(icon.is_some_and(|path| Path::new(&path).is_file()));
    }
}
