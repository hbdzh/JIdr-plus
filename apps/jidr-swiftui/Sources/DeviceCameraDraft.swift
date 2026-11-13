// SPDX-License-Identifier: GPL-3.0-only

/// Local camera edits are compared with the last acknowledged device value.
struct DeviceCameraDraft: Equatable {
    var back: String
    var front: String
}

struct DeviceCameraEdits {
    var draft = DeviceCameraDraft(back: "default", front: "default")
    private(set) var saved: DeviceCameraDraft?
    var hasChanges: Bool { saved != nil && draft != saved }

    mutating func load(_ value: DeviceCameraDraft) { saved = value; draft = value }
    mutating func revert() { if let saved { draft = saved } }
    mutating func acknowledge(_ value: DeviceCameraDraft, submitted: DeviceCameraDraft) {
        saved = value
        if draft == submitted { draft = value }
    }
}
