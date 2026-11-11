// SPDX-License-Identifier: GPL-3.0-only
// M4-C live UI evidence renderer: offscreen NSHostingView captures of the real
// device center and player window against a real daemon + emulator.
//
// This is a test harness, not product code. It has two modes:
//   --self-test : deterministic fixture bridges (JIDR_CENTER_FIXTURE /
//                 JIDR_PLAYER_FIXTURE), no daemon and no emulator. Proves the
//                 harness paths, assertions and evidence writer offline.
//   live        : real `jidr-center-bridge`/`jidr-swiftui-bridge`, real
//                 isolated JIDR_HOME daemon and a real running device; writes
//                 target/m4/live-*.png + evidence.txt.
//
// Rendering follows Tests/Snapshot: fixed dark appearance, disabled animations,
// bundled Geist faces registered before the first view, exact 1x bitmap capture
// with NSHostingView.cacheDisplay (no screen-recording permission needed).
import AppKit
import CoreText
import CryptoKit
import Darwin
import Foundation
import SwiftUI

// MARK: - CLI

struct Options {
    var selfTest = false
    var centerBridge = ""
    var playerBridge = ""
    var device = ""
    var out = "target/m4"
    var fonts = ""
    var language = 1
    var centerTimeout = 180.0
    var frameTimeout = 120.0
    var createMs = 0
    var bootMs = 0
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("live-render: " + message + "\n").utf8))
    exit(2)
}
func note(_ message: String) {
    print("live-render: " + message)
    fflush(stdout)
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
    case "--self-test": options.selfTest = true
    case "--center-bridge": options.centerBridge = value("--center-bridge")
    case "--player-bridge": options.playerBridge = value("--player-bridge")
    case "--device": options.device = value("--device")
    case "--out": options.out = value("--out")
    case "--fonts": options.fonts = value("--fonts")
    case "--language": options.language = Int(value("--language")) ?? 1
    case "--center-timeout": options.centerTimeout = Double(value("--center-timeout")) ?? 180
    case "--frame-timeout": options.frameTimeout = Double(value("--frame-timeout")) ?? 120
    case "--create-ms": options.createMs = Int(value("--create-ms")) ?? 0
    case "--boot-ms": options.bootMs = Int(value("--boot-ms")) ?? 0
    case "-h", "--help":
        print("usage: live-render --self-test --center-bridge PATH --player-bridge PATH --out DIR [--fonts DIR]")
        print("       live-render --center-bridge PATH --player-bridge PATH --device NAME --out DIR [--create-ms N --boot-ms N]")
        exit(0)
    default: fail("unknown argument \(argument)")
    }
    argumentIndex += 1
}
guard !options.centerBridge.isEmpty, !options.playerBridge.isEmpty else {
    fail("--center-bridge and --player-bridge are required")
}
if !options.selfTest && options.device.isEmpty { fail("--device is required in live mode") }

let outDirectory = URL(fileURLWithPath: options.out, isDirectory: true)
try? FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
let runStarted = Date()

// MARK: - Bundled fonts and deterministic application setup

/// Register the OFL Geist faces before any view is built; this mirrors the
/// snapshot harness so the live captures use the same fonts as the packaged app.
func registerBundledFonts(explicitPath: String) {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    var candidates: [String] = []
    if !explicitPath.isEmpty { candidates.append(explicitPath) }
    candidates.append(root.appendingPathComponent("apps/jidr-swiftui/Resources/fonts").path)
    candidates.append(root.appendingPathComponent("target/swiftui-center/JidrSwiftUICenter.app/Contents/Resources/fonts").path)
    for directory in candidates {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
        let files = names.filter { $0.hasSuffix(".ttf") || $0.hasSuffix(".otf") }.sorted()
        guard !files.isEmpty else { continue }
        var registered = 0
        for name in files {
            var error: Unmanaged<CFError>?
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { registered += 1 }
        }
        let live = WbFontResolver.usesBundledFonts
        note("registered \(registered)/\(files.count) font file(s) from \(directory); bundled Geist live: \(live)")
        if live { return }
    }
    note("warning: no bundled Geist fonts found; system font fallback is in use")
}
registerBundledFonts(explicitPath: options.fonts)

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.appearance = NSAppearance(named: .darkAqua)
NSAnimationContext.beginGrouping()
NSAnimationContext.current.duration = 0
NSAnimationContext.current.allowsImplicitAnimation = false
NSAnimationContext.endGrouping()

