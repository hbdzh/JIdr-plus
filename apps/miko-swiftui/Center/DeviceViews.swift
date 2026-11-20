// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers

// Shared navigation treatment for settings and tool categories.
struct MikoNavigationItem: View {
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
    let onPanelClose: ((@escaping () -> Void) -> Void)?
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
    init(model: CenterModel, details: Details, onPanelClose: ((@escaping () -> Void) -> Void)? = nil) {
        self.model = model; self.details = details; self.onPanelClose = onPanelClose
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

    private func closePanel(after completion: @escaping () -> Void = {}) {
        if let onPanelClose { onPanelClose(completion) }
        else { dismiss(); DispatchQueue.main.async(execute: completion) }
    }

    var body: some View {
        VStack(spacing: 0) {
            DeviceSheetHeader(title: model.text("设备配置", "Device settings"),
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
                        Button(model.text("在工具箱中设置…", "Configure in toolbox…")) {
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
                        Text(model.dataDirectory.map(MikoStorageRoot.root(forData:)) ?? "—")
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
            .disabled(saving)

            DeviceSheetFooter(note: model.text("部分更改将在下次启动设备时生效。", "Some changes apply the next time the device starts.")) {
                Button(model.text("取消", "Cancel")) { closePanel() }
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
        .modifier(DeviceSheetGlass())
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
            Button("冷启动") { model.start(details.device.id,coldBoot:true); closePanel() }
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
        guard !values.isEmpty || qualityChanged else { closePanel(); return }
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
            case .success: closePanel()
            case .failure(.device(let failure)): error = failure.localizedDescription
            case .failure(.quality(let failure)):
                error = (changes.isEmpty
                    ? model.text("画质未能保存，请重试。", "Quality could not be saved. Try again.")
                    : model.text("设备配置已保存，但画质未能保存，请重试。", "Device settings were saved, but quality could not be saved. Try again."))
                    + "\n" + failure.localizedDescription
            }
        })
    }
}

struct HardwareProfile: Decodable, Identifiable {
    let id: String; let name: String
    let ram_mb: Int; let cpus: Int; let data_mb: Int; let audio: Bool
    let width: Int?; let height: Int?; let form_factor: String?
}
struct AvailableImage: Decodable, Identifiable {
    let api: Int; let tag: String; let abi: String; let installed_in: String?
    var id: String { "\(api):\(tag):\(abi)" }
    var package: String { "system-images;android-\(api);\(tag);\(abi)" }
}
struct OnboardingCardMaterial: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let dark = colorScheme == .dark
        content.foregroundStyle(WbColor.textPrimary)
            // The window supplies the blur; the translucent tint preserves
            // its color instead of adding an opaque material on top.
            .background {
                shape.fill(Color.white.opacity(dark ? 0.08 : 0.36))
                    .shadow(color: .black.opacity(dark ? 0.10 : 0.08), radius: 12, y: 5)
                    .allowsHitTesting(false)
            }
            .overlay(shape.strokeBorder(dark ? Color.white.opacity(0.16) : Color.black.opacity(0.12)).allowsHitTesting(false))
    }
}

struct CustomResolutionView: View {
    let language: Int
    let onConfirm: (DeviceResolution) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var width: String
    @State private var height: String

    init(language: Int, initialWidth: Int, initialHeight: Int, onConfirm: @escaping (DeviceResolution) -> Void) {
        self.language = language
        self.onConfirm = onConfirm
        _width = State(initialValue: String(initialWidth))
        _height = State(initialValue: String(initialHeight))
    }

    private func text(_ zh: String, _ en: String) -> String { language == 0 ? en : zh }
    private var resolution: DeviceResolution? { DeviceResolution(width: width, height: height) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(text("自定义分辨率", "Custom resolution"))
                    .font(.system(size: 20, weight: .semibold))
                Text(text("设置设备屏幕的宽度和高度。", "Set the width and height of the device screen."))
                    .font(.system(size: 12)).foregroundStyle(WbColor.textSecondary)
            }
            HStack(alignment: .top, spacing: 12) {
                resolutionField(text("宽度 (px)", "Width (px)"), value: $width)
                resolutionField(text("高度 (px)", "Height (px)"), value: $height)
            }
            Text(resolution == nil
                 ? text("宽度和高度须为 240–4096 之间的整数。", "Width and height must be whole numbers from 240 to 4096.")
                 : text("宽度和高度范围：240–4096 像素。", "Width and height: 240–4096 pixels."))
                .font(.system(size: 11))
                .foregroundStyle(resolution == nil ? WbColor.negative : WbColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(text("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(text("确认", "Confirm")) {
                    guard let resolution else { return }
                    onConfirm(resolution)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(resolution == nil)
            }
        }
        .padding(24).frame(width: 420)
        .background(WbColor.raised)
    }

    private func resolutionField(_ label: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 12, weight: .medium))
            TextField(label, text: value).labelsHidden().textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A compact checkbox matching the onboarding cards while keeping toggle accessibility.
struct OnboardingLicenseToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(configuration.isOn ? WbColor.accentText : Color.clear)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(configuration.isOn ? WbColor.accentText : WbColor.textSecondary.opacity(0.55), lineWidth: 1.3)
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    }
                }.frame(width: 17, height: 17)
                configuration.label
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox)
        }
    }
}

