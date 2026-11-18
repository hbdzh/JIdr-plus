//! The game controllers on this machine, read with `gilrs` (IOKit on
//! macOS). Other hosts are refused for now: `gilrs` needs libudev on Linux.

use std::sync::Arc;
use std::sync::atomic::AtomicBool;

use jidr_core::JidrResult;
use serde::Serialize;
use tokio::sync::mpsc;

use super::hid::PadEvent;

/// A controller connected to this machine.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Controller {
    /// Its index for `input.gamepad.connect {controller}`; stable while it
    /// stays connected.
    pub id: usize,
    pub name: String,
    /// Its USB vendor and product IDs, when the system reports them.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vendor: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub product: Option<u16>,
}

/// The controller to use: `id`, or the first one.
pub fn pick(all: &[Controller], id: Option<usize>) -> JidrResult<Controller> {
    let found = match id {
        Some(id) => all.iter().find(|c| c.id == id),
        None => all.first(),
    };
    found.cloned().ok_or_else(|| {
        jidr_core::JidrError::not_found(match (id, all.is_empty()) {
            (_, true) => "no game controller is connected to this computer".to_string(),
            (Some(id), false) => format!(
                "no game controller {id}; connected: {}",
                all.iter()
                    .map(|c| format!("{} ({})", c.id, c.name))
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
            (None, false) => String::new(),
        })
    })
}

#[cfg(target_os = "macos")]
pub use imp::{list, open};

#[cfg(not(target_os = "macos"))]
pub use unsupported::{list, open};

#[cfg(not(target_os = "macos"))]
mod unsupported {
    use super::*;

    fn refuse() -> jidr_core::JidrError {
        jidr_core::JidrError::usage("game controllers can only be forwarded from macOS for now")
    }

    pub fn list() -> JidrResult<Vec<Controller>> {
        Err(refuse())
    }

    pub fn open(
        _id: Option<usize>,
        _tx: mpsc::Sender<PadEvent>,
        _stop: Arc<AtomicBool>,
    ) -> JidrResult<Controller> {
        Err(refuse())
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use std::sync::atomic::Ordering;
    use std::time::Duration;

    use gilrs::{EventType, Gilrs};
    use jidr_core::JidrError;

    use super::super::hid::{Axis, Button};
    use super::*;

    /// How long to wait for the system to report the connected controllers.
    const SETTLE: Duration = Duration::from_millis(300);
    /// How often the reader checks its stop flag.
    const TICK: Duration = Duration::from_millis(100);

    fn start() -> JidrResult<Gilrs> {
        let mut g = Gilrs::new()
            .map_err(|e| JidrError::unexpected(format!("reading game controllers: {e}")))?;
        // Controllers arrive as events once the HID manager has run.
        while g.next_event_blocking(Some(SETTLE)).is_some() {}
        Ok(g)
    }

    fn controllers(g: &Gilrs) -> Vec<Controller> {
        g.gamepads()
            .filter(|(_, p)| p.is_connected())
            .map(|(id, p)| Controller {
                id: id.into(),
                name: p.name().to_string(),
                vendor: p.vendor_id(),
                product: p.product_id(),
            })
            .collect()
    }

    pub fn list() -> JidrResult<Vec<Controller>> {
        start().map(|g| controllers(&g))
    }

    /// Opens controller `id` (default: the first) on a reader thread that
    /// sends its events until `stop`, the receiver closing, or the
    /// controller going away.
    pub fn open(
        id: Option<usize>,
        tx: mpsc::Sender<PadEvent>,
        stop: Arc<AtomicBool>,
    ) -> JidrResult<Controller> {
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        std::thread::Builder::new()
            .name("jidr-gamepad".into())
            .spawn(move || {
                let mut g = match start() {
                    Ok(g) => g,
                    Err(e) => {
                        let _ = ready_tx.send(Err(e));
                        return;
                    }
                };
                let chosen = pick(&controllers(&g), id);
                let want = chosen.as_ref().map(|c| c.id).ok();
                let _ = ready_tx.send(chosen);
                let Some(want) = want else { return };
                while !stop.load(Ordering::Relaxed) {
                    let Some(ev) = g.next_event_blocking(Some(TICK)) else {
                        continue;
                    };
                    if usize::from(ev.id) != want {
                        continue;
                    }
                    for pe in map(ev.event) {
                        if tx.blocking_send(pe).is_err() {
                            return;
                        }
                    }
                    if ev.event == EventType::Disconnected {
                        return;
                    }
                }
            })
            .map_err(|e| JidrError::unexpected(format!("starting the controller reader: {e}")))?;
        ready_rx
            .recv()
            .map_err(|_| JidrError::unexpected("the controller reader stopped"))?
    }

    fn button(b: gilrs::Button) -> Option<Button> {
        use gilrs::Button as G;
        Some(match b {
            G::South => Button::South,
            G::East => Button::East,
            G::West => Button::West,
            G::North => Button::North,
            G::LeftTrigger => Button::LeftBumper,
            G::RightTrigger => Button::RightBumper,
            G::Select => Button::Back,
            G::Start => Button::Start,
            G::Mode => Button::Guide,
            G::LeftThumb => Button::LeftStick,
            G::RightThumb => Button::RightStick,
            G::DPadUp => Button::Up,
            G::DPadDown => Button::Down,
            G::DPadLeft => Button::Left,
            G::DPadRight => Button::Right,
            _ => return None,
        })
    }

    /// A `gilrs` event as the virtual controller's events. Analog triggers
    /// come as `ButtonChanged`; some controllers send the D-pad as axes.
    fn map(ev: EventType) -> Vec<PadEvent> {
        use gilrs::Axis as A;
        use gilrs::Button as G;
        match ev {
            EventType::ButtonChanged(G::LeftTrigger2, v, _) => {
                vec![PadEvent::Axis(Axis::LeftTrigger, v)]
            }
            EventType::ButtonChanged(G::RightTrigger2, v, _) => {
                vec![PadEvent::Axis(Axis::RightTrigger, v)]
            }
            EventType::ButtonPressed(b, _) => button(b)
                .map(|b| vec![PadEvent::Button(b, true)])
                .unwrap_or_default(),
            EventType::ButtonReleased(b, _) => button(b)
                .map(|b| vec![PadEvent::Button(b, false)])
                .unwrap_or_default(),
            EventType::AxisChanged(a, v, _) => match a {
                A::LeftStickX => vec![PadEvent::Axis(Axis::LeftX, v)],
                A::LeftStickY => vec![PadEvent::Axis(Axis::LeftY, v)],
                A::RightStickX => vec![PadEvent::Axis(Axis::RightX, v)],
                A::RightStickY => vec![PadEvent::Axis(Axis::RightY, v)],
                A::DPadX => vec![
                    PadEvent::Button(Button::Left, v < -0.5),
                    PadEvent::Button(Button::Right, v > 0.5),
                ],
                A::DPadY => vec![
                    PadEvent::Button(Button::Up, v > 0.5),
                    PadEvent::Button(Button::Down, v < -0.5),
                ],
                _ => Vec::new(),
            },
            EventType::Disconnected => vec![PadEvent::Disconnected],
            _ => Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pad(id: usize, name: &str) -> Controller {
        Controller {
            id,
            name: name.into(),
            vendor: None,
            product: None,
        }
    }

    #[test]
    fn picks_the_first_or_the_one_asked_for() {
        let all = [pad(0, "Xbox Wireless Controller"), pad(2, "DualSense")];
        assert_eq!(pick(&all, None).unwrap().id, 0);
        assert_eq!(pick(&all, Some(2)).unwrap().name, "DualSense");
        let e = pick(&all, Some(1)).unwrap_err();
        assert_eq!(e.code, jidr_core::ErrorCode::NotFound);
        assert!(
            e.message
                .contains("0 (Xbox Wireless Controller), 2 (DualSense)"),
            "{}",
            e.message
        );
        let e = pick(&[], None).unwrap_err();
        assert_eq!(
            e.message,
            "no game controller is connected to this computer"
        );
    }
}