func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
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

    init(width: Int, height: Int) { self.width = width; self.height = height }

    func mount<V: View>(_ view: V) {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        self.window = window
        self.hosting = hosting
        settle(0.35)
    }
    func settle(_ seconds: TimeInterval = 0.3) {
        guard let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        pump(seconds)
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
    }
    func capture() -> NSBitmapImageRep {
        guard let hosting, let window, window.contentView === hosting else { fail("canvas is not mounted") }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
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

struct Capture {
    let name: String
    let url: URL
    let width: Int
    let height: Int
    let bytes: Int
    let sha256: String
    let elapsedMs: Int
}

func capturePNG(_ view: some View, width: Int, height: Int, name: String, directory: URL? = nil) -> Capture {
    let destination = directory ?? outDirectory
    let started = Date()
    let canvas = Canvas(width: width, height: height)
    canvas.mount(view)
    canvas.settle(0.5)
    let rep = canvas.capture()
    guard let data = rep.representation(using: .png, properties: [:]) else { fail("cannot encode \(name)") }
    let url = destination.appendingPathComponent(name)
    do { try data.write(to: url) } catch { fail("cannot write \(url.path): \(error)") }
    canvas.unmount()
    pump(0.05)
    // A blank capture would still be a valid PNG; require real content bytes and
    // several distinct colours.
    require(data.count > 10_000, "\(name) is suspiciously small (\(data.count) bytes)")
    require(hasContent(rep), "\(name) looks blank (few distinct pixels)")
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let capture = Capture(name: name, url: url, width: width, height: height, bytes: data.count,
                          sha256: digest, elapsedMs: Int(Date().timeIntervalSince(started) * 1000))
    note("rendered \(name) \(width)x\(height) \(data.count) bytes in \(capture.elapsedMs) ms")
    return capture
}

func hasContent(_ rep: NSBitmapImageRep) -> Bool {
    guard let image = rep.cgImage else { return false }
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
    let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return false }
    var colours = Set<UInt32>()
    for index in stride(from: 0, to: bytes.count, by: 4 * 37) {
        let pixel = UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2])
        colours.insert(pixel)
        if colours.count > 40 { return true }
    }
    return colours.count > 40
}

// MARK: - Center

/// Waits until the center model has the real device, its details and its app
/// list, which is what the evidence screenshots must show.
func waitForCenter(_ model: CenterModel, name: String?, timeout: Double) -> (device: Device, details: Details, readyMs: Int) {
    let started = Date()
    let ready = waitUpTo(timeout) {
        guard model.connection.isOnline, model.deviceListLoaded, !model.devices.isEmpty else { return false }
        let target = name.flatMap { wanted in model.devices.first { $0.name == wanted || $0.id == wanted } }
            ?? model.devices.first
        guard target != nil, model.details?.device.id == target?.id else { return false }
        guard model.details?.device.running == true else { return false }
        return !model.appsLoading && (model.appsError == nil || !model.apps.isEmpty)
    }
    guard ready, let device = (name.flatMap { wanted in model.devices.first { $0.name == wanted || $0.id == wanted } } ?? model.devices.first),
          let details = model.details else {
        fail("center did not become ready within \(Int(timeout)) s (connection=\(model.connection), devices=\(model.devices.count), details=\(model.details?.device.name ?? "nil"), appsLoading=\(model.appsLoading), appsError=\(model.appsError ?? "nil"))")
    }
    let elapsed = Int(Date().timeIntervalSince(started) * 1000)
    note("center ready in \(elapsed) ms: \(device.name) (\(device.id)), apps=\(model.apps.count)")
    return (device, details, elapsed)
}

func renderCenterEvidence(_ model: CenterModel) -> [Capture] {
    var captures: [Capture] = []
    captures.append(capturePNG(CenterView(model: model), width: 1000, height: 640, name: "live-center-1000x640.png"))
    captures.append(capturePNG(CenterView(model: model), width: 820, height: 600, name: "live-center-820x600.png"))
    return captures
}

// MARK: - Player

