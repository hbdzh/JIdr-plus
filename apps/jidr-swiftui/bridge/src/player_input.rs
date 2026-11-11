//! A single input owner. Cancellation leaves enough state to release every
//! potentially delivered down event, including temporary clipboard chords.
use super::{Command, panel_point};
use anyhow::{Result, bail};
use jidr_proto::{Controller, control as pb};
use serde_json::json;
use std::future::Future;
use std::sync::atomic::{AtomicU32, Ordering};
use std::time::{Duration, Instant};
use tokio::sync::{mpsc, oneshot};

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Scheduling {
    Fifo,
    Inline,
}
impl Scheduling {
    pub(crate) fn parse(value: &str) -> Option<Self> {
        match value {
            "fifo" => Some(Self::Fifo),
            "inline" => Some(Self::Inline),
            _ => None,
        }
    }
}

pub(crate) trait InputWire: Send {
    fn touch(&mut self, event: pb::TouchEvent) -> impl Future<Output = Result<()>> + Send;
    fn key(&mut self, event: pb::KeyboardEvent) -> impl Future<Output = Result<()>> + Send;
    fn set_clipboard(&mut self, text: String) -> impl Future<Output = Result<()>> + Send;
    fn subscribe_clipboard(&mut self) -> impl Future<Output = Result<()>> + Send;
    fn next_clipboard(&mut self) -> impl Future<Output = Result<Option<String>>> + Send;
    fn close_clipboard(&mut self);
}

pub(crate) struct GrpcInput {
    controller: Controller,
    clipboard: Option<tonic::Streaming<pb::ClipData>>,
    trace: bool,
}

impl GrpcInput {
    pub(crate) fn new(controller: Controller) -> Self {
        Self {
            controller,
            clipboard: None,
            trace: std::env::var("JIDR_PLAYER_INPUT_TRACE").is_ok_and(|v| v == "1"),
        }
    }
}

impl InputWire for GrpcInput {
    async fn touch(&mut self, event: pb::TouchEvent) -> Result<()> {
        traced_rpc(self.trace, "touch", self.controller.send_touch(event)).await?;
        Ok(())
    }
    async fn key(&mut self, event: pb::KeyboardEvent) -> Result<()> {
        traced_rpc(self.trace, "key", self.controller.send_key(event)).await?;
        Ok(())
    }
    async fn set_clipboard(&mut self, text: String) -> Result<()> {
        traced_rpc(
            self.trace,
            "clipboard.set",
            self.controller.set_clipboard(pb::ClipData { text }),
        )
        .await?;
        Ok(())
    }
    async fn subscribe_clipboard(&mut self) -> Result<()> {
        self.clipboard = Some(
            traced_rpc(
                self.trace,
                "clipboard.subscribe",
                self.controller.stream_clipboard(()),
            )
            .await?
            .into_inner(),
        );
        Ok(())
    }
    async fn next_clipboard(&mut self) -> Result<Option<String>> {
        match &mut self.clipboard {
            Some(stream) => Ok(traced_rpc(self.trace, "clipboard.next", stream.message())
                .await?
                .map(|clip| clip.text)),
            None => Ok(None),
        }
    }
    fn close_clipboard(&mut self) {
        self.clipboard = None;
    }
}

