// SPDX-License-Identifier: GPL-3.0-only
// One device center per Jidr data directory. A second launch must focus the
// running center instead of opening another window (and another bridge/daemon
// connection), so every center takes an exclusive `flock` on a lock file inside
// JIDR_HOME before it starts its bridge. The kernel drops the lock when the
// process exits, so a crashed center never leaves a stale lock behind.
//
// The second launch asks the running center to show itself with a distributed
// notification (the notification carries the JIDR_HOME path, so centers that
// use different data directories ignore each other).

import AppKit
import Darwin
import Foundation

extension Notification.Name {
    static let centerActivationRequested = Notification.Name("local.jidr.swiftui.center.activate")
}

final class CenterSingleInstance {
    static let homeKey = "home"

    /// -1 when the lock file cannot be opened (e.g. a read-only data
    /// directory): the center still runs, it just cannot enforce single-instance.
    private let descriptor: Int32
    private let path: String

    private init(descriptor: Int32, path: String) {
        self.descriptor = descriptor
        self.path = path
    }

    /// Takes the lock for `home`; nil means another center already holds it.
    static func acquire(home: String) -> CenterSingleInstance? {
        let directory = URL(fileURLWithPath: home, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(".swiftui-center.lock").path
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else {
            fputs("jidr center: cannot open \(path); single-instance is off\n", stderr)
            return CenterSingleInstance(descriptor: -1, path: path)
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            close(descriptor)
            return nil
        }
        _ = ftruncate(descriptor, 0)
        let pid = "\(getpid())\n"
        _ = pid.withCString { write(descriptor, $0, strlen($0)) }
        _ = fsync(descriptor)
        return CenterSingleInstance(descriptor: descriptor, path: path)
    }

    /// Releases the lock; the file stays for the next launch to reuse.
    func release() {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    /// Asks the running center for `home` to bring its window forward.
    static func requestActivation(home: String) {
        DistributedNotificationCenter.default().postNotificationName(
            .centerActivationRequested, object: nil,
            userInfo: [homeKey: home], deliverImmediately: true)
    }

    /// Observes activation requests for this center's data directory.
    static func observeActivation(home: String, handler: @escaping () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: .centerActivationRequested, object: nil, queue: .main
        ) { note in
            guard (note.userInfo?[homeKey] as? String) == home else { return }
            handler()
        }
    }
}
