//! Create a verified, inactive copy for offline recovery validation.
//! This executable never changes the active storage pointer or removes data.
use anyhow::{Context, Result, bail};
use jidr_core::{JidrPaths, storage_lease::StorageLease};
use jidr_sdk::{legacy_barrier::LegacySocketBarrier, migration};
use std::path::PathBuf;

fn main() -> Result<()> {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    if args.len() != 3 {
        bail!("usage: jidr-offline-copy EXPECTED_DATA DESTINATION QEMU_IMG");
    }
    let expected = PathBuf::from(&args[0]);
    let destination = PathBuf::from(&args[1]);
    let qemu = PathBuf::from(&args[2]);
    let source = JidrPaths::discover()?;
    if !expected.is_absolute() || source.data.canonicalize()? != expected.canonicalize()? {
        bail!("discovered source does not match expected data directory");
    }
    let lease = StorageLease::acquire(&source.data).context("acquiring source storage lease")?;
    migration::ensure_avds_quiescent(&source).context("checking source devices")?;
    let barrier =
        LegacySocketBarrier::acquire(&source.socket()).context("guarding source daemon socket")?;
    eprintln!("Creating verified inactive copy; source will be retained.");
    let copy = migration::prepare_copy(&source, &destination, &qemu, &lease, &barrier)
        .context("preparing inactive copy")?;
    let location = migration::publish_copy(&copy, &source, &lease, &barrier)
        .context("publishing inactive copy")?;
    let value = serde_json::json!({"root":location.root,"marker":location.marker,"files":copy.data.files,"bytes":copy.data.bytes,"qcow_disks":copy.qcow_disks,"journal":copy.journal});
    println!("{value}");
    Ok(())
}
