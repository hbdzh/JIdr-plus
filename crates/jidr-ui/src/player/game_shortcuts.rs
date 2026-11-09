//! Per-device window shortcuts; game key mappings are stored separately.
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use uuid::Uuid;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Binding {
    pub key: String,
    pub command: bool,
    pub control: bool,
    pub shift: bool,
    pub alt: bool,
}

impl Binding {
    pub fn new(key: &str, command: bool, control: bool, shift: bool, alt: bool) -> Option<Self> {
        let key = key.to_ascii_uppercase();
        if key.len() != 1
            || !key.as_bytes()[0].is_ascii_alphanumeric()
            || !(command || control || alt)
        {
            return None;
        }
        // Keep editing and application lifecycle chords available to macOS.
        if command
            && !control
            && !alt
            && matches!(
                key.as_str(),
                "Q" | "W" | "H" | "A" | "C" | "V" | "X" | "Z" | "Y"
            )
        {
            return None;
        }
        Some(Self {
            key,
            command,
            control,
            shift,
            alt,
        })
    }
    pub fn display(&self) -> String {
        format!(
            "{}{}{}{}{}",
            if self.control { "⌃" } else { "" },
            if self.alt { "⌥" } else { "" },
            if self.shift { "⇧" } else { "" },
            if self.command { "⌘" } else { "" },
            self.key
        )
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Shortcuts {
    pub version: u8,
    pub bindings: Vec<Binding>,
}
impl Default for Shortcuts {
    fn default() -> Self {
        Self {
            version: 1,
            bindings: ["S", "F", "J", "I", "T"]
                .into_iter()
                .map(|key| Binding {
                    key: key.into(),
                    command: true,
                    control: false,
                    shift: true,
                    alt: false,
                })
                .collect(),
        }
    }
}
impl Shortcuts {
    pub fn assign(&mut self, index: usize, binding: Binding) -> Result<(), &'static str> {
        if index >= self.bindings.len() {
            return Err(crate::i18n::text(
                "Invalid shortcut action",
                "无效的快捷键操作",
            ));
        }
        if self
            .bindings
            .iter()
            .enumerate()
            .any(|(i, b)| i != index && *b == binding)
        {
            return Err(crate::i18n::text(
                "Shortcut is already in use",
                "该快捷键已被占用",
            ));
        }
        self.bindings[index] = binding;
        Ok(())
    }
    pub fn lookup(&self, binding: &Binding) -> Option<usize> {
        self.bindings.iter().position(|b| b == binding)
    }
    fn valid(&self) -> bool {
        self.version == 1
            && self.bindings.len() == 5
            && self.bindings.iter().enumerate().all(|(i, b)| {
                Binding::new(&b.key, b.command, b.control, b.shift, b.alt).as_ref() == Some(b)
                    && !self.bindings[..i].contains(b)
            })
    }
}
fn path(data: &Path, id: Uuid) -> PathBuf {
    data.join("game-shortcuts").join(format!("{id}.json"))
}
pub fn load(data: &Path, id: Uuid) -> Result<Shortcuts, String> {
    let data = match std::fs::read(path(data, id)) {
        Ok(v) => v,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Shortcuts::default()),
        Err(e) => {
            return Err(format!(
                "{} {e}",
                crate::i18n::text("Could not read shortcuts:", "无法读取快捷键：")
            ));
        }
    };
    let v: Shortcuts = serde_json::from_slice(&data).map_err(|e| {
        format!(
            "{} {e}",
            crate::i18n::text("Could not read shortcuts:", "无法读取快捷键：")
        )
    })?;
    if v.valid() {
        Ok(v)
    } else {
        Err(crate::i18n::text(
            "Invalid shortcut configuration; the original file was preserved",
            "快捷键配置无效，原文件已保留",
        )
        .into())
    }
}
pub fn save(data: &Path, id: Uuid, value: &Shortcuts) -> Result<(), String> {
    if !value.valid() {
        return Err(crate::i18n::text("Invalid shortcut configuration", "快捷键配置无效").into());
    }
    let target = path(data, id);
    let dir = target
        .parent()
        .ok_or(crate::i18n::text("Invalid shortcut path", "快捷键路径无效"))?;
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let temp = dir.join(format!(".{id}-{}.tmp", Uuid::new_v4()));
    let bytes = serde_json::to_vec_pretty(value).map_err(|e| e.to_string())?;
    let result = std::fs::write(&temp, bytes).and_then(|()| std::fs::rename(&temp, target));
    if result.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    result.map_err(|e| {
        format!(
            "{} {e}",
            crate::i18n::text("Could not save shortcuts:", "无法保存快捷键：")
        )
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shortcuts_validate_conflicts_and_persist_per_device() {
        let tmp = tempfile::tempdir().unwrap();
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        let mut s = Shortcuts::default();
        assert!(s.assign(0, s.bindings[1].clone()).is_err());
        assert!(Binding::new("v", true, false, false, false).is_none());
        let binding = Binding::new("k", true, false, true, false).unwrap();
        s.assign(0, binding.clone()).unwrap();
        save(tmp.path(), a, &s).unwrap();
        assert_eq!(load(tmp.path(), a).unwrap().lookup(&binding), Some(0));
        assert_eq!(load(tmp.path(), b).unwrap().lookup(&binding), None);
    }
}
