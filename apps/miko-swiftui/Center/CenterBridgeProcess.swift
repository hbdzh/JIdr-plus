// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Owns one center bridge process and its pipes. Events are delivered on the
/// main queue with their originating session so the model can reject old work.
final class CenterBridgeProcess {
    private final class ReadBuffer { var data = Data() }
    private let executable: String
    private let onEvent: ([String: Any], Int) -> Void
    private let onTermination: (Int) -> Void
    private let parseQueue = DispatchQueue(label: "local.miko.center.parse", qos: .userInitiated)
    private var process: Process?
    private var output: Pipe?
    private var writer: CenterRequestWriter?

    init(executable: String, onEvent: @escaping ([String: Any], Int) -> Void,
         onTermination: @escaping (Int) -> Void) {
        self.executable = executable
        self.onEvent = onEvent
        self.onTermination = onTermination
    }

    var isRunning: Bool { process?.isRunning == true }
    var canWrite: Bool { writer != nil }

    func start(session: Int) throws {
        stopReading()
        let buffer = ReadBuffer()
        let child = Process(), input = Pipe(), output = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.standardError
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.parseQueue.async { [weak self] in self?.receive(data, session: session, buffer: buffer) }
        }
        child.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.onTermination(session) }
        }
        let writer = try CenterRequestWriter(handle: input.fileHandleForWriting)
        do { try child.run() } catch { writer.stop(); throw error }
        self.process = child
        self.output = output
        self.writer = writer
    }

    func send(id: Int, data: Data, onFailure: @escaping (Error) -> Void) -> Bool {
        writer?.send(id: id, data: data, onFailure: onFailure) ?? false
    }
    func cancel(id: Int) { writer?.cancel(id: id) }
    func stopReading() { output?.fileHandleForReading.readabilityHandler = nil }
    func stopWriting() { writer?.stop(); writer = nil }
    func terminate() { if process?.isRunning == true { process?.terminate() } }

    private func receive(_ data: Data, session: Int, buffer: ReadBuffer) {
        buffer.data.append(data)
        while let end = buffer.data.firstIndex(of: 10) {
            let line = Data(buffer.data.prefix(upTo: end))
            buffer.data.removeSubrange(...end)
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            DispatchQueue.main.async { [weak self] in self?.onEvent(event, session) }
        }
    }
}
