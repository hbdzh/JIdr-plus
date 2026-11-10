// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers

// Shared navigation treatment for settings and tool categories.
struct JidrNavigationItem: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: WbSpace.md) {
                Image(systemName: symbol).frame(width: 16).accessibilityHidden(true)
                Text(title).lineLimit(1)
            }
                .wbFont(WbType.body.weighted(selected ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, WbSpace.md).padding(.vertical, WbSpace.sm)
                .background(selected ? WbColor.selected : Color.clear,
                            in: RoundedRectangle(cornerRadius: WbRadius.sm))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

/// A path and its related controls stay together, including for long paths.
struct PathSetting<Actions: View>: View {
    let title: String
    let path: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: WbSpace.sm) {
            Text(title).wbFont(WbType.body.weighted(.medium))
            Text(path).wbFont(WbType.body).foregroundStyle(WbColor.textSecondary)
                .lineLimit(1).truncationMode(.middle).help(path).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: WbSpace.sm, content: actions)
        }.padding(.vertical, WbSpace.xs)
    }
}

struct DeviceArt: View {
    let name: String
    let width: CGFloat
    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource:name, withExtension:"png"), let image = NSImage(contentsOf:url) {
                Image(nsImage:image).resizable().scaledToFit().frame(width:width)
            }
        }.accessibilityHidden(true)
    }
}

struct DeviceDetailsView: View {
    @ObservedObject var model: CenterModel
    let details: Details
    @Environment(\.dismiss) private var dismiss
    @State private var confirmRevert = false
    @State private var selectedRoot = "none"
    @State private var confirmRootChange = false
    @State private var confirmRootSetup = false
    private var rootModeText: String {
        switch details.device.root.mode {
        case "none": return model.text("无", "None")
        case "adb": return "Shell root"
        case "magisk": return model.text("完整 Root", "Full root")
        default: return details.device.root.mode
        }
    }
    private var rootHealthText: String {
        switch details.device.root.health {
        case "ok": return model.text("已验证", "Verified")
        case "failed": return model.text("验证失败", "Verification failed")
        case "unverified": return model.text("尚未验证", "Not verified")
        default: return details.device.root.health ?? "—"
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:WbSpace.lg) {
            HStack(alignment:.top) {
                VStack(alignment:.leading,spacing:WbSpace.xs) {
                    Text("设备详情").wbFont(WbType.headline)
                    Text(details.device.name).wbFont(WbType.body).foregroundStyle(WbColor.textSecondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength:12)
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Form {
                Section(model.text("设备概览", "Overview")) {
                    LabeledContent(model.text("状态", "Status"), value:details.device.statusText(language:model.language))
                    if let holder = model.busyHolder(for: details.device.id) {
                        LabeledContent(model.text("占用", "Busy"), value:holder)
                    }
                    LabeledContent(model.text("设备 ID", "Device ID")) {
                        HStack {
                            Text(details.device.id).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(details.device.id,forType:.string) } label: { Image(systemName:WbIcon.copy) }
                                .buttonStyle(.borderless)
                                .help(model.text("复制设备 ID", "Copy device ID"))
                                .accessibilityLabel(model.text("复制设备 ID", "Copy device ID"))
                        }
                    }
                }
                Section("Android") {
                    LabeledContent("版本",value:details.device.androidVersion)
                    LabeledContent("镜像",value:details.device.imageLabel)
                    LabeledContent("配置",value:details.device.profile)
                    LabeledContent("序列号",value:details.device.runtime?.adb_serial ?? "—")
                    LabeledContent("SDK") {
                        Text(details.device.sdk_root).lineLimit(1).truncationMode(.middle)
                            .help(details.device.sdk_root).textSelection(.enabled)
                    }
                }
                Section(model.text("会话", "Session")) {
                    LabeledContent(model.text("运行时长", "Uptime"), value:model.sessionUptime(details.device) ?? "—")
                    LabeledContent(model.text("上次启动", "Last started"), value:model.sessionStarted(details.device) ?? "—")
                    LabeledContent(model.text("控制台端口", "Console port"), value:details.device.runtime?.console_port.map(String.init) ?? "—")
                    LabeledContent(model.text("gRPC 端口", "gRPC port"), value:details.device.runtime?.grpc_port.map(String.init) ?? "—")
                    LabeledContent(model.text("进程 ID", "Process ID"), value:details.device.runtime?.pid.map(String.init) ?? "—")
                }
                Section("硬件") {
                    LabeledContent("内存",value:"\(details.config["hw.ramSize"] ?? "—") MB")
                    LabeledContent("CPU",value:"\(details.config["hw.cpu.ncore"] ?? "—")")
                    LabeledContent("屏幕",value:"\(details.config["hw.lcd.width"] ?? "—") × \(details.config["hw.lcd.height"] ?? "—")")
                    if let bytes = details.disk_usage { LabeledContent("磁盘占用",value:ByteCountFormatter.string(fromByteCount:Int64(clamping:bytes),countStyle:.file)) }
                }
                Section("Root 状态") {
                    Button("Root 高级工具…") { model.openAdvanced(details.device.id, name:details.device.name, root:true) }.disabled(!details.device.running)
                    LabeledContent("模式",value:rootModeText)
                    if let magisk = details.device.root.magisk_version, !magisk.isEmpty {
                        LabeledContent("Magisk", value:magisk)
                    }
                    LabeledContent("验证",value:rootHealthText)
                    Picker("更改 Root 模式",selection:$selectedRoot) {
                        Text("无").tag("none"); Text("Shell root").tag("adb"); Text("完整 root").tag("magisk")
                    }.disabled(!details.device.stopped)
                    Button("更改 Root 模式…") { confirmRootChange = true }
                        .disabled(!details.device.stopped || selectedRoot == details.device.root.mode)
                    if !details.device.stopped { Text("请先停止设备，再更改 Root 模式。").wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary) }
                    if details.device.root.mode == "magisk" {
                        Button("设置或重试完整 Root…") { confirmRootSetup = true }.disabled(model.busy.contains(details.device.id))
                    }
                    HStack {
                        Button("再次验证") { model.operation("root.verify",id:details.device.id) }.disabled(!details.device.running)
                        Button("恢复为无 Root",role:.destructive) { confirmRevert = true }.disabled(!details.device.stopped || details.device.root.mode == "none")
                    }
                }
            }.formStyle(.grouped)
        }.padding(WbSpace.xl).frame(width:620,height:560)
        .onAppear { selectedRoot = details.device.root.mode }
        .alert("更改 Root 模式？",isPresented:$confirmRootChange) {
            Button("取消",role:.cancel) { }
            Button("更改") {
                if selectedRoot == "magisk" {
                    dismiss(); DispatchQueue.main.async { model.setupFullRoot(details.device.id,name:details.device.name) }
                } else { model.operation("root.set",id:details.device.id,params:["mode":selectedRoot]); dismiss() }
            }
        } message: { Text("更改 Root 模式可能需要冷启动，也可能影响快照恢复。请先保存游戏进度。") }
        .alert("设置完整 Root？",isPresented:$confirmRootSetup) {
            Button("取消",role:.cancel) { }
            Button("继续") { dismiss(); DispatchQueue.main.async { model.setupFullRoot(details.device.id,name:details.device.name) } }
        } message: { Text("将下载并配置 Magisk，设备可能重启。Play 商店镜像可能需要在设备窗口手动授权。请先保存游戏进度。") }
        .alert("恢复为无 Root？",isPresented:$confirmRevert) {
            Button("取消",role:.cancel) { }
            Button("恢复",role:.destructive) { model.operation("root.set",id:details.device.id,params:["mode":"none"]); dismiss() }
        } message: { Text("这将更改设备的 Root 模式，并可能要求冷启动。请先保存游戏进度。") }
    }
}

