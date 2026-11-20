// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

/// Serial, bounded writes keep a slow bridge from blocking the UI thread.
/// Each instance belongs to one bridge session and never writes to a successor.
final class CenterRequestWriter {
    private let queue = DispatchQueue(label: "local.miko.center.writer", qos: .userInitiated)
    private let lock = NSLock()
    private let write: (Data) throws -> Void
    private let close: () -> Void
    private let maxBytes: Int
    private let maxRequests: Int
    private var active = true
    private var pending: [Int: Int] = [:]
    private var started = Set<Int>()
    private var pendingBytes = 0

    init(handle: FileHandle, maxBytes: Int = 2 * 1024 * 1024, maxRequests: Int = 1024) throws {
        guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        self.write = { try handle.write(contentsOf: $0) }
        self.close = { try? handle.close() }
        self.maxBytes = maxBytes
        self.maxRequests = maxRequests
    }

    // Injection supports deterministic backpressure and failure tests.
    init(maxBytes: Int, maxRequests: Int, write: @escaping (Data) throws -> Void, close: @escaping () -> Void = {}) {
        self.write = write; self.close = close
        self.maxBytes = maxBytes; self.maxRequests = maxRequests
    }

    /// Returns false without enqueuing if closed or at capacity.
    func send(id: Int, data: Data, onFailure: @escaping (Error) -> Void) -> Bool {
        lock.lock()
        guard active, pending[id] == nil, pending.count < maxRequests,
              data.count <= maxBytes - pendingBytes else { lock.unlock(); return false }
        pending[id] = data.count
        pendingBytes += data.count
        queue.async { [self] in
            lock.lock()
            guard active, pending[id] != nil else { lock.unlock(); return }
            started.insert(id)
            lock.unlock()
            do { try write(data) }
            catch { stop(); onFailure(error) }
            lock.lock()
            started.remove(id)
            if let size = pending.removeValue(forKey: id) { pendingBytes -= size }
            lock.unlock()
        }
        lock.unlock()
        return true
    }

    /// A timed-out request is discarded if writing has not started.
    func cancel(id: Int) {
        lock.lock(); defer { lock.unlock() }
        guard !started.contains(id), let size = pending.removeValue(forKey: id) else { return }
        pendingBytes -= size
    }

    /// Discards unsent work; an in-progress write finishes only on the old pipe.
    func stop() {
        lock.lock()
        guard active else { lock.unlock(); return }
        active = false
        lock.unlock()
        queue.async { [self] in close() }
    }
}
