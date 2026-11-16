// SPDX-License-Identifier: GPL-3.0-only
// Deterministic offscreen renderer for the SwiftUI previews.
//
// The bridge fixtures (JIDR_CENTER_FIXTURE / JIDR_PLAYER_FIXTURE) provide fixed
// state, so each case renders with fixed geometry, disabled animations, a fixed
// language/locale and a fixed light or dark appearance. The bundled OFL Geist
// faces are registered with CoreText before the first view is built, matching
// the packaged previews (ATSApplicationFontsPath). Baselines live in
// Tests/golden; --check compares decoded pixels exactly (no tolerance).
import AppKit
import CoreText
import Darwin
import Foundation
import SwiftUI

// MARK: - Case table and geometry

enum SnapshotAppearance: Equatable {
    case dark
    case light

    var name: String { self == .light ? "light" : "dark" }

    var nsAppearance: NSAppearance {
        NSAppearance(named: self == .light ? .aqua : .darkAqua)
            ?? NSAppearance(named: .darkAqua)
            ?? NSAppearance.currentDrawing()
    }
}

struct SnapshotCase {
    enum Kind {
        case center(fixture: String)
        case player
        case auxiliary(page: String)
    }

    let name: String
    let kind: Kind
    /// 0 = English, 1 = Chinese; matches `CenterModel.language`/`PlayerTransport.language`.
    let language: Int
    let appearance: SnapshotAppearance

    var width = 1000
    var height = 640
    var recording = false
    var deselected = false
    var singleDevice = false
    var scriptState: String? = nil

    var localeIdentifier: String { language == 0 ? "en" : "zh-Hans" }
    var languageName: String { language == 0 ? "en" : "zh" }
}

