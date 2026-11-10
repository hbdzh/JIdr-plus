// SPDX-License-Identifier: GPL-3.0-only
// Unit tests for Center/Reconnect.swift (run with swiftc, like the other test
// binaries): reconnection backoff and lost-daemon detection.
import Foundation

func check(_ condition: Bool, _ message: String) {
    if !condition { fatalError("Reconnect test failed: \(message)") }
}

let policy = ReconnectPolicy.standard
check(policy.maxAttempts == 6, "standard policy has six attempts")
check(policy.delay(forAttempt: 1) == 0.5, "first delay is 0.5 s")
check(policy.delay(forAttempt: 2) == 1, "second delay doubles")
check(policy.delay(forAttempt: 3) == 2, "third delay doubles")
check(policy.delay(forAttempt: 4) == 4, "fourth delay doubles")
check(policy.delay(forAttempt: 5) == 8, "fifth delay reaches the cap")
check(policy.delay(forAttempt: 6) == 8, "the cap holds for later attempts")
check(policy.delay(forAttempt: 0) == policy.initialDelay, "attempt 0 is the initial delay")
check(policy.delay(forAttempt: -3) == policy.initialDelay, "negative attempts stay at the initial delay")
check(!policy.isExhausted(afterAttempt: 5), "attempt 5 is not the last")
check(policy.isExhausted(afterAttempt: 6), "attempt 6 is the last")
check(policy.isExhausted(afterAttempt: 99), "later attempts are exhausted")

let small = ReconnectPolicy(maxAttempts: 0, initialDelay: -1, maxDelay: 0.2)
check(small.maxAttempts == 1, "attempt limit is at least one")
check(small.delay(forAttempt: 1) == 0, "negative delay clamps to zero")
check(small.delay(forAttempt: 2) <= small.maxDelay, "delay never exceeds the cap")

// Lost-daemon detection from the client's error texts.
check(ConnectionHealth.looksDisconnected("the daemon closed the connection"), "closed connection is a loss")
check(ConnectionHealth.looksDisconnected("Daemon connection lost: broken pipe"), "casing does not matter")
check(ConnectionHealth.looksDisconnected("no Jidr daemon at /tmp/x.sock: Connection refused"), "missing daemon is a loss")
check(!ConnectionHealth.looksDisconnected("device not running"), "ordinary errors are not a loss")

var health = ConnectionHealth(failureThreshold: 2)
check(!health.recordFailure("device not running"), "first ordinary failure does not restart")
check(health.recordFailure("device not running"), "second ordinary failure restarts")
check(health.isLost, "health reports lost")
check(!health.recordFailure("device not running"), "a lost session is only reported once")
health.recordSuccess()
check(!health.isLost, "success clears the lost flag")
check(health.consecutiveFailures == 0, "success resets the counter")
check(health.recordFailure("the daemon closed the connection"), "a loss signature restarts immediately")

var single = ConnectionHealth(failureThreshold: 1)
check(single.recordFailure("timeout"), "threshold one restarts on the first failure")

print("Reconnect tests passed")
