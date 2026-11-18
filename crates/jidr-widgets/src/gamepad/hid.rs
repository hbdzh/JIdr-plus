//! The virtual controller the guest sees: a USB HID gamepad made with
//! AOSP's `hid` shell command (`/dev/uhid`), which `shell` may use without
//! root. It reports as an Xbox 360 controller (045e:028e), so Android loads
//! its stock `Vendor_045e_Product_028e.kl`: the kernel's generic HID driver
//! turns button `n` of a game pad into `BTN_GAMEPAD + n - 1` (`BTN_A` …
//! `BTN_THUMBR`) and X/Y/Z/Rx/Ry/Rz into `ABS_X` … `ABS_RZ`, the codes
//! that layout maps (sticks, `LTRIGGER`/`RTRIGGER`, the hat as the D-pad).

use serde_json::{Value, json};

/// USB vendor and product of an Xbox 360 controller.
pub const VENDOR: u16 = 0x045e;
pub const PRODUCT: u16 = 0x028e;

/// The HID report descriptor (USB HID 1.11 and its usage tables): 15
/// buttons, four 16-bit stick axes, two 8-bit triggers, an 8-way hat.
pub const DESCRIPTOR: [u8; 93] = [
    0x05, 0x01, // Usage Page (Generic Desktop)
    0x09, 0x05, // Usage (Game Pad)
    0xA1, 0x01, // Collection (Application)
    0x05, 0x09, //   Usage Page (Button)
    0x19, 0x01, //   Usage Minimum (1)
    0x29, 0x0F, //   Usage Maximum (15)
    0x15, 0x00, //   Logical Minimum (0)
    0x25, 0x01, //   Logical Maximum (1)
    0x75, 0x01, //   Report Size (1)
    0x95, 0x0F, //   Report Count (15)
    0x81, 0x02, //   Input (Data, Variable, Absolute)
    0x75, 0x01, //   Report Size (1)
    0x95, 0x01, //   Report Count (1)
    0x81, 0x03, //   Input (Constant): padding
    0x05, 0x01, //   Usage Page (Generic Desktop)
    0x09, 0x30, //   Usage (X)
    0x09, 0x31, //   Usage (Y)
    0x09, 0x33, //   Usage (Rx)
    0x09, 0x34, //   Usage (Ry)
    0x16, 0x00, 0x80, //   Logical Minimum (-32768)
    0x26, 0xFF, 0x7F, //   Logical Maximum (32767)
    0x75, 0x10, //   Report Size (16)
    0x95, 0x04, //   Report Count (4)
    0x81, 0x02, //   Input (Data, Variable, Absolute)
    0x09, 0x32, //   Usage (Z): left trigger
    0x09, 0x35, //   Usage (Rz): right trigger
    0x15, 0x00, //   Logical Minimum (0)
    0x26, 0xFF, 0x00, //   Logical Maximum (255)
    0x75, 0x08, //   Report Size (8)
    0x95, 0x02, //   Report Count (2)
    0x81, 0x02, //   Input (Data, Variable, Absolute)
    0x09, 0x39, //   Usage (Hat Switch)
    0x15, 0x01, //   Logical Minimum (1)
    0x25, 0x08, //   Logical Maximum (8)
    0x35, 0x00, //   Physical Minimum (0)
    0x46, 0x3B, 0x01, //   Physical Maximum (315)
    0x65, 0x14, //   Unit (degrees)
    0x75, 0x04, //   Report Size (4)
    0x95, 0x01, //   Report Count (1)
    0x81, 0x42, //   Input (Data, Variable, Absolute, Null State): 0 is centred
    0x65, 0x00, //   Unit (none)
    0x75, 0x04, //   Report Size (4)
    0x95, 0x01, //   Report Count (1)
    0x81, 0x03, //   Input (Constant): padding
    0xC0, // End Collection
];

/// The length of one input report.
pub const REPORT_LEN: usize = 13;

/// A controller button, by position (Xbox names: South is A).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Button {
    South,
    East,
    West,
    North,
    LeftBumper,
    RightBumper,
    Back,
    Start,
    Guide,
    LeftStick,
    RightStick,
    Up,
    Down,
    Left,
    Right,
}

