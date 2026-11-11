// SPDX-License-Identifier: GPL-3.0-only
// Unit tests for Center/TaskCenter.swift: job decoding, ordering for the task
// list, tones and the row text used by the quit guard and the overlay.
import Foundation

func check(_ condition: Bool, _ message: String) {
    if !condition { fatalError("Tasks test failed: \(message)") }
}

let english: (String, String) -> String = { _, en in en }
let json = """
[
  {"id":"a","kind":"device.start","device":"dev-1","progress":0.4,"message":"Booting Android…","state":"running","created_at":"2026-11-11T00:00:01.250Z"},
  {"id":"b","kind":"image.install","progress":null,"message":"","bytes":{"done":1073741824,"total":2147483648},"state":"running","created_at":"2026-11-11T00:00:03Z"},
  {"id":"c","kind":"root.set","device":"dev-1","progress":0.9,"message":"Verifying root","state":"failed","error":{"message":"adb did not answer"},"created_at":"2026-11-11T00:00:02Z"},
  {"id":"d","kind":"snapshot.save","device":"dev-1","progress":1.0,"message":"Done","state":"succeeded","created_at":"2026-11-10T23:59:59.5Z"},
  {"id":"e","kind":"device.stop","device":"dev-1","progress":0.1,"message":"Stopping","state":"pending","created_at":"2026-11-11T00:00:05Z"},
  {"id":"f","kind":"device.start","device":"dev-1","progress":0.2,"message":"","state":"cancelled","created_at":"2026-11-11T00:00:04Z"}
]
"""
let jobs = try JSONDecoder().decode([JobInfo].self, from: Data(json.utf8))
check(jobs.count == 6, "all jobs decode")
check(jobs[0].device == "dev-1", "device ids decode")
check(jobs[0].progress == 0.4, "progress decodes")
check(jobs[1].progress == nil, "a missing progress stays nil")
check(jobs[1].bytes?.total == 2147483648, "download bytes decode")
check(jobs[2].error?.message == "adb did not answer", "job errors decode")
check(jobs[0].isActive && jobs[4].isActive, "pending and running jobs are active")
check(jobs[2].isTerminal && jobs[3].isTerminal && jobs[5].isTerminal, "finished jobs are terminal")
check(jobs[0].cancellable && !jobs[3].cancellable, "only active jobs are cancellable")
check(TaskCatalog.activeCount(jobs) == 3, "three jobs are active")

// Ordering: active first (newest first), then finished (newest first).
let ordered = TaskCatalog.sorted(jobs)
check(ordered.map(\.id) == ["e", "b", "a", "f", "c", "d"], "active jobs first, then finished, newest first: \(ordered.map(\.id))")
check(ordered.prefix(3).allSatisfy(\.isActive), "the active block comes first")

// Tones.
check(TaskCatalog.tone(for: jobs[0]) == .running, "running tone")
check(TaskCatalog.tone(for: jobs[4]) == .queued, "pending tone")
check(TaskCatalog.tone(for: jobs[2]) == .failed, "failed tone")
check(TaskCatalog.tone(for: jobs[3]) == .done, "succeeded tone")
check(TaskCatalog.tone(for: jobs[5]) == .cancelled, "cancelled tone")

// Row text.
check(TaskCatalog.byteDetail(jobs[1].bytes) == "1.1 / 2.1 GB", "bytes format as GB")
check(TaskCatalog.byteDetail(nil) == nil, "no bytes means no byte detail")
check(TaskCatalog.byteDetail(JobBytesInfo(done: 0, total: 0)) == nil, "a zero total is not shown")
check(TaskCatalog.title(for: jobs[0], deviceName: "Pixel", message: "Booting", text: english) == "Starting device · Pixel", "start title names the device")
check(TaskCatalog.title(for: jobs[1], deviceName: nil, message: "Downloading", text: english) == "Downloading image", "download title")
check(TaskCatalog.title(for: jobs[2], deviceName: nil, message: "x", text: english) == "Setting up root", "root titles are grouped")
check(TaskCatalog.detail(for: jobs[2], step: "Verifying root", text: english) == "adb did not answer", "a failure shows its reason")
check(TaskCatalog.detail(for: jobs[3], step: "Done", text: english) == "Done", "a success shows done")
check(TaskCatalog.detail(for: jobs[4], step: "Stopping", text: english) == "Queued", "a pending job shows queued")
check(TaskCatalog.detail(for: jobs[0], step: "Booting Android…", text: english) == "Booting Android…", "a running job shows its step")

// Daemon RFC 3339 timestamps, with and without fractions.
check(DaemonTime.date("2026-11-11T00:00:03Z") != nil, "plain timestamps parse")
check(DaemonTime.date("2026-11-11T00:00:01.250Z") != nil, "fractional timestamps parse")
check(DaemonTime.date(nil) == nil && DaemonTime.date("") == nil, "empty timestamps are nil")
if let plain = DaemonTime.date("2026-11-11T00:00:03Z"), let fraction = DaemonTime.date("2026-11-11T00:00:01.250Z") {
    check(fraction < plain, "fractions order correctly")
}

print("Tasks tests passed")
