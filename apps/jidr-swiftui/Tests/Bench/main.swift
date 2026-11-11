// SPDX-License-Identifier: GPL-3.0-only
// M4-B SwiftUI player performance harness (standalone; it is not part of the app).
//
// It measures the same transport path as the SwiftUI player window:
// `jidr-swiftui-bridge` JFR1 frames -> Sources/FrameDecoder.swift -> newest-frame
// slot -> one main-queue hop -> an AppKit view draw mirroring ScreenView.draw.
// Method and thresholds follow docs/decisions/0001-frame-transport.md and
// docs/display-performance.md. Historical toolkit comparisons remain in the docs.
//
// The probe latency measurement is the ADR-0001 method: with `dev.set
// show_taps=true`, send a touch-down through the player bridge and time the
// first frame presented on the UI hop whose probe patch changed (the show-taps
// dot). It excludes the OS input path and scanout, like the ADR says.
//
// `--self-test` runs the offline checks used before a real device is available:
// argument parsing, percentiles, frame decoding, newest-frame slot, patch
// detection, latency bookkeeping and report encoding.

import AppKit
import CoreGraphics
import CoreText
import Foundation

// MARK: - Process facts

func now() -> Double { ProcessInfo.processInfo.systemUptime }

func writeStderr(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

// MARK: - Command line

struct Options: Equatable {
    var device = ""
    var bridge = ""
    var panelWidth = 1080
    var panelHeight = 2400
    var quality = 1
    var seconds = 10.0
    var taps = 30
    var windowWidth = 340
    var windowHeight = 752
    var probeX = 0.5
    var probeY = 0.55
    var probeThreshold = 30.0
    var dumpDir = ""
    var settleSeconds = 1.0
    var tapTimeoutSeconds = 1.5
    var jsonOut = ""
    var fpsDrive = false
    var hiddenWindow = false
    var firstFrameTimeout = 15.0
    var selfTest = false
    var productionPlayer = false
    var restoreProbes = 0
    /// Place the bench window on this NSScreen index (0-based) so a 60/120 Hz
    /// display can be measured; -1 keeps AppKit's default placement.
    var screen = -1
}

func usage() -> String {
    """
    usage: jidr-swiftui-bench --device NAME --bridge PATH [options]

      --panel-width N        device panel width in px (default 1080)
      --panel-height N       device panel height in px (default 2400)
      --quality 0|1|2        bridge stream quality (default 1)
      --seconds N            frame-rate window in s (default 10)
      --taps N               latency probes, 0 disables (default 30)
      --window WxH           display window in points (default 340x752)
      --probe X,Y            normalized probe point (default 0.5,0.55)
      --probe-threshold F    patch RGB delta that counts as a change (default 30)
      --dump-dir DIR         save the first detected probe frames (PNG + JSONL)
      --settle N             warmup after the first frame in s (default 1)
      --tap-timeout N        per-tap detection timeout in s (default 1.5)
      --json-out PATH        write the machine-readable report
      --fps-drive            drive scroll gestures during the frame-rate phase
                             (ADR-0001 fps bench; use a scrollable scene)
      --first-frame-timeout N  fail after N s without a frame (default 15)
      --screen N             place the window on NSScreen.screens[N] (for a display with a known refresh rate)
      --hidden-window        do not show the window (render-failure check only)
      --production-player    measure the real GameWindowController/ScreenView;
                             requires a device UUID and explicit isolated JIDR_HOME
      --restore-probes N     measure fresh-frame latency after native minimize/restore
      --self-test            run offline checks and exit (no device/window)
      -h, --help             this text
    """
}

enum ParseError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let text): return text }
    }
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var index = 0
    func value(_ name: String) throws -> String {
        index += 1
        guard index < arguments.count else { throw ParseError.message("\(name) needs a value") }
        return arguments[index]
    }
    func int(_ name: String, _ range: ClosedRange<Int>) throws -> Int {
        let raw = try value(name)
        guard let parsed = Int(raw), range.contains(parsed) else {
            throw ParseError.message("\(name) must be an integer in \(range), got \(raw)")
        }
        return parsed
    }
    func double(_ name: String, _ range: ClosedRange<Double>) throws -> Double {
        let raw = try value(name)
        guard let parsed = Double(raw), parsed.isFinite, range.contains(parsed) else {
            throw ParseError.message("\(name) must be a number in \(range), got \(raw)")
        }
        return parsed
    }
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "-h", "--help":
            print(usage())
            exit(0)
        case "--self-test": options.selfTest = true
        case "--production-player": options.productionPlayer = true
        case "--restore-probes": options.restoreProbes = try int(argument, 0...10)
        case "--device": options.device = try value(argument)
        case "--bridge": options.bridge = try value(argument)
        case "--panel-width": options.panelWidth = try int(argument, 1...8192)
        case "--panel-height": options.panelHeight = try int(argument, 1...8192)
        case "--quality": options.quality = try int(argument, 0...2)
        case "--seconds": options.seconds = Double(try int(argument, 1...120))
        case "--taps": options.taps = try int(argument, 0...200)
        case "--window":
            let raw = try value(argument)
            let parts = raw.lowercased().split(separator: "x")
            guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]),
                  (120...4000).contains(width), (120...4000).contains(height) else {
                throw ParseError.message("--window must be WxH within 120...4000, got \(raw)")
            }
            options.windowWidth = width
            options.windowHeight = height
        case "--probe":
            let raw = try value(argument)
            let parts = raw.split(separator: ",")
            guard parts.count == 2, let x = Double(parts[0]), let y = Double(parts[1]),
                  x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
                throw ParseError.message("--probe must be X,Y with 0...1, got \(raw)")
            }
            options.probeX = x
            options.probeY = y
        case "--probe-threshold": options.probeThreshold = try double(argument, 1...765)
        case "--dump-dir": options.dumpDir = try value(argument)
        case "--first-frame-timeout": options.firstFrameTimeout = try double(argument, 0.2...60)
        case "--screen": options.screen = try int(argument, 0...7)
        case "--hidden-window": options.hiddenWindow = true
        case "--fps-drive": options.fpsDrive = true
        case "--settle": options.settleSeconds = try double(argument, 0...10)
        case "--tap-timeout": options.tapTimeoutSeconds = try double(argument, 0.1...10)
        case "--json-out": options.jsonOut = try value(argument)
        default:
            throw ParseError.message("unknown argument \(argument)")
        }
        index += 1
    }
    if !options.selfTest {
        if options.restoreProbes > 0 && !options.productionPlayer {
            throw ParseError.message("restore probes require --production-player")
        }
        guard !options.device.isEmpty else { throw ParseError.message("--device is required") }
        guard !options.bridge.isEmpty else { throw ParseError.message("--bridge is required") }
        guard FileManager.default.isExecutableFile(atPath: options.bridge) else {
            throw ParseError.message("bridge is not executable: \(options.bridge)")
        }
        if options.productionPlayer {
            guard UUID(uuidString: options.device) != nil,
                  let home = ProcessInfo.processInfo.environment["JIDR_HOME"], home.hasPrefix("/") else {
                throw ParseError.message("production-player requires a device UUID and explicit absolute JIDR_HOME")
            }
        }
    }
    return options
}

// MARK: - Statistics