let allCases: [SnapshotCase] = [
    // The five original zh + dark baselines.
    SnapshotCase(name: "center-empty", kind: .center(fixture: "empty"), language: 1, appearance: .dark),
    SnapshotCase(name: "center-populated", kind: .center(fixture: "populated"), language: 1, appearance: .dark),
    SnapshotCase(name: "center-load-failure", kind: .center(fixture: "load-failure"), language: 1, appearance: .dark),
    SnapshotCase(name: "center-long-task", kind: .center(fixture: "long-task"), language: 1, appearance: .dark),
    SnapshotCase(name: "player-running", kind: .player, language: 1, appearance: .dark),
    SnapshotCase(name: "player-running-light", kind: .player, language: 1, appearance: .light),
    SnapshotCase(name: "player-booting-light", kind: .player, language: 1, appearance: .light, scriptState: "booting"),
    SnapshotCase(name: "player-booting-en-dark", kind: .player, language: 0, appearance: .dark, scriptState: "booting"),
    SnapshotCase(name: "player-connecting-light", kind: .player, language: 1, appearance: .light, scriptState: "connecting"),
    SnapshotCase(name: "player-stopped-en-dark", kind: .player, language: 0, appearance: .dark, scriptState: "stopped"),
    SnapshotCase(name: "player-keymap-light", kind: .player, language: 1, appearance: .light, scriptState: "keymap"),
    SnapshotCase(name: "script-recording-light", kind: .player, language: 1, appearance: .light, scriptState: "recording"),
    SnapshotCase(name: "script-playing-light", kind: .player, language: 1, appearance: .light, scriptState: "playing"),
    SnapshotCase(name: "script-management-light", kind: .auxiliary(page: "script-management"), language: 1, appearance: .light, width: 740, height: 480),
    SnapshotCase(name: "script-options-light", kind: .auxiliary(page: "script-options"), language: 1, appearance: .light, width: 300, height: 240),
    // English mode.
    SnapshotCase(name: "center-empty-en", kind: .center(fixture: "empty"), language: 0, appearance: .dark),
    SnapshotCase(name: "center-empty-light", kind: .center(fixture: "empty"), language: 1, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "center-empty-en-minimum", kind: .center(fixture: "empty"), language: 0, appearance: .light, width: 800, height: 550),
    SnapshotCase(name: "center-populated-en", kind: .center(fixture: "populated"), language: 0, appearance: .dark),
    SnapshotCase(name: "center-long-task-en", kind: .center(fixture: "long-task"), language: 0, appearance: .dark),
    SnapshotCase(name: "player-running-en", kind: .player, language: 0, appearance: .dark),
    SnapshotCase(name: "center-populated-en-minimum", kind: .center(fixture: "populated"), language: 0, appearance: .dark, width: 800, height: 550),
    SnapshotCase(name: "center-populated-en-light", kind: .center(fixture: "populated"), language: 0, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "center-recording-en-minimum", kind: .center(fixture: "populated"), language: 0, appearance: .dark, width: 800, height: 550, recording: true),
    SnapshotCase(name: "center-deselected-light", kind: .center(fixture: "populated"), language: 1, appearance: .light, deselected: true),
    SnapshotCase(name: "center-deselected-en-dark", kind: .center(fixture: "populated"), language: 0, appearance: .dark, deselected: true),
    SnapshotCase(name: "settings-general-light", kind: .auxiliary(page: "settings"), language: 1, appearance: .light, width: 700, height: 360),
    SnapshotCase(name: "settings-general-en-dark", kind: .auxiliary(page: "settings"), language: 0, appearance: .dark, width: 700, height: 360),
    SnapshotCase(name: "image-management-light", kind: .auxiliary(page: "image-management"), language: 1, appearance: .light, width: 700, height: 500),
    SnapshotCase(name: "image-management-en-dark", kind: .auxiliary(page: "image-management"), language: 0, appearance: .dark, width: 700, height: 500),
    SnapshotCase(name: "image-management-empty-light", kind: .auxiliary(page: "image-management-empty"), language: 1, appearance: .light, width: 700, height: 500),
    SnapshotCase(name: "image-management-install-light", kind: .auxiliary(page: "image-management-install"), language: 1, appearance: .light, width: 650, height: 580),
    SnapshotCase(name: "sdk-setup-light", kind: .auxiliary(page: "sdk"), language: 1, appearance: .light, width: 650, height: 580),
    SnapshotCase(name: "sdk-setup-en-dark", kind: .auxiliary(page: "sdk"), language: 0, appearance: .dark, width: 650, height: 580),
    SnapshotCase(name: "onboarding-install-footer-active-light", kind: .auxiliary(page: "onboarding-install-footer-active"), language: 1, appearance: .light, width: 650, height: 70),
    SnapshotCase(name: "onboarding-install-footer-failed-en-dark", kind: .auxiliary(page: "onboarding-install-footer-failed"), language: 0, appearance: .dark, width: 650, height: 70),
    SnapshotCase(name: "onboarding-install-active-light", kind: .auxiliary(page: "onboarding-install-active"), language: 1, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "onboarding-install-indeterminate-en-dark", kind: .auxiliary(page: "onboarding-install-indeterminate"), language: 0, appearance: .dark, width: 800, height: 550),
    SnapshotCase(name: "onboarding-install-error-light", kind: .auxiliary(page: "onboarding-install-error"), language: 1, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "onboarding-install-wizard-skipped-light", kind: .auxiliary(page: "onboarding-install-wizard-skipped"), language: 1, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "onboarding-install-skipped-light", kind: .auxiliary(page: "onboarding-install-skipped"), language: 1, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "onboarding-licence-loading-light", kind: .auxiliary(page: "environment-licence-loading"), language: 1, appearance: .light, width: 560, height: 420),
    SnapshotCase(name: "onboarding-licence-light", kind: .auxiliary(page: "environment-licence"), language: 1, appearance: .light, width: 560, height: 420),
    SnapshotCase(name: "onboarding-licence-empty-en-dark", kind: .auxiliary(page: "environment-licence-empty"), language: 0, appearance: .dark, width: 560, height: 420),
    SnapshotCase(name: "onboarding-licence-error-en-dark", kind: .auxiliary(page: "environment-licence-error"), language: 0, appearance: .dark, width: 560, height: 420),
    SnapshotCase(name: "onboarding-environment-light", kind: .auxiliary(page: "onboarding-environment"), language: 1, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "onboarding-ready-light", kind: .auxiliary(page: "onboarding-ready"), language: 1, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "onboarding-ready-reduced-motion-light", kind: .auxiliary(page: "onboarding-ready-reduced-motion"), language: 1, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "onboarding-checking-status-light", kind: .auxiliary(page: "onboarding-checking-status"), language: 1, appearance: .light, width: 320, height: 60),
    SnapshotCase(name: "onboarding-install-other-image-light", kind: .auxiliary(page: "onboarding-install-other-image"), language: 1, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "onboarding-missing-tools-light", kind: .auxiliary(page: "onboarding-missing-tools"), language: 1, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "onboarding-auto-no-images-light", kind: .auxiliary(page: "onboarding-auto-no-images"), language: 1, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "onboarding-environment-no-images-light", kind: .auxiliary(page: "onboarding-environment-no-images"), language: 1, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "onboarding-environment-en-dark", kind: .auxiliary(page: "onboarding-environment"), language: 0, appearance: .dark, width: 1050, height: 700),
    SnapshotCase(name: "onboarding-environment-en-minimum", kind: .auxiliary(page: "onboarding-environment"), language: 0, appearance: .dark, width: 800, height: 550),
    SnapshotCase(name: "new-device-config-light", kind: .auxiliary(page: "new-device-config"), language: 1, appearance: .light, width: 650, height: 580),
    SnapshotCase(name: "new-device-direct-light", kind: .auxiliary(page: "new-device-direct"), language: 1, appearance: .light, width: 650, height: 580),
    SnapshotCase(name: "new-device-direct-no-images-light", kind: .auxiliary(page: "new-device-direct-no-images"), language: 1, appearance: .light, width: 650, height: 580),
    SnapshotCase(name: "new-device-direct-no-tools-light", kind: .auxiliary(page: "new-device-direct-no-tools"), language: 1, appearance: .light, width: 650, height: 580),
    SnapshotCase(name: "onboarding-config-wide-light", kind: .auxiliary(page: "onboarding-config-wide"), language: 1, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "onboarding-config-wide-en-dark", kind: .auxiliary(page: "onboarding-config-wide"), language: 0, appearance: .dark, width: 1050, height: 700),
    SnapshotCase(name: "onboarding-config-en-minimum", kind: .auxiliary(page: "onboarding-config-wide"), language: 0, appearance: .dark, width: 800, height: 550),
    SnapshotCase(name: "onboarding-advanced-wide-light", kind: .auxiliary(page: "onboarding-advanced-wide"), language: 1, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "onboarding-advanced-wide-en-dark", kind: .auxiliary(page: "onboarding-advanced-wide"), language: 0, appearance: .dark, width: 1050, height: 700),
    SnapshotCase(name: "onboarding-custom-resolution-light", kind: .auxiliary(page: "custom-resolution"), language: 1, appearance: .light, width: 420, height: 230),
    SnapshotCase(name: "onboarding-custom-resolution-invalid-en-dark", kind: .auxiliary(page: "custom-resolution-invalid"), language: 0, appearance: .dark, width: 420, height: 230),
    SnapshotCase(name: "onboarding-card-transparency-light", kind: .auxiliary(page: "onboarding-card-transparency"), language: 1, appearance: .light, width: 320, height: 160),
    SnapshotCase(name: "onboarding-card-white-background", kind: .auxiliary(page: "onboarding-card-white-background"), language: 1, appearance: .light, width: 320, height: 160),
    SnapshotCase(name: "tasks-empty-light", kind: .auxiliary(page: "tasks"), language: 1, appearance: .light, width: 480, height: 260),
    SnapshotCase(name: "tasks-active-en-dark", kind: .auxiliary(page: "tasks-active"), language: 0, appearance: .dark, width: 480, height: 264),
    SnapshotCase(name: "command-search-light", kind: .auxiliary(page: "palette"), language: 1, appearance: .light, width: 600, height: 450),
    SnapshotCase(name: "command-search-en-dark", kind: .auxiliary(page: "palette"), language: 0, appearance: .dark, width: 600, height: 450),
    SnapshotCase(name: "recordings-search-light", kind: .auxiliary(page: "recordings"), language: 1, appearance: .light, width: 900, height: 620),
    SnapshotCase(name: "recordings-search-en-dark", kind: .auxiliary(page: "recordings"), language: 0, appearance: .dark, width: 900, height: 620),
    SnapshotCase(name: "center-stopped-light", kind: .auxiliary(page: "center-stopped"), language: 1, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "center-stopped-empty-light", kind: .auxiliary(page: "center-stopped-empty"), language: 1, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "center-many-content-light", kind: .auxiliary(page: "center-many-content"), language: 1, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "center-many-content-wide-light", kind: .auxiliary(page: "center-many-content"), language: 1, appearance: .light, width: 1400, height: 980),
    SnapshotCase(name: "center-stopped-empty-wide-light", kind: .auxiliary(page: "center-stopped-empty"), language: 1, appearance: .light, width: 1400, height: 980),
    SnapshotCase(name: "all-devices-list-light", kind: .auxiliary(page: "all-devices-list"), language: 1, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "all-devices-grid-dark", kind: .auxiliary(page: "all-devices-grid"), language: 0, appearance: .dark, width: 1050, height: 700),
    SnapshotCase(name: "device-preview-states-light", kind: .auxiliary(page: "device-preview-states"), language: 1, appearance: .light, width: 286, height: 110),
    SnapshotCase(name: "device-preview-states-dark", kind: .auxiliary(page: "device-preview-states"), language: 0, appearance: .dark, width: 286, height: 110),
    SnapshotCase(name: "center-stopped-en-minimum", kind: .auxiliary(page: "center-stopped"), language: 0, appearance: .dark, width: 800, height: 550),
    SnapshotCase(name: "settings-defaults-light", kind: .auxiliary(page: "settings-defaults"), language: 1, appearance: .light, width: 700, height: 450),
    SnapshotCase(name: "settings-advanced-en-dark", kind: .auxiliary(page: "settings-advanced"), language: 0, appearance: .dark, width: 700, height: 450),
    SnapshotCase(name: "device-settings-light", kind: .auxiliary(page: "device-settings"), language: 1, appearance: .light, width: 560, height: 620),
    SnapshotCase(name: "center-search-no-results", kind: .auxiliary(page: "search-empty"), language: 0, appearance: .light, width: 800, height: 550),
    SnapshotCase(name: "center-details-error", kind: .auxiliary(page: "details-error"), language: 1, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "tools-root-stopped", kind: .auxiliary(page: "root"), language: 1, appearance: .light, width: 716, height: 500),
    SnapshotCase(name: "tools-camera-stopped-en", kind: .auxiliary(page: "camera"), language: 0, appearance: .dark, width: 716, height: 500),
    SnapshotCase(name: "tools-clipboard-en", kind: .auxiliary(page: "clipboard"), language: 0, appearance: .light, width: 716, height: 500),
    SnapshotCase(name: "snapshots-incomplete-light", kind: .auxiliary(page: "snapshots-incomplete"), language: 1, appearance: .light, width: 600, height: 560),
    SnapshotCase(name: "snapshots-stopped-en", kind: .auxiliary(page: "snapshots"), language: 0, appearance: .dark, width: 600, height: 560),
    SnapshotCase(name: "tools-battery-light", kind: .auxiliary(page: "battery"), language: 1, appearance: .light, width: 716, height: 500),
    SnapshotCase(name: "tools-gps-en-dark", kind: .auxiliary(page: "gps"), language: 0, appearance: .dark, width: 716, height: 500),
    SnapshotCase(name: "tools-network-en-light", kind: .auxiliary(page: "network"), language: 0, appearance: .light, width: 716, height: 500),
    SnapshotCase(name: "tools-calls-light", kind: .auxiliary(page: "calls"), language: 1, appearance: .light, width: 716, height: 500),
    SnapshotCase(name: "tools-fingerprint-light", kind: .auxiliary(page: "fingerprint"), language: 1, appearance: .light, width: 716, height: 500),
    SnapshotCase(name: "tools-developer-en-dark", kind: .auxiliary(page: "developer"), language: 0, appearance: .dark, width: 716, height: 500),
    SnapshotCase(name: "tools-logcat-en-dark", kind: .auxiliary(page: "logcat"), language: 0, appearance: .dark, width: 716, height: 500),
    SnapshotCase(name: "tools-root-en-minimum", kind: .auxiliary(page: "root"), language: 0, appearance: .dark, width: 660, height: 460),
    SnapshotCase(name: "tools-root-full-stopped", kind: .auxiliary(page: "root-full"), language: 1, appearance: .light, width: 716, height: 500),
    SnapshotCase(name: "tools-system-write-en", kind: .auxiliary(page: "root-adb"), language: 0, appearance: .dark, width: 716, height: 620),
    SnapshotCase(name: "tools-system-writable-light", kind: .auxiliary(page: "root-adb-writable"), language: 1, appearance: .light, width: 716, height: 620),
    SnapshotCase(name: "tools-microphone-light", kind: .auxiliary(page: "microphone"), language: 1, appearance: .light, width: 716, height: 560),
    SnapshotCase(name: "tools-microphone-en-dark", kind: .auxiliary(page: "microphone"), language: 0, appearance: .dark, width: 716, height: 560),
    // Light theme.
    SnapshotCase(name: "center-populated-light", kind: .center(fixture: "populated"), language: 1, appearance: .light),
    SnapshotCase(name: "center-single-wide-light", kind: .center(fixture: "populated"), language: 1, appearance: .light, width: 1050, height: 700, singleDevice: true),
    SnapshotCase(name: "center-overview-wide-light", kind: .center(fixture: "populated"), language: 1, appearance: .light, width: 1400, height: 980),
    SnapshotCase(name: "center-overview-wide-en-dark", kind: .center(fixture: "populated"), language: 0, appearance: .dark, width: 1400, height: 980),
    SnapshotCase(name: "center-multiple-wide-light", kind: .center(fixture: "populated"), language: 1, appearance: .light, width: 1400, height: 700),
    SnapshotCase(name: "center-load-failure-light", kind: .center(fixture: "load-failure"), language: 1, appearance: .light),
]

// Small enough that every baseline stays well under 150 KB while preserving the
// real layout: the center window is 1050×700. The player content is the device
// screen plus the 48pt side rail: the fixture streams 360×640 (aspect 0.5625),
// so 768pt of height needs 432pt of screen plus 48pt of sidebar.
let playerSize = (width: 480, height: 768)


// MARK: - CLI

struct Options {
    var update = false
    var check = false
    var only: [String] = []
    var all = false
    var list = false
    var centerBridge = ""
    var playerBridge = ""
    var uiFixture = ""
    var golden = ""
    var fonts = ""
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("snapshot: " + message + "\n").utf8))
    exit(2)
}

