// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Foundation

/// Main-thread owner of in-flight center requests and their visible progress.
final class CenterRequestTracker: ObservableObject {
    typealias Completion = (Result<Any, Error>) -> Void
    typealias Progress = (String, String?, Double?) -> Void
    struct Finished {
        let method: String
        let device: String?
        let completion: Completion
    }
    private struct Entry {
        let method: String
        let device: String?
        let mutation: Bool
        let completion: Completion
        let progress: Progress?
        var deadline: DispatchWorkItem?
    }
    private var entries: [Int: Entry] = [:]
    private var sequence = 0
    @Published private var messages: [Int: String] = [:]

    var hasMutations: Bool { entries.values.contains { $0.mutation } }
    var mutationCount: Int { entries.values.filter { $0.mutation }.count }
    var mutationMethods: [String] { entries.values.filter { $0.mutation }.map(\.method) }

    func nextID() -> Int { sequence += 1; return sequence }
    func register(id: Int, method: String, device: String?, mutation: Bool,
                  progress: Progress?, completion: @escaping Completion) {
        entries[id] = Entry(method: method, device: device, mutation: mutation,
                            completion: completion, progress: progress)
    }
    func setDeadline(_ work: DispatchWorkItem, for id: Int) { entries[id]?.deadline = work }

    /// Delivers progress first, then records per-device text for the UI.
    func updateProgress(id: Int, message: String, job: String?, fraction: Double?) -> (hasHandler: Bool, hasDevice: Bool) {
        guard let entry = entries[id] else { return (false, false) }
        entry.progress?(message, job, fraction)
        let hasDevice = entries[id]?.device != nil
        if hasDevice && !message.isEmpty { messages[id] = message }
        return (entry.progress != nil, hasDevice)
    }

    func latestMessage(for device: String) -> String? {
        entries.keys.sorted().reversed().first { entries[$0]?.device == device && messages[$0] != nil }.flatMap { messages[$0] }
    }

    /// Removing a request before invoking its completion prevents double replies.
    func finish(id: Int) -> Finished? {
        guard let entry = entries.removeValue(forKey: id) else { return nil }
        entry.deadline?.cancel()
        messages.removeValue(forKey: id)
        return Finished(method: entry.method, device: entry.device, completion: entry.completion)
    }

    func failAll(_ error: Error) {
        let pending = Array(entries.values)
        entries.removeAll()
        for entry in pending { entry.deadline?.cancel() }
        messages.removeAll()
        for entry in pending { entry.completion(.failure(error)) }
    }

    func cancelDeadlines() {
        for id in Array(entries.keys) {
            entries[id]?.deadline?.cancel()
            entries[id]?.deadline = nil
        }
    }
}
