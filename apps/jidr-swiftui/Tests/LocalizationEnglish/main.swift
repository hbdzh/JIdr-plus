// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// M3 English-mode regression corpus. Every user-visible dynamic message that can
// reach the UI must be free of Chinese when the language preference is 0
// (English). The bridges now send stable codes plus English fallbacks; the Swift
// copy keeps the legacy Chinese diagnostics translatable for older payloads.
//
// Compile and run (test.sh wiring is the Lead's):
//   out=target/swiftui-center
//   swiftc -module-cache-path "$out/module-cache" \
//     apps/jidr-swiftui/Sources/OperationMessages.swift \
//     apps/jidr-swiftui/Sources/PlayerSession.swift \
//     apps/jidr-swiftui/Sources/WindowQuality.swift \
//     apps/jidr-swiftui/Sources/KeyMapping.swift \
//     apps/jidr-swiftui/Sources/LogFilter.swift \
//     apps/jidr-swiftui/Sources/LogStream.swift \
//     apps/jidr-swiftui/Tests/LocalizationEnglish/main.swift \
//     -o "$out/localization-english-tests"
//   "$out/localization-english-tests"

func containsChinese(_ value: String) -> Bool {
    value.unicodeScalars.contains { scalar in
        switch scalar.value {
        case 0x3000...0x303F, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xFF01...0xFF60: return true
        default: return false
        }
    }
}

func expectNoChinese(_ label: String, _ value: String) {
    precondition(!containsChinese(value), "\(label) still contains Chinese: \(value)")
}

let previewMessage = "UI preview: this operation requires a real device connection."
precondition(PlayerStatusText.translate(previewMessage, language: 0) == previewMessage)
precondition(PlayerStatusText.translate(previewMessage, language: 1) == "界面预览无法执行此操作，请连接真实设备。")
precondition(OperationMessages.error(previewMessage, language: 1) == "界面预览无法执行此操作，请连接真实设备。")

// 1. OperationMessages: daemon diagnostics are English, so language 0 passes
//    them through unchanged; the known notice pairs still get their English text.
let daemonMessages = [
    "no such module zip: /tmp/test.zip",
    "no such certificate file: /tmp/cert.pem",
    "installing the module: INSTALL_FAILED_UPDATE_INCOMPATIBLE",
    "Resolving the Magisk release",
    "Downloading Magisk 30.7",
    "Downloading system image: system-images;android-35;google_apis;arm64-v8a",
    "Verifying root",
    "The operation could not be completed. (JidrError error 3.)",
]
for message in daemonMessages {
    expectNoChinese("OperationMessages.error(\(message))", OperationMessages.error(message, language: 0))
    expectNoChinese("OperationMessages.notice(\(message))", OperationMessages.notice(message, language: 0))
    expectNoChinese("OperationMessages.progress(\(message))", OperationMessages.progress(message, language: 0))
}
precondition(OperationMessages.notice("SDK 安装完成。", language: 0) == "SDK installation complete.")
precondition(OperationMessages.notice("操作完成", language: 0) == "Completed")
precondition(!containsChinese(OperationMessages.notice("正在保存录屏…", language: 0)))
precondition(OperationMessages.error("some daemon failure", language: 0) == "some daemon failure")

// 2. PlayerDiagnosis: empty and known exits translate; unknown text passes through.
for raw in [
    "",
    "not_found: device is not running; start it first",
    "device is not running",
    "Connection refused",
    "bridge exited with status 1",
] {
    expectNoChinese("PlayerDiagnosis.describe(\(raw))", PlayerDiagnosis.describe(raw, language: 0))
}