struct EditDeviceView: View {
    @ObservedObject var model: CenterModel
    let details: Details
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var ram: String
    @State private var cores: String
    @State private var width: String
    @State private var height: String
    @State private var density: String
    @State private var resolutionPreset: String
    @State private var audio: Bool
    @State private var quickBoot: String
    @State private var cameraBack: String
    @State private var cameraFront: String
    @State private var sleepMinutes: String
    @State private var error = ""
    @State private var saving = false
    @State private var confirmColdBoot = false
    @State private var quality = 1
    @State private var qualityLoaded = false
    @State private var qualityMessage = ""
    private let resolutionPresets = [("720×1280", "720", "1280"), ("1080×1920", "1080", "1920"), ("1080×2400", "1080", "2400"), ("1280×720", "1280", "720"), ("1920×1080", "1920", "1080")]
    init(model: CenterModel, details: Details) {
        self.model = model; self.details = details
        _name = State(initialValue:details.device.name)
        _ram = State(initialValue:details.config["hw.ramSize"] ?? "")
        _cores = State(initialValue:details.config["hw.cpu.ncore"] ?? "")
        _width = State(initialValue:details.config["hw.lcd.width"] ?? "")
        _height = State(initialValue:details.config["hw.lcd.height"] ?? "")
        _density = State(initialValue:details.config["hw.lcd.density"] ?? "")
        let resolution = "\(details.config["hw.lcd.width"] ?? "")×\(details.config["hw.lcd.height"] ?? "")"
        _resolutionPreset = State(initialValue:["720×1280", "1080×1920", "1080×2400", "1280×720", "1920×1080"].contains(resolution) ? resolution : "custom")
        _audio = State(initialValue:details.device.launch.audio ?? true)
        _quickBoot = State(initialValue:details.device.launch.quick_boot.map { $0 ? "on" : "off" } ?? "global")
        _cameraBack = State(initialValue:details.device.launch.camera_back ?? "default")
        _cameraFront = State(initialValue:details.device.launch.camera_front ?? "default")
        _sleepMinutes = State(initialValue:details.device.auto_hibernate_minutes.map(String.init) ?? "")
    }
    var body: some View {
        VStack(alignment:.leading,spacing:WbSpace.lg) {
            Text("设备设置").wbFont(WbType.headline)
            Text(details.device.name).wbFont(WbType.body).foregroundStyle(WbColor.textSecondary).lineLimit(1)
            Label(details.device.running ? model.text("设备运行中，停止后才能修改硬件和启动设置。", "Stop the running device to change hardware and startup settings.") : model.text("更改屏幕设置会冷启动；原快速启动快照由后台备份。", "Display changes require a cold boot; the quick-boot snapshot is backed up."), systemImage:WbIcon.info)
                .foregroundStyle(WbColor.textSecondary).wbFont(WbType.body)
            Form {
                Section(model.text("硬件", "Hardware")) {
                TextField("名称",text:$name)
                TextField("内存（MB）",text:$ram)
                TextField("CPU 核心数",text:$cores)
                Picker("分辨率预设",selection:Binding(get: { resolutionPreset },set: { selection in
                    resolutionPreset = selection
                    if let preset = resolutionPresets.first(where: { $0.0 == selection }) { width = preset.1; height = preset.2 }
                })) {
                    Text("自定义").tag("custom")
                    ForEach(resolutionPresets, id: \.0) { preset in Text(preset.0).tag(preset.0) }
                }
                if resolutionPreset == "custom" {
                    TextField("屏幕宽度（px）",text:$width)
                    TextField("屏幕高度（px）",text:$height)
                }
                TextField("屏幕密度（dpi）",text:$density)
                }.disabled(!details.device.stopped)
                Section(model.text("启动与外设", "Startup & peripherals")) {
                Picker("快速启动",selection:$quickBoot) { Text("跟随全局").tag("global"); Text("开启").tag("on"); Text("停用").tag("off") }
                LabeledContent(model.text("自动休眠", "Auto sleep")) {
                    TextField(model.text("默认", "Default"),text:$sleepMinutes)
                        .multilineTextAlignment(.trailing).frame(maxWidth:120)
                }
                Text(model.text("单位为分钟；留空跟随全局，0 为关闭。", "Minutes; leave blank for the global setting, or use 0 to turn off."))
                    .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                Picker("后置摄像头",selection:$cameraBack) { Text("默认").tag("default"); Text("禁用").tag("none"); Text("模拟").tag("emulated"); Text("虚拟场景").tag("virtualscene"); Text("Mac 摄像头 1").tag("webcam0"); Text("Mac 摄像头 2").tag("webcam1") }
                Picker("前置摄像头",selection:$cameraFront) { Text("默认").tag("default"); Text("禁用").tag("none"); Text("模拟").tag("emulated"); Text("Mac 摄像头 1").tag("webcam0"); Text("Mac 摄像头 2").tag("webcam1") }
                }.disabled(!details.device.stopped)
                Section(model.text("声音与画面", "Audio & display")) {
            Toggle("设备声音（下次启动生效）",isOn:$audio)
            HStack {
                Picker("游戏窗口画质",selection:$quality) {
                    Text("流畅").tag(0); Text("清晰").tag(1); Text("节能").tag(2)
                }.disabled(!qualityLoaded)
                Button("保存画质") {
                    do {
                        guard let path = model.dataDirectory else { return }
                        try WindowQualityStore(dataDirectory:path,device:details.device.id).save(UInt8(quality))
                        qualityMessage = model.text("画质已保存，下次打开窗口生效。", "Quality saved; it applies next time the window opens.")
                    } catch { qualityMessage = error.localizedDescription }
                }.disabled(!qualityLoaded)
            }
            Text("只改变画面传输分辨率，不改变游戏帧率。") .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
            if !qualityMessage.isEmpty { Text(qualityMessage).wbFont(WbType.caption) }
                }
            }.formStyle(.grouped)
            Button("冷启动一次…") { confirmColdBoot = true }.disabled(!details.device.stopped || saving)
            if !error.isEmpty { Text(error).foregroundStyle(WbColor.negative) }
            HStack { Spacer(); Button("取消") { dismiss() }.disabled(saving).keyboardShortcut(.cancelAction); Button("保存") {
                let trimmed = name.trimmingCharacters(in:.whitespacesAndNewlines)
                guard !trimmed.isEmpty, let r = Int(ram), (512...65536).contains(r), let c = Int(cores), (1...16).contains(c), let w = Int(width), (240...4096).contains(w), let h = Int(height), (240...4096).contains(h), let dpi = Int(density), (72...1000).contains(dpi) else { error = model.text("请检查名称、内存、CPU、分辨率和 DPI。", "Check the name, memory, CPU, resolution and DPI."); return }
                var values: [String:Any] = [:]
                if trimmed != details.device.name { values["name"] = trimmed }
                for (key,value,old) in [("ram_mb",r,details.config["hw.ramSize"]),("cpus",c,details.config["hw.cpu.ncore"]),("width",w,details.config["hw.lcd.width"]),("height",h,details.config["hw.lcd.height"]),("density",dpi,details.config["hw.lcd.density"])] {
                    if String(value) != old { values[key] = value }
                }
                if audio != (details.device.launch.audio ?? true) { values["audio"] = audio }
                if details.device.stopped {
                    let oldQuick = details.device.launch.quick_boot.map { $0 ? "on" : "off" } ?? "global"
                    if quickBoot != oldQuick { values["quick_boot"] = quickBoot == "global" ? NSNull() : (quickBoot == "on") as Any }
                    if cameraBack != (details.device.launch.camera_back ?? "default") { values["camera_back"] = cameraBack }
                    if cameraFront != (details.device.launch.camera_front ?? "default") { values["camera_front"] = cameraFront }
                    if sleepMinutes != (details.device.auto_hibernate_minutes.map(String.init) ?? "") {
                        if sleepMinutes.isEmpty { values["auto_hibernate_minutes"] = NSNull() }
                        else if let minutes = Int(sleepMinutes), (0...1440).contains(minutes) { values["auto_hibernate_minutes"] = minutes }
                        else { error = model.text("自动休眠时间必须介于 0 到 1440 分钟。", "Idle sleep must be between 0 and 1440 minutes."); return }
                    }
                }
                if !details.device.stopped { values = values.filter { $0.key == "audio" } }
                guard !values.isEmpty else { dismiss(); return }
                values["device"] = details.device.id
                saving = true
                model.call("device.edit",values) { result in
                    saving = false
                    switch result {
                    case .success: model.refresh(); if model.selected == details.device.id { model.load(details.device.id) }; dismiss()
                    case .failure(let failure): error = failure.localizedDescription
                    }
                }
            }.buttonStyle(.borderedProminent).disabled(saving).keyboardShortcut(.defaultAction) }
        }.padding(WbSpace.xl).frame(width:560,height:560)
        .onAppear {
            do {
                guard let path = model.dataDirectory else { qualityMessage = model.text("无法读取数据目录", "Cannot read the data directory"); return }
                quality = Int(try WindowQualityStore(dataDirectory:path,device:details.device.id).load())
                qualityLoaded = true
            } catch { qualityMessage = error.localizedDescription }
        }
        .alert("冷启动设备？",isPresented:$confirmColdBoot) {
            Button("取消",role:.cancel) { }
            Button("冷启动") { model.start(details.device.id,coldBoot:true); dismiss() }
        } message: { Text("本次启动将跳过快速启动快照，未保存的设置不会应用。") }
    }
}