func renderPlayerEvidence(executable: String, deviceID: String, width: Int, height: Int,
                          directory: URL? = nil) -> (Capture, Int) {
    let destination = directory ?? outDirectory
    let transport = PlayerTransport()
    transport.language = options.language
    let canvas = Canvas(width: 432, height: 768)
    canvas.mount(ContentView(transport: transport, mapping: transport.mapping, sidebar: SidebarState()))
    pump(0.2)
    var firstFrameMs: Int?
    let started = Date()
    let inner = transport.onFrame
    transport.onFrame = { image, rotation in
        if firstFrameMs == nil { firstFrameMs = Int(Date().timeIntervalSince(started) * 1000) }
        inner?(image, rotation)
    }
    do {
        try transport.start(device: deviceID, width: width, height: height, executable: executable, quality: 1)
    } catch {
        fail("cannot start the live player bridge: \(error)")
    }
    let framed = waitUpTo(options.frameTimeout, until: {
        transport.linkState.isRunning && transport.frameWidth > 0 && firstFrameMs != nil
    })
    guard framed, let frameMs = firstFrameMs else {
        fail("player did not show a first frame within \(Int(options.frameTimeout)) s (state=\(transport.linkState), frame=\(transport.frameWidth)x\(transport.frameHeight))")
    }
    note("player first frame after \(frameMs) ms (\(transport.frameWidth)x\(transport.frameHeight))")
    // Let the last frame and chrome settle; the connecting notice is transient.
    pump(0.6)
    transport.onStatus?("")
    pump(0.2)
    canvas.settle(0.2)
    let captureStarted = Date()
    let rep = canvas.capture()
    guard let data = rep.representation(using: .png, properties: [:]) else { fail("cannot encode live-player.png") }
    let url = destination.appendingPathComponent("live-player-432x768.png")
    do { try data.write(to: url) } catch { fail("cannot write \(url.path): \(error)") }
    require(data.count > 10_000, "live-player-432x768.png is suspiciously small (\(data.count) bytes)")
    require(hasContent(rep), "live-player-432x768.png looks blank")
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let capture = Capture(name: "live-player-432x768.png", url: url, width: 432, height: 768,
                          bytes: data.count, sha256: digest,
                          elapsedMs: Int(Date().timeIntervalSince(captureStarted) * 1000))
    note("rendered live-player-432x768.png \(data.count) bytes in \(capture.elapsedMs) ms")
    transport.stop()
    canvas.unmount()
    pump(0.1)
    return (capture, frameMs)
}

// MARK: - Evidence

func writeEvidence(_ text: String, name: String) -> URL {
    let url = outDirectory.appendingPathComponent(name)
    do { try text.write(to: url, atomically: true, encoding: .utf8) } catch { fail("cannot write \(url.path): \(error)") }
    note("wrote \(url.path)")
    return url
}

func describeOutput(_ captures: [Capture]) -> String {
    captures.map { "  \($0.name) size=\($0.width)x\($0.height) bytes=\($0.bytes) sha256=\($0.sha256) elapsed_ms=\($0.elapsedMs)" }
        .joined(separator: "\n")
}

// MARK: - Self-test (fixtures, no daemon/emulator)

func runSelfTest() {
    let selftestDirectory = outDirectory.appendingPathComponent("selftest", isDirectory: true)
    try? FileManager.default.createDirectory(at: selftestDirectory, withIntermediateDirectories: true)
    // The fixture bridges replace the daemon/device; everything else is the same
    // rendering/assertion path used for the live evidence.
    setenv("JIDR_CENTER_FIXTURE", "populated", 1)
    let model: CenterModel
    do { model = try CenterModel(center: options.centerBridge, bridge: options.playerBridge) }
    catch { fail("cannot start the fixture center bridge: \(error)") }
    model.language = options.language
    let (device, details, centerReadyMs) = waitForCenter(model, name: nil, timeout: 30)
    require(!device.name.isEmpty, "fixture device has no name")
    require(details.device.running, "fixture device is not running")
    require(!(details.device.runtime?.adb_serial ?? "").isEmpty, "fixture device has no serial")
    require(!model.apps.isEmpty, "fixture app list is empty")
    let centerCaptures = [
        capturePNG(CenterView(model: model), width: 1000, height: 640, name: "live-center-1000x640.png",
                   directory: selftestDirectory),
        capturePNG(CenterView(model: model), width: 820, height: 600, name: "live-center-820x600.png",
                   directory: selftestDirectory),
    ]
    unsetenv("JIDR_CENTER_FIXTURE")
    model.close()

    setenv("JIDR_PLAYER_FIXTURE", "1", 1)
    let (playerCapture, frameMs) = renderPlayerEvidence(executable: options.playerBridge, deviceID: "fixture-device",
                                                        width: 1080, height: 2400, directory: selftestDirectory)
    unsetenv("JIDR_PLAYER_FIXTURE")
    var captures = centerCaptures
    captures.append(playerCapture)
    let evidence = """
    Jidr M4-C offscreen UI evidence — SELF-TEST (fixtures, no daemon/emulator)
    generated: \(ISO8601DateFormatter().string(from: Date()))
    note: harness smoke test only; live evidence is target/m4/evidence.txt
    device: name=\(device.name) id=\(device.id) status=\(device.statusText(language: options.language)) serial=\(details.device.runtime?.adb_serial ?? "-") image=\(device.androidVersion)
    timings: center_ready_ms=\(centerReadyMs) player_first_frame_ms=\(frameMs)
    outputs (selftest/):
    \(describeOutput(captures))
    assertions: PASS (center device/details/apps ready, 1000x640 + 820x600 + 432x768 non-empty, first frame seen)
    """
    let evidenceURL = selftestDirectory.appendingPathComponent("evidence-selftest.txt")
    do { try evidence.write(to: evidenceURL, atomically: true, encoding: .utf8) }
    catch { fail("cannot write \(evidenceURL.path): \(error)") }
    note("wrote \(evidenceURL.path)")
    print("SELF-TEST PASSED")
}

