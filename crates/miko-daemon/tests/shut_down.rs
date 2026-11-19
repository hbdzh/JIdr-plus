//! Root cold boots shut down Android before ending the emulator.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod common;

use common::Harness;
use miko_core::DeviceStatus;
use miko_core::provider::DaemonContext;
use serde_json::json;

async fn running(h: &Harness) -> (uuid::Uuid, String) {
    let mut c = h.client().await;
    let d = c
        .ok("device.create", json!({"name": "S", "image": "35"}))
        .await;
    c.run("device.start", json!({"device": "S"})).await;
    (
        d["id"].as_str().unwrap().parse().unwrap(),
        d["avd"].as_str().unwrap().to_owned(),
    )
}

#[tokio::test]
async fn shutdown_skips_exit_save_after_guest_powers_off() {
    let h = Harness::start().await;
    let (id, avd) = running(&h).await;
    let d = h.daemon.state().shut_down_device(id).await.unwrap();
    assert_eq!(d.status, DeviceStatus::Stopped);
    assert_eq!(h.backend.power_offs(), vec![avd.clone()]);
    assert_eq!(h.backend.unsaved_stops(), vec![avd]);
    assert!(h.backend.running().is_empty());
}

#[tokio::test]
async fn shutdown_falls_back_to_normal_stop_when_guest_stays_on() {
    let h = Harness::start().await;
    let (id, avd) = running(&h).await;
    h.backend.stick_power_off();
    let d = h.daemon.state().shut_down_device(id).await.unwrap();
    assert_eq!(d.status, DeviceStatus::Stopped);
    assert_eq!(h.backend.power_offs(), vec![avd]);
    assert!(h.backend.unsaved_stops().is_empty());
    assert!(h.backend.running().is_empty());
}

#[tokio::test]
async fn shutdown_of_stopped_device_does_not_contact_guest() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    let d = c
        .ok("device.create", json!({"name": "S", "image": "35"}))
        .await;
    let id = d["id"].as_str().unwrap().parse().unwrap();
    assert_eq!(
        h.daemon.state().shut_down_device(id).await.unwrap().status,
        DeviceStatus::Stopped
    );
    assert!(h.backend.power_offs().is_empty());
}
