// SPDX-License-Identifier: GPL-3.0-only
// Unit tests for Center/CommandPalette.swift: the action catalog, the fuzzy
// filter and the keyboard selection rules.
import Foundation

func check(_ condition: Bool, _ message: String) {
    if !condition { fatalError("Palette test failed: \(message)") }
}

let english: (String, String) -> String = { _, en in en }
let running = PaletteDevice(id: "run", name: "Pixel", state: .running, android: "Android 15 · API 35", status: "Running")
let stopped = PaletteDevice(id: "stop", name: "Tablet", state: .stopped, android: "Android 13 · API 33", status: "Stopped")
let booting = PaletteDevice(id: "boot", name: "Booting", state: .starting, android: "Android 14 · API 34", status: "Starting")
let busy = PaletteDevice(id: "busy", name: "Busy", state: .busy, android: "Android 16 · API 36", status: "Busy · in use by another client")

var all = PaletteCatalog.items(devices: [running, stopped, booting, busy], sdkReady: true, text: english)
func actions(_ device: PaletteDevice) -> [PaletteAction] {
    all.filter { $0.id.hasSuffix(":\(device.id)") }.map(\.action)
}

// Device entries come first, one "Open" per device.
check(all.first?.kind == .device, "the first entry is a device")
check(all.filter { $0.kind == .device }.count == 4, "one device entry per device")
check(all.first?.title == "Open Pixel", "device entry title is the device name")
check(all.first?.subtitle == "Running", "the device status is the subtitle")
check(all.filter { $0.kind == .device }.allSatisfy { $0.keyboard.isEmpty }, "device entries have no shortcut hint")

// Lifecycle entries follow the device state (the Slint palette rules).
let runningActions = actions(running)
check(runningActions.contains(.stopDevice("run")), "a running device can stop")
check(runningActions.contains(.restartDevice("run")), "a running device can restart")
check(runningActions.contains(.advancedTools("run")), "a running device opens advanced tools")
check(runningActions.contains(.rootTools("run")), "a running device opens the Root tools")
check(runningActions.contains(.installAPK("run")), "a running device installs an APK")
check(!runningActions.contains(.startDevice("run")), "a running device is not started")
check(!runningActions.contains(.deleteDevice("run")), "a running device is not deleted")
check(!runningActions.contains(.editDevice("run")), "a running device is not edited")
let stoppedActions = actions(stopped)
check(stoppedActions.contains(.startDevice("stop")), "a stopped device can start")
check(stoppedActions.contains(.editDevice("stop")), "a stopped device can be edited")
check(stoppedActions.contains(.deleteDevice("stop")), "a stopped device can be deleted")
check(stoppedActions.contains(.snapshots("stop")), "a stopped device opens snapshots")
check(!stoppedActions.contains(.stopDevice("stop")), "a stopped device is not stopped")
check(!stoppedActions.contains(.restartDevice("stop")), "a stopped device is not restarted")
let bootingActions = actions(booting)
check(bootingActions.contains(.stopDevice("boot")), "a booting device can be stopped")
check(!bootingActions.contains(.startDevice("boot")), "a booting device is not started")
check(!bootingActions.contains(.deleteDevice("boot")), "a booting device is not deleted")
let busyActions = actions(busy)
check(!busyActions.contains(.stopDevice("busy")), "a held device offers no lifecycle entry")
check(busyActions.contains(.deviceDetails("busy")), "a held device still opens its details")

// Center-wide entries.
check(all.contains { $0.action == .newDevice && $0.keyboard == "⌘N" }, "new device shows ⌘N")
check(all.contains { $0.action == .settings && $0.keyboard == "⌘," }, "settings shows ⌘,")
check(all.contains { $0.action == .tasks }, "the task list is always available")
check(all.contains { $0.action == .toggleAppearance }, "appearance toggle is available")
check(PaletteCatalog.items(devices: [], sdkReady: false, text: english).contains { $0.action == .setupSDK }, "missing SDK offers setup")
check(!PaletteCatalog.items(devices: [stopped], sdkReady: true, text: english).contains { $0.action == .setupSDK }, "an installed SDK hides setup")

// Ids are unique and stable enough for SwiftUI.
check(Set(all.map(\.id)).count == all.count, "entry ids are unique")
check(PaletteCatalog.actionKey(.startDevice("x")) == "start:x", "action keys are stable")
check(PaletteCatalog.actionKey(.toggleAppearance) == "appearance", "setting keys are stable")

// Fuzzy matching: letters in order, case-insensitive.
check(PaletteCatalog.matches(text: "Open Pixel-ish 6.1", query: "pix61"), "ordered letters match")
check(PaletteCatalog.matches(text: "New device", query: "ND"), "matching is case insensitive")
check(PaletteCatalog.matches(text: "New device", query: "new device"), "spaces in the query are ignored")
check(!PaletteCatalog.matches(text: "New device", query: "dn"), "out-of-order letters do not match")

// Filtering: title and subtitle, contiguous title matches first.
let everything = PaletteCatalog.filter(all, query: "")
check(everything.count == all.count, "an empty query keeps everything")
let pixel = PaletteCatalog.filter(all, query: "pixel")
check(pixel.contains { $0.action == .openDevice("run") }, "a device name filters its entries")
check(pixel.contains { $0.action == .stopDevice("run") }, "device actions match the device name")
let tablet = PaletteCatalog.filter(all, query: "tablet")
check(tablet.allSatisfy { $0.title.lowercased().contains("tablet") || $0.subtitle.lowercased().contains("tablet") || $0.action == .openDevice("stop") }, "tablet entries are relevant")
let ranked = PaletteCatalog.filter(all, query: "set")
if let first = ranked.first {
    check(first.title.lowercased().contains("set"), "a contiguous title match ranks first, got \(first.title)")
} else { fatalError("Palette test failed: expected settings matches") }
check(PaletteCatalog.filter(all, query: "zzz").isEmpty, "no match gives an empty list")

// Selection movement is clamped to the visible rows.
check(PaletteCatalog.move(selection: 0, by: -1, count: 5) == 0, "up stops at the first row")
check(PaletteCatalog.move(selection: 4, by: 1, count: 5) == 4, "down stops at the last row")
check(PaletteCatalog.move(selection: 2, by: 1, count: 5) == 3, "down moves one row")
check(PaletteCatalog.move(selection: 3, by: -1, count: 5) == 2, "up moves one row")
check(PaletteCatalog.move(selection: 7, by: 1, count: 0) == 0, "an empty list selects zero")

// Every English branch is a real translation (no Chinese leaks in the catalog).
for entry in all where entry.title.contains(where: { $0.isChinese }) {
    fatalError("Palette test failed: English catalog leaked \(entry.title)")
}
extension Character {
    var isChinese: Bool { unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
}

print("Palette tests passed")

check(stoppedActions.contains(.advancedTools("stop")) && stoppedActions.contains(.rootTools("stop")), "offline configuration and Root status are discoverable for stopped devices")
