// SPDX-License-Identifier: GPL-3.0-only
import Foundation

precondition(DeviceOnboardingRoute.useDeviceSetup(hasTools: true, installedImageCount: 1))
precondition(DeviceOnboardingRoute.useDeviceSetup(hasTools: true, installedImageCount: 3))
precondition(!DeviceOnboardingRoute.useDeviceSetup(hasTools: false, installedImageCount: 1))
precondition(!DeviceOnboardingRoute.useDeviceSetup(hasTools: true, installedImageCount: 0))
precondition(!DeviceOnboardingRoute.useDeviceSetup(hasTools: false, installedImageCount: 0))
precondition(DeviceOnboardingRoute.selectedImage(installed: ["old", "new"], current: "old", preferred: "new") == "new")
precondition(DeviceOnboardingRoute.selectedImage(installed: ["old"], current: "old", preferred: "missing") == "old")
precondition(DeviceOnboardingRoute.selectedImage(installed: ["new"], current: "old", preferred: nil) == "new")
precondition(DeviceOnboardingRoute.selectedImage(installed: [], current: "old", preferred: "new") == "")
var sdkFirst = DeviceSDKReuseCheck()
sdkFirst.recordTools(true)
precondition(sdkFirst.ready == nil, "do not leave setup before the image check")
sdkFirst.recordImages(1)
precondition(sdkFirst.ready == true)
var imagesFirst = DeviceSDKReuseCheck()
imagesFirst.recordImages(1)
precondition(imagesFirst.ready == nil, "do not leave setup before the SDK check")
imagesFirst.recordTools(false)
precondition(imagesFirst.ready == false)
var noImages = DeviceSDKReuseCheck()
noImages.recordTools(true); noImages.recordImages(0)
precondition(noImages.ready == false, "a reusable SDK without images still requires preparation")

var form = DeviceCreation(name:" 测试设备 ",image:"35:google_apis:arm64-v8a",profile:"agent-lean",ram:"2048",cpus:"2",storage:"8",root:"adb",audio:false)
let params = try form.parameters()
precondition(params["name"] as? String == "测试设备")
precondition(params["data_mb"] as? Int == 8192)
precondition(params["width"] == nil && params["height"] == nil, "presets retain their profile resolution")
let customResolution = DeviceResolution(width: " 1440 ", height: "3120")!
form.resolution = customResolution
let customParams = try form.parameters()
precondition(customParams["width"] as? Int == 1440 && customParams["height"] as? Int == 3120)
precondition(customParams["profile"] as? String == "agent-lean", "custom resolution preserves the base profile")
form.resolution = nil
let restoredParams = try form.parameters()
precondition(restoredParams["width"] == nil && restoredParams["height"] == nil,
             "returning to a preset removes custom dimensions")
precondition(DeviceResolution(width: "240", height: "4096") != nil)
precondition(DeviceResolution(width: "239", height: "1920") == nil)
precondition(DeviceResolution(width: "1080", height: "4097") == nil)
precondition(DeviceResolution(width: "1.5", height: "1920") == nil)
precondition(DeviceResolution(width: "", height: "1920") == nil)
var selection = DeviceResolutionSelection()
precondition(selection.active == nil && !selection.isCustom)
selection.apply(customResolution)
precondition(selection.active == customResolution && selection.isCustom)
selection.selectPreset()
precondition(selection.active == nil && selection.saved == customResolution && !selection.isCustom,
             "preset selection removes overrides while preserving the last custom values")
selection.apply(customResolution)
precondition(selection.active == customResolution, "custom dimensions can be selected again")
form.storage = "257"
do { _ = try form.parameters(); fatalError("invalid storage accepted") } catch { }
form.storage = "8"; form.cpus = "0"
do { _ = try form.parameters(); fatalError("invalid CPU accepted") } catch { }
form.cpus = "2"; form.image = "35:google_apis_playstore:arm64-v8a"
do { _ = try form.parameters(); fatalError("unsupported root accepted") } catch { }
print("Device creation tests passed")

let invalidDraft = DeviceCreation(name: "  ", image: "system-images;android-35;google_apis;arm64-v8a", profile: "pixel_7", ram: "4096", cpus: "4", storage: "6", root: "none", audio: true)
precondition(!invalidDraft.isValid, "empty names never enable Create")
var validDraft = invalidDraft
validDraft.name = "A device"
precondition(validDraft.isValid)
validDraft.ram = "not a number"
precondition(!validDraft.isValid, "invalid hardware never enables Create")

var submission = DeviceCreationSubmission()
precondition(submission.begin(), "first creation can start")
precondition(!submission.begin(), "a second request cannot start while creation is in flight")
submission.finish(succeeded: false)
precondition(submission.begin(), "a failed creation can be retried")
submission.finish(succeeded: true)
precondition(submission.didCreate && !submission.isSaving)
precondition(!submission.begin(), "a successful creation cannot be submitted again while the device list refreshes")
