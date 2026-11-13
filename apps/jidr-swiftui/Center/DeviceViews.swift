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
            if let image = WbImageCache.image(named: name) {
                Image(nsImage:image).resizable().scaledToFit().frame(width:width)
            }
        }.accessibilityHidden(true)
    }
}

// MARK: - Shared sheet chrome

/// Shared title and device subtitle for device sheets and tools.
struct DeviceSheetHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .wbFont(WbType.headline)
                .foregroundStyle(WbColor.textPrimary)
            Text(subtitle)
                .wbFont(WbType.body)
                .foregroundStyle(WbColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WbSpace.xl)
        .padding(.top, WbSpace.lg)
        .padding(.bottom, WbSpace.md)
    }
}

/// Bottom bar: explanatory note on the left, actions on the right.
struct DeviceSheetFooter<Actions: View>: View {
    var note: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 0) {
            WbDivider()
            HStack(alignment: .center, spacing: WbSpace.sm) {
                Text(note)
                    .wbFont(WbType.caption)
                    .foregroundStyle(WbColor.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: WbSpace.sm)
                actions()
            }
            .padding(.horizontal, WbSpace.xl)
            .padding(.vertical, WbSpace.md)
        }
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
    @State private var sleepMinutes: String
    @State private var error = ""
    @State private var saving = false
    @State private var confirmColdBoot = false
    @State private var quality = 1
    @State private var qualityLoaded = false
    @State private var originalQuality = 1
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
        _sleepMinutes = State(initialValue:details.device.auto_hibernate_minutes.map(String.init) ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            DeviceSheetHeader(title: model.text("设备设置", "Device settings"),
                              subtitle: details.device.name)
            Form {
                Section {
                    HStack(alignment: .top, spacing: WbSpace.sm) {
                        Image(systemName: WbIcon.info)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(WbColor.textTertiary)
                            .padding(.top, 1)
                        Text(details.device.running
                             ? model.text("设备运行中，停止后才能修改硬件和启动设置。", "Stop the running device to change hardware and startup settings.")
                             : model.text("更改屏幕设置会冷启动；原快速启动快照由后台备份。", "Display changes require a cold boot; the quick-boot snapshot is backed up."))
                            .wbFont(WbType.caption)
                            .foregroundStyle(WbColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section(model.text("基本信息", "Basic information")) {
                    LabeledContent(model.text("设备名称", "Device name")) {
                        TextField("", text: $name)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .frame(width: 220)
                            .disabled(!details.device.stopped || saving)
                            .accessibilityLabel(model.text("设备名称", "Device name"))
                    }
                    LabeledContent(model.text("系统镜像", "System image"), value: details.device.imageLabel)
                }

                Section(model.text("性能与显示", "Performance & display")) {
                    LabeledContent(model.text("内存 (MB)", "Memory (MB)")) {
                        numberField($ram, label: model.text("内存 (MB)", "Memory (MB)"))
                    }
                    LabeledContent(model.text("CPU 核心数", "CPU cores")) {
                        numberField($cores, label: model.text("CPU 核心数", "CPU cores"))
                    }
                    LabeledContent(model.text("分辨率", "Resolution")) {
                        Picker("", selection: Binding(get: { resolutionPreset }, set: { selection in
                            resolutionPreset = selection
                            if let preset = resolutionPresets.first(where: { $0.0 == selection }) { width = preset.1; height = preset.2 }
                        })) {
                            Text(model.text("自定义", "Custom")).tag("custom")
                            ForEach(resolutionPresets, id: \.0) { preset in Text(preset.0).tag(preset.0) }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        .accessibilityLabel(model.text("分辨率", "Resolution"))
                    }
                    if resolutionPreset == "custom" {
                        LabeledContent(model.text("屏幕宽度 (px)", "Screen width (px)")) {
                            numberField($width, label: model.text("屏幕宽度 (px)", "Screen width (px)"))
                        }
                        LabeledContent(model.text("屏幕高度 (px)", "Screen height (px)")) {
                            numberField($height, label: model.text("屏幕高度 (px)", "Screen height (px)"))
                        }
                    }
                    LabeledContent(model.text("屏幕密度 (dpi)", "Screen density (dpi)")) {
                        numberField($density, label: model.text("屏幕密度 (dpi)", "Screen density (dpi)"))
                    }
                }
                .disabled(!details.device.stopped || saving)

                Section(model.text("启动", "Startup")) {
                    LabeledContent(model.text("快速启动", "Quick boot")) {
                        Picker("", selection: $quickBoot) {
                            Text(model.text("跟随全局", "Follow global")).tag("global")
                            Text(model.text("开启", "On")).tag("on")
                            Text(model.text("停用", "Off")).tag("off")
                        }
                        .labelsHidden()
                        .frame(width: 180)
                        .accessibilityLabel(model.text("快速启动", "Quick boot"))
                    }
                    LabeledContent(model.text("自动休眠", "Auto sleep")) {
                        TextField("", text: $sleepMinutes, prompt: Text(model.text("跟随全局", "Global default")))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 110)
                            .accessibilityLabel(model.text("自动休眠", "Auto sleep"))
                    }
                    Text(model.text("单位为分钟；留空跟随全局，0 为关闭。", "Minutes; leave blank for the global setting, or use 0 to turn off."))
                        .wbFont(WbType.caption)
                        .foregroundStyle(WbColor.textSecondary)
                }
                .disabled(!details.device.stopped || saving)

                Section(model.text("外设", "Peripherals")) {
                    LabeledContent(model.text("摄像头", "Cameras")) {
                        Button(model.text("在设备工具中设置…", "Configure in device tools…")) {
                            model.openAdvanced(details.device.id, name: details.device.name,
                                               section: 8, relativeTo: NSApp.keyWindow)
                        }.disabled(saving)
                    }
                }

                Section(model.text("声音与画面", "Audio & display")) {
                    Toggle(model.text("设备声音（下次启动生效）", "Device audio (applies next start)"), isOn: $audio)
                        .toggleStyle(.switch)
                        .tint(WbColor.accent)
                    LabeledContent(model.text("游戏窗口画质", "Game window quality")) {
                        HStack(spacing: WbSpace.sm) {
                            Picker("", selection: $quality) {
                                Text(model.text("流畅", "Smooth")).tag(0)
                                Text(model.text("清晰", "Sharp")).tag(1)
                                Text(model.text("节能", "Power saving")).tag(2)
                            }
                            .labelsHidden()
                            .frame(width: 110)
                            .disabled(!qualityLoaded)
                            .accessibilityLabel(model.text("游戏窗口画质", "Game window quality"))
                        }
                    }
                    Text(model.text("画质随本页一起保存，下次打开设备窗口生效；不改变游戏帧率。", "Quality is saved with this page and applies next time the device window opens; game frame rate is unchanged."))
                        .wbFont(WbType.caption)
                        .foregroundStyle(WbColor.textSecondary)
                    if !qualityMessage.isEmpty {
                        Text(qualityMessage)
                            .wbFont(WbType.caption)
                            .foregroundStyle(WbColor.textSecondary)
                    }
                }

                Section(model.text("存储", "Storage")) {
                    LabeledContent(model.text("磁盘占用", "Disk usage"),
                                   value: details.disk_usage.map { ByteCountFormatter.string(fromByteCount:Int64(clamping:$0),countStyle:.file) } ?? "—")
                    LabeledContent(model.text("数据目录", "Data folder")) {
                        Text(model.dataDirectory ?? "—")
                            .wbFont(WbType.code)
                            .foregroundStyle(WbColor.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.dataDirectory ?? "")
                            .textSelection(.enabled)
                    }
                }

                if !error.isEmpty {
                    Section {
                        Text(error)
                            .wbFont(WbType.caption)
                            .foregroundStyle(WbColor.negative)
                    }
                }

                Section {
                    Button(model.text("冷启动一次…", "Cold boot once…")) { confirmColdBoot = true }
                        .buttonStyle(.bordered).controlSize(.regular)
                        .disabled(!details.device.stopped || saving)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(WbColor.raised)
            .disabled(saving)

            DeviceSheetFooter(note: model.text("部分更改将在下次启动设备时生效。", "Some changes apply the next time the device starts.")) {
                Button(model.text("取消", "Cancel")) { dismiss() }
                    .buttonStyle(.bordered).controlSize(.regular)
                    .disabled(saving)
                    .keyboardShortcut(.cancelAction)
                Button(model.text("保存", "Save")) { save() }
                    .buttonStyle(.borderedProminent).controlSize(.regular).tint(WbColor.accent)
                    .disabled(saving)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .interactiveDismissDisabled(saving)
        .frame(width: 560, height: 620)
        .background(WbColor.raised)
        .onAppear {
            do {
                guard let path = model.dataDirectory else { qualityMessage = model.text("无法读取数据目录", "Cannot read the data directory"); return }
                quality = Int(try WindowQualityStore(dataDirectory:path,device:details.device.id).load())
                originalQuality = quality
                qualityLoaded = true
            } catch { qualityMessage = error.localizedDescription }
        }
        .alert("冷启动设备？",isPresented:$confirmColdBoot) {
            Button("取消",role:.cancel) { }
            Button("冷启动") { model.start(details.device.id,coldBoot:true); dismiss() }
        } message: { Text("本次启动将跳过快速启动快照，未保存的设置不会应用。") }
    }

    // MARK: Helpers

    private func numberField(_ value: Binding<String>, label: String) -> some View {
        TextField("", text: value)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 110)
            .accessibilityLabel(label)
    }

    private func save() {
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
            if sleepMinutes != (details.device.auto_hibernate_minutes.map(String.init) ?? "") {
                if sleepMinutes.isEmpty { values["auto_hibernate_minutes"] = NSNull() }
                else if let minutes = Int(sleepMinutes), (0...1440).contains(minutes) { values["auto_hibernate_minutes"] = minutes }
                else { error = model.text("自动休眠时间必须介于 0 到 1440 分钟。", "Idle sleep must be between 0 and 1440 minutes."); return }
            }
        }
        if !details.device.stopped { values = values.filter { $0.key == "audio" } }
        let qualityChanged = qualityLoaded && quality != originalQuality
        guard !values.isEmpty || qualityChanged else { dismiss(); return }
        let changes = values
        saving = true
        DeviceSettingsSave.commit(saveDevice: { done in
            guard !changes.isEmpty else { done(.success(())); return }
            var params = changes
            params["device"] = details.device.id
            model.call("device.edit", params) { result in
                switch result {
                case .success:
                    model.refresh()
                    if model.selected == details.device.id { model.load(details.device.id) }
                    done(.success(()))
                case .failure(let failure): done(.failure(failure))
                }
            }
        }, saveQuality: {
            guard qualityChanged else { return }
            guard let path = model.dataDirectory else {
                throw CocoaError(.fileNoSuchFile)
            }
            try WindowQualityStore(dataDirectory: path, device: details.device.id).save(UInt8(quality))
        }, completion: { result in
            saving = false
            switch result {
            case .success: dismiss()
            case .failure(.device(let failure)): error = failure.localizedDescription
            case .failure(.quality(let failure)):
                error = (changes.isEmpty
                    ? model.text("画质未能保存，请重试。", "Quality could not be saved. Try again.")
                    : model.text("设备设置已保存，但画质未能保存，请重试。", "Device settings were saved, but quality could not be saved. Try again."))
                    + "\n" + failure.localizedDescription
            }
        })
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
    var onClose: (() -> Void)? = nil
    private func finish() { if let onClose { onClose() } else { dismiss() } }
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
            case .success: model.refresh(); finish()
            case .failure(let failure): error = model.text("无法使用该 SDK，请确认目录包含 emulator 和 platform-tools。", "Cannot use this SDK. Check that it contains emulator and platform-tools.") + "\n" + failure.localizedDescription
            }
        }
    }

    private func chooseInstallLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = t("选择安装位置", "Choose install location")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setInstallLocation(url.path)
    }
    private func restoreInstallLocation() { setInstallLocation(NSNull()) }
    private func setInstallLocation(_ path: Any) {
        loading = true; error = ""
        loadingMessage = t("正在保存安装位置…", "Saving install location…")
        model.call("center.toolpath.set", ["kind": "jidr_sdk", "path": path]) { result in
            loading = false
            switch result {
            case .success:
                loadSDKStatus(); loadAvailableImages()
            case .failure(let failure):
                error = t("无法保存安装位置，请选择可写的目录后重试。",
                          "Could not save the install location. Choose a writable directory and retry.")
                    + "\n" + failure.localizedDescription
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
    private func t(_ zh: String, _ en: String) -> String { model.text(zh, en) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 22)).foregroundStyle(WbColor.accentText)
                    .frame(width: 44, height: 44)
                    .background(WbColor.accentContainer, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(showingInstallStatus ? t("安装进度", "Installation progress") : showingLicenses ? t("许可协议", "Licence agreements") : "Android SDK")
                        .font(.system(size: 18, weight: .semibold))
                    Text(t("配置模拟器工具和 Android 系统镜像。", "Set up emulator tools and Android system images."))
                        .font(.system(size: 12)).foregroundStyle(WbColor.textSecondary)
                }
                Spacer(minLength: 8)
                Text(showingInstallStatus ? "3 / 3" : showingLicenses ? "2 / 3" : "1 / 3")
                    .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(WbColor.textSecondary)
            }
            .padding(24)
            Divider()
            if showingLicenses {
                licenceContent
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if showingInstallStatus { installationContent }
                        else { configurationContent }
                        if loading { ProgressView(loadingMessage).controlSize(.small) }
                        if !error.isEmpty {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 12)).foregroundStyle(WbColor.negative).textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                }
            }
            Divider()
            footer
        }
        .frame(width: 650, height: 520)
        .font(.system(size: 13))
        .background(WbColor.surface)
        .tint(WbColor.accent)
        .onAppear {
            if model.sdkInstalling { showingInstallStatus = true; return }
            loadSDKStatus(); loadAvailableImages()
        }
        .interactiveDismissDisabled(loading)
    }

    @ViewBuilder private var configurationContent: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let existing = sdkStatus?.studio_sdk {
                    Label(t("已检测到可用的 Android SDK", "Android SDK detected"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(WbColor.positive).font(.system(size: 12, weight: .medium))
                    Text(existing).font(.system(size: 11, design: .monospaced)).foregroundStyle(WbColor.textSecondary)
                        .lineLimit(2).truncationMode(.middle).help(existing).textSelection(.enabled)
                    HStack(spacing: 8) {
                        Button(t("使用此 SDK", "Use this SDK")) { finish() }.disabled(loading)
                        Button(t("选择其他位置…", "Choose another location…"), action: chooseExistingSDK).disabled(loading)
                    }.buttonStyle(.bordered)
                } else {
                    Text(t("已有 SDK？选择包含 emulator 和 platform-tools 的目录。", "Already have an SDK? Choose its emulator and platform-tools directory."))
                        .font(.system(size: 12)).foregroundStyle(WbColor.textSecondary)
                    Button(t("选择 SDK 目录…", "Choose SDK folder…"), action: chooseExistingSDK).buttonStyle(.bordered).disabled(loading)
                }
                if !sdkStatusError.isEmpty {
                    Text(sdkStatusError).font(.system(size: 12)).foregroundStyle(WbColor.negative).textSelection(.enabled)
                    Button(t("重新检查", "Check again"), action: loadSDKStatus).buttonStyle(.link)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        } label: { Label(t("外部 Android SDK（只读，可选）", "External Android SDK (read-only, optional)"), systemImage: "folder").font(.system(size: 12, weight: .semibold)) }

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(t("系统镜像", "System image"))
                    Spacer(minLength: 16)
                    Picker(t("系统镜像", "System image"), selection: $selection) {
                        Text(t("仅安装模拟器工具", "Emulator tools only")).tag("")
                        ForEach(Array(Set(images.filter { $0.installed_in == nil }.map(\.api))).sorted(by: >), id: \.self) { api in
                            Section("Android API \(api)") {
                                ForEach(images.filter { $0.api == api && $0.installed_in == nil }.sorted {
                                    let lhs = DevicePresentation.imageOrder($0.tag)
                                    let rhs = DevicePresentation.imageOrder($1.tag)
                                    return lhs == rhs ? $0.id < $1.id : lhs < rhs
                                }) { image in
                                    Text("API \(api) · \(Device.imageTagLabel(image.tag)) · \(image.abi)").tag(image.id)
                                }
                            }
                        }
                    }.labelsHidden().frame(maxWidth: 360).disabled(loading || loadingImages)
                }
                if let location = sdkStatus?.install_sdk ?? sdkStatus?.private_sdk {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(t("安装位置：\(location)", "Install location: \(location)"))
                            .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                            .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                            .help(location)
                        HStack(spacing: 8) {
                            Button(t("更改安装位置…", "Change install location…"), action: chooseInstallLocation)
                                .disabled(loading)
                            if sdkStatus?.custom_sdk != nil {
                                Button(t("恢复默认", "Restore default"), action: restoreInstallLocation)
                                    .disabled(loading)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Text(t("新安装的 emulator 和系统镜像会保存到此目录；已有默认目录中的镜像仍可继续使用。",
                       "Newly installed emulator files and system images go to this directory; images in the existing default directory remain available."))
                    .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(t("将安装模拟器工具、ADB 和所选镜像。下一步先检查许可协议。", "Installs emulator tools, ADB and the selected image. Review licences before installation."))
                    .font(.system(size: 12)).foregroundStyle(WbColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                if loadingImages {
                    ProgressView(t("正在读取镜像列表…", "Loading system images…")).controlSize(.small)
                } else if !imageError.isEmpty {
                    Text(imageError).font(.system(size: 12)).foregroundStyle(WbColor.negative).textSelection(.enabled)
                    Button(t("重新读取镜像", "Retry images"), action: loadAvailableImages).buttonStyle(.link)
                } else if images.allSatisfy({ $0.installed_in != nil }) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(t("暂无可下载的镜像，可以只安装工具。", "No downloadable images are available. You can still install tools."))
                            .font(.system(size: 12)).foregroundStyle(WbColor.textSecondary)
                        Spacer(minLength: 0)
                        Button(t("刷新", "Refresh"), action: loadAvailableImages).buttonStyle(.link)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        } label: { Label(t("安装或更新组件", "Install or update components"), systemImage: "arrow.down.circle").font(.system(size: 12, weight: .semibold)) }
    }

    private var licenceContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if licenses.isEmpty {
                Label(t("所选组件没有需要接受的新许可。", "The selected components have no new licences to accept."), systemImage: "checkmark.circle")
                    .foregroundStyle(WbColor.textSecondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(licenses) { license in
                            Text(license.id).font(.system(size: 13, weight: .semibold))
                            Text(license.text).font(.system(size: 12)).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
                }
                .background(WbColor.raised, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WbColor.borderDefault))
                Toggle(t("我已阅读并同意上述许可协议", "I have read and agree to the licences above"), isOn: $reviewed).disabled(loading)
            }
            if loading { ProgressView(loadingMessage).controlSize(.small) }
            if !error.isEmpty { Text(error).font(.system(size: 12)).foregroundStyle(WbColor.negative).textSelection(.enabled) }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var installationContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.sdkInstalling {
                if let fraction = model.sdkInstallFraction {
                    ProgressView(value: fraction) { Text(model.sdkInstallMessage).font(.system(size: 13)) }
                    Text(t("当前步骤 \(Int(fraction * 100))%", "Current step \(Int(fraction * 100))%"))
                        .font(.system(size: 12)).foregroundStyle(WbColor.textSecondary)
                } else { ProgressView(model.sdkInstallMessage).controlSize(.small) }
                Text(t("可在后台继续。退出前请等待安装或取消完成。", "You can continue in the background. Wait for installation or cancellation before quitting."))
                    .font(.system(size: 12)).foregroundStyle(WbColor.textSecondary)
            } else {
                Label(model.sdkInstallMessage, systemImage: model.sdkInstallSucceeded == false ? "exclamationmark.triangle" : "checkmark.circle")
            }
            if let message = model.sdkInstallError { Text(message).font(.system(size: 12)).foregroundStyle(WbColor.negative).textSelection(.enabled) }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if showingLicenses, !loading {
                Button(t("返回", "Back")) { showingLicenses = false; reviewed = false }
            }
            Spacer()
            if showingInstallStatus {
                if model.sdkInstalling {
                    Button(model.sdkCancelPending ? t("正在取消…", "Cancelling…") : t("取消安装", "Cancel installation")) { model.cancelSDKInstall() }
                        .disabled(model.sdkInstallJob == nil || model.sdkCancelPending)
                    Button(t("后台运行", "Run in background")) { finish() }.keyboardShortcut(.cancelAction)
                } else {
                    if model.sdkInstallSucceeded == false { Button(t("重新选择并重试", "Choose and retry"), action: retrySetup) }
                    Button(t("完成", "Done")) { finish() }.keyboardShortcut(.cancelAction)
                }
            } else {
                Button(t("取消", "Cancel")) { finish() }.disabled(loading).keyboardShortcut(.cancelAction)
                Button(showingLicenses ? (licenses.isEmpty ? t("安装", "Install") : t("同意并安装", "Agree and install")) : t("继续", "Continue")) {
                    if showingLicenses {
                        loading = true; error = ""; loadingMessage = t("正在确认许可…", "Confirming licences…"); accept(0)
                    } else { prepare() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(loading || (showingLicenses && !licenses.isEmpty && !reviewed))
                .keyboardShortcut(.defaultAction)
            }
        }
        .buttonStyle(.bordered).controlSize(.regular)
        .padding(.horizontal, 24).padding(.vertical, 16)
        .background(WbColor.chrome)
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

    func applyProfile(_ id: String) {
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

    private var creation: DeviceCreation {
        DeviceCreation(name: name, image: image, profile: profile, ram: ram, cpus: cpus,
                       storage: storage, root: root, audio: audio)
    }

    var body: some View {
        ZStack {
            creationForm.opacity(installing ? 0 : 1)
                .allowsHitTesting(!installing).accessibilityHidden(installing).disabled(installing)
            if installing {
                InstallSDKView(model: model, onClose: { installing = false; loadImages() })
                    .background(WbColor.raised)
            }
        }
        .frame(width: installing ? 650 : 520, height: 520)
    }
    private var creationForm: some View {
        VStack(spacing: 0) {
            DeviceSheetHeader(title: model.text("添加设备", "Add device"),
                              subtitle: model.text("选择已经安装的系统镜像和硬件配置。", "Choose an installed system image and hardware profile."))
            Form {
                Section(model.text("基础配置", "Basic configuration")) {
                    LabeledContent(model.text("设备名称", "Device name")) {
                        TextField(model.text("例如：Pixel 9 Pro", "e.g. Pixel 9 Pro"), text: $name)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .frame(width: 220)
                            .disabled(saving)
                            .accessibilityLabel(model.text("设备名称", "Device name"))
                    }
                    LabeledContent(model.text("系统镜像", "System image")) {
                        Picker("", selection: $image) {
                            Text(model.text("请选择", "Select")).tag("")
                            ForEach(images) { item in
                                Text("Android API \(item.api) · \(Device.imageTagLabel(item.tag))").tag(item.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        .accessibilityLabel(model.text("系统镜像", "System image"))
                    }
                    LabeledContent(model.text("硬件配置", "Hardware profile")) {
                        Picker("", selection: $profile) {
                            Text(model.text("请选择", "Select")).tag("")
                            ForEach(profiles) { item in Text(item.name).tag(item.id) }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        .onChange(of: profile) { value in applyProfile(value) }
                        .accessibilityLabel(model.text("硬件配置", "Hardware profile"))
                    }
                    LabeledContent(model.text("Root 模式", "Root mode")) {
                        Picker("", selection: $root) {
                            Text(model.text("无", "None")).tag("none")
                            Text("Shell Root").tag("adb")
                            Text(model.text("完整 Root", "Full Root")).tag("magisk")
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        .disabled(saving)
                        .accessibilityLabel(model.text("Root 模式", "Root mode"))
                    }
                    if root == "magisk" {
                        Text(model.text("创建后将下载并配置 Magisk，期间设备会启动并重启。", "After creation Magisk is downloaded and configured; the device starts and reboots in the process."))
                            .wbFont(WbType.caption)
                            .foregroundStyle(WbColor.textSecondary)
                    }
                }

                Section {
                    DisclosureGroup(model.text("高级配置", "Advanced configuration"), isExpanded: $showAdvanced) {
                        LabeledContent(model.text("内存 (MB)", "Memory (MB)")) {
                            numberField($ram, label: model.text("内存 (MB)", "Memory (MB)"))
                        }
                        LabeledContent(model.text("CPU 核心数", "CPU cores")) {
                            numberField($cpus, label: model.text("CPU 核心数", "CPU cores"))
                        }
                        LabeledContent(model.text("设备存储 (GB)", "Device storage (GB)")) {
                            numberField($storage, label: model.text("设备存储 (GB)", "Device storage (GB)"))
                        }
                        Toggle(model.text("设备声音", "Device audio"), isOn: $audio)
                            .toggleStyle(.switch)
                            .tint(WbColor.accent)
                    }
                }

                if images.isEmpty {
                    Section {
                        HStack(alignment: .top, spacing: WbSpace.sm) {
                            Image(systemName: WbIcon.info)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(WbColor.textTertiary)
                                .padding(.top, 1)
                            Text(model.text("没有找到已安装的系统镜像。", "No installed system images were found."))
                                .wbFont(WbType.caption)
                                .foregroundStyle(WbColor.textSecondary)
                        }
                    }
                }

                Section {
                    Button(model.text("安装 SDK 和系统镜像…", "Install SDK & system images…")) { installing = true }
                        .buttonStyle(.bordered).controlSize(.regular)
                        .disabled(saving)
                }

                if !error.isEmpty {
                    Section {
                        Text(error)
                            .wbFont(WbType.caption)
                            .foregroundStyle(WbColor.negative)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(WbColor.raised)

            DeviceSheetFooter(note: model.text("创建后可随时在设备设置中调整。", "You can adjust these settings after creating the device.")) {
                Button(model.text("取消", "Cancel")) { dismiss() }
                    .buttonStyle(.bordered).controlSize(.regular)
                    .disabled(saving)
                    .keyboardShortcut(.cancelAction)
                Button(model.text("创建", "Create")) { create() }
                    .buttonStyle(.borderedProminent).controlSize(.regular).tint(WbColor.accent)
                    .disabled(saving || !creation.isValid || images.isEmpty || profiles.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 520, height: 520)
        .background(WbColor.raised)
        .onAppear {
            if name.isEmpty {
                var number = 1
                while model.devices.contains(where: { $0.name == model.text("我的安卓手机 \(number)", "My Android phone \(number)") }) { number += 1 }
                name = model.text("我的安卓手机 \(number)", "My Android phone \(number)")
            }
            model.call("profile.list") { result in
                do { profiles = try model.decode(result.get(),as:[HardwareProfile].self); profile = profiles.first?.id ?? "" }
                catch { self.error = error.localizedDescription }
            }
            model.call("settings.get") { result in
                if let data = try? result.get(), let value = try? model.decode(data,as:DaemonSettings.self) { root = value.default_root_mode }
            }
            loadImages()
        }
    }

    private func numberField(_ value: Binding<String>, label: String) -> some View {
        TextField("", text: value)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 110)
            .accessibilityLabel(label)
    }

    private func create() {
        let parameters: [String:Any]
        do { parameters = try creation.parameters() }
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
    }
}

struct ToolPaths: Decodable { let android_sdk: String?; let jidr_sdk: String? }
struct CenterPaths: Decodable { let data: String; let cache: String; let logs: String; let tools: ToolPaths }
struct DaemonSettings: Decodable {
    let default_root_mode: String
    let quick_boot: Bool
    let budget_percent: UInt8
    let auto_hibernate_minutes: UInt32
}
struct SDKStatus: Decodable {
    let tools_sdk: String?
    let studio_sdk: String?
    let private_sdk: String?
    /// Writable SDK that Jidr installs into (custom root or the private SDK).
    let install_sdk: String?
    /// Set only when the user selected a custom writable install root.
    let custom_sdk: String?
}
struct CacheEntry: Decodable { let size: UInt64 }
struct AboutInfo: Decodable { let version: String; let repository: String }
struct SettingsView: View {
    @ObservedObject var model: CenterModel
    let onClose: () -> Void
    private var category: Int { model.settingsCategory }
    @State private var tileURL = ""
    @State private var mcpBinary = "jidr"
    @State private var confirmClaudeConfig = false
    @State private var paths: CenterPaths?
    @State private var sdkStatus: SDKStatus?
    @State private var policy = DevicePolicyDraft(root: "none", quickBoot: true, budget: "80", idleMinutes: "0")
    @State private var savedPolicy: DevicePolicyDraft?
    private var policyDirty: Bool { savedPolicy != nil && policy != savedPolicy }
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
                policy = DevicePolicyDraft(root: value.default_root_mode, quickBoot: value.quick_boot,
                                           budget: String(value.budget_percent), idleMinutes: String(value.auto_hibernate_minutes))
                savedPolicy = policy
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
            switch result {
            case .success:
                message = model.text("外部 Android SDK 路径已保存，下次启动设备时生效。", "External Android SDK path saved; it will apply on the next device start.")
                load()
            case .failure(let failure): message = failure.localizedDescription
            }
        }
    }
    func chooseJidrSDKLocation() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = model.text("选择安装位置", "Choose install location")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setJidrSDKLocation(url.path)
    }
    func restoreJidrSDKLocation() { setJidrSDKLocation(NSNull()) }
    private func setJidrSDKLocation(_ path:Any) {
        guard !saving else { return }; saving = true
        model.call("center.toolpath.set",["kind":"jidr_sdk","path":path]) { result in
            saving = false
            switch result {
            case .success:
                message = model.text("Jidr SDK 安装位置已保存。", "Jidr SDK install location saved.")
                load()
            case .failure(let failure): message = failure.localizedDescription
            }
        }
    }
    func choose(_ kind:String) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tool(kind,path:url.path)
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
        settingsContent
        .frame(minWidth: 640, minHeight: 340)
        .preferredColorScheme(model.colorScheme)
        .environment(\.locale, Locale(identifier: model.language == 0 ? "en" : "zh-Hans"))
        .background(WbColor.surface)
        .onExitCommand { if !saving { onClose() } }
        .onAppear(perform:load)
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

    // MARK: - Preference panes (navigation is the native window toolbar)

    private var settingsContent: some View {
        Group {
            if category == 0 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        GroupBox {
                            HStack {
                                Text(model.text("语言", "Language"))
                                Spacer()
                                Picker(model.text("语言", "Language"), selection: Binding(get: { model.language }, set: { model.setPreference("language", $0) })) {
                                    Text("中文").tag(1)
                                    Text("English").tag(0)
                                }
                                .labelsHidden().frame(width: 180)
                            }
                            .padding(10)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            Text(model.text("外观", "Appearance")).font(.system(size: 13, weight: .semibold))
                            AppearancePreviewCard(model: model)
                            Text(model.text("选择跟随系统时，外观会随 macOS 自动切换。", "With System selected, appearance changes automatically with macOS."))
                                .font(.system(size: 12)).foregroundStyle(WbColor.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text(model.text("更改会立即生效。", "Changes take effect immediately."))
                            .font(.system(size: 12)).foregroundStyle(WbColor.textSecondary)
                    }
                    .frame(maxWidth: 600, alignment: .leading)
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            } else {
                Form {
                    switch category {
                    case 1: defaultsPage
                    case 2: dataPage
                    case 3: advancedPage
                    default: aboutPage
                    }
                    if !message.isEmpty {
                        Section { Text(message).font(.system(size: 12)).foregroundStyle(WbColor.textSecondary).textSelection(.enabled) }
                    }
                }
                .formStyle(.grouped)
                .disabled(saving)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Actual appearance choices, including System. The thumbnail colours are
    /// fixed; only surrounding labels and selection follow the current theme.
    struct AppearancePreviewCard: View {
        @ObservedObject var model: CenterModel
        var body: some View {
            HStack(alignment: .top, spacing: 16) {
                option(0, title: model.text("跟随系统", "System"))
                option(1, title: model.text("浅色", "Light"))
                option(2, title: model.text("深色", "Dark"))
            }
        }
        private func option(_ mode: Int, title: String) -> some View {
            Button { model.setPreference("appearance", mode) } label: {
                VStack(spacing: 9) {
                    GeometryReader { geometry in
                        ZStack(alignment: .topLeading) {
                            HStack(spacing: 0) {
                                Rectangle().fill(mode == 2 ? JidrColor.surfaceRaised.dark : JidrColor.surfaceRaised.light)
                                if mode == 0 { Rectangle().fill(JidrColor.surfaceRaised.dark) }
                            }
                            HStack(spacing: 0) {
                                Rectangle().fill(mode == 2 ? JidrColor.surfaceChrome.dark : JidrColor.surfaceChrome.light)
                                    .frame(width: geometry.size.width * 0.28)
                                VStack(alignment: .leading, spacing: 7) {
                                    Capsule().fill(mode == 2 ? JidrColor.textSecondary.dark : JidrColor.textSecondary.light).frame(width: 36, height: 4)
                                    Capsule().fill(mode == 2 ? JidrColor.borderStrong.dark : JidrColor.borderStrong.light).frame(width: 52, height: 4)
                                    Capsule().fill(mode == 2 ? JidrColor.borderStrong.dark : JidrColor.borderStrong.light).frame(width: 44, height: 4)
                                    Spacer(minLength: 0)
                                }.padding(12)
                                Spacer(minLength: 0)
                            }.padding(.top, 16)
                            HStack(spacing: 3) {
                                ForEach(0..<3, id: \.self) { _ in Circle().fill(JidrColor.textSecondary.light.opacity(0.5)).frame(width: 4, height: 4) }
                            }.padding(6)
                            RoundedRectangle(cornerRadius: 3).fill(WbColor.accent).frame(width: 22, height: 5).offset(x: 6, y: 27)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(model.appearance == mode ? WbColor.accent : WbColor.borderStrong, lineWidth: model.appearance == mode ? 2 : 1))
                    }.frame(height: 82)
                    HStack(spacing: 5) {
                        Image(systemName: model.appearance == mode ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(model.appearance == mode ? WbColor.accent : WbColor.textSecondary)
                        Text(title).foregroundStyle(WbColor.textPrimary)
                    }.font(.system(size: 12))
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(title)
            .accessibilityValue(model.appearance == mode ? model.text("已选择", "Selected") : model.text("未选择", "Not selected"))
        }
    }

    // MARK: - Device defaults

    @ViewBuilder private var defaultsPage: some View {
        Section(model.text("新设备默认值", "Defaults for new devices")) {
            Picker(selection: $policy.root) {
                Text(model.text("无", "None")).tag("none")
                Text("Shell Root").tag("adb")
                Text(model.text("完整 Root", "Full Root")).tag("magisk")
            } label: {
                Text(model.text("默认 Root 模式", "Default root mode"))
            }
            Text(model.text("默认 Root 模式仅用于之后创建的设备。", "The default Root mode applies only to devices created later."))
                .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
        }
        Section(model.text("全局运行策略", "Global device policies")) {
            Toggle(model.text("停止设备时保存快速启动快照", "Save quick-boot snapshot when stopping"), isOn: $policy.quickBoot)
                .toggleStyle(.switch)
                .tint(WbColor.accent)
            LabeledContent {
                TextField("", text: $policy.budget)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 92)
                    .accessibilityLabel(model.text("模拟器总内存预算 (%)", "Total emulator memory budget (%)"))
            } label: {
                Text(model.text("模拟器总内存预算 (%)", "Total emulator memory budget (%)"))
            }
            LabeledContent {
                TextField("", text: $policy.idleMinutes)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 92)
                    .accessibilityLabel(model.text("自动休眠（分钟）", "Idle sleep (minutes)"))
            } label: {
                Text(model.text("自动休眠（分钟）", "Idle sleep (minutes)"))
            }
            if loaded && policy.parameters == nil {
                Label(model.text("内存预算须为 10–100%，休眠分钟数须为非负整数。", "Use a 10–100% budget and a nonnegative whole number of idle minutes."), systemImage: WbIcon.warning)
                    .wbFont(WbType.caption).foregroundStyle(WbColor.negative)
            }
            Text(model.text("内存预算占 Mac 总内存的 10–100%，用于所有设备的合计预算。自动休眠 0 为关闭。", "The combined device budget is 10–100% of your Mac’s RAM. Idle sleep 0 disables it."))
                .wbFont(WbType.caption)
                .foregroundStyle(WbColor.textSecondary)
        }
        Section {
            HStack(alignment: .center, spacing: WbSpace.md) {
                Text(model.text("快速启动和休眠策略也适用于未单独覆盖设置的已有设备。", "Quick boot and idle sleep also apply to existing devices that follow global settings."))
                    .wbFont(WbType.caption)
                    .foregroundStyle(WbColor.textSecondary)
                Spacer(minLength: WbSpace.sm)
                if policyDirty {
                    Text(model.text("有未保存的更改", "Unsaved changes"))
                        .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                }
                Button(model.text("保存设置", "Save settings")) {
                    guard let parameters = policy.parameters else {
                        message = model.text("内存预算必须为 10–100%，自动休眠时间必须为非负整数。", "Memory budget must be 10–100%; idle sleep must be a nonnegative integer."); return
                    }
                    let submittedPolicy = policy
                    saving = true
                    model.call("settings.set", parameters) { result in
                        saving = false
                        switch result {
                        case .success: savedPolicy = submittedPolicy; message = model.text("设置已保存。", "Settings saved.")
                        case .failure(let failure): message = failure.localizedDescription
                        }
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.regular).tint(WbColor.accent)
                .disabled(!loaded || saving || !policyDirty || policy.parameters == nil)
            }
        }
    }

    // MARK: - Data and tools

    @ViewBuilder private var dataPage: some View {
        Section(model.text("Jidr SDK（可写安装位置）", "Jidr SDK (writable install location)")) {
            SettingsPathRow(title: model.text("安装位置", "Install location"),
                            path: installSDKPath ?? model.text("读取中…", "Loading…")) {
                Button(model.text("更改位置…", "Change location…"), action: chooseJidrSDKLocation)
                    .buttonStyle(.bordered).controlSize(.regular)
                    .disabled(saving)
                if sdkStatus?.custom_sdk != nil {
                    Button(model.text("恢复默认", "Restore default"), action: restoreJidrSDKLocation)
                        .buttonStyle(.bordered).controlSize(.regular)
                        .disabled(saving)
                }
                linkButton(model.text("显示目录", "Show folder"), disabled: installSDKPath == nil) {
                    showFolder(installSDKPath)
                }
                Spacer(minLength: 0)
                Button(model.text("安装 SDK 和系统镜像…", "Install SDK & system images…")) { installing = true }
                    .buttonStyle(.bordered).controlSize(.regular)
                    .disabled(saving)
            }
            Text(model.text("新安装的 emulator 和系统镜像会保存到此目录；已有默认目录中的镜像仍可继续使用。",
                            "Newly installed emulator files and system images go to this directory; images in the existing default directory remain available."))
                .wbFont(WbType.caption)
                .foregroundStyle(WbColor.textSecondary)
        }
        Section(model.text("外部 Android SDK（只读）", "External Android SDK (read-only)")) {
            SettingsPathRow(title: model.text("外部 Android SDK", "External Android SDK"),
                            path: paths?.tools.android_sdk ?? sdkStatus?.studio_sdk ?? model.text("自动选择", "Automatic")) {
                Button(model.text("选择 SDK", "Choose SDK")) { choose("sdk") }
                    .buttonStyle(.bordered).controlSize(.regular)
                    .disabled(paths == nil || saving)
                Button(model.text("恢复自动选择", "Restore automatic")) { tool("sdk",path:NSNull()) }
                    .buttonStyle(.bordered).controlSize(.regular).disabled(paths == nil || saving)
                linkButton(model.text("显示目录", "Show folder"), disabled: paths?.tools.android_sdk == nil && sdkStatus?.studio_sdk == nil) {
                    showFolder(paths?.tools.android_sdk ?? sdkStatus?.studio_sdk)
                }
            }
            Text(model.text("选择路径后立即生效。Jidr 只读取此 SDK，不会修改其中的文件。",
                            "Jidr only reads this SDK; it never installs into or modifies it."))
                .wbFont(WbType.caption)
                .foregroundStyle(WbColor.textSecondary)
        }
        Section(model.text("存储", "Storage")) {
            SettingsPathRow(title: model.text("数据目录", "Data folder"),
                            path: paths?.data ?? model.text("读取中…", "Loading…")) {
                Button(model.text("显示数据目录", "Show data folder")) { showFolder(paths?.data) }
                    .buttonStyle(.bordered).controlSize(.regular)
                    .disabled(paths == nil)
            }
            HStack(alignment: .center, spacing: WbSpace.md) {
                Text(storageSummary)
                    .wbFont(WbType.body)
                    .foregroundStyle(WbColor.textSecondary)
                    .lineLimit(2)
                Spacer(minLength: WbSpace.sm)
                Button(model.text("清理下载缓存…", "Clear download cache…")) { confirmCacheClear = true }
                    .buttonStyle(.bordered).controlSize(.regular)
                    .disabled(saving || cacheBytes == nil || cacheBytes == 0)
            }
        }
    }

    private var installSDKPath: String? { sdkStatus?.install_sdk ?? sdkStatus?.private_sdk }

    private var storageSummary: String {
        let images = imageCount.map(String.init) ?? "…"
        let cache = cacheBytes.map { ByteCountFormatter.string(fromByteCount:Int64(clamping:$0),countStyle:.file) } ?? "…"
        let usedBytes = deviceUsage.values.reduce(UInt64(0)) { total, bytes in
            let (sum, overflow) = total.addingReportingOverflow(bytes)
            return overflow ? UInt64.max : sum
        }
        let used = deviceUsage.isEmpty ? "—" : ByteCountFormatter.string(fromByteCount:Int64(clamping:usedBytes),countStyle:.file)
        return model.text("已安装镜像 \(images) · 下载缓存 \(cache) · 设备占用 \(used)",
                          "\(images) images · \(cache) cache · \(used) devices")
    }

    // MARK: - Advanced

    @ViewBuilder private var advancedPage: some View {
        Section(model.text("地图", "Maps")) {
            LabeledContent {
                TextField("", text: $tileURL, prompt: Text(model.text("默认地图服务", "Default map provider")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 260)
                    .accessibilityLabel(model.text("地图瓦片地址", "Map tile URL"))
            } label: {
                Text(model.text("地图瓦片地址", "Map tile URL"))
            }
            Text(model.text("留空使用默认服务商。须使用 HTTPS 并包含 {z}、{x}、{y}。打开地图时，服务商会收到请求。",
                            "Empty uses the default provider. Use HTTPS and include {z}, {x}, {y}; the provider receives requests when the map is opened."))
                .wbFont(WbType.caption)
                .foregroundStyle(WbColor.textSecondary)
            HStack(spacing: WbSpace.sm) {
                Spacer(minLength: 0)
                Button(model.text("保存地图设置", "Save map settings")) {
                    saving = true
                    model.call("center.prefs.set",["tile_url":tileURL]) { result in
                        saving = false
                        switch result {
                        case .success: model.tileURL = tileURL; message = model.text("地图设置已保存。", "Map settings saved.")
                        case .failure(let error): message = error.localizedDescription.contains("Map tile URL must") ? model.text("地图地址必须使用 HTTPS，并包含 {z}、{x} 和 {y}。", "Map tile URL must use HTTPS and contain {z}, {x} and {y}.") : error.localizedDescription
                        }
                    }
                }
                .buttonStyle(.bordered).controlSize(.regular)
                .disabled(saving)
            }
        }
        Section("MCP") {
            LabeledContent {
                TextField("", text: $mcpBinary, prompt: Text("jidr"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .frame(width: 260)
                    .accessibilityLabel(model.text("MCP 命令路径", "MCP command path"))
            } label: {
                Text(model.text("MCP 命令路径", "MCP command path"))
            }
            Text(model.text("可填写 jidr 可执行文件的绝对路径。将以下配置添加到支持 MCP 的客户端。",
                            "Absolute path to the jidr executable. Add this configuration to your MCP client."))
                .wbFont(WbType.caption)
                .foregroundStyle(WbColor.textSecondary)
            HStack(spacing: WbSpace.sm) {
                Spacer(minLength: 0)
                Button(model.text("配置 Claude Desktop…", "Configure Claude Desktop…")) { confirmClaudeConfig = true }
                    .buttonStyle(.bordered).controlSize(.regular)
                    .disabled(saving)
                Button(model.text("复制 MCP 配置", "Copy MCP configuration")) {
                    guard !mcpBinary.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, let data = try? JSONSerialization.data(withJSONObject:["mcpServers":["jidr":["command":mcpBinary,"args":["mcp"]]]],options:[.prettyPrinted,.sortedKeys]), let text = String(data:data,encoding:.utf8) else { return }
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string)
                    message = model.text("MCP 配置已复制。", "MCP configuration copied.")
                }
                .buttonStyle(.bordered).controlSize(.regular)
            }
        }
    }

    // MARK: - About

    @ViewBuilder private var aboutPage: some View {
        Section(model.text("关于", "About")) {
            VStack(spacing: WbSpace.xs + 2) {
                appIcon
                Text("Jidr")
                    .wbFont(WbType.headline)
                    .foregroundStyle(WbColor.textPrimary)
                Text(model.text("安卓模拟器 · 版本 \(about?.version ?? "—")", "Android emulator · version \(about?.version ?? "—")"))
                    .wbFont(WbType.caption)
                    .foregroundStyle(WbColor.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, WbSpace.sm)
            HStack(spacing: WbSpace.sm) {
                Button(model.text("检查更新", "Check for updates")) { checkUpdate() }
                    .buttonStyle(.borderedProminent).controlSize(.regular).tint(WbColor.accent)
                    .disabled(checkingUpdate || about == nil)
                if let releaseURL {
                    Button(model.text("查看新版本", "View new version")) { NSWorkspace.shared.open(releaseURL) }
                        .buttonStyle(.bordered).controlSize(.regular)
                }
                Button(model.text("源代码", "Source code")) {
                    if let value = about?.repository, let url = URL(string:value) { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.bordered).controlSize(.regular)
                .disabled(about == nil)
                Button(model.text("许可证", "Licenses")) {
                    if let value = about?.repository, let url = URL(string:value + "/blob/master/NOTICE") { NSWorkspace.shared.open(url) }
                }
                .buttonStyle(.bordered).controlSize(.regular)
                .disabled(about == nil)
                Spacer(minLength: 0)
            }
            if !updateMessage.isEmpty {
                Text(updateMessage)
                    .wbFont(WbType.caption)
                    .foregroundStyle(WbColor.textSecondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private var appIcon: some View {
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") != nil,
           let icon = NSApp.applicationIconImage {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(WbColor.accentContainer)
                .frame(width: 64, height: 64)
                .overlay(
                    Image(systemName: WbIcon.deviceEmpty)
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(WbColor.textSecondary)
                )
        }
    }

    // MARK: - Small helpers

    private func linkButton(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .wbFont(WbType.label.weighted(.medium))
                .foregroundStyle(disabled ? WbColor.textDisabled : WbColor.accentText)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// A labelled path row used by Settings → Data & tools: title, monospaced path
/// and a row of native actions underneath.
private struct SettingsPathRow<Actions: View>: View {
    var title: String
    var path: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: WbSpace.xs + 1) {
            Text(title)
                .wbFont(WbType.body)
                .foregroundStyle(WbColor.textPrimary)
            Text(path)
                .wbFont(WbType.code)
                .foregroundStyle(WbColor.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            HStack(spacing: WbSpace.sm) {
                actions()
            }
            .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, WbSpace.xs)
    }
}


// MARK: - Device center

/// Quiet centred state used by the device/detail/app cards (loading, empty,
/// disconnected) instead of ad-hoc ProgressViews.
private struct CenterQuietState: View {
    var icon: String
    var text: String
    var height: CGFloat = 120
    var showsProgress = false

    var body: some View {
        VStack(spacing: WbSpace.sm) {
            if showsProgress { ProgressView().controlSize(.small) }
            else {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(WbColor.textTertiary)
            }
            Text(text)
                .wbFont(WbType.body)
                .foregroundStyle(WbColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .padding(.horizontal, WbSpace.lg)
    }
}

/// AppKit keeps attributed menu titles, unlike SwiftUI's native Menu bridge.
struct DeviceMoreButton: NSViewRepresentable {
    @ObservedObject var model: CenterModel
    let device: Device

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(frame: .zero)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        return button
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.identifier = NSUserInterfaceItemIdentifier("jidr-device-more:\(device.id)")
        button.toolTip = model.text("更多设备操作", "More device actions")
        button.setAccessibilityLabel(model.text("更多设备操作：\(device.name)", "More actions for \(device.name)"))
    }

    final class Coordinator: NSObject {
        var parent: DeviceMoreButton
        init(_ parent: DeviceMoreButton) { self.parent = parent }
        @objc func showMenu(_ button: NSButton) {
            menu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
        }
        func menu() -> NSMenu {
            let model = parent.model, device = parent.device
            let menu = NSMenu()
            menu.autoenablesItems = false
            func add(_ zh: String, _ en: String, _ tag: Int, enabled: Bool = true, destructive: Bool = false) {
                let item = NSMenuItem(title: model.text(zh, en), action: #selector(performAction(_:)), keyEquivalent: "")
                item.target = self; item.tag = tag; item.isEnabled = enabled
                let symbols = [6: "shield", 12: "arrow.clockwise", 13: "trash"]
                if let symbol = symbols[tag] {
                    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                    item.image?.isTemplate = true
                    #if compiler(>=6.4)
                    if #available(macOS 27.0, *) {
                        item.preferredImageVisibility = .visible
                    }
                    #endif
                }
                if destructive && enabled {
                    item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.systemRed])
                }
                menu.addItem(item)
            }
            if !device.stopped && model.fullRoot[device.id] != nil { add("查看 Root 配置", "View root setup", 6) }
            if !device.stopped {
                add("重启", "Restart", 12, enabled: device.running && !model.busy.contains(device.id))
            }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            add("删除设备", "Delete device", 13, enabled: device.stopped && !model.busy.contains(device.id), destructive: true)
            return menu
        }
        @objc func performAction(_ item: NSMenuItem) {
            let model = parent.model, device = parent.device
            switch item.tag {
            case 6: model.rootPresentation = RootPresentation(id: device.id, name: device.name)
            case 12: model.restart(device.id)
            case 13: model.requestDeletion(device.id)
            default: break
            }
        }
    }
}

private struct CenterStatusDot: View {
    let tone: WbStatusTone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var glowing = false
    var body: some View {
        Circle().fill(tone.color).frame(width: 7, height: 7)
            .shadow(color: tone == .running ? tone.color.opacity(glowing ? 0.5 : 0.15) : .clear,
                    radius: glowing ? 4 : 1)
            .onAppear {
                if tone == .running && !reduceMotion {
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { glowing = true }
                }
            }
    }
}

private struct CenterAPKDrop: ViewModifier {
    @ObservedObject var model: CenterModel
    @State private var droppedAPK: URL?
    @State private var choosingDevice = false

    func body(content: Content) -> some View {
        content
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil, perform: receive)
            .confirmationDialog(model.text("选择要安装应用的设备", "Choose a device to install the app"),
                                isPresented: $choosingDevice) {
                ForEach(model.devices.filter(\.running)) { device in
                    Button(device.name) { install(device.id) }.disabled(model.busy.contains(device.id))
                }
                Button(model.text("取消", "Cancel"), role: .cancel) { droppedAPK = nil }
            } message: { Text(droppedAPK?.lastPathComponent ?? "") }
    }

    private func install(_ id: String) {
        if let url = droppedAPK { model.operation("file.install", id: id, params: ["apk": url.path, "replace": true]) }
        droppedAPK = nil
    }

    private func receive(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            DispatchQueue.main.async {
                guard let url, url.isFileURL, url.pathExtension.lowercased() == "apk" else {
                    model.showError(model.text("请选择 APK 安装包。", "Choose an APK file.")); return
                }
                guard model.devices.contains(where: \.running) else {
                    model.showError(model.text("请先启动设备，再安装应用。", "Start a device before installing an app.")); return
                }
                let running = model.devices.filter(\.running)
                droppedAPK = url
                if running.count == 1, let device = running.first {
                    if model.busy.contains(device.id) {
                        droppedAPK = nil
                        model.showError(model.text("设备正忙，请稍后安装应用。", "The device is busy. Try installing the app again shortly."))
                    } else { install(device.id) }
                } else { choosingDevice = true }
            }
        }
        return true
    }
}

struct CenterView: View {
    @ObservedObject var model: CenterModel
    @State private var appsPresented = false
    private var centerSurface: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor.windowBackgroundColor : NSColor(srgbRed: 245/255, green: 245/255, blue: 247/255, alpha: 1)
        })
    }

    var selectedDevice: Device? { model.devices.first(where: {$0.id == model.selected}) }
    private var filteredDevices: [Device] {
        model.filteredDevices
    }

    // MARK: Body

    var body: some View {
        let base = ZStack {
            GeometryReader { _ in
                VStack(spacing: WbSpace.zero) {
                    if ProcessInfo.processInfo.environment["JIDR_UI_PREVIEW"] == "1" {
                        Label(model.text("界面预览 · 测试设备，未连接真实模拟器", "UI preview · Test devices; no real emulator connected"), systemImage: "eye")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, WbSpace.lg).padding(.vertical, WbSpace.sm)
                    }
                    if !model.connection.isOnline {
                        ConnectionStatusPill(model: model).padding(.horizontal, WbSpace.lg).padding(.top, WbSpace.sm)
                    }
                    layout
                    if model.isEmptyDeviceLibrary, let toast = model.toast {
                        ToastOverlay(toast: toast) { model.dismissToast() }
                    }
                    if !model.notice.isEmpty {
                        HStack(alignment: .top, spacing: WbSpace.sm) {
                            Label(model.displayNotice, systemImage: WbIcon.info)
                                .wbFont(WbType.caption).textSelection(.enabled)
                            Spacer(minLength: WbSpace.sm)
                            Button { model.notice = "" } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(model.text("关闭提示", "Dismiss message"))
                        }
                        .foregroundStyle(WbColor.textSecondary)
                        .padding(.horizontal, WbSpace.lg)
                        .padding(.bottom, WbSpace.sm)
                    }
                }
                .background(centerSurface)
            }
        }
        .frame(minWidth:800,minHeight:550)
        .background { Rectangle().fill(.ultraThinMaterial).ignoresSafeArea(.container, edges: .top) }
        .background(CenterWindowChrome(model: model).frame(width: 0, height: 0))
        .environment(\.locale, Locale(identifier:model.language == 0 ? "en" : "zh-Hans"))
        .preferredColorScheme(model.colorScheme)
        return base
        .onChange(of: model.isEmptyDeviceLibrary) { empty in
            if empty { model.deviceQuery = "" }
        }
        .onChange(of:model.paletteOpen) { open in
            if !open, model.sheet == nil, !model.tasksOpen { model.searchFocusRequest += 1 }
        }
        .onChange(of:model.tasksOpen) { open in
            if !open, model.sheet == nil, !model.paletteOpen { model.searchFocusRequest += 1 }
        }
        .modifier(CenterAPKDrop(model: model))
        .sheet(item:$model.sheet) { sheet in
            Group {
                switch sheet {
                case .newDevice: NewDeviceView(model:model)
                case .setupSDK: InstallSDKView(model:model)
                case .settings: EmptyView() // Routed to the independent settings window.
                case .snapshots:
                    if let device = selectedDevice { SnapshotsView(model:model, device:device) }
                    else { Text("请选择设备") }
                case .edit:
                    if let details = model.details { EditDeviceView(model:model,details:details) }
                    else { ProgressView(model.text("正在读取设备详情…", "Loading device details…")) }
                }
            }.environment(\.locale, Locale(identifier:model.language == 0 ? "en" : "zh-Hans"))
        }
        .sheet(isPresented: $appsPresented) {
            VStack(spacing: 0) {
                appsCard
                WbDivider()
                HStack {
                    Spacer()
                    Button(model.text("完成", "Done")) { appsPresented = false }
                        .keyboardShortcut(.cancelAction)
                }.padding(WbSpace.lg)
            }
            .frame(width: 560, height: 480)
        }
        .sheet(item:$model.rootPresentation) { target in
            FullRootView(model:model,target:target).environment(\.locale, Locale(identifier:model.language == 0 ? "en" : "zh-Hans"))
        }
        .alert(model.text("删除“\(model.deleteTarget?.name ?? "")”及全部数据？", "Delete “\(model.deleteTarget?.name ?? "")” and all its data?"),
               isPresented: $model.deleteRequested, presenting: model.deleteTarget) { target in
            Button(model.text("取消", "Cancel"), role: .cancel) { }
            Button(model.text("删除", "Delete"), role: .destructive) { model.confirmDeletion(target) }
        } message: { target in
            Text(model.text("“\(target.name)”中的应用、游戏数据和快照将被删除，无法撤销。", "Apps, game data and snapshots on “\(target.name)” will be permanently deleted."))
        }
        .alert(model.text("重新安装应用？", "Reinstall the app?"),
               isPresented: Binding(get: { model.reinstallPrompt != nil },
                                     set: { if !$0 { model.cancelSignatureConflictReinstall() } }),
               presenting: model.reinstallPrompt) { _ in
            Button(model.text("取消", "Cancel"), role:.cancel) { model.cancelSignatureConflictReinstall() }
            Button(model.text("卸载并重新安装", "Uninstall and reinstall"), role:.destructive) { model.confirmSignatureConflictReinstall() }
        } message: { prompt in
            let name = prompt.apkName
            let zh = "“\(name)”与设备上已安装的应用签名不一致。继续会先卸载现有应用，并删除其应用数据。"
            let en = "“\(name)” was signed with a different key than the installed app. Continuing uninstalls the existing app first, which deletes its data."
            Text(model.text(zh, en))
        }
    }

    // MARK: Layout

    private var layout: some View {
        HSplitView {
            DeviceLibrarySidebar(model: model)
                .frame(minWidth: 210, idealWidth: 232, maxWidth: 240)
            Group {
                if model.isEmptyDeviceLibrary {
                    emptyDeviceState
                } else if let device = selectedDevice {
                    DeviceOverviewView(model: model, device: device) { appsPresented = true }
                        .id(device.id)
                } else {
                    CenterQuietState(icon: WbIcon.deviceEmpty,
                                     text: model.text("选择一台设备查看详情", "Select a device to see its details"), height: 196)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottomTrailing) {
            if !model.isEmptyDeviceLibrary, let toast = model.toast {
                ToastOverlay(toast: toast) { model.dismissToast() }
                    .frame(maxWidth: 440).padding()
            }
        }
    }

    private var emptyDeviceState: some View {
        VStack(spacing: WbSpace.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: WbRadius.xl, style: .continuous)
                    .fill(WbColor.accentContainer)
                    .frame(width: 80, height: 80)
                Image(systemName: WbIcon.deviceEmpty)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(WbColor.textSecondary)
                Circle()
                    .fill(WbColor.accent)
                    .frame(width: 22, height: 22)
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(WbColor.accentOnAccent)
                    )
                    .offset(x: 31, y: 31)
            }
            .accessibilityHidden(true)
            VStack(spacing: WbSpace.sm) {
                Text(model.text("创建你的第一台安卓设备", "Create your first Android device"))
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(model.text("在 Mac 上运行安卓应用和游戏。", "Run Android apps and games on your Mac."))
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: WbSpace.md) {
                Button(model.text("创建设备", "Create device")) { model.present(.newDevice) }
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(WbColor.accent)
                Button(model.text("设置 Android SDK…", "Set up Android SDK…")) { model.present(.setupSDK) }
                    .buttonStyle(.link)
            }
            .padding(.top, WbSpace.xs)
        }
        .frame(maxWidth: 480)
        .padding(WbSpace.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("empty-device-library")
    }

    // MARK: Apps card

    private var appsCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: WbSpace.sm) {
                Text(model.text("已安装的游戏和应用", "Installed games and apps"))
                    .wbFont(WbType.title)
                    .foregroundStyle(WbColor.textPrimary)
                Spacer(minLength: WbSpace.sm)
                Button {
                    if let device = selectedDevice { model.load(device.id) }
                } label: {
                    Image(systemName: WbIcon.refresh)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(WbColor.textSecondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(selectedDevice?.running != true)
                .help(model.text("刷新应用列表", "Refresh apps"))
                .accessibilityLabel(model.text("刷新应用列表", "Refresh apps"))
                Button(model.text("安装 APK", "Install APK"), systemImage: WbIcon.installAPK) {
                    if let device = selectedDevice { model.chooseFile(device: device.id, apk: true) }
                }
                .buttonStyle(.bordered).controlSize(.regular)
                .disabled(selectedDevice?.running != true)
            }
            .padding(.horizontal, WbSpace.lg)
            .padding(.top, WbSpace.md)
            .padding(.bottom, WbSpace.sm)

            if let device = selectedDevice, device.running {
                if model.appsLoading {
                    CenterQuietState(icon: WbIcon.appEmpty,
                                     text: model.text("正在读取已安装的游戏和应用…", "Loading installed games and apps…"),
                                     height: 96, showsProgress: true)
                } else if let error = model.appsError {
                    CenterQuietState(icon: WbIcon.warning, text: error, height: 96)
                } else if model.apps.isEmpty {
                    CenterQuietState(icon: WbIcon.appEmpty,
                                     text: model.text("尚未安装可启动的游戏或应用。", "No launchable apps installed yet."),
                                     height: 120)
                } else {
                    List {
                        ForEach(model.apps) { app in
                            HStack(spacing: WbSpace.sm + 2) {
                                WbAppIcon(symbol: WbIcon.appEmpty, imagePath: app.icon, size: 30)
                                Text(app.name)
                                    .wbFont(WbType.body)
                                    .foregroundStyle(WbColor.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: WbSpace.sm)
                                Button(model.text("启动", "Launch")) { model.launch(app, device: device.id) }
                                    .buttonStyle(.bordered).controlSize(.regular)
                            }
                            .padding(.vertical, 3)
                            .listRowInsets(EdgeInsets(top: 3, leading: WbSpace.lg, bottom: 3, trailing: WbSpace.lg))
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .frame(maxHeight: .infinity)
                }
                if let note = model.appsNote {
                    Text(note)
                        .wbFont(WbType.caption)
                        .foregroundStyle(WbColor.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, WbSpace.lg)
                        .padding(.bottom, WbSpace.sm)
                }
            } else {
                CenterQuietState(icon: WbIcon.appEmpty,
                                 text: selectedDevice == nil
                                    ? model.text("选择一台设备查看应用。", "Select a device to see its apps.")
                                    : model.text("启动设备后查看已安装的游戏和应用。", "Start the device to see installed games and apps."),
                                 height: 150)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Helpers

    private func statusTone(_ device: Device) -> WbStatusTone {
        switch device.status.state {
        case "running": return .running
        case "starting", "booting", "stopping": return .starting
        case "crashed": return .error
        default: return .stopped
        }
    }

    private func deviceMeta(_ device: Device) -> String {
        [device.androidVersion, device.imageLabel].joined(separator: " · ")
    }
}
