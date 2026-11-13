// SPDX-License-Identifier: GPL-3.0-only
import Foundation
precondition(SDKInstallPlan.wasCancelled("cancelled", requested: true))
precondition(!SDKInstallPlan.wasCancelled("cancelled", requested: false))
precondition(!SDKInstallPlan.wasCancelled("network error", requested: true))
precondition(SDKInstallPlan.validProgress(0.5) == 0.5)
precondition(SDKInstallPlan.validProgress(nil) == nil)
precondition(SDKInstallPlan.validProgress(.infinity) == nil)
precondition(SDKInstallPlan.validProgress(-0.1) == nil && SDKInstallPlan.validProgress(1.1) == nil)

let license = PendingLicense(id:"test-license",sha256:"test-hash",text:"Test-only licence text")
let plan = SDKInstallPlan(imagePackage:"system-images;android-35;google_apis;arm64-v8a",licenses:[license])
do { _ = try plan.consentRequests(reviewed:false); fatalError("unreviewed license accepted") } catch { }
let requests = try plan.consentRequests(reviewed:true)
precondition(requests.count == 1 && requests[0]["id"] == "test-license" && requests[0]["sha256"] == "test-hash")
precondition(plan.method == "image.install" && plan.parameters["image"] as? String == plan.imagePackage)
let tools = SDKInstallPlan(imagePackage:nil,licenses:[])
let empty = try tools.consentRequests(reviewed:false)
precondition(empty.isEmpty && tools.method == "sdk.install")
let malformed = SDKInstallPlan(imagePackage:nil,licenses:[PendingLicense(id:"test",sha256:"x",text:"")])
do { _ = try malformed.consentRequests(reviewed:true); fatalError("empty license accepted") } catch { }
precondition(OperationMessages.progress("Downloading Magisk 30.7",language:1) == "正在下载 Magisk 30.7")
precondition(OperationMessages.progress("Verifying root",language:0) == "Verifying root")
precondition(OperationMessages.notice("SDK installation complete.",language:1) == "SDK 安装完成。")
precondition(OperationMessages.notice("操作完成",language:0) == "Completed")
let notice = "Magisk GPL source: https://example.invalid/source"
precondition(OperationMessages.progress(notice,language:1) == notice)
precondition(OperationMessages.routeSpeed("0") == nil && OperationMessages.routeSpeed("65") == nil)
precondition(OperationMessages.routeSpeed("nan") == nil && OperationMessages.routeSpeed("64") == 64)
precondition(OperationMessages.error("speed must be between 0 and 64×",language:1) == "路线速度倍率须大于 0 且不超过 64。")
precondition(OperationMessages.error("no such module zip: /tmp/test.zip",language:1) == "找不到模块文件：/tmp/test.zip")
precondition(OperationMessages.error("no such module zip: /tmp/test.zip",language:0) == "no such module zip: /tmp/test.zip")
let stoppedDevice = "Test Pixel is not running; start it first"
precondition(OperationMessages.error(stoppedDevice, language: 1) == "设备“Test Pixel”未运行，请先启动设备。")
precondition(OperationMessages.error(stoppedDevice, language: 0) == stoppedDevice)
print("SDK installation plan tests passed")
