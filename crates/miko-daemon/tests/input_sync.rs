//! The input synchronizer's control plane (D45) on the fake backend.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod common;

use common::{Conn, Harness};
use serde_json::{Value, json};

async fn running(c: &mut Conn, name: &str) -> Value {
    c.ok("device.create", json!({ "name": name, "image": "35" }))
        .await;
    c.run("device.start", json!({ "device": name })).await
}

async fn three(c: &mut Conn) -> [String; 3] {
    let mut ids = Vec::new();
    for name in ["A", "B", "C"] {
        let d = running(c, name).await;
        ids.push(d["id"].as_str().unwrap().to_string());
    }
    [ids[0].clone(), ids[1].clone(), ids[2].clone()]
}

async fn next_state(sub: &mut Conn) -> Value {
    loop {
        let v = sub.read().await;
        if v["method"] == "event" && v["params"]["topic"] == "sync.state" {
            return v["params"]["data"].clone();
        }
    }
}

async fn code(c: &mut Conn, method: &str, params: Value) -> String {
    let e = c.err(method, params).await;
    e["data"]["code"].as_str().unwrap().to_string()
}

async fn subscriber(h: &Harness) -> Conn {
    let mut sub = h.client().await;
    sub.ok("events.subscribe", json!({ "topics": ["sync."] }))
        .await;
    sub
}

#[tokio::test]
async fn a_session_starts_reports_and_stops() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    let [a, b, cc] = three(&mut c).await;
    assert_eq!(c.ok("sync.status", json!({})).await, Value::Null);

    let s = c
        .ok(
            "sync.start",
            json!({ "leader": "A", "followers": ["B", "C"] }),
        )
        .await;
    assert_eq!(s["leader"], a);
    assert_eq!(s["followers"][0]["device"], b);
    assert_eq!(s["followers"][1]["device"], cc);
    assert_eq!(s["followers"][0]["status"], json!({ "state": "ready" }));
    assert!(s["leader_display"]["width"].as_u64().is_some_and(|w| w > 0));
    assert!(
        s["followers"][0]["display"]["width"]
            .as_u64()
            .is_some_and(|w| w > 0)
    );
    assert_eq!(s["options"]["adaptation"], "stretch");
    assert_eq!(s["options"]["lock_followers"], true);
    assert_eq!(c.ok("sync.status", json!({})).await["id"], s["id"]);

    assert_eq!(
        c.ok("sync.stop", json!({})).await,
        json!({ "stopped": true })
    );
    assert_eq!(c.ok("sync.status", json!({})).await, Value::Null);
    assert_eq!(
        c.ok("sync.stop", json!({})).await,
        json!({ "stopped": false })
    );
    h.stop().await;
}

#[tokio::test]
async fn start_validates_its_input() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    three(&mut c).await;
    c.ok("device.create", json!({ "name": "Off", "image": "35" }))
        .await;

    assert_eq!(
        code(
            &mut c,
            "sync.start",
            json!({ "leader": "A", "followers": [] })
        )
        .await,
        "usage"
    );
    assert_eq!(
        code(
            &mut c,
            "sync.start",
            json!({ "leader": "A", "followers": ["A"] })
        )
        .await,
        "usage"
    );
    assert_eq!(
        code(
            &mut c,
            "sync.start",
            json!({ "leader": "A", "followers": ["B", "B"] })
        )
        .await,
        "usage"
    );
    assert_eq!(
        code(
            &mut c,
            "sync.start",
            json!({ "leader": "A", "followers": ["Off"] })
        )
        .await,
        "usage"
    );
    assert_eq!(
        code(
            &mut c,
            "sync.start",
            json!({ "leader": "Off", "followers": ["A"] })
        )
        .await,
        "usage"
    );
    assert_eq!(
        code(
            &mut c,
            "sync.start",
            json!({ "leader": "A", "followers": ["Nope"] })
        )
        .await,
        "not_found"
    );
    assert_eq!(
        code(
            &mut c,
            "sync.start",
            json!({ "leader": "A", "followers": ["B"], "options": { "jitter_ms": 21 } })
        )
        .await,
        "usage"
    );
    assert_eq!(
        code(
            &mut c,
            "sync.start",
            json!({ "leader": "A", "followers": ["B"], "options": { "bogus": 1 } })
        )
        .await,
        "usage"
    );
    assert_eq!(c.ok("sync.status", json!({})).await, Value::Null);
    h.stop().await;
}

