// SPDX-License-Identifier: GPL-3.0-only
// Deterministic offscreen renderer for the SwiftUI previews.
//
// The bridge fixtures (JIDR_CENTER_FIXTURE / JIDR_PLAYER_FIXTURE) provide fixed
// state, so each case renders with fixed window geometry, a fixed dark
// appearance, disabled animations and a fixed zh-Hans locale. Baselines live in
// Tests/golden; --check compares decoded pixels exactly (no tolerance).
import AppKit
import Darwin
import Foundation
import SwiftUI

// MARK: - Case table and geometry

struct SnapshotCase {
    enum Kind {
        case center(fixture: String)
        case player
    }
    let name: String
    let kind: Kind
}

let allCases: [SnapshotCase] = [
    SnapshotCase(name: "center-empty", kind: .center(fixture: "empty")),
    SnapshotCase(name: "center-populated", kind: .center(fixture: "populated")),
    SnapshotCase(name: "center-load-failure", kind: .center(fixture: "load-failure")),
    SnapshotCase(name: "center-long-task", kind: .center(fixture: "long-task")),
    SnapshotCase(name: "player-running", kind: .player),
]

// Small enough that every baseline stays well under 100 KB while preserving the
// real layout: the center window is 1050×700, the player content is 432×768.
let centerSize = (width: 1000, height: 640)
let playerSize = (width: 432, height: 768)

// MARK: - CLI

struct Options {
    var update = false
    var check = false
    var only: String?
    var centerBridge = ""
    var playerBridge = ""
    var golden = ""
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
    case "--golden": options.golden = value("--golden")
    default: fail("unknown argument \(argument); usage: snapshot --update|--check [--only CASE] --center-bridge PATH --player-bridge PATH --golden DIR")
    }
    argumentIndex += 1
}
guard options.update != options.check else { fail("pass exactly one of --update or --check") }
guard !options.centerBridge.isEmpty, !options.playerBridge.isEmpty, !options.golden.isEmpty else {
    fail("--center-bridge, --player-bridge and --golden are required")
}
let goldenDirectory = URL(fileURLWithPath: options.golden, isDirectory: true)

// MARK: - Deterministic application setup

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
    private var window: NSWindow?
    private var hosting: NSHostingView<AnyView>?

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    func mount<V: View>(_ view: V) {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
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

func renderCenter(fixture: String) -> NSBitmapImageRep {
    require(fixtureCases.contains(fixture), "unknown center fixture \(fixture)")
    setenv("JIDR_CENTER_FIXTURE", fixture, 1)
    defer { unsetenv("JIDR_CENTER_FIXTURE") }
    let model: CenterModel
    do {
        model = try CenterModel(center: options.centerBridge, game: options.centerBridge, bridge: options.playerBridge)
    } catch {
        fail("cannot start the center bridge for fixture \(fixture): \(error)")
    }
    defer { model.closePlayers(); model.close() }
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
        // `start()` opens a booting player window now; the center-side job
        // progress is the same `operation` path, so drive it directly to keep
        // this case a single deterministic window.
        model.operation("device.start", id: id)
        require(waitUpTo(5, until: {
            model.progress(for: id) == "正在重启设备" && model.activeJobs.count == 1
        }), "fixture long-task: no in-flight job progress or task button")
        pump(0.2)
    default:
        fail("unsupported center fixture \(fixture)")
    }
    let canvas = Canvas(width: centerSize.width, height: centerSize.height)
    canvas.mount(CenterView(model: model))
    canvas.settle(0.4)
    let rep = canvas.capture()
    canvas.unmount()
    pump(0.05)
    return rep
}

func renderPlayer() -> NSBitmapImageRep {
    setenv("JIDR_PLAYER_FIXTURE", "1", 1)
    defer { unsetenv("JIDR_PLAYER_FIXTURE") }
    let transport = PlayerTransport()
    transport.language = 1
    let canvas = Canvas(width: playerSize.width, height: playerSize.height)
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

func render(_ snapshotCase: SnapshotCase) -> NSBitmapImageRep {
    switch snapshotCase.kind {
    case .center(let fixture): return renderCenter(fixture: fixture)
    case .player: return renderPlayer()
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
        print("updated \(snapshotCase.name) \(rendered.width)x\(rendered.height) \(data.count) bytes")
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
        print("PASS \(snapshotCase.name) \(rendered.width)x\(rendered.height) (\(baselineData.count) baseline bytes)")
    } else {
        failures += 1
        let at = first.map { "\($0.x),\($0.y)" } ?? "?"
        print("FAIL \(snapshotCase.name): \(differing) of \(rendered.width * rendered.height) pixels differ (first at \(at))")
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