struct HardwareProfile: Decodable, Identifiable {
    let id: String; let name: String
    let ram_mb: Int; let cpus: Int; let data_mb: Int; let audio: Bool
}
struct AvailableImage: Decodable, Identifiable {
    let api: Int; let tag: String; let abi: String; let installed_in: String?
    var id: String { "\(api):\(tag):\(abi)" }
    var package: String { "system-images;android-\(api);\(tag);\(abi)" }
}
struct InstallSDKView: View {
    @ObservedObject var model: CenterModel
    @Environment(\.dismiss) private var dismiss
    @State private var images: [AvailableImage] = []
    @State private var selection = ""
    @State private var licenses: [PendingLicense] = []
    @State private var reviewed = false
    @State private var loading = false
    @State private var loadingImages = false
    @State private var imageError = ""
    @State private var sdkStatusError = ""
    @State private var loadingMessage = ""
    @State private var showingLicenses = false
    @State private var showingInstallStatus = false
    @State private var error = ""
    @State private var plan: SDKInstallPlan?
    @State private var sdkStatus: SDKStatus?

    private var package: String? { images.first(where: { $0.id == selection })?.package }
    private var packages: [String] { ["emulator", "platform-tools"] + (package.map { [$0] } ?? []) }

    private func loadSDKStatus() {
        sdkStatusError = ""
        model.call("sdk.status") { result in
            do { sdkStatus = try model.decode(result.get(),as:SDKStatus.self) }
            catch { sdkStatusError = model.text("无法检查 SDK 状态，请重试。", "Unable to check SDK status. Try again.") + "\n" + error.localizedDescription }
        }
    }
    private func loadAvailableImages() {
        guard !loadingImages else { return }
        loadingImages = true; imageError = ""
        model.call("image.list", ["available":true]) { result in
            loadingImages = false
            do {
                images = try model.decode(result.get(),as:[AvailableImage].self)
                if !selection.isEmpty && !images.contains(where: { $0.id == selection && $0.installed_in == nil }) { selection = "" }
            }
            catch { imageError = model.text("无法读取 SDK 镜像列表，请检查网络后重试。", "Unable to load SDK images. Check your connection and retry.") + "\n" + error.localizedDescription }
        }
    }
    private func retrySetup() {
        showingInstallStatus = false; showingLicenses = false; reviewed = false
        error = ""; plan = nil
        loadSDKStatus(); loadAvailableImages()
    }

