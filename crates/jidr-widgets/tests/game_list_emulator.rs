//! Read and launch a synthetic app on an isolated, temporary emulator.
#![cfg(feature = "emulator")]
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod common;

use serde_json::json;

#[tokio::test(flavor = "multi_thread")]
#[ignore = "requires a separately generated synthetic APK and configured SDK build tools"]
async fn lists_icon_and_launches_synthetic_app() {
    let apk = std::env::var("JIDR_TEST_LIST_APK")
        .expect("set JIDR_TEST_LIST_APK to a synthetic test APK");
    let env = common::Env::boot("jidr-list-test").await;
    env.call("file.install", json!({"apk": apk})).await;
    let result = env.call("app.list", json!({})).await;
    let apps = result["apps"].as_array().unwrap();
    let game = apps
        .iter()
        .find(|v| v["package"] == "ly.jidr.testgame")
        .expect("test game listed");
    assert_eq!(game["name"], "Jidr Test Game");
    let icon = game["icon"].as_str().expect("test icon available");
    assert!(
        std::fs::read(icon)
            .unwrap()
            .starts_with(b"\x89PNG\r\n\x1a\n")
    );
    let launched = env
        .call("app.launch", json!({"package":"ly.jidr.testgame"}))
        .await;
    assert_eq!(launched["launched"], "ly.jidr.testgame");
    assert_eq!(launched["focused"], true);
    env.stop().await;
}
