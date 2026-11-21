// SPDX-License-Identifier: GPL-3.0-only
import Combine
import Foundation

let tracker = CenterRequestTracker()
var changes = 0
let observer = tracker.objectWillChange.sink { changes += 1 }
var progressCalls = 0
var completed = 0
let one = tracker.nextID(), two = tracker.nextID()
precondition(two == one + 1)
tracker.register(id: one, method: "device.start", device: "device", mutation: true,
                 progress: { _, _, _ in progressCalls += 1 }, completion: { _ in completed += 1 })
tracker.register(id: two, method: "device.details", device: "device", mutation: false,
                 progress: nil, completion: { _ in completed += 1 })
precondition(tracker.hasMutations && tracker.mutationCount == 1 && tracker.mutationMethods == ["device.start"])
let first = tracker.updateProgress(id: one, message: "starting", job: nil, fraction: 0.5)
precondition(first.hasHandler && first.hasDevice && progressCalls == 1)
_ = tracker.updateProgress(id: two, message: "loading", job: nil, fraction: nil)
precondition(tracker.latestMessage(for: "device") == "loading" && changes > 0)
let deadline = DispatchWorkItem { preconditionFailure("finished timeout should be cancelled") }
tracker.setDeadline(deadline, for: two)
let finished = tracker.finish(id: two)!
precondition(finished.method == "device.details" && finished.device == "device" && deadline.isCancelled)
finished.completion(.success(NSNull()))
precondition(tracker.finish(id: two) == nil && tracker.latestMessage(for: "device") == "starting")
tracker.failAll(NSError(domain: "test", code: 1))
precondition(completed == 2 && !tracker.hasMutations && tracker.latestMessage(for: "device") == nil)
tracker.failAll(NSError(domain: "test", code: 2))
precondition(completed == 2, "each request finishes exactly once")
let reentrant = tracker.nextID()
tracker.register(id: reentrant, method: "device.start", device: "device", mutation: true,
                 progress: { _, _, _ in tracker.failAll(NSError(domain: "test", code: 3)) }, completion: { _ in })
let reported = tracker.updateProgress(id: reentrant, message: "late", job: nil, fraction: nil)
precondition(reported.hasHandler && !reported.hasDevice && tracker.latestMessage(for: "device") == nil,
             "progress after a reentrant disconnect cannot resurrect stale state")
withExtendedLifetime(observer) {}
print("Center request tracker tests passed")
