// SPDX-License-Identifier: GPL-3.0-only

/// The overview exposes one primary device action for each lifecycle state.
enum DeviceOverviewPrimaryAction: Equatable {
    case start, stop, cancelStart, progress

    init(state: String) {
        switch state {
        case "running": self = .stop
        case "stopped", "crashed", "hibernated": self = .start
        case "starting", "booting": self = .cancelStart
        default: self = .progress
        }
    }
}

