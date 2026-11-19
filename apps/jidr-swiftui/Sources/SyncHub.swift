// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Foundation

enum PlayerSyncRole: String, Equatable {
    case off
    case leader
    case follower
}

enum SyncAdaptation: String, Codable, CaseIterable, Equatable {
    case stretch
    case letterbox
}

struct SyncDisplaySize: Codable, Equatable {
    var width: Int
    var height: Int

    var aspectRatio: Double {
        guard width > 0, height > 0 else { return 0 }
        return Double(width) / Double(height)
    }

    var isPortrait: Bool { height >= width }

    /// True when orientations differ or aspect ratios differ by more than 5%.
    func differsSignificantly(from other: SyncDisplaySize) -> Bool {
        guard width > 0, height > 0, other.width > 0, other.height > 0 else { return false }
        if isPortrait != other.isPortrait { return true }
        let ratio = aspectRatio / other.aspectRatio
        return abs(ratio - 1.0) > 0.05
    }
}

struct SyncOptionsModel: Codable, Equatable {
    var adaptation: SyncAdaptation = .stretch
    var sync_keyboard: Bool = true
    var sync_text: Bool = true
    var sync_tool_keys: Bool = true
    var lock_followers: Bool = true
    var jitter_ms: Int = 0
}

enum SyncFollowerStatus: Equatable, Codable {
    case ready
    case lagging
    case error(String)
    case detached

    private enum CodingKeys: String, CodingKey {
        case state
        case message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let state = try c.decode(String.self, forKey: .state)
        switch state {
        case "ready": self = .ready
        case "lagging": self = .lagging
        case "detached": self = .detached
        case "error":
            let message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
            self = .error(message)
        default:
            self = .ready
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ready:
            try c.encode("ready", forKey: .state)
        case .lagging:
            try c.encode("lagging", forKey: .state)
        case .detached:
            try c.encode("detached", forKey: .state)
        case .error(let message):
            try c.encode("error", forKey: .state)
            try c.encode(message, forKey: .message)
        }
    }
}

struct SyncFollowerCounters: Codable, Equatable {
    var forwarded: Int = 0
    var dropped: Int = 0
}

struct SyncFollowerModel: Codable, Equatable, Identifiable {
    var id: String { device }
    var device: String
    var display: SyncDisplaySize?
    var status: SyncFollowerStatus
    var counters: SyncFollowerCounters
}

struct SyncSessionModel: Codable, Equatable, Identifiable {
    var id: String
    var leader: String
    var leader_display: SyncDisplaySize?
    var followers: [SyncFollowerModel]
    var options: SyncOptionsModel
    var started_at: String

    var memberCount: Int { 1 + followers.count }
}

/// Bridge transport surface required by `SyncHub` (implemented by
/// `PlayerTransport` and by fake targets in unit tests).
protocol SyncBridgeTarget: AnyObject {
    var syncDeviceID: String? { get }
    func sendSyncMode(
        role: String,
        lock: Bool,
        leader: String?,
        leaderDisplay: SyncDisplaySize?,
        adaptation: String,
        syncKeyboard: Bool,
        syncText: Bool,
        syncToolKeys: Bool
    )
    func sendSyncInput(seq: Int, event: [String: Any])
    func sendSyncRelease()
}

/// Routes real-time input events from the active leader bridge to every
/// follower bridge on per-follower serial queues (D45).
final class SyncHub: ObservableObject {
    private struct AppliedSyncMode: Equatable {
        let role: String
        let lock: Bool
        let leader: String?
        let leaderDisplay: SyncDisplaySize?
        let adaptation: String
        let syncKeyboard: Bool
        let syncText: Bool
        let syncToolKeys: Bool
    }

    private struct QueuedRelayWork {
        let generation: UInt64
        let seq: Int
        let event: [String: Any]
        let emittedAt: TimeInterval
        let deadline: DispatchTime
        let moveFinger: String?
    }

    private static let maxQueueCapacity = 256
    private static let overflowLimit = 8

    @Published private(set) var session: SyncSessionModel?
    @Published private(set) var totalEventsRelayed: Int = 0
    @Published private(set) var averageLatencyMs: Int = 0
    @Published private(set) var lastError: String?