// MARK: - Live (real daemon + emulator)

func runLive() {
    unsetenv("JIDR_CENTER_FIXTURE")
    unsetenv("JIDR_PLAYER_FIXTURE")
    let model: CenterModel
    do { model = try CenterModel(center: options.centerBridge, bridge: options.playerBridge) }
    catch { fail("cannot start the real center bridge: \(error)") }
    model.language = options.language
    let (device, details, centerReadyMs) = waitForCenter(model, name: options.device, timeout: options.centerTimeout)

    // The task's evidence assertions: the model really carries the live device.
    require(device.name == options.device || device.id == options.device, "rendered device is not the requested device")
    require(device.running, "device is not running: \(device.statusText(language: options.language))")
    let serial = details.device.runtime?.adb_serial ?? ""
    require(!serial.isEmpty, "device has no adb serial")
    require(model.appsError == nil, "app list failed: \(model.appsError ?? "")")
    // `app.list` lists launchable *third-party* apps (`pm list packages -3`), so
    // a freshly created image legitimately has zero entries; "ready" means the
    // listing completed without an error and the center shows its real empty
    // state. A fixture/self-test image has one app and still passes here.
    require(!model.appsLoading, "app list is still loading")
    note("device asserts: name=\(device.name) status=running serial=\(serial) apps=\(model.apps.count)")
    if model.apps.isEmpty {
        note("note: fresh device has no third-party launchable apps; the center renders its empty state")
    }

    let config = details.config
    let frameWidth = Int(config["hw.lcd.width"] ?? "") ?? 1080
    let frameHeight = Int(config["hw.lcd.height"] ?? "") ?? 2400
    let centerCaptures = renderCenterEvidence(model)
    let (playerCapture, firstFrameMs) = renderPlayerEvidence(executable: options.playerBridge, deviceID: device.id,
                                                             width: frameWidth, height: frameHeight)
    model.close()

    var captures = centerCaptures
    captures.append(playerCapture)
    let totalMs = Int(Date().timeIntervalSince(runStarted) * 1000)
    let environment = ProcessInfo.processInfo.environment
    let evidence = """
    Jidr M4-C offscreen UI evidence — LIVE (real daemon + real emulator)
    generated: \(ISO8601DateFormatter().string(from: Date()))
    environment: JIDR_HOME=\(environment["JIDR_HOME"] ?? "-") ANDROID_HOME=\(environment["ANDROID_HOME"] ?? "-") JIDR_TEST_SDK=\(environment["JIDR_TEST_SDK"] ?? "-")
    binaries: center_bridge=\(options.centerBridge) player_bridge=\(options.playerBridge)
    device: name=\(device.name) id=\(device.id) status=running serial=\(serial)
            image=\(device.androidVersion) tag=\(device.image.tag) profile=\(device.profile) sdk_root=\(device.sdk_root)
            screen=\(frameWidth)x\(frameHeight) dpi=\(config["hw.lcd.density"] ?? "-") ram_mb=\(config["hw.ramSize"] ?? "-") cpus=\(config["hw.cpu.ncore"] ?? "-")
    apps: count=\(model.apps.count) state=\(model.apps.isEmpty ? "empty (fresh image: no third-party launchable apps)" : "loaded") note=\(model.appsNote ?? "-")
    timings: device_create_ms=\(options.createMs) device_boot_ms=\(options.bootMs) center_ready_ms=\(centerReadyMs) render_total_ms=\(totalMs) player_first_frame_ms=\(firstFrameMs)
    outputs:
    \(describeOutput(captures))
    assertions: PASS (device name/status/serial in model, app list ready (count=\(model.apps.count); empty is expected on a fresh image), PNG sizes/non-blank, player first frame)
    """
    _ = writeEvidence(evidence, name: "evidence.txt")
    print("LIVE EVIDENCE PASSED")
}

if options.selfTest { runSelfTest() } else { runLive() }