#[tokio::test]
async fn only_one_session_at_a_time() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    three(&mut c).await;
    c.ok("sync.start", json!({ "leader": "A", "followers": ["B"] }))
        .await;
    assert_eq!(
        code(
            &mut c,
            "sync.start",
            json!({ "leader": "C", "followers": ["B"] })
        )
        .await,
        "busy"
    );
    c.ok("sync.stop", json!({})).await;
    c.ok("sync.start", json!({ "leader": "C", "followers": ["B"] }))
        .await;
    h.stop().await;
}

#[tokio::test]
async fn start_accepts_partial_options() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    three(&mut c).await;
    let s = c
        .ok(
            "sync.start",
            json!({ "leader": "A", "followers": ["B"], "options":
                { "adaptation": "letterbox", "sync_text": false, "jitter_ms": 7 } }),
        )
        .await;
    assert_eq!(s["options"]["adaptation"], "letterbox");
    assert_eq!(s["options"]["sync_text"], false);
    assert_eq!(s["options"]["sync_keyboard"], true);
    assert_eq!(s["options"]["jitter_ms"], 7);
    h.stop().await;
}

#[tokio::test]
async fn members_and_options_can_change_while_active() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    let [a, b, cc] = three(&mut c).await;
    assert_eq!(
        code(&mut c, "sync.add_follower", json!({ "device": "C" })).await,
        "not_found"
    );
    c.ok("sync.start", json!({ "leader": "A", "followers": ["B"] }))
        .await;

    let s = c.ok("sync.add_follower", json!({ "device": "C" })).await;
    assert_eq!(s["followers"].as_array().unwrap().len(), 2);
    assert_eq!(
        code(&mut c, "sync.add_follower", json!({ "device": "C" })).await,
        "usage"
    );
    assert_eq!(
        code(&mut c, "sync.add_follower", json!({ "device": "A" })).await,
        "usage"
    );

    let s = c.ok("sync.set_leader", json!({ "device": "B" })).await;
    assert_eq!(s["leader"], b);
    let followers: Vec<&Value> = s["followers"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| &f["device"])
        .collect();
    assert_eq!(followers, [&json!(a), &json!(cc)]);
    assert_eq!(
        code(&mut c, "sync.remove_follower", json!({ "device": "B" })).await,
        "usage"
    );

    let s = c.ok("sync.remove_follower", json!({ "device": "C" })).await;
    assert_eq!(s["followers"].as_array().unwrap().len(), 1);
    assert_eq!(
        code(&mut c, "sync.remove_follower", json!({ "device": "C" })).await,
        "not_found"
    );

    let s = c
        .ok(
            "sync.set_options",
            json!({ "options": { "lock_followers": false } }),
        )
        .await;
    assert_eq!(s["options"]["lock_followers"], false);
    assert_eq!(s["options"]["sync_keyboard"], true);
    assert_eq!(
        code(
            &mut c,
            "sync.set_options",
            json!({ "options": { "jitter_ms": 99 } })
        )
        .await,
        "usage"
    );
    assert_eq!(
        c.ok("sync.status", json!({})).await["options"]["lock_followers"],
        false
    );
    h.stop().await;
}

#[tokio::test]
async fn commands_need_an_active_session() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    three(&mut c).await;
    for (method, params) in [
        ("sync.add_follower", json!({ "device": "A" })),
        ("sync.remove_follower", json!({ "device": "A" })),
        ("sync.set_leader", json!({ "device": "A" })),
        ("sync.set_options", json!({ "options": {} })),
        ("sync.report", json!({ "device": "A" })),
    ] {
        assert_eq!(code(&mut c, method, params).await, "not_found", "{method}");
    }
    h.stop().await;
}

#[tokio::test]
async fn removing_the_last_follower_ends_the_session() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    three(&mut c).await;
    let mut sub = subscriber(&h).await;
    c.ok("sync.start", json!({ "leader": "A", "followers": ["B"] }))
        .await;
    assert!(next_state(&mut sub).await["session"].is_object());
    let reply = c.ok("sync.remove_follower", json!({ "device": "B" })).await;
    assert_eq!(reply, Value::Null);
    let ended = next_state(&mut sub).await;
    assert_eq!(ended["session"], Value::Null);
    assert_eq!(ended["reason"], "no follower is left");
    assert_eq!(c.ok("sync.status", json!({})).await, Value::Null);
    h.stop().await;
}

