// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import UniformTypeIdentifiers

// This prototype intentionally requires an explicit device and data directory.
// It never starts, stops, or changes the configuration of an emulator.
final class PlayerTransport: ObservableObject {
    enum RecordingState { case idle, starting, recording, stopping }
    @Published var recording: RecordingState = .idle
    @Published var connectionEnded = false
    @Published var recordingStateUnknown = false
    @Published var language = 1
    let mapping = KeyMappingStore()
    private let process = Process()
    private let input = Pipe()
    private let frames = Pipe()
    private let diagnostics = Pipe()
    private let inputQueue = DispatchQueue(label: "jidr.prototype.input")
    var onFrame: ((CGImage, Int) -> Void)?
    var onStatus: ((String) -> Void)?
    var onFrameSize: ((Int, Int) -> Void)?
    var onReconnect: (() -> Void)?
    var onAdvanced: (() -> Void)?
    var onPixelPerfect: (() -> Void)?
    private let decoder = FrameDecoder()
    private let decoderLock = NSLock()
    private var pendingFrame: (CGImage, Int)?
    private var frameScheduled = false
    private let frameLock = NSLock()
    private var diagnosticBuffer = Data()
    private let pasteboard: NSPasteboard = {
        if let name = ProcessInfo.processInfo.environment["JIDR_PROTOTYPE_TEST_PASTEBOARD"], !name.isEmpty {
            return NSPasteboard(name: NSPasteboard.Name(name))
        }
        return .general
    }()
    private var copySequence = 0
    private var pendingCopy: (id: Int, changeCount: Int)?
    private var didReceiveFrame = false

