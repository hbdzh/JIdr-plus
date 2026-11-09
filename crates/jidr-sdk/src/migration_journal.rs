//! Durable migration checkpoints. A checkpoint is evidence of progress, not
//! authorization to activate or delete either copy.
use serde::{Deserialize, Serialize};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    Copying,
    Prepared,
    Publishing,
    Published,
}

/// An observation only: none of these states changes the active location or
/// authorizes deleting a source or incomplete copy.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecoveryState {
    CopyInterrupted,
    Prepared,
    PublishInterrupted,
    Published,
    NeedsReview,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Journal {
    pub version: u8,
    pub source_data: PathBuf,
    pub destination: PathBuf,
    pub staging: PathBuf,
    pub marker: Option<uuid::Uuid>,
    pub phase: Phase,
}

impl Journal {
    /// A unique file is created before copying. It is retained on errors so
    /// an interrupted migration can be inspected without changing either tree.
    pub fn create(
        path: &Path,
        source: &Path,
        destination: &Path,
        staging: &Path,
    ) -> io::Result<Self> {
        if !path.is_absolute()
            || !source.is_absolute()
            || !destination.is_absolute()
            || !staging.is_absolute()
            || path.parent() != destination.parent()
            || staging.parent() != destination.parent()
            || staging == destination
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid journal paths",
            ));
        }
        let journal = Self {
            version: 1,
            source_data: source.to_owned(),
            destination: destination.to_owned(),
            staging: staging.to_owned(),
            marker: None,
            phase: Phase::Copying,
        };
        let mut file = private_file(path)?;
        serde_json::to_writer_pretty(&mut file, &journal)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        sync_parent(path)?;
        Ok(journal)
    }

    pub fn read(path: &Path) -> io::Result<Self> {
        let journal: Self = serde_json::from_slice(&fs::read(path)?)?;
        if journal.version != 1 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unsupported migration journal",
            ));
        }
        Ok(journal)
    }

    pub fn inspect(&self) -> RecoveryState {
        if !self.source_data.is_dir() {
            return RecoveryState::NeedsReview;
        }
        let presence = |path: &Path| match fs::symlink_metadata(path) {
            Ok(_) => Ok(true),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
            Err(e) => Err(e),
        };
        let (Ok(staging_exists), Ok(destination_exists)) =
            (presence(&self.staging), presence(&self.destination))
        else {
            return RecoveryState::NeedsReview;
        };
        let valid = |root: &Path| {
            self.marker.is_some_and(|marker| {
                fs::symlink_metadata(root).is_ok_and(|m| m.file_type().is_dir())
                    && fs::symlink_metadata(root.join("data")).is_ok_and(|m| m.file_type().is_dir())
                    && jidr_core::paths::PortableLocation {
                        root: root.to_owned(),
                        marker,
                    }
                    .resolve()
                    .is_ok()
            })
        };
        match (self.phase, staging_exists, destination_exists) {
            (Phase::Copying, _, false) => RecoveryState::CopyInterrupted,
            (Phase::Prepared, true, false) if valid(&self.staging) => RecoveryState::Prepared,
            (Phase::Publishing, true, false) if valid(&self.staging) => {
                RecoveryState::PublishInterrupted
            }
            (Phase::Publishing | Phase::Published, false, true) if valid(&self.destination) => {
                RecoveryState::Published
            }
            _ => RecoveryState::NeedsReview,
        }
    }

    /// Only forward transitions are accepted. If syncing fails after rename,
    /// re-read the checkpoint and inspect the paths before doing anything else.
    pub fn advance(
        &mut self,
        path: &Path,
        phase: Phase,
        marker: Option<uuid::Uuid>,
    ) -> io::Result<()> {
        let valid = matches!(
            (self.phase, phase),
            (Phase::Copying, Phase::Prepared)
                | (Phase::Prepared, Phase::Publishing)
                | (Phase::Publishing, Phase::Published)
        );
        if !valid || marker.is_none() || (self.marker.is_some() && self.marker != marker) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid migration checkpoint transition",
            ));
        }
        let mut next = self.clone();
        next.phase = phase;
        next.marker = marker;
        let parent = path
            .parent()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid journal path"))?;
        let temp = parent.join(format!(".jidr-journal-{}.tmp", uuid::Uuid::new_v4()));
        let result = (|| {
            let mut file = private_file(&temp)?;
            serde_json::to_writer_pretty(&mut file, &next)?;
            file.write_all(b"\n")?;
            file.sync_all()?;
            fs::rename(&temp, path)?;
            sync_parent(path)
        })();
        if result.is_err() {
            let _ = fs::remove_file(temp);
        }
        result?;
        *self = next;
        Ok(())
    }
}

fn private_file(path: &Path) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

fn sync_parent(path: &Path) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid journal path"))?;
    File::open(parent)?.sync_all()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn records_interruption_and_never_skips_a_phase() {
        let root = tempfile::tempdir().unwrap();
        let root = root.path().canonicalize().unwrap();
        let path = root.join("journal.json");
        fs::create_dir(root.join("old")).unwrap();
        let mut journal = Journal::create(
            &path,
            &root.join("old"),
            &root.join("new"),
            &root.join("stage"),
        )
        .unwrap();
        assert_eq!(journal.inspect(), RecoveryState::CopyInterrupted);
        assert!(
            Journal::create(
                &path,
                &root.join("old"),
                &root.join("new"),
                &root.join("stage")
            )
            .is_err()
        );
        let marker_id = uuid::Uuid::new_v4();
        let marker = Some(marker_id);
        assert!(journal.advance(&path, Phase::Published, marker).is_err());
        journal.advance(&path, Phase::Prepared, marker).unwrap();
        assert_eq!(Journal::read(&path).unwrap().phase, Phase::Prepared);
        fs::create_dir_all(root.join("stage/data")).unwrap();
        jidr_core::paths::PortableLocation {
            root: root.join("stage"),
            marker: marker_id,
        }
        .write_marker()
        .unwrap();
        assert_eq!(journal.inspect(), RecoveryState::Prepared);
        assert!(
            journal
                .advance(&path, Phase::Publishing, Some(uuid::Uuid::new_v4()))
                .is_err()
        );
        journal.advance(&path, Phase::Publishing, marker).unwrap();
        assert_eq!(Journal::read(&path).unwrap().phase, Phase::Publishing);
        assert_eq!(journal.inspect(), RecoveryState::PublishInterrupted);
        fs::rename(root.join("stage"), root.join("new")).unwrap();
        assert_eq!(journal.inspect(), RecoveryState::Published);
        journal.advance(&path, Phase::Published, marker).unwrap();
        assert_eq!(Journal::read(&path).unwrap().phase, Phase::Published);
        fs::remove_dir(root.join("old")).unwrap();
        assert_eq!(journal.inspect(), RecoveryState::NeedsReview);
    }
}
