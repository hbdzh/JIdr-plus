// SPDX-License-Identifier: GPL-3.0-only
import Foundation

final class FakeBridgeTarget: SyncBridgeTarget {
    var syncDeviceID: String?
    var modes: [(role: String, lock: Bool, leader: String?, adaptation: String)] = []
    var inputs: [(seq: Int, type: String, down: Bool?)] = []
    var releaseCount = 0
    private let lock = NSLock()

    init(deviceID: String) {
        self.syncDeviceID = deviceID
    }

    func sendSyncMode(
        role: String,
        lock: Bool,
        leader: String?,
        leaderDisplay: SyncDisplaySize?,
        adaptation: String,
        syncKeyboard: Bool,
        syncText: Bool,
        syncToolKeys: Bool
    ) {
        self.lock.lock()
        modes.append((role, lock, leader, adaptation))
        self.lock.unlock()
    }

    func sendSyncInput(seq: Int, event: [String: Any]) {
        self.lock.lock()
        let type = event["type"] as? String ?? ""
        let down = event["down"] as? Bool
        inputs.append((seq, type, down))
        self.lock.unlock()
    }

    func sendSyncRelease() {
        self.lock.lock()
        releaseCount += 1
        self.lock.unlock()
    }

    func inputSnapshot() -> [(seq: Int, type: String, down: Bool?)] {
        lock.lock()
        defer { lock.unlock() }
        return inputs
    }

    func modeCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return modes.count
    }

    func releaseSnapshot() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return releaseCount
    }
}

func assertTrue(_ cond: Bool, _ msg: String) {
    if !cond {
        fputs("FAIL: \(msg)\n", stderr)
        exit(1)
    }
}

