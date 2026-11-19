// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Combine

/// Matches the existing daemon client; injectable for asynchronous UI tests.
protocol DeviceToolClient: AnyObject {
    func call(_ method: String, _ params: [String: Any],
              onProgress: ((String, String?, Double?) -> Void)?,
              done: @escaping (Result<Any, Error>) -> Void)
}

enum WritableSystemPolicy {
    /// Disabling must stay available even if the device no longer qualifies.
    static func canChange(enabled: Bool, mode: String, api: Int, adbAllowed: Bool,
                          available: Bool, idle: Bool) -> Bool {
        available && idle && (enabled || (mode == "adb" && api >= 31 && adbAllowed))
    }
}

/// Owned by the center, not the tool page: switching pages must not lose Stop.
final class MicrophoneSession: ObservableObject {
    @Published var file: URL?
    @Published var loop = false
    @Published private(set) var active = false
    @Published private(set) var stopping = false
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    @Published private(set) var finished = false
    private var token: UUID?
    private var job: String?
    private var cancelSent = false

    func start(device: String, client: DeviceToolClient) {
        guard !active, let file else { return }
        let request = UUID()
        token = request
        job = nil; cancelSent = false
        active = true; stopping = false; finished = false; error = nil; progress = nil
        client.call("audio.inject", ["device": device, "path": file.path, "loop": loop],
                    onProgress: { [weak self, weak client] _, job, fraction in
            guard let self, self.token == request else { return }
            self.job = job ?? self.job
            self.progress = fraction.map { min(1, max(0, $0)) }
            if self.stopping, let client { self.cancel(client: client, token: request) }
        }) { [weak self] result in
            guard let self, self.token == request else { return }
            self.token = nil; self.job = nil
            self.active = false; self.finished = true
            if case .failure(let failure) = result {
                let message = failure.localizedDescription
                if !(self.stopping && (message.localizedCaseInsensitiveContains("cancelled") || message.localizedCaseInsensitiveContains("canceled"))) {
                    self.error = message
                }
            }
            self.stopping = false
        }
    }

    func stop(client: DeviceToolClient) {
        guard active, !stopping, let token else { return }
        stopping = true; error = nil
        // The file may still be loading. Cancel the job rather than racing an
        // audio.stop before the microphone has been registered in the daemon.
        cancel(client: client, token: token)
    }

    private func cancel(client: DeviceToolClient, token: UUID) {
        guard let job, !cancelSent else { return }
        cancelSent = true
        client.call("jobs.cancel", ["job": job], onProgress: nil) { [weak self] result in
            guard let self, self.token == token else { return }
            if case .failure(let failure) = result {
                self.cancelSent = false; self.stopping = false
                self.error = failure.localizedDescription
            }
            // The inject completion confirms the stream has actually ended.
        }
    }
}