struct EnvironmentLicensesView: View {
    let language: Int
    let licenses: [PendingLicense]?
    let loading: Bool
    let error: String
    let canAgree: Bool
    let retry: () -> Void
    let onAgree: () -> Bool
    @Environment(\.dismiss) private var dismiss
    private func t(_ zh: String, _ en: String) -> String { language == 1 ? zh : en }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(t("Android SDK 许可说明", "Android SDK licence details"))
                    .font(.system(size: 18, weight: .semibold))
                Text(t("以下是所选组件实际需要确认的许可。", "These licences apply to the selected components."))
                    .font(.system(size: 12)).foregroundStyle(WbColor.textSecondary)
            }.padding(22)
            Divider()
            Group {
                if loading {
                    ProgressView(t("正在读取许可…", "Loading licences…")).controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !error.isEmpty {
                    VStack(spacing: 12) {
                        Text(error).foregroundStyle(WbColor.negative).textSelection(.enabled)
                        Button(t("重试", "Retry"), action: retry)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let licenses, licenses.isEmpty {
                    Text(t("所选组件没有关联的许可文本。", "No licence text is associated with the selected components."))
                        .foregroundStyle(WbColor.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let licenses {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(licenses) { license in
                                HStack {
                                    Text(license.id).font(.system(size: 13, weight: .semibold))
                                    if license.accepted == true {
                                        Text(t("已接受", "Accepted")).font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(WbColor.positive)
                                    }
                                }
                                Text(license.text).font(.system(size: 12)).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                } else {
                    Text(t("许可尚未读取。", "Licences have not been loaded."))
                        .foregroundStyle(WbColor.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                Spacer()
                Button(t("关闭", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(t("同意", "Agree")) {
                    if onAgree() { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(loading || !error.isEmpty || licenses == nil || !canAgree)
            }
            .tint(WbColor.accent)
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 560, height: 420)
        .background(WbColor.raised)
    }
}

struct OnboardingInstallProgressView: View {
    let language: Int
    let state: SDKOnboardingInstallState
    let fraction: Double?
    let message: String
    let error: String?
    private func t(_ zh: String, _ en: String) -> String { language == 1 ? zh : en }

    private var title: String {
        switch state {
        case .skipped: return t("需要确认许可", "Licence confirmation required")
        case .preparing, .installing: return t("正在准备 Android 运行环境", "Preparing the Android environment")
        case .completed: return t("Android 运行环境已准备好", "Android environment is ready")
        case .failed: return t("安装未完成", "Installation did not complete")
        case .cancelled: return t("安装已取消", "Installation cancelled")
        }
    }
    private var subtitle: String {
        switch state {
        case .skipped: return t("请返回上一步，查看并同意许可后继续。", "Go back, review the licences, and agree before continuing.")
        case .preparing: return t("正在确认安装许可。", "Confirming installation licences.")
        case .installing: return t("安装所需组件，请稍候。", "Installing the required components.")
        case .completed: return t("现在可以继续配置设备。", "You can now configure your device.")
        case .failed, .cancelled: return t("返回上一步可调整设置并重试。", "Go back to change your settings and try again.")
        }
    }
    private var symbol: String {
        switch state {
        case .skipped, .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "xmark.circle"
        case .preparing, .installing: return "arrow.down.to.line"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            VStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 29, weight: .medium))
                    .foregroundStyle(state == .failed ? WbColor.negative : WbColor.accentText)
                    .frame(width: 72, height: 72)
                    .background(WbColor.accentContainer.opacity(0.65), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Text(title).font(.system(size: 25, weight: .semibold)).foregroundStyle(WbColor.textPrimary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(WbColor.textSecondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity)
            if state == .preparing || state == .installing {
                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        Text(t("当前任务进度", "Current task progress")).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if let fraction {
                            Text("\(Int(fraction * 100))%")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                        }
                    }
                    if let fraction { ProgressView(value: fraction).labelsHidden().tint(WbColor.accent) }
                    else { ProgressView().controlSize(.small) }
                    if !message.isEmpty {
                        Text(message).font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }.frame(maxWidth: 500, alignment: .leading).padding(.top, 38)
            }
            if let error, !error.isEmpty, state == .failed {
                Text(error).font(.system(size: 12)).foregroundStyle(WbColor.negative)
                    .textSelection(.enabled).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 500).padding(.top, 20)
            }
            Spacer(minLength: 20)
        }.padding(.horizontal, 32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OnboardingInstallFooterView: View {
    let language: Int
    let state: SDKOnboardingInstallState
    let cancelPending: Bool
    let canCancel: Bool
    let onCancel: () -> Void
    let onReview: () -> Void
    var onReturnToSetup: (() -> Void)? = nil
    private func t(_ zh: String, _ en: String) -> String { language == 1 ? zh : en }

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            if state.showsCancel {
                Button(cancelPending ? t("正在取消…", "Cancelling…") : t("取消安装", "Cancel installation"), action: onCancel)
                    .disabled(!canCancel || cancelPending)
            } else if state.showsReviewSettings {
                Button(t("返回修改", "Review settings"), action: onReview)
                if let onReturnToSetup {
                    Button(t("返回设备配置", "Return to device setup"), action: onReturnToSetup)
                }
            }
        }
        .buttonStyle(.bordered).controlSize(.regular)
        .padding(.horizontal, 32).padding(.vertical, 18)
    }
}

struct OnboardingEnvironmentChecking: View {
    let language: Int
    var body: some View {
        ProgressView(language == 1 ? "正在检查环境…" : "Checking the environment…").controlSize(.small)
    }
}

struct NewDeviceView: View {
    @ObservedObject var model: CenterModel
    var initialStep = 0
    var inline = false
    var initialShowAdvanced = false
    var automaticallySkipReadyEnvironment = true
    var initialImageInstall = false
    var startAtDeviceSetup = false
    var standaloneImageInstall = false
    var standaloneSDKSetup = false
    private var standaloneEnvironment: Bool { standaloneImageInstall || standaloneSDKSetup }
    var reduceMotionOverride: Bool? = nil
    var onPanelClose: ((@escaping () -> Void) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var step: Int
    @State private var name = ""
    @State private var profiles: [HardwareProfile] = []
    @State private var profilesLoaded = false
    @State private var images: [AvailableImage] = []
    @State private var imagesLoaded = false
    @State private var profile = ""
    @State private var customSelection = DeviceResolutionSelection()
    @State private var showingCustomResolution = false
    @State private var image = ""
    @State private var ram = "4096"
    @State private var cpus = "4"
    @State private var storage = "6"
    @State private var root = "none"
    @State private var audio = true
    @State private var error = ""
    @State private var submission = DeviceCreationSubmission()
    @State private var imageInstallReturnStep: Int?
    @State private var environmentReturnStep: Int?
    @State private var showAdvanced = false
    @State private var environmentStatus: SDKStatus?
    @State private var initialImagesChecked = false
    @State private var initialSDKChecked = false
    @State private var initialRouteResolved = false
    @State private var directDeviceSetup = false
    @State private var initialized = false
    @State private var environmentError = ""
    @State private var environmentBusy = false
    @State private var availableImages: [AvailableImage] = []
    @State private var availableImagesLoading = false
    @State private var availableImagesError = ""
    @State private var installImageID = ""
    @State private var onboardingInstallRequested = false
    @State private var preparationAttempt = SDKPreparationAttempt()
    @State private var environmentReview = SDKLicenseReview()
    @State private var showingEnvironmentLicenses = false
    @State private var environmentLicenseLoading = false
    @State private var environmentLicenseError = ""
    @State private var onboardingStorageEstimate: StorageEstimateInfo?
    @State private var onboardingStorageProgress = ""

    init(model: CenterModel, initialStep: Int = 0, inline: Bool = false,
         initialShowAdvanced: Bool = false, automaticallySkipReadyEnvironment: Bool = true,
         initialImageInstall: Bool = false, startAtDeviceSetup: Bool = false,
         standaloneImageInstall: Bool = false, standaloneSDKSetup: Bool = false,
         reduceMotionOverride: Bool? = nil, onPanelClose: ((@escaping () -> Void) -> Void)? = nil) {
        self.model = model
        self.initialStep = initialStep
        self.inline = inline
        self.initialShowAdvanced = initialShowAdvanced
        self.automaticallySkipReadyEnvironment = automaticallySkipReadyEnvironment
        self.initialImageInstall = initialImageInstall
        self.startAtDeviceSetup = startAtDeviceSetup
        self.standaloneImageInstall = standaloneImageInstall
        self.standaloneSDKSetup = standaloneSDKSetup
        self.reduceMotionOverride = reduceMotionOverride
        self.onPanelClose = onPanelClose
        _step = State(initialValue: startAtDeviceSetup ? 3 : min(3, max(0, initialStep)))
        _directDeviceSetup = State(initialValue: startAtDeviceSetup)
        _showAdvanced = State(initialValue: initialShowAdvanced)
    }
    private func closePanel(after completion: @escaping () -> Void = {}) {
        if let onPanelClose { onPanelClose(completion) }
        else { dismiss(); DispatchQueue.main.async(execute: completion) }
    }
    private var saving: Bool { submission.isSaving }
    private var createdSuccessfully: Bool { submission.didCreate }
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }
    private var resolvingInitialRoute: Bool {
        inline && initialStep == 0 && automaticallySkipReadyEnvironment && !initialRouteResolved
    }

    private func resolveInitialRoute() {
        guard resolvingInitialRoute, initialImagesChecked, initialSDKChecked else { return }
        directDeviceSetup = DeviceOnboardingRoute.useDeviceSetup(hasTools: environmentStatus?.tools_sdk != nil && !preparesRuntime,
                                                                  installedImageCount: images.count)
        if directDeviceSetup { step = 3 }
        initialRouteResolved = true
    }

    private var creation: DeviceCreation {
        DeviceCreation(name: name, image: image, profile: profile, ram: ram, cpus: cpus,
                       storage: storage, root: root, audio: audio,
                       resolution: customSelection.active)
    }
    private var steps: [String] {
        [model.text("运行环境", "Environment"), model.text("安装环境", "Install environment"), model.text("设备配置", "Device setup")]
    }
    private var validationMessage: String? {
        guard imagesLoaded && !profiles.isEmpty else { return nil }
        do { _ = try creation.parameters(); return nil }
        catch { return model.creationError(error) }
    }

    private func applyProfile(_ id: String) {
        guard let value = profiles.first(where: { $0.id == id }) else { return }
        ram = String(value.ram_mb); cpus = String(value.cpus)
        storage = String(max(2, value.data_mb / 1024))
    }
    private func loadImages(preferredImageID: String? = nil, onComplete: @escaping (Bool) -> Void = { _ in }) {
        imagesLoaded = false
        model.call("image.list", ["available": false]) { result in
            do {
                let available = try model.decode(result.get(), as: [AvailableImage].self).filter { $0.installed_in != nil }
                images = available
                image = DeviceOnboardingRoute.selectedImage(installed: available.map(\.id), current: image, preferred: preferredImageID)
                imagesLoaded = true
                onComplete(true)
            } catch { self.error = error.localizedDescription; onComplete(false) }
            initialImagesChecked = true
            resolveInitialRoute()
        }
    }
    private func advance() {
        error = ""
        if step == 0 {
            guard canBeginEnvironmentInstallation else { return }
            beginEnvironmentInstallation()
        } else { step = 3 }
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = inline && geometry.size.width >= 900 && geometry.size.height >= 600
            VStack(spacing: 0) {
                wizardHeader
                ZStack {
                if resolvingInitialRoute {
                    VStack {
                        Spacer()
                        ProgressView(model.text("正在检查 Android 环境…", "Checking Android environment…"))
                        Spacer()
                    }
                    .transition(.opacity)
                } else if step == 1 {
                    VStack(spacing: 0) {
                    OnboardingInstallProgressView(language: model.language, state: onboardingInstallState,
                                                  fraction: onboardingInstallState.displayedFraction(model.sdkInstallFraction),
                                                  message: onboardingInstallMessage,
                                                  error: environmentError.isEmpty ? model.sdkInstallError : environmentError)
                    onboardingInstallFooter
                    }
                    .transition(.opacity)
                } else {
                    VStack(spacing: 0) {
                    ScrollViewReader { scroll in
                    ScrollView {
                        HStack(spacing: wide ? 48 : 0) {
                            if wide {
                                ZStack {
                                    OnboardingArtwork(step: step == 3 ? 1 : 0)
                                        .id(step == 3)
                                        .transition(.opacity)
                                }
                            }
                            VStack(alignment: .leading, spacing: 18) {
                                ZStack(alignment: .topLeading) {
                                    if step == 0 { environmentStep.transition(.opacity) }
                                    else { configurationStep.transition(.opacity) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if !error.isEmpty {
                                    Text(error).wbFont(WbType.caption).foregroundStyle(WbColor.negative).textSelection(.enabled)
                                }
                                if createdSuccessfully {
                                    HStack {
                                        Text(model.text("设备已创建，正在刷新设备列表。", "Device created. Refreshing the device list."))
                                            .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                                        Button(model.text("刷新", "Refresh")) { model.refresh() }.buttonStyle(.link)
                                    }
                                }
                            }
                            .frame(maxWidth: wide ? 390 : 470, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - 164), alignment: .center)
                        .padding(.horizontal, wide ? 24 : 28)
                        .padding(.vertical, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: showAdvanced) { expanded in
                        guard expanded else { return }
                        DispatchQueue.main.async {
                            withAnimation(WbMotion.scroll.animation(reduceMotion: reduceMotion)) {
                                scroll.scrollTo("onboarding-advanced-fields", anchor: .bottom)
                            }
                        }
                    }
                    }
                    wizardFooter
                    }
                    .transition(.opacity)
                }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(WbMotion.status.animation(reduceMotion: reduceMotion), value: step)
            }
        }
        .frame(width: inline ? nil : 650, height: inline ? nil : 580)
        .frame(maxWidth: inline ? 1100 : nil, maxHeight: inline ? .infinity : nil)
        .background(!inline && standaloneEnvironment ? WbColor.raised : Color.clear)
        .modifier(DeviceSheetGlass(enabled: !inline && !standaloneEnvironment))
        .sheet(isPresented: $showingEnvironmentLicenses) {
            EnvironmentLicensesView(language: model.language, licenses: environmentReview.licenses,
                                    loading: environmentLicenseLoading, error: environmentLicenseError,
                                    canAgree: !environmentBusy && environmentReview.canAgree(to: environmentSelection),
                                    retry: { loadEnvironmentLicenses() },
                                    onAgree: {
                                        guard environmentReview.agree(to: environmentSelection) else { return false }
                                        if preparesRuntime { DispatchQueue.main.async { beginEnvironmentInstallation() } }
                                        return true
                                    })
        }
        .sheet(isPresented: $showingCustomResolution) {
            let selected = profiles.first(where: { $0.id == profile })
            CustomResolutionView(language: model.language,
                                 initialWidth: customSelection.saved?.width ?? selected?.width ?? 1080,
                                 initialHeight: customSelection.saved?.height ?? selected?.height ?? 1920) { resolution in
                customSelection.apply(resolution)
            }
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            if name.isEmpty {
                var number = 1
                while model.devices.contains(where: { $0.name == model.text("我的安卓手机 \(number)", "My Android phone \(number)") }) { number += 1 }
                name = model.text("我的安卓手机 \(number)", "My Android phone \(number)")
            }
            model.call("profile.list") { result in
                profilesLoaded = true
                do {
                    profiles = try model.decode(result.get(), as: [HardwareProfile].self)
                    profile = profiles.first?.id ?? ""
                    applyProfile(profile)
                }
                catch { self.error = error.localizedDescription }
            }
            model.call("settings.get") { result in
                if let data = try? result.get(), let value = try? model.decode(data, as: DaemonSettings.self) { root = value.default_root_mode }
            }
            loadImages()
            if initialImageInstall { openImageInstaller() } else { loadEnvironment() }
        }
        .alert(model.text("更改存储位置？", "Change storage location?"),
               isPresented: Binding(get: { onboardingStorageEstimate != nil }, set: { if !$0 { onboardingStorageEstimate = nil } }),
               presenting: onboardingStorageEstimate) { estimate in
            Button(model.text("取消", "Cancel"), role: .cancel) { onboardingStorageEstimate = nil }
            Button(model.text("开始迁移", "Move data")) { onboardingStorageEstimate = nil; moveOnboardingStorage(estimate) }
        } message: { estimate in
            Text(model.text("设备、镜像和缓存将迁移到所选目录。运行中的设备会先停止。", "Devices, images and cache will move to the selected folder. Running devices will be stopped first."))
        }
        .interactiveDismissDisabled(model.onboardingInstallForegroundRequired || model.migratingStorage)
        .onChange(of: installImageID) { _ in environmentSelectionChanged() }
        .onChange(of: environmentStatus?.install_sdk ?? environmentStatus?.private_sdk) { _ in environmentSelectionChanged() }
    }

    private var wizardHeader: some View {
        HStack(alignment: .center) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(WbColor.accentText)
                Text(model.text("miko 模拟器", "miko simulator")).font(.system(size: 15, weight: .semibold))
            }
            Spacer()
            if !standaloneEnvironment && !directDeviceSetup && !resolvingInitialRoute {
            HStack(spacing: 7) {
                ForEach(0..<steps.count, id: \.self) { index in
                    Capsule()
                        .fill(index == min(step, 2) ? WbColor.textPrimary : WbColor.textSecondary.opacity(0.22))
                        .frame(width: index == min(step, 2) ? 21 : 6, height: 6)
                }
                Text("\(min(step, 2) + 1) / \(steps.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(WbColor.textSecondary)
                    .padding(.leading, 5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.text("第 \(min(step, 2) + 1) 步，共 \(steps.count) 步：\(steps[min(step, 2)])", "Step \(min(step, 2) + 1) of \(steps.count): \(steps[min(step, 2)])"))
            }
        }
        .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stepEyebrow: some View {
        Text(standaloneImageInstall ? model.text("系统镜像  /  安装镜像", "SYSTEM IMAGES  /  INSTALL IMAGE") : standaloneSDKSetup ? model.text("Android 环境  /  设置", "ANDROID ENVIRONMENT  /  SETUP") : directDeviceSetup ? (step == 0 ? (imageInstallReturnStep != nil ? model.text("创建设备  /  安装镜像", "CREATE DEVICE  /  INSTALL IMAGE") : model.text("创建设备  /  运行环境", "CREATE DEVICE  /  ENVIRONMENT")) : model.text("创建设备  /  设备配置", "CREATE DEVICE  /  DEVICE SETUP"))
             : step == 0 ? model.text("第 1 步  /  运行环境", "STEP 1  /  ENVIRONMENT")
                         : model.text("第 3 步  /  设备配置", "STEP 3  /  DEVICE SETUP"))
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(0.7)
            .foregroundStyle(WbColor.textSecondary)
    }

    private func loadEnvironment(onStatus: @escaping (Bool) -> Void = { _ in }) {
        environmentError = ""
        model.call("sdk.status") { result in
            do { environmentStatus = try model.decode(result.get(), as: SDKStatus.self); onStatus(true) }
            catch { environmentStatus = nil; environmentError = model.text("无法检查 SDK 状态：", "Unable to check SDK status: ") + error.localizedDescription; onStatus(false) }
            initialSDKChecked = true
            resolveInitialRoute()
            if step == 0 && preparesRuntime && !environmentBusy && !environmentLicenseLoading && environmentReview.licenses == nil {
                loadEnvironmentLicenses(automaticallyPrepare: true)
            }
        }
        guard !availableImagesLoading else { return }
        availableImagesLoading = true; availableImagesError = ""
        model.call("image.list", ["available": true]) { result in
            availableImagesLoading = false
            do {
                availableImages = try model.decode(result.get(), as: [AvailableImage].self).filter { $0.installed_in == nil }
                installImageID = SDKImageSelection.afterRefresh(current: installImageID, available: availableImages.map(\.id))
            } catch { availableImagesError = model.text("无法读取可下载镜像：", "Unable to load downloadable images: ") + error.localizedDescription }
        }
    }

    private func onboardingStorageButton(_ title: String) -> some View {
        Button(action: chooseOnboardingStorage) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WbColor.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(WbColor.borderDefault.opacity(0.8)))
        }
        .buttonStyle(.plain)
        .disabled(saving || environmentBusy || model.migratingStorage || model.dataDirectory == nil)
    }

    private func chooseOnboardingStorage() {
        guard !environmentBusy, !model.migratingStorage else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = model.text("选择存储目录", "Choose storage folder")
        panel.message = model.text("选择保存设备、系统镜像和缓存的目录。", "Choose the folder for devices, system images and cache.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = model.dataDirectory, MikoStorageRoot.root(forData: data) == url.standardizedFileURL.path { return }
        environmentBusy = true; environmentError = ""
        model.estimateStorageMigration(to: MikoStorageRoot.destination(forRoot: url)) { result in
            environmentBusy = false
            switch result {
            case .success(let estimate): onboardingStorageEstimate = estimate
            case .failure(let error): environmentError = OperationMessages.storageError(code: (error as? CenterMessageError)?.code, message: error.localizedDescription, language: model.language)
            }
        }
    }

    private func moveOnboardingStorage(_ estimate: StorageEstimateInfo) {
        environmentBusy = true; onboardingStorageProgress = model.text("正在迁移数据…", "Moving data…")
        model.migrateStorage(to: estimate.destination, onProgress: { message, _ in onboardingStorageProgress = message }) { result in
            environmentBusy = false; onboardingStorageProgress = ""
            switch result {
            case .success: loadImages(); loadEnvironment()
            case .failure(let error): environmentError = OperationMessages.storageError(code: (error as? CenterMessageError)?.code, message: error.localizedDescription, language: model.language)
            }
        }
    }

    private var preparesRuntime: Bool {
        guard let status = environmentStatus, !standaloneImageInstall, imageInstallReturnStep == nil else { return false }
        return status.tools_sdk == nil || status.runtime_needs_install == true
    }

    private var environmentSelection: SDKInstallSelection? {
        guard let status = environmentStatus, let destination = status.install_sdk ?? status.private_sdk else { return nil }
        if preparesRuntime {
            return SDKInstallSelection(imagePackage: nil, destination: destination)
        }
        let selectedImage = availableImages.first(where: { $0.id == installImageID })
        return SDKImageSelection.planSelection(selectedID: installImageID, selectedPackage: selectedImage?.package,
                                               requiresImage: true,
                                               destination: destination)
    }

    private func environmentSelectionChanged() {
        guard let reviewed = environmentReview.selection, reviewed != environmentSelection else { return }
        invalidateEnvironmentReview()
    }

    private func invalidateEnvironmentReview() {
        environmentReview.reset(); environmentLicenseLoading = false; environmentLicenseError = ""
    }

    private func loadEnvironmentLicenses(automaticallyPrepare: Bool = false) {
        guard !environmentLicenseLoading, let selection = environmentSelection else { return }
        let revision = environmentReview.begin(selection)
        environmentLicenseLoading = true; environmentLicenseError = ""
        let packages = selection.imagePackage.map { [$0] } ?? ["emulator", "platform-tools"]
        model.call("sdk.license_details", ["packages": packages]) { result in
            guard environmentReview.revision == revision, environmentSelection == selection else { return }
            environmentLicenseLoading = false
            do {
                let licenses = try model.decode(result.get(), as: [PendingLicense].self)
                guard environmentReview.complete(licenses, selection: selection, revision: revision),
                      automaticallyPrepare else { return }
                if licenses.allSatisfy({ $0.accepted == true }), environmentReview.agree(to: environmentSelection) {
                    beginEnvironmentInstallation()
                } else if !licenses.isEmpty {
                    showingEnvironmentLicenses = true
                }
            } catch {
                environmentLicenseError = model.text("无法读取许可，请检查网络后重试。", "Unable to load licences. Check your connection and retry.") + "\n" + error.localizedDescription
            }
        }
    }

    private var canBeginEnvironmentInstallation: Bool {
        (preparesRuntime || environmentStatus?.tools_sdk != nil) && environmentReview.canBeginInstallation(for: environmentSelection, busy: environmentBusy,
                                               installing: model.sdkInstalling,
                                               imagesLoading: !preparesRuntime && availableImagesLoading)
    }

    private func beginEnvironmentInstallation() {
        guard canBeginEnvironmentInstallation,
              let selection = environmentSelection,
              let plan = environmentReview.authorizedPlan(for: selection) else { return }
        let requests: [[String: String]]
        do { requests = try plan.consentRequests(reviewed: true) }
        catch { environmentError = model.text("许可信息无效，请重新查看。", "Licence information is invalid. Review it again."); invalidateEnvironmentReview(); return }
        onboardingInstallRequested = true; step = 1
        let attempt = preparationAttempt.begin()
        model.onboardingInstallForegroundRequired = true
        environmentBusy = true; environmentError = ""
        model.call("sdk.status") { result in
            guard preparationAttempt.isCurrent(attempt) else { return }
            do {
                let current = try model.decode(result.get(), as: SDKStatus.self)
                guard (current.install_sdk ?? current.private_sdk) == selection.destination,
                      environmentSelection == selection,
                      environmentReview.authorizedPlan(for: selection) != nil else {
                    environmentBusy = false; model.onboardingInstallForegroundRequired = false
                    environmentStatus = current; invalidateEnvironmentReview()
                    environmentError = model.text("SDK 配置已更改，请重新查看许可。", "SDK configuration changed. Review the licences again.")
                    return
                }
                acceptEnvironmentLicenses(requests, index: 0, plan: plan, attempt: attempt)
            } catch {
                environmentBusy = false; model.onboardingInstallForegroundRequired = false
                environmentError = model.text("无法检查 SDK 状态：", "Unable to check SDK status: ") + error.localizedDescription
            }
        }
    }

    private func acceptEnvironmentLicenses(_ requests: [[String: String]], index: Int, plan: SDKInstallPlan, attempt: Int) {
        guard preparationAttempt.isCurrent(attempt) else { return }
        if index == requests.count {
            guard !model.sdkInstalling else {
                environmentBusy = false; model.onboardingInstallForegroundRequired = false
                environmentError = model.text("已有安装任务正在运行。", "An installation is already running.")
                return
            }
            let installedImageID = plan.imagePackage == nil ? nil : installImageID
            model.startSDKInstall(plan) { succeeded in
                if succeeded {
                    if plan.imagePackage == nil {
                        invalidateEnvironmentReview()
                        imageInstallReturnStep = nil; environmentReturnStep = nil
                        loadEnvironment()
                        loadImages { _ in
                            if standaloneSDKSetup { closePanel() }
                            else if images.isEmpty { step = 0; onboardingInstallRequested = false }
                            else { directDeviceSetup = true; step = 3 }
                        }
                        return
                    }
                    loadImages(preferredImageID: installedImageID); loadEnvironment()
                    if SDKOnboardingInstallState.shouldDismissAfterSuccess(requested: onboardingInstallRequested, step: step, succeeded: succeeded, standalone: standaloneEnvironment) {
                        closePanel()
                    } else if !standaloneEnvironment, let next = SDKOnboardingInstallState.nextStepAfterSuccess(requested: onboardingInstallRequested, step: step, succeeded: succeeded) { step = next }
                    imageInstallReturnStep = nil
                    environmentReturnStep = nil
                }
            }
            environmentBusy = false
            return
        }
        model.call("sdk.accept_license", requests[index]) { result in
            guard preparationAttempt.isCurrent(attempt) else { return }
            switch result {
            case .success: acceptEnvironmentLicenses(requests, index: index + 1, plan: plan, attempt: attempt)
            case .failure(let failure):
                environmentBusy = false; model.onboardingInstallForegroundRequired = false; invalidateEnvironmentReview()
                environmentError = model.text("无法记录许可确认，请重新查看后重试。", "Unable to record licence consent. Review and try again.") + "\n" + failure.localizedDescription
            }
        }
    }

    private func environmentSectionHeader(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(WbColor.textPrimary)
            Spacer(minLength: 8)
            Text(detail).font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
        }
        .padding(.horizontal, 2)
    }

    private func environmentIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium)).foregroundStyle(WbColor.accentText)
            .frame(width: 38, height: 38)
            .background(WbColor.accentContainer.opacity(0.9), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .accessibilityHidden(true)
    }

    private var environmentStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepEyebrow.padding(.bottom, 12)
            Text(imageInstallReturnStep == nil ? model.text("准备 Android 环境", "Prepare your Android environment") : model.text("安装其他系统镜像", "Install another system image"))
                .font(.system(size: 28, weight: .semibold)).foregroundStyle(WbColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.text("首次设置会准备模拟器和 ADB。系统镜像按需下载。", "Set up the emulator and ADB, then download system images as needed."))
                .font(.system(size: 13)).foregroundStyle(WbColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)

            environmentSectionHeader(model.text("存储位置", "Storage location"), detail: "")
                .padding(.top, 22).padding(.bottom, 9)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        let location = model.dataDirectory.map(MikoStorageRoot.root(forData:)) ?? model.text("读取中…", "Loading…")
                        Text(location)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(location)
                        Text(model.text("设备、系统镜像和缓存保存在这里。", "Devices, system images and cache are stored here."))
                            .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    onboardingStorageButton(model.text("更改位置…", "Change location…"))
                }
                if !onboardingStorageProgress.isEmpty { Text(onboardingStorageProgress).font(.caption) }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).modifier(OnboardingCardMaterial())

            environmentSectionHeader(model.text("安装所需组件", "Install components"),
                                     detail: model.text("按需准备", "As needed"))
                .padding(.top, 14).padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 11) {
                    environmentIcon("arrow.down.to.line")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preparesRuntime ? model.text("模拟器和 ADB", "Emulator and ADB") : model.text("系统镜像", "System image"))
                            .font(.system(size: 12, weight: .semibold))
                        Text(preparesRuntime ? model.text("先准备运行工具，稍后再选择系统镜像。", "Prepare the tools, then choose a system image.") : model.text("系统镜像会保存在 miko 的目录。", "System images are stored in the miko folder."))
                            .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !preparesRuntime {
                Picker(model.text("安装组件", "Components to install"), selection: $installImageID) {
                    Text(availableImages.isEmpty ? model.text("没有可安装的系统镜像", "No system images available to install")
                                                 : model.text("请选择要安装的镜像", "Choose a system image to install")).tag("")
                    ForEach(availableImages) { image in
                        Text("API \(image.api) · \(Device.imageTagLabel(image.tag)) · \(image.abi)").tag(image.id)
                    }
                }
                .pickerStyle(.menu).buttonStyle(.borderless).controlSize(.regular)
                .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(model.text("安装组件", "Components to install"))
                .disabled(environmentBusy)
                }
                HStack(alignment: .center, spacing: 8) {
                    if preparesRuntime {
                        Text(model.text("工具会安装到 miko 的目录。", "Tools will be installed in the miko folder."))
                    } else if availableImagesLoading {
                        ProgressView().controlSize(.small)
                        Text(model.text("正在读取镜像列表…", "Loading images…"))
                    } else {
                        Image(systemName: !availableImagesError.isEmpty ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(!availableImagesError.isEmpty ? WbColor.negative : WbColor.positive)
                        Text(!availableImagesError.isEmpty ? availableImagesError
                             : installImageID.isEmpty ? (availableImages.isEmpty ? model.text("没有可安装的系统镜像", "No system images available to install") : model.text("请选择要安装的镜像", "Choose a system image to install"))
                             : model.text("已读取系统镜像列表", "System images loaded"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button(model.text("重新检测", "Check again")) {
                        loadEnvironment()
                        loadImages()
                    }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(WbColor.accentText)
                        .disabled(environmentBusy || availableImagesLoading)
                }
                .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).modifier(OnboardingCardMaterial())
            environmentSectionHeader(model.text("许可确认", "Licence confirmation"), detail: "")
                .padding(.top, 14).padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 7) {
                Toggle(model.text("我已阅读并同意相关许可", "I have read and agree to the licences"), isOn: Binding(
                    get: { environmentReview.agreed },
                    set: { agreed in
                        if agreed && environmentReview.licenses == nil {
                            showingEnvironmentLicenses = true
                            loadEnvironmentLicenses()
                        } else { environmentReview.setAgreed(agreed) }
                    }
                ))
                .toggleStyle(OnboardingLicenseToggleStyle()).font(.system(size: 12, weight: .semibold))
                .disabled(environmentBusy || environmentSelection == nil || availableImagesLoading)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(model.text("安装组件可能涉及 Android SDK 许可。", "Installing components may require Android SDK licences."))
                        .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(model.text("查看许可说明", "View licence details")) {
                        showingEnvironmentLicenses = true
                        if environmentReview.licenses == nil { loadEnvironmentLicenses() }
                    }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(WbColor.accentText)
                    .disabled(environmentBusy || environmentSelection == nil || availableImagesLoading)
                }.padding(.leading, 27).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).modifier(OnboardingCardMaterial())
            if environmentBusy { OnboardingEnvironmentChecking(language: model.language).padding(.top, 8) }
            if !environmentError.isEmpty { Text(environmentError).font(.system(size: 11)).foregroundStyle(WbColor.negative).textSelection(.enabled).padding(.top, 8) }
        }
    }

    private func openImageInstaller() {
        imageInstallReturnStep = 3
        directDeviceSetup = true
        environmentError = ""; error = ""
        invalidateEnvironmentReview()
        installImageID = ""
        step = 0
        loadEnvironment()
    }

    private var configurationStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepEyebrow.padding(.bottom, 12)
            Text(model.text("配置你的设备", "Configure your device"))
                .font(.system(size: 28, weight: .semibold)).foregroundStyle(WbColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.text("设置名称、硬件和 Root 模式，之后也可以调整。", "Choose a name, hardware profile and root mode. You can adjust them later."))
                .font(.system(size: 13)).foregroundStyle(WbColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.text("存储目录", "Storage folder"))
                        Spacer()
                        onboardingStorageButton(model.text("更改目录…", "Change folder…"))
                    }
                    Text(model.dataDirectory.map(MikoStorageRoot.root(forData:)) ?? model.text("读取中…", "Loading…"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(WbColor.textSecondary)
                        .textSelection(.enabled)
                    Text(model.text("设备数据、系统镜像和缓存保存在此目录。", "Device data, system images and caches are stored here."))
                        .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "square.3.layers.3d")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(WbColor.accentText)
                                .accessibilityHidden(true)
                            Text(model.text("系统镜像", "System image"))
                            Spacer(minLength: 8)
                            Button(action: openImageInstaller) {
                                Label(images.isEmpty ? model.text("安装镜像…", "Install image…") : model.text("安装其他镜像…", "Install another image…"),
                                      systemImage: "arrow.down.circle")
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(WbColor.accentText)
                            .disabled(saving)
                            .accessibilityIdentifier("onboarding-install-other-image")
                        }
                        if !imagesLoaded && error.isEmpty {
                            ProgressView(model.text("正在读取系统镜像…", "Loading system images…")).controlSize(.small)
                        } else if images.isEmpty {
                            Text(model.text("没有已安装的系统镜像，请先安装。", "No system images are installed. Install one first."))
                                .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                        } else {
                            Picker(model.text("系统镜像", "System image"), selection: $image) {
                                ForEach(images) { item in
                                    Text("Android API \(item.api) · \(Device.imageTagLabel(item.tag)) · \(item.abi)").tag(item.id)
                                }
                            }
                            .pickerStyle(.menu).buttonStyle(.borderless).labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(saving)
                            .accessibilityLabel(model.text("系统镜像", "System image"))
                        }
                        if initialSDKChecked && environmentStatus?.tools_sdk == nil {
                            Text(model.text("未找到可用的模拟器工具。", "Emulator tools are unavailable."))
                                .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                            Button(model.text("配置运行环境…", "Configure environment…")) {
                                environmentReturnStep = 3
                                directDeviceSetup = true
                                invalidateEnvironmentReview()
                                step = 0
                                loadEnvironment()
                            }
                            .buttonStyle(.link).disabled(saving)
                        }
                    }
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.text("设备名称", "Device name"))
                    TextField(model.text("例如：Pixel 9 Pro", "e.g. Pixel 9 Pro"), text: $name)
                        .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity).disabled(saving)
                        .accessibilityLabel(model.text("设备名称", "Device name"))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.text("设备规格", "Device profile"))
                    if profiles.isEmpty {
                        Text(profilesLoaded ? model.text("没有可用的设备规格。", "No device profiles are available.")
                                            : model.text("正在读取设备规格…", "Loading device profiles…"))
                            .font(.system(size: 12)).foregroundStyle(WbColor.textSecondary)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                            ForEach(profiles) { item in profileCard(item) }
                            customProfileCard
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.text("Root 模式", "Root mode"))
                    rootModeControl
                    Text(rootExplanation)
                        .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 13)).padding(17)
            .modifier(OnboardingCardMaterial())
            .padding(.top, 22)
            Button { showAdvanced.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text(model.text("高级配置", "Advanced configuration"))
                    Spacer(minLength: 0)
                    Text(model.text("内存、CPU、存储与声音", "Memory, CPU, storage and audio"))
                        .font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(WbColor.textSecondary.opacity(0.8))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
            .foregroundStyle(WbColor.textSecondary).padding(.top, 16)
            .accessibilityLabel(model.text("高级配置", "Advanced configuration"))
            .accessibilityValue(showAdvanced ? model.text("已展开", "Expanded") : model.text("已收起", "Collapsed"))
            if showAdvanced {
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        advancedNumberField(model.text("内存 (MB)", "Memory (MB)"), value: $ram)
                        advancedNumberField(model.text("CPU 核心数", "CPU cores"), value: $cpus)
                        advancedNumberField(model.text("设备存储 (GB)", "Storage (GB)"), value: $storage)
                    }
                    Divider()
                    HStack {
                        Text(model.text("设备声音", "Device audio"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Toggle(model.text("设备声音", "Device audio"), isOn: $audio)
                            .labelsHidden().toggleStyle(.switch).tint(Color(nsColor: .controlAccentColor))
                    }
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(WbColor.textSecondary)
                .padding(17).frame(maxWidth: .infinity, alignment: .leading)
                .modifier(OnboardingCardMaterial())
                .padding(.top, 10)
                .id("onboarding-advanced-fields")
            }
            if let validationMessage {
                Text(validationMessage).wbFont(WbType.caption).foregroundStyle(WbColor.negative).padding(.top, 12)
            }
        }
    }

    @ViewBuilder private var rootModeControl: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let segments = HStack(spacing: 0) {
            rootModeButton(model.text("关闭", "Off"), value: "none")
            rootModeButton("Shell Root", value: "adb")
            rootModeButton(model.text("完整 Root", "Full Root"), value: "magisk")
        }
        .padding(3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.text("Root 模式", "Root mode"))
        .onMoveCommand { direction in
            let values = ["none", "adb", "magisk"]
            guard !saving, let index = values.firstIndex(of: root) else { return }
            switch direction {
            case .left: root = values[max(0, index - 1)]
            case .right: root = values[min(values.count - 1, index + 1)]
            default: break
            }
        }
        if #available(macOS 26.0, *) {
            segments.glassEffect(.regular, in: shape)
        } else {
            segments.background(.regularMaterial, in: shape)
        }
    }

    private func rootModeButton(_ title: String, value: String) -> some View {
        let selected = root == value
        return Button { root = value } label: {
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .foregroundStyle(selected ? Color(nsColor: .alternateSelectedControlTextColor) : WbColor.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(selected ? Color(nsColor: .controlAccentColor).opacity(0.88) : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(saving)
        .accessibilityValue(selected ? model.text("已选择", "Selected") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var rootExplanation: String {
        switch root {
        case "adb": return model.text("通过 Root Shell 使用高级功能。", "Use advanced features through a root shell.")
        case "magisk": return model.text("创建后将下载并配置 Magisk，期间设备会启动并重启。", "After creation Magisk is downloaded and configured; the device starts and reboots in the process.")
        default: return model.text("设备不会启用 Root。", "Root access is disabled.")
        }
    }
    private func profileCard(_ item: HardwareProfile) -> some View {
        let detail = item.width.flatMap { width in item.height.map { "\(width) × \($0)" } }
        return profileOption(item.name, detail: detail,
                             symbol: item.form_factor == "tablet" ? "ipad" : "iphone",
                             selected: !customSelection.isCustom && profile == item.id) {
            profile = item.id
            customSelection.selectPreset()
            applyProfile(item.id)
        }
    }
    private var customProfileCard: some View {
        let detail = customSelection.saved.map { "\($0.width) × \($0.height)" }
            ?? model.text("设置分辨率", "Set resolution")
        return profileOption(model.text("自定义", "Custom"), detail: detail,
                             symbol: "slider.horizontal.3", selected: customSelection.isCustom) {
            showingCustomResolution = true
        }
        .accessibilityIdentifier("device-profile-custom")
    }
    private func profileOption(_ title: String, detail: String?, symbol: String, selected: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                }
                .foregroundStyle(selected ? WbColor.accentText : WbColor.textSecondary)
                Text(title).font(.system(size: 11, weight: .medium))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if let detail {
                    Text(verbatim: detail).font(.system(size: 10))
                        .foregroundStyle(WbColor.textSecondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 65, alignment: .topLeading)
            .padding(9)
            .background(selected ? WbColor.accentContainer.opacity(0.65) : Color.primary.opacity(0.025),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? WbColor.accentText.opacity(0.65) : WbColor.borderSubtle))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain).disabled(saving)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? model.text("已选择", "Selected") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func advancedNumberField(_ label: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .bottomLeading)
            TextField("", text: value).textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading).foregroundStyle(WbColor.textPrimary)
                .disabled(saving).accessibilityLabel(label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var onboardingInstallState: SDKOnboardingInstallState {
        SDKOnboardingInstallState.resolve(requested: onboardingInstallRequested,
                                          preparing: environmentBusy,
                                          running: model.sdkInstalling,
                                          succeeded: model.sdkInstallSucceeded,
                                          error: environmentError.isEmpty ? model.sdkInstallError : environmentError)
    }
    private var onboardingInstallMessage: String {
        if onboardingInstallState == .preparing { return model.text("正在确认许可…", "Confirming licences…") }
        return model.sdkInstallMessage
    }
    private var onboardingInstallFooter: some View {
        OnboardingInstallFooterView(language: model.language, state: onboardingInstallState,
                                    cancelPending: model.sdkCancelPending,
                                    canCancel: (onboardingInstallState == .preparing && environmentBusy && !model.sdkInstalling) || onboardingInstallState == .installing,
                                    onCancel: {
                                        if environmentBusy && !model.sdkInstalling {
                                            preparationAttempt.cancel()
                                            environmentBusy = false; model.onboardingInstallForegroundRequired = false
                                            onboardingInstallRequested = false; environmentReview.reset(); step = 0
                                        } else { model.cancelSDKInstall() }
                                    },
                                    onReview: { step = 0; environmentError = ""; environmentReview.reset() },
                                    onReturnToSetup: standaloneEnvironment ? nil : {
                                        environmentError = ""; environmentReview.reset()
                                        imageInstallReturnStep = nil; environmentReturnStep = nil
                                        directDeviceSetup = true; step = 3
                                    })
    }
    private var wizardFooter: some View {
        HStack(spacing: 8) {
            if !standaloneEnvironment && step == 0 && (imageInstallReturnStep != nil || environmentReturnStep != nil) {
                Button {
                    error = ""
                    if step == 0, let returnStep = imageInstallReturnStep {
                        imageInstallReturnStep = nil; invalidateEnvironmentReview(); step = returnStep
                    } else if step == 0, let returnStep = environmentReturnStep {
                        environmentReturnStep = nil; invalidateEnvironmentReview(); step = returnStep
                    }
                } label: {
                    Label(model.text("返回设备配置", "Return to device setup"), systemImage: "arrow.left")
                }
                .buttonStyle(.plain).foregroundStyle(WbColor.textSecondary).disabled(saving || environmentBusy)
                .accessibilityIdentifier("onboarding-back")
            }
            Spacer()
            if !inline {
                Button(model.text("取消", "Cancel")) { closePanel() }.disabled(saving).keyboardShortcut(.cancelAction)
            }
            if step < 3 {
                if step == 0 && !environmentReview.agreed {
                    Text(model.text("请先查看并同意许可", "Review and agree to the licences first"))
                        .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                }
                onboardingAction(model.text("开始安装", "Install"), action: advance,
                                 disabled: saving || environmentBusy || !canBeginEnvironmentInstallation)
            } else {
                onboardingAction(model.text("创建设备", "Create device"), action: create,
                                 disabled: saving || createdSuccessfully || !imagesLoaded || !creation.isValid || images.isEmpty || profiles.isEmpty || environmentStatus?.tools_sdk == nil)
            }
        }
        .buttonStyle(.bordered).controlSize(.regular)
        .padding(.horizontal, 32).padding(.vertical, 18)
    }

    @ViewBuilder private func onboardingAction(_ title: String, action: @escaping () -> Void, disabled: Bool) -> some View {
        let button = Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 86, minHeight: 20)
        }
        .disabled(disabled)
        .keyboardShortcut(.defaultAction)
        .tint(Color(nsColor: .controlAccentColor))

        if #available(macOS 26.0, *) {
            button.buttonStyle(.glassProminent).buttonBorderShape(.roundedRectangle).controlSize(.regular)
        } else {
            button.buttonStyle(.borderedProminent).controlSize(.regular)
        }
    }
    private func create() {
        let parameters: [String: Any]
        do { parameters = try creation.parameters() }
        catch { self.error = model.creationError(error); return }
        guard submission.begin() else { return }
        model.call("device.create", parameters) { result in
            switch result {
            case .success(let data):
                submission.finish(succeeded: true)
                do {
                    let created = try model.decode(data, as: Device.self)
                    model.selected = created.id; model.details = nil; model.apps = []
                    model.refresh()
                    let afterClose = {
                        if root == "magisk" { model.setupFullRoot(created.id, name: created.name) }
                    }
                    if !inline { closePanel(after: afterClose) } else { afterClose() }
                } catch { self.error = model.text("设备已创建，但读取结果失败：", "Device created, but its result could not be read: ") + error.localizedDescription; model.refresh() }
            case .failure(let failure): submission.finish(succeeded: false); error = failure.localizedDescription
            }
        }
    }
}