    func start(device: String, width: Int, height: Int, executable: String, quality: UInt8 = 1) throws {
        connectionEnded = false
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [device, String(width), String(height), String(quality)]
        process.standardInput = input
        process.standardOutput = frames
        process.standardError = diagnostics
        frames.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.consumeFrames(data)
        }
        diagnostics.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            self?.consumeDiagnostics(data)
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connectionEnded = true
                if self.recording != .idle {
                    self.recordingStateUnknown = true
                    self.recording = .idle
                    self.onStatus?("连接已结束，录屏状态未知；请在设备中心检查录屏。")
                } else { self.onStatus?("连接已结束（\(process.terminationStatus)）") }
            }
        }
        try process.run()
        onStatus?("正在连接测试设备…")
    }

    func send(_ message: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        inputQueue.async { [weak self] in
            guard let self, self.process.isRunning else { return }
            var line = data; line.append(10)
            try? self.input.fileHandleForWriting.write(contentsOf: line)
        }
    }

    func chooseScreenshot() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Jidr 截图.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        send(["type":"screenshot", "path":url.path])
        onStatus?("正在保存截图…")
    }

    func toggleRecording() {
        switch recording {
        case .idle:
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = "Jidr 录屏.mp4"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard !FileManager.default.fileExists(atPath: url.path) else { onStatus?("录屏文件已存在，请选择新文件名。") ; return }
            recording = .starting
            send(["type":"start_recording", "path":url.path])
            onStatus?("正在启动录屏…")
        case .recording:
            recording = .stopping
            send(["type":"stop_recording"])
            onStatus?("正在保存录屏…")
        case .starting, .stopping: break
        }
    }

    func chooseFile(apkOnly: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if apkOnly, let apk = UTType(filenameExtension: "apk") { panel.allowedContentTypes = [apk] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sendFile(url)
    }

    func sendFile(_ url: URL) {
        guard url.isFileURL else { onStatus?("请选择本地文件"); return }
        send(["type":"send_file", "path":url.path])
        onStatus?(url.pathExtension.lowercased() == "apk" ? "正在安装应用…" : "正在发送文件…")
    }

    func paste() {
        if let text = pasteboard.string(forType: .string) { send(["type": "paste", "text": text]) }
    }

    func copy(cut: Bool) {
        copySequence += 1
        pendingCopy = (copySequence, pasteboard.changeCount)
        send(["type": cut ? "cut" : "copy", "request_id": copySequence])
    }

    func stop() {
        frames.fileHandleForReading.readabilityHandler = nil
        diagnostics.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
    }

    private func consumeFrames(_ data: Data) {
        decoderLock.lock()
        defer { decoderLock.unlock() }
        let valid = autoreleasepool {
            decoder.consume(data) { frame in
                let width = frame.width, height = frame.height, rotation = frame.rotation
                let pixels = frame.pixels
                guard let provider = CGDataProvider(data: pixels as CFData),
                      let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
                frameLock.lock()
                pendingFrame = (image, rotation)
                let schedule = !frameScheduled
                if schedule { frameScheduled = true }
                frameLock.unlock()
                if schedule {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.frameLock.lock(); let frame = self.pendingFrame
                        self.pendingFrame = nil; self.frameScheduled = false; self.frameLock.unlock()
                        if let frame {
                            if !self.didReceiveFrame { self.didReceiveFrame = true; self.onStatus?("已连接") }
                            self.onFrameSize?(frame.0.width, frame.0.height)
                            self.onFrame?(frame.0, frame.1)
                        }
                    }
                }
            }
        }
        if !valid { stop() }
    }

    private func consumeDiagnostics(_ data: Data) {
        diagnosticBuffer.append(data)
        while let newline = diagnosticBuffer.firstIndex(of: 10) {
            let line = String(decoding: diagnosticBuffer.prefix(upTo: newline), as: UTF8.self)
            diagnosticBuffer.removeSubrange(...newline)
            if line.hasPrefix("JIDR_CLIPBOARD:") {
                let payload = String(line.dropFirst("JIDR_CLIPBOARD:".count))
                if let bytes = payload.data(using: .utf8), let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], let id = value["request_id"] as? Int, let text = value["text"] as? String {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let pending = self.pendingCopy, pending.id == id else { return }
                        self.pendingCopy = nil
                        guard self.pasteboard.changeCount == pending.changeCount else { self.onStatus?("Mac 剪贴板已变化，请重新复制"); return }
                        self.pasteboard.clearContents()
                        self.pasteboard.setString(text, forType: .string)
                    }
                }
            } else if line.hasPrefix("JIDR_MAPPING_PATH:") {
                let payload = String(line.dropFirst("JIDR_MAPPING_PATH:".count))
                if let data = payload.data(using: .utf8), let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let path = result["path"] as? String {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.mapping.load(path: path)
                        let prefs = URL(fileURLWithPath:path).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("gui-prefs.json")
                        if let data = try? Data(contentsOf:prefs), let object = (try? JSONSerialization.jsonObject(with:data)) as? [String:Any], let value = object["language"] as? Int, (0...1).contains(value) { self.language = value }
                    }
                }
            } else if line.hasPrefix("JIDR_RECORD:") {
                let payload = String(line.dropFirst("JIDR_RECORD:".count))
                if let data = payload.data(using: .utf8), let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let state = result["state"] as? String, let message = result["message"] as? String {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        switch state {
                        case "recording": self.recording = .recording
                        case "finished", "failed": self.recording = .idle
                        case "stop_failed": if self.recording == .stopping { self.recording = .recording }
                        default: break
                        }
                        self.onStatus?(message)
                    }
                }
            } else if line.hasPrefix("JIDR_OPERATION:") {
                let payload = String(line.dropFirst("JIDR_OPERATION:".count))
                guard let data = payload.data(using: .utf8),
                      let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let message = result["message"] as? String else { continue }
                let readable: String
                if message.contains("INSTALL_FAILED_INSUFFICIENT_STORAGE") {
                    readable = "安装失败：模拟器存储空间不足，请先释放空间。"
                } else if message.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
                    readable = "安装失败：应用签名不匹配，原应用及数据未删除。"
                } else {
                    readable = message
                }
                DispatchQueue.main.async { [weak self] in self?.onStatus?(readable) }
            } else if !line.isEmpty {
                DispatchQueue.main.async { [weak self] in self?.onStatus?(line) }
            }
        }
    }
}

