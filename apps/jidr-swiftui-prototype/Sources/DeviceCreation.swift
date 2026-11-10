// SPDX-License-Identifier: GPL-3.0-only
import Foundation

struct DeviceCreation {
    var name: String
    var image: String
    var profile: String
    var ram: String
    var cpus: String
    var storage: String
    var root: String
    var audio: Bool

    func parameters() throws -> [String:Any] {
        let name = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, !image.isEmpty, !profile.isEmpty else { throw Validation.invalid("请填写名称并选择镜像及配置。") }
        guard let ram = Int(ram), (512...65536).contains(ram) else { throw Validation.invalid("内存必须介于 512 和 65536 MB 之间。") }
        guard let cpus = Int(cpus), (1...16).contains(cpus) else { throw Validation.invalid("CPU 核心数必须介于 1 和 16 之间。") }
        guard let storage = Int(storage), (2...256).contains(storage) else { throw Validation.invalid("设备存储必须介于 2 和 256 GB 之间。") }
        guard ["none", "adb", "magisk"].contains(root) else { throw Validation.invalid("请选择有效的 Root 模式。") }
        if root == "adb" && image.split(separator:":").dropFirst().first?.contains("playstore") == true {
            throw Validation.invalid("Play 商店镜像不支持 Shell root，请选择其他 Root 模式。")
        }
        return ["name":name,"image":image,"profile":profile,"ram_mb":ram,"cpus":cpus,
                "data_mb":storage * 1024,"root_mode":root,"audio":audio]
    }
    enum Validation: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }
}