enum Stat {
    /// Same nearest-rank percentile as `crates/jidr-ui/src/player/session.rs`.
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int(((Double(sorted.count - 1)) * p).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    /// 1 / median inter-frame interval, ignoring gaps >= 100 ms (ADR-0001).
    static func activeFPS(intervals: [Double]) -> Double? {
        let active = intervals.filter { $0 < 100 }
        guard let median = percentile(active, 0.5), median > 0 else { return nil }
        return 1000 / median
    }
}

/// Frame-rate buckets computed from frame timestamps, not from main-thread
/// timer samples (timers jitter while the UI thread draws). ADR-0001 wants a
/// 10 s window; 1 s buckets give the per-second distribution, 250 ms buckets
/// give the "active fps" median while frames are flowing.
struct RateBucket {
    let start: Double
    let frames: Int
    let rate: Double
}

enum FPSBuckets {
    static func buckets(times: [Double], bucketSeconds: Double,
                        start: Double, end: Double) -> [RateBucket] {
        guard bucketSeconds > 0, end > start else { return [] }
        let count = max(1, Int(((end - start) / bucketSeconds).rounded(.up)))
        var frames = [Int](repeating: 0, count: count)
        for time in times where time >= start && time <= end {
            let index = min(count - 1, max(0, Int((time - start) / bucketSeconds)))
            frames[index] += 1
        }
        return (0..<count).map { index in
            let lower = start + Double(index) * bucketSeconds
            let upper = min(end, lower + bucketSeconds)
            let span = max(0.001, upper - lower)
            return RateBucket(start: lower, frames: frames[index], rate: Double(frames[index]) / span)
        }
    }

    /// Median rate over buckets that contain at least two frames.
    static func activeMedian(_ buckets: [RateBucket]) -> Double? {
        let rates = buckets.filter { $0.frames >= 2 }.map(\.rate)
        guard !rates.isEmpty else { return nil }
        return Stat.percentile(rates, 0.5)
    }

    static func percentiles(_ buckets: [RateBucket]) -> (median: Double?, p10: Double?) {
        let rates = buckets.filter { $0.frames >= 2 }.map(\.rate)
        guard !rates.isEmpty else { return (nil, nil) }
        return (Stat.percentile(rates, 0.5), Stat.percentile(rates, 0.1))
    }
}

// MARK: - Probe patch and latency detection

struct Patch: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    static let zero = Patch(red: 0, green: 0, blue: 0)

    /// Mean RGB of a small square around a normalized point in the decoded RGBA
    /// frame (the same frame the view draws). Returns nil for an empty frame.
    static func sample(pixels: Data, width: Int, height: Int,
                       normalizedX: Double, normalizedY: Double, radius: Int) -> Patch? {
        guard width > 0, height > 0, pixels.count >= width * height * 4 else { return nil }
        let centerX = min(max(Int(normalizedX * Double(width)), 0), width - 1)
        let centerY = min(max(Int(normalizedY * Double(height)), 0), height - 1)
        var red = 0.0, green = 0.0, blue = 0.0, count = 0.0
        for y in max(0, centerY - radius)...min(height - 1, centerY + radius) {
            for x in max(0, centerX - radius)...min(width - 1, centerX + radius) {
                let offset = (y * width + x) * 4
                red += Double(pixels[offset])
                green += Double(pixels[offset + 1])
                blue += Double(pixels[offset + 2])
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return Patch(red: red / count, green: green / count, blue: blue / count)
    }

    func distance(to other: Patch) -> Double {
        abs(red - other.red) + abs(green - other.green) + abs(blue - other.blue)
    }
}

/// The last touch probe waiting for the show-taps dot to appear on the UI hop.
struct PendingTouch {
    let sentAt: Double
    let baseline: Patch
    var detectedLatencyMilliseconds: Double?
}

/// Touch→frame probe detector. `beginTouch` records the touch-down time and the
/// patch of the last presented frame; every frame presented on the UI hop is
/// observed, and the first changed patch records the latency.
final class ProbeDetector {
    private let condition = NSCondition()
    private var pending: PendingTouch?
    private var timeouts = 0
    private var detections = 0
    private var lastDetection: (baseline: Patch, observed: Patch, latency: Double)?
    private let threshold: Double
    let probeX: Double
    let probeY: Double
    let radius: Int

    init(threshold: Double, probeX: Double, probeY: Double, radius: Int = 3) {
        self.threshold = threshold
        self.probeX = probeX
        self.probeY = probeY
        self.radius = radius
    }

    var detected: Int { condition.lock(); defer { condition.unlock() }; return detections }
    var missed: Int { condition.lock(); defer { condition.unlock() }; return timeouts }

    func beginTouch(at time: Double, baseline: Patch) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard pending == nil else { return false }
        pending = PendingTouch(sentAt: time, baseline: baseline, detectedLatencyMilliseconds: nil)
        return true
    }

    /// Returns the latency when this frame is the changed (dot) frame.
    @discardableResult
    func observe(patch: Patch, at time: Double) -> Double? {
        condition.lock()
        defer { condition.unlock() }
        guard var current = pending, current.detectedLatencyMilliseconds == nil else { return nil }
        guard patch.distance(to: current.baseline) >= threshold else { return nil }
        let latency = max(0, (time - current.sentAt) * 1000)
        current.detectedLatencyMilliseconds = latency
        pending = current
        detections += 1
        lastDetection = (current.baseline, patch, latency)
        condition.broadcast()
        return latency
    }

    /// Blocks the tap driver until the frame is detected or `timeout` elapses.
    func waitForDetection(timeout: Double) -> Double? {
        condition.lock()
        defer { condition.unlock() }
        guard pending != nil else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while pending?.detectedLatencyMilliseconds == nil {
            if !condition.wait(until: deadline) { break }
        }
        let result = pending?.detectedLatencyMilliseconds
        if result == nil { timeouts += 1 }
        pending = nil
        return result
    }

    func cancelTouch() {
        condition.lock()
        pending = nil
        condition.unlock()
    }

    /// Baseline/observed patches of the most recent detection, for --dump-dir.
    func lastDetectedProbe() -> (baseline: Patch, observed: Patch, latency: Double)? {
        condition.lock()
        defer { condition.unlock() }
        return lastDetection
    }
}

// MARK: - Newest-frame slot (ADR-0001 rule 5)

/// Pure newest-frame slot: a newer frame replaces an undrained one. Extracted so
/// the self-test can prove the "never build a backlog" rule without a window.
struct LatestSlot<Frame> {
    private(set) var latest: Frame?
    private(set) var replaced = 0

    mutating func submit(_ frame: Frame) {
        if latest != nil { replaced += 1 }
        latest = frame
    }

    mutating func take() -> Frame? {
        let frame = latest
        latest = nil
        return frame
    }
}

// MARK: - Recorder

struct Counter: Equatable {
    var received = 0
    var presented = 0
    var drawn = 0
    var replaced = 0
    var bytes = 0
}

struct BenchFrame {
    let image: CGImage
    let width: Int
    let height: Int
    let rotation: Int
    let patch: Patch
    let receivedAt: Double
}

final class Recorder {
    private let lock = NSLock()
    private var counter = Counter()
    private var receiveTimes: [Double] = []
    private var drawTimes: [Double] = []
    private var presentedTimes: [Double] = []
    private var lastPresentedPatch: Patch?
    private var rssMegabytes: Double?
    private var latencySamples: [Double] = []
    let detector: ProbeDetector

    init(options: Options) {
        detector = ProbeDetector(threshold: options.probeThreshold,
                                 probeX: options.probeX, probeY: options.probeY)
    }

    func noteReceived(bytes: Int, at time: Double) {
        lock.lock()
        counter.received += 1
        counter.bytes += bytes
        receiveTimes.append(time)
        if receiveTimes.count > 20_000 { receiveTimes.removeFirst(receiveTimes.count - 20_000) }
        lock.unlock()
    }

    @discardableResult
    func notePresented(patch: Patch, at time: Double, detect: Bool = true) -> Double? {
        lock.lock()
        counter.presented += 1
        presentedTimes.append(time)
        if presentedTimes.count > 20_000 { presentedTimes.removeFirst(presentedTimes.count - 20_000) }
        lastPresentedPatch = patch
        lock.unlock()
        return detect ? detector.observe(patch: patch, at: time) : nil
    }

