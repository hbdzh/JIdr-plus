// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Owns per-device start, stop and deferred window-close state on the main thread.
final class CenterDeviceLifecycle {
    private(set) var pendingWindowStops = Set<String>()
    private(set) var stoppingDevices = Set<String>()
    private(set) var startingDevices = Set<String>()
    private var startJobs: [String: String] = [:]
    private var startCancelRequested = Set<String>()

    func requestWindowStop(_ id: String) -> Bool { pendingWindowStops.insert(id).inserted }
    func finishWindowStop(_ id: String) { pendingWindowStops.remove(id) }
    func beginStop(_ id: String) { stoppingDevices.insert(id) }
    func finishStop(_ id: String) { stoppingDevices.remove(id) }
    func beginStart(_ id: String) { startingDevices.insert(id) }
    func recordStartJob(_ job: String, for id: String) { startJobs[id] = job }
    func finishStart(_ id: String) {
        startingDevices.remove(id)
        startJobs.removeValue(forKey: id)
        startCancelRequested.remove(id)
    }
    /// Only the first close request may cancel a start job for this device.
    func jobToCancel(for id: String) -> String? {
        guard startingDevices.contains(id), pendingWindowStops.contains(id),
              let job = startJobs[id], startCancelRequested.insert(id).inserted else { return nil }
        return job
    }
}
