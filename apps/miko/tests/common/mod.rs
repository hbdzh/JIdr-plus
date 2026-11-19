//! Runs the `miko` binary against an in-process fake daemon (`TestDaemon`).
#![allow(dead_code)]

use std::path::{Path, PathBuf};

use assert_cmd::Command;
use miko_daemon::testing::TestDaemon;
use serde_json::Value;

pub struct Env {
    _tmp: tempfile::TempDir,
    rt: tokio::runtime::Runtime,
    daemon: Option<TestDaemon>,
    /// `MIKO_HOME` for the CLI.
    pub home: PathBuf,
}

impl Env {
    pub fn new() -> Self {
        let tmp = tempfile::tempdir().unwrap();
        let rt = tokio::runtime::Runtime::new().unwrap();
        let daemon = rt.block_on(TestDaemon::start(tmp.path())).unwrap();
        let home = tmp.path().join("j");
        Self {
            _tmp: tmp,
            rt,
            daemon: Some(daemon),
            home,
        }
    }

    pub fn backend(&self) -> &miko_backend::fake::FakeBackend {
        &self.daemon.as_ref().unwrap().backend
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut c = Command::cargo_bin("miko").unwrap();
        c.args(args)
            .env("MIKO_HOME", &self.home)
            // Never spawn a real daemon from tests.
            .env("MIKO_DAEMON_BIN", "/nonexistent/miko")
            .env_remove("MIKO_RESTART_STALE")
            .timeout(std::time::Duration::from_secs(60));
        c
    }

    /// Runs `miko <args>` with `stdin` piped in (`miko shell` reads it as a script).
    pub fn miko_stdin(&self, args: &[&str], stdin: &str) -> std::process::Output {
        self.command(args).write_stdin(stdin).output().unwrap()
    }

    pub fn miko(&self, args: &[&str]) -> std::process::Output {
        self.command(args).output().unwrap()
    }

    fn parse(args: &[&str], o: &std::process::Output) -> (i32, Value) {
        let stdout = String::from_utf8_lossy(&o.stdout);
        let v: Value = serde_json::from_str(stdout.lines().last().unwrap_or("null"))
            .unwrap_or_else(|e| {
                panic!(
                    "{args:?}: bad JSON {stdout:?} ({e}); stderr {}",
                    String::from_utf8_lossy(&o.stderr)
                )
            });
        assert_eq!(
            v["miko_json"],
            2,
            "{args:?}: stdout {stdout:?} stderr {}",
            String::from_utf8_lossy(&o.stderr)
        );
        (o.status.code().unwrap_or(-1), v)
    }

    /// Runs with --json; returns (exit code, envelope).
    pub fn json(&self, args: &[&str]) -> (i32, Value) {
        let mut all = vec!["--json"];
        all.extend_from_slice(args);
        Self::parse(args, &self.miko(&all))
    }

    /// Like `json`, with `HOME` pointed somewhere else.
    pub fn json_with_home(&self, args: &[&str], home: &Path) -> (i32, Value) {
        let mut all = vec!["--json"];
        all.extend_from_slice(args);
        Self::parse(
            args,
            &self.command(&all).env("HOME", home).output().unwrap(),
        )
    }

    pub fn ok(&self, args: &[&str]) -> Value {
        let (code, v) = self.json(args);
        assert_eq!(code, 0, "{args:?} → {v}");
        assert_eq!(v["ok"], true);
        v["result"].clone()
    }

    pub fn fail(&self, args: &[&str], exit: i32) -> Value {
        let (code, v) = self.json(args);
        assert_eq!(code, exit, "{args:?} → {v}");
        assert_eq!(v["ok"], false);
        assert_eq!(v["error"]["exit_code"], exit);
        v["error"].clone()
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        if let Some(d) = self.daemon.take() {
            self.rt.block_on(d.stop());
        }
    }
}
