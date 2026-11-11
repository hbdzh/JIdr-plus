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
    // Light theme (player chrome is intentionally dark-only, so no light player).
    SnapshotCase(name: "center-populated-light", kind: .center(fixture: "populated"), language: 1, appearance: .light),
    SnapshotCase(name: "center-load-failure-light", kind: .center(fixture: "load-failure"), language: 1, appearance: .light),
]

// Small enough that every baseline stays well under 150 KB while preserving the
// real layout: the center window is 1050×700, the player content is 432×768.
let playerSize = (width: 432, height: 768)


// MARK: - CLI

struct Options {
    var update = false
    var check = false
    var only: String?
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
    case "--only": options.only = value("--only")
    case "--center-bridge": options.centerBridge = value("--center-bridge")
    case "--player-bridge": options.playerBridge = value("--player-bridge")
    case "--ui-fixture": options.uiFixture = value("--ui-fixture")
    case "--golden": options.golden = value("--golden")
    case "--fonts": options.fonts = value("--fonts")
    default: fail("unknown argument \(argument); usage: snapshot --update|--check [--only CASE] --center-bridge PATH --player-bridge PATH --golden DIR [--fonts DIR]")
    }
    argumentIndex += 1
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

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
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
        window.orderFrontRegardless()
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

func renderAuxiliary(_ snapshotCase: SnapshotCase, page: String) -> NSBitmapImageRep {
    require(!options.uiFixture.isEmpty, "auxiliary views require --ui-fixture")
    if page == "tasks-active" { setenv("JIDR_UI_TASKS", "1", 1) }
    else { unsetenv("JIDR_UI_TASKS") }
    defer { unsetenv("JIDR_UI_TASKS") }
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
    let canvas = Canvas(width: snapshotCase.width, height: snapshotCase.height, appearance: snapshotCase.appearance)
    switch page {
    case "settings": canvas.mount(SettingsView(model: model, onClose: {}))
    case "sdk": canvas.mount(InstallSDKView(model: model))
    case "tasks", "tasks-active": canvas.mount(TaskCenterView(model: model))
    case "palette": canvas.mount(CommandPaletteView(model: model))
    default: fail("unknown auxiliary view: \(page)")
    }
    canvas.settle(0.5)
    let rep = canvas.capture()
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

var selected = allCases
if let only = options.only {
    selected = allCases.filter { $0.name == only }
    if selected.isEmpty {
        fail("unknown case \(only); known cases: \(allCases.map(\.name).joined(separator: ", "))")
    }
}
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
        print("snapshot check: PASS (\(selected.count)/\(allCases.count) cases)")
    } else {
        print("snapshot check: FAIL (\(failures) of \(selected.count) cases)")
        exit(1)
    }
}