    /// Opens a background player session for a follower with no open window.
    var ensureBridge: ((String) -> Void)?
    /// Closes a background-only player session created by the hub.
    var releaseBackgroundBridge: ((String) -> Void)?
    /// Reports follower status/counters to the daemon (`sync.report`), throttled.
    var reportHealth: ((String, SyncFollowerStatus, SyncFollowerCounters) -> Void)?

    private let stateLock = NSLock()
    private var bridges: [String: SyncBridgeTarget] = [:]
    private var backgroundOwned: Set<String> = []
    private var queues: [String: DispatchQueue] = [:]
    private var pendingQueues: [String: [QueuedRelayWork]] = [:]
    private var lastDeadlines: [String: DispatchTime] = [:]
    private var downFingers: [String: Set<String>] = [:]
    private var overflows: [String: Int] = [:]
    private var activeFollowers: Set<String> = []
    private var appliedModes: [String: AppliedSyncMode] = [:]
    private var relayGeneration: UInt64 = 0
    private var counters: [String: SyncFollowerCounters] = [:]
    private var lastReportAt: [String: TimeInterval] = [:]
    private var latencySamples: [Double] = []

    func registerBridge(_ target: SyncBridgeTarget, for deviceID: String, background: Bool = false) {
        stateLock.lock()
        bridges[deviceID] = target
        appliedModes.removeValue(forKey: deviceID)
        if background {
            backgroundOwned.insert(deviceID)
        }
        let currentSession = session
        if let currentSession, currentSession.followers.contains(where: { $0.device == deviceID }) {
            activeFollowers.insert(deviceID)
        }
        stateLock.unlock()

        applyRole(for: deviceID, on: target, session: currentSession, force: true)
        if let currentSession,
           currentSession.followers.contains(where: { $0.device == deviceID && $0.status == .detached }) {
            let c = counters[deviceID] ?? SyncFollowerCounters()
            reportHealth?(deviceID, .ready, c)
        }
    }

    func markWindowVisible(for deviceID: String) {
        stateLock.lock()
        backgroundOwned.remove(deviceID)
        stateLock.unlock()
    }

    func unregisterBridge(for deviceID: String) {
        stateLock.lock()
        bridges.removeValue(forKey: deviceID)
        queues.removeValue(forKey: deviceID)
        pendingQueues.removeValue(forKey: deviceID)
        lastDeadlines.removeValue(forKey: deviceID)
        downFingers.removeValue(forKey: deviceID)
        overflows.removeValue(forKey: deviceID)
        appliedModes.removeValue(forKey: deviceID)
        activeFollowers.remove(deviceID)
        backgroundOwned.remove(deviceID)
        stateLock.unlock()
    }

    /// Marks a bridge as disconnected while its player window remains open (e.g.
    /// waiting for Reconnect). Releases followers if the leader died, or
    /// marks a follower `detached` so it stops receiving/reporting events.
    func markBridgeLost(for deviceID: String) {
        stateLock.lock()
        bridges.removeValue(forKey: deviceID)
        queues.removeValue(forKey: deviceID)
        pendingQueues.removeValue(forKey: deviceID)
        lastDeadlines.removeValue(forKey: deviceID)
        downFingers.removeValue(forKey: deviceID)
        appliedModes.removeValue(forKey: deviceID)
        activeFollowers.remove(deviceID)
        let currentSession = session
        let followerTargets: [SyncBridgeTarget] = currentSession?.followers.compactMap { bridges[$0.device] } ?? []
        let c = counters[deviceID] ?? SyncFollowerCounters()
        stateLock.unlock()

        guard let currentSession else { return }
        if currentSession.leader == deviceID {
            for target in followerTargets {
                target.sendSyncRelease()
            }
        } else if currentSession.followers.contains(where: { $0.device == deviceID }) {
            reportHealth?(deviceID, .detached, c)
        }
    }

    /// Releases held inputs on all followers when the leader pauses or stops
    /// script playback/recording, discarding any queued pre-release events.
    func releaseFollowers(from deviceID: String) {
        guard let currentSession = session, currentSession.leader == deviceID else { return }

        stateLock.lock()
        relayGeneration &+= 1
        pendingQueues.removeAll()
        lastDeadlines.removeAll()
        downFingers.removeAll()
        let followerTargets: [SyncBridgeTarget] = currentSession.followers.compactMap { bridges[$0.device] }
        stateLock.unlock()

        for target in followerTargets {
            target.sendSyncRelease()
        }
    }

