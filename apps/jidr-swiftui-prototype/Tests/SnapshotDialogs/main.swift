// SPDX-License-Identifier: GPL-3.0-only
// Offline checks for the snapshot data helpers (Center/SnapshotData.swift),
// covering the D29 refusal split, sorting, formatting and the save-name rules.
// No SwiftUI, no daemon.
import Foundation

let rows = [
    SnapshotRow(name: "default_boot", folder: "default_boot", quick_boot: true, restorable: true,
                root_mode: nil, magisk_version: nil, created_at: "2026-10-01T10:00:00Z", size_bytes: 0, thumbnail: nil),
    SnapshotRow(name: "Clean install", folder: "Clean-install", quick_boot: false, restorable: false,
                root_mode: "magisk", magisk_version: "30.7", created_at: "2026-10-09T18:40:00Z",
                size_bytes: 2_100_000_000, thumbnail: nil),
    SnapshotRow(name: "Logged in", folder: "Logged-in", quick_boot: false, restorable: true,
                root_mode: "none", magisk_version: nil, created_at: "2026-10-13T11:02:00Z",
                size_bytes: 2_400_000_000, thumbnail: nil),
]

// Quick boot sorts last; named snapshots are newest first.
let sorted = Snapshots.sorted(rows)
assert(sorted.map(\.name) == ["Logged in", "Clean install", "default_boot"])
assert(sorted[2].id == "default_boot")

// Identifiers fall back to the name when the daemon does not send `id`.
let withoutFolder = SnapshotRow(name: "old", folder: nil, quick_boot: false, restorable: true,
                                root_mode: nil, magisk_version: nil, created_at: nil, size_bytes: nil, thumbnail: nil)
assert(withoutFolder.id == "old")

// Root-mode labels and tags (snapshots/mod.rs:17-23, 98-106).
assert(Snapshots.modeName("magisk", language: 1) == "完整 Root")
assert(Snapshots.modeName("adb", language: 0) == "Shell root")
assert(Snapshots.modeName(nil, language: 0) == "Not tagged")
assert(Snapshots.rootTag(mode: "magisk", magisk: "30.7", language: 1) == "保存时模式：完整 Root · Magisk 30.7")
assert(Snapshots.rootTag(mode: "none", magisk: "30.7", language: 0) == "Taken with: Not rooted")

// Sizes and times.
assert(Snapshots.size(2_100_000_000).hasSuffix("GB"))
assert(Snapshots.size(nil) == "")
assert(Snapshots.when(nil, language: 0) == "")
// Times are shown in the local time zone, so check the shape, not the day.
let zhTime = Snapshots.when("2026-10-09T18:40:00Z", language: 1)
assert(zhTime.contains("月") && zhTime.contains(":"), zhTime)
let enTime = Snapshots.when("2026-10-09T18:40:00Z", language: 0)
assert(enTime.contains("Oct") && enTime.contains(":"), enTime)

// Save-name rules (snapshots.rs:95-111).
assert(Snapshots.nameProblem("") == .empty)
assert(Snapshots.nameProblem("   ") == .empty)
assert(Snapshots.nameProblem("a/b") == .forbiddenCharacters)
assert(Snapshots.nameProblem("a:b") == .forbiddenCharacters)
assert(Snapshots.nameProblem(".hidden") == .forbiddenCharacters)
assert(Snapshots.nameProblem("default_boot") == .reserved)
assert(Snapshots.nameProblem(String(repeating: "x", count: 101)) == .tooLong)
assert(Snapshots.nameProblem("Before boss") == nil)
assert(Snapshots.nameProblem("首领之前") == nil)

// The other-snapshot size hint (snapshots/mod.rs:324-358).
let hint = Snapshots.sizesHint(sorted, language: 0)
assert(hint.contains("Log in") == false && hint.contains("2") && hint.contains("GB"), hint)
let noSizes = Snapshots.sizesHint([rows[0]], language: 0)
assert(noSizes.contains("about as much disk"), noSizes)
let one = SnapshotRow(name: "a", folder: nil, quick_boot: false, restorable: true, root_mode: nil,
                      magisk_version: nil, created_at: nil, size_bytes: 2_100_000_000, thumbnail: nil)
assert(Snapshots.sizesHint([one], language: 0).contains("other snapshot is"))

// The banner: a refused snapshot taken under another root mode wins.
let refusedBanner = Snapshots.banner(sorted, deviceMode: "none", language: 1)
assert(refusedBanner.1, "expected a warning banner")
assert(refusedBanner.0.contains("完整 Root") && refusedBanner.0.contains("无 Root"), refusedBanner.0)
let okRows = rows.map { row -> SnapshotRow in
    SnapshotRow(name: row.name, folder: row.folder, quick_boot: row.quick_boot, restorable: true,
                root_mode: row.root_mode, magisk_version: row.magisk_version,
                created_at: row.created_at, size_bytes: row.size_bytes, thumbnail: row.thumbnail)
}
let okBanner = Snapshots.banner(okRows, deviceMode: "none", language: 0)
assert(!okBanner.1)
assert(okBanner.0.contains("all 2 can be restored"), okBanner.0)
assert(Snapshots.banner([], deviceMode: nil, language: 0).0 == "")

// Refusals: another root mode vs incomplete files (D29).
let mismatch = Snapshots.refusal(rows[1], deviceMode: "none", language: 0)
assert(mismatch?.kind == .rootMode(snapshot: "magisk", device: "none", magisk: "30.7"))
assert(Snapshots.refusal(rows[2], deviceMode: "none", language: 0) == nil)
let incomplete = SnapshotRow(name: "broken", folder: nil, quick_boot: false, restorable: false,
                             root_mode: "none", magisk_version: nil, created_at: nil, size_bytes: nil, thumbnail: nil)
assert(Snapshots.refusal(incomplete, deviceMode: "none", language: 0)?.kind == .incomplete)
// An untagged, incomplete snapshot is not a root-mode refusal.
let untagged = SnapshotRow(name: "outside", folder: nil, quick_boot: false, restorable: false,
                           root_mode: nil, magisk_version: nil, created_at: nil, size_bytes: nil, thumbnail: nil)
assert(Snapshots.refusal(untagged, deviceMode: "none", language: 0)?.kind == .incomplete)

// ISO-8601 with fractional seconds decodes too.
assert(Snapshots.created("2026-10-09T18:40:00.123Z") != nil)

print("Snapshot data tests passed")
