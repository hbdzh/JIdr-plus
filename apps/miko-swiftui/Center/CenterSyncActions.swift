// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Foundation

extension CenterModel {
    func openSyncPanel(preselect devices: [String] = []) {
        syncPanel.present(model: self, preselect: devices)
    }

    func refreshSyncStatus() {
        call("sync.status", [:]) { [weak self] result in
            if case .success(let value) = result, let self {
                CenterSyncSession.apply(value, to: self.syncHub)
            }
        }
    }

    func startSync(leader: String, followers: [String], options: SyncOptionsModel) {
        let params: [String: Any] = [
            "leader": leader,
            "followers": followers,
            "options": [
                "adaptation": options.adaptation.rawValue,
                "sync_keyboard": options.sync_keyboard,
                "sync_text": options.sync_text,
                "sync_tool_keys": options.sync_tool_keys,
                "lock_followers": options.lock_followers,
                "jitter_ms": options.jitter_ms,
            ],
        ]
        call("sync.start", params) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                CenterSyncSession.apply(value, to: self.syncHub)
                // Ensure the leader has an open player window so input flows immediately.
                if self.players[leader] == nil {
                    self.openGame(leader)
                }
            case .failure(let error):
                self.showError(self.readable(error))
            }
        }
    }

    func stopSync() {
        call("sync.stop", [:]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.syncHub.applySession(nil)
            case .failure(let error):
                self.showError(self.readable(error))
            }
        }
    }

    func setSyncLeader(_ device: String) {
        if let currentLeader = syncHub.session?.leader,
           currentLeader != device,
           let leaderTransport = players[currentLeader]?.transport,
           leaderTransport.scriptRecording != .idle || leaderTransport.scriptPlayback != .idle {
            showError(text("主控端正在录制或回放脚本，请先停止后再切换主控。", "Stop recording or playback on the leader before switching control."))
            return
        }
        call("sync.set_leader", ["device": device]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                CenterSyncSession.apply(value, to: self.syncHub)
            case .failure(let error):
                self.showError(self.readable(error))
            }
        }
    }

    func setSyncOptions(_ options: SyncOptionsModel) {
        let params: [String: Any] = [
            "options": [
                "adaptation": options.adaptation.rawValue,
                "sync_keyboard": options.sync_keyboard,
                "sync_text": options.sync_text,
                "sync_tool_keys": options.sync_tool_keys,
                "lock_followers": options.lock_followers,
                "jitter_ms": options.jitter_ms,
            ],
        ]
        call("sync.set_options", params) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                CenterSyncSession.apply(value, to: self.syncHub)
            case .failure(let error):
                self.showError(self.readable(error))
            }
        }
    }

    func addSyncFollower(_ device: String, completion: ((Bool) -> Void)? = nil) {
        call("sync.add_follower", ["device": device]) { [weak self] result in
            guard let self else { completion?(false); return }
            switch result {
            case .success(let value):
                CenterSyncSession.apply(value, to: self.syncHub)
                completion?(true)
            case .failure(let error):
                self.showError(self.readable(error))
                completion?(false)
            }
        }
    }

    func removeSyncFollower(_ device: String) {
        call("sync.remove_follower", ["device": device]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value): CenterSyncSession.apply(value, to: self.syncHub)
            case .failure(let error): self.showError(self.readable(error))
            }
        }
    }

}