struct CenterPaths: Decodable { let data: String; let cache: String; let logs: String }
struct DaemonSettings: Decodable {
    let default_root_mode: String
    let quick_boot: Bool
    let budget_percent: UInt8
    let auto_hibernate_minutes: UInt32
}
struct SDKStatus: Decodable {
    let tools_sdk: String?
    let private_sdk: String?
    /// Writable SDK that Miko installs into (custom root or the private SDK).
    let install_sdk: String?
    /// Set only when the user selected a custom writable install root.
    let custom_sdk: String?
    var runtime_needs_install: Bool? = nil
}
struct CacheEntry: Decodable { let size: UInt64 }
struct AboutInfo: Decodable { let version: String; let repository: String }

/// Keep the native pop-up menu and its keyboard behavior while giving its
/// closed control the same system glass treatment as the surrounding window.
private struct SettingsGlassPicker: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.pickerStyle(.menu).buttonStyle(.borderless).controlSize(.regular)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            content.pickerStyle(.menu).buttonStyle(.bordered).controlSize(.regular)
        }
    }
}

/// Settings has an AppKit glass backdrop rather than the SwiftUI glass
/// container used by device panels. Give the same native bordered controls a
/// glass surface while retaining their normal enabled and disabled colors.
private struct SettingsPanelButtonStyle: ViewModifier {
    var prominent = false
    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                content.buttonStyle(.borderedProminent).controlSize(.regular)
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                content.buttonStyle(.bordered).controlSize(.regular)
                    .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        } else if prominent {
            content.buttonStyle(.borderedProminent).controlSize(.regular)
        } else {
            content.buttonStyle(.bordered).controlSize(.regular)
        }
    }
}