    private func chooseExistingSDK() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loading = true; error = ""; loadingMessage = model.text("正在检查 SDK…", "Checking SDK…")
        model.call("center.toolpath.set",["kind":"sdk","path":url.path]) { result in
            loading = false
            switch result {
            case .success: model.refresh(); dismiss()
            case .failure(let failure): error = model.text("无法使用该 SDK，请确认目录包含 emulator 和 platform-tools。", "Cannot use this SDK. Check that it contains emulator and platform-tools.") + "\n" + failure.localizedDescription
            }
        }
    }

    private func prepare() {
        loading = true; error = ""; loadingMessage = model.text("正在读取许可…", "Loading licences…")
        model.call("sdk.licenses", ["packages":packages]) { result in
            loading = false
            do {
                let found = try model.decode(result.get(), as:[PendingLicense].self)
                licenses = found; plan = SDKInstallPlan(imagePackage:package,licenses:found)
                reviewed = false; showingLicenses = true
            }
            catch { self.error = model.text("无法读取 SDK 许可，请检查网络后重试。", "Unable to load SDK licences. Check your connection and retry.") + "\n" + error.localizedDescription }
        }
    }
    private func accept(_ index: Int) {
        guard let plan else { loading = false; return }
        let requests: [[String:String]]
        do { requests = try plan.consentRequests(reviewed:reviewed) }
        catch { loading = false; self.error = model.text("请阅读并同意许可协议。", "Review and agree to the licences first."); return }
        if index == requests.count {
            showingInstallStatus = true; loading = false
            model.startSDKInstall(plan)
            return
        }
        model.call("sdk.accept_license", requests[index]) { result in
            switch result {
            case .success: accept(index + 1)
            case .failure(let failure): loading = false; error = model.text("无法记录许可确认，请重新检查许可后重试。", "Unable to record licence consent. Review the licences and retry.") + "\n" + failure.localizedDescription
            }
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:WbSpace.lg) {
            Text("安装 Android SDK 和系统镜像").wbFont(WbType.headline)
            if showingInstallStatus {
                if model.sdkInstalling {
                    if let fraction = model.sdkInstallFraction {
                        ProgressView(value:fraction) { Text(model.sdkInstallMessage) }
                        Text(model.text("当前步骤 \(Int(fraction * 100))%", "Current step \(Int(fraction * 100))%"))
                            .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                    } else { ProgressView(model.sdkInstallMessage) }
                    Text(model.text("安装可以在后台继续；退出前请等待安装或取消完成。", "Installation can continue in the background. Wait for installation or cancellation before quitting."))
                        .wbFont(WbType.body).foregroundStyle(WbColor.textSecondary)
                } else {
                    Text(model.sdkInstallMessage).wbFont(WbType.body)
                }
                if let installError = model.sdkInstallError { Text(installError).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary).textSelection(.enabled) }
            } else if showingLicenses {
                if licenses.isEmpty { Text("所选组件没有需要接受的新许可。") }
                else {
                    ScrollView { VStack(alignment:.leading,spacing:WbSpace.md) { ForEach(licenses) { license in
                        Text(license.id).wbFont(WbType.title)
                        Text(license.text).textSelection(.enabled)
                    } }.frame(maxWidth:.infinity,alignment:.leading) }.frame(height:280)
                    Toggle("我已阅读并同意上述许可协议",isOn:$reviewed)
                }
            } else {
                Text("选择要安装的系统镜像；也可以只安装模拟器工具。")
                if !sdkStatusError.isEmpty {
                    Text(sdkStatusError).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary).textSelection(.enabled)
                    Button(model.text("重新检查 SDK", "Retry SDK check"),action:loadSDKStatus)
                }
                if let existing = sdkStatus?.tools_sdk {
                    VStack(alignment:.leading,spacing:WbSpace.sm) {
                        Label(model.text("已检测到可用的 Android SDK", "Android SDK detected"),systemImage:WbIcon.checkCircle)
                            .foregroundStyle(WbColor.textSecondary)
                        Text(existing).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                            .lineLimit(1).truncationMode(.middle).help(existing).textSelection(.enabled)
                        Button(model.text("使用检测到的 SDK", "Use detected SDK")) { dismiss() }.disabled(loading)
                    }
                }
                if let location = sdkStatus?.private_sdk {
                    Text(model.text("下载位置：\(location)", "Download location: \(location)"))
                        .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary).textSelection(.enabled)
                }
                Button("使用已有 SDK…") { chooseExistingSDK() }.disabled(loading)
                Picker("系统镜像",selection:$selection) {
                    Text("仅安装模拟器工具").tag("")
                    ForEach(images.filter { $0.installed_in == nil }) { image in
                        Text("Android API \(image.api) · \(image.tag) · \(image.abi)").tag(image.id)
                    }
                }
                if loadingImages {
                    ProgressView(model.text("正在读取镜像列表…", "Loading system images…")).controlSize(.small)
                } else if !imageError.isEmpty {
                    Text(imageError).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary).textSelection(.enabled)
                    Button(model.text("重新读取镜像", "Retry images"),action:loadAvailableImages)
                } else if images.allSatisfy({ $0.installed_in != nil }) {
                    Text("未找到可下载的镜像；请检查网络，或使用已有 SDK。") .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                    Button(model.text("重新读取镜像", "Retry images"),action:loadAvailableImages)
                }
            }
            if loading { ProgressView(loadingMessage) }
            if !error.isEmpty { Text(error).foregroundStyle(WbColor.negative).textSelection(.enabled) }
            HStack { Spacer()
                if showingInstallStatus {
                    if model.sdkInstalling {
                        Button(model.sdkCancelPending ? model.text("正在取消…", "Cancelling…") : model.text("取消安装", "Cancel installation")) { model.cancelSDKInstall() }
                            .disabled(model.sdkInstallJob == nil || model.sdkCancelPending)
                        Button(model.text("后台运行", "Run in background")) { dismiss() }.keyboardShortcut(.cancelAction)
                    } else {
                        if model.sdkInstallSucceeded == false { Button(model.text("重新选择并重试", "Choose and retry"),action:retrySetup) }
                        Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                } else {
                Button("取消") { dismiss() }.disabled(loading).keyboardShortcut(.cancelAction)
                if showingLicenses {
                    Button(licenses.isEmpty ? "安装" : "同意并安装") { loading = true; error = ""; loadingMessage = model.text("正在确认许可…", "Confirming licences…"); accept(0) }
                        .disabled(loading || (!licenses.isEmpty && !reviewed))
                        .keyboardShortcut(.defaultAction)
                } else { Button("继续") { prepare() }.disabled(loading).keyboardShortcut(.defaultAction) }
                }
            }
        }.padding(WbSpace.xl).frame(width:650)
        .onAppear {
            if model.sdkInstalling { showingInstallStatus = true; return }
            loadSDKStatus(); loadAvailableImages()
        }
        .interactiveDismissDisabled(loading)
    }
}
struct NewDeviceView: View {
    @ObservedObject var model: CenterModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var profiles: [HardwareProfile] = []
    @State private var images: [AvailableImage] = []
    @State private var profile = ""
    @State private var image = ""
    @State private var ram = "4096"
    @State private var cpus = "4"
    @State private var storage = "6"
    @State private var root = "none"
    @State private var audio = true
    @State private var error = ""
    @State private var saving = false
    @State private var installing = false
    @State private var showAdvanced = false
    func applyProfile(_ id:String) {
        guard let value = profiles.first(where: { $0.id == id }) else { return }
        ram = String(value.ram_mb); cpus = String(value.cpus)
        storage = String(max(2, value.data_mb / 1024)); audio = value.audio
    }
    func loadImages() {
        model.call("image.list",["available":false]) { result in
            do { images = try model.decode(result.get(),as:[AvailableImage].self).filter { $0.installed_in != nil }; image = images.first?.id ?? "" }
            catch { self.error = error.localizedDescription }
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:WbSpace.lg) {
            Text("添加设备").wbFont(WbType.headline)
            Text("选择已经安装的系统镜像和硬件配置。").foregroundStyle(WbColor.textSecondary)
            Form {
                Section("基础配置") {
                TextField("设备名称",text:$name)
                Picker("系统镜像",selection:$image) { Text("请选择").tag(""); ForEach(images) { Text("Android API \($0.api) · \($0.tag)").tag($0.id) } }
                Picker("硬件配置",selection:$profile) { Text("请选择").tag(""); ForEach(profiles) { Text($0.name).tag($0.id) } }
                    .onChange(of:profile) { _, value in applyProfile(value) }
                Picker("Root 模式",selection:$root) { Text("无").tag("none"); Text("Shell root").tag("adb"); Text("完整 root").tag("magisk") }
                if root == "magisk" { Text("创建后将下载并配置 Magisk，期间设备会启动并重启。").wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary) }
                }
                Section {
                    Button { showAdvanced.toggle() } label: {
                        Label(model.text("高级配置", "Advanced configuration"), systemImage:showAdvanced ? WbIcon.chevronDown : WbIcon.chevronRight)
                    }.buttonStyle(.plain)
                    if showAdvanced {
                TextField("内存（MB）",text:$ram)
                TextField("CPU 核心数",text:$cpus)
                TextField("设备存储（GB）",text:$storage)
                Toggle("设备声音",isOn:$audio)
                    }
                }
            }.formStyle(.grouped)
            if images.isEmpty { Text("没有找到已安装的系统镜像。").wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary) }
            Button("安装 SDK 和系统镜像…") { installing = true }
            if !error.isEmpty { Text(error).foregroundStyle(WbColor.negative) }
            HStack { Spacer(); Button("取消") { dismiss() }.disabled(saving).keyboardShortcut(.cancelAction)
                Button("创建") {
                    let parameters: [String:Any]
                    do { parameters = try DeviceCreation(name:name,image:image,profile:profile,ram:ram,cpus:cpus,storage:storage,root:root,audio:audio).parameters() }
                    catch { self.error = model.creationError(error); return }
                    saving = true
                    model.call("device.create",parameters) { result in
                        saving = false
                        switch result {
                        case .success(let data):
                            do {
                                let created = try model.decode(data,as:Device.self)
                                model.selected = created.id; model.details = nil; model.apps = []
                                model.refresh(); dismiss()
                                if root == "magisk" { DispatchQueue.main.async { model.setupFullRoot(created.id,name:created.name) } }
                            } catch { self.error = model.text("设备已创建，但读取结果失败：", "Device created, but its result could not be read: ") + error.localizedDescription; model.refresh() }
                        case .failure(let failure): error = failure.localizedDescription
                        }
                    }
                }.buttonStyle(.borderedProminent).disabled(saving || images.isEmpty || profiles.isEmpty).keyboardShortcut(.defaultAction)
            }
        }.padding(WbSpace.xl).frame(width:520, height:520).onAppear {
            model.call("profile.list") { result in
                do { profiles = try model.decode(result.get(),as:[HardwareProfile].self); profile = profiles.first?.id ?? "" }
                catch { self.error = error.localizedDescription }
            }
            model.call("settings.get") { result in
                if let data = try? result.get(), let value = try? model.decode(data,as:DaemonSettings.self) { root = value.default_root_mode }
            }
            loadImages()
        }
        .sheet(isPresented:$installing,onDismiss:loadImages) {
            InstallSDKView(model:model).environment(\.locale,Locale(identifier:model.language == 0 ? "en" : "zh-Hans"))
        }
    }
}