var options = Options()
var argumentIndex = 1
let arguments = CommandLine.arguments
while argumentIndex < arguments.count {
    let argument = arguments[argumentIndex]
    func value(_ name: String) -> String {
        argumentIndex += 1
        guard argumentIndex < arguments.count else { fail("\(name) needs a value") }
        return arguments[argumentIndex]
    }
    switch argument {
    case "--update": options.update = true
    case "--check": options.check = true
    case "--only": options.only.append(value("--only"))
    case "--all": options.all = true
    case "--list": options.list = true
    case "--center-bridge": options.centerBridge = value("--center-bridge")
    case "--player-bridge": options.playerBridge = value("--player-bridge")
    case "--ui-fixture": options.uiFixture = value("--ui-fixture")
    case "--golden": options.golden = value("--golden")
    case "--fonts": options.fonts = value("--fonts")
    default: fail("unknown argument \(argument); usage: snapshot --update|--check (--only CASE ...|--all) [--list] --center-bridge PATH --player-bridge PATH --golden DIR [--fonts DIR]")
    }
    argumentIndex += 1
}
// Choose the scope before creating NSApplication, fixtures or any windows.
guard !options.all || options.only.isEmpty else { fail("--all and --only cannot be combined") }
var selected: [SnapshotCase]
if !options.only.isEmpty {
    let unknown = options.only.filter { name in !allCases.contains { $0.name == name } }
    guard unknown.isEmpty else { fail("unknown case(s): \(unknown.joined(separator: ", ")); use --list for known cases") }
    let requested = Set(options.only)
    selected = allCases.filter { requested.contains($0.name) }
} else if options.all || options.list {
    selected = allCases
} else {
    fail("choose --only CASE (repeatable) for a local change, or --all for the full matrix")
}
if options.list {
    selected.forEach { print($0.name) }
    exit(0)
}
guard options.update != options.check else { fail("pass exactly one of --update or --check") }
guard !options.centerBridge.isEmpty, !options.playerBridge.isEmpty, !options.golden.isEmpty else {
    fail("--center-bridge, --player-bridge and --golden are required")
}
let goldenDirectory = URL(fileURLWithPath: options.golden, isDirectory: true)

// MARK: - Bundled fonts and deterministic application setup

/// Register the OFL Geist/Geist Mono faces with CoreText before any view is
/// built. The packaged previews get this for free from ATSApplicationFontsPath;
/// a bare swiftc executable does not, and `WbFontResolver` caches its fallback
/// on first use. Prefers the explicit `--fonts` path, then the built preview
/// bundles, then reports that the system font fallback is in use.
func registerBundledFonts(explicitPath: String) {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var candidates: [String] = []
    if !explicitPath.isEmpty { candidates.append(explicitPath) }
    candidates.append(root.appendingPathComponent("apps/jidr-swiftui/Resources/fonts").path)
    candidates.append(root.appendingPathComponent("target/swiftui-center/Jidr.app/Contents/Resources/fonts").path)
    for directory in candidates {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
        let files = names.filter { $0.hasSuffix(".ttf") || $0.hasSuffix(".otf") }.sorted()
        guard !files.isEmpty else { continue }
        var registered = 0
        var firstFailure: String?
        for name in files {
            var error: Unmanaged<CFError>?
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                registered += 1
            } else if firstFailure == nil {
                firstFailure = name
            }
        }
        let live = WbFontResolver.usesBundledFonts
        print("snapshot: registered \(registered)/\(files.count) font file(s) from \(directory); bundled Geist/Geist Mono live: \(live)")
        if live {
            let face = WbFontResolver.resolvedPostScriptName(family: .ui, weight: .regular) ?? "system"
            print("snapshot: UI face = \(face)")
            return
        }
        if let firstFailure {
            fputs("snapshot: warning: \(firstFailure) did not provide a resolvable PostScript face\n", stderr)
        }
    }
    fputs("snapshot: no bundled Geist fonts found (apps/jidr-swiftui/Resources/fonts); rendering with the system font fallback\n", stderr)
}

registerBundledFonts(explicitPath: options.fonts)

// Pin overlay scrollers for this process only. The host's scrollbar preference
// otherwise changes the width of selected rows without any source change.
var snapshotDefaults = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
snapshotDefaults["AppleShowScrollBars"] = "WhenScrolling"
UserDefaults.standard.setVolatileDomain(snapshotDefaults, forName: UserDefaults.argumentDomain)

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
application.appearance = NSAppearance(named: .darkAqua)
NSAnimationContext.beginGrouping()
NSAnimationContext.current.duration = 0
NSAnimationContext.current.allowsImplicitAnimation = false
NSAnimationContext.endGrouping()

func pump(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

func waitUpTo(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        pump(0.02)
    }
    return condition()
}

func require(_ condition: Bool, _ message: String) {
    if !condition { fail(message) }
}

// MARK: - Offscreen capture

final class Canvas {
    let width: Int
    let height: Int
    private let appearance: SnapshotAppearance
    private var window: NSWindow?
    private var hosting: NSHostingView<AnyView>?

    init(width: Int, height: Int, appearance: SnapshotAppearance) {
        self.width = width
        self.height = height
        self.appearance = appearance
    }

    func mount<V: View>(_ view: V) {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.appearance = appearance.nsAppearance
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance.nsAppearance
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        // Keep the hosting window unordered: cacheDisplay renders the view tree
        // without putting a surface on the user's desktop or taking focus.
        self.window = window
        self.hosting = hosting
        settle()
    }

    func settle(_ seconds: TimeInterval = 0.3) {
        guard let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        pump(seconds)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        require(!NSApplication.shared.isActive && NSApplication.shared.activationPolicy() == .prohibited,
                "snapshot renderer must never activate")
        require(window?.isVisible == false && window?.isKeyWindow == false && window?.isMainWindow == false,
                "snapshot canvas must stay hidden and unfocused")
    }

    /// Render the mounted view at exactly width×height pixels (1× backing).
    func capture() -> NSBitmapImageRep {
        guard let hosting, let window, window.contentView === hosting else {
            fail("canvas is not mounted")
        }
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { fail("cannot allocate a \(width)x\(height) bitmap") }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    func inspect(_ check: (NSView, NSWindow) -> Void) {
        guard let hosting, let window else { fail("canvas is not mounted") }
        check(hosting, window)
    }

    func unmount() {
        window?.orderOut(nil)
        window?.contentView = nil
        window?.close()
        window = nil
        hosting = nil
    }
}

func pngData(_ rep: NSBitmapImageRep) -> Data {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fail("cannot encode a PNG")
    }
    return data
}

/// Normalised sRGB RGBA bytes, so the comparison is independent of the PNG
/// encoder's colour chunk choices and only pixel differences can fail.
func rgbaBytes(_ image: CGImage) -> (width: Int, height: Int, bytes: [UInt8]) {
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB() as CGColorSpace? else {
        fail("cannot create a colour space")
    }
    bytes.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { fail("cannot create a comparison context") }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return (width, height, bytes)
}

func pixels(_ rep: NSBitmapImageRep) -> (width: Int, height: Int, bytes: [UInt8]) {
    guard let image = rep.cgImage else { fail("bitmap has no CGImage") }
    return rgbaBytes(image)
}

// MARK: - Rendering each case

let fixtureCases = ["empty", "populated", "load-failure", "long-task", "disconnect"]

