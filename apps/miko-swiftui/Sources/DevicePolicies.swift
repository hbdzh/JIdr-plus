// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Draft for the existing settings.set command. Validation is shared by the
/// enabled state and submission, so an invalid draft never looks ready to save.
struct DevicePolicyDraft: Equatable {
    var root: String
    var quickBoot: Bool
    var budget: String
    var idleMinutes: String

    var parameters: [String: Any]? {
        guard ["none", "adb", "magisk"].contains(root),
              let percent = UInt8(budget), (10...100).contains(percent),
              let minutes = UInt32(idleMinutes) else { return nil }
        return ["default_root_mode": root, "quick_boot": quickBoot,
                "budget_percent": percent, "auto_hibernate_minutes": minutes]
    }
}