struct ToolPaths: Decodable { let android_sdk: String?; let jdk_home: String? }
struct CenterPaths: Decodable { let data: String; let cache: String; let logs: String; let tools: ToolPaths }
struct DaemonSettings: Decodable {
    let default_root_mode: String
    let quick_boot: Bool
    let budget_percent: UInt8
    let auto_hibernate_minutes: UInt32
}
struct SDKStatus: Decodable { let tools_sdk: String?; let private_sdk: String? }
struct CacheEntry: Decodable { let size: UInt64 }
struct AboutInfo: Decodable { let version: String; let repository: String }
struct SettingsView: View {
    @ObservedObject var model: CenterModel
    @Environment(\.dismiss) private var dismiss
    @State private var category = 0
    @State private var migrationParent: URL?
    @State private var migrationChecking = false
    @State private var migrationMessage = ""
    @State private var tileURL = ""
    @State private var mcpBinary = "jidr"
    @State private var confirmClaudeConfig = false
    @State private var paths: CenterPaths?
    @State private var sdkStatus: SDKStatus?
    @State private var root = "none"
    @State private var quickBoot = true
    @State private var budget = "80"
    @State private var autoHibernate = "0"
    @State private var loaded = false
    @State private var message = ""
    @State private var saving = false
    @State private var installing = false
    @State private var cacheBytes: UInt64?
    @State private var imageCount: Int?
    @State private var deviceUsage: [String:UInt64] = [:]
    @State private var about: AboutInfo?
    @State private var confirmCacheClear = false
    @State private var checkingUpdate = false
    @State private var updateMessage = ""
    @State private var releaseURL: URL?
    func load() {
        tileURL = model.tileURL
        model.call("center.paths") { result in
            do { paths = try model.decode(result.get(),as:CenterPaths.self) }
            catch { message = error.localizedDescription }
        }
        model.call("sdk.status") { result in
            do { sdkStatus = try model.decode(result.get(),as:SDKStatus.self) }
            catch { message = error.localizedDescription }
        }
        model.call("settings.get") { result in
            do {
                let value = try model.decode(result.get(),as:DaemonSettings.self)
                root = value.default_root_mode; quickBoot = value.quick_boot
                budget = String(value.budget_percent)
                autoHibernate = String(value.auto_hibernate_minutes)
                loaded = true
            }
            catch { message = error.localizedDescription }
        }
        model.call("cache.list") { result in
            do {
                let entries = try model.decode(result.get(),as:[CacheEntry].self)
                cacheBytes = entries.reduce(0) { total, item in total.addingReportingOverflow(item.size).overflow ? UInt64.max : total + item.size }
            } catch { message = error.localizedDescription }
        }
        model.call("image.list",["available":false]) { result in
            do { imageCount = try model.decode(result.get(),as:[AvailableImage].self).filter { $0.installed_in != nil }.count }
            catch { message = error.localizedDescription }
        }
        for device in model.devices {
            model.call("device.details",["device":device.id]) { result in
                if let value = try? result.get(), let details = try? model.decode(value,as:Details.self), let bytes = details.disk_usage { deviceUsage[device.id] = bytes }
            }
        }
        model.call("center.about") { result in
            if let value = try? result.get() { about = try? model.decode(value,as:AboutInfo.self) }
        }
    }
    func tool(_ kind:String, path:Any) {
        guard !saving else { return }; saving = true
        model.call("center.toolpath.set",["kind":kind,"path":path]) { result in
            saving = false
            switch result { case .success: message = kind == "sdk" ? model.text("SDK 路径已保存，下次启动设备时生效。", "SDK path saved; it will apply on the next device start.") : model.text("JDK 路径已保存。", "JDK path saved."); load()
            case .failure(let failure): message = failure.localizedDescription }
        }
    }
    func choose(_ kind:String) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tool(kind,path:url.path)
    }
    func chooseMigrationParent() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = model.text("选择位置", "Choose location")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        migrationParent = folder; migrationMessage = model.text("已选择目标位置，数据尚未迁移。", "Destination selected; no data has been moved.")
    }
    func checkMigration() {
        guard let parent = migrationParent, let sdk = paths?.tools.android_sdk ?? sdkStatus?.tools_sdk else {
            migrationMessage = model.text("请选择目标位置并确认 SDK 可用。", "Choose a destination and ensure the SDK is available."); return
        }
        migrationChecking = true
        model.call("center.migration.preflight",["parent":parent.path,"sdk":sdk]) { result in
            migrationChecking = false
            switch result {
            case .success(let value):
                guard let data = value as? [String:Any], let required = data["required_bytes"] as? Int64, let available = data["available_bytes"] as? Int64 else {
                    migrationMessage = model.text("检查结果无效。", "Invalid preflight result."); return
                }
                let needed = ByteCountFormatter.string(fromByteCount:required,countStyle:.file)
                let free = ByteCountFormatter.string(fromByteCount:available,countStyle:.file)
                migrationMessage = model.text("空间初步检查通过：需要约 \(needed)，可用 \(free)。数据尚未迁移或切换。", "Space preflight passed: needs about \(needed), \(free) available. No data has been moved or switched.")
                if let issues = data["incomplete_snapshots"] as? [String], !issues.isEmpty {
                    migrationMessage += "\n" + model.text("发现文件不完整的快照，不能保证恢复：", "Incomplete snapshots cannot be assumed recoverable: ") + issues.joined(separator:", ")
                }
            case .failure(let error):
                let reason = error.localizedDescription
                let translated: String
                switch reason {
                case "destination already exists": translated = model.text("目标目录已存在，请选择其他位置。", "The destination already exists. Choose another location.")
                case "destination overlaps source": translated = model.text("目标位置与现有数据重叠。", "The destination overlaps existing data.")
                case "destination or qemu-img unavailable": translated = model.text("目标目录或 SDK 磁盘工具不可用。", "The destination or SDK disk tool is unavailable.")
                case "paths must be absolute": translated = model.text("目标和 SDK 路径必须是绝对路径。", "Destination and SDK paths must be absolute.")
                default: translated = reason
                }
                migrationMessage = model.text("初步检查未通过：", "Preliminary check failed: ") + translated
            }
        }
    }
    func showFolder(_ path:String?) {
        guard let path, FileManager.default.fileExists(atPath:path), NSWorkspace.shared.open(URL(fileURLWithPath:path)) else { message = model.text("无法打开目录。", "Cannot open the folder."); return }
    }
    func checkUpdate() {
        guard let about, let url = URL(string:"https://api.github.com/repos/hbdzh/JIdr-plus/releases/latest") else { return }
        checkingUpdate = true; updateMessage = model.text("正在检查更新…", "Checking for updates…"); releaseURL = nil
        var request = URLRequest(url:url); request.timeoutInterval = 8
        request.setValue("JIdr/\(about.version)",forHTTPHeaderField:"User-Agent")
        URLSession.shared.dataTask(with:request) { data, response, _ in
            let parsed = data.flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                checkingUpdate = false
                guard status == 200, let tag = parsed?["tag_name"] as? String,
                      let page = parsed?["html_url"] as? String, let destination = URL(string:page),
                      destination.scheme == "https", destination.host == "github.com",
                      destination.path.hasPrefix("/hbdzh/JIdr-plus/releases/") else {
                    updateMessage = model.text("无法检查更新，请稍后重试。", "Unable to check for updates. Try again later."); return
                }
                let latest = tag.trimmingCharacters(in:CharacterSet(charactersIn:"v"))
                let newer = latest.compare(about.version,options:.numeric) == .orderedDescending
                updateMessage = newer ? model.text("发现新版本：\(latest)", "New version available: \(latest)") : model.text("已是最新版本。", "You're up to date.")
                if newer { releaseURL = destination }
            }
        }.resume()
    }
    var body: some View {
        HStack(spacing: WbSpace.zero) {
            VStack(alignment: .leading, spacing: WbSpace.xs) {
                Text(model.text("设置", "Settings")).wbFont(WbType.headline).padding(.horizontal, WbSpace.md).padding(.bottom, WbSpace.md)
                ForEach(Array([(model.text("通用", "General"), WbIcon.settings),
                               (model.text("设备默认值", "Device defaults"), WbIcon.advancedTools),
                               (model.text("数据与工具", "Data & tools"), WbIcon.dataTools),
                               (model.text("高级", "Advanced"), WbIcon.advancedConfig),
                               (model.text("关于", "About"), WbIcon.info)].enumerated()), id: \.offset) { index, item in
                    JidrNavigationItem(title:item.0, symbol:item.1, selected:category == index) { category = index }
                }
                Spacer()
            }.padding(WbSpace.lg).frame(width: 185).background(WbColor.raised)
            Divider()
            VStack(alignment:.leading,spacing:WbSpace.lg) {
            HStack { Text([model.text("通用", "General"), model.text("设备默认值", "Device defaults"), model.text("数据与工具", "Data & tools"), model.text("高级", "Advanced"), model.text("关于", "About")][category]).wbFont(WbType.headline); Spacer(); Button("关闭") { dismiss() }.disabled(saving).keyboardShortcut(.cancelAction) }
            ScrollView {
              Form {
                if category == 0 { Section("界面") {
                    Picker("语言", selection:Binding(get:{model.language},set:{model.setPreference("language",$0)})) { Text("中文").tag(1); Text("English").tag(0) }
                    Picker("外观", selection:Binding(get:{model.appearance},set:{model.setPreference("appearance",$0)})) { Text("跟随系统").tag(0); Text("浅色").tag(1); Text("深色").tag(2) }
                }
                }
                if category == 3 { Section(model.text("高级设置", "Advanced")) {
                    TextField(model.text("地图瓦片地址（留空使用默认）", "Map tile URL (empty for default)"),text:$tileURL)
                    Text(model.text("须使用 HTTPS 并包含 {z}、{x}、{y}。打开地图时，服务商会收到请求。", "Use HTTPS and include {z}, {x}, {y}. The provider receives requests when the map is opened.")).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                    Button(model.text("保存地图设置", "Save map settings")) {
                        saving = true
                        model.call("center.prefs.set",["tile_url":tileURL]) { result in
                            saving = false
                            switch result { case .success: model.tileURL = tileURL; message = model.text("地图设置已保存。", "Map settings saved."); case .failure(let error): message = error.localizedDescription.contains("Map tile URL must") ? model.text("地图地址必须使用 HTTPS，并包含 {z}、{x} 和 {y}。", "Map tile URL must use HTTPS and contain {z}, {x} and {y}.") : error.localizedDescription }
                        }
                    }.disabled(saving)
                    TextField(model.text("MCP 命令路径", "MCP command path"),text:$mcpBinary)
                    Text(model.text("将以下配置添加到支持 MCP 的客户端。可填写 jidr 可执行文件的绝对路径。", "Add this configuration to your MCP client. You may enter the absolute path to the jidr executable.")).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                    Button(model.text("配置 Claude Desktop…", "Configure Claude Desktop…")) { confirmClaudeConfig = true }.disabled(saving)
                    Button(model.text("复制 MCP 配置", "Copy MCP configuration")) {
                        guard !mcpBinary.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, let data = try? JSONSerialization.data(withJSONObject:["mcpServers":["jidr":["command":mcpBinary,"args":["mcp"]]]],options:[.prettyPrinted,.sortedKeys]), let text = String(data:data,encoding:.utf8) else { return }
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string)
                        message = model.text("MCP 配置已复制。", "MCP configuration copied.")
                    }
                }
                }
                if category == 1 { Section("设备默认设置") {
                    Picker("默认 Root 模式",selection:$root) { Text("无").tag("none"); Text("Shell root").tag("adb"); Text("完整 root").tag("magisk") }
                    Toggle("停止设备时保存快速启动快照",isOn:$quickBoot)
                    TextField("设备内存预算（%）",text:$budget)
                    TextField("自动休眠分钟数（0 为关闭）",text:$autoHibernate)
                    Button("保存默认设置") {
                        guard let percent = UInt8(budget), (10...100).contains(percent), let minutes = UInt32(autoHibernate) else {
                            message = model.text("内存预算必须为 10–100%，自动休眠时间必须为非负整数。", "Memory budget must be 10–100%; idle sleep must be a nonnegative integer."); return
                        }
                        saving = true; model.call("settings.set",["default_root_mode":root,"quick_boot":quickBoot,"budget_percent":percent,"auto_hibernate_minutes":minutes]) { result in
                            saving = false; switch result { case .success: message = model.text("已保存", "Saved"); case .failure(let failure): message = failure.localizedDescription }
                        }
                    }.disabled(!loaded || saving)
                }
                }
                if category == 2 { Section("数据和工具位置") {
                    PathSetting(title:model.text("数据目录", "Data folder"), path:paths?.data ?? model.text("读取中…", "Loading…")) {
                        Button("显示数据目录") { showFolder(paths?.data) }.disabled(paths == nil)
                    }
                    PathSetting(title:"Android SDK", path:paths?.tools.android_sdk ?? sdkStatus?.tools_sdk ?? model.text("自动选择", "Automatic")) {
                        Button("选择 SDK") { choose("sdk") }.disabled(paths == nil || saving)
                        Button("恢复自动选择") { tool("sdk",path:NSNull()) }.disabled(paths == nil || saving)
                        Button(model.text("显示目录", "Show folder")) { showFolder(paths?.tools.android_sdk ?? sdkStatus?.tools_sdk) }.disabled(paths?.tools.android_sdk == nil && sdkStatus?.tools_sdk == nil)
                    }
                    Button("安装 SDK 和系统镜像…") { installing = true }.disabled(saving)
                    PathSetting(title:"JDK", path:paths?.tools.jdk_home ?? model.text("系统默认", "System default")) {
                        Button("选择 JDK") { choose("jdk") }.disabled(paths == nil || saving)
                        Button("恢复系统默认") { tool("jdk",path:NSNull()) }.disabled(paths == nil || saving)
                    }
                    PathSetting(title:model.text("迁移目标", "Migration destination"), path:migrationParent.map { $0.appendingPathComponent("Jidr").path } ?? model.text("未选择", "Not selected")) {
                        Button(model.text("选择目标位置…", "Choose destination…")) { chooseMigrationParent() }.disabled(saving || migrationChecking)
                        Button(model.text("初步检查", "Preliminary check")) { checkMigration() }.disabled(migrationParent == nil || saving || migrationChecking)
                    }
                    Text(model.text("目前仅支持初步检查；尚不能迁移或切换数据位置。", "Only preliminary checks are available; migration and switching are not yet supported."))
                        .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                    if !migrationMessage.isEmpty { Text(migrationMessage).wbFont(WbType.caption).textSelection(.enabled) }
                }
                Section("存储用量") {
                    ForEach(model.devices) { device in
                        LabeledContent(device.name,value:deviceUsage[device.id].map { ByteCountFormatter.string(fromByteCount:Int64(clamping:$0),countStyle:.file) } ?? model.text("读取中…", "Loading…"))
                    }
                    LabeledContent("已安装镜像",value:imageCount.map(String.init) ?? model.text("读取中…", "Loading…"))
                    LabeledContent("下载缓存",value:cacheBytes.map { ByteCountFormatter.string(fromByteCount:Int64(clamping:$0),countStyle:.file) } ?? model.text("读取中…", "Loading…"))
                    Button("清理下载缓存…") { confirmCacheClear = true }.disabled(saving || cacheBytes == nil || cacheBytes == 0)
                }
                }
                if category == 4 { Section("关于") {
                    LabeledContent("版本",value:about?.version ?? "—")
                    HStack {
                        Button("检查更新") { checkUpdate() }.disabled(checkingUpdate || about == nil)
                        if let releaseURL { Button("查看新版本") { NSWorkspace.shared.open(releaseURL) } }
                        Button("源代码") { if let value = about?.repository, let url = URL(string:value) { NSWorkspace.shared.open(url) } }.disabled(about == nil)
                        Button("许可证") { if let value = about?.repository, let url = URL(string:value + "/blob/master/NOTICE") { NSWorkspace.shared.open(url) } }.disabled(about == nil)
                    }
                    if !updateMessage.isEmpty { Text(updateMessage).wbFont(WbType.caption) }
                }
                }
              }.formStyle(.grouped).frame(maxWidth: 680, alignment: .leading)
            }
            if !message.isEmpty { Text(message).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary).textSelection(.enabled) }
            }.padding(WbSpace.xl).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(width:780,height:540).onAppear(perform:load)
        .sheet(isPresented:$installing,onDismiss:load) {
            InstallSDKView(model:model).environment(\.locale,Locale(identifier:model.language == 0 ? "en" : "zh-Hans"))
        }
        .alert(model.text("配置 Claude Desktop？", "Configure Claude Desktop?"),isPresented:$confirmClaudeConfig) {
            Button(model.text("取消", "Cancel"),role:.cancel) { }
            Button(model.text("配置", "Configure")) {
                let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
                do { try MCPConfiguration.install(at:path,command:mcpBinary); message = model.text("配置已保存，请重启 Claude Desktop。", "Configuration saved. Restart Claude Desktop.") }
                catch { message = model.text("无法保存 Claude 配置：", "Could not save Claude configuration: ") + OperationMessages.error(error.localizedDescription,language:model.language) }
            }
        } message: { Text(model.text("将添加或替换 Jidr 的 MCP 配置，保留其他配置。", "This adds or replaces the Jidr MCP entry and preserves other settings.")) }
        .alert("清理下载缓存？",isPresented:$confirmCacheClear) {
            Button("取消",role:.cancel) { }
            Button("清理",role:.destructive) {
                saving = true
                model.call("cache.prune") { result in
                    saving = false
                    switch result { case .success: message = model.text("下载缓存已清理。", "Download cache cleared."); load(); case .failure(let failure): message = failure.localizedDescription }
                }
            }
        } message: { Text("已下载的缓存文件会被删除，之后需要时可能重新下载。设备数据和快照不会删除。") }
    }
}