// Native acceptance only; disabled in normal launches and timing runs. Method
// names/timing/status are logged, never key names or clipboard contents.
async fn traced_rpc<T>(
    enabled: bool,
    method: &str,
    future: impl Future<Output = std::result::Result<T, tonic::Status>> + Send,
) -> Result<T> {
    let start = enabled.then(Instant::now);
    if enabled {
        eprintln!("JIDR_INPUT_RPC:begin:{method}");
    }
    let result = future.await;
    if let Some(start) = start {
        eprintln!(
            "JIDR_INPUT_RPC:end:{method}:{}:{}",
            start.elapsed().as_millis(),
            result.is_ok()
        );
    }
    Ok(result?)
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Held {
    Touch {
        id: i32,
        x: i32,
        y: i32,
    },
    Key {
        code_type: i32,
        code: i32,
        key: String,
    },
}

pub(crate) struct InputState<W> {
    wire: W,
    // Press order, updated in place by repeated downs/moves. Releasing in
    // reverse order keeps modifiers down until their dependent keys are up.
    held: Vec<Held>,
}

impl<W: InputWire> InputState<W> {
    pub(crate) fn new(wire: W) -> Self {
        Self {
            wire,
            held: Vec::new(),
        }
    }

    async fn touch(&mut self, id: i32, x: i32, y: i32, down: bool) -> Result<()> {
        if down {
            let entry = Held::Touch { id, x, y };
            if let Some(old) = self
                .held
                .iter_mut()
                .find(|h| matches!(h, Held::Touch { id: held, .. } if *held == id))
            {
                *old = entry;
            } else {
                self.held.push(entry);
            }
        }
        self.wire.touch(touch_event(id, x, y, down)).await?;
        if !down {
            self.held
                .retain(|h| !matches!(h, Held::Touch { id: held, .. } if *held == id));
        }
        Ok(())
    }

    async fn key(&mut self, code_type: i32, code: i32, key: String, down: bool) -> Result<()> {
        let entry = Held::Key {
            code_type,
            code,
            key: key.clone(),
        };
        if down && !self.held.contains(&entry) {
            self.held.push(entry.clone());
        }
        self.wire.key(key_event(code_type, code, key, down)).await?;
        if !down {
            self.held.retain(|h| *h != entry);
        }
        Ok(())
    }

    async fn chord(&mut self, code: i32) -> Result<()> {
        for (code, down) in [(29, true), (code, true), (code, false), (29, false)] {
            if let Err(error) = self
                .key(
                    pb::keyboard_event::KeyCodeType::Evdev as i32,
                    code,
                    String::new(),
                    down,
                )
                .await
            {
                self.release_matching(true).await;
                return Err(error);
            }
        }
        Ok(())
    }

    /// Also runs after a cancelled RPC: the remote may have applied a down
    /// even when its response never arrived. Releases use bounded attempts.
    pub(crate) async fn release(&mut self) {
        self.wire.close_clipboard();
        self.release_matching(false).await;
    }

    async fn release_matching(&mut self, evdev_only: bool) {
        // Keep entries owned until each attempt finishes: shutdown may also
        // interrupt a chord's error recovery while an up is awaiting a reply.
        while let Some(index) = self.held.iter().rposition(|h|
            !evdev_only || matches!(h, Held::Key { code_type, .. } if *code_type == pb::keyboard_event::KeyCodeType::Evdev as i32)) {
            let entry = self.held[index].clone();
            let _ = tokio::time::timeout(Duration::from_secs(1), async {
                match entry {
                    Held::Touch { id, x, y } => self.wire.touch(touch_event(id, x, y, false)).await,
                    Held::Key {
                        code_type,
                        code,
                        key,
                    } => self.wire.key(key_event(code_type, code, key, false)).await,
                }
            })
            .await;
            self.held.remove(index);
        }
    }

    pub(crate) async fn command(
        &mut self,
        command: Command,
        panel: (u32, u32),
        rotation: &AtomicU32,
    ) -> Result<()> {
        match command {
            Command::Touch { x, y, down } => {
                if let Some((x, y)) =
                    panel_point(x, y, panel.0, panel.1, rotation.load(Ordering::Relaxed))
                {
                    self.touch(1, x, y, down).await?;
                }
            }
            Command::MappedTouch { id, x, y, down } => {
                if !(3..=9).contains(&id) {
                    bail!("invalid mapped touch id");
                }
                let point = if down {
                    panel_point(x, y, panel.0, panel.1, rotation.load(Ordering::Relaxed))
                } else {
                    self.held.iter().find_map(|h| match h {
                        Held::Touch { id: held, x, y } if *held == id => Some((*x, *y)),
                        _ => None,
                    })
                };
                if let Some((x, y)) = point {
                    self.touch(id, x, y, down).await?;
                }
            }
            Command::Key { key, down } => {
                if key.len() > 64 || key.is_empty() {
                    bail!("invalid key");
                }
                self.key(pb::keyboard_event::KeyCodeType::Usb as i32, 0, key, down)
                    .await?;
            }
            Command::Text { text } | Command::Paste { text } => {
                if text.len() > 1024 * 1024 {
                    bail!("text too large");
                }
                self.wire.set_clipboard(text).await?;
                self.chord(47).await?;
            }
            Command::Copy { request_id } | Command::Cut { request_id } => {
                let result = self
                    .copy(request_id, matches!(command, Command::Cut { .. }))
                    .await;
                self.wire.close_clipboard();
                result?;
            }
            Command::SelectAll => self.chord(30).await?,
            _ => bail!("toolbar commands must be handled by the daemon"),
        }
        Ok(())
    }

    async fn copy(&mut self, request_id: u64, cut: bool) -> Result<()> {
        tokio::time::timeout(Duration::from_secs(2), self.wire.subscribe_clipboard()).await??;
        // Consume the initial snapshot before sending the chord, as before.
        let _ = tokio::time::timeout(Duration::from_secs(2), self.wire.next_clipboard()).await??;
        self.chord(if cut { 45 } else { 46 }).await?;
        if let Ok(Ok(Some(text))) =
            tokio::time::timeout(Duration::from_millis(1500), self.wire.next_clipboard()).await
        {
            eprintln!(
                "JIDR_CLIPBOARD:{}",
                json!({"request_id":request_id,"text":text})
            );
        }
        Ok(())
    }
}

fn touch_event(id: i32, x: i32, y: i32, down: bool) -> pb::TouchEvent {
    pb::TouchEvent {
        touches: vec![pb::Touch {
            x,
            y,
            identifier: id,
            pressure: if down { 100 } else { 0 },
            touch_major: if down { 5 } else { 0 },
            expiration: pb::touch::EventExpiration::NeverExpire as i32,
            ..Default::default()
        }],
        display: 0,
    }
}

fn key_event(code_type: i32, key_code: i32, key: String, down: bool) -> pb::KeyboardEvent {
    pb::KeyboardEvent {
        code_type,
        key_code,
        key,
        event_type: if down {
            pb::keyboard_event::KeyEventType::Keydown as i32
        } else {
            pb::keyboard_event::KeyEventType::Keyup as i32
        },
        ..Default::default()
    }
}

pub(crate) trait SerialInput: Send {
    fn handle(&mut self, line: String) -> impl Future<Output = ()> + Send;
    fn release(&mut self) -> impl Future<Output = ()> + Send;
}

/// Exactly one consumer; EOF drains the bounded FIFO. On a device/frame/output
/// disconnect, cancel in-flight work then release its possibly delivered downs.
pub(crate) async fn worker<H: SerialInput>(
    mut handler: H,
    mut receiver: mpsc::Receiver<String>,
    stop: oneshot::Receiver<()>,
) {
    {
        let commands = async {
            while let Some(line) = receiver.recv().await {
                handler.handle(line).await;
            }
        };
        tokio::select! { () = commands => {}, _ = stop => {} }
    }
    handler.release().await;
}

#[cfg(test)]
#[path = "player_input_tests.rs"]
mod tests;
