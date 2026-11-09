//! Cooperative exclusion between a daemon and an offline storage migration.
//!
//! Older Jidr versions do not take this lease. A migration must separately
//! stop and prevent restarts of all such processes and emulator writers.

use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};

#[derive(Debug)]
pub struct StorageLease {
    _file: File,
    data: PathBuf,
    token: uuid::Uuid,
}

impl StorageLease {
    /// Hold this value for the whole period in which the data must not be
    /// opened by another cooperative daemon or migration.
    pub fn acquire(data: &Path) -> io::Result<Self> {
        if !fs::symlink_metadata(data)?.file_type().is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "storage directory is unavailable",
            ));
        }
        let data = data.canonicalize()?;
        let path = data.join(".jidr-storage.lock");
        if let Ok(metadata) = fs::symlink_metadata(&path)
            && !metadata.file_type().is_file()
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid storage lock file",
            ));
        }
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path)?;
        file.try_lock()
            .map_err(|e| io::Error::other(format!("Jidr storage is in use: {e}")))?;
        Ok(Self {
            _file: file,
            data,
            token: uuid::Uuid::new_v4(),
        })
    }

    pub fn covers(&self, data: &Path) -> io::Result<bool> {
        Ok(self.data == data.canonicalize()?)
    }

    /// Distinguishes reacquiring the same lock from continuously holding it.
    pub fn token(&self) -> uuid::Uuid {
        self.token
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn excludes_another_lease_until_dropped() {
        let path = std::env::temp_dir().join(format!("jidr-lease-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&path).unwrap();
        let first = StorageLease::acquire(&path).unwrap();
        assert!(first.covers(&path).unwrap());
        assert!(StorageLease::acquire(&path).is_err());
        drop(first);
        let second = StorageLease::acquire(&path).unwrap();
        drop(second);
        fs::remove_dir_all(path).unwrap();
    }
}
