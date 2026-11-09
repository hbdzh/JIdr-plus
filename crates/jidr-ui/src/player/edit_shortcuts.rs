//! Explicit text-editing shortcuts for a game window. Clipboard contents are
//! transferred only in response to the user's copy, cut or paste action.

use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use jidr_proto::{Controller, control as pb};
use tokio::io::AsyncWriteExt;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Shortcut {
    SelectAll,
    Copy,
    Cut,
    Paste,
    Undo,
    Redo,
}

impl Shortcut {
    pub fn parse(text: &str, shift: bool) -> Option<Self> {
        match (text.to_ascii_lowercase().as_str(), shift) {
            ("a", false) => Some(Self::SelectAll),
            ("c", false) => Some(Self::Copy),
            ("x", false) => Some(Self::Cut),
            ("v", false) => Some(Self::Paste),
            ("z", false) => Some(Self::Undo),
            ("z", true) | ("y", false) => Some(Self::Redo),
            _ => None,
        }
    }

    /// Android physical-key shortcuts use Linux evdev codes.
    fn key(self) -> (i32, bool) {
        match self {
            Self::SelectAll => (30, false),
            Self::Copy => (46, false),
            Self::Cut => (45, false),
            Self::Paste => (47, false),
            Self::Undo => (44, false),
            Self::Redo => (44, true),
        }
    }
}

fn event(code: i32, down: bool) -> pb::KeyboardEvent {
    pb::KeyboardEvent {
        code_type: pb::keyboard_event::KeyCodeType::Evdev as i32,
        event_type: if down {
            pb::keyboard_event::KeyEventType::Keydown as i32
        } else {
            pb::keyboard_event::KeyEventType::Keyup as i32
        },
        key_code: code,
        ..Default::default()
    }
}

fn chord(shortcut: Shortcut) -> Vec<pb::KeyboardEvent> {
    let (key, shift) = shortcut.key();
    let mut events = vec![event(29, true)]; // Ctrl
    if shift {
        events.push(event(42, true));
    } // Shift
    events.push(event(key, true));
    events.push(event(key, false));
    if shift {
        events.push(event(42, false));
    }
    events.push(event(29, false));
    events
}

async fn send_chord(ctl: &mut Controller, shortcut: Shortcut) -> Result<(), String> {
    let events = chord(shortcut);
    for ev in events {
        if let Err(e) = ctl.send_key(ev).await {
            // Do not leave modifiers held if a call fails partway through.
            let _ = ctl.send_key(event(42, false)).await;
            let _ = ctl.send_key(event(29, false)).await;
            return Err(format!("Keyboard shortcut failed: {e}"));
        }
    }
    Ok(())
}

pub(super) async fn host_clipboard() -> Result<String, String> {
    let output = tokio::process::Command::new("pbpaste")
        .output()
        .await
        .map_err(|e| format!("Can't read the Mac clipboard: {e}"))?;
    if !output.status.success() {
        return Err("Can't read the Mac clipboard".into());
    }
    String::from_utf8(output.stdout).map_err(|_| {
        crate::i18n::text("The Mac clipboard isn't text", "Mac 剪贴板内容不是文本").into()
    })
}

