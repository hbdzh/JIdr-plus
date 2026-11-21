// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Owns player/tool windows and per-device opening and visibility bookkeeping.
final class CenterWindowRegistry {
    private(set) var players: [String: GameWindowController] = [:]
    private var tools: [String: DeviceToolsPanelController] = [:]
    private var opening = Set<String>()
    private var background = Set<String>()
    private var pendingVisible = Set<String>()
    private var launchStates: [String: PlayerLaunchState] = [:]

    func player(_ id: String) -> GameWindowController? { players[id] }
    func setPlayer(_ player: GameWindowController, for id: String) { players[id] = player }
    func removePlayer(_ id: String) { players.removeValue(forKey: id); launchStates.removeValue(forKey: id) }
    func tool(_ id: String) -> DeviceToolsPanelController? { tools[id] }
    func setTool(_ tool: DeviceToolsPanelController, for id: String) { tools[id] = tool }
    func removeTool(_ id: String) { tools.removeValue(forKey: id) }
    func closeAllTools() {
        for controller in Array(tools.values) { controller.close() }
        tools.removeAll()
    }
    func beginOpening(_ id: String) -> Bool { opening.insert(id).inserted }
    func endOpening(_ id: String) { opening.remove(id) }
    func markBackground(_ id: String) { background.insert(id) }
    func clearBackground(_ id: String) { background.remove(id) }
    func isBackground(_ id: String) -> Bool { background.contains(id) }
    func requestVisible(_ id: String) { pendingVisible.insert(id); background.remove(id) }
    @discardableResult func consumeVisible(_ id: String) -> Bool { pendingVisible.remove(id) != nil }
    func setInitialLaunchState(_ state: PlayerLaunchState, for id: String) { launchStates[id] = state }
    /// Suppress repeated state delivery to the same open player.
    func markLaunchState(_ state: PlayerLaunchState, for id: String) -> Bool {
        guard players[id] != nil, launchStates[id] != state else { return false }
        launchStates[id] = state
        return true
    }
}