private struct AgentRobotBadge: View {
    var body: some View {
        VStack(spacing: 1) {
            Rectangle()
                .fill(WbColor.textSecondary)
                .frame(width: 1.5, height: 3)
            RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                .strokeBorder(WbColor.textSecondary, lineWidth: 1.4)
                .frame(width: 16, height: 12)
                .overlay(
                    HStack(spacing: 4) {
                        Circle().fill(WbColor.textSecondary).frame(width: 2.2, height: 2.2)
                        Circle().fill(WbColor.textSecondary).frame(width: 2.2, height: 2.2)
                    }
                )
        }
        .accessibilityHidden(true)
    }
}

private struct AgentPillButtonStyle: ButtonStyle {
    var prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? WbColor.raised : WbColor.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                prominent ? AnyShapeStyle(WbColor.textPrimary) : AnyShapeStyle(Color.primary.opacity(0.035)),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .strokeBorder(prominent ? .clear : WbColor.borderDefault.opacity(0.8), lineWidth: 1)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1.0) : 0.45)
            .contentShape(Capsule())
    }
}

private struct SettingsSection<Content: View>: View {
    private let title: String?
    private let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        } label: {
            if let title { Text(title) }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: CenterModel
    var glassBackground = false
    var onContentHeightChange: (Int, CGFloat) -> Void = { _, _ in }
    let onClose: () -> Void
    private var category: Int { model.settingsCategory }
    @State private var tileURL = ""
    @State private var mcpBinary = ProcessInfo.processInfo.environment["MIKO_DAEMON_BIN"] ?? "miko"
    @State private var confirmCodexConfig = false
    @State private var confirmWorkBuddyConfig = false
    @State private var paths: CenterPaths?
    @State private var sdkStatus: SDKStatus?
    @State private var policy = DevicePolicyDraft(root: "none", quickBoot: true, budget: "80", idleMinutes: "0")
    @State private var savedPolicy: DevicePolicyDraft?
    private var policyDirty: Bool { savedPolicy != nil && policy != savedPolicy }
    @State private var loaded = false
    @State private var message = ""
    @State private var saving = false
    @State private var cacheBytes: UInt64?
    @State private var imageCount: Int?
    @State private var deviceUsage: [String:UInt64] = [:]
    @State private var about: AboutInfo?
    @State private var confirmCacheClear = false
    @State private var pendingStorageMigration: StorageEstimateInfo?
    @State private var migrationProgressMessage: String?
    @State private var migrationProgressValue: Double?
    @State private var checkingUpdate = false
    @State private var updateMessage = ""
    @State private var releaseURL: URL?
    private enum PolicyField { case budget, idle }
    @FocusState private var policyFocus: PolicyField?
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
        loadImageCount()
        for device in model.devices {
            model.call("device.details",["device":device.id]) { result in
                if let value = try? result.get(), let details = try? model.decode(value,as:Details.self), let bytes = details.disk_usage { deviceUsage[device.id] = bytes }
            }
        }
        model.call("center.about") { result in
            if let value = try? result.get() { about = try? model.decode(value,as:AboutInfo.self) }
        }
    }
    private func loadImageCount() {
        model.call("image.list", ["available": false]) { result in
            do { imageCount = try model.decode(result.get(), as: [AvailableImage].self).filter { $0.installed_in != nil }.count }
            catch { message = error.localizedDescription }
        }
    }
    func chooseDataLocation() {
        guard !saving, !model.migratingStorage else { return }
        if model.hasActiveRecording || !model.recording.isEmpty || model.hasActiveJobs {
            message = model.text("请先等待当前录屏和后台任务完成。", "Wait for active recordings and background jobs to finish first.")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = model.text("选择存储目录", "Choose storage folder")
        panel.message = model.text("选择保存设备、系统镜像和缓存的目录。", "Choose the folder for devices, system images and cache.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = paths?.data, MikoStorageRoot.root(forData: data) == url.standardizedFileURL.path { return }
        let destination = MikoStorageRoot.destination(forRoot: url)
        saving = true
        message = ""
        model.estimateStorageMigration(to: destination) { result in
            saving = false
            switch result {
            case .success(let estimate):
                pendingStorageMigration = estimate
            case .failure(let error):
                message = storageErrorMessage(error)
            }
        }
    }
    func startStorageMigration(_ estimate: StorageEstimateInfo) {
        guard !saving, !model.migratingStorage else { return }
        saving = true
        message = ""
        migrationProgressValue = 0.05
        migrationProgressMessage = model.text("正在准备迁移…", "Preparing migration…")
        model.migrateStorage(to: estimate.destination, onProgress: { text, progress in
            migrationProgressMessage = text
            if let progress { migrationProgressValue = progress }
        }) { result in
            saving = false
            migrationProgressMessage = nil
            migrationProgressValue = nil
            switch result {
            case .success(let info):
                let sizeText = ByteCountFormatter.string(fromByteCount: Int64(clamping: info.bytes), countStyle: .file)
                if info.source_cleaned == false {
                    message = model.text(
                        "设备数据已迁移至 \(info.data)（\(info.files) 个文件，\(sizeText)），但未能自动清理旧目录 \(info.previous_data)，请手动删除以释放空间。",
                        "Device data migrated to \(info.data) (\(info.files) files, \(sizeText)), but the previous folder at \(info.previous_data) could not be removed automatically. Delete it manually to free space."
                    )
                } else {
                    message = model.text(
                        "设备数据已迁移至 \(info.data)（\(info.files) 个文件，\(sizeText)），原目录 \(info.previous_data) 已清理。",
                        "Device data migrated to \(info.data) (\(info.files) files, \(sizeText)), and the previous folder at \(info.previous_data) was removed."
                    )
                }
                load()
            case .failure(let error):
                message = storageErrorMessage(error)
            }
        }
    }
    private func storageErrorMessage(_ error: Error) -> String {
        OperationMessages.storageError(code: (error as? CenterMessageError)?.code,
                                       message: error.localizedDescription,
                                       language: model.language)
    }
    func showFolder(_ path:String?) {
        guard let path, FileManager.default.fileExists(atPath:path), NSWorkspace.shared.open(URL(fileURLWithPath:path)) else { message = model.text("无法打开目录。", "Cannot open the folder."); return }
    }
    func checkUpdate() {
        guard let about, let url = URL(string:"https://api.github.com/repos/hbdzh/miko-simulator/releases/latest") else { return }
        checkingUpdate = true; updateMessage = model.text("正在检查更新…", "Checking for updates…"); releaseURL = nil
        var request = URLRequest(url:url); request.timeoutInterval = 8
        request.setValue("Miko/\(about.version)",forHTTPHeaderField:"User-Agent")
        URLSession.shared.dataTask(with:request) { data, response, _ in
            let parsed = data.flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            DispatchQueue.main.async {
                checkingUpdate = false
                guard status == 200, let tag = parsed?["tag_name"] as? String,
                      let page = parsed?["html_url"] as? String, let destination = URL(string:page),
                      destination.scheme == "https", destination.host == "github.com",
                      destination.path.hasPrefix("/hbdzh/miko-simulator/releases/") else {
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
        .preferredColorScheme(model.colorScheme)
        .environment(\.locale, Locale(identifier: model.language == 0 ? "en" : "zh-Hans"))
        .background {
            if !glassBackground { WbColor.surface }
        }
        .onExitCommand { if !saving { onClose() } }
        .onAppear(perform:load)
        .onChange(of: model.imageInventoryRevision) { _ in loadImageCount() }
        .alert(model.text("配置 Codex？", "Configure Codex?"),isPresented:$confirmCodexConfig) {
            Button(model.text("取消", "Cancel"),role:.cancel) { }
            Button(model.text("配置", "Configure")) {
                let command = mcpBinary
                saving = true
                DispatchQueue.global(qos:.userInitiated).async {
                    let result = Result { try MCPConfiguration.install(command:command) }
                    DispatchQueue.main.async {
                        saving = false
                        switch result {
                        case .success: message = model.text("配置已保存，请重新打开 Codex 或开始新对话。", "Configuration saved. Reopen Codex or start a new conversation.")
                        case .failure(let error): message = model.text("无法保存 Codex 配置：", "Could not save Codex configuration: ") + OperationMessages.error(error.localizedDescription,language:model.language)
                        }
                    }
                }
            }
        } message: { Text(model.text("将添加或替换 Codex 中名为 miko 的 MCP 配置，保留其他配置。", "This adds or replaces the MCP entry named miko in Codex and preserves other settings.")) }
        .alert(model.text("配置 WorkBuddy？", "Configure WorkBuddy?"),isPresented:$confirmWorkBuddyConfig) {
            Button(model.text("取消", "Cancel"),role:.cancel) { }
            Button(model.text("配置", "Configure")) {
                let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".workbuddy/mcp.json")
                do {
                    try MCPConfiguration.installWorkBuddy(at:path,command:mcpBinary)
                    message = model.text("配置已保存，请在 WorkBuddy 中检查 MCP 连接状态。", "Configuration saved. Check the MCP connection status in WorkBuddy.")
                } catch {
                    message = model.text("无法保存 WorkBuddy 配置：", "Could not save WorkBuddy configuration: ") + OperationMessages.error(error.localizedDescription,language:model.language)
                }
            }
        } message: { Text(model.text("将添加或替换 WorkBuddy 中名为 miko 的 MCP 配置，保留其他配置。", "This adds or replaces the MCP entry named miko in WorkBuddy and preserves other settings.")) }
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
        .alert(model.text("迁移设备数据？", "Migrate device data?"),
               isPresented: Binding(get: { pendingStorageMigration != nil },
                                    set: { if !$0 { pendingStorageMigration = nil } }),
               presenting: pendingStorageMigration) { estimate in
            Button(model.text("取消", "Cancel"), role: .cancel) { pendingStorageMigration = nil }
            Button(model.text("开始迁移", "Migrate")) {
                pendingStorageMigration = nil
                startStorageMigration(estimate)
            }
        } message: { estimate in
            let currentSize = ByteCountFormatter.string(fromByteCount: Int64(clamping: estimate.source_bytes), countStyle: .file)
            let requiredSize = ByteCountFormatter.string(fromByteCount: Int64(clamping: estimate.required_bytes), countStyle: .file)
            Text(model.text(
                "将把现有设备、镜像数据与设置复制并校验到：\n\(estimate.destination)\n\n当前大小 \(currentSize)，至少需要 \(requiredSize)。迁移并校验成功后将删除原目录以释放空间，如有运行中的设备会先停止。",
                "Existing devices, disk images and settings will be copied and verified to:\n\(estimate.destination)\n\nCurrent size: \(currentSize), required space: \(requiredSize). After copying and verification succeed, the original folder will be removed to free space; running devices will be stopped first."
            ))
        }
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
                                .labelsHidden().modifier(SettingsGlassPicker()).frame(width: 180)
                            }
                            .padding(10)
                        }
                        GroupBox {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.text("录屏包含设备音频", "Include device audio in recordings"))
                                    Text(model.text("关闭后录屏仅保存画面。", "When off, screen recordings save video only."))
                                        .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Toggle("", isOn: Binding(get: { model.recordAudio }, set: { model.setRecordAudio($0) }))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .tint(WbColor.accent)
                                    .accessibilityLabel(model.text("录屏包含设备音频", "Include device audio in recordings"))
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
                    .background(settingsHeightReader)
                }
            } else {
                ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch category {
                    case 1: defaultsPage
                    case 2: dataPage
                    case 3: agentsPage
                    case 4: advancedPage
                    default: aboutPage
                    }
                    if !message.isEmpty {
                        SettingsSection { Text(message).font(.system(size: 12)).foregroundStyle(WbColor.textSecondary).textSelection(.enabled) }
                    }
                }
                .disabled(saving)
                .padding(28)
                .frame(maxWidth: 680)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .background(settingsHeightReader)
                }
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var settingsHeightReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { onContentHeightChange(category, proxy.size.height) }
                .onChange(of: proxy.size.height) { height in onContentHeightChange(category, height) }
        }
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
                                Rectangle().fill(mode == 2 ? MikoColor.surfaceRaised.dark : MikoColor.surfaceRaised.light)
                                if mode == 0 { Rectangle().fill(MikoColor.surfaceRaised.dark) }
                            }
                            HStack(spacing: 0) {
                                Rectangle().fill(mode == 2 ? MikoColor.surfaceChrome.dark : MikoColor.surfaceChrome.light)
                                    .frame(width: geometry.size.width * 0.28)
                                VStack(alignment: .leading, spacing: 7) {
                                    Capsule().fill(mode == 2 ? MikoColor.textSecondary.dark : MikoColor.textSecondary.light).frame(width: 36, height: 4)
                                    Capsule().fill(mode == 2 ? MikoColor.borderStrong.dark : MikoColor.borderStrong.light).frame(width: 52, height: 4)
                                    Capsule().fill(mode == 2 ? MikoColor.borderStrong.dark : MikoColor.borderStrong.light).frame(width: 44, height: 4)
                                    Spacer(minLength: 0)
                                }.padding(12)
                                Spacer(minLength: 0)
                            }.padding(.top, 16)
                            HStack(spacing: 3) {
                                ForEach(0..<3, id: \.self) { _ in Circle().fill(MikoColor.textSecondary.light.opacity(0.5)).frame(width: 4, height: 4) }
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
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.text("新设备默认值", "Defaults for new devices"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WbColor.textPrimary)
                Text(model.text("默认 Root 模式 · 仅用于之后创建的设备。", "Default root mode · applies only to devices created later."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(WbColor.textSecondary)
            }
            HStack(spacing: 10) {
                defaultRootRadioOption(
                    value: "none",
                    title: model.text("无", "None"),
                    subtitle: model.text("不启用 Root", "Root disabled")
                )
                defaultRootRadioOption(
                    value: "adb",
                    title: "Shell Root",
                    subtitle: model.text("通过 Root Shell 调试", "Via root shell")
                )
                defaultRootRadioOption(
                    value: "magisk",
                    title: model.text("完整 Root", "Full Root"),
                    subtitle: model.text("配置 Magisk 权限", "Magisk full root")
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(OnboardingCardMaterial())
        VStack(alignment: .leading, spacing: 14) {
            Text(model.text("全局运行策略", "Global device policies"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(WbColor.textPrimary)

            HStack(alignment: .center, spacing: WbSpace.md) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.text("停止设备时保存快速启动快照", "Save quick-boot snapshot when stopping"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(WbColor.textPrimary)
                    Text(model.text("关闭后，停止设备时仅保存必要状态。", "When off, only essential state is saved on stop."))
                        .font(.system(size: 11.5))
                        .foregroundStyle(WbColor.textSecondary)
                }
                Spacer(minLength: WbSpace.sm)
                HStack(spacing: 10) {
                    Text(policy.quickBoot ? model.text("开启", "On") : model.text("关闭", "Off"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(policy.quickBoot ? WbColor.positive : WbColor.textSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(
                            policy.quickBoot ? WbColor.positive.opacity(0.14) : Color.primary.opacity(0.06),
                            in: Capsule()
                        )
                    Toggle(model.text("停止设备时保存快速启动快照", "Save quick-boot snapshot when stopping"), isOn: $policy.quickBoot)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(WbColor.positive)
                }
            }

            Divider().opacity(0.65)

            policyNumericRow(
                title: model.text("模拟器总内存预算", "Total emulator memory budget"),
                subtitle: model.text("所有设备共享的内存使用上限。", "Combined memory limit shared across all devices."),
                text: $policy.budget,
                unit: "%",
                field: .budget,
                accessibilityLabel: model.text("模拟器总内存预算 (%)", "Total emulator memory budget (%)")
            )

            Divider().opacity(0.65)

            policyNumericRow(
                title: model.text("自动休眠", "Idle sleep"),
                subtitle: model.text("设备空闲达到设定时间后自动休眠，0 表示关闭。", "Sleep idle devices after this time; 0 disables it."),
                text: $policy.idleMinutes,
                unit: model.text("分钟", "min"),
                field: .idle,
                accessibilityLabel: model.text("自动休眠（分钟）", "Idle sleep (minutes)")
            )

            if loaded && policy.parameters == nil {
                Label(model.text("内存预算须为 10–100%，休眠分钟数须为非负整数。", "Use a 10–100% budget and a nonnegative whole number of idle minutes."), systemImage: WbIcon.warning)
                    .wbFont(WbType.caption).foregroundStyle(WbColor.negative)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(OnboardingCardMaterial())
        SettingsSection {
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
                .modifier(SettingsPanelButtonStyle(prominent: true)).tint(WbColor.accent)
                .disabled(!loaded || saving || !policyDirty || policy.parameters == nil)
            }
        }
    }

    private func policyNumericRow(
        title: String,
        subtitle: String,
        text: Binding<String>,
        unit: String,
        field: PolicyField,
        accessibilityLabel: String
    ) -> some View {
        HStack(alignment: .center, spacing: WbSpace.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WbColor.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(WbColor.textSecondary)
            }
            Spacer(minLength: WbSpace.sm)
            HStack(spacing: unit == "%" ? 1 : 4) {
                TextField("", text: text)
                    .textFieldStyle(.plain)
                    .focused($policyFocus, equals: field)
                    .font(.system(size: 12.5))
                    .foregroundStyle(WbColor.textPrimary)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 18)
                    .accessibilityLabel(accessibilityLabel)
                Text(unit)
                    .font(.system(size: 12.5))
                    .foregroundStyle(WbColor.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(width: 116)
            .background(Color.primary.opacity(0.035), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(
                        policyFocus == field ? WbColor.accent : WbColor.borderDefault.opacity(0.8),
                        lineWidth: 1
                    )
            )
            .contentShape(Capsule())
            .onTapGesture { policyFocus = field }
        }
    }

    private func defaultRootRadioOption(value: String, title: String, subtitle: String) -> some View {
        let selected = policy.root == value
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return Button { policy.root = value } label: {
            HStack(alignment: .top, spacing: 9) {
                ZStack {
                    Circle()
                        .strokeBorder(selected ? WbColor.accent : WbColor.borderStrong, lineWidth: selected ? 1.8 : 1.3)
                        .frame(width: 16, height: 16)
                    if selected {
                        Circle()
                            .fill(WbColor.accent)
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(WbColor.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(WbColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selected ? WbColor.accentContainer.opacity(0.65) : Color.primary.opacity(0.035),
                in: shape
            )
            .overlay(
                shape.strokeBorder(
                    selected ? WbColor.accentText.opacity(0.65) : WbColor.borderDefault.opacity(0.8),
                    lineWidth: 1
                )
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? model.text("已选择", "Selected") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: - Data and tools

    @ViewBuilder private var dataPage: some View {
        SettingsSection(model.text("存储", "Storage")) {
            SettingsPathRow(title: model.text("存储目录", "Storage folder"),
                            path: paths.map { MikoStorageRoot.root(forData: $0.data) } ?? model.text("读取中…", "Loading…")) {
                Button(model.text("更改位置…", "Change location…"), action: chooseDataLocation)
                    .modifier(SettingsPanelButtonStyle())
                    .disabled(paths == nil || saving || model.migratingStorage)
                Button(model.text("显示目录", "Show folder")) { showFolder(paths.map { MikoStorageRoot.root(forData: $0.data) }) }
                    .modifier(SettingsPanelButtonStyle())
                    .disabled(paths == nil)
            }
            if let data = paths?.data, let imageRoot = sdkStatus?.custom_sdk,
               !MikoStorageRoot.contains(root: MikoStorageRoot.root(forData: data), path: imageRoot) {
                Text(model.text("部分镜像位于其他位置。更改存储目录时可将它们一并迁移。", "Some images are stored elsewhere. Changing the storage folder can move them together."))
                    .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
            } else {
                Text(model.text("设备、系统镜像和缓存统一存放在此目录。", "Devices, system images and cache are stored in this folder."))
                    .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
            }
            if let migrationProgressMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(migrationProgressMessage)
                        .wbFont(WbType.caption)
                        .foregroundStyle(WbColor.textSecondary)
                    if let migrationProgressValue {
                        ProgressView(value: min(1, max(0, migrationProgressValue)))
                    } else {
                        ProgressView()
                    }
                }
            }
            HStack(alignment: .center, spacing: WbSpace.md) {
                Text(storageSummary)
                    .wbFont(WbType.body)
                    .foregroundStyle(WbColor.textSecondary)
                    .lineLimit(2)
                Spacer(minLength: WbSpace.sm)
                Button(model.text("清理下载缓存…", "Clear download cache…")) { confirmCacheClear = true }
                    .modifier(SettingsPanelButtonStyle())
                    .disabled(saving || cacheBytes == nil || cacheBytes == 0)
            }
        }
    }


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

    // MARK: - Agents

    @ViewBuilder private var agentsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: WbSpace.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.text("智能体", "Agents"))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(WbColor.textPrimary)
                    Text(model.text("连接 AI 编程工具，通过 Miko 控制 Android 设备", "Connect AI coding tools to control Android devices through Miko"))
                        .font(.system(size: 12))
                        .foregroundStyle(WbColor.textSecondary)
                }
                Spacer(minLength: WbSpace.sm)
                AgentRobotBadge()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider().opacity(0.65)

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.text("MCP 服务", "MCP server"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WbColor.textPrimary)
                    Spacer(minLength: WbSpace.sm)
                    Text(model.text("服务连接设置", "Connection settings"))
                        .font(.system(size: 11))
                        .foregroundStyle(WbColor.textTertiary)
                }
                Text(model.text("命令路径", "Command path"))
                    .font(.system(size: 12))
                    .foregroundStyle(WbColor.textSecondary)
                HStack(spacing: 8) {
                    TextField("", text: $mcpBinary, prompt: Text("miko"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundStyle(WbColor.textPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Color.primary.opacity(0.035), in: Capsule())
                        .overlay(Capsule().strokeBorder(WbColor.borderDefault.opacity(0.8), lineWidth: 1))
                        .accessibilityLabel(model.text("MCP 命令路径", "MCP command path"))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(mcpBinary, forType: .string)
                        message = model.text("MCP 命令路径已复制。", "MCP command path copied.")
                    } label: {
                        Image(systemName: WbIcon.copy)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(WbColor.textSecondary)
                            .frame(width: 40, height: 32)
                            .background(Color.primary.opacity(0.035), in: Capsule())
                            .overlay(Capsule().strokeBorder(WbColor.borderDefault.opacity(0.8), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(mcpBinary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help(model.text("复制命令路径", "Copy command path"))
                    .accessibilityLabel(model.text("复制命令路径", "Copy command path"))
                }
                Text(model.text("选择 Miko 可执行文件，用于配置支持 MCP 的客户端。",
                                "Choose the Miko executable to configure MCP-compatible clients."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(WbColor.textSecondary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider().opacity(0.65)

            VStack(alignment: .leading, spacing: 12) {
                Text(model.text("客户端配置", "Client configuration"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(WbColor.textPrimary)

                agentClientRow(
                    icon: "terminal",
                    title: "Codex",
                    subtitle: model.text("OpenAI 编程工具", "OpenAI coding tool"),
                    onCopy: {
                        guard let text = try? MCPConfiguration.configuration(command: mcpBinary) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        message = model.text("MCP 配置已复制。", "MCP configuration copied.")
                    },
                    onConfigure: { confirmCodexConfig = true }
                )

                Divider().opacity(0.65)

                agentClientRow(
                    icon: "desktopcomputer",
                    title: "WorkBuddy",
                    subtitle: model.text("AI 工作助手", "AI work assistant"),
                    onCopy: {
                        guard let data = try? MCPConfiguration.workBuddyConfiguration(command: mcpBinary),
                              let text = String(data: data, encoding: .utf8) else { return }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        message = model.text("MCP 配置已复制。", "MCP configuration copied.")
                    },
                    onConfigure: { confirmWorkBuddyConfig = true }
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider().opacity(0.65)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: WbIcon.deviceEmpty)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(WbColor.textSecondary)
                    Text(model.text("Android 沙盒与自动化", "Android sandbox & automation"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WbColor.textPrimary)
                }
                Text(model.text("AI 智能体可以使用临时 Android 设备进行截图、点击、界面分析和自动化操作。会话结束后自动清理，不影响主力设备。",
                                "AI agents can use ephemeral Android devices for screenshots, taps, UI inspection and automation. Sessions are cleaned up automatically without affecting your primary devices."))
                    .font(.system(size: 12))
                    .foregroundStyle(WbColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(OnboardingCardMaterial())
    }

    private func agentClientRow(
        icon: String,
        title: String,
        subtitle: String,
        onCopy: @escaping () -> Void,
        onConfigure: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.035))
                .frame(width: 36, height: 36)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(WbColor.borderDefault.opacity(0.8), lineWidth: 1)
                )
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(WbColor.textPrimary)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WbColor.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(WbColor.textSecondary)
            }
            Spacer(minLength: WbSpace.sm)
            Button(model.text("复制配置", "Copy config"), action: onCopy)
                .buttonStyle(AgentPillButtonStyle(prominent: false))
            Button(model.text("配置…", "Configure…"), action: onConfigure)
                .buttonStyle(AgentPillButtonStyle(prominent: true))
                .disabled(saving)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Advanced

    @ViewBuilder private var advancedPage: some View {
        SettingsSection(model.text("地图", "Maps")) {
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
                .modifier(SettingsPanelButtonStyle())
                .disabled(saving)
            }
        }
    }

    // MARK: - About

    @ViewBuilder private var aboutPage: some View {
        SettingsSection(model.text("关于", "About")) {
            VStack(spacing: WbSpace.xs + 2) {
                appIcon
                Text(model.text("miko 模拟器", "miko simulator"))
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
                    .modifier(SettingsPanelButtonStyle(prominent: true)).tint(WbColor.accent)
                    .disabled(checkingUpdate || about == nil)
                if let releaseURL {
                    Button(model.text("查看新版本", "View new version")) { NSWorkspace.shared.open(releaseURL) }
                        .modifier(SettingsPanelButtonStyle())
                }
                Button(model.text("源代码", "Source code")) {
                    if let value = about?.repository, let url = URL(string:value) { NSWorkspace.shared.open(url) }
                }
                .modifier(SettingsPanelButtonStyle())
                .disabled(about == nil)
                Button(model.text("许可证", "Licenses")) {
                    if let value = about?.repository, let url = URL(string:value + "/blob/master/NOTICE") { NSWorkspace.shared.open(url) }
                }
                .modifier(SettingsPanelButtonStyle())
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

    private func settingsActionButton(_ title: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
        .modifier(SettingsPanelButtonStyle())
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
        button.identifier = NSUserInterfaceItemIdentifier("miko-device-more:\(device.id)")
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
                let symbols = [6: "shield", 12: "arrow.clockwise", 13: "trash", 14: "moon.zzz"]
                if let symbol = symbols[tag], let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                    if destructive && enabled,
                       let redImage = image.withSymbolConfiguration(.init(paletteColors: [.systemRed])) {
                        redImage.isTemplate = false
                        item.image = redImage
                    } else {
                        image.isTemplate = true
                        item.image = image
                    }
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
                add("休眠", "Hibernate", 14, enabled: device.running && !model.busy.contains(device.id) && model.busyHolder(for: device.id) == nil)
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
            case 14: model.hibernate(device.id)
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
    private var centerSurface: Color { Color(nsColor: .underPageBackgroundColor) }

    var selectedDevice: Device? { model.devices.first(where: {$0.id == model.selected}) }
    private var filteredDevices: [Device] {
        model.filteredDevices
    }

    // MARK: Body

    var body: some View {
        let base = ZStack {
            GeometryReader { _ in
                VStack(spacing: WbSpace.zero) {
                    if ProcessInfo.processInfo.environment["MIKO_UI_PREVIEW"] == "1" {
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
                        .overlay(alignment: .bottom) {
                            if model.isEmptyDeviceLibrary, let toast = model.toast {
                                ToastOverlay(toast: toast) { model.dismissToast() }
                                    .frame(maxWidth: 440)
                                    .padding(.horizontal, WbSpace.lg)
                            }
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
            }
        }
        .frame(minWidth:800,minHeight:550)
        .background(CenterWindowChrome(model: model).frame(width: 0, height: 0))
        .environment(\.locale, Locale(identifier:model.language == 0 ? "en" : "zh-Hans"))
        .preferredColorScheme(model.colorScheme)
        return base
        .accessibilityHidden(model.sheet == .newDevice || model.sheet == .snapshots || model.sheet == .folderSync || model.sheet == .edit || model.sheet == .imageManagement)
        .onChange(of: model.isEmptyDeviceLibrary) { empty in
            if empty { model.deviceQuery = "" }
        }
        .modifier(CenterAPKDrop(model: model))
        .sheet(item: Binding(get: { model.sheet == .setupSDK ? model.sheet : nil },
                             set: { if $0 == nil { model.dismissSDKSheet() } }), onDismiss: model.sdkSheetDidDismiss) { _ in
            NewDeviceView(model: model, standaloneSDKSetup: true)
                .environment(\.locale, Locale(identifier: model.language == 0 ? "en" : "zh-Hans"))
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

    @ViewBuilder private var layout: some View {
        if model.isEmptyDeviceLibrary {
            NewDeviceView(model: model, inline: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    ZStack {
                        CenterOnboardingGlass()
                        Color(nsColor: .windowBackgroundColor).opacity(0.75)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
        } else {
            navigationLayout
        }
    }

    private var navigationLayout: some View { nativeNavigationLayout }

    private var nativeNavigationLayout: some View {
        NavigationSplitView(columnVisibility: Binding(
            get: { model.sidebarVisible ? .all : .detailOnly },
            set: { model.sidebarVisible = $0 != .detailOnly }
        )) {
            DeviceLibrarySidebar(model: model)
                .navigationSplitViewColumnWidth(min: 250, ideal: 270, max: 300)
        } detail: {
            libraryDetail
                .background(centerSurface, ignoresSafeAreaEdges: [.top, .bottom, .trailing])
                .overlay(alignment: .bottom) { libraryToast }
        }
    }

    private var libraryDetail: some View {
        Group {
            if model.showingAllDevices {
                AllDevicesView(model: model)
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

    @ViewBuilder private var libraryToast: some View {
        if !model.isEmptyDeviceLibrary, let toast = model.toast {
            ToastOverlay(toast: toast) { model.dismissToast() }
                .frame(maxWidth: 440)
                .padding(.horizontal, WbSpace.lg)
        }
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