// 3. PlayerStatusText: the legacy Chinese bridge diagnostics translate to English,
//    including the prefix forms that append the daemon's own error text.
let legacyBridgeDiagnostics = [
    "截图已保存",
    "应用已安装",
    "文件已发送到设备下载目录",
    "正在录屏",
    "录屏已保存",
    "录屏路径无效或文件已存在",
    "请选择有效的本地文件路径",
    "请选择本地文件，不支持文件夹",
    "安装失败：模拟器存储空间不足，请先释放空间。",
    "安装失败：应用签名不匹配，原应用及数据未删除。",
    "原始像素大小超出当前屏幕",
    "连接已结束，录屏状态未知；请在设备中心检查录屏。",
    "请先停止录屏并等待保存完成",
    "请先保存或取消键位编辑。",
    "键位方案无法读取，请检查原文件；未进行覆盖。",
    "请先为选中的位置绑定按键",
    "键位方案已在其他位置修改，请取消编辑后重新打开。",
    "键位方案已保存",
    "请按一个字母、数字或空格绑定",
    "请使用字母、数字或空格",
    "录屏文件已存在，请选择新文件名。",
    "正在启动录屏…",
    "正在保存录屏…",
    "Mac 剪贴板已变化，请重新复制",
    "无法打开截图目录。",
    "日志连接已结束。",
    "日志量过大，部分内容未接收。",
    "日志数据过大，连接已停止。",
]
for message in legacyBridgeDiagnostics {
    expectNoChinese("PlayerStatusText.translate(\(message))", PlayerStatusText.translate(message, language: 0))
}
for message in [
    "录屏失败：daemon unavailable",
    "停止录屏失败：timed out",
    "已绑定 K",
    "无法启动桥接：not found",
    "连接已结束（3）",
    "unknown raw diagnostic",
] {
    expectNoChinese("PlayerStatusText.translate(\(message))", PlayerStatusText.translate(message, language: 0))
}
precondition(PlayerStatusText.translate("", language: 0) == "")

// 4. Window-quality errors: English copy plus a stable code per case.
for error in WindowQualityStore.QualityError.allCases {
    expectNoChinese("QualityError.localizedDescription", error.localizedDescription)
    precondition(error.code.hasPrefix("quality."), "unexpected quality code \(error.code)")
    precondition(error.code.allSatisfy { $0.isASCII })
}

// 5. Key-mapping errors: English copy, stable NSError domain/code, and never
//    overwrite a corrupt or externally changed file.
let mappingRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("jidr-i18n-mapping-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: mappingRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: mappingRoot) }

let corruptPath = mappingRoot.appendingPathComponent("corrupt.json")
let corruptBytes = Data("{not json".utf8)
try corruptBytes.write(to: corruptPath)
let unreadable = KeyMappingStore()
unreadable.load(path: corruptPath.path)
precondition(unreadable.error != nil)
expectNoChinese("KeyMappingStore.unreadable", unreadable.error ?? "")
precondition(!unreadable.begin())
let corruptAfter = try Data(contentsOf: corruptPath)
precondition(corruptAfter == corruptBytes)

let mappingPath = mappingRoot.appendingPathComponent("device.json")
let bindable = KeyMappingStore()
bindable.load(path: mappingPath.path)
precondition(bindable.begin())
bindable.place(x: 0.5, y: 0.5, rotation: 0)
do {
    try bindable.save()
    fatalError("saved without a bound key")
} catch let error as NSError {
    expectNoChinese("KeyMappingStore.binding-required", error.localizedDescription)
    precondition(error.domain == "JidrMapping" && error.code == 1)
}
precondition(bindable.assign("A"))
try bindable.save()
precondition(bindable.begin())
bindable.place(x: 0.2, y: 0.2, rotation: 0)
precondition(bindable.assign("B"))
let externalBytes = Data("external change".utf8)
try externalBytes.write(to: mappingPath)
do {
    try bindable.save()
    fatalError("a conflicting key map was overwritten")
} catch let error as NSError {
    expectNoChinese("KeyMappingStore.conflict", error.localizedDescription)
    precondition(error.domain == "JidrMapping" && error.code == 2)
}
let externalAfter = try Data(contentsOf: mappingPath)
precondition(externalAfter == externalBytes)

// 6. Logcat stream failures: English copy and stable codes.
for diagnosis in LogStreamDiagnosis.allCases {
    expectNoChinese("LogStreamDiagnosis.message(\(diagnosis.code))", diagnosis.message)
    precondition(diagnosis.code.hasPrefix("logstream."), "unexpected code \(diagnosis.code)")
    precondition(diagnosis.code.allSatisfy { $0.isASCII })
}
let stream = LogStream()
stream.start(executable: "/nonexistent/jidr-center-bridge", device: "test-device", filters: [])
if let error = stream.error {
    expectNoChinese("LogStream.start", error)
}

print("Localization English corpus tests passed")