async fn put_host_clipboard(text: &str) -> Result<(), String> {
    let mut child = tokio::process::Command::new("pbcopy")
        .stdin(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Can't write the Mac clipboard: {e}"))?;
    let mut stdin = child.stdin.take().ok_or("Can't write the Mac clipboard")?;
    stdin
        .write_all(text.as_bytes())
        .await
        .map_err(|e| format!("Can't write the Mac clipboard: {e}"))?;
    drop(stdin);
    if !child
        .wait()
        .await
        .map_err(|e| format!("Can't write the Mac clipboard: {e}"))?
        .success()
    {
        return Err("Can't write the Mac clipboard".into());
    }
    Ok(())
}

/// The operations are kept separate from their ordering so a fake transport
/// can exercise clipboard races without reading a user's clipboard.
trait EditBackend {
    async fn read_host(&mut self) -> Result<String, String>;
    async fn write_guest(&mut self, text: String) -> Result<(), String>;
    async fn watch_guest(&mut self) -> Result<(), String>;
    async fn next_guest(&mut self) -> Result<Option<String>, String>;
    async fn write_host(&mut self, text: &str) -> Result<(), String>;
    async fn send(&mut self, shortcut: Shortcut) -> Result<(), String>;
}

struct LiveBackend {
    ctl: Controller,
    stream: Option<tonic::Streaming<pb::ClipData>>,
}

impl EditBackend for LiveBackend {
    async fn read_host(&mut self) -> Result<String, String> {
        host_clipboard().await
    }

    async fn write_guest(&mut self, text: String) -> Result<(), String> {
        self.ctl
            .set_clipboard(pb::ClipData { text })
            .await
            .map_err(|e| format!("Can't send clipboard to Android: {e}"))?;
        Ok(())
    }

    async fn watch_guest(&mut self) -> Result<(), String> {
        let response = tokio::time::timeout(Duration::from_secs(2), self.ctl.stream_clipboard(()))
            .await
            .map_err(|_| {
                crate::i18n::text(
                    "Timed out connecting to the Android clipboard",
                    "连接 Android 剪贴板超时",
                )
                .to_string()
            })?
            .map_err(|e| format!("Can't read Android clipboard: {e}"))?;
        let mut stream = response.into_inner();
        let initial = tokio::time::timeout(Duration::from_secs(2), stream.message())
            .await
            .map_err(|_| {
                crate::i18n::text(
                    "Timed out reading the Android clipboard",
                    "读取 Android 剪贴板超时",
                )
                .to_string()
            })?
            .map_err(|e| format!("Can't read Android clipboard: {e}"))?;
        if initial.is_none() {
            return Err(crate::i18n::text(
                "Android clipboard stream closed",
                "Android 剪贴板连接已关闭",
            )
            .into());
        }
        self.stream = Some(stream);
        Ok(())
    }

    async fn next_guest(&mut self) -> Result<Option<String>, String> {
        let stream = self.stream.as_mut().ok_or(crate::i18n::text(
            "Android clipboard stream is not open",
            "Android 剪贴板连接未打开",
        ))?;
        match tokio::time::timeout(Duration::from_millis(1500), stream.message()).await {
            Ok(Ok(Some(clip))) => Ok(Some(clip.text)),
            Ok(Ok(None)) => Err(crate::i18n::text(
                "Android clipboard stream closed",
                "Android 剪贴板连接已关闭",
            )
            .into()),
            Ok(Err(e)) => Err(format!("Can't read Android clipboard: {e}")),
            Err(_) => Ok(None),
        }
    }

    async fn write_host(&mut self, text: &str) -> Result<(), String> {
        put_host_clipboard(text).await
    }
    async fn send(&mut self, shortcut: Shortcut) -> Result<(), String> {
        send_chord(&mut self.ctl, shortcut).await
    }
}

async fn execute(
    io: &mut impl EditBackend,
    shortcut: Shortcut,
    alive: &AtomicBool,
) -> Result<(), String> {
    if !alive.load(Ordering::Acquire) {
        return Ok(());
    }
    match shortcut {
        Shortcut::Paste => {
            let text = io.read_host().await?;
            if text.is_empty() {
                return Err(crate::i18n::text(
                    "The Mac clipboard has no text to paste",
                    "Mac 剪贴板中没有可粘贴的文本",
                )
                .into());
            }
            if !alive.load(Ordering::Acquire) {
                return Ok(());
            }
            io.write_guest(text).await?;
            if alive.load(Ordering::Acquire) {
                io.send(shortcut).await?;
            }
        }
        Shortcut::Copy | Shortcut::Cut => {
            // The watcher consumes its initial snapshot before the chord.
            // No new guest event means no host clipboard modification.
            let host_before = io.read_host().await?;
            io.watch_guest().await?;
            if !alive.load(Ordering::Acquire) {
                return Ok(());
            }
            io.send(shortcut).await?;
            if let Some(text) = io.next_guest().await?
                && alive.load(Ordering::Acquire)
            {
                if io.read_host().await? != host_before {
                    return Err(crate::i18n::text(
                        "Mac clipboard changed; copy again",
                        "Mac 剪贴板内容已更改，请重新复制",
                    )
                    .into());
                }
                io.write_host(&text).await?;
            }
        }
        _ => io.send(shortcut).await?,
    }
    Ok(())
}

/// Send text composed by the host input method without reading or changing
/// the Mac clipboard. Android must have a focused editable field.
async fn execute_text(
    io: &mut impl EditBackend,
    text: String,
    alive: &AtomicBool,
) -> Result<(), String> {
    if text.is_empty() || !alive.load(Ordering::Acquire) {
        return Ok(());
    }
    io.write_guest(text).await?;
    if alive.load(Ordering::Acquire) {
        io.send(Shortcut::Paste).await?;
    }
    Ok(())
}

pub async fn send_text(ctl: Controller, text: String, alive: &AtomicBool) -> Result<(), String> {
    execute_text(&mut LiveBackend { ctl, stream: None }, text, alive).await
}

/// Called with the per-window operation lock held, so paste cannot overtake a
/// copy on the same device. `alive` prevents queued operations after closing.
pub async fn run(ctl: Controller, shortcut: Shortcut, alive: &AtomicBool) -> Result<(), String> {
    execute(&mut LiveBackend { ctl, stream: None }, shortcut, alive).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Fake {
        calls: Vec<String>,
        host: String,
        host_after: Option<String>,
        guest_event: Option<String>,
        watch_fails: bool,
    }

    impl EditBackend for Fake {
        async fn read_host(&mut self) -> Result<String, String> {
            let is_second = self.calls.iter().any(|call| call == "read_host");
            self.calls.push("read_host".into());
            Ok(if is_second {
                self.host_after.clone().unwrap_or_else(|| self.host.clone())
            } else {
                self.host.clone()
            })
        }
        async fn write_guest(&mut self, text: String) -> Result<(), String> {
            self.calls.push(format!("guest:{text}"));
            Ok(())
        }
        async fn watch_guest(&mut self) -> Result<(), String> {
            self.calls.push("watch".into());
            if self.watch_fails {
                Err("unavailable".into())
            } else {
                Ok(())
            }
        }
        async fn next_guest(&mut self) -> Result<Option<String>, String> {
            self.calls.push("next".into());
            Ok(self.guest_event.take())
        }
        async fn write_host(&mut self, text: &str) -> Result<(), String> {
            self.calls.push(format!("host:{text}"));
            Ok(())
        }
        async fn send(&mut self, shortcut: Shortcut) -> Result<(), String> {
            self.calls.push(format!("key:{shortcut:?}"));
            Ok(())
        }
    }

    #[test]
    fn maps_only_supported_editing_shortcuts() {
        assert_eq!(Shortcut::parse("c", false), Some(Shortcut::Copy));
        assert_eq!(Shortcut::parse("V", false), Some(Shortcut::Paste));
        assert_eq!(Shortcut::parse("Z", true), Some(Shortcut::Redo));
        assert_eq!(Shortcut::parse("z", false), Some(Shortcut::Undo));
        assert_eq!(Shortcut::parse("c", true), None);
        assert_eq!(Shortcut::parse("q", false), None);
    }

    #[test]
    fn chord_releases_every_key_in_order() {
        let keys: Vec<_> = chord(Shortcut::Redo)
            .iter()
            .map(|e| (e.key_code, e.event_type))
            .collect();
        assert_eq!(keys, [(29, 0), (42, 0), (44, 0), (44, 1), (42, 1), (29, 1)]);
        let keys: Vec<_> = chord(Shortcut::Paste)
            .iter()
            .map(|e| (e.key_code, e.event_type))
            .collect();
        assert_eq!(keys, [(29, 0), (47, 0), (47, 1), (29, 1)]);
    }

    #[tokio::test]
    async fn clipboard_operations_preserve_order_and_do_not_copy_stale_content() {
        let alive = AtomicBool::new(true);
        let mut paste = Fake {
            host: "中文 test".into(),
            ..Default::default()
        };
        execute(&mut paste, Shortcut::Paste, &alive).await.unwrap();
        assert_eq!(paste.calls, ["read_host", "guest:中文 test", "key:Paste"]);

        let mut copy = Fake {
            guest_event: Some("新内容".into()),
            ..Default::default()
        };
        execute(&mut copy, Shortcut::Copy, &alive).await.unwrap();
        assert_eq!(
            copy.calls,
            [
                "read_host",
                "watch",
                "key:Copy",
                "next",
                "read_host",
                "host:新内容"
            ]
        );

        let mut no_selection = Fake::default();
        execute(&mut no_selection, Shortcut::Cut, &alive)
            .await
            .unwrap();
        assert_eq!(
            no_selection.calls,
            ["read_host", "watch", "key:Cut", "next"]
        );

        let mut changed = Fake {
            host: "before".into(),
            host_after: Some("new Mac copy".into()),
            guest_event: Some("Android copy".into()),
            ..Default::default()
        };
        assert!(execute(&mut changed, Shortcut::Copy, &alive).await.is_err());
        assert_eq!(
            changed.calls,
            ["read_host", "watch", "key:Copy", "next", "read_host"]
        );

        let mut failed_watch = Fake {
            watch_fails: true,
            ..Default::default()
        };
        assert!(
            execute(&mut failed_watch, Shortcut::Copy, &alive)
                .await
                .is_err()
        );
        assert_eq!(failed_watch.calls, ["read_host", "watch"]);

        alive.store(false, Ordering::Release);
        let mut closed = Fake::default();
        execute(&mut closed, Shortcut::Paste, &alive).await.unwrap();
        assert!(closed.calls.is_empty());
    }

    #[tokio::test]
    async fn composed_text_never_reads_or_overwrites_host_clipboard() {
        let alive = AtomicBool::new(true);
        let mut fake = Fake::default();
        execute_text(&mut fake, "你好，世界".into(), &alive)
            .await
            .unwrap();
        assert_eq!(fake.calls, ["guest:你好，世界", "key:Paste"]);
    }
}