#[tokio::test]
async fn state_events_follow_the_session() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    three(&mut c).await;
    let mut sub = subscriber(&h).await;
    c.ok("sync.start", json!({ "leader": "A", "followers": ["B"] }))
        .await;
    assert_eq!(
        next_state(&mut sub).await["session"]["followers"][0]["status"]["state"],
        "ready"
    );
    c.ok(
        "sync.set_options",
        json!({ "options": { "sync_text": false } }),
    )
    .await;
    assert_eq!(
        next_state(&mut sub).await["session"]["options"]["sync_text"],
        false
    );
    c.ok("sync.stop", json!({})).await;
    let ended = next_state(&mut sub).await;
    assert_eq!(ended["session"], Value::Null);
    assert_eq!(ended["reason"], "stopped");
    h.stop().await;
}

#[tokio::test]
async fn a_stopped_follower_is_dropped_and_a_stopped_leader_ends_the_session() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    let [_, _, cc] = three(&mut c).await;
    let mut sub = subscriber(&h).await;
    c.ok(
        "sync.start",
        json!({ "leader": "A", "followers": ["B", "C"] }),
    )
    .await;
    next_state(&mut sub).await;

    c.ok("device.stop", json!({ "device": "B" })).await;
    let s = next_state(&mut sub).await;
    let followers = s["session"]["followers"].as_array().unwrap();
    assert_eq!(followers.len(), 1);
    assert_eq!(followers[0]["device"], cc);

    c.ok("device.stop", json!({ "device": "A" })).await;
    let ended = next_state(&mut sub).await;
    assert_eq!(ended["session"], Value::Null);
    assert_eq!(ended["reason"], "the leader stopped");
    assert_eq!(c.ok("sync.status", json!({})).await, Value::Null);
    h.stop().await;
}

#[tokio::test]
async fn a_deleted_follower_is_dropped() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    three(&mut c).await;
    let mut sub = subscriber(&h).await;
    c.ok(
        "sync.start",
        json!({ "leader": "A", "followers": ["B", "C"] }),
    )
    .await;
    next_state(&mut sub).await;
    c.ok("device.stop", json!({ "device": "C" })).await;
    next_state(&mut sub).await;
    c.ok("device.delete", json!({ "device": "C" })).await;
    // C was already dropped on stop: the session still holds A and B.
    let s = c.ok("sync.status", json!({})).await;
    assert_eq!(s["followers"].as_array().unwrap().len(), 1);
    h.stop().await;
}

#[tokio::test]
async fn reports_update_followers_and_announce_failures() {
    let h = Harness::start().await;
    let mut c = h.client().await;
    let [_, b, _] = three(&mut c).await;
    let mut sub = subscriber(&h).await;
    c.ok("sync.start", json!({ "leader": "A", "followers": ["B"] }))
        .await;
    next_state(&mut sub).await;

    let s = c
        .ok(
            "sync.report",
            json!({ "device": "B",
                "status": { "state": "lagging" },
                "display": { "width": 720, "height": 1280 },
                "counters": { "forwarded": 12, "dropped": 3 } }),
        )
        .await;
    assert_eq!(s["followers"][0]["status"]["state"], "lagging");
    assert_eq!(s["followers"][0]["display"]["width"], 720);
    assert_eq!(s["followers"][0]["counters"]["dropped"], 3);
    next_state(&mut sub).await;

    c.ok(
        "sync.report",
        json!({ "device": "B", "status": { "state": "error", "message": "bridge gone" } }),
    )
    .await;
    loop {
        let v = sub.read().await;
        if v["params"]["topic"] == "sync.follower_error" {
            assert_eq!(v["params"]["data"]["device"], b);
            assert_eq!(v["params"]["data"]["message"], "bridge gone");
            break;
        }
    }

    // The leader takes a display size but no follower fields.
    let s = c
        .ok(
            "sync.report",
            json!({ "device": "A", "display": { "width": 1080, "height": 2400 } }),
        )
        .await;
    assert_eq!(s["leader_display"]["height"], 2400);
    assert_eq!(
        code(
            &mut c,
            "sync.report",
            json!({ "device": "A", "status": { "state": "ready" } })
        )
        .await,
        "usage"
    );
    assert_eq!(
        code(
            &mut c,
            "sync.report",
            json!({ "device": "B", "display": { "width": 0, "height": 5 } })
        )
        .await,
        "usage"
    );
    assert_eq!(
        code(&mut c, "sync.report", json!({ "device": "C" })).await,
        "not_found"
    );
    h.stop().await;
}