    func noteDrawn(at time: Double) {
        lock.lock()
        counter.drawn += 1
        drawTimes.append(time)
        if drawTimes.count > 20_000 { drawTimes.removeFirst(drawTimes.count - 20_000) }
        lock.unlock()
    }

    func noteReplaced() {
        lock.lock()
        counter.replaced += 1
        lock.unlock()
    }

    func snapshot() -> Counter {
        lock.lock()
        defer { lock.unlock() }
        return counter
    }

    var presentedPatch: Patch? {
        lock.lock()
        defer { lock.unlock() }
        return lastPresentedPatch
    }

    func times(_ kind: String, between start: Double, and end: Double) -> [Double] {
        lock.lock()
        let source: [Double]
        switch kind {
        case "received": source = receiveTimes
        case "presented": source = presentedTimes
        default: source = drawTimes
        }
        lock.unlock()
        return source.filter { $0 >= start && $0 <= end }
    }

    func receiveIntervals(after start: Double, before end: Double) -> [Double] {
        lock.lock()
        let times = receiveTimes.filter { $0 >= start && $0 <= end }
        lock.unlock()
        return zip(times, times.dropFirst()).map { ($0.1 - $0.0) * 1000 }
    }

    func drawIntervals(after start: Double, before end: Double) -> [Double] {
        lock.lock()
        let times = drawTimes.filter { $0 >= start && $0 <= end }
        lock.unlock()
        return zip(times, times.dropFirst()).map { ($0.1 - $0.0) * 1000 }
    }

    func recordLatency(_ value: Double) {
        lock.lock()
        latencySamples.append(value)
        lock.unlock()
    }

    var latencies: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return latencySamples
    }

    func setRSSMegabytes(_ value: Double?) {
        lock.lock()
        rssMegabytes = value
        lock.unlock()
    }

    var rss: Double? {
        lock.lock()
        defer { lock.unlock() }
        return rssMegabytes
    }
}

// MARK: - Frame pump: reader thread -> newest slot -> one UI hop

final class FramePump {
    private let lock = NSLock()
    private var slot = LatestSlot<BenchFrame>()
    private var scheduled = false
    private var finished = false
    private let recorder: Recorder
    var onPresent: ((BenchFrame, Double?) -> Void)?
    var onFinished: (() -> Void)?

    init(recorder: Recorder) { self.recorder = recorder }

    func submit(_ frame: BenchFrame) {
        recorder.noteReceived(bytes: frame.width * frame.height * 4, at: frame.receivedAt)
        lock.lock()
        if slot.latest != nil { recorder.noteReplaced() }
        slot.submit(frame)
        let needsSchedule = !scheduled
        if needsSchedule { scheduled = true }
        lock.unlock()
        if needsSchedule {
            DispatchQueue.main.async { [weak self] in self?.drain() }
        }
    }

    private func drain() {
        lock.lock()
        let frame = slot.take()
        scheduled = false
        let done = finished
        lock.unlock()
        if let frame {
            let detection = recorder.notePresented(patch: frame.patch, at: now())
            onPresent?(frame, detection)
        }
        if done { onFinished?() }
    }

    func finish() {
        lock.lock()
        finished = true
        let needsDrain = scheduled
        lock.unlock()
        if !needsDrain {
            DispatchQueue.main.async { [weak self] in self?.onFinished?() }
        }
    }
}

// MARK: - Display view (mirrors ScreenView.draw)

final class BenchView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var onDraw: ((Double) -> Void)?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        guard let image, image.width > 0, image.height > 0 else { return }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let rect = NSRect(x: (bounds.width - size.width) / 2,
                          y: (bounds.height - size.height) / 2,
                          width: size.width, height: size.height)
        let backing = window?.backingScaleFactor ?? 1
        let exact = abs(rect.width * backing - CGFloat(image.width)) < 0.5
            && abs(rect.height * backing - CGFloat(image.height)) < 0.5
        NSGraphicsContext.current?.imageInterpolation = exact ? .none : .high
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(in: rect)
        onDraw?(now())
    }
}

/// Measurement only: one queued main-thread probe at most, with bounded storage.
final class MainQueueProbe {
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private var pending = false
    private var samples: [(Double, Double)] = []
    func start() {
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        source.schedule(deadline: .now(), repeating: .milliseconds(100))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.pending { self.lock.unlock(); return }
            self.pending = true
            self.lock.unlock()
            let submitted = now()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let time = now()
                self.samples.append((time, max(0, time - submitted) * 1000))
                if self.samples.count > 20_000 { self.samples.removeFirst(self.samples.count - 20_000) }
                self.lock.lock(); self.pending = false; self.lock.unlock()
            }
        }
        timer = source; source.resume()
    }
    func stop() { timer?.cancel(); timer = nil }
    func values(from start: Double, to end: Double) -> [Double] {
        samples.filter { $0.0 >= start && $0.0 <= end }.map { $0.1 }
    }
    deinit { stop() }
}

func distribution(_ values: [Double]) -> [String: Any] {
    ["count": values.count, "p50": Stat.percentile(values, 0.5) ?? NSNull(),
     "p95": Stat.percentile(values, 0.95) ?? NSNull(),
     "p99": Stat.percentile(values, 0.99) ?? NSNull(), "max": values.max() ?? NSNull()]
}

func freshFrameLatency(requested: Double, received: Double, drawn: Double) -> Double? {
    guard requested.isFinite, received.isFinite, drawn.isFinite,
          received >= requested, drawn >= received else { return nil }
    return (drawn - requested) * 1000
}

func memoryMiB(_ value: String) -> Double? {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let suffix = text.last, let number = Double(text.dropLast()), number.isFinite, number >= 0 else { return nil }
    switch suffix {
    case "K": return number / 1024
    case "M": return number
    case "G": return number * 1024
    default: return nil
    }
}

/// Queried only after the timed phases; vmmap overhead cannot change the fps/latency window.
func footprint(pid: Int32) -> [String: Any] {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/vmmap")
    process.arguments = ["-summary", String(pid)]
    process.standardOutput = output; process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return ["available": false] }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return ["available": false] }
    let text = String(decoding: data, as: UTF8.self)
    var result: [String: Any] = ["available": true]
    for line in text.split(separator: "\n") {
        if line.hasPrefix("Physical footprint:") {
            result["physical_mib"] = memoryMiB(String(line.split(separator: ":").last ?? ""))
        } else if line.hasPrefix("Physical footprint (peak):") {
            result["peak_physical_mib"] = memoryMiB(String(line.split(separator: ":").last ?? ""))
        }
    }
    if result["physical_mib"] == nil || result["peak_physical_mib"] == nil { result["available"] = false }
    return result
}

// MARK: - Process helpers

func processCPUSeconds(pid: Int32 = getpid()) -> Double? {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/ps")
    child.arguments = ["-o", "time=", "-p", String(pid)]
    let pipe = Pipe()
    child.standardOutput = pipe
    child.standardError = FileHandle.nullDevice
    do { try child.run() } catch { return nil }
    child.waitUntilExit()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    // "MM:SS.ss" or "HH:MM:SS.ss" (apple `ps -o time`).
    var seconds = 0.0
    for part in text.split(separator: ":") {
        guard let value = Double(part) else { return nil }
        seconds = seconds * 60 + value
    }
    return seconds
}

func processRSSMegabytes() -> Double? {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/ps")
    child.arguments = ["-o", "rss=", "-p", String(getpid())]
    let pipe = Pipe()
    child.standardOutput = pipe
    child.standardError = FileHandle.nullDevice
    do { try child.run() } catch { return nil }
    child.waitUntilExit()
    let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return Double(text).map { $0 / 1024 }
}

