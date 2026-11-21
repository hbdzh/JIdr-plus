// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers

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
                            .help(name)
                            .accessibilityLabel(model.text("设备名称", "Device name"))
                    }
                    LabeledContent(model.text("系统镜像", "System image"), value: details.device.imageLabel)
                        .help(details.device.imageLabel)
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
                        }.buttonStyle(WbPillButtonStyle()).disabled(saving)
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
                        .buttonStyle(WbPillButtonStyle()).controlSize(.regular)
                        .disabled(!details.device.stopped || saving)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .disabled(saving)

            DeviceSheetFooter(note: model.text("部分更改将在下次启动设备时生效。", "Some changes apply the next time the device starts.")) {
                Button(model.text("取消", "Cancel")) { closePanel() }
                    .buttonStyle(WbPillButtonStyle()).controlSize(.regular)
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