struct CenterView: View {
    @ObservedObject var model: CenterModel
    @State private var query = ""
    @State private var detailsVisible = true
    @FocusState private var searchFocused: Bool
    var selectedDevice: Device? { model.devices.first(where:{$0.id == model.selected}) }
    private var filteredDevices: [Device] {
        model.devices.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }
    @ViewBuilder private func startButton(_ device:Device) -> some View {
        Button(device.running ? "停止" : "启动",systemImage:device.running ? WbIcon.stop : WbIcon.play) {
            if device.running { model.stop(device.id) } else { model.start(device.id) }
        }.buttonStyle(.borderedProminent).disabled(model.busy.contains(device.id) || (!device.running && !device.stopped))
    }
    @ViewBuilder private func restartButton(_ device:Device) -> some View {
        Button("重启",systemImage:WbIcon.refresh) { model.restart(device.id) }.disabled(!device.running || model.busy.contains(device.id))
    }
    @ViewBuilder private func deleteButton(_ device:Device) -> some View {
        Button("删除设备",systemImage:WbIcon.trash,role:.destructive) { model.deleteRequested = true }.disabled(!device.stopped || model.busy.contains(device.id))
    }
    @ViewBuilder private func settingsButton(_ device:Device) -> some View {
        Button("设备设置",systemImage:WbIcon.settings) { model.presentDeviceSheet(.edit, device:device.id) }.disabled(model.details == nil || model.busy.contains(device.id))
    }