    func applySession(_ next: SyncSessionModel?) {
        let previous = session
        session = next

        if next == nil {
            totalEventsRelayed = 0
            averageLatencyMs = 0
            latencySamples.removeAll()
            lastReportAt.removeAll()

            stateLock.lock()
            relayGeneration &+= 1
            activeFollowers.removeAll()
            pendingQueues.removeAll()
            lastDeadlines.removeAll()
            downFingers.removeAll()
            overflows.removeAll()
            counters.removeAll()
            queues.removeAll()
            let prevMembers = previous.map { [$0.leader] + $0.followers.map(\.device) } ?? []
            var toTurnOff: [(String, SyncBridgeTarget)] = []
            var toReleaseBg: [String] = []
            for id in prevMembers {
                if let target = bridges[id] {
                    toTurnOff.append((id, target))
                }
                if backgroundOwned.remove(id) != nil {
                    toReleaseBg.append(id)
                }
            }
            stateLock.unlock()

            for (id, target) in toTurnOff {
                applyRole(for: id, on: target, session: nil)
            }
            for id in toReleaseBg {
                releaseBackgroundBridge?(id)
            }
            return
        }

        guard let next else { return }
        let activeIDs = Set([next.leader] + next.followers.map(\.device))
        let followerIDs = Set(next.followers.map(\.device))
        let sessionOrLeaderChanged = previous?.id != next.id || previous?.leader != next.leader

        stateLock.lock()
        if sessionOrLeaderChanged {
            relayGeneration &+= 1
            pendingQueues.removeAll()
            lastDeadlines.removeAll()
            downFingers.removeAll()
            overflows.removeAll()
        }
        activeFollowers = followerIDs.intersection(Set(bridges.keys))

        var removedTargets: [(String, SyncBridgeTarget)] = []
        var removedBg: [String] = []
        if let prev = previous {
            let prevIDs = Set([prev.leader] + prev.followers.map(\.device))
            for removed in prevIDs.subtracting(activeIDs) {
                queues.removeValue(forKey: removed)
                pendingQueues.removeValue(forKey: removed)
                lastDeadlines.removeValue(forKey: removed)
                downFingers.removeValue(forKey: removed)
                overflows.removeValue(forKey: removed)
                counters.removeValue(forKey: removed)
                lastReportAt.removeValue(forKey: removed)
                if let target = bridges[removed] {
                    removedTargets.append((removed, target))
                }
                if backgroundOwned.remove(removed) != nil {
                    removedBg.append(removed)
                }
            }
        }

        var existingTargets: [(String, SyncBridgeTarget)] = []
        var missingFollowers: [String] = []
        for id in activeIDs {
            if let target = bridges[id] {
                existingTargets.append((id, target))
            } else if id != next.leader {
                missingFollowers.append(id)
            }
        }
        stateLock.unlock()

        for (removed, target) in removedTargets {
            applyRole(for: removed, on: target, session: nil)
        }
        for removed in removedBg {
            releaseBackgroundBridge?(removed)
        }
        for (id, target) in existingTargets {
            applyRole(for: id, on: target, session: next)
        }
        for fid in missingFollowers {
            // Ensure a background player session exists for followers without an open window.
            ensureBridge?(fid)
        }
    }

    func recordError(_ message: String) {
        lastError = message
    }

    func clearError() {
        lastError = nil
    }