func renderCenter(_ snapshotCase: SnapshotCase) -> NSBitmapImageRep {
    guard case .center(let fixture) = snapshotCase.kind else { fail("\(snapshotCase.name) is not a center case") }
    require(fixtureCases.contains(fixture), "unknown center fixture \(fixture)")
    setenv("JIDR_CENTER_FIXTURE", fixture, 1)
    defer { unsetenv("JIDR_CENTER_FIXTURE") }
    let model: CenterModel
    do {
        model = try CenterModel(center: options.centerBridge, bridge: options.playerBridge)
    } catch {
        fail("cannot start the center bridge for fixture \(fixture): \(error)")
    }
    defer { model.closePlayers(); model.close() }
    let language = snapshotCase.language
    switch fixture {
    case "empty":
        require(waitUpTo(5, until: { model.connection.isOnline && model.deviceListLoaded && model.devices.isEmpty }),
                "fixture empty: the device list never loaded")
    case "populated":
        require(waitUpTo(5, until: {
            model.connection.isOnline && model.deviceListLoaded && model.devices.count == 2 && model.details != nil
                && !model.appsLoading && (!model.apps.isEmpty || model.appsError != nil)
        }), "fixture populated: details or the app list never loaded")
    case "load-failure":
        require(waitUpTo(5, until: { model.connection.isOnline && !model.notice.isEmpty }),
                "fixture load-failure: no failure notice")
        pump(0.2)
    case "long-task":
        require(waitUpTo(5, until: {
            model.connection.isOnline && model.deviceListLoaded && model.devices.count == 1 && model.details != nil
        }), "fixture long-task: the device list or details never loaded")
        guard let id = model.selected else { fail("fixture long-task: no device selected") }
        // Language drives the localized job-progress text, so switch it before
        // the operation starts.
        model.language = language
        // `start()` opens a booting player window now; the center-side job
        // progress is the same `operation` path, so drive it directly to keep
        // this case a single deterministic window.
        model.operation("device.start", id: id)
        let progressText = language == 0 ? "Rebooting" : "正在重启设备"
        require(waitUpTo(5, until: {
            model.progress(for: id) == progressText && model.activeJobs.count == 1
        }), "fixture long-task: no in-flight job progress or task button")
        pump(0.2)
    default:
        fail("unsupported center fixture \(fixture)")
    }
    // Apply the matrix language/appearance only after the async state loaded, so
    // every view re-evaluates with the requested deterministic values.
    model.language = language
    if snapshotCase.singleDevice { model.devices = Array(model.devices.prefix(1)) }
    if snapshotCase.recording, let id = model.selected { model.recording.insert(id) }
    if snapshotCase.deselected { model.setDeviceSelection(nil) }
    model.appearance = snapshotCase.appearance == .light ? 1 : 2
    pump(0.1)
    let canvas = Canvas(width: snapshotCase.width, height: snapshotCase.height, appearance: snapshotCase.appearance)
    canvas.mount(CenterView(model: model))
    canvas.settle(0.4)
    if fixture == "empty" {
        model.present(.newDevice)
        require(model.sheet == nil, "initial device creation stays in the main window")
        canvas.inspect { host, window in
            require(window.attachedSheet == nil, "initial onboarding is not presented as a sheet")
            require(window.toolbar == nil, "borderless snapshot canvases do not install window chrome")
            require(!nativeDescendants(host, NSSplitView.self).contains { $0.delegate is NSSplitViewController },
                    "empty onboarding must not contain a navigation sidebar")
            require(!nativeDescendants(host, NSSearchField.self).contains { $0.identifier?.rawValue == "device-search" },
                    "empty onboarding must not contain device search")
            if #available(macOS 26.0, *) {
                require(nativeDescendants(host, NSGlassEffectView.self).contains { $0.accessibilityIdentifier() == "onboarding-glass" },
                        "onboarding uses the system Liquid Glass effect")
            } else {
                require(nativeDescendants(host, NSVisualEffectView.self).contains { $0.accessibilityIdentifier() == "onboarding-glass" && $0.blendingMode == .behindWindow },
                        "older systems use a behind-window material")
            }
        }
        let previousWindow = model.centerWindow
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 550),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        let chrome = CenterToolbarController(model: model, window: window)
        guard let onboardingToolbar = window.toolbar else { fail("onboarding toolbar is missing") }
        if #available(macOS 15.0, *) {
            let actions = onboardingToolbar.items.filter { $0.itemIdentifier != .flexibleSpace }
            require(onboardingToolbar.isVisible && actions.count == 4 && actions.allSatisfy { $0.isHidden && !$0.isEnabled },
                    "onboarding keeps its native title bar but hides toolbar actions")
        } else {
            require(onboardingToolbar.isVisible && onboardingToolbar.items.isEmpty, "older systems use an empty onboarding toolbar")
        }
        require(!window.isOpaque && window.backgroundColor == .clear, "onboarding window exposes its glass backdrop")
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        guard let close = window.standardWindowButton(.closeButton),
              let minimize = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton) else { fail("window controls are missing") }
        let onboardingButtons = [close, minimize, zoom].map { $0.convert($0.bounds, to: nil) }
        model.deviceListLoaded = false
        pump(0.2)
        guard let toolbar = window.toolbar else { fail("device center toolbar is missing") }
        require(toolbar.isVisible && toolbar.items.map(\.itemIdentifier) == chrome.toolbarAllowedItemIdentifiers(toolbar),
                "all toolbar actions return outside onboarding")
        if #available(macOS 15.0, *) {
            require(toolbar.items.allSatisfy { !$0.isHidden }, "device center actions are visible")
            require(toolbar.items.filter { $0.itemIdentifier != .flexibleSpace }.allSatisfy(\.isEnabled),
                    "device center actions are enabled again")
        }
        if #available(macOS 26.0, *) {
            require(!window.isOpaque && window.backgroundColor == .clear, "custom sidebar glass needs a transparent window")
        } else {
            require(window.isOpaque && window.backgroundColor != .clear, "older device center restores its window background")
        }
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        guard let centerClose = window.standardWindowButton(.closeButton),
              let centerMinimize = window.standardWindowButton(.miniaturizeButton),
              let centerZoom = window.standardWindowButton(.zoomButton) else { fail("device center window controls are missing") }
        let centerButtons = [centerClose, centerMinimize, centerZoom].map { $0.convert($0.bounds, to: nil) }
        require(zip(onboardingButtons, centerButtons).allSatisfy { pair in abs(pair.0.minX - pair.1.minX) < 0.5 && abs(pair.0.midY - pair.1.midY) < 0.5 },
                "onboarding and device center window controls have matching positions")
        model.deviceListLoaded = true
        pump(0.2)
        if #available(macOS 15.0, *) {
            require(window.toolbar === onboardingToolbar && onboardingToolbar.items.filter { $0.itemIdentifier != .flexibleSpace }.allSatisfy(\.isHidden),
                    "toolbar actions are hidden when onboarding returns")
        } else { require(window.toolbar === onboardingToolbar && onboardingToolbar.items.isEmpty, "older systems restore the empty toolbar") }
        require(!window.isOpaque && window.backgroundColor == .clear, "returning to onboarding restores the glass window")
        if snapshotCase.name == "center-empty-light" {
            let legacyWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 550),
                                        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            let legacyChrome = CenterToolbarController(model: model, window: legacyWindow, forceLegacyToolbar: true)
            guard let emptyToolbar = legacyWindow.toolbar else { fail("legacy onboarding toolbar missing") }
            require(emptyToolbar.isVisible && emptyToolbar.items.isEmpty, "legacy onboarding retains an empty title bar")
            func legacyTrafficLights() -> [NSRect] {
                legacyWindow.contentView?.superview?.layoutSubtreeIfNeeded()
                return [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap {
                    guard let button = legacyWindow.standardWindowButton($0) else { return nil }
                    return button.convert(button.bounds, to: nil)
                }
            }
            let emptyFrames = legacyTrafficLights()
            model.deviceListLoaded = false
            pump(0.2)
            guard let libraryToolbar = legacyWindow.toolbar else { fail("legacy library toolbar missing") }
            require(libraryToolbar !== emptyToolbar && libraryToolbar.items.map(\.itemIdentifier) == legacyChrome.toolbarAllowedItemIdentifiers(libraryToolbar),
                    "legacy device center restores its actions")
            let libraryFrames = legacyTrafficLights()
            require(emptyFrames.count == 3 && libraryFrames.count == 3 && zip(emptyFrames, libraryFrames).allSatisfy {
                abs($0.0.minX - $0.1.minX) < 0.5 && abs($0.0.midY - $0.1.midY) < 0.5
            }, "legacy title bars align their traffic lights")
            model.deviceListLoaded = true
            pump(0.2)
            require(legacyWindow.toolbar === emptyToolbar, "legacy onboarding restores its empty toolbar")
        }
        model.centerWindow = previousWindow
        canvas.settle(0.2)
    }
    let rep = canvas.capture()
    canvas.unmount()
    pump(0.05)
    return rep
}

func renderPlayer(_ snapshotCase: SnapshotCase) -> NSBitmapImageRep {
    setenv("JIDR_PLAYER_FIXTURE", "1", 1)
    defer { unsetenv("JIDR_PLAYER_FIXTURE") }
    let transport = PlayerTransport()
    transport.language = snapshotCase.language
    let canvas = Canvas(width: playerSize.width, height: playerSize.height, appearance: snapshotCase.appearance)
    canvas.mount(ContentView(transport: transport, mapping: transport.mapping, sidebar: SidebarState())
        .background(PlayerChromeMaterial()))
    // Shared material, transparent hosting surfaces and live appearance changes
    // are checked on the real window in Tests/PlayerLifecycle. These hidden
    // snapshots cover the native fallback; WindowServer blur needs screen review.
    if ["booting", "connecting", "stopped"].contains(snapshotCase.scriptState) {
        if snapshotCase.scriptState == "booting" {
            transport.applyLaunchState(.booting(progress: 0.3, message: snapshotCase.language == 0 ? "Starting 30%" : "正在启动 30%"))
        } else if snapshotCase.scriptState == "stopped" {
            transport.applyLaunchState(.stopped(reason: ""))
        }
        canvas.settle(0.3)
        let rep = canvas.capture()
        canvas.unmount()
        return rep
    }
    // ContentView.onAppear installs transport.onStatus; wait for it so the
    // transient connecting notice can later be cleared deterministically.
    pump(0.2)
    require(waitUpTo(3, until: { transport.onStatus != nil }),
            "player fixture: the player window did not install its status handler")
    do {
        try transport.start(device: "fixture-device", width: 1080, height: 2400,
                            executable: options.playerBridge, quality: 1)
    } catch {
        fail("cannot start the player fixture bridge: \(error)")
    }
    require(waitUpTo(8, until: { transport.linkState.isRunning && transport.frameWidth > 0 }),
            "player fixture: the frame stream never reached the running state")
    if snapshotCase.scriptState == "keymap" {
        let home = ProcessInfo.processInfo.environment["JIDR_HOME"] ?? NSTemporaryDirectory()
        transport.mapping.load(path: URL(fileURLWithPath: home).appendingPathComponent("fixture-keymap.json").path)
        require(transport.mapping.begin(), "key mapping fixture begins editing")
    }
    // The fixture sends three identical frames; wait for the stream to settle so
    // the capture never sees a partially updated canvas.
    pump(0.4)
    if snapshotCase.scriptState == "recording" {
        transport.applyScriptNotification(["op": "record", "state": "recording", "event_count": 16])
    } else if snapshotCase.scriptState == "playing" {
        transport.applyScriptNotification(["op": "play", "state": "playing", "loop": 2, "count": 3, "name": "日常登录"])
    }
    // The connecting status is a transient notice bubble (six-second timer). It
    // is not part of the running-window state, so clear it deterministically
    // instead of racing the timer.
    transport.onStatus?("")
    pump(0.2)
    canvas.settle(0.2)
    let rep = canvas.capture()
    if snapshotCase.scriptState == "recording" {
        require(transport.scriptRecordedEvents == 16, "recorded event count reaches the player")
        transport.scriptRecordStop(name: "Fixture recording")
        require(transport.scriptRecordFinishing, "saving is pending until the bridge responds")
        transport.applyScriptNotification(["op": "record", "state": "saved", "script": [
            "id": "fixture", "name": "Fixture recording", "duration_ms": 1000,
            "event_count": 16, "created_at": "2026-11-13T14:35:00Z"
        ]])
        require(!transport.scriptRecordFinishing && transport.scriptRecording == .idle,
                "saved notification closes recording controls")
        require(transport.scripts.contains(where: { $0.id == "fixture" }), "saved recording appears in the list")
    } else if snapshotCase.scriptState == "playing" {
        require(transport.scriptPlayback == .playing && transport.scriptPlaybackLoop == 2,
                "playback status and loop reach the player")
        transport.applyScriptNotification(["op": "play", "state": "finished"])
        require(transport.scriptPlayback == .idle, "completed playback removes controls")
    }
    transport.stop()
    canvas.unmount()
    pump(0.05)
    return rep
}

func nativeDescendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
    ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { nativeDescendants($0, type) }
}


/// Check actual hosted controls while every window remains unordered. These
/// regressions are scoped to Device tools, and never drive the user's desktop.
func validateTools(_ canvas: Canvas, selection: DeviceToolsSelection, page: String) {
    canvas.inspect { host, window in
        let tables = nativeDescendants(host, NSTableView.self)
        require(tables.count == 1 && tables[0] is CompactDeviceToolsTableView && tables[0].style == .sourceList && tables[0].rowHeight == 32 && !tables[0].floatsGroupRows,
                "device tools must use the native system sidebar with 32-point rows and no floating headers")
        guard let split = nativeDescendants(host, NSSplitView.self).first(where: { $0.delegate is NSSplitViewController }),
              let splitController = split.delegate as? NSSplitViewController,
              splitController.splitViewItems.contains(where: { $0.behavior == .sidebar }) else {
            fail("device tools must use the system navigation sidebar")
        }
        if #available(macOS 26.0, *) {
            var ancestor = tables[0].superview
            var hasSystemGlass = false
            while let view = ancestor {
                if view is NSGlassEffectView { hasSystemGlass = true; break }
                ancestor = view.superview
            }
            require(hasSystemGlass, "system glass surrounds the device tools sidebar")
            guard let detail = splitController.splitViewItems.last?.viewController.view,
                  let bitmap = detail.bitmapImageRepForCachingDisplay(in: detail.bounds) else {
                fail("device tools detail background cannot be inspected")
            }
            require(detail.safeAreaInsets.left > 0, "detail extends beneath the system sidebar")
            detail.cacheDisplay(in: detail.bounds, to: bitmap)
            let x = Int(detail.safeAreaInsets.left * 0.5 * CGFloat(bitmap.pixelsWide) / detail.bounds.width)
            guard let underSidebar = bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2) else {
                fail("device tools sidebar background sample is missing")
            }
            require(underSidebar.alphaComponent < 0.01, "detail background does not cover system sidebar glass")
        }
        let original = window.frame
        let table = tables[0]
        require(abs((table.enclosingScrollView?.bounds.width ?? 0) - 168) < 1, "sidebar keeps the approved compact width")
        if let cell = table.view(atColumn: 0, row: table.selectedRow, makeIfNecessary: true) as? NSTableCellView {
            require(cell.textField?.font?.pointSize == 13, "sidebar labels use normal macOS sidebar typography")
            guard let row = table.rowView(atRow: table.selectedRow, makeIfNecessary: true) else { fail("system selection row is missing") }
            require(type(of: row) == NSTableRowView.self, "selection must use AppKit's standard row drawing instead of a custom narrow fill")
            require(row.bounds.height >= 32, "selected rows must retain the standard thicker hit/highlight area")
            cell.backgroundStyle = .emphasized
            require(cell.backgroundStyle == .emphasized && cell.imageView?.cell?.backgroundStyle == .emphasized,
                    "native emphasis propagates to both the text and icon cells")
            require(cell.textField?.textColor == NSColor.alternateSelectedControlTextColor,
                    "active selected text follows the system selection text color")
            cell.backgroundStyle = .normal
            require(cell.textField?.textColor == NSColor.labelColor && cell.imageView?.contentTintColor == nil,
                    "inactive selection uses system label colors without fixed custom tints")
            require(cell.imageView?.image?.isTemplate == true, "symbols must follow system emphasis, not a fixed palette")
        } else { fail("selected native sidebar label is missing") }
        let layout = canvas.capture()
        if let top = layout.colorAt(x: 3, y: 18)?.usingColorSpace(.sRGB),
           let bottom = layout.colorAt(x: 3, y: layout.pixelsHigh - 18)?.usingColorSpace(.sRGB) {
            require(abs(top.redComponent - bottom.redComponent) < 0.01 && abs(top.greenComponent - bottom.greenComponent) < 0.01 && abs(top.blueComponent - bottom.blueComponent) < 0.01,
                    "the sidebar surface continues through the header and footer")
        }
        let detailScrolls = nativeDescendants(host, NSScrollView.self).filter { scroll in
            guard scroll !== table.enclosingScrollView else { return false }
            return scroll.convert(scroll.bounds, to: host).minX + scroll.safeAreaInsets.left >= 167
        }
        guard let pageScroll = detailScrolls.max(by: { $0.bounds.width < $1.bounds.width }) else {
            fail("device tools detail page has no scroll viewport")
        }
        let pageRect = pageScroll.convert(pageScroll.bounds, to: host)
        require(abs(pageRect.minX + pageScroll.safeAreaInsets.left - 168) <= 2 && abs(pageRect.maxX - host.bounds.maxX) <= 2,
                "detail scrolling spans the entire page; the scroll indicator must stay at its far-right edge")
        if page == "network" {
            require(detailScrolls.count == 1, "network settings must not create nested form-area scrollers")
            let clip = pageScroll.contentView
            let initialOrigin = clip.bounds.origin
            require((pageScroll.documentView?.bounds.height ?? 0) > clip.bounds.height,
                    "the network page must scroll as one long document")
            clip.scroll(to: NSPoint(x: initialOrigin.x, y: initialOrigin.y + 100))
            pageScroll.reflectScrolledClipView(clip)
            canvas.settle(0.05)
            require(clip.bounds.origin.y > initialOrigin.y && window.frame == original,
                    "scrolling the page moves its full document without resizing the window")
            clip.scroll(to: initialOrigin)
            pageScroll.reflectScrolledClipView(clip)
        }
        if page == "battery" {
            let charge = nativeDescendants(host, NSTextField.self).first { $0.isEditable && $0.stringValue == "75" }
            require(charge != nil && (charge?.bounds.width ?? 0) >= 100, "battery input must stay readable in the detail form")
            let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: "\u{f701}",
                                      charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125)!
            tables[0].keyDown(with: down)
            canvas.settle(0.1)
            require(selection.section == 1, "native sidebar arrow navigation selects GPS")
            require(window.frame == original, "keyboard navigation keeps the panel frame unchanged")
            for destination in [2, 5, 6] {
                table.keyDown(with: down)
                canvas.settle(0.05)
                require(selection.section == destination, "arrow navigation skips nonselectable group headings")
                require(window.frame == original, "cross-group keyboard navigation never resizes the window")
            }
        }
        if page == "camera" {
            let popups = nativeDescendants(host, NSPopUpButton.self)
            guard let back = popups.first(where: { $0.accessibilityLabel() == "Back camera" }),
                  let front = popups.first(where: { $0.accessibilityLabel() == "Front camera" }) else {
                fail("detail form must expose both camera controls")
            }
            let backRect = back.convert(back.bounds, to: host)
            let frontRect = front.convert(front.bounds, to: host)
            require(abs(backRect.maxX - frontRect.maxX) < 1 && backRect.width >= 175,
                    "camera rows must align their controls on the right")
            require(back.isEnabled && front.isEnabled, "stopped devices must still allow editing camera sources")
            back.selectItem(withTitle: "Emulated")
            require(NSApp.sendAction(back.action!, to: back.target, from: back), "native camera popup action is handled")
            pump(0.05)
            for section in [4, 8] {
                selection.section = section
                canvas.settle(0.1)
                require(window.frame == original, "changing sidebar selection must never resize the panel: \(window.frame) != \(original) for \(section)")
            }
            let restored = nativeDescendants(host, NSPopUpButton.self).first { $0.accessibilityLabel() == "Back camera" }
            require(restored?.selectedItem?.representedObject as? String == "emulated", "camera draft survives switching to Root and back")
            if let home = ProcessInfo.processInfo.environment["JIDR_HOME"],
               let requests = try? String(contentsOfFile: home + "/requests.jsonl", encoding: .utf8) {
                let writes = requests.split(separator: "\n").contains { line in
                    guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return false }
                    return request["method"] as? String == "camera.set"
                }
                require(!writes, "editing and switching camera drafts must never save them automatically")
            }
        }
        require(!window.isVisible && !NSApp.isActive, "Device tools regressions must remain hidden")
    }
}