    private func toolbar(compact: Bool) -> some View {
        HStack(spacing: WbSpace.sm) {
            Text("安卓模拟器").wbFont(WbType.title)
            Spacer()
            TextField("搜索设备", text:$query)
                .textFieldStyle(.roundedBorder)
                .frame(width:compact ? 150 : 200)
                .focused($searchFocused)
                .accessibilityLabel(model.text("搜索设备", "Search devices"))
            Button { model.openPalette() } label: { Image(systemName:WbIcon.search) }
                .help(model.text("搜索命令和设备（⌘K）", "Search commands and devices (⌘K)"))
                .accessibilityLabel(model.text("搜索命令和设备（⌘K）", "Search commands and devices (⌘K)"))
            ConnectionStatusPill(model:model)
            if !model.activeJobs.isEmpty {
                Button { model.openTasks() } label: {
                    HStack(spacing:WbSpace.xs) { Image(systemName:WbIcon.tasks); Text("\(model.activeJobs.count)") }
                }
                .help(model.text("后台任务", "Background tasks"))
                .accessibilityLabel(model.text("后台任务（\(model.activeJobs.count)）", "Background tasks (\(model.activeJobs.count))"))
            }
            if compact {
                Button { model.present(.newDevice) } label: { Image(systemName:WbIcon.plus) }
                    .help(model.text("新建设备（⌘N）", "New device (⌘N)"))
                    .accessibilityLabel(model.text("新建设备（⌘N）", "New device (⌘N)"))
            } else {
                Button("添加设备",systemImage:WbIcon.plus) { model.present(.newDevice) }
                    .help(model.text("新建设备（⌘N）", "New device (⌘N)"))
            }
            Button { model.present(.settings) } label: { Image(systemName:WbIcon.settings) }
                .help(model.text("设置（⌘,）", "Settings (⌘,)"))
                .accessibilityLabel(model.text("设置（⌘,）", "Settings (⌘,)"))
            Button { model.refresh() } label: { Image(systemName:WbIcon.refresh) }
                .help(model.text("刷新设备（⌘R）", "Refresh devices (⌘R)"))
                .accessibilityLabel(model.text("刷新设备（⌘R）", "Refresh devices (⌘R)"))
            Button { detailsVisible.toggle() } label: {
                Image(systemName:detailsVisible ? WbIcon.hideDetails : WbIcon.showDetails)
            }
            .help(detailsVisible ? model.text("隐藏详情", "Hide details") : model.text("显示详情", "Show details"))
            .accessibilityLabel(detailsVisible ? model.text("隐藏详情", "Hide details") : model.text("显示详情", "Show details"))
        }.padding(.leading, compact ? 84 : 94).padding(.trailing,WbSpace.md).frame(height: WbLayout.windowTitlebarHeight)
        .background(WbColor.chrome)
    }

    /// Wide windows keep the two-column layout; narrow ones (800×550 minimum)
    /// collapse to one scrollable column with the detail/app column collapsible.
    @ViewBuilder private func layout(compact: Bool, height: CGFloat) -> some View {
        if compact {
            ScrollView {
                VStack(spacing:WbSpace.lg) {
                    deviceList.frame(height:max(200, min(320, height * 0.32)))
                    quickActions
                    if detailsVisible {
                        detailCard
                        appList.frame(height:210)
                    }
                }.padding(WbSpace.lg)
            }
        } else {
            HStack(alignment:.top,spacing:WbSpace.lg) {
                VStack(spacing:WbSpace.lg) { deviceList; quickActions }.frame(maxWidth:.infinity,maxHeight:.infinity)
                if detailsVisible {
                    VStack(spacing:WbSpace.lg) { detailCard; appList }.frame(maxWidth:.infinity,maxHeight:.infinity)
                }
            }.padding(WbSpace.lg)
        }
    }