impl Button {
    /// Its bit in the report's button field (button `bit + 1` of the
    /// descriptor); `None` for the D-pad, which is the hat.
    fn bit(self) -> Option<u16> {
        Some(match self {
            Self::South => 0,       // BTN_A
            Self::East => 1,        // BTN_B
            Self::West => 3,        // BTN_X
            Self::North => 4,       // BTN_Y
            Self::LeftBumper => 6,  // BTN_TL
            Self::RightBumper => 7, // BTN_TR
            Self::Back => 10,       // BTN_SELECT
            Self::Start => 11,      // BTN_START
            Self::Guide => 12,      // BTN_MODE
            Self::LeftStick => 13,  // BTN_THUMBL
            Self::RightStick => 14, // BTN_THUMBR
            Self::Up | Self::Down | Self::Left | Self::Right => return None,
        })
    }
}

/// A controller axis. Sticks go from -1 to 1 with up and right positive;
/// triggers from 0 (released) to 1.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Axis {
    LeftX,
    LeftY,
    RightX,
    RightY,
    LeftTrigger,
    RightTrigger,
}

/// What the host controller did.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PadEvent {
    Button(Button, bool),
    Axis(Axis, f32),
    /// The controller went away (unplugged, switched off).
    Disconnected,
}

/// The controller's whole state, as one report carries it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Pad {
    buttons: u16,
    /// Left X, left Y, right X, right Y, HID-style: down is positive.
    sticks: [i16; 4],
    triggers: [u8; 2],
    up: bool,
    down: bool,
    left: bool,
    right: bool,
}

fn stick(v: f32) -> i16 {
    (v.clamp(-1.0, 1.0) * 32767.0).round() as i16
}

fn trigger(v: f32) -> u8 {
    (v.clamp(0.0, 1.0) * 255.0).round() as u8
}

impl Pad {
    /// Applies an event; true when the report changed.
    pub fn apply(&mut self, ev: PadEvent) -> bool {
        let before = *self;
        match ev {
            PadEvent::Button(b, down) => match (b, b.bit()) {
                (_, Some(bit)) if down => self.buttons |= 1 << bit,
                (_, Some(bit)) => self.buttons &= !(1 << bit),
                (Button::Up, None) => self.up = down,
                (Button::Down, None) => self.down = down,
                (Button::Left, None) => self.left = down,
                _ => self.right = down,
            },
            PadEvent::Axis(a, v) => match a {
                Axis::LeftX => self.sticks[0] = stick(v),
                Axis::LeftY => self.sticks[1] = stick(-v),
                Axis::RightX => self.sticks[2] = stick(v),
                Axis::RightY => self.sticks[3] = stick(-v),
                Axis::LeftTrigger => self.triggers[0] = trigger(v),
                Axis::RightTrigger => self.triggers[1] = trigger(v),
            },
            PadEvent::Disconnected => {}
        }
        *self != before
    }

    /// The hat: 0 centred, 1 up, then clockwise in 45° steps to 8 up-left.
    /// Opposite directions held together cancel out.
    fn hat(&self) -> u8 {
        let y = i8::from(self.down) - i8::from(self.up);
        let x = i8::from(self.right) - i8::from(self.left);
        match (x, y) {
            (0, -1) => 1,
            (1, -1) => 2,
            (1, 0) => 3,
            (1, 1) => 4,
            (0, 1) => 5,
            (-1, 1) => 6,
            (-1, 0) => 7,
            (-1, -1) => 8,
            _ => 0,
        }
    }

    /// The input report, in the descriptor's layout (little-endian).
    pub fn report(&self) -> [u8; REPORT_LEN] {
        let mut r = [0u8; REPORT_LEN];
        r[..2].copy_from_slice(&self.buttons.to_le_bytes());
        for (i, s) in self.sticks.iter().enumerate() {
            r[2 + 2 * i..4 + 2 * i].copy_from_slice(&s.to_le_bytes());
        }
        r[10] = self.triggers[0];
        r[11] = self.triggers[1];
        r[12] = self.hat();
        r
    }
}

/// The `hid` command's line that creates the device.
pub fn register_line(name: &str) -> Value {
    json!({
        "id": 1,
        "command": "register",
        "name": name,
        "vid": VENDOR,
        "pid": PRODUCT,
        "bus": "usb",
        "descriptor": DESCRIPTOR.as_slice(),
    })
}

