// SPDX-License-Identifier: GPL-3.0-only
// Client-side reconnection for the center bridge. The Rust bridge connects to
// the daemon once and has no reconnect loop of its own (that is a later
// daemon-level task), so the center restarts the bridge process when it exits
// or when the daemon stops answering. This file is pure logic so it can be
// unit-tested offline; CenterModel owns the timers and the process.

import Foundation

/// What the center shows about its link to the daemon.
enum ConnectionPhase: Equatable {
    case connecting
    case online
    case reconnecting(attempt: Int)
    case disconnected

    var isOnline: Bool { self == .online }

    var attempt: Int {
        if case .reconnecting(let attempt) = self { return attempt }
        return 0
    }
}

/// Exponential backoff with a hard attempt limit: the center must show
/// "disconnected" (with a manual retry) instead of retrying forever.
struct ReconnectPolicy: Equatable {
    let maxAttempts: Int
    let initialDelay: TimeInterval
    let maxDelay: TimeInterval

    static let standard = ReconnectPolicy(maxAttempts: 6, initialDelay: 0.5, maxDelay: 8)

    init(maxAttempts: Int, initialDelay: TimeInterval, maxDelay: TimeInterval) {
        self.maxAttempts = max(1, maxAttempts)
        self.initialDelay = max(0, initialDelay)
        self.maxDelay = max(self.initialDelay, maxDelay)
    }

    /// Delay before restart attempt `attempt` (1-based): 0.5, 1, 2, 4, 8, 8…
    func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return initialDelay }
        let exponent = min(Double(attempt - 1), 20)
        return min(maxDelay, initialDelay * pow(2, exponent))
    }

    /// True when `attempt` is the last one allowed, so the next stop is final.
    func isExhausted(afterAttempt attempt: Int) -> Bool { attempt >= maxAttempts }
}

/// Detects a lost daemon from call failures: the client fails in-flight and
/// new calls as soon as the daemon socket closes, and a daemon that stops
/// answering fails two health probes in a row.
struct ConnectionHealth: Equatable {
    /// Error texts `jidr-client` produces when the daemon socket is gone or
    /// the bridge could not establish a session.
    static let lossSignatures = [
        "daemon closed the connection",
        "daemon connection lost",
        "no jidr daemon at",
        "did not answer the handshake",
        "did not start within",
    ]

    let failureThreshold: Int
    private(set) var consecutiveFailures = 0
    private(set) var isLost = false

    init(failureThreshold: Int = 2) {
        self.failureThreshold = max(1, failureThreshold)
    }

    /// True when `message` comes from a closed or unreachable daemon socket.
    static func looksDisconnected(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lossSignatures.contains { lower.contains($0) }
    }

    /// Records one failed call; true when the bridge should be restarted.
    mutating func recordFailure(_ message: String) -> Bool {
        guard !isLost else { return false }
        consecutiveFailures += 1
        if Self.looksDisconnected(message) || consecutiveFailures >= failureThreshold {
            isLost = true
            return true
        }
        return false
    }

    mutating func recordSuccess() {
        consecutiveFailures = 0
        isLost = false
    }
}

/// How often the center probes the daemon, and how long a probe may go
/// unanswered before the bridge is restarted. Death usually fails the call
/// immediately; the timeout covers a socket that accepted the request but
/// never answers (the client has no request timeout of its own).
let centerHeartbeatInterval: TimeInterval = 4
let centerHeartbeatTimeout: TimeInterval = 5