final class ScreenView: NSView, NSTextInputClient {
    var transport: PlayerTransport?
    var image: CGImage? { didSet { needsDisplay = true } }
    private var rotation = 0
    private var mappedKeys: [UInt16: (id: Int, x: Double, y: Double)] = [:]
    func present(_ frame: CGImage, rotation next: Int) {
        if rotation != next { releaseMappedKeys(); transport?.mapping.rotationChanged(); rotation = next }
        image = frame
    }
    private var marked = NSMutableAttributedString(string: "")
    private var markedSelection = NSRange(location: 0, length: 0)
    private var dragging = false
    private var lastTouch: (CGFloat, CGFloat)?
    private var pendingKey: (UInt16, String)?
    private var pressedKeys: [UInt16: String] = [:]
    private var pressedModifiers: Set<String> = []
    private var windowObserver: NSObjectProtocol?
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { super.init(coder: coder); registerForDraggedTypes([.fileURL]) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], urls.count == 1 else { return false }
        transport?.sendFile(urls[0])
        return true
    }
    override var isFlipped: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        if let window {
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.releaseHeldInputs() }
        } else { windowObserver = nil }
    }
    deinit { if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) } }

    private var imageRect: NSRect {
        guard let image, image.width > 0, image.height > 0 else { return .zero }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); dirtyRect.fill()
        if let image {
            let backing = window?.backingScaleFactor ?? 1
            let exact = abs(imageRect.width * backing - CGFloat(image.width)) < 0.5 && abs(imageRect.height * backing - CGFloat(image.height)) < 0.5
            NSGraphicsContext.current?.imageInterpolation = exact ? .none : .high
            NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(in: imageRect)
        }
        if let mapping = transport?.mapping {
            for binding in mapping.visibleBindings where binding.rotation == rotation {
                let p = NSPoint(x: imageRect.minX + imageRect.width * binding.x, y: imageRect.minY + imageRect.height * binding.y)
                let circle = NSRect(x:p.x - 17, y:p.y - 17, width:34, height:34)
                NSColor.systemBlue.withAlphaComponent(0.8).setFill(); NSBezierPath(ovalIn: circle).fill()
                let label = binding.key == "SPACE" ? "SPC" : binding.key
                let attrs: [NSAttributedString.Key: Any] = [.font:NSFont.boldSystemFont(ofSize:12), .foregroundColor:NSColor.white]
                let size = label.size(withAttributes: attrs)
                label.draw(at:NSPoint(x:p.x - size.width / 2, y:p.y - size.height / 2), withAttributes:attrs)
            }
        }
        if marked.length > 0 {
            let box = NSRect(x: 12, y: max(12, bounds.height - 46), width: max(0, bounds.width - 24), height: 34)
            NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill(); NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
            marked.draw(at: NSPoint(x: box.minX + 8, y: box.minY + 6))
        }
    }
    private func sendTouch(_ event: NSEvent, down: Bool) {
        let rect = imageRect, point = convert(event.locationInWindow, from: nil)
        guard rect.width > 0, rect.height > 0 else { return }
        if !dragging && !rect.contains(point) { return }
        let x = min(1, max(0, (point.x - rect.minX) / rect.width))
        let y = min(1, max(0, (point.y - rect.minY) / rect.height))
        lastTouch = (x, y)
        transport?.send(["type": "touch", "x": x, "y": y, "down": down])
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(point) else { return }
        if let mapping = transport?.mapping, mapping.editing {
            mapping.place(x: Double((point.x - imageRect.minX) / imageRect.width), y: Double((point.y - imageRect.minY) / imageRect.height), rotation: rotation)
            transport?.onStatus?("请按一个字母、数字或空格绑定")
            return
        }
        dragging = true; sendTouch(event, down: true)
    }
    override func mouseDragged(with event: NSEvent) { if dragging { sendTouch(event, down: true) } }
    override func mouseUp(with event: NSEvent) { if dragging { sendTouch(event, down: false); dragging = false } }
    private func releaseMappedKeys() {
        for value in mappedKeys.values { transport?.send(["type":"mapped_touch", "id":value.id, "x":value.x, "y":value.y, "down":false]) }
        mappedKeys.removeAll()
    }
    fileprivate func releaseHeldInputs() {
        releaseMappedKeys()
        if dragging, let lastTouch { transport?.send(["type":"touch", "x":lastTouch.0, "y":lastTouch.1, "down":false]); dragging = false }
        for key in pressedKeys.values { transport?.send(["type":"key", "key":key, "down":false]) }
        for key in pressedModifiers { transport?.send(["type":"key", "key":key, "down":false]) }
        pressedKeys.removeAll()
        pressedModifiers.removeAll()
    }
    override func resignFirstResponder() -> Bool {
        releaseHeldInputs()
        return super.resignFirstResponder()
    }
    override func flagsChanged(with event: NSEvent) {
        for (flag, key) in [(NSEvent.ModifierFlags.shift, "Shift"), (.control, "Control"), (.option, "Alt")] {
            let down = event.modifierFlags.contains(flag)
            if down && !pressedModifiers.contains(key) {
                pressedModifiers.insert(key)
                transport?.send(["type":"key", "key":key, "down":true])
            } else if !down && pressedModifiers.remove(key) != nil {
                transport?.send(["type":"key", "key":key, "down":false])
            }
        }
    }
    override func keyDown(with event: NSEvent) {
        if let mapping = transport?.mapping, !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option) {
            let raw = event.charactersIgnoringModifiers ?? ""
            let key = raw == " " ? "SPACE" : raw.uppercased()
            if mapping.editing {
                if mapping.pending && mapping.assign(key) { transport?.onStatus?("已绑定 \(key)") }
                else if mapping.pending { transport?.onStatus?("请使用字母、数字或空格") }
                return
            }
            if mappedKeys[event.keyCode] != nil { return }
            if mapping.enabled, let binding = mapping.scheme.bindings.first(where: { $0.key == key && $0.rotation == rotation }) {
                guard let id = (3...9).first(where: { id in !mappedKeys.values.contains(where: { $0.id == id }) }) else { return }
                mappedKeys[event.keyCode] = (id, binding.x, binding.y)
                transport?.send(["type":"mapped_touch", "id":id, "x":binding.x, "y":binding.y, "down":true])
                return
            }
        }
        if event.isARepeat && pressedKeys[event.keyCode] != nil { return }
        if event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "v": transport?.paste(); return
            case "c": transport?.copy(cut: false); return
            case "x": transport?.copy(cut: true); return
            case "a": transport?.send(["type":"select_all"]); return
            default: break
            }
        }
        let specials: [UInt16: String] = [36:"Enter", 48:"Tab", 51:"Backspace", 53:"Escape", 117:"Delete", 123:"ArrowLeft", 124:"ArrowRight", 125:"ArrowDown", 126:"ArrowUp"]
        if let key = specials[event.keyCode], !hasMarkedText() {
            pressedKeys[event.keyCode] = key
            transport?.send(["type":"key", "key":key, "down":true]); return
        }
        if !event.isARepeat, let value = event.charactersIgnoringModifiers, value.unicodeScalars.count == 1, let scalar = value.unicodeScalars.first, scalar.isASCII, !CharacterSet.controlCharacters.contains(scalar) {
            pendingKey = (event.keyCode, value.lowercased())
        }
        interpretKeyEvents([event])
        pendingKey = nil
    }
    override func keyUp(with event: NSEvent) {
        if let value = mappedKeys.removeValue(forKey: event.keyCode) {
            transport?.send(["type":"mapped_touch", "id":value.id, "x":value.x, "y":value.y, "down":false]); return
        }
        if let key = pressedKeys.removeValue(forKey: event.keyCode) { transport?.send(["type":"key", "key":key, "down":false]) }
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        let wasComposing = hasMarkedText()
        marked = NSMutableAttributedString(string: ""); markedSelection = NSRange(location: 0, length: 0); needsDisplay = true
        if !wasComposing, let pendingKey, text.unicodeScalars.count == 1, text.unicodeScalars.first?.isASCII == true {
            pressedKeys[pendingKey.0] = pendingKey.1
            transport?.send(["type":"key", "key":pendingKey.1, "down":true])
        } else if !text.isEmpty { transport?.send(["type":"text", "text":text]) }
    }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let value = (string as? NSAttributedString)?.string ?? (string as? String ?? "")
        marked = NSMutableAttributedString(string: value, attributes: [.foregroundColor:NSColor.labelColor, .font:NSFont.systemFont(ofSize:16)])
        markedSelection = selectedRange; needsDisplay = true
    }
    func unmarkText() { marked = NSMutableAttributedString(string: ""); needsDisplay = true }
    func selectedRange() -> NSRange { hasMarkedText() ? markedSelection : NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, NSMaxRange(range) <= marked.length else { return nil }
        actualRange?.pointee = range; return marked.attributedSubstring(from: range)
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.foregroundColor, .font] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let local = NSRect(x: 12, y: max(12, bounds.height - 46), width: 1, height: 24)
        return window?.convertToScreen(convert(local, to: nil)) ?? .zero
    }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    override func doCommand(by selector: Selector) { }
}