func makeImage(from frame: DecodedFrame) -> CGImage? {
    let width = frame.width, height = frame.height
    let pixels = frame.pixels
    guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

// MARK: - Bench orchestration

final class Bench {
    let options: Options
    let recorder: Recorder
    var window: NSWindow
    let view: BenchView
    let pump: FramePump
    var bridge: Process?
    var bridgeInput: FileHandle?
    var dumpedDetections = 0
    let writeLock = NSLock()
    var stderrLines: [String] = []
    var production: GameWindowController?
    private let mainQueueProbe = MainQueueProbe()
    private var presentation = 0
    private var drawnPresentation = 0
    private var lastPresentedReceivedAt = 0.0
    private var restoreSamples: [Double] = []
    private var restoreAttempt = 0
    private var restoreTimeouts = 0
    private var restoreRequestedAt: Double?
    private var launchedAt = 0.0


    // FPS phase
    var fpsStart = 0.0
    var fpsCounterStart = Counter()
    var cpuStart: Double?
    var bridgePid: Int32?
    var bridgeCpuStart: Double?
    var phaseEnd = 0.0
    var fpsResult: [String: Any] = [:]
    // Latency phase
    var latencies: [Double] = []

    init(options: Options) throws {
        self.options = options
        recorder = Recorder(options: options)
        let view = BenchView(frame: NSRect(x: 0, y: 0, width: options.windowWidth, height: options.windowHeight))
        self.view = view
        pump = FramePump(recorder: recorder)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: options.windowWidth, height: options.windowHeight),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = view
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if options.screen >= 0, options.screen < NSScreen.screens.count {
            let visible = NSScreen.screens[options.screen].visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                          y: visible.midY - size.height / 2))
        }
        pump.onPresent = { [weak self] frame, detection in
            guard let self else { return }
            self.view.image = frame.image
            if detection != nil { self.dumpProbeEvidence(frame.image) }
        }
        pump.onFinished = { [weak self] in
            guard let self else { return }
            self.finish(code: ExitCode.bridgeFailure.rawValue,
                        reason: "bridge stream ended before the benchmark finished")
        }
        view.onDraw = { [weak self] time in
            // Only count draws while the benchmark window is actually on screen;
            // a hidden/offscreen window still runs AppKit's display cycle, and
            // counting those draws would hide a "no GUI session" failure.
            guard let self, self.window.isVisible else { return }
            self.recorder.noteDrawn(at: time)
        }
    }

    enum ExitCode: Int32 {
        case ok = 0
        case usage = 2
        case bridgeFailure = 3
        case latencyFailure = 4
        case renderFailure = 5
    }

    // MARK: Setup

    /// Refresh rate of the display the bench window is on. AppKit draws at most
    /// once per refresh, so `displayed_fps` cannot exceed this.
    private func displayRefreshHz() -> Double? {
        guard let screen = window.screen ?? NSScreen.main else { return nil }
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        if let id = number.map({ CGDirectDisplayID($0.uint32Value) }),
           let mode = CGDisplayCopyDisplayMode(id), mode.refreshRate > 0 {
            return mode.refreshRate
        }
        let max = screen.maximumFramesPerSecond
        return max > 0 ? Double(max) : nil
    }

    func start() {
        launchedAt = now()
        do {
            if options.productionPlayer { try startProductionPlayer() }
            else { try startBridge() }
            mainQueueProbe.start()
        } catch {
            finish(code: ExitCode.bridgeFailure.rawValue, reason: "cannot start bridge: \(error)")
            return
        }
        if !options.hiddenWindow {
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
        } else {
            writeStderr("bench: --hidden-window: the window is not shown; expect no draws")
        }
        let deadline = now() + options.firstFrameTimeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.waitForFirstFrame(deadline: deadline) }
    }

    private func startProductionPlayer() throws {
        let home = ProcessInfo.processInfo.environment["JIDR_HOME"] ?? ""
        let data = URL(fileURLWithPath: home).appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let player = GameWindowController()
        player.transport.language = 0
        player.open(device: options.device, width: options.panelWidth, height: options.panelHeight,
                    executable: options.bridge, quality: UInt8(options.quality), dataDirectory: data.path,
                    launch: .stopped(reason: "Preparing measurement"))
        guard let realWindow = player.window else { throw ParseError.message("player window did not open") }
        realWindow.contentView?.layoutSubtreeIfNeeded()
        guard let render = player.transport.onFrame else { throw ParseError.message("ScreenView did not attach") }
        window.close()
        window = realWindow
        production = player
        if options.screen >= 0, options.screen < NSScreen.screens.count {
            let screen = NSScreen.screens[options.screen].visibleFrame
            window.setFrameOrigin(NSPoint(x: screen.midX - window.frame.width / 2,
                                          y: screen.midY - window.frame.height / 2))
        }
        player.transport.measureDecodedFrame = { [weak self] frame in
            let time = now()
            let patch = Patch.sample(pixels: frame.pixels, width: frame.width, height: frame.height,
                                     normalizedX: self?.options.probeX ?? 0.5,
                                     normalizedY: self?.options.probeY ?? 0.55, radius: 3) ?? .zero
            self?.recorder.noteReceived(bytes: frame.width * frame.height * 4, at: time)
            return PlayerFrameProbeSample(receivedAt: time, red: patch.red, green: patch.green, blue: patch.blue)
        }
        player.transport.onFrameReplaced = { [weak self] in self?.recorder.noteReplaced() }
        player.transport.onFrame = { [weak self] image, rotation in
            render(image, rotation)
            guard let self else { return }
            self.view.image = image // Retain the same image, not a second decoded buffer.
            self.presentation += 1
        }
        player.transport.onMeasuredFramePresented = { [weak self] sample in
            guard let self else { return }
            let patch = Patch(red: sample.red, green: sample.green, blue: sample.blue)
            self.recorder.notePresented(patch: patch, at: now(), detect: false)
            self.lastPresentedReceivedAt = sample.receivedAt
        }
        player.transport.onFrameDrawn = { [weak self] in
            guard let self, self.window.isVisible, !self.window.isMiniaturized,
                  self.presentation != self.drawnPresentation else { return }
            self.drawnPresentation = self.presentation
            let time = now()
            self.recorder.noteDrawn(at: time)
            if let patch = self.recorder.presentedPatch,
               self.recorder.detector.observe(patch: patch, at: time) != nil,
               let image = self.view.image { self.dumpProbeEvidence(image) }
            if let requested = self.restoreRequestedAt,
               let latency = freshFrameLatency(requested: requested, received: self.lastPresentedReceivedAt, drawn: time) {
                self.restoreSamples.append(latency)
                self.restoreRequestedAt = nil
                self.nextRestoreProbe()
            }
        }
        player.transport.beginStreaming()
        bridgePid = player.transport.bridgeProcessIdentifier
    }

    private func startBridge() throws {
        let child = Process()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        child.executableURL = URL(fileURLWithPath: options.bridge)
        child.arguments = [options.device, String(options.panelWidth), String(options.panelHeight),
                           String(options.quality)]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = errors
        child.terminationHandler = { [weak self] child in
            DispatchQueue.main.async {
                guard let self else { return }
                self.pump.finish()
            }
        }
        try child.run()
        bridge = child
        bridgePid = child.processIdentifier
        bridgeInput = input.fileHandleForWriting
        let stdout = output.fileHandleForReading
        let probeX = options.probeX, probeY = options.probeY
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let decoder = FrameDecoder()
            while true {
                let data = stdout.availableData
                if data.isEmpty { break }
                let valid = decoder.consume(data) { frame in
                    guard let self else { return }
                    let patch = Patch.sample(pixels: frame.pixels, width: frame.width, height: frame.height,
                                             normalizedX: probeX, normalizedY: probeY, radius: 3) ?? .zero
                    guard let image = makeImage(from: frame) else { return }
                    self.pump.submit(BenchFrame(image: image, width: frame.width, height: frame.height,
                                                rotation: frame.rotation, patch: patch, receivedAt: now()))
                }
                if !valid {
                    DispatchQueue.main.async { self?.pump.finish() }
                    break
                }
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let handle = errors.fileHandleForReading
            var buffer = Data()
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = String(decoding: buffer.prefix(upTo: newline), as: UTF8.self)
                    buffer.removeSubrange(...newline)
                    guard !line.isEmpty else { continue }
                    DispatchQueue.main.async {
                        self?.stderrLines.append(line)
                        if (self?.stderrLines.count ?? 0) > 20 { self?.stderrLines.removeFirst() }
                    }
                    writeStderr("bridge: \(line)")
                }
            }
        }
    }

    private func send(_ command: [String: Any]) {
        if let production { production.transport.send(command); return }
        guard JSONSerialization.isValidJSONObject(command),
              let data = try? JSONSerialization.data(withJSONObject: command),
              let handle = bridgeInput else { return }
        writeLock.lock()
        defer { writeLock.unlock() }
        var line = data
        line.append(10)
        try? handle.write(contentsOf: line)
    }

    /// Saves the first detected show-taps frames so the probe method can be
    /// inspected on a real device (baseline/observed patch values, PNG).
    private func dumpProbeEvidence(_ image: CGImage) {
        guard !options.dumpDir.isEmpty, dumpedDetections < 3 else { return }
        dumpedDetections += 1
        let directory = URL(fileURLWithPath: options.dumpDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = String(format: "probe-%02d", dumpedDetections)
        let probe = recorder.detector.lastDetectedProbe()
        let rep = NSBitmapImageRep(cgImage: image)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: directory.appendingPathComponent(name + ".png"))
        }
        let line: [String: Any] = [
            "latency_ms": probe?.latency ?? NSNull(),
            "baseline_rgb": probe.map { [$0.baseline.red, $0.baseline.green, $0.baseline.blue] } ?? [],
            "observed_rgb": probe.map { [$0.observed.red, $0.observed.green, $0.observed.blue] } ?? [],
            "distance": probe.map { $0.baseline.distance(to: $0.observed) } ?? NSNull(),
            "frame": ["width": image.width, "height": image.height],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]) {
            let file = directory.appendingPathComponent("probes.jsonl")
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.write(Data([10]))
                try? handle.close()
            } else {
                try? (data + Data([10])).write(to: file)
            }
        }
    }

    // MARK: Phases

    private func waitForFirstFrame(deadline: Double) {
        if recorder.snapshot().received > 0 {
            if production != nil {
                window.setContentSize(NSSize(width: options.windowWidth + 48, height: options.windowHeight))
            }
            writeStderr("bench: first frame received, settling \(options.settleSeconds)s")
            DispatchQueue.main.asyncAfter(deadline: .now() + options.settleSeconds) { [weak self] in
                self?.startFPSPhase()
            }
            return
        }
        if now() > deadline {
            finish(code: ExitCode.bridgeFailure.rawValue,
                   reason: "no frames received in \(Int(options.firstFrameTimeout)) s (is the device running and the bridge reachable?)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForFirstFrame(deadline: deadline)
        }
    }

    private func startFPSPhase() {
        fpsCounterStart = recorder.snapshot()
        fpsStart = now()
        phaseEnd = fpsStart + options.seconds
        cpuStart = processCPUSeconds()
        bridgeCpuStart = bridgePid.flatMap { processCPUSeconds(pid: $0) }
        view.needsDisplay = true
        startFPSDriver()
        DispatchQueue.main.asyncAfter(deadline: .now() + options.seconds) { [weak self] in
            self?.finishFPSPhase()
        }
    }

    /// ADR-0001 fps bench: keep the emulator producing frames by injecting
    /// alternating vertical drags through the player's own input path while the
    /// frame-rate phase runs. The scene has to be scrollable (the shell script
    /// opens Settings first). Stops before the latency taps start.
    private func startFPSDriver() {
        guard options.fpsDrive else { return }
        let queue = DispatchQueue(label: "jidr.bench.fps-driver")
        queue.async { [weak self] in
            guard let self else { return }
            let steps = 24
            let sweep = 0.30
            var up = true
            while !self.driverStopped {
                let (startY, endY) = up ? (0.78, 0.30) : (0.30, 0.78)
                up.toggle()
                self.send(["type": "touch", "x": 0.5, "y": startY, "down": true])
                for step in 1...steps {
                    if self.driverStopped { break }
                    let y = startY + (endY - startY) * Double(step) / Double(steps)
                    self.send(["type": "touch", "x": 0.5, "y": y, "down": true])
                    Thread.sleep(forTimeInterval: sweep / Double(steps))
                }
                self.send(["type": "touch", "x": 0.5, "y": endY, "down": false])
                Thread.sleep(forTimeInterval: 0.10)
            }
            self.send(["type": "touch", "x": 0.5, "y": 0.5, "down": false])
        }
    }

    private let driverLock = NSLock()
    private var driverStopFlag = false
    var driverStopped: Bool {
        get { driverLock.lock(); defer { driverLock.unlock() }; return driverStopFlag }
        set { driverLock.lock(); driverStopFlag = newValue; driverLock.unlock() }
    }

    private func finishFPSPhase() {
        driverStopped = true
        let phaseEndTime = now()
        let elapsed = phaseEndTime - fpsStart
        let end = recorder.snapshot()
        let received = Double(end.received - fpsCounterStart.received)
        let presented = Double(end.presented - fpsCounterStart.presented)
        let drawn = Double(end.drawn - fpsCounterStart.drawn)
        let bytes = Double(end.bytes - fpsCounterStart.bytes)
        let cpuEnd = processCPUSeconds()
        let cpuPercent: Double? = {
            guard let start = cpuStart, let finish = cpuEnd else { return nil }
            return (finish - start) / elapsed * 100
        }()
        let bridgeCpuEnd = bridgePid.flatMap { processCPUSeconds(pid: $0) }
        let bridgeCpuPercent: Double? = {
            guard let start = bridgeCpuStart, let finish = bridgeCpuEnd else { return nil }
            return (finish - start) / elapsed * 100
        }()
        recorder.setRSSMegabytes(processRSSMegabytes())
        let receiveIntervals = recorder.receiveIntervals(after: fpsStart, before: phaseEndTime)
        // Per-second and 250 ms rates from frame timestamps (not from
        // main-timer counter samples, which jitter while the UI thread draws).
        func buckets(_ kind: String, _ width: Double) -> [RateBucket] {
            FPSBuckets.buckets(times: recorder.times(kind, between: fpsStart, and: phaseEndTime),
                               bucketSeconds: width, start: fpsStart, end: phaseEndTime)
        }
        let perSecond = buckets("received", 1)
        let secondPresented = buckets("presented", 1)
        let secondDrawn = buckets("drawn", 1)
        let perSecondReceived = perSecond.map(\.rate)
        let perSecondPresented = secondPresented.map(\.rate)
        let perSecondDrawn = secondDrawn.map(\.rate)
        let quarter = 0.25
        let quarterReceived = buckets("received", quarter)
        let quarterPresented = buckets("presented", quarter)
        let quarterDrawn = buckets("drawn", quarter)
        let quarterReceivedStats = FPSBuckets.percentiles(quarterReceived)
        let quarterPresentedStats = FPSBuckets.percentiles(quarterPresented)
        let quarterDrawnStats = FPSBuckets.percentiles(quarterDrawn)
        let totalCpuPercent: Any = {
            if let player = cpuPercent, let bridge = bridgeCpuPercent { return player + bridge }
            if let player = cpuPercent { return player }
            if let bridge = bridgeCpuPercent { return bridge }
            return NSNull()
        }()
        let streamFrame = view.image.map { [$0.width, $0.height] } ?? [0, 0]
        fpsResult = [
            "seconds": elapsed,
            "received_fps": received / elapsed,
            "presented_fps": presented / elapsed,
            "displayed_fps": drawn / elapsed,
            "mb_per_s": bytes / 1e6 / elapsed,
            "active_fps_median": quarterReceivedStats.median ?? 0,
            "active_presented_fps_median": quarterPresentedStats.median ?? 0,
            "active_displayed_fps_median": quarterDrawnStats.median ?? 0,
            "active_received_fps_p10": quarterReceivedStats.p10 ?? 0,
            "active_displayed_fps_p10": quarterDrawnStats.p10 ?? 0,
            "bucket_ms": 250,
            "interval_median_fps": Stat.activeFPS(intervals: receiveIntervals) ?? 0,
            "receive_interval_ms": distribution(receiveIntervals),
            "draw_interval_ms": distribution(recorder.drawIntervals(after: fpsStart, before: phaseEndTime)),
            "main_queue_lag_ms": distribution(mainQueueProbe.values(from: fpsStart, to: phaseEndTime)),
            "per_second_received": perSecondReceived,
            "per_second_presented": perSecondPresented,
            "per_second_displayed": perSecondDrawn,
            "median_received_fps": Stat.percentile(perSecondReceived, 0.5) ?? 0,
            "median_presented_fps": Stat.percentile(perSecondPresented, 0.5) ?? 0,
            "median_displayed_fps": Stat.percentile(perSecondDrawn, 0.5) ?? 0,
            "p10_displayed_fps": Stat.percentile(perSecondDrawn, 0.1) ?? 0,
            "replaced_frames": end.replaced - fpsCounterStart.replaced,
            "replacement_scope": options.productionPlayer ? "Swift pending-frame slot" : "standalone FramePump slot",
            "display_refresh_hz": displayRefreshHz() ?? NSNull(),
            "displayed_ratio_of_refresh": displayRefreshHz().map { refresh in
                refresh > 0 ? (drawn / elapsed) / refresh : 0
            } ?? NSNull(),
            "stream_width": streamFrame[0],
            "stream_height": streamFrame[1],
            "cpu_percent": cpuPercent ?? NSNull(),
            "bridge_cpu_percent": bridgeCpuPercent ?? NSNull(),
            "total_cpu_percent": totalCpuPercent,
            "rss_mb": recorder.rss ?? NSNull(),
        ]
        let refresh = displayRefreshHz()
        print(String(format: "swiftui fps: %.2f s  received %.2f fps  presented %.2f fps  displayed %.2f fps (display %@ Hz)  %.1f MB/s",
                     elapsed, received / elapsed, presented / elapsed, drawn / elapsed,
                     refresh.map { String(format: "%.0f", $0) } ?? "?", bytes / 1e6 / elapsed))
        if let cpuPercent {
            let total = bridgeCpuPercent.map { cpuPercent + $0 }
            print(String(format: "swiftui fps: 250ms-bucket median received %.1f · presented %.1f · displayed %.1f  |  per-second displayed median %.1f",
                         quarterReceivedStats.median ?? 0, quarterPresentedStats.median ?? 0,
                         quarterDrawnStats.median ?? 0, Stat.percentile(perSecondDrawn, 0.5) ?? 0))
            print(String(format: "swiftui fps: player CPU %.1f%% · bridge CPU %@ · total %@",
                         cpuPercent,
                         bridgeCpuPercent.map { String(format: "%.1f%%", $0) } ?? "—",
                         total.map { String(format: "%.1f%%", $0) } ?? "—"))
        }
        if drawn == 0 {
            finish(code: ExitCode.renderFailure.rawValue,
                   reason: "no NSView draws: the benchmark window is not visible (GUI session required)")
            return
        }
        if options.taps <= 0 {
            startRestoreProbesOrFinish()
            return
        }
        startLatencyPhase()
    }

    private func startLatencyPhase() {
        send(["type": "tool_key", "key": "home"])
        writeStderr("bench: latency phase (\(options.taps) taps, probe \(options.probeX),\(options.probeY), show_taps must be on)")
        // A cold Android launcher may still be starting after the first HOME.
        // This untimed settling period is identical for every A/B run.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.runTaps() }
    }

    private func runTaps() {
        let queue = DispatchQueue(label: "jidr.bench.taps")
        queue.async { [weak self] in
            guard let self else { return }
            for index in 0..<self.options.taps {
                Thread.sleep(forTimeInterval: 0.15)
                guard let baseline = self.recorder.presentedPatch else {
                    Thread.sleep(forTimeInterval: 0.2)
                    continue
                }
                let sentAt = now()
                guard self.recorder.detector.beginTouch(at: sentAt, baseline: baseline) else {
                    Thread.sleep(forTimeInterval: 0.1)
                    continue
                }
                self.send(["type": "touch", "x": self.options.probeX, "y": self.options.probeY, "down": true])
                let latency = self.recorder.detector.waitForDetection(timeout: self.options.tapTimeoutSeconds)
                self.send(["type": "touch", "x": self.options.probeX, "y": self.options.probeY, "down": false])
                if let latency {
                    self.recorder.recordLatency(latency)
                    writeStderr("bench: tap \(index + 1): \(latency) ms")
                } else {
                    writeStderr("bench: tap \(index + 1) timed out; baseline=\(baseline), latest=\(String(describing: self.recorder.presentedPatch))")
                }
                self.send(["type": "tool_key", "key": "home"])
                // Let a launcher/app transition finish before the next baseline,
                // so only the show-taps dot can change the probe patch.
                Thread.sleep(forTimeInterval: 0.35)
            }
            DispatchQueue.main.async { [weak self] in self?.finishLatencyPhase() }
        }
    }

    private func finishLatencyPhase() {
        let samples = recorder.latencies
        let detected = recorder.detector.detected
        let missed = recorder.detector.missed
        let median = Stat.percentile(samples, 0.5)
        let p90 = Stat.percentile(samples, 0.9)
        print(String(format: "swiftui latency: %d/%d taps detected  median %@  p90 %@",
                     detected, options.taps,
                     median.map { String(format: "%.1f ms", $0) } ?? "—",
                     p90.map { String(format: "%.1f ms", $0) } ?? "—"))
        latencyResult = [
            "taps": options.taps,
            "detected": detected,
            "missed": missed,
            "median_ms": median ?? NSNull(),
            "p90_ms": p90 ?? NSNull(),
            "p95_ms": Stat.percentile(samples, 0.95) ?? NSNull(),
            "p99_ms": Stat.percentile(samples, 0.99) ?? NSNull(),
            "endpoint": options.productionPlayer ? "ScreenView.draw" : "UI-hop",
            "samples_ms": samples,
            "probe": ["x": options.probeX, "y": options.probeY, "threshold": options.probeThreshold],
        ]
        if samples.isEmpty {
            finish(code: ExitCode.latencyFailure.rawValue,
                   reason: "no touch probe was detected; is `dev.set show_taps` on and the home screen static?")
            return
        }
        startRestoreProbesOrFinish()
    }

    var latencyResult: [String: Any] = [:]

    private func startRestoreProbesOrFinish() {
        guard restoreAttempt < options.restoreProbes else {
            finish(code: restoreTimeouts == 0 ? ExitCode.ok.rawValue : ExitCode.renderFailure.rawValue,
                   reason: restoreTimeouts == 0 ? "complete" : "fresh frame timed out after window restore")
            return
        }
        restoreAttempt += 1
        let attempt = restoreAttempt
        window.miniaturize(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, !self.finished else { return }
            self.restoreRequestedAt = now()
            self.window.deminiaturize(nil)
            self.window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, !self.finished, self.restoreAttempt == attempt, self.restoreRequestedAt != nil else { return }
                self.restoreTimeouts += 1
                self.restoreRequestedAt = nil
                self.nextRestoreProbe()
            }
        }
    }

    private func nextRestoreProbe() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.startRestoreProbesOrFinish() }
    }

    // MARK: Report

    func finish(code: Int32, reason: String) {
        if finished { return }
        finished = true
        mainQueueProbe.stop()
        let environment = ProcessInfo.processInfo.environment
        let build: [String: Any] = ["profile": environment["JIDR_BENCH_PROFILE"] ?? "unknown",
                      "revision": environment["JIDR_BENCH_REVISION"] ?? "unknown",
                      "tracked_dirty": environment["JIDR_BENCH_DIRTY"] ?? "unknown",
                      "inputs_sha256": environment["JIDR_BENCH_INPUTS_SHA256"] ?? "unknown",
                      "binary_sha256": environment["JIDR_BENCH_BINARY_SHA256"] ?? "unknown",
                      "bridge_sha256": environment["JIDR_BENCH_BRIDGE_SHA256"] ?? "unknown"]
        let memory: [String: Any] = ["player": footprint(pid: getpid()),
                                     "bridge": bridgePid.map { footprint(pid: $0) } ?? ["available": false]]
        let firstDecode = recorder.times("received", between: launchedAt, and: now()).first.map { ($0 - launchedAt) * 1000 }
        let firstDraw = recorder.times("drawn", between: launchedAt, and: now()).first.map { ($0 - launchedAt) * 1000 }
        let startup: [String: Any] = ["bridge_launch_to_first_decode_ms": firstDecode ?? NSNull(),
                                      "bridge_launch_to_first_draw_ms": firstDraw ?? NSNull()]
        let restore: [String: Any] = ["attempts": restoreAttempt, "timeouts": restoreTimeouts,
                                      "fresh_frame_ms": distribution(restoreSamples), "samples_ms": restoreSamples]
        let report: [String: Any] = [
            "harness": "jidr-swiftui-player-bench",
            "version": 2,
            "measurement_path": options.productionPlayer ? "GameWindowController/PlayerTransport/ScreenView" : "standalone FramePump/BenchView",
            "build": build, "memory": memory, "startup": startup, "restore": restore,
            "unmeasured": ["OS input delivery", "GPU scanout", "production center lists", "other Space and fullscreen transitions"],
            "method": "jidr-swiftui-bridge JFR1 -> FrameDecoder -> newest-frame slot -> one main hop -> NSView draw; "
                + (options.productionPlayer ? "latency = transport.send -> first actual ScreenView.draw whose probe changed; " : "latency = stdin touch-down write -> first presented frame whose probe changed; ")
                + "excludes OS input path and scanout (ADR-0001)",
            "generated_at": ISO8601DateFormatter().string(from: Date()),
            "exit_code": Int(code),
            "reason": reason,
            "device": options.device,
            "bridge": options.bridge,
            "panel": ["width": options.panelWidth, "height": options.panelHeight],
            "quality": options.quality,
            "window": ["width": options.windowWidth, "height": options.windowHeight,
                       "backing_scale": window.backingScaleFactor],
            "fps": fpsResult,
            "latency": latencyResult,
        ]
        if !options.jsonOut.isEmpty {
            do {
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: options.jsonOut))
                writeStderr("bench: report written to \(options.jsonOut)")
            } catch {
                writeStderr("bench: cannot write report: \(error)")
            }
        }
        production?.transport.stop()
        production?.window?.close()
        bridge?.terminate()
        fflush(stdout)
        exit(code)
    }

    private var finished = false
}

