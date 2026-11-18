//! One job of a kind per device (a microphone injection, a game controller),
//! each with a stop flag that its stop command sets.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use jidr_core::{JidrError, JidrResult};
use uuid::Uuid;

/// Stop flags of the jobs in progress, by device.
#[derive(Debug, Default)]
pub struct Running(Mutex<HashMap<Uuid, Arc<AtomicBool>>>);

impl Running {
    pub fn get(&self, id: Uuid) -> Option<Arc<AtomicBool>> {
        self.0.lock().ok()?.get(&id).cloned()
    }

    /// Registers a job on `id`; `busy` (with the message `busy` builds)
    /// while another one runs.
    pub fn start(&self, id: Uuid, busy: impl FnOnce() -> String) -> JidrResult<Registered<'_>> {
        let flag = Arc::new(AtomicBool::new(false));
        let mut m = self
            .0
            .lock()
            .map_err(|_| JidrError::unexpected("running jobs lock poisoned"))?;
        if m.contains_key(&id) {
            return Err(JidrError::busy(busy()));
        }
        m.insert(id, flag.clone());
        Ok(Registered {
            map: self,
            id,
            flag,
        })
    }

    /// Asks the job on `id` to stop; false when none runs.
    pub fn stop(&self, id: Uuid) -> bool {
        match self.get(id) {
            Some(f) => {
                f.store(true, Ordering::Relaxed);
                true
            }
            None => false,
        }
    }
}

/// Removes its job from the map when dropped, however the job ends.
#[derive(Debug)]
pub struct Registered<'a> {
    map: &'a Running,
    id: Uuid,
    pub flag: Arc<AtomicBool>,
}

impl Drop for Registered<'_> {
    fn drop(&mut self) {
        if let Ok(mut m) = self.map.0.lock()
            && m.get(&self.id).is_some_and(|f| Arc::ptr_eq(f, &self.flag))
        {
            m.remove(&self.id);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_job_per_device() {
        let jobs = Running::default();
        let id = Uuid::new_v4();
        let reg = jobs.start(id, || "Phone is busy".into()).unwrap();
        let e = jobs.start(id, || "Phone is busy".into()).err().unwrap();
        assert_eq!(
            (e.code, e.message.as_str()),
            (jidr_core::ErrorCode::Busy, "Phone is busy")
        );
        // Another device is fine.
        let other = jobs.start(Uuid::new_v4(), String::new).unwrap();
        // The stop command sets the job's flag.
        assert!(jobs.stop(id));
        assert!(reg.flag.load(Ordering::Relaxed));
        drop(reg);
        assert!(jobs.get(id).is_none());
        assert!(!jobs.stop(id), "nothing left to stop");
        assert!(jobs.start(id, String::new).is_ok());
        drop(other);
    }
}
