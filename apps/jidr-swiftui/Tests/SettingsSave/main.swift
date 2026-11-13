// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum TestError: Error { case device, disk }
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
let store = try WindowQualityStore(dataDirectory: directory.path, device: "00000000-0000-4000-8000-000000000001")
try store.save(1)
func savedQuality() -> UInt8 {
    do { return try store.load() }
    catch { fatalError("cannot read test quality: \(error)") }
}

// Editing a draft, then Cancel, never touches persisted quality.
let stagedQuality: UInt8 = 2
precondition(savedQuality() == 1)
var reply: ((Result<Void, Error>) -> Void)?
var completionCount = 0
DeviceSettingsSave.commit(saveDevice: { reply = $0 }, saveQuality: {
    try store.save(stagedQuality)
}, completion: { result in
    guard case .failure(.device) = result else { fatalError("hardware failure must be reported") }
    completionCount += 1
})
precondition(savedQuality() == 1, "no local write before daemon acknowledgement")
reply?(.failure(TestError.device))
precondition(savedQuality() == 1 && completionCount == 1, "daemon failure keeps staged quality uncommitted")

// No hardware changes: Save still persists quality, without a device mutation.
DeviceSettingsSave.commit(saveDevice: { $0(.success(())) }, saveQuality: {
    try store.save(stagedQuality)
}, completion: { result in
    guard case .success = result else { fatalError("quality-only save failed") }
    completionCount += 1
})
precondition(savedQuality() == 2 && completionCount == 2)

// The full asynchronous save commits quality only after device success.
reply = nil
DeviceSettingsSave.commit(saveDevice: { reply = $0 }, saveQuality: {
    try store.save(0)
}, completion: { result in
    guard case .success = result else { fatalError("full save failed") }
    completionCount += 1
})
precondition(savedQuality() == 2 && completionCount == 2)
reply?(.success(()))
precondition(savedQuality() == 0 && completionCount == 3)

var deviceCommitted = false
DeviceSettingsSave.commit(saveDevice: { done in
    deviceCommitted = true
    done(.success(()))
}, saveQuality: {
    precondition(deviceCommitted)
    throw TestError.disk
}, completion: { result in
    guard case .failure(.quality) = result else { fatalError("partial save must be distinguished") }
    completionCount += 1
})
precondition(deviceCommitted && completionCount == 4 && savedQuality() == 0)

precondition(DevicePresentation.imageTag("google_apis_ps16k") == "Google APIs · 16 KB")
precondition(DevicePresentation.imageTag("google_apis_playstore_ps16k") == "Play Store · 16 KB")
precondition(DevicePresentation.imageTag("google_apis") == "Google APIs")
precondition(DevicePresentation.imageTag("aosp_atd") == "AOSP ATD")
precondition(DevicePresentation.imageTag("vendor_new_image") == "vendor new image")
precondition(DevicePresentation.imageOrder("google_apis") < DevicePresentation.imageOrder("google_apis_ps16k"))
precondition(DevicePresentation.profile("phone-6.1-fhd") == "6.1″ · FHD+")
precondition(DevicePresentation.profile("Pixel_7") == "Pixel 7")
print("Device settings save and presentation tests passed")

var policy = DevicePolicyDraft(root: "adb", quickBoot: true, budget: "75", idleMinutes: "0")
let originalPolicy = policy
precondition(policy.parameters?["budget_percent"] as? UInt8 == 75)
policy.budget = "101"
precondition(policy.parameters == nil)
policy.budget = "75"
policy.idleMinutes = "-1"
precondition(policy.parameters == nil)
policy.idleMinutes = "1.5"
precondition(policy.parameters == nil)
policy.idleMinutes = "30"
precondition(policy != originalPolicy && policy.parameters?["auto_hibernate_minutes"] as? UInt32 == 30)
precondition(policy.parameters?["default_root_mode"] as? String == "adb")

var route = RoutePlaybackState()
precondition(!route.isRunning)
let firstRoute = route.start()
route.setPaused(true, token: firstRoute)
precondition(route.isPaused)
route.setPaused(false, token: firstRoute)
precondition(route.isRunning && !route.isPaused)
route.stop(firstRoute)
let nextRoute = route.start()
route.complete(firstRoute)
route.setPaused(true, token: firstRoute)
precondition(route.isRunning && !route.isPaused, "late replies cannot reset or pause a newer route")
route.complete(nextRoute)
precondition(!route.isRunning)

// A read is not a change; only acknowledged saves establish a new baseline.
var cameras = DeviceCameraEdits()
precondition(!cameras.hasChanges && cameras.saved == nil)
let originalCameras = DeviceCameraDraft(back: "virtualscene", front: "none")
cameras.load(originalCameras)
precondition(!cameras.hasChanges)
cameras.draft.front = "webcam0"
precondition(cameras.hasChanges)
cameras.revert()
precondition(cameras.draft == originalCameras && !cameras.hasChanges)
cameras.draft.back = "emulated"
let submittedCameras = cameras.draft
// A failed save leaves both the saved value and editable draft intact.
precondition(cameras.saved == originalCameras && cameras.hasChanges)
cameras.acknowledge(submittedCameras, submitted: submittedCameras)
precondition(!cameras.hasChanges && cameras.saved == submittedCameras)
// A late acknowledgement must not erase newer edits.
cameras.draft.front = "webcam1"
cameras.acknowledge(submittedCameras, submitted: submittedCameras)
precondition(cameras.hasChanges && cameras.draft.front == "webcam1")
print("Camera edit state regressions passed")
