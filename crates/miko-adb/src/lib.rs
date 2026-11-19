//! Async wrapper around the `adb` binary: devices, shell, install, push/pull,
//! logcat, root/unroot, connect. Errors map to Miko error codes.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use miko_core::{ErrorCode, MikoError, MikoResult};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};

/// Default timeout for one adb invocation.
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(120);

/// Reuse valid UTF-8 output without copying, preserving lossy decoding on error.
fn output_text(bytes: Vec<u8>) -> String {
    String::from_utf8(bytes)
        .unwrap_or_else(|error| String::from_utf8_lossy(error.as_bytes()).into_owned())
}

#[derive(Debug, Clone)]
pub struct Adb {
    bin: PathBuf,
    serial: Option<String>,
    timeout: Duration,
}

/// Captured result of one adb run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Output {
    pub status: Option<i32>,
    pub stdout: String,
    pub stderr: String,
}

impl Output {
    pub fn success(&self) -> bool {
        self.status == Some(0)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
pub struct DeviceEntry {
    pub serial: String,
    /// `device`, `offline`, `unauthorized`, `recovery`, …
    pub state: String,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct InstallOptions {
    /// `-r`: replace an installed app.
    pub replace: bool,
    /// `-g`: grant all runtime permissions.
    pub grant_permissions: bool,
    /// `-d`: allow version downgrade.
    pub downgrade: bool,
}

/// Why an install failed, for the UI's signature-mismatch prompt.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, schemars::JsonSchema)]
pub struct InstallFailure {
    /// e.g. `INSTALL_FAILED_UPDATE_INCOMPATIBLE`.
    pub reason: String,
    /// True when uninstalling the existing app would let the install succeed.
    pub signature_mismatch: bool,
}

impl Adb {
    pub fn new(bin: impl Into<PathBuf>) -> Self {
        Self {
            bin: bin.into(),
            serial: None,
            timeout: DEFAULT_TIMEOUT,
        }
    }

    /// The same adb, targeting one device (`-s <serial>`).
    pub fn device(&self, serial: impl Into<String>) -> Self {
        Self {
            serial: Some(serial.into()),
            ..self.clone()
        }
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    pub fn serial(&self) -> Option<&str> {
        self.serial.as_deref()
    }

    pub fn bin(&self) -> &Path {
        &self.bin
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut cmd = Command::new(&self.bin);
        if let Some(s) = &self.serial {
            cmd.arg("-s").arg(s);
        }
        cmd.args(args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        cmd
    }

    /// Spawn a guest command with piped standard input, killed on drop.
    pub fn spawn_with_stdin(&self, args: &[&str]) -> MikoResult<Child> {
        self.command(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .spawn()
            .map_err(|e| MikoError::sdk(format!("cannot run adb at {}: {e}", self.bin.display())))
    }

    /// Runs adb and returns its output, whatever the exit status.
    pub async fn raw(&self, args: &[&str]) -> MikoResult<Output> {
        let child = self.command(args).spawn().map_err(|e| {
            MikoError::sdk(format!("cannot run adb at {}: {e}", self.bin.display()))
        })?;
        let out = tokio::time::timeout(self.timeout, child.wait_with_output())
            .await
            .map_err(|_| {
                MikoError::unexpected(format!(
                    "adb {} timed out after {} s",
                    args.join(" "),
                    self.timeout.as_secs()
                ))
            })?
            .map_err(|e| MikoError::unexpected(format!("adb {}: {e}", args.join(" "))))?;
        Ok(Output {
            status: out.status.code(),
            stdout: output_text(out.stdout),
            stderr: output_text(out.stderr),
        })
    }

    /// Runs adb and fails unless it exits 0.
    pub async fn run(&self, args: &[&str]) -> MikoResult<Output> {
        let out = self.raw(args).await?;
        if out.success() {
            Ok(out)
        } else {
            Err(self.classify(args, &out))
        }
    }

    /// Maps adb's error text to a Miko error code.
    fn classify(&self, args: &[&str], out: &Output) -> MikoError {
        let text = format!("{}{}", out.stderr, out.stdout);
        let msg = text.trim();
        let code = if msg.contains("not found") && msg.contains("device")
            || msg.contains("no devices/emulators found")
        {
            ErrorCode::NotFound
        } else if msg.contains("device offline") || msg.contains("device still authorizing") {
            ErrorCode::Busy
        } else {
            ErrorCode::Sdk
        };
        MikoError::new(code, format!("adb {} failed: {msg}", args.join(" ")))
            .with_data(serde_json::json!({"status": out.status, "serial": self.serial}))
    }

    pub async fn version(&self) -> MikoResult<String> {
        let out = self.run(&["version"]).await?;
        Ok(out.stdout.lines().next().unwrap_or_default().to_string())
    }

    pub async fn devices(&self) -> MikoResult<Vec<DeviceEntry>> {
        let out = self.run(&["devices"]).await?;
        Ok(parse_devices(&out.stdout))
    }

    /// Runs a shell command and returns `(exit code, stdout)`. adb's shell
    /// protocol v2 propagates the remote exit code.
    pub async fn shell_status(&self, cmd: &str) -> MikoResult<(i32, String)> {
        let out = self.raw(&["shell", cmd]).await?;
        if out.status.is_none()
            || out.stderr.contains("error: device")
            || out.stderr.contains("no devices")
        {
            return Err(self.classify(&["shell", cmd], &out));
        }
        Ok((out.status.unwrap_or(-1), out.stdout))
    }

    /// Runs a shell command; non-zero exit is an error.
    pub async fn shell(&self, cmd: &str) -> MikoResult<String> {
        let out = self.run(&["shell", cmd]).await?;
        Ok(out.stdout)
    }

    pub async fn getprop(&self, name: &str) -> MikoResult<String> {
        Ok(self
            .shell(&format!("getprop {name}"))
            .await?
            .trim()
            .to_string())
    }

    /// Installs an APK. A rejected install returns `sdk` with an
    /// [`InstallFailure`] in `data`.
    pub async fn install(&self, apk: &Path, opts: InstallOptions) -> MikoResult<()> {
        let apk_s = apk.to_string_lossy();
        let mut args = vec!["install"];
        if opts.replace {
            args.push("-r");
        }
        if opts.grant_permissions {
            args.push("-g");
        }
        if opts.downgrade {
            args.push("-d");
        }
        args.push(&apk_s);
        let out = self.raw(&args).await?;
        let text = format!("{}\n{}", out.stdout, out.stderr);
        if out.success() && text.contains("Success") {
            return Ok(());
        }
        match parse_install_failure(&text) {
            Some(f) => Err(MikoError::sdk(format!("install failed: {}", f.reason))
                .with_data(serde_json::to_value(&f).unwrap_or_default())),
            None => Err(self.classify(&args, &out)),
        }
    }

    pub async fn uninstall(&self, package: &str) -> MikoResult<()> {
        let out = self.run(&["uninstall", package]).await?;
        if out.stdout.contains("Success") {
            Ok(())
        } else {
            Err(MikoError::sdk(format!(
                "uninstall {package}: {}",
                out.stdout.trim()
            )))
        }
    }

    pub async fn push(&self, local: &Path, remote: &str) -> MikoResult<()> {
        self.run(&["push", &local.to_string_lossy(), remote])
            .await
            .map(|_| ())
    }

    /// Copy several local sources into one existing device directory.
    pub async fn push_many(
        &self,
        locals: &[PathBuf],
        remote: &str,
        newer_only: bool,
    ) -> MikoResult<()> {
        let paths: Vec<String> = locals
            .iter()
            .map(|p| p.to_string_lossy().into_owned())
            .collect();
        let mut args = vec!["push"];
        if newer_only {
            args.push("--sync");
        }
        args.extend(paths.iter().map(String::as_str));
        args.push(remote);
        self.run(&args).await.map(|_| ())
    }

    pub async fn pull(&self, remote: &str, local: &Path) -> MikoResult<()> {
        self.run(&["pull", remote, &local.to_string_lossy()])
            .await
            .map(|_| ())
    }

    /// `logcat -d` with extra filter args.
    pub async fn logcat_dump(&self, args: &[&str]) -> MikoResult<String> {
        let mut all = vec!["logcat", "-d"];
        all.extend_from_slice(args);
        Ok(self.run(&all).await?.stdout)
    }

    pub async fn logcat_clear(&self) -> MikoResult<()> {
        self.run(&["logcat", "-c"]).await.map(|_| ())
    }

    /// Follows logcat; lines arrive on the returned receiver until the child
    /// exits or the receiver is dropped (which kills the child).
    pub fn logcat_follow(&self, args: &[&str]) -> MikoResult<LogcatStream> {
        let mut all = vec!["logcat"];
        all.extend_from_slice(args);
        let mut child = self
            .command(&all)
            .spawn()
            .map_err(|e| MikoError::sdk(format!("cannot run adb logcat: {e}")))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| MikoError::unexpected("adb logcat has no stdout"))?;
        let (tx, rx) = tokio::sync::mpsc::channel(1024);
        tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                if tx.send(line).await.is_err() {
                    break;
                }
            }
        });
        Ok(LogcatStream { child, lines: rx })
    }

    /// Flushes the guest's page cache to its disks (`sync`). Run it before
    /// anything that ends the VM without a guest shutdown (the emulator's
    /// `Shutdown` VM state, a kill, a cold boot): writes Android only cached,
    /// such as a `settings put`, are otherwise lost (#79).
    pub async fn sync(&self) -> MikoResult<()> {
        self.shell("sync").await.map(drop)
    }

    /// `adb root`. Images that don't allow it ("production builds") fail
    /// with `root_failed`.
    pub async fn root(&self) -> MikoResult<()> {
        self.adbd_mode("root", "restarting adbd as root", "already running as root")
            .await
    }

    pub async fn unroot(&self) -> MikoResult<()> {
        self.adbd_mode(
            "unroot",
            "restarting adbd as non root",
            "not running as root",
        )
        .await
    }

    async fn adbd_mode(&self, verb: &str, restarted: &str, already: &str) -> MikoResult<()> {
        let out = self.raw(&[verb]).await?;
        let text = format!("{}{}", out.stdout, out.stderr);
        if text.contains(restarted) || text.contains(already) {
            return Ok(());
        }
        if text.contains("cannot run as root") || text.contains("production builds") {
            return Err(MikoError::root_failed(format!(
                "adb {verb}: {}",
                text.trim()
            )));
        }
        if out.success() {
            return Ok(());
        }
        Err(self.classify(&[verb], &out))
    }

    /// `adb connect host:port` (needed past the ~16 instances adb scans, D9).
    pub async fn connect(&self, addr: &str) -> MikoResult<()> {
        let out = self.raw(&["connect", addr]).await?;
        if out.stdout.contains("connected to") {
            Ok(())
        } else {
            Err(MikoError::sdk(format!(
                "adb connect {addr}: {}",
                out.stdout.trim()
            )))
        }
    }

    pub async fn disconnect(&self, addr: &str) -> MikoResult<()> {
        self.raw(&["disconnect", addr]).await.map(|_| ())
    }

    /// Waits until `adb -s <serial>` reports `device`.
    pub async fn wait_for_device(&self, timeout: Duration) -> MikoResult<()> {
        let serial = self
            .serial
            .clone()
            .ok_or_else(|| MikoError::usage("wait_for_device needs a serial"))?;
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let base = Adb {
                serial: None,
                ..self.clone()
            };
            if base
                .devices()
                .await?
                .iter()
                .any(|d| d.serial == serial && d.state == "device")
            {
                return Ok(());
            }
            if tokio::time::Instant::now() >= deadline {
                return Err(MikoError::boot_timeout(format!(
                    "{serial} did not come online"
                )));
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
    }
}

/// A running `adb logcat`; dropping it kills the process.
#[derive(Debug)]
pub struct LogcatStream {
    child: Child,
    pub lines: tokio::sync::mpsc::Receiver<String>,
}

impl LogcatStream {
    pub async fn stop(mut self) {
        let _ = self.child.kill().await;
    }
}

/// Quote one argument for the device shell.
pub fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

pub fn parse_devices(text: &str) -> Vec<DeviceEntry> {
    text.lines()
        .skip_while(|l| !l.starts_with("List of devices"))
        .skip(1)
        .filter_map(|l| {
            let mut parts = l.split_whitespace();
            Some(DeviceEntry {
                serial: parts.next()?.to_string(),
                state: parts.next()?.to_string(),
            })
        })
        .collect()
}

/// Extracts `Failure [REASON ...]` or `INSTALL_FAILED_…` from install output.
pub fn parse_install_failure(text: &str) -> Option<InstallFailure> {
    let reason = text
        .split(|c: char| c.is_whitespace() || c == '[' || c == ']' || c == ':')
        .find(|w| w.starts_with("INSTALL_FAILED_") || w.starts_with("INSTALL_PARSE_FAILED_"))?
        .to_string();
    let signature_mismatch = matches!(
        reason.as_str(),
        "INSTALL_FAILED_UPDATE_INCOMPATIBLE" | "INSTALL_FAILED_SHARED_USER_INCOMPATIBLE"
    );
    Some(InstallFailure {
        reason,
        signature_mismatch,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn output_decoding_matches_lossy_utf8_and_reuses_valid_storage() {
        let valid = "ADB 输出 العربية 🙂\0\r\n".repeat(4096).into_bytes();
        let pointer = valid.as_ptr();
        let expected = String::from_utf8_lossy(&valid).into_owned();
        let decoded = output_text(valid);
        assert_eq!(decoded, expected);
        assert_eq!(decoded.as_ptr(), pointer, "valid output keeps its buffer");

        for bytes in [
            Vec::new(),
            (0..=255).collect(),
            b"before\xf0\x9fafter\xff\xc0\xaf\xed\xa0\x80\r\n".to_vec(),
        ] {
            let expected = String::from_utf8_lossy(&bytes).into_owned();
            assert_eq!(output_text(bytes), expected);
        }
    }

    #[test]
    fn parses_device_list() {
        let text = "* daemon started successfully\nList of devices attached\nemulator-5554\tdevice\n127.0.0.1:5585\toffline\n\n";
        assert_eq!(
            parse_devices(text),
            vec![
                DeviceEntry {
                    serial: "emulator-5554".into(),
                    state: "device".into()
                },
                DeviceEntry {
                    serial: "127.0.0.1:5585".into(),
                    state: "offline".into()
                },
            ]
        );
        assert!(parse_devices("List of devices attached\n").is_empty());
    }

    #[test]
    fn parses_install_failures() {
        let f = parse_install_failure(
            "Performing Streamed Install\nadb: failed to install x.apk: Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: Existing package com.x signatures do not match]",
        )
        .unwrap();
        assert_eq!(f.reason, "INSTALL_FAILED_UPDATE_INCOMPATIBLE");
        assert!(f.signature_mismatch);
        let f = parse_install_failure("Failure [INSTALL_FAILED_VERSION_DOWNGRADE]").unwrap();
        assert!(!f.signature_mismatch);
        assert!(parse_install_failure("Success").is_none());
    }
}
