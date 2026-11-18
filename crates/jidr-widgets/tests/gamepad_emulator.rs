//! The guest side of game controller passthrough (#23) on a real emulator:
//! the virtual controller made with `hid` over `adb shell` (no root) is an
//! Xbox 360 game pad to Android, its reports arrive as `BUTTON_A` and
//! joystick motion, and closing `hid` removes it. CI has no physical
//! controller, so the events are synthetic; `input.gamepad.connect` adds
//! only the host reader on top.
#![cfg(feature = "emulator")]
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod common;

use std::sync::atomic::AtomicBool;
use std::time::Duration;

use jidr_adb::Adb;
use jidr_core::Cancel;
use jidr_widgets::gamepad::hid::{self, Axis, Button, PadEvent};
use jidr_widgets::gamepad::{Ended, forward};
use tokio::io::AsyncWriteExt;
use tokio::sync::mpsc;

const NAME: &str = "Jidr Test Pad";

#[tokio::test(flavor = "multi_thread")]
async fn a_virtual_controller_reaches_android() {
    let env = common::Env::boot("widgets-gamepad").await;
    let adb = Adb::new(env.info.adb_path.clone()).device(env.info.adb_serial.clone());
    let mut child = adb.spawn_with_stdin(&["shell", "hid", "-"]).unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let reg = format!("{}\n", hid::register_line(NAME));
    stdin.write_all(reg.as_bytes()).await.unwrap();
    stdin.flush().await.unwrap();

    env.eventually_shell(
        "Android to add the controller with the Xbox 360 key layout",
        "dumpsys input",
        &[NAME, "KeyLayoutFile", "Classes"],
        "",
        |out| {
            out.split(NAME).nth(1).is_some_and(|after| {
                after
                    .lines()
                    .take(16)
                    .any(|l| l.contains("Vendor_045e_Product_028e.kl"))
            })
        },
    )
    .await;

    let (tx, mut rx) = mpsc::channel(8);
    for ev in [
        PadEvent::Button(Button::South, true),
        PadEvent::Button(Button::South, false),
        PadEvent::Axis(Axis::LeftX, 1.0),
        PadEvent::Axis(Axis::LeftX, 0.0),
    ] {
        tx.send(ev).await.unwrap();
    }
    drop(tx);
    let (ended, sent) = forward(&mut rx, &mut stdin, &AtomicBool::new(false), &Cancel::new())
        .await
        .unwrap();
    assert_eq!((ended, sent), (Ended::Unplugged, 4));

    // API 30 prints `keyCode=96`, newer images `keyCode=BUTTON_A(96)`;
    // joystick motion is `source=0x01000010` or `source=JOYSTICK`.
    env.eventually_shell(
        "BUTTON_A and joystick motion from the controller",
        "dumpsys input",
        &["scanCode=304", "JOYSTICK", "0x01000010"],
        "",
        |out| {
            let key = out
                .lines()
                .any(|l| l.contains("scanCode=304") && l.contains("96"));
            let stick = out.lines().any(|l| {
                l.contains("MotionEvent")
                    && (l.contains("source=JOYSTICK") || l.contains("source=0x01000010"))
            });
            key && stick
        },
    )
    .await;

    // EOF ends `hid`, and Android removes the controller.
    drop(stdin);
    let _ = tokio::time::timeout(Duration::from_secs(10), child.wait()).await;
    env.eventually("the controller to go away", |e| {
        !e.shell("dumpsys input").contains(NAME)
    })
    .await;

    env.stop().await;
}
