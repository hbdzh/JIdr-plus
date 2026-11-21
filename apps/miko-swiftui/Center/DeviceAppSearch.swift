// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct DeviceSearchApp: Equatable {
    let name: String
    let package: String
}

/// Main-thread coordinator; the cache only stores text, never app icons.
final class DeviceAppSearch {
    typealias Request = (String, @escaping (Result<[DeviceSearchApp], Error>) -> Void) -> Void
    private struct Entry { let apps: [DeviceSearchApp]; let time: TimeInterval }
    private let request: Request
    private let publish: ([String: String]) -> Void
    private let clock: () -> TimeInterval
    private let ttl: TimeInterval
    private let limit: Int
    private let debounceInterval: TimeInterval
    private let retryInterval: TimeInterval
    private var debounceWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var cache: [String: Entry] = [:]
    private var epochs: [String: Int] = [:]
    private var inFlight: [String: Int] = [:]
    private var failed = Set<String>()
    private var running: [String] = []
    private var query = ""
    private var requestsEnabled = false
    private var lastMatches: [String: String] = [:]

    init(ttl: TimeInterval = 30, limit: Int = 3,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         debounceInterval: TimeInterval = 0.3, retryInterval: TimeInterval = 30,
         request: @escaping Request, publish: @escaping ([String: String]) -> Void) {
        self.ttl = ttl; self.limit = max(1, limit); self.clock = clock
        self.debounceInterval = debounceInterval; self.retryInterval = retryInterval
        self.request = request; self.publish = publish
    }

    /// Typing updates local results immediately; callers debounce `startRequests`.
    func update(query newQuery: String, running newRunning: [String]) {
        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let removed = Set(running).subtracting(newRunning)
        for id in removed { invalidateData(id) }
        if query != trimmed { failed.removeAll() }
        query = trimmed
        running = newRunning
        requestsEnabled = false
        publishMatches()
    }

    /// Updates cached matches immediately and owns the debounced request and retry timers.
    func scheduleUpdate(query: String, running: [String], retryFailed: Bool = false) {
        cancelScheduled()
        update(query: query, running: running)
        if retryFailed { self.retryFailed() }
        guard !self.query.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in self?.startRequests() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: work)
        let refresh = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scheduleUpdate(query: self.query, running: self.running, retryFailed: true)
        }
        retryWork = refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + retryInterval, execute: refresh)
    }

    private func cancelScheduled() {
        debounceWork?.cancel(); debounceWork = nil
        retryWork?.cancel(); retryWork = nil
    }

    func retryFailed() { failed.removeAll() }

    func startRequests() {
        guard !query.isEmpty else { return }
        requestsEnabled = true
        publishMatches()
        pump()
    }

    func reset() {
        cancelScheduled()
        requestsEnabled = false
        for id in running { invalidateData(id) }
        publishMatches()
    }

    func invalidate(_ id: String) {
        invalidateData(id)
        publishMatches()
        pump()
    }

    private func invalidateData(_ id: String) {
        cache.removeValue(forKey: id)
        epochs[id, default: 0] &+= 1
        failed.remove(id)
    }

    private func fresh(_ entry: Entry) -> Bool { clock() - entry.time < ttl }

    private func publishMatches() {
        var matches: [String: String] = [:]
        if !query.isEmpty {
            for id in running {
                guard let entry = cache[id], fresh(entry),
                      let match = entry.apps.first(where: { $0.name.localizedCaseInsensitiveContains(query) || $0.package.localizedCaseInsensitiveContains(query) }) else { continue }
                matches[id] = match.name
            }
        }
        if matches != lastMatches { lastMatches = matches; publish(matches) }
    }

    private func pump() {
        guard requestsEnabled, !query.isEmpty else { return }
        while inFlight.count < limit,
              let id = running.first(where: { inFlight[$0] == nil && !failed.contains($0) && (cache[$0].map { !fresh($0) } ?? true) }) {
            let epoch = epochs[id, default: 0]
            inFlight[id] = epoch
            request(id) { [weak self] result in
                guard let self, self.inFlight[id] == epoch else { return }
                self.inFlight.removeValue(forKey: id)
                if self.running.contains(id), self.epochs[id, default: 0] == epoch {
                    switch result {
                    case .success(let apps): self.cache[id] = Entry(apps: apps, time: self.clock())
                    case .failure: self.failed.insert(id)
                    }
                }
                self.publishMatches()
                self.pump()
            }
        }
    }
}
