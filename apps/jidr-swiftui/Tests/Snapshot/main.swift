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
    SnapshotCase(name: "sdk-setup-light", kind: .auxiliary(page: "sdk"), language: 1, appearance: .light, width: 650, height: 520),
    SnapshotCase(name: "sdk-setup-en-dark", kind: .auxiliary(page: "sdk"), language: 0, appearance: .dark, width: 650, height: 520),
    SnapshotCase(name: "tasks-empty-light", kind: .auxiliary(page: "tasks"), language: 1, appearance: .light, width: 480, height: 260),
    SnapshotCase(name: "tasks-active-en-dark", kind: .auxiliary(page: "tasks-active"), language: 0, appearance: .dark, width: 480, height: 264),
    SnapshotCase(name: "command-search-light", kind: .auxiliary(page: "palette"), language: 1, appearance: .light, width: 600, height: 450),
    SnapshotCase(name: "command-search-en-dark", kind: .auxiliary(page: "palette"), language: 0, appearance: .dark, width: 600, height: 450),
    SnapshotCase(name: "recordings-search-light", kind: .auxiliary(page: "recordings"), language: 1, appearance: .light, width: 900, height: 620),
    SnapshotCase(name: "recordings-search-en-dark", kind: .auxiliary(page: "recordings"), language: 0, appearance: .dark, width: 900, height: 620),
    SnapshotCase(name: "center-stopped-light", kind: .auxiliary(page: "center-stopped"), language: 1, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "center-stopped-en-minimum", kind: .auxiliary(page: "center-stopped"), language: 0, appearance: .dark, width: 800, height: 550),
    SnapshotCase(name: "settings-defaults-light", kind: .auxiliary(page: "settings-defaults"), language: 1, appearance: .light, width: 700, height: 450),
    SnapshotCase(name: "settings-advanced-en-dark", kind: .auxiliary(page: "settings-advanced"), language: 0, appearance: .dark, width: 700, height: 450),
    SnapshotCase(name: "device-settings-light", kind: .auxiliary(page: "device-settings"), language: 1, appearance: .light, width: 560, height: 620),
    SnapshotCase(name: "center-search-no-results", kind: .auxiliary(page: "search-empty"), language: 0, appearance: .light, width: 800, height: 550),
    SnapshotCase(name: "center-details-error", kind: .auxiliary(page: "details-error"), language: 1, appearance: .light, width: 1050, height: 700),
    SnapshotCase(name: "tools-root-stopped", kind: .auxiliary(page: "root"), language: 1, appearance: .light, width: 716, height: 500),
    SnapshotCase(name: "tools-camera-stopped-en", kind: .auxiliary(page: "camera"), language: 0, appearance: .dark, width: 716, height: 500),
    SnapshotCase(name: "tools-clipboard-en", kind: .auxiliary(page: "clipboard"), language: 0, appearance: .light, width: 716, height: 500),
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
    // Light theme (player chrome is intentionally dark-only, so no light player).
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
    canvas.mount(ContentView(transport: transport, mapping: transport.mapping, sidebar: SidebarState()))
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
    // The fixture sends three identical frames; wait for the stream to settle so
    // the capture never sees a partially updated canvas.
    pump(0.4)
    // The connecting status is a transient notice bubble (six-second timer). It
    // is not part of the running-window state, so clear it deterministically
    // instead of racing the timer.
    transport.onStatus?("")
    pump(0.2)
    canvas.settle(0.2)
    transport.stop()
    let rep = canvas.capture()
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
            return scroll.convert(scroll.bounds, to: host).minX >= 168
        }
        guard let pageScroll = detailScrolls.max(by: { $0.bounds.width < $1.bounds.width }) else {
            fail("device tools detail page has no scroll viewport")
        }
        let pageRect = pageScroll.convert(pageScroll.bounds, to: host)
        require(abs(pageRect.minX - 169) <= 2 && abs(pageRect.maxX - host.bounds.maxX) <= 2,
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
    if ["center-stopped", "device-settings", "root", "camera", "snapshots", "details-error", "root-full", "root-adb", "root-adb-writable"].contains(page) {
        guard let device = model.devices.first(where: { $0.stopped }) else { fail("fixture has no stopped device") }
        model.select(device.id)
        require(waitUpTo(5) { model.details?.device.id == device.id }, "stopped details did not load")
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
    case "settings", "settings-defaults", "settings-advanced": canvas.mount(SettingsView(model: model, onClose: {}))
    case "center-stopped", "search-empty", "details-error": canvas.mount(CenterView(model: model))
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
    case "snapshots": canvas.mount(SnapshotsView(model: model, device: model.details!.device))
    case "device-settings":
        guard let details = model.details else { fail("editor details missing") }
        canvas.mount(EditDeviceView(model: model, details: details))
    case "sdk": canvas.mount(InstallSDKView(model: model))
    case "tasks", "tasks-active": canvas.mount(TaskCenterView(model: model))
    case "palette": canvas.mount(CommandPaletteView(model: model))
    case "recordings":
        let transport = PlayerTransport()
        transport.language = snapshotCase.language
        canvas.mount(PlayerScriptsView(transport: transport))
    default: fail("unknown auxiliary view: \(page)")
    }
    canvas.settle(0.5)
    let rep = canvas.capture()
    if let selection = toolsSelection { validateTools(canvas, selection: selection, page: page) }
    canvas.unmount()
    pump(0.05)
    return rep
}

func render(_ snapshotCase: SnapshotCase) -> NSBitmapImageRep {
    switch snapshotCase.kind {
    case .center: return renderCenter(snapshotCase)
    case .player: return renderPlayer(snapshotCase)
    case .auxiliary(let page): return renderAuxiliary(snapshotCase, page: page)
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
