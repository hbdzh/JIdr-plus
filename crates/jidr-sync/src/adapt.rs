//! Which events are forwarded, and how coordinates map between screens.

use jidr_automation::Event;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

use crate::session::{DisplaySize, SyncOptions};

/// How a leader's normalized position maps onto a follower's screen.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum Adaptation {
    /// Same relative position on every screen (0.5, 0.5 is always the
    /// centre). Different shapes stretch the picture.
    #[default]
    Stretch,
    /// The leader's whole screen is fitted inside the follower's, keeping its
    /// shape and centred, so a tap lands on the same pixel of the scaled
    /// picture. The bars around it are never touched.
    Letterbox,
}

/// Whether the options let this kind of event through.
pub fn allows(event: &Event, options: &SyncOptions) -> bool {
    match event {
        Event::Touch { .. } | Event::MappedTouch { .. } => true,
        Event::Key { .. } => options.sync_keyboard,
        Event::Text { .. } | Event::Paste { .. } => options.sync_text,
        Event::ToolKey { .. } => options.sync_tool_keys,
    }
}

fn letterbox(x: f64, y: f64, leader: DisplaySize, follower: DisplaySize) -> (f64, f64) {
    let (lw, lh) = (f64::from(leader.width), f64::from(leader.height));
    let (fw, fh) = (f64::from(follower.width), f64::from(follower.height));
    let scale = (fw / lw).min(fh / lh);
    let (cw, ch) = (lw * scale, lh * scale);
    let (ox, oy) = ((fw - cw) / 2.0, (fh - ch) / 2.0);
    (
        ((ox + x * cw) / fw).clamp(0.0, 1.0),
        ((oy + y * ch) / fh).clamp(0.0, 1.0),
    )
}

/// Maps `event` from the leader's screen to the follower's. Events without
/// coordinates are returned unchanged. Without both sizes (or with an invalid
/// one) positions pass through unchanged, which is `Stretch`.
///
/// Returns `None` for an event that is outside the format bounds.
pub fn adapt(
    event: &Event,
    leader: Option<DisplaySize>,
    follower: Option<DisplaySize>,
    mode: Adaptation,
) -> Option<Event> {
    if !event.fits_format() {
        return None;
    }
    let sizes = match (mode, leader, follower) {
        (Adaptation::Letterbox, Some(l), Some(f)) if l.is_valid() && f.is_valid() => Some((l, f)),
        _ => None,
    };
    let Some((l, f)) = sizes else {
        return Some(event.clone());
    };
    Some(match event {
        Event::Touch { x, y, down } => {
            let (x, y) = letterbox(*x, *y, l, f);
            Event::Touch { x, y, down: *down }
        }
        Event::MappedTouch { id, x, y, down } => {
            let (x, y) = letterbox(*x, *y, l, f);
            Event::MappedTouch {
                id: *id,
                x,
                y,
                down: *down,
            }
        }
        other => other.clone(),
    })
}