func testRelayOrderingAndFiltering() {
    let hub = SyncHub()
    let leader = FakeBridgeTarget(deviceID: "L")
    let f1 = FakeBridgeTarget(deviceID: "F1")
    let f2 = FakeBridgeTarget(deviceID: "F2")
    hub.registerBridge(leader, for: "L")
    hub.registerBridge(f1, for: "F1")
    hub.registerBridge(f2, for: "F2")

    let session = SyncSessionModel(
        id: "s1",
        leader: "L",
        leader_display: SyncDisplaySize(width: 1080, height: 2400),
        followers: [
            SyncFollowerModel(device: "F1", display: nil, status: .ready, counters: .init()),
            SyncFollowerModel(device: "F2", display: nil, status: .ready, counters: .init()),
        ],
        options: SyncOptionsModel(
            adaptation: .letterbox,
            sync_keyboard: true,
            sync_text: false,
            sync_tool_keys: true,
            lock_followers: true,
            jitter_ms: 0
        ),
        started_at: "2026-11-19T00:00:00Z"
    )
    hub.applySession(session)

    assertTrue(leader.modes.last?.role == "leader", "leader mode set")
    assertTrue(f1.modes.last?.role == "follower" && f1.modes.last?.adaptation == "letterbox", "f1 mode set")

    // Touch and key are forwarded; text is filtered by sync_text=false; non-leader events ignored.
    hub.handleLeaderEvent(from: "L", seq: 1, event: ["type": "touch", "x": 0.5, "y": 0.5, "down": true])
    hub.handleLeaderEvent(from: "L", seq: 2, event: ["type": "text", "text": "secret"])
    hub.handleLeaderEvent(from: "F1", seq: 3, event: ["type": "touch", "x": 0.1, "y": 0.1, "down": true])
    hub.handleLeaderEvent(from: "L", seq: 4, event: ["type": "key", "key": "A", "down": true])

    let deadline = Date().addingTimeInterval(2.0)
    while Date() < deadline && (f1.inputSnapshot().count < 2 || f2.inputSnapshot().count < 2) {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    assertTrue(f1.inputSnapshot().map(\.seq) == [1, 4], "f1 received [1, 4]")
    assertTrue(f2.inputSnapshot().map(\.seq) == [1, 4], "f2 received [1, 4]")
    assertTrue(leader.inputSnapshot().isEmpty, "leader never receives relayed inputs")
    assertTrue(hub.totalEventsRelayed == 2, "totalEventsRelayed == 2")
}

func testBackgroundSessionLifecycleAndTeardown() {
    let hub = SyncHub()
    let leader = FakeBridgeTarget(deviceID: "L")
    hub.registerBridge(leader, for: "L")

    var ensured: [String] = []
    var released: [String] = []
    hub.ensureBridge = { id in
        ensured.append(id)
        let target = FakeBridgeTarget(deviceID: id)
        hub.registerBridge(target, for: id, background: true)
    }
    hub.releaseBackgroundBridge = { id in
        released.append(id)
    }

    let session = SyncSessionModel(
        id: "s2",
        leader: "L",
        leader_display: nil,
        followers: [
            SyncFollowerModel(device: "F-bg", display: nil, status: .ready, counters: .init()),
        ],
        options: SyncOptionsModel(),
        started_at: "2026-11-19T00:00:00Z"
    )
    hub.applySession(session)
    assertTrue(ensured == ["F-bg"], "ensured background bridge for F-bg")

    hub.applySession(nil)
    assertTrue(released == ["F-bg"], "released background bridge on stop")
    assertTrue(leader.modes.last?.role == "off", "leader turned off on stop")
}

func testDisplayMismatchDetection() {
    let portrait = SyncDisplaySize(width: 1080, height: 2400)
    let portraitSimilar = SyncDisplaySize(width: 720, height: 1600)
    let landscape = SyncDisplaySize(width: 2400, height: 1080)
    assertTrue(!portrait.differsSignificantly(from: portraitSimilar), "same aspect ratio should match")
    assertTrue(portrait.differsSignificantly(from: landscape), "orientation mismatch should warn")
}

func testJitterPreservesFifoOrder() {
    let hub = SyncHub()
    let leader = FakeBridgeTarget(deviceID: "L")
    let f1 = FakeBridgeTarget(deviceID: "F1")
    hub.registerBridge(leader, for: "L")
    hub.registerBridge(f1, for: "F1")

    var opts = SyncOptionsModel()
    opts.jitter_ms = 20
    let session = SyncSessionModel(
        id: "s-jitter",
        leader: "L",
        leader_display: nil,
        followers: [
            SyncFollowerModel(device: "F1", display: nil, status: .ready, counters: .init()),
        ],
        options: opts,
        started_at: "2026-11-19T00:00:00Z"
    )
    hub.applySession(session)

    let count = 25
    for seq in 1...count {
        hub.handleLeaderEvent(from: "L", seq: seq, event: ["type": "touch", "x": 0.5, "y": 0.5, "down": seq % 2 == 1])
    }

    let deadline = Date().addingTimeInterval(3.0)
    while Date() < deadline && f1.inputSnapshot().count < count {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }

    let seqs = f1.inputSnapshot().map(\.seq)
    assertTrue(seqs == Array(1...count), "jitter must preserve FIFO seq order, got \(seqs)")
}

func testBridgeLossAndModeDeduplication() {
    let hub = SyncHub()
    let leader = FakeBridgeTarget(deviceID: "L")
    let f1 = FakeBridgeTarget(deviceID: "F1")
    let f2 = FakeBridgeTarget(deviceID: "F2")
    hub.registerBridge(leader, for: "L")
    hub.registerBridge(f1, for: "F1")
    hub.registerBridge(f2, for: "F2")

    var reported: [(String, SyncFollowerStatus)] = []
    hub.reportHealth = { id, status, _ in
        reported.append((id, status))
    }

    let s1 = SyncSessionModel(
        id: "s3",
        leader: "L",
        leader_display: SyncDisplaySize(width: 1080, height: 2400),
        followers: [
            SyncFollowerModel(device: "F1", display: nil, status: .ready, counters: .init()),
            SyncFollowerModel(device: "F2", display: nil, status: .ready, counters: .init()),
        ],
        options: SyncOptionsModel(),
        started_at: "2026-11-19T00:00:00Z"
    )
    hub.applySession(s1)
    let modesAfterStart = f2.modeCount()

    // Counter-only update must not resend sync_mode.
    let s1Counters = SyncSessionModel(
        id: "s3",
        leader: "L",
        leader_display: SyncDisplaySize(width: 1080, height: 2400),
        followers: [
            SyncFollowerModel(device: "F1", display: nil, status: .ready, counters: .init(forwarded: 5, dropped: 0)),
            SyncFollowerModel(device: "F2", display: nil, status: .ready, counters: .init(forwarded: 5, dropped: 0)),
        ],
        options: SyncOptionsModel(),
        started_at: "2026-11-19T00:00:00Z"
    )
    hub.applySession(s1Counters)
    assertTrue(f2.modeCount() == modesAfterStart, "counter-only update should not resend sync_mode")

    // Leader switch must send updated leader to F2.
    let s1Switched = SyncSessionModel(
        id: "s3",
        leader: "F1",
        leader_display: SyncDisplaySize(width: 1080, height: 2400),
        followers: [
            SyncFollowerModel(device: "L", display: nil, status: .ready, counters: .init()),
            SyncFollowerModel(device: "F2", display: nil, status: .ready, counters: .init()),
        ],
        options: SyncOptionsModel(),
        started_at: "2026-11-19T00:00:00Z"
    )
    hub.applySession(s1Switched)
    assertTrue(f2.modeCount() == modesAfterStart + 1 && f2.modes.last?.leader == "F1", "leader switch updates F2")

    // Losing follower F2 reports detached; losing leader F1 releases remaining follower L.
    hub.markBridgeLost(for: "F2")
    assertTrue(reported.last?.0 == "F2" && reported.last?.1 == .detached, "lost follower reported detached")
    hub.markBridgeLost(for: "F1")
    assertTrue(leader.releaseSnapshot() == 1, "lost leader releases remaining followers")
}

func testLeaderReleaseClearsPendingAndReleasesFollowers() {
    let hub = SyncHub()
    let leader = FakeBridgeTarget(deviceID: "L")
    let f1 = FakeBridgeTarget(deviceID: "F1")
    let f2 = FakeBridgeTarget(deviceID: "F2")
    hub.registerBridge(leader, for: "L")
    hub.registerBridge(f1, for: "F1")
    hub.registerBridge(f2, for: "F2")

    var opts = SyncOptionsModel()
    opts.jitter_ms = 20
    let session = SyncSessionModel(
        id: "s-release",
        leader: "L",
        leader_display: nil,
        followers: [
            SyncFollowerModel(device: "F1", display: nil, status: .ready, counters: .init()),
            SyncFollowerModel(device: "F2", display: nil, status: .ready, counters: .init()),
        ],
        options: opts,
        started_at: "2026-11-19T00:00:00Z"
    )
    hub.applySession(session)

    hub.handleLeaderEvent(from: "L", seq: 1, event: ["type": "touch", "x": 0.5, "y": 0.5, "down": true])
    hub.releaseFollowers(from: "F1")
    assertTrue(f1.releaseSnapshot() == 0 && f2.releaseSnapshot() == 0, "non-leader release ignored")

    hub.releaseFollowers(from: "L")
    assertTrue(f1.releaseSnapshot() == 1 && f2.releaseSnapshot() == 1, "leader release reaches every follower")

    // Queued jittered event from before release must be dropped rather than arriving after release.
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    assertTrue(f1.inputSnapshot().isEmpty && f2.inputSnapshot().isEmpty, "pre-release queued inputs discarded")
}

testRelayOrderingAndFiltering()
testBackgroundSessionLifecycleAndTeardown()
testDisplayMismatchDetection()
testJitterPreservesFifoOrder()
testBridgeLossAndModeDeduplication()
testLeaderReleaseClearsPendingAndReleasesFollowers()
print("SyncHub tests ok")
