//! Pool leases (D42, Phase 13d): who holds which throwaway clone, and until
//! when. A lease is tied to the client connection that took it (MCP: the
//! agent's process; 2 minutes of grace after it disconnects) or to a TTL
//! (the CLI's default is 2 hours). The daemon's reaper releases expired ones.

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::path::Path;
use std::time::Duration;

use chrono::{DateTime, Utc};
use jidr_core::{Device, JidrError, JidrResult};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// How long a connection lease outlives its connection.
pub const GRACE: Duration = Duration::from_secs(120);
/// How often the reaper looks for expired leases.
pub const REAP_EVERY: Duration = Duration::from_secs(30);

/// What keeps a lease alive.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case", tag = "kind")]
pub enum Holder {
    /// The client connection that took it (until it closes, plus grace).
    Connection { id: u64 },
    /// A fixed lifetime, renewable.
    Ttl,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
pub struct Lease {
    pub id: Uuid,
    pub base: Uuid,
    pub device: Uuid,
    pub holder: Holder,
    /// When the reaper releases it; `None` while its connection is open or its
    /// TTL-based clone is still being prepared.
    pub expires_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Default)]
pub struct Leases {
    by_id: HashMap<Uuid, Lease>,
    // In-flight clones have no TTL until they are delivered.
    pending: HashSet<Uuid>,
    connections: HashSet<u64>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct LeaseFile {
    version: u32,
    leases: Vec<StoredLease>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StoredLease {
    lease: Lease,
    #[serde(default)]
    pending: bool,
}

impl Leases {
    /// Load conservatively: malformed records must never cause clone deletion.
    pub fn load(path: &Path, devices: &[Device], now: DateTime<Utc>) -> JidrResult<Self> {
        let mut leases = Self::default();
        let bytes = match std::fs::read(path) {
            Ok(bytes) => Some(bytes),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(e) => {
                return Err(JidrError::unexpected(format!(
                    "reading {}: {e}",
                    path.display()
                )));
            }
        };
        if let Some(bytes) = bytes {
            let file: LeaseFile = serde_json::from_slice(&bytes)
                .map_err(|e| JidrError::unexpected(format!("invalid {}: {e}", path.display())))?;
            if file.version != 1 {
                return Err(JidrError::unexpected(format!(
                    "unsupported lease file version {}",
                    file.version
                )));
            }
            for record in file.leases {
                let mut lease = record.lease;
                let Some(device) = devices.iter().find(|d| d.id == lease.device) else {
                    continue;
                };
                if device.pool_base != Some(lease.base)
                    || leases.for_device(lease.device).is_some()
                    || leases.by_id.contains_key(&lease.id)
                {
                    return Err(JidrError::unexpected(
                        "invalid or duplicate persisted pool lease",
                    ));
                }
                if !record.pending && lease.holder == Holder::Ttl && lease.expires_at.is_none() {
                    return Err(JidrError::unexpected("persisted TTL lease has no expiry"));
                }
                // No connection or in-flight job survives a daemon restart.
                // Keep an existing deadline rather than extending it on each restart.
                if (record.pending || matches!(lease.holder, Holder::Connection { .. }))
                    && lease.expires_at.is_none()
                {
                    lease.expires_at = Some(now + grace());
                }
                leases.insert(lease);
            }
        }
        // Migrate pre-persistence clones and recover a crash between registry
        // insertion and lease insertion, retaining the established grace period.
        for device in devices.iter().filter(|d| d.pool_base.is_some()) {
            if leases.for_device(device.id).is_none()
                && let Some(base) = device.pool_base
            {
                leases.insert(Lease {
                    id: Uuid::new_v4(),
                    base,
                    device: device.id,
                    holder: Holder::Ttl,
                    expires_at: Some(now + grace()),
                    created_at: now,
                });
            }
        }
        Ok(leases)
    }

    /// Write a complete snapshot atomically, before acknowledging mutations.
    pub fn save(&self, path: &Path) -> JidrResult<()> {
        let parent = path
            .parent()
            .ok_or_else(|| JidrError::unexpected("invalid lease path"))?;
        std::fs::create_dir_all(parent)
            .map_err(|e| JidrError::unexpected(format!("creating {}: {e}", parent.display())))?;
        let tmp = parent.join(format!(".pool-leases-{}.tmp", Uuid::new_v4()));
        let file = LeaseFile {
            version: 1,
            leases: self
                .all()
                .into_iter()
                .map(|lease| StoredLease {
                    pending: self.pending.contains(&lease.id),
                    lease,
                })
                .collect(),
        };
        let result = (|| -> std::io::Result<()> {
            let mut out = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&tmp)?;
            serde_json::to_writer_pretty(&mut out, &file)?;
            out.write_all(b"\n")?;
            out.sync_all()?;
            std::fs::rename(&tmp, path)
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
        result.map_err(|e| JidrError::unexpected(format!("saving {}: {e}", path.display())))?;
        // The rename has committed: a directory-sync failure cannot safely be
        // reported as a failed transaction without diverging from disk.
        if let Err(error) = std::fs::File::open(parent).and_then(|dir| dir.sync_all()) {
            tracing::warn!(%error, "cannot sync lease directory");
        }
        Ok(())
    }

    pub fn connected(&mut self, conn: u64) {
        self.connections.insert(conn);
    }

    pub fn insert_pending(&mut self, mut lease: Lease, now: DateTime<Utc>) {
        if let Holder::Connection { id } = lease.holder
            && !self.connections.contains(&id)
        {
            lease.expires_at = Some(now + grace());
        }
        self.pending.insert(lease.id);
        self.insert(lease);
    }

    pub fn activate(&mut self, id: Uuid, ttl: Duration, now: DateTime<Utc>) -> JidrResult<Lease> {
        let l = self
            .by_id
            .get_mut(&id)
            .ok_or_else(|| JidrError::not_found(format!("no lease {id}")))?;
        if l.holder == Holder::Ttl {
            l.expires_at = Some(expiry(now, ttl)?);
        }
        self.pending.remove(&id);
        Ok(l.clone())
    }

    pub fn is_pending(&self, id: Uuid) -> bool {
        self.pending.contains(&id)
    }

    pub fn abandon(&mut self, id: Uuid, now: DateTime<Utc>) {
        if self.pending.remove(&id)
            && let Some(lease) = self.by_id.get_mut(&id)
            && lease.expires_at.is_none()
        {
            lease.expires_at = Some(now + grace());
        }
    }
    pub fn insert(&mut self, lease: Lease) {
        self.by_id.insert(lease.id, lease);
    }

    pub fn get(&self, id: Uuid) -> Option<&Lease> {
        self.by_id.get(&id)
    }

    /// The lease on `device`, if it is a pool clone.
    pub fn for_device(&self, device: Uuid) -> Option<&Lease> {
        self.by_id.values().find(|l| l.device == device)
    }

    pub fn remove(&mut self, id: Uuid) -> Option<Lease> {
        self.pending.remove(&id);
        self.by_id.remove(&id)
    }

    pub fn all(&self) -> Vec<Lease> {
        let mut v: Vec<Lease> = self.by_id.values().cloned().collect();
        v.sort_by_key(|l| l.created_at);
        v
    }

    pub fn len(&self) -> usize {
        self.by_id.len()
    }

    pub fn is_empty(&self) -> bool {
        self.by_id.is_empty()
    }

    pub fn of_base(&self, base: Uuid) -> usize {
        self.by_id.values().filter(|l| l.base == base).count()
    }

    /// Connection `conn` closed: its leases expire after the grace period.
    pub fn disconnected(&mut self, conn: u64, now: DateTime<Utc>) -> bool {
        self.connections.remove(&conn);
        let mut changed = false;
        for l in self.by_id.values_mut() {
            if l.holder == (Holder::Connection { id: conn }) && l.expires_at.is_none() {
                l.expires_at = Some(now + grace());
                changed = true;
            }
        }
        changed
    }

    /// Extends a lease. A connection lease whose connection is open has no
    /// expiry to extend; a TTL lease runs `ttl` from now.
    pub fn renew(&mut self, id: Uuid, ttl: Duration, now: DateTime<Utc>) -> JidrResult<Lease> {
        let l = self
            .by_id
            .get_mut(&id)
            .ok_or_else(|| JidrError::not_found(format!("no lease {id}")))?;
        if l.holder == Holder::Ttl || l.expires_at.is_some() {
            l.expires_at = Some(expiry(now, ttl)?);
        }
        Ok(l.clone())
    }

    /// Leases due for release at `now`.
    pub fn expired(&self, now: DateTime<Utc>) -> Vec<Lease> {
        self.by_id
            .values()
            .filter(|l| !self.pending.contains(&l.id) && l.expires_at.is_some_and(|t| t <= now))
            .cloned()
            .collect()
    }
}

pub fn expiry(now: DateTime<Utc>, ttl: Duration) -> JidrResult<DateTime<Utc>> {
    let ttl =
        chrono::Duration::from_std(ttl).map_err(|_| JidrError::usage("ttl_s is too large"))?;
    now.checked_add_signed(ttl)
        .ok_or_else(|| JidrError::usage("ttl_s is too large"))
}

fn grace() -> chrono::Duration {
    chrono::Duration::from_std(GRACE).unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lease(holder: Holder, expires_at: Option<DateTime<Utc>>) -> Lease {
        Lease {
            id: Uuid::new_v4(),
            base: Uuid::nil(),
            device: Uuid::new_v4(),
            holder,
            expires_at,
            created_at: Utc::now(),
        }
    }

    #[test]
    fn connection_leases_expire_after_grace() {
        let now = Utc::now();
        let mut l = Leases::default();
        let a = lease(Holder::Connection { id: 1 }, None);
        let b = lease(Holder::Connection { id: 2 }, None);
        l.insert(a.clone());
        l.insert(b.clone());
        assert!(
            l.expired(now + chrono::Duration::days(1)).is_empty(),
            "open connections"
        );
        l.disconnected(1, now);
        assert_eq!(l.get(a.id).unwrap().expires_at, Some(now + grace()));
        assert!(
            l.expired(now + chrono::Duration::seconds(119)).is_empty(),
            "in grace"
        );
        let due = l.expired(now + chrono::Duration::seconds(120));
        assert_eq!(due.iter().map(|x| x.id).collect::<Vec<_>>(), vec![a.id]);
        // Renewing during grace extends it; an open connection has nothing to renew.
        l.renew(a.id, Duration::from_secs(600), now).unwrap();
        assert!(l.expired(now + chrono::Duration::seconds(300)).is_empty());
        assert_eq!(
            l.renew(b.id, Duration::from_secs(5), now)
                .unwrap()
                .expires_at,
            None
        );
    }

    #[test]
    fn ttl_leases_expire_and_renew() {
        let now = Utc::now();
        let mut l = Leases::default();
        let t = lease(Holder::Ttl, Some(now + chrono::Duration::seconds(60)));
        l.insert(t.clone());
        assert!(l.expired(now).is_empty());
        assert_eq!(l.expired(now + chrono::Duration::seconds(60)).len(), 1);
        l.renew(
            t.id,
            Duration::from_secs(3600),
            now + chrono::Duration::seconds(50),
        )
        .unwrap();
        assert!(l.expired(now + chrono::Duration::seconds(61)).is_empty());
        l.disconnected(7, now);
        assert_eq!(l.of_base(Uuid::nil()), 1);
        assert_eq!(l.for_device(t.device).unwrap().id, t.id);
        assert!(l.remove(t.id).is_some() && l.is_empty());
    }

    #[test]
    fn disconnect_before_pending_insert_still_starts_grace() {
        let now = Utc::now();
        let mut leases = Leases::default();
        leases.connected(7);
        leases.disconnected(7, now);
        let l = lease(Holder::Connection { id: 7 }, None);
        leases.insert_pending(l.clone(), now);
        assert_eq!(leases.get(l.id).unwrap().expires_at, Some(now + grace()));
        assert!(
            leases.expired(now + chrono::Duration::days(1)).is_empty(),
            "pending boot is protected"
        );
        let activated = leases.activate(l.id, Duration::from_secs(60), now).unwrap();
        assert_eq!(activated.expires_at, Some(now + grace()));
        assert_eq!(leases.expired(now + grace()).len(), 1);
    }

    #[test]
    fn rejects_unrepresentable_ttl() {
        assert!(expiry(Utc::now(), Duration::from_secs(u64::MAX)).is_err());
    }
}
