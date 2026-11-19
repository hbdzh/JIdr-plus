// SPDX-License-Identifier: GPL-3.0-only

/// UI state for one route. A stopped/finished request cannot overwrite the
/// state of a newer route when its completion arrives late.
struct RoutePlaybackState {
    enum Phase { case idle, playing, paused }
    private(set) var phase: Phase = .idle
    private(set) var token = 0
    var isRunning: Bool { phase != .idle }
    var isPaused: Bool { phase == .paused }

    mutating func start() -> Int {
        token &+= 1
        phase = .playing
        return token
    }
    mutating func complete(_ token: Int) {
        guard token == self.token else { return }
        phase = .idle
    }
    mutating func setPaused(_ paused: Bool, token: Int) {
        guard token == self.token, isRunning else { return }
        phase = paused ? .paused : .playing
    }
    mutating func stop(_ token: Int) {
        guard token == self.token else { return }
        self.token &+= 1
        phase = .idle
    }
}
