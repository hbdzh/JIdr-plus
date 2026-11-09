//! Per-device game-window preferences. Invalid or off-screen geometry is not
//! restored; a malformed file is never overwritten silently.
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use uuid::Uuid;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct WindowState {
    pub version: u32,
    pub width: f32,
    pub height: f32,
    pub x: i32,
    pub y: i32,
    pub sidebar: bool,
    pub on_top: bool,
    #[serde(default)]
    pub landscape: bool,
    #[serde(default = "default_quality")]
    pub quality: u8,
}

fn default_quality() -> u8 {
    1
}

impl WindowState {
    fn validate(&self) -> Result<(), String> {
        if self.version != 1
            || !self.width.is_finite()
            || !self.height.is_finite()
            || !(180.0..=3840.0).contains(&self.width)
            || !(240.0..=2160.0).contains(&self.height)
            || self.quality > 2
        {
            return Err("Invalid saved window settings".into());
        }
        Ok(())
    }
}

/// Require a useful part of the title bar to remain on an available display.
pub fn visible(x: i32, y: i32, width: u32, displays: &[(i32, i32, u32, u32)]) -> bool {
    displays.iter().any(|&(mx, my, mw, mh)| {
        let (x, y, mx, my) = (i64::from(x), i64::from(y), i64::from(mx), i64::from(my));
        let right = x + i64::from(width);
        let mr = mx + i64::from(mw);
        let mb = my + i64::from(mh);
        right.min(mr) - x.max(mx) >= 80 && y >= my && y < mb - 32
    })
}

fn path(data: &Path, device: Uuid) -> PathBuf {
    data.join("window-state").join(format!("{device}.json"))
}

fn quality_path(data: &Path, device: Uuid) -> PathBuf {
    data.join("window-state")
        .join(format!("{device}.quality.json"))
}

/// A separate preference lets device settings change quality before a game
/// window has ever been opened, without inventing saved window geometry.
pub fn load_quality(data: &Path, device: Uuid) -> Result<u8, String> {
    let bytes = match std::fs::read(quality_path(data, device)) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(load(data, device)?.map_or(1, |state| state.quality));
        }
        Err(e) => return Err(format!("Can't read quality settings: {e}")),
    };
    let value: u8 =
        serde_json::from_slice(&bytes).map_err(|e| format!("Can't read quality settings: {e}"))?;
    if value > 2 {
        return Err("Invalid quality settings".into());
    }
    Ok(value)
}

pub fn save_quality(data: &Path, device: Uuid, quality: u8) -> Result<(), String> {
    if quality > 2 {
        return Err("Invalid quality settings".into());
    }
    // Refuse to silently replace a malformed preference or window-state file.
    load_quality(data, device)?;
    let target = quality_path(data, device);
    let dir = target.parent().ok_or("Invalid quality settings path")?;
    std::fs::create_dir_all(dir).map_err(|e| format!("Can't save quality settings: {e}"))?;
    let tmp = dir.join(format!(".{device}-{}.tmp", Uuid::new_v4()));
    let result =
        std::fs::write(&tmp, quality.to_string()).and_then(|()| std::fs::rename(&tmp, target));
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result.map_err(|e| format!("Can't save quality settings: {e}"))
}

pub fn load(data: &Path, device: Uuid) -> Result<Option<WindowState>, String> {
    let bytes = match std::fs::read(path(data, device)) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("Can't read window settings: {e}")),
    };
    let state: WindowState =
        serde_json::from_slice(&bytes).map_err(|e| format!("Can't read window settings: {e}"))?;
    state.validate()?;
    Ok(Some(state))
}

pub fn save(data: &Path, device: Uuid, state: &WindowState) -> Result<(), String> {
    state.validate()?;
    let target = path(data, device);
    let dir = target.parent().ok_or("Invalid window settings path")?;
    std::fs::create_dir_all(dir).map_err(|e| format!("Can't save window settings: {e}"))?;
    let tmp = dir.join(format!(".{device}-{}.tmp", Uuid::new_v4()));
    let data = serde_json::to_vec_pretty(state).map_err(|e| e.to_string())?;
    let result = std::fs::write(&tmp, data).and_then(|()| std::fs::rename(&tmp, target));
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    result.map_err(|e| format!("Can't save window settings: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn geometry_must_have_visible_titlebar() {
        let monitors = [(0, 0, 1920, 1080), (-1280, 0, 1280, 1024)];
        assert!(visible(100, 100, 400, &monitors));
        assert!(visible(-900, 100, 400, &monitors));
        assert!(!visible(5000, 100, 400, &monitors));
        assert!(!visible(100, -500, 400, &monitors));
    }
    #[test]
    fn settings_are_isolated_and_invalid_files_are_preserved() {
        let tmp = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        let s = WindowState {
            version: 1,
            width: 400.0,
            height: 752.0,
            x: -200,
            y: 30,
            sidebar: false,
            on_top: true,
            landscape: false,
            quality: 1,
        };
        save(tmp.path(), id, &s).unwrap();
        assert_eq!(load(tmp.path(), id).unwrap(), Some(s));
        assert_eq!(load(tmp.path(), Uuid::new_v4()).unwrap(), None);
        std::fs::write(path(tmp.path(), id), b"invalid").unwrap();
        assert!(load(tmp.path(), id).is_err());
        assert_eq!(std::fs::read(path(tmp.path(), id)).unwrap(), b"invalid");
    }

    #[test]
    fn quality_is_per_device_and_does_not_overwrite_invalid_files() {
        let tmp = tempfile::tempdir().unwrap();
        let id = Uuid::new_v4();
        assert_eq!(load_quality(tmp.path(), id).unwrap(), 1);
        save_quality(tmp.path(), id, 2).unwrap();
        assert_eq!(load_quality(tmp.path(), id).unwrap(), 2);
        assert_eq!(load_quality(tmp.path(), Uuid::new_v4()).unwrap(), 1);
        std::fs::write(quality_path(tmp.path(), id), b"bad").unwrap();
        assert!(save_quality(tmp.path(), id, 0).is_err());
        assert_eq!(std::fs::read(quality_path(tmp.path(), id)).unwrap(), b"bad");
    }
}
