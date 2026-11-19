//! Image inventory and deletion operate only on unused Miko-owned copies.
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod common;
use common::Harness;
use serde_json::json;

fn image_at(root: &std::path::Path, tag: &str) -> std::path::PathBuf {
    let path = root.join(format!(
        "system-images/android-35/{tag}/{}",
        miko_sdk::host::host_abi()
    ));
    std::fs::create_dir_all(&path).unwrap();
    for file in ["source.properties", "system.img", "ramdisk.img"] {
        std::fs::write(path.join(file), b"synthetic image").unwrap();
    }
    path
}

#[tokio::test]
async fn inventory_and_remove_preserve_external_and_referenced_images() {
    let h = Harness::start().await;
    let private = h.paths.sdk();
    let own = image_at(&private, "google_apis");
    let external = h.tmp.path().join("studio").join(format!(
        "system-images/android-35/google_apis/{}",
        miko_sdk::host::host_abi()
    ));
    let package = format!("35:google_apis:{}", miko_sdk::host::host_abi());
    let mut c = h.client().await;
    let list = c.ok("image.inventory", json!({})).await;
    let own_row = list
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["source"] == "private" && v["tag"] == "google_apis")
        .unwrap();
    assert_eq!(own_row["size_bytes"], 45);
    assert_eq!(own_row["can_delete"], true);
    assert!(
        list.as_array()
            .unwrap()
            .iter()
            .any(|v| v["source"] == "external"
                && v["tag"] == "google_apis"
                && v["can_delete"] == false)
    );
    c.ok(
        "device.create",
        json!({"name":"Uses image", "image": package}),
    )
    .await;
    let rows = c.ok("image.inventory", json!({})).await;
    let row = rows
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["source"] == "private" && v["tag"] == "google_apis")
        .unwrap();
    assert_eq!(row["used_by"][0]["name"], "Uses image");
    assert_eq!(row["can_delete"], false);
    let args = json!({"source":"private", "root":private, "image":package});
    assert_eq!(
        c.err("image.remove", args.clone()).await["data"]["code"],
        "busy"
    );
    assert!(own.exists() && external.exists());
    c.ok("device.delete", json!({"device":"Uses image"})).await;
    c.ok("image.remove", args).await;
    assert!(
        !own.exists() && external.exists(),
        "external SDK copy must remain untouched"
    );
    let denied = c
        .err(
            "image.remove",
            json!({"source":"external", "root":h.tmp.path().join("studio"), "image":package}),
        )
        .await;
    assert_eq!(denied["data"]["code"], "usage");
    assert!(external.exists());
    h.stop().await;
}

#[tokio::test]
async fn image_removal_rejects_stale_roots_and_unsafe_paths() {
    let h = Harness::start().await;
    let private = h.paths.sdk();
    let own = image_at(&private, "google_apis");
    let mut c = h.client().await;
    let pkg = format!("35:google_apis:{}", miko_sdk::host::host_abi());
    let err = c
        .err(
            "image.remove",
            json!({"source":"private", "root":h.tmp.path().join("studio"), "image":pkg}),
        )
        .await;
    assert_eq!(err["data"]["code"], "busy");
    let err = c
        .err(
            "image.remove",
            json!({"source":"private", "root":private, "image":"35:../../escape:arm64-v8a"}),
        )
        .await;
    assert_eq!(err["data"]["code"], "usage");
    assert!(own.exists());
    #[cfg(unix)]
    {
        let alias = own.parent().unwrap().join("symlinked");
        std::os::unix::fs::symlink(&own, &alias).unwrap();
        let err = c
            .err(
                "image.remove",
                json!({"source":"private", "root":private, "image":"35:google_apis:symlinked"}),
            )
            .await;
        assert_eq!(err["data"]["code"], "sdk");
        assert!(own.exists());
    }
    h.stop().await;
}

#[tokio::test]
async fn image_removal_rejects_external_sdk_overlap_and_unverifiable_configuration() {
    let h = Harness::start().await;
    let studio = h.tmp.path().join("studio");
    let private = h.paths.sdk();
    let own = image_at(&private, "google_apis");
    let pkg = format!("35:google_apis:{}", miko_sdk::host::host_abi());
    miko_core::tool_paths::ToolPaths {
        android_sdk: None,
        miko_sdk: Some(studio.clone()),
    }
    .save(&h.paths)
    .unwrap();
    let mut c = h.client().await;
    let error = c
        .err(
            "image.remove",
            json!({"source":"custom", "root":studio, "image":pkg}),
        )
        .await;
    assert_eq!(error["data"]["code"], "sdk");
    assert!(
        studio
            .join(format!(
                "system-images/android-35/google_apis/{}",
                miko_sdk::host::host_abi()
            ))
            .exists()
    );
    // An unavailable configured external SDK must fail closed, not be treated
    // as proof that a writable root is distinct from it.
    std::fs::write(
        miko_core::tool_paths::ToolPaths::path(&h.paths),
        json!({"android_sdk": h.tmp.path().join("missing-sdk"), "miko_sdk": null}).to_string(),
    )
    .unwrap();
    let rows = c.ok("image.inventory", json!({})).await;
    let row = rows
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["source"] == "private" && v["tag"] == "google_apis")
        .unwrap();
    assert_eq!(row["can_delete"], false);
    let error = c
        .err(
            "image.remove",
            json!({"source":"private", "root":private, "image":pkg}),
        )
        .await;
    assert_eq!(error["data"]["code"], "sdk");
    assert!(own.exists());
    h.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn concurrent_creation_and_removal_never_leave_a_device_without_its_image() {
    let h = Harness::start().await;
    let private = h.paths.sdk();
    let own = image_at(&private, "google_apis");
    // Remove the alternate copy so a winning removal cannot fall back to it.
    let external = h.tmp.path().join("studio").join(format!(
        "system-images/android-35/google_apis/{}",
        miko_sdk::host::host_abi()
    ));
    std::fs::remove_dir_all(external).unwrap();
    let pkg = format!("35:google_apis:{}", miko_sdk::host::host_abi());
    let mut create = h.client().await;
    let mut remove = h.client().await;
    let barrier = std::sync::Arc::new(tokio::sync::Barrier::new(2));
    let create_barrier = barrier.clone();
    let create_pkg = pkg.clone();
    let create_task = tokio::spawn(async move {
        create_barrier.wait().await;
        create
            .call(
                "device.create",
                json!({"name":"Concurrent", "image":create_pkg}),
            )
            .await
    });
    let remove_task = tokio::spawn(async move {
        barrier.wait().await;
        remove
            .call(
                "image.remove",
                json!({"source":"private", "root":private, "image":pkg}),
            )
            .await
    });
    let (created, removed) = (create_task.await.unwrap(), remove_task.await.unwrap());
    if created.get("result").is_some() {
        assert!(removed.get("error").is_some() && own.exists());
    } else {
        assert!(removed.get("result").is_some() && !own.exists());
    }
    h.stop().await;
}