struct PlayerView: NSViewRepresentable {
    let transport: PlayerTransport
    func makeNSView(context: Context) -> ScreenView {
        let view = ScreenView(); view.transport = transport
        transport.mapping.onChange = { [weak view, weak transport] in
            guard let view else { return }
            if let mapping = transport?.mapping, !mapping.enabled || mapping.editing { view.releaseHeldInputs() }
            view.needsDisplay = true
        }
        transport.onFrame = { [weak view] image, rotation in view?.present(image, rotation: rotation) }
        return view
    }
    func updateNSView(_ view: ScreenView, context: Context) { }
}

private let sidebarWidth: CGFloat = 48

final class SidebarState: ObservableObject {
    @Published var visible = true
}

struct ContentView: View {
    @ObservedObject var transport: PlayerTransport
    @ObservedObject var mapping: KeyMappingStore
    @ObservedObject var sidebar: SidebarState
    @State private var status = "准备中"
    @State private var connected = false

    private func tool(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                .frame(width: sidebarWidth, height: 38)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(localized(title)).accessibilityLabel(localized(title))
    }
    private func localized(_ text: String) -> String {
        guard transport.language == 0, let path = Bundle.main.path(forResource:"en",ofType:"lproj"), let bundle = Bundle(path:path) else { return text }
        for (prefix, translation) in [("连接已结束（", "Connection ended ("), ("已绑定 ", "Bound "), ("无法启动桥接：", "Unable to start the connection: ")] {
            if text.hasPrefix(prefix) {
                var suffix = String(text.dropFirst(prefix.count))
                if prefix == "连接已结束（", suffix.hasSuffix("）") { suffix.removeLast(); suffix += ")" }
                return translation + suffix
            }
        }
        return bundle.localizedString(forKey:text,value:text,table:nil)
    }
    private func key(_ name: String) { transport.send(["type":"tool_key", "key":name]) }
    var body: some View {
        ZStack(alignment: .topTrailing) {
            HStack(spacing: 0) {
                PlayerView(transport: transport)
                if sidebar.visible {
                    ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        tool("返回", "arrow.left") { key("back") }
                        tool("主页", "circle") { key("home") }
                        tool("最近使用", "square") { key("recents") }
                        Divider().opacity(0.3).padding(.horizontal, 10).padding(.vertical, 3)
                        tool("电源", "power") { key("power") }
                        if transport.onAdvanced != nil { tool("高级工具", "slider.horizontal.3") { transport.onAdvanced?() } }
                        tool("音量增大", "speaker.wave.2") { key("volume_up") }
                        tool("音量减小", "speaker.wave.1") { key("volume_down") }
                        tool("向左旋转", "rotate.left") { transport.send(["type":"rotate", "direction":1]) }
                        tool("向右旋转", "rotate.right") { transport.send(["type":"rotate", "direction":-1]) }
                        Divider().opacity(0.3).padding(.horizontal, 10).padding(.vertical, 3)
                        tool("键位映射", "keyboard") {
                            if !mapping.editing {
                                if !mapping.begin() { transport.onStatus?(mapping.error ?? "键位方案尚未加载") }
                            }
                        }
                        tool(transport.recording == .idle ? "开始录屏" : "停止录屏", transport.recording == .idle ? "record.circle" : "stop.circle") { transport.toggleRecording() }
                        tool("截图", "camera") { transport.chooseScreenshot() }
                        tool("安装 APK", "square.and.arrow.down") { transport.chooseFile(apkOnly: true) }
                        tool("发送文件", "folder") { transport.chooseFile(apkOnly: false) }
                        Divider().opacity(0.3).padding(.horizontal, 10).padding(.vertical, 3)
                        tool("画面原始像素大小", "1.magnifyingglass") { transport.onPixelPerfect?() }
                        tool("全屏", "arrow.up.left.and.arrow.down.right") { NSApp.keyWindow?.toggleFullScreen(nil) }
                    }
                    }.scrollIndicators(.hidden)
                    .foregroundStyle(Color(red: 0.65, green: 0.69, blue: 0.75))
                    .frame(width: sidebarWidth)
                    .background(Color(red: 0.07, green: 0.08, blue: 0.1))
                }
            }
            if mapping.editing {
                VStack {
                    HStack(spacing: 8) {
                        Text(mapping.pending ? "按键绑定中…" : "点击画面添加键位").font(.caption)
                        Button("清空") { mapping.clear() }
                        Button("取消") { mapping.cancel() }
                        Button("保存") {
                            do { try mapping.save(); transport.onStatus?("键位方案已保存") }
                            catch { transport.onStatus?(error.localizedDescription) }
                        }
                    }.padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                }.padding(8).padding(.trailing, sidebar.visible ? sidebarWidth : 0)
            } else if !mapping.scheme.bindings.isEmpty {
                VStack { HStack {
                    Button(mapping.enabled ? "停用键位" : "启用键位") { mapping.enabled.toggle() }
                    Button(mapping.hints ? "隐藏提示" : "显示提示") { mapping.hints.toggle() }
                    Spacer()
                }.font(.caption).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)); Spacer() }.padding(8).padding(.trailing, sidebar.visible ? sidebarWidth : 0)
            }
            if status != "准备中" && status != "已连接" {
                VStack {
                    Spacer()
                    VStack(spacing:8) {
                        Text(localized(status)).font(.callout)
                        if transport.connectionEnded, transport.onReconnect != nil {
                            Button("重新连接") { transport.onReconnect?() }
                                .disabled(mapping.editing || transport.recordingStateUnknown)
                            if mapping.editing { Text("请先保存或取消键位编辑。 ").font(.caption) }
                        }
                    }.padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(8)
                }
            }
        }
        .environment(\.locale, Locale(identifier:transport.language == 0 ? "en" : "zh-Hans"))
        .onAppear { transport.onStatus = { message in
            status = message
            if message == "已连接" { connected = true }
            if message.hasPrefix("连接已结束") || message.hasPrefix("无法启动桥接") { connected = false }
            if connected && message != "已连接" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                    if connected && status == message { status = "已连接" }
                }
            }
        } }
        .accessibilityValue(status)
    }
}

