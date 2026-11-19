// SPDX-License-Identifier: GPL-3.0-only
import Foundation

final class FakeClient: DeviceToolClient {
    struct Request {
        let method: String
        let params: [String: Any]
        let progress: ((String, String?, Double?) -> Void)?
        let done: (Result<Any, Error>) -> Void
    }
    var requests: [Request] = []
    func call(_ method: String, _ params: [String: Any],
              onProgress: ((String, String?, Double?) -> Void)?,
              done: @escaping (Result<Any, Error>) -> Void) {
        requests.append(Request(method: method, params: params, progress: onProgress, done: done))
    }
}
struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func policy(_ enabled: Bool = false, _ mode: String = "adb", _ api: Int = 35,
            _ adb: Bool = true, _ available: Bool = true, _ idle: Bool = true) -> Bool {
    WritableSystemPolicy.canChange(enabled: enabled, mode: mode, api: api,
        adbAllowed: adb, available: available, idle: idle)
}
precondition(policy())
precondition(!policy(false, "adb", 30))
precondition(policy(false, "adb", 31))
precondition(!policy(false, "magisk"))
precondition(!policy(false, "none"))
precondition(!policy(false, "adb", 35, false))
precondition(!policy(false, "adb", 35, true, false))
precondition(!policy(false, "adb", 35, true, true, false))
precondition(policy(true, "none", 30, false), "revert remains possible after a mode/image change")

let client = FakeClient()
let session = MicrophoneSession()
session.start(device: "one", client: client)
precondition(client.requests.isEmpty, "no file must not start a task")
session.file = URL(fileURLWithPath: "/tmp/中文 audio.wav")
session.loop = true
session.start(device: "one", client: client)
let injection = client.requests[0]
precondition(injection.method == "audio.inject")
precondition(injection.params["device"] as? String == "one")
precondition(injection.params["path"] as? String == "/tmp/中文 audio.wav")
precondition(injection.params["loop"] as? Bool == true)
session.start(device: "one", client: client)
precondition(client.requests.count == 1, "duplicate starts must be blocked")
// Stop while the WAV is still loading must cancel when the job id arrives.
session.stop(client: client)
precondition(session.active && session.stopping && client.requests.count == 1)
injection.progress?("", "job-one", 0.25)
precondition(client.requests.count == 2 && client.requests[1].method == "jobs.cancel")
precondition(client.requests[1].params["job"] as? String == "job-one")
injection.progress?("", "job-one", 0.5)
precondition(client.requests.count == 2, "repeated progress must not duplicate cancellation")
client.requests[1].done(.success([:]))
precondition(session.active, "cancel acknowledgement is not stream completion")
injection.done(.failure(Failure(message: "cancelled")))
precondition(!session.active && !session.stopping && session.finished && session.error == nil)

session.start(device: "one", client: client)
let second = client.requests[2]
injection.progress?("", "stale", 1)
injection.done(.failure(Failure(message: "stale failure")))
precondition(session.active && session.error == nil && session.progress == nil, "late callbacks cannot overwrite the next playback")
second.progress?("", "job-two", 2)
precondition(session.progress == 1)
session.stop(client: client)
client.requests[3].done(.failure(Failure(message: "daemon disconnected")))
precondition(session.active && !session.stopping && session.error != nil, "failed Stop remains retryable")
session.stop(client: client)
precondition(client.requests.count == 5)
second.done(.failure(Failure(message: "unsupported emulator")))
precondition(!session.active && session.error == "unsupported emulator", "Stop must not hide unrelated injection failures")
client.requests[4].done(.failure(Failure(message: "late stop failure")))
precondition(session.error == "unsupported emulator")

session.start(device: "one", client: client)
client.requests.last!.done(.success(["stopped": false]))
precondition(!session.active && session.finished && session.error == nil)
session.start(device: "one", client: client)
client.requests.last!.done(.failure(Failure(message: "invalid WAV")))
precondition(!session.active && session.error == "invalid WAV")
print("Device tools policy and asynchronous microphone tests passed")
