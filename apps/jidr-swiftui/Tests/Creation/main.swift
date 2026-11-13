// SPDX-License-Identifier: GPL-3.0-only
import Foundation

var form = DeviceCreation(name:" 测试设备 ",image:"35:google_apis:arm64-v8a",profile:"agent-lean",ram:"2048",cpus:"2",storage:"8",root:"adb",audio:false)
let params = try form.parameters()
precondition(params["name"] as? String == "测试设备")
precondition(params["data_mb"] as? Int == 8192)
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