/// The `hid` command's line that sends one input report.
pub fn report_line(pad: &Pad) -> Value {
    json!({ "id": 1, "command": "report", "report": pad.report() })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Walks the descriptor's short items and adds up the input bits.
    fn input_bits(d: &[u8]) -> u32 {
        let (mut i, mut size, mut count, mut bits) = (0, 0u32, 0u32, 0u32);
        while i < d.len() {
            let prefix = d[i];
            let len = match prefix & 0x03 {
                3 => 4,
                n => usize::from(n),
            };
            let data = d[i + 1..i + 1 + len]
                .iter()
                .rev()
                .fold(0u32, |a, b| (a << 8) | u32::from(*b));
            match prefix & 0xFC {
                0x74 => size = data,
                0x94 => count = data,
                0x80 => bits += size * count,
                _ => {}
            }
            i += 1 + len;
        }
        bits
    }

    #[test]
    fn descriptor_matches_the_report() {
        assert_eq!(input_bits(&DESCRIPTOR), REPORT_LEN as u32 * 8);
        assert_eq!(DESCRIPTOR.first(), Some(&0x05));
        assert_eq!(DESCRIPTOR.last(), Some(&0xC0), "closes its collection");
    }

    #[test]
    fn buttons_land_on_the_xbox_layout_bits() {
        let mut p = Pad::default();
        assert!(p.apply(PadEvent::Button(Button::South, true)));
        assert!(!p.apply(PadEvent::Button(Button::South, true)), "no change");
        p.apply(PadEvent::Button(Button::West, true));
        p.apply(PadEvent::Button(Button::RightStick, true));
        // Bits 0 (BTN_A), 3 (BTN_X) and 14 (BTN_THUMBR).
        assert_eq!(p.report()[..2], (1u16 | 1 << 3 | 1 << 14).to_le_bytes());
        p.apply(PadEvent::Button(Button::South, false));
        assert_eq!(p.report()[..2], (1u16 << 3 | 1 << 14).to_le_bytes());
    }

    #[test]
    fn sticks_flip_y_and_triggers_scale() {
        let mut p = Pad::default();
        p.apply(PadEvent::Axis(Axis::LeftX, 1.0));
        p.apply(PadEvent::Axis(Axis::LeftY, 1.0)); // up
        p.apply(PadEvent::Axis(Axis::RightY, -2.0)); // clamped, down
        p.apply(PadEvent::Axis(Axis::LeftTrigger, 1.0));
        p.apply(PadEvent::Axis(Axis::RightTrigger, 0.5));
        let r = p.report();
        assert_eq!(i16::from_le_bytes([r[2], r[3]]), 32767);
        assert_eq!(i16::from_le_bytes([r[4], r[5]]), -32767);
        assert_eq!(i16::from_le_bytes([r[6], r[7]]), 0);
        assert_eq!(i16::from_le_bytes([r[8], r[9]]), 32767);
        assert_eq!((r[10], r[11]), (255, 128));
    }

    #[test]
    fn dpad_is_the_hat() {
        let mut p = Pad::default();
        assert_eq!(p.report()[12], 0);
        p.apply(PadEvent::Button(Button::Up, true));
        assert_eq!(p.report()[12], 1);
        p.apply(PadEvent::Button(Button::Right, true));
        assert_eq!(p.report()[12], 2);
        p.apply(PadEvent::Button(Button::Up, false));
        assert_eq!(p.report()[12], 3);
        p.apply(PadEvent::Button(Button::Left, true));
        assert_eq!(p.report()[12], 0, "left and right cancel out");
        p.apply(PadEvent::Button(Button::Right, false));
        p.apply(PadEvent::Button(Button::Down, true));
        assert_eq!(p.report()[12], 6);
        assert_eq!(p.report()[..2], [0, 0], "the D-pad sets no button bit");
    }

    #[test]
    fn lines_have_the_hid_command_shape() {
        let reg = register_line("Xbox Wireless Controller");
        assert_eq!(reg["command"], "register");
        assert_eq!(
            (reg["vid"].as_u64(), reg["pid"].as_u64()),
            (Some(1118), Some(654))
        );
        assert_eq!(
            reg["descriptor"].as_array().map(Vec::len),
            Some(DESCRIPTOR.len())
        );
        let mut p = Pad::default();
        p.apply(PadEvent::Button(Button::South, true));
        assert_eq!(
            report_line(&p),
            json!({"id": 1, "command": "report", "report": [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]})
        );
    }
}
