// SPDX-License-Identifier: GPL-3.0-only
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}
// The overview has a single lifecycle action and never substitutes Open for Stop.
for state in ["stopped", "crashed", "hibernated"] {
    require(DeviceOverviewPrimaryAction(state: state) == .start, "\(state) offers Start")
}
require(DeviceOverviewPrimaryAction(state: "running") == .stop, "running offers Stop")
for state in ["starting", "booting"] {
    require(DeviceOverviewPrimaryAction(state: state) == .cancelStart, "\(state) retains cancellation")
}
require(DeviceOverviewPrimaryAction(state: "stopping") == .progress, "stopping shows progress")
print("Device overview action tests passed")
