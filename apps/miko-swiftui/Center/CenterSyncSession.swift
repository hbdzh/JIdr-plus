// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Converts center-protocol session updates without coupling the sync hub to JSON.
enum CenterSyncSession {
    static func apply(_ value: Any?, to hub: SyncHub) {
        guard let value, !(value is NSNull) else { hub.applySession(nil); return }
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
            let session = try JSONDecoder().decode(SyncSessionModel.self, from: data)
            hub.clearError()
            hub.applySession(session)
        } catch {
            // Keep existing state if payload is malformed.
        }
    }
}