/// The one call a relay makes per event and follower: filter by the options,
/// then adapt the coordinates.
pub fn forward(
    event: &Event,
    options: &SyncOptions,
    leader: Option<DisplaySize>,
    follower: Option<DisplaySize>,
) -> Option<Event> {
    if !allows(event, options) {
        return None;
    }
    adapt(event, leader, follower, options.adaptation)
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;
    use proptest::prelude::*;

    fn size(width: u32, height: u32) -> DisplaySize {
        DisplaySize { width, height }
    }

    fn touch(x: f64, y: f64) -> Event {
        Event::Touch { x, y, down: true }
    }

    fn near(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    fn xy(event: &Event) -> (f64, f64) {
        match event {
            Event::Touch { x, y, .. } | Event::MappedTouch { x, y, .. } => (*x, *y),
            other => panic!("no coordinates: {other:?}"),
        }
    }

    #[test]
    fn stretch_keeps_the_relative_position() {
        let out = adapt(
            &touch(0.25, 0.75),
            Some(size(1080, 2400)),
            Some(size(1280, 720)),
            Adaptation::Stretch,
        )
        .unwrap();
        assert_eq!(out, touch(0.25, 0.75));
    }

    #[test]
    fn letterbox_with_the_same_shape_is_the_identity() {
        let (x, y) = xy(&adapt(
            &touch(0.3, 0.6),
            Some(size(1080, 2400)),
            Some(size(540, 1200)),
            Adaptation::Letterbox,
        )
        .unwrap());
        assert!(near(x, 0.3) && near(y, 0.6));
    }

    #[test]
    fn letterbox_centres_a_portrait_leader_on_a_landscape_follower() {
        // 1000x2000 portrait into 2000x1000: scale 0.5, content 500x1000,
        // bars of 750 px left and right.
        let l = Some(size(1000, 2000));
        let f = Some(size(2000, 1000));
        let centre = xy(&adapt(&touch(0.5, 0.5), l, f, Adaptation::Letterbox).unwrap());
        assert!(near(centre.0, 0.5) && near(centre.1, 0.5));
        let left = xy(&adapt(&touch(0.0, 0.0), l, f, Adaptation::Letterbox).unwrap());
        assert!(near(left.0, 0.375) && near(left.1, 0.0));
        let right = xy(&adapt(&touch(1.0, 1.0), l, f, Adaptation::Letterbox).unwrap());
        assert!(near(right.0, 0.625) && near(right.1, 1.0));
    }

    #[test]
    fn letterbox_centres_a_landscape_leader_on_a_portrait_follower() {
        let l = Some(size(2000, 1000));
        let f = Some(size(1000, 2000));
        let top_left = xy(&adapt(&touch(0.0, 0.0), l, f, Adaptation::Letterbox).unwrap());
        assert!(near(top_left.0, 0.0) && near(top_left.1, 0.375));
    }

    #[test]
    fn letterbox_without_both_sizes_passes_through() {
        let e = touch(0.2, 0.9);
        assert_eq!(
            adapt(&e, None, Some(size(10, 10)), Adaptation::Letterbox).unwrap(),
            e
        );
        assert_eq!(
            adapt(
                &e,
                Some(size(0, 10)),
                Some(size(10, 10)),
                Adaptation::Letterbox
            )
            .unwrap(),
            e
        );
    }

    #[test]
    fn mapped_touch_keeps_its_id_and_edge() {
        let e = Event::MappedTouch {
            id: 4,
            x: 0.0,
            y: 1.0,
            down: false,
        };
        let out = adapt(
            &e,
            Some(size(1000, 2000)),
            Some(size(2000, 1000)),
            Adaptation::Letterbox,
        )
        .unwrap();
        match out {
            Event::MappedTouch { id, x, y, down } => {
                assert_eq!(id, 4);
                assert!(near(x, 0.375) && near(y, 1.0));
                assert!(!down);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn out_of_bounds_events_are_rejected() {
        let s = Some(size(100, 100));
        assert!(adapt(&touch(1.5, 0.5), s, s, Adaptation::Stretch).is_none());
        assert!(adapt(&touch(f64::NAN, 0.5), s, s, Adaptation::Stretch).is_none());
        assert!(
            adapt(
                &Event::Key {
                    key: String::new(),
                    down: true
                },
                s,
                s,
                Adaptation::Stretch
            )
            .is_none()
        );
        assert!(
            adapt(
                &Event::MappedTouch {
                    id: 2,
                    x: 0.5,
                    y: 0.5,
                    down: true
                },
                s,
                s,
                Adaptation::Stretch
            )
            .is_none()
        );
    }

    #[test]
    fn options_filter_event_kinds() {
        let key = Event::Key {
            key: "A".into(),
            down: true,
        };
        let text = Event::Text { text: "hi".into() };
        let paste = Event::Paste { text: "hi".into() };
        let tool = Event::ToolKey { key: "home".into() };
        let all = SyncOptions::default();
        for e in [&key, &text, &paste, &tool, &touch(0.1, 0.1)] {
            assert!(forward(e, &all, None, None).is_some());
        }
        let none = SyncOptions {
            sync_keyboard: false,
            sync_text: false,
            sync_tool_keys: false,
            ..all
        };
        for e in [&key, &text, &paste, &tool] {
            assert!(forward(e, &none, None, None).is_none());
        }
        assert!(forward(&touch(0.1, 0.1), &none, None, None).is_some());
    }

    proptest! {
        #[test]
        fn adapted_events_always_fit_the_format(
            x in 0.0f64..=1.0,
            y in 0.0f64..=1.0,
            lw in 1u32..=8192, lh in 1u32..=8192,
            fw in 1u32..=8192, fh in 1u32..=8192,
            letterbox in any::<bool>(),
        ) {
            let mode = if letterbox { Adaptation::Letterbox } else { Adaptation::Stretch };
            let out = adapt(&touch(x, y), Some(size(lw, lh)), Some(size(fw, fh)), mode).unwrap();
            prop_assert!(out.fits_format());
        }

        #[test]
        fn letterbox_stays_inside_the_scaled_picture(
            x in 0.0f64..=1.0,
            y in 0.0f64..=1.0,
            lw in 1u32..=8192, lh in 1u32..=8192,
            fw in 1u32..=8192, fh in 1u32..=8192,
        ) {
            let out = adapt(
                &touch(x, y),
                Some(size(lw, lh)),
                Some(size(fw, fh)),
                Adaptation::Letterbox,
            ).unwrap();
            let (ox, oy) = xy(&out);
            let scale = (f64::from(fw) / f64::from(lw)).min(f64::from(fh) / f64::from(lh));
            let cw = f64::from(lw) * scale / f64::from(fw);
            let ch = f64::from(lh) * scale / f64::from(fh);
            prop_assert!(ox >= (1.0 - cw) / 2.0 - 1e-9 && ox <= (1.0 + cw) / 2.0 + 1e-9);
            prop_assert!(oy >= (1.0 - ch) / 2.0 - 1e-9 && oy <= (1.0 + ch) / 2.0 + 1e-9);
        }
    }
}
