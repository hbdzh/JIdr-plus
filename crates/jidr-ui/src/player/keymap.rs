//! Per-device click mappings. Coordinates are normalized to the displayed
//! screen and bound to its exact rotation; they never depend on window size.
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use super::input;
use super::input::Screen;
use jidr_proto::control as pb;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

const VERSION: u32 = 1;
const MAX_BINDINGS: usize = 64;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Binding {
    pub key: String,
    pub x: f32,
    pub y: f32,
    pub rotation: u32,
}

pub fn panel_point(binding: &Binding, panel: Screen, shown: Screen) -> (i32, i32) {
    panel.unrotate(binding.rotation, shown.to_px(binding.x, binding.y))
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Scheme {
    pub version: u32,
    pub bindings: Vec<Binding>,
}

impl Default for Scheme {
    fn default() -> Self {
        Self {
            version: VERSION,
            bindings: Vec::new(),
        }
    }
}

pub fn key(text: &str) -> Option<String> {
    if text == " " {
        return Some("SPACE".into());
    }
    let mut chars = text.chars();
    let c = chars.next()?;
    if chars.next().is_some() || !c.is_ascii_alphanumeric() {
        return None;
    }
    Some(c.to_ascii_uppercase().to_string())
}

impl Scheme {
    pub fn remove_at(&mut self, x: f32, y: f32, width: f32, height: f32, rotation: u32) -> bool {
        if !x.is_finite()
            || !y.is_finite()
            || !width.is_finite()
            || !height.is_finite()
            || width <= 0.0
            || height <= 0.0
        {
            return false;
        }
        let nearest = self
            .bindings
            .iter()
            .enumerate()
            .filter(|(_, b)| b.rotation == rotation)
            .map(|(i, b)| {
                let dx = (b.x - x) * width;
                let dy = (b.y - y) * height;
                (i, dx * dx + dy * dy)
            })
            .filter(|(_, distance)| *distance <= 20.0 * 20.0)
            .min_by(|a, b| a.1.total_cmp(&b.1));
        if let Some((i, _)) = nearest {
            self.bindings.remove(i);
            true
        } else {
            false
        }
    }
    pub fn validate(&self) -> Result<(), String> {
        if self.version != VERSION {
            return Err("Unsupported key mapping version".into());
        }
        if self.bindings.len() > MAX_BINDINGS {
            return Err("Too many key mappings".into());
        }
        let mut seen = HashSet::new();
        for b in &self.bindings {
            let valid_key = b.key == "SPACE" || key(&b.key).as_ref() == Some(&b.key);
            if !valid_key
                || !b.x.is_finite()
                || !b.y.is_finite()
                || !(0.0..=1.0).contains(&b.x)
                || !(0.0..=1.0).contains(&b.y)
                || b.rotation > 3
                || !seen.insert((b.key.clone(), b.rotation))
            {
                return Err("Invalid or duplicate key mapping".into());
            }
        }
        Ok(())
    }

    pub fn assign(&mut self, text: &str, x: f32, y: f32, rotation: u32) -> Result<(), String> {
        let key = key(text).ok_or("Use a letter, number or Space")?;
        if !x.is_finite()
            || !y.is_finite()
            || !(0.0..=1.0).contains(&x)
            || !(0.0..=1.0).contains(&y)
            || rotation > 3
        {
            return Err("Invalid screen position".into());
        }
        if let Some(b) = self
            .bindings
            .iter_mut()
            .find(|b| b.key == key && b.rotation == rotation)
        {
            b.x = x;
            b.y = y;
        } else {
            if self.bindings.len() >= MAX_BINDINGS {
                return Err("Maximum number of mappings reached".into());
            }
            self.bindings.push(Binding {
                key,
                x,
                y,
                rotation,
            });
        }
        Ok(())
    }
}

fn path(data: &Path, device: Uuid) -> PathBuf {
    data.join("keymaps").join(format!("{device}.json"))
}

pub fn load(data: &Path, device: Uuid) -> Result<Scheme, String> {
    let content = match std::fs::read(path(data, device)) {
        Ok(content) => content,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Scheme::default()),
        Err(e) => return Err(format!("Can't read mapping: {e}")),
    };
    let scheme: Scheme =
        serde_json::from_slice(&content).map_err(|e| format!("Can't read mapping: {e}"))?;
    scheme.validate()?;
    Ok(scheme)
}

/// Write a new file first and atomically replace the old one on success.
pub fn save(data: &Path, device: Uuid, scheme: &Scheme) -> Result<(), String> {
    scheme.validate()?;
    let target = path(data, device);
    let dir = target.parent().ok_or("Invalid mapping directory")?;
    std::fs::create_dir_all(dir).map_err(|e| format!("Can't save mapping: {e}"))?;
    let tmp = dir.join(format!(".{}-{}.tmp", device, Uuid::new_v4()));
    let bytes =
        serde_json::to_vec_pretty(scheme).map_err(|e| format!("Can't save mapping: {e}"))?;
    let result = std::fs::write(&tmp, bytes).and_then(|()| std::fs::rename(&tmp, &target));
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result.map_err(|e| format!("Can't save mapping: {e}"))
}

/// A separate touch ID per held key; IDs 1 and 2 belong to mouse gestures.
#[derive(Default)]
pub struct Held {
    active: HashMap<String, (i32, i32, i32)>,
}