func renderAuxiliary(_ snapshotCase: SnapshotCase, page: String) -> NSBitmapImageRep {
    require(!options.uiFixture.isEmpty, "auxiliary views require --ui-fixture")
    if page == "new-device-direct-no-images" || page == "onboarding-environment-no-images" || page == "onboarding-auto-no-images" { setenv("JIDR_UI_NO_IMAGES", "1", 1) }
    defer { unsetenv("JIDR_UI_NO_IMAGES") }
    if page == "center-many-content" { setenv("JIDR_UI_MANY_CONTENT", "1", 1) }
    defer { unsetenv("JIDR_UI_MANY_CONTENT") }
    if page == "snapshots-incomplete" { setenv("JIDR_UI_INCOMPLETE_QUICK_BOOT", "1", 1) }
    defer { unsetenv("JIDR_UI_INCOMPLETE_QUICK_BOOT") }
    if page == "center-stopped-empty" { setenv("JIDR_UI_EMPTY_SNAPSHOTS", "1", 1) }
    defer { unsetenv("JIDR_UI_EMPTY_SNAPSHOTS") }
    if page == "onboarding-install-active" { setenv("JIDR_UI_SDK_SUCCESS", "1", 1) }
    defer { unsetenv("JIDR_UI_SDK_SUCCESS") }
    if page == "onboarding-missing-tools" || page == "new-device-direct-no-tools" { setenv("JIDR_UI_NO_TOOLS", "1", 1) }
    defer { unsetenv("JIDR_UI_NO_TOOLS") }
    if page == "image-management-empty" { setenv("JIDR_UI_NO_MANAGED_IMAGES", "1", 1) }
    defer { unsetenv("JIDR_UI_NO_MANAGED_IMAGES") }
    if page == "tasks-active" { setenv("JIDR_UI_TASKS", "1", 1) }
    else { unsetenv("JIDR_UI_TASKS") }
    defer { unsetenv("JIDR_UI_TASKS") }
    if page == "root-full" { setenv("JIDR_UI_ROOT", "magisk", 1) }
    if page == "root-adb" { setenv("JIDR_UI_ROOT", "adb", 1) }
    if page == "root-adb-writable" { setenv("JIDR_UI_ROOT", "adb-writable", 1) }
    defer { unsetenv("JIDR_UI_ROOT") }
    let model: CenterModel
    do { model = try CenterModel(center: options.uiFixture, bridge: options.playerBridge) }
    catch { fail("cannot start UI fixture: \(error)") }
    defer { model.close() }
    require(waitUpTo(5) { model.connection.isOnline && model.details != nil }, "UI fixture did not load")
    model.language = snapshotCase.language
    model.appearance = snapshotCase.appearance == .light ? 1 : 2
    if page == "tasks-active" {
        model.refreshJobs()
        require(waitUpTo(5) { model.taskRows.count == 2 }, "task fixture did not load")
    }
    if ["center-stopped", "center-stopped-empty", "device-settings", "root", "camera", "snapshots", "snapshots-incomplete", "details-error", "root-full", "root-adb", "root-adb-writable"].contains(page) {
        guard let device = model.devices.first(where: { $0.stopped }) else { fail("fixture has no stopped device") }
        model.select(device.id)
        require(waitUpTo(5) { model.details?.device.id == device.id }, "stopped details did not load")
    }
    if page == "all-devices-list" || page == "all-devices-grid" {
        model.showAllDevices()
        model.gridView = page == "all-devices-grid"
    }
    if page == "center-many-content" {
        require(waitUpTo(5) { model.apps.count == 16 && !model.appsLoading }, "many-app fixture did not load")
    }
    if page == "search-empty" { model.deviceQuery = "no-matching-device" }
    if page == "details-error" {
        model.details = nil
        model.detailsLoading = false
        model.detailsError = model.text("读取设备详情超时，请重试。", "Reading device details timed out. Try again.")
    }
    if page == "settings-defaults" { model.settingsCategory = 1 }
    if page == "settings-advanced" { model.settingsCategory = 3 }
    if page == "microphone" {
        model.microphoneSession(for: model.selected!).file = URL(fileURLWithPath: "/tmp/voice-test.wav")
    }
    let canvas = Canvas(width: snapshotCase.width, height: snapshotCase.height, appearance: snapshotCase.appearance)
    var toolsSelection: DeviceToolsSelection?
    switch page {
    case "image-management", "image-management-empty": canvas.mount(ImageManagementView(model: model))
    case "image-management-install": canvas.mount(NewDeviceView(model: model, initialImageInstall: true, standaloneImageInstall: true))
    case "settings", "settings-defaults", "settings-advanced": canvas.mount(SettingsView(model: model, onClose: {}))
    case "center-stopped", "center-stopped-empty", "center-many-content", "search-empty", "details-error", "all-devices-list", "all-devices-grid": canvas.mount(CenterView(model: model))
    case "root", "root-full", "root-adb", "root-adb-writable", "microphone", "camera", "clipboard", "battery", "gps", "network", "calls", "fingerprint", "developer", "logcat":
        let tab = ["root": 4, "root-full": 4, "root-adb": 4, "root-adb-writable": 4, "microphone": 10, "camera": 8, "clipboard": 6, "battery": 0, "gps": 1, "network": 2, "calls": 5, "fingerprint": 7, "developer": 9, "logcat": 3][page]!
        let selection = DeviceToolsSelection(section: tab)
        toolsSelection = selection
        let tools = AdvancedToolsView(model: model, id: model.selected!, initialRoot: false, selection: selection)
        if page == "network" {
            // Native switches otherwise capture an initial off-to-on animation
            // while the asynchronous network fixture is being applied.
            canvas.mount(tools.transaction { $0.animation = nil; $0.disablesAnimations = true })
            require(waitUpTo(3) {
                var loaded = false
                canvas.inspect { host, _ in
                    let switches = nativeDescendants(host, NSSwitch.self)
                    loaded = switches.count == 2 && switches.allSatisfy { $0.state == .on }
                }
                return loaded
            }, "network fixture switches did not reach their loaded state")
        } else {
            canvas.mount(tools)
        }
    case "snapshots", "snapshots-incomplete": canvas.mount(SnapshotsView(model: model, device: model.details!.device))
    case "device-settings":
        guard let details = model.details else { fail("editor details missing") }
        canvas.mount(EditDeviceView(model: model, details: details))
    case "sdk": canvas.mount(NewDeviceView(model: model, standaloneSDKSetup: true))
    case "new-device-config": canvas.mount(NewDeviceView(model: model, initialStep: 3))
    case "new-device-direct", "new-device-direct-no-images", "new-device-direct-no-tools":
        canvas.mount(NewDeviceView(model: model, startAtDeviceSetup: true))
    case "custom-resolution", "custom-resolution-invalid":
        canvas.mount(CustomResolutionView(language: snapshotCase.language,
                                          initialWidth: page == "custom-resolution" ? 1080 : 100,
                                          initialHeight: page == "custom-resolution" ? 2400 : 5000,
                                          onConfirm: { _ in }))
    case "onboarding-config-wide", "onboarding-advanced-wide":
        canvas.mount(NewDeviceView(model: model, initialStep: 3, inline: true, initialShowAdvanced: page == "onboarding-advanced-wide").frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { CenterOnboardingGlass().ignoresSafeArea() }
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
    case "onboarding-install-footer-active", "onboarding-install-footer-failed":
        canvas.mount(OnboardingInstallFooterView(language: snapshotCase.language,
                                                 state: page == "onboarding-install-footer-active" ? .installing : .failed,
                                                 cancelPending: false, canCancel: true, onCancel: {}, onReview: {},
                                                 onReturnToSetup: page == "onboarding-install-footer-failed" ? {} : nil)
            .background { CenterOnboardingGlass().ignoresSafeArea() })
    case "onboarding-install-wizard-skipped":
        canvas.mount(NewDeviceView(model: model, initialStep: 1, inline: true).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { CenterOnboardingGlass().ignoresSafeArea() })
    case "onboarding-install-active", "onboarding-install-indeterminate", "onboarding-install-error", "onboarding-install-skipped":
        let state: SDKOnboardingInstallState = page == "onboarding-install-skipped" ? .skipped : page == "onboarding-install-error" ? .failed : .installing
        canvas.mount(OnboardingInstallProgressView(language: snapshotCase.language, state: state,
                                                  fraction: page == "onboarding-install-active" ? 0.42 : nil,
                                                  message: "Downloading emulator", error: page == "onboarding-install-error" ? "Network unavailable." : nil)
            .background { CenterOnboardingGlass().ignoresSafeArea() })
    case "environment-licence", "environment-licence-empty", "environment-licence-error", "environment-licence-loading":
        let licenses = page == "environment-licence" ? [PendingLicense(id: "fixture-test-licence", sha256: "test-hash", text: String(repeating: "Synthetic test licence text. No SDK licence is accepted.\n", count: 12), accepted: true)] : page == "environment-licence-empty" ? [] : nil
        canvas.mount(EnvironmentLicensesView(language: snapshotCase.language, licenses: licenses, loading: page == "environment-licence-loading",
                                             error: page == "environment-licence-error" ? "Unable to load licences. Try again." : "",
                                             canAgree: page != "environment-licence-error" && page != "environment-licence-loading", retry: {}, onAgree: { true }))
    case "onboarding-environment", "onboarding-environment-no-images":
        canvas.mount(NewDeviceView(model: model, inline: true, automaticallySkipReadyEnvironment: false).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { CenterOnboardingGlass().ignoresSafeArea() })
    case "onboarding-ready", "onboarding-missing-tools", "onboarding-auto-no-images":
        canvas.mount(NewDeviceView(model: model, inline: true).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { CenterOnboardingGlass().ignoresSafeArea() })
    case "onboarding-ready-reduced-motion":
        canvas.mount(NewDeviceView(model: model, inline: true, reduceMotionOverride: true).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { CenterOnboardingGlass().ignoresSafeArea() })
    case "onboarding-checking-status":
        canvas.mount(OnboardingEnvironmentChecking(language: snapshotCase.language).padding())
    case "onboarding-install-other-image":
        canvas.mount(NewDeviceView(model: model, initialStep: 2, inline: true, initialImageInstall: true).frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { CenterOnboardingGlass().ignoresSafeArea() })
    case "onboarding-card-transparency":
        canvas.mount(ZStack {
            HStack(spacing: 0) {
                Color(red: 0.9, green: 0.25, blue: 0.3)
                Color(red: 0.15, green: 0.4, blue: 0.9)
            }
            Color.clear.frame(width: 240, height: 110).modifier(OnboardingCardMaterial())
        })
    case "onboarding-card-white-background":
        canvas.mount(ZStack {
            Color.white
            Color.clear.frame(width: 240, height: 110).modifier(OnboardingCardMaterial())
        })
    case "tasks", "tasks-active": canvas.mount(TaskCenterView(model: model))
    case "palette": canvas.mount(CommandPaletteView(model: model))
    case "device-preview-states":
        guard let running = model.devices.first(where: { $0.running }),
              let stopped = model.devices.first(where: { $0.stopped }),
              let context = CGContext(data: nil, width: 32, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fail("thumbnail fixture cannot be created")
        }
        context.setFillColor(NSColor.green.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        guard let image = context.makeImage() else { fail("thumbnail fixture has no image") }
        model.rememberThumbnail(image, device: running.id)
        model.rememberThumbnail(image, device: stopped.id)
        canvas.mount(HStack(spacing: 10) {
            DevicePreview(model: model, device: running, width: 64, height: 110)
            DevicePreview(model: model, device: stopped, width: 64, height: 110)
            DeviceArtwork(state: .running, frame: nil, width: 64, height: 110)
            DeviceArtwork(state: .starting, frame: nil, width: 64, height: 110)
        })
    case "script-options":
        canvas.mount(PlaybackOptionsPopover(language: snapshotCase.language, mode: .constant("count"), count: .constant(3), seconds: .constant(60), interval: .constant(500), speed: .constant(1))
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(WbColor.overlay))
    case "recordings":
        let transport = PlayerTransport()
        transport.language = snapshotCase.language
        canvas.mount(PlayerScriptsView(transport: transport))
    default: fail("unknown auxiliary view: \(page)")
    }
    canvas.settle(0.5)
    if ["new-device-direct", "new-device-direct-no-images", "new-device-direct-no-tools"].contains(page) {
        canvas.inspect { host, _ in
            require(nativeDescendants(host, NSTextField.self).contains { $0.isEditable && $0.stringValue.contains("安卓手机") },
                    "new device opens directly at device configuration")
            let hasImageSelector = !nativeDescendants(host, NSPopUpButton.self).isEmpty
            require(hasImageSelector == (page != "new-device-direct-no-images"),
                    "the image selector appears only when an installed image exists")
        }
    }
    if ["onboarding-ready", "onboarding-ready-reduced-motion", "onboarding-missing-tools", "onboarding-auto-no-images"].contains(page) {
        canvas.inspect { host, _ in
            let hasDeviceName = nativeDescendants(host, NSTextField.self).contains { $0.isEditable }
            require(hasDeviceName == (page == "onboarding-ready" || page == "onboarding-ready-reduced-motion"),
                    "only a complete SDK with an installed image opens device setup directly")
            if page == "onboarding-ready" || page == "onboarding-ready-reduced-motion" {
                require(!nativeDescendants(host, NSPopUpButton.self).isEmpty,
                        "direct setup exposes an image selector")
            }
        }
    }
    if page == "onboarding-advanced-wide" {
        // Profile loading changes the document height while the expansion
        // scroll animation is running. Capture its settled bottom position.
        canvas.settle(1.0)
        canvas.inspect { host, _ in
            guard let scroll = nativeDescendants(host, NSScrollView.self)
                .filter({ ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height })
                .max(by: { $0.bounds.width < $1.bounds.width }),
                  let document = scroll.documentView else {
                fail("expanded onboarding must have a scrollable configuration")
            }
            let clip = scroll.contentView
            let bottom = max(0, document.bounds.height - clip.bounds.height)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: bottom))
            scroll.reflectScrolledClipView(clip)
        }
        canvas.settle(0.2)
    }
    if page == "center-many-content" {
        canvas.inspect { host, _ in
            guard let appsScroll = nativeDescendants(host, NSScrollView.self).first(where: {
                abs($0.bounds.height - 171) < 2 && ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height
            }) else { fail("the 16-app overview needs a bounded, scrollable app list") }
            let clip = appsScroll.contentView
            let original = clip.bounds.origin
            let bottom = max(0, (appsScroll.documentView?.bounds.height ?? 0) - clip.bounds.height)
            clip.scroll(to: NSPoint(x: original.x, y: bottom))
            appsScroll.reflectScrolledClipView(clip)
            canvas.settle(0.1)
            require(abs(clip.bounds.origin.y - original.y) > 1, "the app list scrolls to reveal additional apps")
            clip.scroll(to: original)
            appsScroll.reflectScrolledClipView(clip)
            canvas.settle(0.1)
        }
    }
    if page == "all-devices-list" || page == "all-devices-grid" {
        canvas.inspect { host, window in
            guard nativeDescendants(host, NSTableView.self).contains(where: { $0.accessibilityIdentifier() == "library-devices" }) else {
                fail("native device sidebar is missing")
            }
            let systemSidebar = nativeDescendants(host, NSSplitView.self)
                .compactMap { $0.delegate as? NSSplitViewController }
                .flatMap(\.splitViewItems).first { $0.behavior == .sidebar }
            require(systemSidebar != nil, "device center uses the system sidebar")
            let previousCenterWindow = model.centerWindow
            let toolbarWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 550),
                                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
            let toolbarController = CenterToolbarController(model: model, window: toolbarWindow)
            defer { model.centerWindow = previousCenterWindow }
            guard let toolbar = toolbarWindow.toolbar,
                  let toggle = toolbarController.toolbar(toolbar, itemForItemIdentifier: .init("jidr.sidebar"), willBeInsertedIntoToolbar: true),
                  let toggleAction = toggle.action else { fail("sidebar toolbar action is missing") }
            require(toolbarController.toolbarDefaultItemIdentifiers(toolbar).filter { $0.rawValue == "jidr.sidebar" }.count == 1,
                    "toolbar has one sidebar toggle")
            toolbarWindow.toolbar = NSToolbar(identifier: "jidr.fixture.replacement")
            pump(0.1)
            require(toolbarWindow.toolbar === toolbar, "system toolbar replacement preserves the Jidr toolbar")
            require(NSApp.sendAction(toggleAction, to: toggle.target, from: toggle), "sidebar toolbar action responds")
            pump(0.3)
            require(!model.sidebarVisible, "toolbar collapses the sidebar")
            require(systemSidebar?.isCollapsed == true, "native sidebar is collapsed")
            require(NSApp.sendAction(toggleAction, to: toggle.target, from: toggle), "sidebar toolbar action responds again")
            pump(0.3)
            require(model.sidebarVisible, "toolbar expands the sidebar")
            require(systemSidebar?.isCollapsed == false, "native sidebar is expanded")
            guard let table = nativeDescendants(host, NSTableView.self).first(where: { $0.accessibilityIdentifier() == "library-devices" }) else {
                fail("device sidebar did not return after expanding")
            }
            guard let search = nativeDescendants(host, NSSearchField.self).first(where: { $0.identifier?.rawValue == "device-search" }) else {
                fail("device search is missing")
            }
            guard let listScroll = table.enclosingScrollView else { fail("device list scroll view is missing") }
            require(listScroll.bounds.width <= search.bounds.width + 1,
                    "device selection stays inset within the sidebar search width")
            search.stringValue = "no-such-device-fixture"
            search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
            require(model.deviceQuery == "no-such-device-fixture" && model.filteredDevices.isEmpty,
                    "sidebar search updates the device filter")
            search.stringValue = ""
            search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
            pump(0.2)
            require(model.deviceQuery.isEmpty && !model.filteredDevices.isEmpty, "clearing search restores devices")
            require(table.numberOfRows == model.filteredDevices.count + 2 && table.selectedRow == 0,
                    "all-devices entry is selected and the device rows remain available")
            require(!(table.delegate?.tableView?(table, shouldSelectRow: 1) ?? true), "device heading is not selectable")
            guard let headingCell = table.view(atColumn: 0, row: 1, makeIfNecessary: true),
                  let addButton = nativeDescendants(headingCell, NSButton.self).first else { fail("device heading add button is missing") }
            // The temporary toolbar test window must not become the owner of
            // a real panel in this deliberately hidden renderer.
            model.centerWindow = previousCenterWindow
            addButton.performClick(nil)
            require(model.sheet == nil && table.selectedRow == 0, "hidden snapshot canvas does not open a device window or change selection")
            require(model.showingAllDevices && model.selected == nil, "all-devices view has no selected device")
            table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
            require(!model.showingAllDevices && model.selected == model.filteredDevices.first?.id,
                    "selecting a device opens its overview")
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            require(model.showingAllDevices && model.selected == nil, "all-devices entry can be selected again")
            model.refresh()
            var completed = false
            model.call("device.list") { _ in completed = true }
            require(waitUpTo(5) { completed }, "device refresh did not complete")
            require(model.showingAllDevices && model.selected == nil, "refresh preserves the all-devices view")
        }
        // Restore the initial layout after testing the system collapse animation.
        canvas.unmount()
        canvas.mount(CenterView(model: model))
        canvas.settle(0.3)
    }
    let rep = canvas.capture()
    if page == "onboarding-card-transparency" {
        guard let redSide = rep.colorAt(x: 80, y: 80)?.usingColorSpace(.sRGB),
              let blueSide = rep.colorAt(x: 240, y: 80)?.usingColorSpace(.sRGB),
              let redBackground = rep.colorAt(x: 20, y: 80)?.usingColorSpace(.sRGB),
              let blueBackground = rep.colorAt(x: 300, y: 80)?.usingColorSpace(.sRGB) else {
            fail("cannot inspect onboarding card backdrop")
        }
        require(redSide.greenComponent > redBackground.greenComponent + 0.1 &&
                blueSide.greenComponent > blueBackground.greenComponent + 0.1 &&
                redSide.greenComponent < redBackground.greenComponent + 0.4 &&
                blueSide.greenComponent < blueBackground.greenComponent + 0.4,
                "onboarding card adds a translucent light tint to the backdrop")
        require(redSide.redComponent - blueSide.redComponent > 0.25 &&
                blueSide.blueComponent - redSide.blueComponent > 0.25,
                "onboarding card must let different backdrop colors show through")
    }
    if page == "onboarding-install-active" {
        model.onboardingInstallForegroundRequired = true
        var completionResult: Bool?
        model.startSDKInstall(SDKInstallPlan(imagePackage: nil, licenses: [])) { completionResult = $0 }
        require(waitUpTo(5) { !model.sdkInstalling && model.sdkInstallSucceeded == true && completionResult == true },
                "synthetic successful installation did not complete")
        require(!model.onboardingInstallForegroundRequired,
                "the foreground restriction must clear when an installation succeeds")
        require(SDKOnboardingInstallState.shouldAdvanceAfterSuccess(requested: true, step: 1, succeeded: completionResult),
                "successful installation must advance to the image step")
    }
    if page == "onboarding-install-error" {
        model.onboardingInstallForegroundRequired = true
        model.openPalette()
        model.openTasks()
        model.present(.settings)
        require(!model.paletteOpen && !model.tasksOpen && model.settingsWindow == nil,
                "foreground installation must block navigation to other panels")
        var completionResult: Bool?
        model.startSDKInstall(SDKInstallPlan(imagePackage: nil, licenses: [])) { completionResult = $0 }
        require(waitUpTo(5) { !model.sdkInstalling && model.sdkInstallSucceeded == false && completionResult == false },
                "synthetic installation failure did not complete")
        require(!model.onboardingInstallForegroundRequired,
                "the foreground restriction must clear when an installation fails")
    }
    if page == "onboarding-card-white-background" {
        guard let edge = rep.colorAt(x: 40, y: 80)?.usingColorSpace(.sRGB),
              let inside = rep.colorAt(x: 60, y: 80)?.usingColorSpace(.sRGB) else {
            fail("cannot inspect onboarding card boundary")
        }
        require(inside.redComponent - edge.redComponent > 0.05,
                "onboarding card boundary must remain visible against white")
    }
    if page == "all-devices-list" {
        let devices = model.devices
        require(!devices.isEmpty, "transition fixture needs devices")
        for _ in 0..<2 {
            model.devices = []
            canvas.settle(0.3)
            canvas.inspect { host, _ in
                require(model.isEmptyDeviceLibrary && !nativeDescendants(host, NSSplitView.self).contains { $0.delegate is NSSplitViewController },
                        "removing the last device shows onboarding without a sidebar")
            }
            model.devices = devices
            canvas.settle(0.3)
            canvas.inspect { host, _ in
                require(!model.isEmptyDeviceLibrary && nativeDescendants(host, NSSplitView.self).contains { $0.delegate is NSSplitViewController },
                        "adding a device restores the navigation sidebar")
                require(nativeDescendants(host, NSSearchField.self).contains { $0.identifier?.rawValue == "device-search" && $0.isEnabled },
                        "adding a device restores search")
            }
        }
    }
    if page == "device-preview-states" {
        guard let running = rep.colorAt(x: 32, y: 55)?.usingColorSpace(.sRGB),
              let stopped = rep.colorAt(x: 106, y: 55)?.usingColorSpace(.sRGB) else { fail("cannot inspect thumbnail pixels") }
        require(running.greenComponent > 0.8 && running.redComponent < 0.2, "running device shows the existing screen thumbnail")
        require(stopped.redComponent < 0.2 && stopped.greenComponent < 0.2 && stopped.blueComponent < 0.2,
                "stopped device uses its dark screen even if a stale thumbnail exists")
        guard let placeholder = rep.colorAt(x: 180, y: 55)?.usingColorSpace(.sRGB) else { fail("cannot inspect running placeholder") }
        require(placeholder.blueComponent > stopped.blueComponent,
                "running device without a frame uses the neutral placeholder")
        require(DeviceArtworkState(deviceState: "booting") == .starting &&
                DeviceArtworkState(deviceState: "running") == .running &&
                DeviceArtworkState(deviceState: "hibernated") == .stopped,
                "device states select the corresponding artwork")
    }
    if let selection = toolsSelection { validateTools(canvas, selection: selection, page: page) }
    canvas.unmount()
    pump(0.05)
    return rep
}