    /// Relays one `JIDR_SYNC:` event from the leader bridge to all active followers.
    func handleLeaderEvent(
        from deviceID: String,
        seq: Int,
        event: [String: Any],
        emittedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        guard let session, session.leader == deviceID else { return }
        guard Self.allowsEvent(event, options: session.options) else { return }

        totalEventsRelayed += 1
        let jitterMax = max(0, min(20, session.options.jitter_ms))
        let fingerInfo = Self.classifyFinger(event)

        var pendingReports: [(String, SyncFollowerStatus, SyncFollowerCounters)] = []
        var toSchedule: [(String, SyncBridgeTarget, DispatchQueue, DispatchTime, Bool)] = []

        stateLock.lock()
        let gen = relayGeneration
        let now = DispatchTime.now()

        for follower in session.followers {
            let fid = follower.device
            guard activeFollowers.contains(fid), let target = bridges[fid] else { continue }
            if overflows[fid, default: 0] >= Self.overflowLimit { continue }

            let moveFinger: String? = {
                guard let (finger, isDown) = fingerInfo, isDown,
                      downFingers[fid, default: []].contains(finger) else { return nil }
                return finger
            }()

            if let finger = moveFinger,
               var queueItems = pendingQueues[fid],
               let last = queueItems.last,
               last.generation == gen,
               last.moveFinger == finger {
                queueItems[queueItems.count - 1] = QueuedRelayWork(
                    generation: gen,
                    seq: seq,
                    event: event,
                    emittedAt: emittedAt,
                    deadline: last.deadline,
                    moveFinger: finger
                )
                pendingQueues[fid] = queueItems
                var c = counters[fid] ?? SyncFollowerCounters()
                c.dropped += 1
                counters[fid] = c
                continue
            }

            var queueItems = pendingQueues[fid] ?? []
            if queueItems.count >= Self.maxQueueCapacity {
                if let dropIdx = queueItems.firstIndex(where: { $0.moveFinger != nil }) {
                    queueItems.remove(at: dropIdx)
                    var c = counters[fid] ?? SyncFollowerCounters()
                    c.dropped += 1
                    counters[fid] = c
                } else if moveFinger != nil {
                    var c = counters[fid] ?? SyncFollowerCounters()
                    c.dropped += 1
                    counters[fid] = c
                    continue
                } else {
                    let count = overflows[fid, default: 0] + 1
                    overflows[fid] = count
                    let c = counters[fid] ?? SyncFollowerCounters()
                    if count >= Self.overflowLimit {
                        activeFollowers.remove(fid)
                        pendingQueues[fid] = nil
                        pendingReports.append((fid, .error("the follower fell too far behind and lost input"), c))
                    } else {
                        pendingReports.append((fid, .lagging, c))
                    }
                    continue
                }
            }

            if let (finger, isDown) = fingerInfo {
                var held = downFingers[fid] ?? []
                if isDown {
                    held.insert(finger)
                } else {
                    held.remove(finger)
                }
                downFingers[fid] = held
            }

            let delayMs = jitterMax > 0 ? Int.random(in: 0...jitterMax) : 0
            let prevDeadline = lastDeadlines[fid] ?? now
            let targetTime = max(prevDeadline, now + .milliseconds(delayMs))
            lastDeadlines[fid] = targetTime

            let wasEmpty = queueItems.isEmpty
            queueItems.append(QueuedRelayWork(
                generation: gen,
                seq: seq,
                event: event,
                emittedAt: emittedAt,
                deadline: targetTime,
                moveFinger: moveFinger
            ))
            pendingQueues[fid] = queueItems

            let queue = queues[fid] ?? {
                let q = DispatchQueue(label: "jidr.sync.follower.\(fid)", qos: .userInteractive)
                queues[fid] = q
                return q
            }()
            toSchedule.append((fid, target, queue, targetTime, delayMs == 0 && wasEmpty))
        }
        stateLock.unlock()

        for (fid, status, c) in pendingReports {
            reportHealth?(fid, status, c)
        }

        for (fid, target, queue, targetTime, immediate) in toSchedule {
            if immediate {
                queue.async { [weak self, weak target] in
                    self?.drainQueue(for: fid, target: target)
                }
            } else {
                queue.asyncAfter(deadline: targetTime) { [weak self, weak target] in
                    self?.drainQueue(for: fid, target: target)
                }
            }
        }
    }