impl Held {
    pub fn down(&mut self, key: &str, x: i32, y: i32) -> Option<(i32, i32, i32)> {
        if self.active.contains_key(key) {
            return None;
        }
        let id = (3..=9).find(|id| !self.active.values().any(|p| p.0 == *id))?;
        let point = (id, x, y);
        self.active.insert(key.to_string(), point);
        Some(point)
    }
    pub fn up(&mut self, key: &str) -> Option<(i32, i32, i32)> {
        self.active.remove(key)
    }
    pub fn drain(&mut self) -> Vec<(i32, i32, i32)> {
        self.active.drain().map(|(_, p)| p).collect()
    }

    /// Return whether the key is bound and the touch event, if any. Repeated
    /// key-downs are consumed without creating extra touches.
    pub fn dispatch(
        &mut self,
        scheme: &Scheme,
        text: &str,
        down: bool,
        enabled: bool,
        screen: (u32, Screen, Screen),
    ) -> (bool, Option<pb::InputEvent>) {
        let (rotation, panel, shown) = screen;
        let Some(key) = key(text) else {
            return (false, None);
        };
        if !down {
            return match self.up(&key) {
                Some(point) => (true, Some(input::touch_event(&[point], false))),
                None => (false, None),
            };
        }
        if !enabled {
            return (false, None);
        }
        let Some(binding) = scheme
            .bindings
            .iter()
            .find(|b| b.key == key && b.rotation == rotation)
        else {
            return (false, None);
        };
        let (x, y) = panel_point(binding, panel, shown);
        (
            true,
            self.down(&key, x, y)
                .map(|point| input::touch_event(&[point], true)),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn assign_replaces_same_key_only_in_same_rotation_and_validates() {
        let mut s = Scheme::default();
        s.assign("a", 0.2, 0.3, 0).unwrap();
        s.assign("A", 0.7, 0.8, 0).unwrap();
        s.assign("a", 0.1, 0.2, 1).unwrap();
        assert_eq!(s.bindings.len(), 2);
        assert_eq!((s.bindings[0].x, s.bindings[0].y), (0.7, 0.8));
        assert!(s.assign("!", 0.1, 0.2, 0).is_err());
        assert!(s.assign("b", f32::NAN, 0.2, 0).is_err());
        assert!(s.validate().is_ok());
        assert!(!s.remove_at(0.7, 0.8, 300.0, 600.0, 1));
        assert!(s.remove_at(0.7, 0.8, 300.0, 600.0, 0));
        assert_eq!(s.bindings.len(), 1);
    }
    #[test]
    fn schemes_round_trip_and_corruption_is_not_silently_discarded() {
        let dir = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        let mut scheme = Scheme::default();
        scheme.assign(" ", 0.25, 0.75, 3).unwrap();
        save(dir.path(), id, &scheme).unwrap();
        assert_eq!(load(dir.path(), id).unwrap(), scheme);
        std::fs::write(path(dir.path(), id), b"broken").unwrap();
        assert!(load(dir.path(), id).is_err());
        assert_eq!(std::fs::read(path(dir.path(), id)).unwrap(), b"broken");
    }
    #[test]
    fn held_keys_have_unique_ids_and_release_without_repeat() {
        let mut h = Held::default();
        let a = h.down("A", 12, 34).unwrap();
        assert!(h.down("A", 12, 34).is_none());
        let b = h.down("B", 56, 78).unwrap();
        assert_ne!(a.0, b.0);
        assert_eq!(h.up("A"), Some(a));
        assert_eq!(h.drain(), vec![b]);
        assert!(h.up("B").is_none());
    }
    #[test]
    fn saved_positions_map_through_the_current_rotation() {
        let panel = Screen {
            width: 1080,
            height: 2400,
        };
        let shown = Screen {
            width: 2400,
            height: 1080,
        };
        let binding = Binding {
            key: "A".into(),
            x: 0.25,
            y: 0.5,
            rotation: 1,
        };
        assert_eq!(panel_point(&binding, panel, shown), (539, 600));
    }
    #[test]
    fn mapped_press_repeat_and_release_send_one_correct_touch_pair() {
        let mut scheme = Scheme::default();
        scheme.assign("a", 0.25, 0.5, 1).unwrap();
        let panel = Screen {
            width: 1080,
            height: 2400,
        };
        let shown = Screen {
            width: 2400,
            height: 1080,
        };
        let mut held = Held::default();
        assert!(
            !held
                .dispatch(&scheme, "a", true, false, (1, panel, shown))
                .0
        );
        assert!(!held.dispatch(&scheme, "a", true, true, (0, panel, shown)).0);
        let (handled, event) = held.dispatch(&scheme, "a", true, true, (1, panel, shown));
        assert!(handled);
        let Some(pb::input_event::Type::TouchEvent(down)) = event.unwrap().r#type else {
            panic!("touch event expected")
        };
        assert_eq!(
            (
                down.touches[0].x,
                down.touches[0].y,
                down.touches[0].pressure
            ),
            (539, 600, 100)
        );
        assert!(
            held.dispatch(&scheme, "a", true, true, (1, panel, shown))
                .1
                .is_none()
        );
        let (handled, event) = held.dispatch(&scheme, "a", false, false, (1, panel, shown));
        assert!(handled);
        let Some(pb::input_event::Type::TouchEvent(up)) = event.unwrap().r#type else {
            panic!("touch event expected")
        };
        assert_eq!(
            (up.touches[0].identifier, up.touches[0].pressure),
            (down.touches[0].identifier, 0)
        );
    }
}
