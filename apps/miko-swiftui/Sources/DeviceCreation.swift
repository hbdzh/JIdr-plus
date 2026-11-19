// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Wait for both independent SDK probes before selecting the first page.
enum DeviceOnboardingRoute {
    static func useDeviceSetup(hasTools: Bool, installedImageCount: Int) -> Bool {
        hasTools && installedImageCount > 0
    }

    static func selectedImage(installed: [String], current: String, preferred: String?) -> String {
        if let preferred, installed.contains(preferred) { return preferred }
        if installed.contains(current) { return current }
        return installed.first ?? ""
    }
}

/// Decide only after both SDK and installed-image checks have returned.
struct DeviceSDKReuseCheck {
    private var hasTools: Bool?
    private var imageCount: Int?
    mutating func recordTools(_ value: Bool) { hasTools = value }
    mutating func recordImages(_ count: Int) { imageCount = count }
    var ready: Bool? {
        guard let hasTools, let imageCount else { return nil }
        return DeviceOnboardingRoute.useDeviceSetup(hasTools: hasTools, installedImageCount: imageCount)
    }
}

/// A resolution accepted by the device editor and the emulator backend.
struct DeviceResolution: Equatable {
    let width: Int
    let height: Int

    init?(width: String, height: String) {
        guard let width = Int(width.trimmingCharacters(in: .whitespacesAndNewlines)),
              let height = Int(height.trimmingCharacters(in: .whitespacesAndNewlines)),
              (240...4096).contains(width), (240...4096).contains(height) else { return nil }
        self.width = width
        self.height = height
    }
}

struct DeviceResolutionSelection {
    private(set) var saved: DeviceResolution?
    private(set) var isCustom = false
    var active: DeviceResolution? { isCustom ? saved : nil }

    mutating func apply(_ resolution: DeviceResolution) {
        saved = resolution
        isCustom = true
    }

    mutating func selectPreset() { isCustom = false }
}

/// Tracks an in-flight creation independently of the device-list refresh.
struct DeviceCreationSubmission {
    private(set) var isSaving = false
    private(set) var didCreate = false

    mutating func begin() -> Bool {
        guard !isSaving && !didCreate else { return false }
        isSaving = true
        return true
    }

    mutating func finish(succeeded: Bool) {
        isSaving = false
        if succeeded { didCreate = true }
    }
}

struct DeviceCreation {
    var name: String
    var image: String
    var profile: String
    var ram: String
    var cpus: String
    var storage: String
    var root: String
    var audio: Bool
    var resolution: DeviceResolution? = nil

    var isValid: Bool { (try? parameters()) != nil }

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
        var params: [String: Any] = ["name":name,"image":image,"profile":profile,"ram_mb":ram,"cpus":cpus,
                                     "data_mb":storage * 1024,"root_mode":root,"audio":audio]
        if let resolution {
            params["width"] = resolution.width
            params["height"] = resolution.height
        }
        return params
    }
    enum Validation: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }
}