func renderScriptManagementWindow(_ snapshotCase: SnapshotCase) -> NSBitmapImageRep {
    let transport = PlayerTransport()
    transport.language = snapshotCase.language
    let controller = PlayerScriptsWindowController(transport: transport)
    guard let window = controller.window, let root = window.contentView?.superview else { fail("recordings window has no native frame") }
    require(window.toolbarStyle == .unifiedCompact, "recordings toolbar uses compact native controls")
    let toolbarItems = window.toolbar?.items.map { $0.itemIdentifier.rawValue } ?? []
    guard let createIndex = toolbarItems.firstIndex(of: "jidr.recordings.new"),
          let importIndex = toolbarItems.firstIndex(of: "jidr.recordings.import") else {
        fail("recordings toolbar must contain New and Import")
    }
    require(importIndex == createIndex + 2 && toolbarItems[createIndex + 1] == NSToolbarItem.Identifier.space.rawValue,
            "native toolbar spacing keeps New and Import as separate controls")
    window.appearance = snapshotCase.appearance.nsAppearance
    transport.applyScriptNotification(["op": "list", "scripts": [
        ["id": "1", "name": "日常登录", "duration_ms": 18000, "event_count": 16, "action_count": 4, "created_at": "2026-11-13T14:35:00Z"],
        ["id": "2", "name": "游戏日常任务", "duration_ms": 156000, "event_count": 84, "action_count": 12, "created_at": "2026-11-12T20:18:00Z"],
        ["id": "3", "name": "领取每日奖励", "duration_ms": 42000, "event_count": 25, "action_count": 5, "created_at": "2026-11-10T12:00:00Z"]
    ]])
    root.layoutSubtreeIfNeeded()
    pump(0.4)
    root.layoutSubtreeIfNeeded()
    guard let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { fail("cannot capture recordings window") }
    root.cacheDisplay(in: root.bounds, to: bitmap)
    require(!window.isVisible && !NSApp.isActive, "recordings preview remains hidden")
    window.contentView = nil
    window.close()
    return bitmap
}