    private func drainQueue(for fid: String, target: SyncBridgeTarget?) {
        while true {
            stateLock.lock()
            guard let target, activeFollowers.contains(fid) else {
                pendingQueues.removeValue(forKey: fid)
                stateLock.unlock()
                return
            }
            guard var items = pendingQueues[fid], let first = items.first else {
                stateLock.unlock()
                return
            }
            if first.generation != relayGeneration {
                items.removeFirst()
                pendingQueues[fid] = items
                stateLock.unlock()
                continue
            }
            let now = DispatchTime.now()
            if first.deadline > now {
                let queue = queues[fid]
                let rescheduleAt = first.deadline
                stateLock.unlock()
                queue?.asyncAfter(deadline: rescheduleAt) { [weak self, weak target] in
                    self?.drainQueue(for: fid, target: target)
                }
                return
            }
            items.removeFirst()
            pendingQueues[fid] = items
            var c = counters[fid] ?? SyncFollowerCounters()
            c.forwarded += 1
            counters[fid] = c
            let status: SyncFollowerStatus = (overflows[fid, default: 0] > 0 || items.count * 2 > Self.maxQueueCapacity)
                ? .lagging
                : .ready
            stateLock.unlock()

            target.sendSyncInput(seq: first.seq, event: first.event)
            let elapsedMs = max(0, (ProcessInfo.processInfo.systemUptime - first.emittedAt) * 1000.0)
            DispatchQueue.main.async { [weak self] in
                self?.recordDelivery(deviceID: fid, elapsedMs: elapsedMs, status: status, counters: c)
            }
        }
    }

    private static func classifyFinger(_ event: [String: Any]) -> (String, Bool)? {
        guard let type = event["type"] as? String else { return nil }
        switch type {
        case "touch":
            guard let down = event["down"] as? Bool else { return nil }
            return ("touch", down)
        case "mapped_touch":
            guard let id = event["id"] as? Int, let down = event["down"] as? Bool else { return nil }
            return ("mapped:\(id)", down)
        default:
            return nil
        }
    }

    static func allowsEvent(_ event: [String: Any], options: SyncOptionsModel) -> Bool {
        guard let type = event["type"] as? String else { return false }
        switch type {
        case "touch", "mapped_touch":
            return true
        case "key":
            return options.sync_keyboard
        case "text", "paste":
            return options.sync_text
        case "tool_key":
            return options.sync_tool_keys
        default:
            return false
        }
    }

    private func recordDelivery(
        deviceID: String,
        elapsedMs: Double,
        status: SyncFollowerStatus,
        counters: SyncFollowerCounters
    ) {
        latencySamples.append(elapsedMs)
        if latencySamples.count > 64 {
            latencySamples.removeFirst(latencySamples.count - 64)
        }
        if !latencySamples.isEmpty {
            let sum = latencySamples.reduce(0, +)
            averageLatencyMs = Int((sum / Double(latencySamples.count)).rounded())
        }
        let now = ProcessInfo.processInfo.systemUptime
        let last = lastReportAt[deviceID] ?? 0
        if now - last >= 0.5 {
            lastReportAt[deviceID] = now
            reportHealth?(deviceID, status, counters)
        }
    }

    private func applyRole(
        for deviceID: String,
        on target: SyncBridgeTarget,
        session: SyncSessionModel?,
        force: Bool = false
    ) {
        let nextMode: AppliedSyncMode
        if let session {
            let role: String
            if session.leader == deviceID {
                role = "leader"
            } else if session.followers.contains(where: { $0.device == deviceID }) {
                role = "follower"
            } else {
                role = "off"
            }
            nextMode = AppliedSyncMode(
                role: role,
                lock: session.options.lock_followers,
                leader: session.leader,
                leaderDisplay: session.leader_display,
                adaptation: session.options.adaptation.rawValue,
                syncKeyboard: session.options.sync_keyboard,
                syncText: session.options.sync_text,
                syncToolKeys: session.options.sync_tool_keys
            )
        } else {
            nextMode = AppliedSyncMode(
                role: "off",
                lock: false,
                leader: nil,
                leaderDisplay: nil,
                adaptation: SyncAdaptation.stretch.rawValue,
                syncKeyboard: true,
                syncText: true,
                syncToolKeys: true
            )
        }

        stateLock.lock()
        let unchanged = !force && appliedModes[deviceID] == nextMode
        if !unchanged {
            appliedModes[deviceID] = nextMode
        }
        stateLock.unlock()

        guard !unchanged else { return }

        target.sendSyncMode(
            role: nextMode.role,
            lock: nextMode.lock,
            leader: nextMode.leader,
            leaderDisplay: nextMode.leaderDisplay,
            adaptation: nextMode.adaptation,
            syncKeyboard: nextMode.syncKeyboard,
            syncText: nextMode.syncText,
            syncToolKeys: nextMode.syncToolKeys
        )
    }
}