final class GameWindowController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onWarning: ((String) -> Void)?
    let transport = PlayerTransport()
    private let sidebar = SidebarState()
    private var sidebarButton: NSButton?
    private var pinButton: NSButton?
    private var stateStore: GameWindowStateStore?
    var window: NSWindow?
    private var aspect: CGFloat = 720.0 / 1280.0
    private var side: CGFloat = sidebarWidth
    private var didReceiveSize = false
    private var frameWidth = 0
    private var frameHeight = 0

    private func fitWindow() {
        guard let window else { return }
        let current = window.contentLayoutRect.size
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let maxHeight = max(200, visible.height - (window.frame.height - current.height) - 24)
        let maxWidth = max(200, visible.width - 24)
        let height = min(current.height, maxHeight, (maxWidth - side) / aspect)
        window.setContentSize(NSSize(width: height * aspect + side, height: height))
        let frame = window.frame
        let x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        let y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !sender.styleMask.contains(.fullScreen) else { return frameSize }
        let decorations = sender.frame.height - sender.contentLayoutRect.height
        let old = sender.contentLayoutRect.size
        let proposedHeight = max(180, frameSize.height - decorations)
        let widthHeight = max(180, (frameSize.width - side) / aspect)
        let height = abs(proposedHeight - old.height) >= abs(widthHeight - old.height) ? proposedHeight : widthHeight
        return NSSize(width: height * aspect + side, height: height + decorations)
    }

    @objc private func toggleSidebar() {
        sidebar.visible.toggle()
        side = sidebar.visible ? sidebarWidth : 0
        updateSidebarButton()
        fitWindow()
    }

    private func updateSidebarButton() {
        let label = transport.language == 0
            ? (sidebar.visible ? "Hide sidebar" : "Show sidebar")
            : (sidebar.visible ? "隐藏侧边栏" : "显示侧边栏")
        sidebarButton?.toolTip = label
        sidebarButton?.setAccessibilityLabel(label)
    }

    private func addSidebarButton(to window: NSWindow) {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: 28))
        button.bezelStyle = .inline
        button.isBordered = false
        button.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "隐藏侧边栏")
        button.imagePosition = .imageOnly
        button.toolTip = "隐藏侧边栏"
        button.setAccessibilityLabel("隐藏侧边栏")
        button.target = self
        button.action = #selector(toggleSidebar)
        accessory.view = button
        sidebarButton = button
        window.addTitlebarAccessoryViewController(accessory)
    }

    @objc private func togglePin() {
        guard let window else { return }
        window.level = window.level == .floating ? .normal : .floating
        updatePinButton()
    }

    private func updatePinButton() {
        let pinned = window?.level == .floating
        let label = transport.language == 0
            ? (pinned ? "Unpin window" : "Pin window")
            : (pinned ? "取消窗口置顶" : "窗口置顶")
        pinButton?.image = NSImage(systemSymbolName:pinned ? "pin.fill" : "pin",accessibilityDescription:label)
        pinButton?.toolTip = label
        pinButton?.setAccessibilityLabel(label)
    }

    private func addPinButton(to window:NSWindow) {
        let accessory = NSTitlebarAccessoryViewController(); accessory.layoutAttribute = .right
        let button = NSButton(frame:NSRect(x:0,y:0,width:36,height:28))
        button.bezelStyle = .inline; button.isBordered = false; button.imagePosition = .imageOnly
        button.target = self; button.action = #selector(togglePin); accessory.view = button
        pinButton = button; window.addTitlebarAccessoryViewController(accessory)
        updatePinButton()
    }

    private func saveState() {
        guard let window, let stateStore, !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
        let frame = window.frame
        let state = GameWindowState(x:frame.minX,y:frame.minY,width:frame.width,height:frame.height,
                                    sidebar:sidebar.visible,onTop:window.level == .floating,landscape:aspect > 1)
        do { try stateStore.save(state) } catch { onWarning?(error.localizedDescription) }
    }

    func open(device: String, width: Int, height: Int, executable: String, displayName: String? = nil, quality: UInt8 = 1, dataDirectory: String? = nil) {
        guard width > 0, height > 0 else { return }
        aspect = CGFloat(width) / CGFloat(height)
        var saved: GameWindowState?
        var legacy: (sidebar:Bool,onTop:Bool)?
        if let dataDirectory {
            do {
                let store = try GameWindowStateStore(dataDirectory:dataDirectory,device:device)
                saved = try store.load(); stateStore = store
                if saved == nil { legacy = try store.legacyPreferences() }
            } catch { onWarning?(error.localizedDescription) }
        }
        if let sidebarVisible = saved?.sidebar ?? legacy?.sidebar { sidebar.visible = sidebarVisible; side = sidebarVisible ? sidebarWidth : 0 }
        let initialHeight: CGFloat = 740
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:initialHeight * aspect + side,height:initialHeight), styleMask:[.titled,.closable,.miniaturizable,.resizable], backing:.buffered, defer:false)
        window.isReleasedWhenClosed = false
        window.title = "\(displayName ?? device) — Jidr"
        window.delegate = self
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: ContentView(transport: transport, mapping: transport.mapping, sidebar: sidebar))
        addSidebarButton(to: window)
        self.window = window
        window.level = (saved?.onTop ?? legacy?.onTop ?? false) ? .floating : .normal
        addPinButton(to:window)
        updateSidebarButton()
        transport.onPixelPerfect = { [weak self] in
            guard let self, let window = self.window, self.frameWidth > 0, self.frameHeight > 0, let screen = window.screen else { return }
            let scale = window.backingScaleFactor
            let size = NSSize(width:CGFloat(self.frameWidth) / scale + self.side,height:CGFloat(self.frameHeight) / scale)
            let full = window.frameRect(forContentRect:NSRect(origin:.zero,size:size))
            guard !window.styleMask.contains(.fullScreen), full.width <= screen.visibleFrame.width, full.height <= screen.visibleFrame.height else {
                self.transport.onStatus?(self.transport.language == 0 ? "Original size does not fit this display" : "原始像素大小超出当前屏幕")
                return
            }
            window.setContentSize(size)
            let frame = window.frame, visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x:min(max(frame.minX,visible.minX),visible.maxX-frame.width), y:min(max(frame.minY,visible.minY),visible.maxY-frame.height)))
        }
        transport.onFrameSize = { [weak self] width, height in
            guard let self, width > 0, height > 0 else { return }
            self.frameWidth = width; self.frameHeight = height
            let next = CGFloat(width) / CGFloat(height)
            if !self.didReceiveSize || abs(next - self.aspect) > 0.001 {
                self.aspect = next
                self.didReceiveSize = true
                self.fitWindow()
            }
        }
        if let saved {
            let frame = NSRect(x:saved.x,y:saved.y,width:saved.width,height:saved.height)
            let title = NSRect(x:frame.minX,y:frame.maxY - 24,width:frame.width,height:24)
            if NSScreen.screens.contains(where: { screen in let overlap = screen.visibleFrame.intersection(title); return !overlap.isNull && overlap.width >= 80 && overlap.height >= 12 }) {
                window.setFrame(frame,display:false)
                if saved.landscape != (aspect > 1) { fitWindow() }
            } else { fitWindow(); window.center() }
        } else { fitWindow(); window.center() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        do { try transport.start(device:device,width:width,height:height,executable:executable,quality:quality) }
        catch { transport.onStatus?("无法启动桥接：\(error.localizedDescription)") }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard transport.recording == .idle else { transport.onStatus?("请先停止录屏并等待保存完成"); return false }
        return true
    }
    func windowWillClose(_ notification: Notification) {
        saveState()
        transport.stop()
        onClose?()
        // AppKit may still be processing the close event after its delegate returns.
        DispatchQueue.main.async { [self] in _ = self }
    }
}