    private var deviceList: some View {
        VStack(alignment:.leading) {
            HStack { Text("我的设备"); Text("\(model.devices.count)") }.wbFont(WbType.title)
            if model.deviceListLoaded && model.devices.isEmpty {
                VStack(alignment:.leading, spacing:WbSpace.md) {
                    Label(model.text("开始使用 Jidr", "Get started with Jidr"), systemImage:WbIcon.deviceEmpty)
                        .wbFont(WbType.title)
                    Text(model.text("先选择已有 Android SDK 或安装所需组件，然后创建第一台设备。", "Choose an existing Android SDK or install the required components, then create your first device."))
                        .wbFont(WbType.body).foregroundStyle(WbColor.textSecondary)
                    HStack {
                        Button(model.text("设置 Android SDK…", "Set up Android SDK…")) { model.present(.setupSDK) }
                        Button(model.text("创建设备…", "Create device…")) { model.present(.newDevice) }
                    }
                }.padding(.vertical,WbSpace.md)
            } else { ScrollView {
                LazyVStack(spacing:WbSpace.sm) {
                    ForEach(filteredDevices) { device in
                        Button { model.select(device.id) } label: {
                            HStack { DeviceArt(name:"device-list", width:40); VStack(alignment:.leading) { Text(device.name).wbFont(WbType.title).lineLimit(1).truncationMode(.middle); HStack(spacing:WbSpace.sm) { Circle().fill(device.running ? WbColor.positive : WbColor.textTertiary).frame(width:6,height:6).accessibilityHidden(true); Text(device.statusText(language:model.language)) }.wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary); if let progress = model.progress(for:device.id) { Text(progress).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary).lineLimit(1) } else { Text(device.androidVersion).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary) } }; Spacer(); Image(systemName:WbIcon.chevronRight).accessibilityHidden(true) }.padding(WbSpace.md).frame(maxWidth:.infinity,alignment:.leading).background(model.selected == device.id ? WbColor.selected : WbColor.raised,in:RoundedRectangle(cornerRadius: WbRadius.lg))
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children:.ignore)
                        .accessibilityLabel(model.text("\(device.name)，\(device.statusText(language:model.language))", "\(device.name), \(device.statusText(language:0))"))
                        .accessibilityHint(model.text("按 Return 打开设备窗口，或选择设备后使用常用操作。", "Press Return to open the device window, or use the quick actions after selecting it."))
                        .accessibilityAction(named: Text(model.text("打开设备窗口", "Open device window"))) {
                            model.focusOrOpenDeviceWindow(device.id)
                        }
                        .simultaneousGesture(TapGesture(count:2).onEnded {
                            model.focusOrOpenDeviceWindow(device.id)
                        })
                    }
                }
            } }
        }.padding(WbSpace.lg).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            .background(WbColor.raised,in:RoundedRectangle(cornerRadius: WbRadius.xl))
    }

    private var quickActions: some View {
        VStack(alignment:.leading,spacing:WbSpace.md) {
            Text("常用操作").wbFont(WbType.title)
            if let device = selectedDevice {
                Grid(alignment:.leading,horizontalSpacing:12,verticalSpacing:12) {
                    GridRow {
                        Button("安装 APK",systemImage:WbIcon.installAPK) { model.chooseFile(device:device.id,apk:true) }
                        Button("发送文件",systemImage:WbIcon.folder) { model.chooseFile(device:device.id,apk:false) }
                    }
                    GridRow {
                        Button("截图",systemImage:WbIcon.camera) { model.screenshot(device:device.id) }
                        Button(model.recording.contains(device.id) ? "停止录屏" : "录屏",systemImage:WbIcon.record) { model.toggleRecording(device:device.id) }
                    }
                }.disabled(!device.running)
                HStack {
                    Button("管理快照",systemImage:WbIcon.camera) { model.selected = device.id; model.present(.snapshots) }
                    Button("截图目录",systemImage:WbIcon.folder) { model.openScreenshotFolder() }
                }
            }
        }.padding(WbSpace.lg).frame(maxWidth:.infinity,alignment:.leading)
            .background(WbColor.raised,in:RoundedRectangle(cornerRadius: WbRadius.xl))
    }

    private var detailCard: some View {
        VStack(alignment:.leading,spacing:WbSpace.lg) {
            HStack { Text("设备详情").wbFont(WbType.title); Spacer(); Button("查看设备详情") { if let device = selectedDevice { model.presentDeviceSheet(.details, device:device.id) } }.buttonStyle(.plain).disabled(model.details == nil) }
            if let device = selectedDevice {
                HStack { DeviceArt(name:"device-detail", width:86); VStack(alignment:.leading) { Text(device.name).wbFont(WbType.headline).lineLimit(1).truncationMode(.middle); Text(device.statusText(language:model.language)).foregroundStyle(device.running ? .green : WbColor.textSecondary); Text(device.androidVersion).foregroundStyle(WbColor.textSecondary) }; Spacer() }
                if let holder = model.busyHolder(for: device.id) {
                    Label(holder, systemImage:WbIcon.busy).wbFont(WbType.caption).foregroundStyle(WbColor.warning)
                }
                if let d = model.details {
                    Grid(alignment:.leading,horizontalSpacing:24,verticalSpacing:8) {
                        GridRow { Text("CPU").foregroundStyle(WbColor.textSecondary); Text(model.text("\(d.config["hw.cpu.ncore"] ?? "—") 核", "\(d.config["hw.cpu.ncore"] ?? "—") cores")); Text("内存").foregroundStyle(WbColor.textSecondary); Text("\(d.config["hw.ramSize"] ?? "—") MB") }
                        GridRow { Text("屏幕").foregroundStyle(WbColor.textSecondary); Text("\(d.config["hw.lcd.width"] ?? "—")×\(d.config["hw.lcd.height"] ?? "—")"); Text("DPI").foregroundStyle(WbColor.textSecondary); Text(d.config["hw.lcd.density"] ?? "—") }
                        GridRow { Text(model.text("镜像", "Image")).foregroundStyle(WbColor.textSecondary); Text(device.imageLabel); Text(model.text("配置", "Profile")).foregroundStyle(WbColor.textSecondary); Text(device.profile) }
                        GridRow { Text(model.text("磁盘占用", "Disk usage")).foregroundStyle(WbColor.textSecondary); Text(d.disk_usage.map { ByteCountFormatter.string(fromByteCount:Int64(clamping:$0),countStyle:.file) } ?? "—"); Text(model.text("序列号", "Serial")).foregroundStyle(WbColor.textSecondary); Text(device.runtime?.adb_serial ?? "—") }
                    }
                }
                ViewThatFits(in:.horizontal) {
                    HStack { startButton(device); restartButton(device); deleteButton(device); settingsButton(device) }.fixedSize()
                    VStack(alignment:.leading) {
                        HStack { startButton(device); restartButton(device) }
                        HStack { deleteButton(device); settingsButton(device) }
                    }
                }
                if let progress = model.progress(for:device.id) {
                    HStack { ProgressView().controlSize(.small); Text(progress).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary) }
                }
                if model.fullRoot[device.id] != nil {
                    Button("查看 Root 配置") { model.rootPresentation = RootPresentation(id:device.id,name:device.name) }
                }
            } else { Text("请选择设备").foregroundStyle(WbColor.textSecondary) }
        }.padding(WbSpace.lg).frame(maxWidth:.infinity,alignment:.topLeading)
            .background(WbColor.raised,in:RoundedRectangle(cornerRadius: WbRadius.xl))
    }

    private var appList: some View {
        VStack(alignment:.leading,spacing:WbSpace.md) {
            HStack {
                Text("已安装的游戏和应用").wbFont(WbType.title)
                Spacer()
                Button("刷新",systemImage:WbIcon.refresh) { if let device = selectedDevice { model.load(device.id) } }
                    .disabled(selectedDevice?.running != true)
            }
            if let device = selectedDevice, device.running {
                if model.appsLoading { ProgressView(model.text("正在读取已安装的游戏和应用…", "Loading installed games and apps…")).controlSize(.small).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary) }
                if let error = model.appsError { Label(error,systemImage:WbIcon.warning).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary).textSelection(.enabled) }
                if let note = model.appsNote { Text(note).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary).textSelection(.enabled) }
                if !model.appsLoading && model.appsError == nil && model.apps.isEmpty {
                    Label(model.text("尚未安装可启动的游戏或应用。", "No launchable apps installed yet."), systemImage:WbIcon.appEmpty)
                        .wbFont(WbType.body).foregroundStyle(WbColor.textSecondary).padding(.vertical, WbSpace.sm)
                }
                ScrollView {
                    LazyVStack {
                        ForEach(model.apps) { app in
                            HStack {
                                if let path = app.icon, let icon = NSImage(contentsOfFile:path) {
                                    Image(nsImage:icon).resizable().frame(width:32,height:32).clipShape(RoundedRectangle(cornerRadius: WbRadius.sm))
                                }
                                Text(app.name); Spacer()
                                Button("启动",systemImage:WbIcon.play) { model.launch(app,device:device.id) }
                            }.padding(WbSpace.sm)
                        }
                    }
                }
            } else { Text("启动设备后查看已安装的游戏和应用。").foregroundStyle(WbColor.textSecondary) }
            Spacer(minLength:0)
        }.padding(WbSpace.lg).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
            .background(WbColor.raised,in:RoundedRectangle(cornerRadius: WbRadius.xl))
    }

    var body: some View {
        ZStack {
            GeometryReader { geometry in
                let compact = geometry.size.width < 940
                VStack(spacing:WbSpace.zero) {
                    toolbar(compact: compact)
                    Divider()
                    layout(compact: compact, height: geometry.size.height)
                    if !model.notice.isEmpty { Text(model.displayNotice).wbFont(WbType.caption).padding(WbSpace.sm) }
                }
            }
            if model.paletteOpen { CommandPaletteView(model:model) }
            if model.tasksOpen { TaskCenterView(model:model) }
            if let toast = model.toast {
                VStack { Spacer(); ToastOverlay(toast:toast) { model.dismissToast() } }
            }
        }
        .frame(minWidth:800,minHeight:550).background(WbColor.surface)
        .ignoresSafeArea(.container, edges:.top)
        .environment(\.locale, Locale(identifier:model.language == 0 ? "en" : "zh-Hans"))
        .preferredColorScheme(model.appearance == 1 ? .light : model.appearance == 2 ? .dark : nil)
        .onChange(of:model.searchFocusRequest) { _, _ in searchFocused = true }
        .onChange(of:model.paletteOpen) { _, open in
            if !open, model.sheet == nil { searchFocused = true }
        }
        .onChange(of:model.tasksOpen) { _, open in
            if !open, model.sheet == nil { searchFocused = true }
        }
        .sheet(item:$model.sheet) { sheet in
            Group {
                switch sheet {
                case .newDevice: NewDeviceView(model:model)
                case .setupSDK: InstallSDKView(model:model)
                case .settings: SettingsView(model:model)
                case .snapshots:
                    if let device = selectedDevice { SnapshotsView(model:model, device:device) }
                    else { Text("请选择设备") }
                case .details:
                    if let details = model.details { DeviceDetailsView(model:model,details:details) }
                    else { ProgressView(model.text("正在读取设备详情…", "Loading device details…")) }
                case .edit:
                    if let details = model.details { EditDeviceView(model:model,details:details) }
                    else { ProgressView(model.text("正在读取设备详情…", "Loading device details…")) }
                }
            }.environment(\.locale, Locale(identifier:model.language == 0 ? "en" : "zh-Hans"))
        }
        .sheet(item:$model.rootPresentation) { target in
            FullRootView(model:model,target:target).environment(\.locale, Locale(identifier:model.language == 0 ? "en" : "zh-Hans"))
        }
        .alert("删除设备及全部数据？",isPresented:$model.deleteRequested) {
            Button("取消",role:.cancel) { }
            Button("删除",role:.destructive) { if let device = selectedDevice, device.stopped { model.operation("device.delete",id:device.id) } }
        } message: { Text("设备中的应用、游戏数据和快照将被删除，无法撤销。") }
        .alert(model.text("重新安装应用？", "Reinstall the app?"),
               isPresented: Binding(get: { model.reinstallPrompt != nil },
                                     set: { if !$0 { model.cancelSignatureConflictReinstall() } }),
               presenting: model.reinstallPrompt) { _ in
            Button(model.text("取消", "Cancel"), role:.cancel) { model.cancelSignatureConflictReinstall() }
            Button(model.text("卸载并重新安装", "Uninstall and reinstall"), role:.destructive) { model.confirmSignatureConflictReinstall() }
        } message: { prompt in
            Text(model.text("“\(prompt.apkName)”与设备上已安装的应用签名不一致。继续会先卸载现有应用，并删除其应用数据。",
                            "“\(prompt.apkName)” was signed with a different key than the installed app. Continuing uninstalls the existing app first, which deletes its data."))
        }
    }
}
