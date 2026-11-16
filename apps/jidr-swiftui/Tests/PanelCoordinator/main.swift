// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum TestPanel: Equatable { case palette, tasks, edit }
var events: [String] = []
var pending: (() -> Void)?
let coordinator = PanelCoordinator<TestPanel>(present: { events.append("show:\($0)") }, dismiss: { panel, finish in
    events.append("hide:\(panel)"); pending = finish
}, didDismiss: { events.append("closed:\($0)") })
coordinator.request(.palette)
assert(coordinator.active == .palette && events == ["show:palette"])
coordinator.request(.tasks)
assert(coordinator.active == .palette && coordinator.isClosing && events == ["show:palette", "hide:palette"])
coordinator.request(.edit)
assert(events.count == 2, "switches wait until the previous panel is gone")
let firstCompletion = pending!
firstCompletion()
assert(coordinator.active == .edit && events == ["show:palette", "hide:palette", "closed:palette", "show:edit"])
firstCompletion()
assert(coordinator.active == .edit && events.count == 4, "stale completions cannot change a later panel")
var afterCloseRan = false
coordinator.dismissCurrent { afterCloseRan = true; events.append("after") }
assert(coordinator.active == .edit && !afterCloseRan)
pending?()
assert(coordinator.active == nil && afterCloseRan && events.suffix(2) == ["closed:edit", "after"])
coordinator.request(.tasks)
coordinator.request(nil)
let lateCompletion = pending!
coordinator.shutdown()
lateCompletion()
assert(coordinator.active == nil && coordinator.desired == nil && !coordinator.isClosing)
var immediateEvents: [String] = []
let immediate = PanelCoordinator<TestPanel>(present: { immediateEvents.append("show:\($0)") }, dismiss: { panel, finish in
    immediateEvents.append("hide:\(panel)")
    finish()
}, didDismiss: { immediateEvents.append("closed:\($0)") })
immediate.request(.palette)
immediate.request(.tasks)
assert(immediate.active == .tasks && immediateEvents == ["show:palette", "hide:palette", "closed:palette", "show:tasks"],
       "immediate reduced-motion dismissals still serialize transitions")
print("Panel coordinator tests passed")
