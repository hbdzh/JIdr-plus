// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import Foundation

struct LogLineBuffer {
    private(set) var lines: [String] = []
    let limit: Int
    mutating func append(_ newLines: [String]) {
        lines.append(contentsOf: newLines)
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }
}

/// Owns one private logcat bridge connection; stopping it closes that connection.
final class LogStream: ObservableObject {
    @Published private(set) var text = ""
    @Published private(set) var error: String?
    @Published private(set) var active = false
    @Published private(set) var revision = 0
    private var process: Process?
    private var pending = Data()
    private var buffer = LogLineBuffer(limit: 1000)
    private var generation = UUID()

    deinit { if process?.isRunning == true { process?.terminate() } }

    func start(executable: String, device: String, filters: [String]) {
        guard process == nil else { return }
        do {
            let filterData = try JSONEncoder().encode(filters)
            guard let filterJSON = String(data: filterData, encoding: .utf8) else { return }
            let child = Process(), output = Pipe()
            let token = UUID(); generation = token
            child.executableURL = URL(fileURLWithPath: executable)
            child.arguments = ["--logcat", device, filterJSON]
            child.standardOutput = output; child.standardError = FileHandle.nullDevice
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                DispatchQueue.main.async { self?.consume(data, generation: token) }
            }
            child.terminationHandler = { [weak self] _ in
                output.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.process = nil; self.active = false
                    self.error = "日志连接已结束。"
                }
            }
            try child.run()
            process = child; active = true; error = nil; pending.removeAll()
            buffer = LogLineBuffer(limit: 1000); text = ""; revision += 1
        } catch {
            self.error = error.localizedDescription
            active = false
        }
    }

    func stop() {
        generation = UUID()
        let child = process; process = nil; active = false
        if child?.isRunning == true { child?.terminate() }
        pending.removeAll()
    }

    private func consume(_ data: Data, generation token: UUID) {
        guard generation == token else { return }
        pending.append(data)
        while let end = pending.firstIndex(of: 10) {
            let line = Data(pending.prefix(upTo: end)); pending.removeSubrange(...end)
            guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String:Any] else { continue }
            if event["type"] as? String == "lines", let lines = event["lines"] as? [String] {
                buffer.append(lines); text = buffer.lines.joined(separator: "\n"); revision += 1
            } else if event["type"] as? String == "dropped" {
                error = "日志量过大，部分内容未接收。"
            }
        }
        if pending.count > 2 * 1024 * 1024 { stop(); error = "日志数据过大，连接已停止。" }
    }
}