// MARK: - Offline self-test

func framePacket(width: Int, height: Int, rotation: Int, pixels: [UInt8]) -> Data {
    var packet = Data("JFR1".utf8)
    for value in [width, height, rotation, pixels.count] {
        var bigEndian = UInt32(value).bigEndian
        withUnsafeBytes(of: &bigEndian) { packet.append(contentsOf: $0) }
    }
    packet.append(contentsOf: pixels)
    return packet
}

func runSelfTest() -> Int32 {
    var checks = 0
    var failures = 0
    func expect(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition {
            failures += 1
            print("SELF-TEST FAILED: \(message)")
        }
    }

    expect(memoryMiB("1024K") == 1 && memoryMiB("2G") == 2048 && memoryMiB("49.0M") == 49, "vmmap binary units")
    expect(memoryMiB("nonsense") == nil && memoryMiB("-1M") == nil, "invalid memory values are unavailable")
    let summary = distribution([1, 2, 3, 4, 100])
    expect(summary["p95"] as? Double == 100 && summary["p99"] as? Double == 100, "tail percentile uses full intervals including stalls")
    expect(distribution([])["p95"] is NSNull, "missing metric is unavailable, not zero")
    expect(freshFrameLatency(requested: 11, received: 10, drawn: 12) == nil, "an old frame painted after restore is not a fresh frame")
    expect(freshFrameLatency(requested: 11, received: 11.01, drawn: 11.02).map { abs($0 - 20) < 0.001 } == true, "restore latency ends at actual draw of a fresh decode")
    expect(freshFrameLatency(requested: 11, received: 12, drawn: 11.5) == nil, "invalid timestamp order is rejected")
    do {
        let mode = try parseOptions(["--self-test", "--production-player"])
        expect(mode.productionPlayer, "production measurement path is explicit")
    } catch { expect(false, "production mode parse") }

    // 1. CLI parsing and defaults.
    do {
        let parsed = try parseOptions(["--device", "Bench", "--bridge", "/bin/sh",
                                       "--seconds", "3", "--taps", "2",
                                       "--window", "320x700", "--probe", "0.4,0.6",
                                       "--quality", "2", "--json-out", "/tmp/x.json"])
        expect(parsed.device == "Bench" && parsed.bridge == "/bin/sh", "device/bridge parse")
        expect(parsed.seconds == 3 && parsed.taps == 2, "seconds/taps parse")
        expect(parsed.windowWidth == 320 && parsed.windowHeight == 700, "window parse")
        expect(parsed.probeX == 0.4 && parsed.probeY == 0.6, "probe parse")
        expect(parsed.quality == 2, "quality parse")
        let defaults = try parseOptions(["--device", "Bench", "--bridge", "/bin/sh"])
        expect(defaults.seconds == 10 && defaults.taps == 30, "default seconds/taps")
        expect(defaults.windowWidth == 340 && defaults.windowHeight == 752, "default window")
        expect(defaults.panelWidth == 1080 && defaults.panelHeight == 2400, "default panel")
        expect(defaults.quality == 1, "default quality")
        for bad in [["--device", "x"], ["--device", "x", "--bridge", "/bin/sh", "--seconds", "0"],
                    ["--device", "x", "--bridge", "/bin/sh", "--window", "10x10"],
                    ["--bogus"]] {
            do {
                _ = try parseOptions(bad)
                expect(false, "invalid arguments accepted: \(bad)")
            } catch { checks += 1 }
        }
    } catch {
        expect(false, "parseOptions threw unexpectedly: \(error)")
    }

    // 2. Percentiles follow session.rs (nearest rank, upper middle for even
    // counts at p=0.5).
    expect(Stat.percentile([1, 2, 3, 4], 0.5) == 3, "p50 nearest-rank")
    expect(Stat.percentile([1, 2, 3, 4], 0.9) == 4, "p90 nearest-rank")
    expect(Stat.percentile([1, 2, 3, 4], 0) == 1, "p0")
    expect(Stat.percentile([], 0.5) == nil, "empty percentile")
    expect(Stat.activeFPS(intervals: [16.667, 16.667, 200]) != nil, "active fps ignores >=100 ms gaps")
    if let fps = Stat.activeFPS(intervals: [16.667, 16.667, 16.667]) {
        expect(abs(fps - 60) < 0.3, "active fps 60 from 16.667 ms intervals, got \(fps)")
    } else {
        expect(false, "active fps nil")
    }

    // 2b. Timestamp-based fps buckets (the phase no longer samples a main timer).
    let bucketTimes = [0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 1.1]
    let oneSecond = FPSBuckets.buckets(times: bucketTimes, bucketSeconds: 1, start: 0, end: 2)
    expect(oneSecond.count == 2, "two 1 s buckets")
    expect(oneSecond[0].frames == 8 && abs(oneSecond[0].rate - 8) < 1e-9, "first second bucket")
    expect(oneSecond[1].frames == 1, "second second bucket")
    let quarterBuckets = FPSBuckets.buckets(times: [0.0, 0.05, 0.10, 0.25, 0.30], bucketSeconds: 0.25, start: 0, end: 0.5)
    expect(quarterBuckets.count == 2, "two 250 ms buckets")
    expect(quarterBuckets[0].frames == 3, "250 ms bucket frames")
    if let active = FPSBuckets.activeMedian(quarterBuckets) {
        expect(abs(active - 12) < 1e-9, "250 ms active median (upper middle), got \(active)")
    } else {
        expect(false, "250 ms active median nil")
    }
    expect(FPSBuckets.activeMedian([]) == nil, "empty bucket median")
    do {
        let driven = try parseOptions(["--device", "d", "--bridge", "/bin/sh", "--fps-drive"])
        expect(driven.fpsDrive, "--fps-drive parse")
        let hidden = try parseOptions(["--device", "d", "--bridge", "/bin/sh", "--hidden-window"])
        expect(hidden.hiddenWindow, "--hidden-window parse")
    } catch {
        expect(false, "driver option parse: \(error)")
    }

    // 3. Probe patch sampling and distance.
    var solid = [UInt8](repeating: 0, count: 6 * 4 * 4)
    for offset in stride(from: 0, to: solid.count, by: 4) {
        solid[offset] = 10; solid[offset + 1] = 20; solid[offset + 2] = 30; solid[offset + 3] = 255
    }
    let solidPatch = Patch.sample(pixels: Data(solid), width: 6, height: 4,
                                  normalizedX: 0.5, normalizedY: 0.5, radius: 1)
    expect(solidPatch != nil, "patch sampled")
    expect(solidPatch.map { abs($0.red - 10) < 0.001 && abs($0.green - 20) < 0.001 } ?? false,
           "patch mean rgb")
    var changed = solid
    let center = ((2 * 6) + 3) * 4
    changed[center] = 200; changed[center + 1] = 200; changed[center + 2] = 200
    if let solidPatch, let changedPatch = Patch.sample(pixels: Data(changed), width: 6, height: 4,
                                                       normalizedX: 0.5, normalizedY: 0.5, radius: 1) {
        expect(solidPatch.distance(to: changedPatch) > 30, "patch distance detects change")
        expect(Patch.zero.distance(to: Patch.zero) == 0, "patch distance zero")
    } else {
        expect(false, "changed patch not sampled")
    }
    expect(Patch.sample(pixels: Data([1, 2, 3]), width: 2, height: 2,
                        normalizedX: 0.5, normalizedY: 0.5, radius: 1) == nil, "short pixel buffer rejected")

    // 4. Probe detector records the first changed frame and reports misses.
    let detector = ProbeDetector(threshold: 30, probeX: 0.5, probeY: 0.5)
    let black = Patch.zero
    let white = Patch(red: 200, green: 200, blue: 200)
    expect(detector.beginTouch(at: 100, baseline: black), "begin touch")
    expect(detector.observe(patch: black, at: 100.5) == nil, "unchanged patch ignored")
    let observed = detector.observe(patch: white, at: 100.013)
    expect(observed != nil && abs((observed ?? 0) - 13) < 1, "latency recorded (13 ms), got \(String(describing: observed))")
    expect(detector.waitForDetection(timeout: 0.1) != nil, "waitForDetection returns recorded latency")
    expect(detector.detected == 1, "one detection")
    expect(detector.beginTouch(at: 200, baseline: black), "begin a second touch")
    expect(!detector.beginTouch(at: 200.1, baseline: black), "second concurrent touch refused")
    expect(detector.waitForDetection(timeout: 0.05) == nil, "timeout with no change")
    expect(detector.missed == 1, "one miss")

    // 5. Newest-frame slot never builds a backlog.
    var slot = LatestSlot<Int>()
    slot.submit(1); slot.submit(2); slot.submit(3)
    expect(slot.replaced == 2, "two frames replaced by newer ones")
    expect(slot.take() == 3, "newest frame wins")
    expect(slot.take() == nil, "slot empty after take")
    slot.submit(4)
    expect(slot.replaced == 2, "no replacement when slot is empty")

    // 6. FrameDecoder decodes the bridge packet format.
    let packet = framePacket(width: 2, height: 1, rotation: 1,
                             pixels: [1, 2, 3, 255, 4, 5, 6, 255])
    let decoder = FrameDecoder()
    var decoded: DecodedFrame?
    expect(decoder.consume(packet) { decoded = $0 }, "valid packet accepted")
    expect(decoded?.width == 2 && decoded?.height == 1 && decoded?.rotation == 1, "decoded dimensions")
    expect(decoded?.pixels.count == 8, "decoded pixel bytes")
    if let decoded { expect(makeImage(from: decoded)?.width == 2, "CGImage from decoded frame") }
    var bad = Data("NOPE".utf8)
    bad.append(contentsOf: [UInt8](repeating: 0, count: 16))
    expect(!decoder.consume(bad) { _ in }, "invalid magic rejected")

    // 7. Recorder counters and report encoding.
    var recorderOptions = Options()
    recorderOptions.device = "unit"
    recorderOptions.bridge = "/bin/sh"
    let recorder = Recorder(options: recorderOptions)
    recorder.noteReceived(bytes: 16, at: now())
    recorder.notePresented(patch: black, at: now())
    recorder.noteDrawn(at: now())
    recorder.recordLatency(12.5)
    let counter = recorder.snapshot()
    expect(counter.received == 1 && counter.bytes == 16, "receive counter")
    expect(counter.presented == 1 && counter.drawn == 1, "present/draw counters")
    expect(recorder.latencies == [12.5], "latency samples stored")
    let report: [String: Any] = [
        "harness": "jidr-swiftui-player-bench",
        "fps": ["displayed_fps": 59.5, "cpu_percent": NSNull()],
        "latency": ["median_ms": 13.5, "samples_ms": [12.5]],
        "device": "unit",
    ]
    do {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        let roundTrip = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        expect(roundTrip?["device"] as? String == "unit", "report JSON round-trip")
        expect((roundTrip?["fps"] as? [String: Any])?["displayed_fps"] as? Double == 59.5, "nested fps JSON")
    } catch {
        expect(false, "report JSON encoding: \(error)")
    }

    // 8. Frame intervals used for active fps exclude gaps >= 100 ms.
    let intervals = [16.0, 17.0, 200.0, 16.5]
    expect(Stat.activeFPS(intervals: intervals) != nil, "active fps from filtered intervals")
    _ = checks
    if failures > 0 {
        print("SELF-TEST FAILED (\(failures)/\(checks) checks)")
        return 1
    }
    print("SELF-TEST PASSED (\(checks) checks)")
    return 0
}

// MARK: - Main

let rawArguments = Array(CommandLine.arguments.dropFirst())
let options: Options
do {
    options = try parseOptions(rawArguments)
} catch {
    writeStderr("jidr-swiftui-bench: \(error)")
    writeStderr(usage())
    exit(2)
}
if options.selfTest {
    exit(runSelfTest())
}

if let fontDirectory = ProcessInfo.processInfo.environment["JIDR_BENCH_FONTS"],
   let files = try? FileManager.default.contentsOfDirectory(atPath: fontDirectory) {
    for file in files where file.hasSuffix(".ttf") {
        CTFontManagerRegisterFontsForURL(URL(fileURLWithPath: fontDirectory).appendingPathComponent(file) as CFURL, .process, nil)
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let bench: Bench
do {
    bench = try Bench(options: options)
} catch {
    writeStderr("jidr-swiftui-bench: \(error)")
    exit(3)
}
bench.start()
application.run()
