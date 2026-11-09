//! Temporary socket barrier for old clients that do not know storage leases.
//! It must be acquired only after the old daemon and every emulator writer
//! have stopped. It cannot stop an already-running process or prevent a user
//! from launching an old executable after the barrier is released.
#![cfg(unix)]

use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, JoinHandle};
use std::time::Duration;

/// Owns the original daemon socket while a migration is quiescent.
pub struct LegacySocketBarrier {
    path: PathBuf,
    device: u64,
    inode: u64,
    token: uuid::Uuid,
    stop: Arc<AtomicBool>,
    alive: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl LegacySocketBarrier {
    /// Binds only an absent path. A stale socket must not be removed here:
    /// removing an active daemon's socket would allow two writers.
    pub fn acquire(path: &Path) -> io::Result<Self> {
        let listener = UnixListener::bind(path)?;
        let initialized = (|| {
            fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
            listener.set_nonblocking(true)?;
            fs::symlink_metadata(path)
        })();
        let metadata = match initialized {
            Ok(metadata) => metadata,
            Err(error) => {
                drop(listener);
                return Err(error);
            }
        };
        let stop = Arc::new(AtomicBool::new(false));
        let stop_thread = stop.clone();
        let alive = Arc::new(AtomicBool::new(true));
        let thread_alive = alive.clone();
        let thread = thread::Builder::new()
            .name("jidr-legacy-barrier".into())
            .spawn(move || {
                while !stop_thread.load(Ordering::Acquire) {
                    match listener.accept() {
                        Ok((stream, _)) => reply_busy(stream),
                        Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                            thread::sleep(Duration::from_millis(10));
                        }
                        Err(_) => break,
                    }
                }
                thread_alive.store(false, Ordering::Release);
            })?;
        Ok(Self {
            path: path.to_owned(),
            device: metadata.dev(),
            inode: metadata.ino(),
            token: uuid::Uuid::new_v4(),
            stop,
            alive,
            thread: Some(thread),
        })
    }

    /// The owner must check this before using a prepared copy; a removed or
    /// replaced socket means that old writers may have restarted.
    pub fn is_intact(&self) -> bool {
        self.alive.load(Ordering::Acquire) && self.owns_path()
    }

    pub fn covers(&self, path: &Path) -> bool {
        self.path == path && self.is_intact()
    }

    pub fn token(&self) -> uuid::Uuid {
        self.token
    }

    fn owns_path(&self) -> bool {
        fs::symlink_metadata(&self.path)
            .is_ok_and(|m| m.dev() == self.device && m.ino() == self.inode)
    }
}

fn reply_busy(mut stream: UnixStream) {
    let _ = stream.set_read_timeout(Some(Duration::from_millis(200)));
    let _ = stream.set_write_timeout(Some(Duration::from_millis(200)));
    let mut request = Vec::new();
    let mut reader = BufReader::new((&stream).take(64 * 1024));
    if reader.read_until(b'\n', &mut request).is_err() {
        return;
    }
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(&request) else {
        return;
    };
    let Some(id) = value.get("id").cloned() else {
        return;
    };
    let response = jidr_core::rpc::Response::err(
        id,
        jidr_core::rpc::RpcError::from_jidr(&jidr_core::JidrError::busy(
            "Jidr storage migration is in progress",
        )),
    );
    if serde_json::to_writer(&mut stream, &response).is_ok() {
        let _ = stream.write_all(b"\n");
    }
}

impl Drop for LegacySocketBarrier {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
        if self.owns_path() {
            let _ = fs::remove_file(&self.path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_connections_and_does_not_unlink_a_replacement() {
        let root = tempfile::tempdir().unwrap();
        let socket = root.path().join("daemon.sock");
        let barrier = LegacySocketBarrier::acquire(&socket).unwrap();
        assert!(barrier.is_intact());
        assert!(LegacySocketBarrier::acquire(&socket).is_err());
        let mut stream = UnixStream::connect(&socket).unwrap();
        stream
            .write_all(b"{\"jsonrpc\":\"2.0\",\"method\":\"hello\",\"id\":7}\n")
            .unwrap();
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).unwrap();
        let reply: jidr_core::rpc::Response = serde_json::from_str(&line).unwrap();
        assert_eq!(reply.id, 7);
        assert_eq!(
            reply.error.unwrap().to_jidr().code,
            jidr_core::ErrorCode::Busy
        );
        fs::remove_file(&socket).unwrap();
        fs::write(&socket, b"replacement").unwrap();
        assert!(!barrier.is_intact());
        drop(barrier);
        assert_eq!(fs::read(&socket).unwrap(), b"replacement");
    }
}