func render(_ snapshotCase: SnapshotCase) -> NSBitmapImageRep {
    switch snapshotCase.kind {
    case .center: return renderCenter(snapshotCase)
    case .player: return renderPlayer(snapshotCase)
    case .auxiliary(let page):
        if page == "script-management" { return renderScriptManagementWindow(snapshotCase) }
        return renderAuxiliary(snapshotCase, page: page)
    }
}

// MARK: - Run

if options.update {
    do {
        try FileManager.default.createDirectory(at: goldenDirectory, withIntermediateDirectories: true)
    } catch {
        fail("cannot create \(goldenDirectory.path): \(error)")
    }
}

var failures = 0
for snapshotCase in selected {
    let rep = render(snapshotCase)
    let rendered = pixels(rep)
    let url = goldenDirectory.appendingPathComponent("\(snapshotCase.name).png")
    if options.update {
        let data = pngData(rep)
        do {
            try data.write(to: url)
        } catch {
            fail("cannot write \(url.path): \(error)")
        }
        print("updated \(snapshotCase.name) [\(snapshotCase.languageName)/\(snapshotCase.appearance.name)] \(rendered.width)x\(rendered.height) \(data.count) bytes")
        continue
    }
    guard let baselineData = try? Data(contentsOf: url) else {
        failures += 1
        print("FAIL \(snapshotCase.name): missing baseline \(url.path)")
        continue
    }
    guard let baselineRep = NSBitmapImageRep(data: baselineData) else {
        failures += 1
        print("FAIL \(snapshotCase.name): cannot decode baseline \(url.path)")
        continue
    }
    let baseline = pixels(baselineRep)
    if baseline.width != rendered.width || baseline.height != rendered.height {
        failures += 1
        print("FAIL \(snapshotCase.name): size \(rendered.width)x\(rendered.height) != baseline \(baseline.width)x\(baseline.height)")
        continue
    }
    var differing = 0
    var first: (x: Int, y: Int)?
    for index in stride(from: 0, to: rendered.bytes.count, by: 4) {
        var same = true
        for channel in 0..<4 where rendered.bytes[index + channel] != baseline.bytes[index + channel] {
            same = false
            break
        }
        if !same {
            differing += 1
            if first == nil {
                let pixel = index / 4
                first = (pixel % rendered.width, pixel / rendered.width)
            }
        }
    }
    if differing == 0 {
        print("PASS \(snapshotCase.name) [\(snapshotCase.languageName)/\(snapshotCase.appearance.name)] \(rendered.width)x\(rendered.height) (\(baselineData.count) baseline bytes)")
    } else {
        failures += 1
        let at = first.map { "\($0.x),\($0.y)" } ?? "?"
        print("FAIL \(snapshotCase.name) [\(snapshotCase.languageName)/\(snapshotCase.appearance.name)]: \(differing) of \(rendered.width * rendered.height) pixels differ (first at \(at))")
    }
}

if options.check {
    if failures == 0 {
        print("snapshot check: PASS (\(selected.count)/\(selected.count) selected cases; \(allCases.count) available, hidden rendering)")
    } else {
        print("snapshot check: FAIL (\(failures) of \(selected.count) cases)")
        exit(1)
    }
}
