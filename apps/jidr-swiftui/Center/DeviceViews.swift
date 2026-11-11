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

// MARK: - Shared sheet chrome

/// Title + subtitle + circular close button, used by the device sheets.
private struct DeviceSheetHeader: View {
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
private struct DeviceSheetFooter<Actions: View>: View {
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
    private var rootHealthTone: WbStatusTone {
        switch details.device.root.health {
        case "ok": return .running
        case "failed": return .error
        case "unverified": return .starting
        default: return .neutral
        }
    }
    private var statusTone: WbStatusTone {
        switch details.device.status.state {
        case "running": return .running
        case "starting", "booting", "stopping": return .starting
        case "crashed": return .error
        default: return .stopped
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            DeviceSheetHeader(title: model.text("设备详情", "Device details"),
                              subtitle: details.device.name)
            Form {
                Section {
                    HStack(alignment: .center, spacing: WbSpace.md) {
                        WbDeviceThumbnail(name: "device-detail", width: 52, height: 94)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(details.device.name)
                                .wbFont(WbType.title)
                                .foregroundStyle(WbColor.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack(spacing: WbSpace.sm) {
                                WbStatusLabel(text: details.device.statusText(language: model.language), tone: statusTone)
                                Text(details.device.androidVersion)
                                    .wbFont(WbType.caption)
                                    .foregroundStyle(WbColor.textSecondary)
                            }
                            Text(details.device.imageLabel + " · " + details.device.profileLabel)
                                .wbFont(WbType.caption)
                                .foregroundStyle(WbColor.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: WbSpace.md)
                        HStack(spacing: WbSpace.sm) {
                            if details.device.running {
                                Button(model.text("打开设备", "Open device")) { model.focusOrOpenDeviceWindow(details.device.id) }
                                    .buttonStyle(.borderedProminent).controlSize(.regular).tint(WbColor.accent)
                                Button(model.text("停止", "Stop"), systemImage: WbIcon.stop) { model.stop(details.device.id) }
                                    .buttonStyle(.bordered).controlSize(.regular)
                                    .disabled(model.busy.contains(details.device.id))
                            } else if details.device.stopped {
                                Button(model.text("启动设备", "Start device")) { model.start(details.device.id) }
                                    .buttonStyle(.borderedProminent).controlSize(.regular).tint(WbColor.accent)
                                    .disabled(model.busy.contains(details.device.id))
                            }
                        }
                    }
                    .padding(.vertical, WbSpace.xs)
                }

                Section(model.text("设备概览", "Overview")) {
                    LabeledContent(model.text("状态", "Status")) {
                        WbStatusLabel(text: details.device.statusText(language: model.language), tone: statusTone)
                    }
                    if let holder = model.busyHolder(for: details.device.id) {
                        LabeledContent(model.text("占用", "Busy")) {
                            Text(holder).foregroundStyle(WbColor.warning).lineLimit(1)
                        }
                    }
                    LabeledContent(model.text("设备 ID", "Device ID")) {
                        HStack(spacing: WbSpace.xs) {
                            Text(details.device.id)
                                .wbFont(WbType.code)
                                .foregroundStyle(WbColor.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(details.device.id, forType: .string)
                            } label: {
                                Image(systemName: WbIcon.copy)
                                    .font(.system(size: 12))
                                    .frame(width: 22, height: 22)
                            }
                            .buttonStyle(.borderless)
                            .help(model.text("复制设备 ID", "Copy device ID"))
                            .accessibilityLabel(model.text("复制设备 ID", "Copy device ID"))
                        }
                    }
                }

                Section("Android") {
                    LabeledContent(model.text("版本", "Version"), value: details.device.androidVersion)
                    LabeledContent(model.text("镜像", "Image"), value: details.device.imageLabel)
                    LabeledContent(model.text("配置", "Profile"), value: details.device.profileLabel)
                    LabeledContent(model.text("序列号", "Serial"), value: details.device.runtime?.adb_serial ?? "—")
                    LabeledContent("SDK") {
                        Text(details.device.sdk_root)
                            .wbFont(WbType.code)
                            .foregroundStyle(WbColor.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(details.device.sdk_root)
                            .textSelection(.enabled)
                    }
                }

                Section(model.text("会话", "Session")) {
                    LabeledContent(model.text("运行时长", "Uptime"), value: model.sessionUptime(details.device) ?? "—")
                    LabeledContent(model.text("上次启动", "Last started"), value: model.sessionStarted(details.device) ?? "—")
                    LabeledContent(model.text("控制台端口", "Console port"),
                                   value: details.device.runtime?.console_port.map(String.init) ?? "—")
                    LabeledContent(model.text("gRPC 端口", "gRPC port"),
                                   value: details.device.runtime?.grpc_port.map(String.init) ?? "—")
                    LabeledContent(model.text("进程 ID", "Process ID"),
                                   value: details.device.runtime?.pid.map(String.init) ?? "—")
                }

                Section(model.text("硬件", "Hardware")) {
                    LabeledContent(model.text("内存", "Memory"), value: "\(details.config["hw.ramSize"] ?? "—") MB")
                    LabeledContent("CPU", value: model.text("\(details.config["hw.cpu.ncore"] ?? "—") 核",
                                                            "\(details.config["hw.cpu.ncore"] ?? "—") cores"))
                    LabeledContent(model.text("屏幕", "Screen"),
                                   value: "\(details.config["hw.lcd.width"] ?? "—") × \(details.config["hw.lcd.height"] ?? "—")")
                    if let bytes = details.disk_usage {
                        LabeledContent(model.text("磁盘占用", "Disk usage"),
                                       value: ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file))
                    }
                }

                Section(model.text("Root 状态", "Root status")) {
                    LabeledContent(model.text("模式", "Mode"), value: rootModeText)
                    if let magisk = details.device.root.magisk_version, !magisk.isEmpty {
                        LabeledContent("Magisk", value: magisk)
                    }
                    LabeledContent(model.text("验证", "Verification")) {
                        WbStatusLabel(text: rootHealthText, tone: rootHealthTone)
                    }
                    LabeledContent(model.text("更改 Root 模式", "Change root mode")) {
                        Picker("", selection: $selectedRoot) {
                            Text(model.text("无", "None")).tag("none")
                            Text("Shell root").tag("adb")
                            Text(model.text("完整 root", "Full root")).tag("magisk")
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        .disabled(!details.device.stopped)
                        .accessibilityLabel(model.text("更改 Root 模式", "Change root mode"))
                    }
                    HStack(spacing: WbSpace.sm) {
                        Button(model.text("Root 高级工具…", "Root tools…")) {
                            model.openAdvanced(details.device.id, name: details.device.name, root: true)
                        }
                        .buttonStyle(.bordered).controlSize(.regular)
                        .disabled(!details.device.running)
                        Button(model.text("更改 Root 模式…", "Change root mode…")) { confirmRootChange = true }
                            .buttonStyle(.bordered).controlSize(.regular)
                            .disabled(!details.device.stopped || selectedRoot == details.device.root.mode)
                        if details.device.root.mode == "magisk" {
                            Button(model.text("设置或重试完整 Root…", "Set up or retry full root…")) { confirmRootSetup = true }
                                .buttonStyle(.bordered).controlSize(.regular)
                                .disabled(model.busy.contains(details.device.id))
                        }
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: WbSpace.sm) {
                        Button(model.text("再次验证", "Verify again")) {
                            model.operation("root.verify", id: details.device.id)
                        }
                        .buttonStyle(.bordered).controlSize(.regular)
                        .disabled(!details.device.running)
                        Button(model.text("恢复为无 Root", "Revert to no root"), role: .destructive) {
                            confirmRevert = true
                        }
                        .buttonStyle(.bordered).controlSize(.regular)
                        .disabled(!details.device.stopped || details.device.root.mode == "none")
                        Spacer(minLength: 0)
                    }
                    if !details.device.stopped {
                        Text(model.text("请先停止设备，再更改 Root 模式。", "Stop the device before changing the root mode."))
                            .wbFont(WbType.caption)
                            .foregroundStyle(WbColor.textSecondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(WbColor.raised)

            DeviceSheetFooter(note: "") {
                Button(model.text("关闭", "Close")) { dismiss() }
                    .buttonStyle(.bordered).controlSize(.regular)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 620, height: 700)
        .background(WbColor.raised)
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

                Section(model.text("启动与外设", "Startup & peripherals")) {
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
                        TextField(model.text("默认", "Default"), text: $sleepMinutes)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 110)
                            .accessibilityLabel(model.text("自动休眠", "Auto sleep"))
                    }
                    Text(model.text("单位为分钟；留空跟随全局，0 为关闭。", "Minutes; leave blank for the global setting, or use 0 to turn off."))
                        .wbFont(WbType.caption)
                        .foregroundStyle(WbColor.textSecondary)
                    LabeledContent(model.text("后置摄像头", "Rear camera")) {
                        cameraPicker($cameraBack, includesVirtualScene: true, label: model.text("后置摄像头", "Rear camera"))
                    }
                    LabeledContent(model.text("前置摄像头", "Front camera")) {
                        cameraPicker($cameraFront, includesVirtualScene: false, label: model.text("前置摄像头", "Front camera"))
                    }
                }
                .disabled(!details.device.stopped || saving)

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
                            Button(model.text("保存画质", "Save quality")) { saveQuality() }
                                .buttonStyle(.bordered).controlSize(.regular)
                                .disabled(!qualityLoaded)
                        }
                    }
                    Text(model.text("只改变画面传输分辨率，不改变游戏帧率。", "Only the streamed resolution changes; the game frame rate is untouched."))
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
        .frame(width: 560, height: 620)
        .background(WbColor.raised)
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

    // MARK: Helpers

    private func numberField(_ value: Binding<String>, label: String) -> some View {
        TextField("", text: value)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 110)
            .accessibilityLabel(label)
    }

    private func cameraPicker(_ selection: Binding<String>, includesVirtualScene: Bool, label: String) -> some View {
        Picker("", selection: selection) {
            Text(model.text("默认", "Default")).tag("default")
            Text(model.text("禁用", "Disabled")).tag("none")
            Text(model.text("模拟", "Emulated")).tag("emulated")
            if includesVirtualScene {
                Text(model.text("虚拟场景", "Virtual scene")).tag("virtualscene")
            }
            Text(model.text("Mac 摄像头 1", "Mac camera 1")).tag("webcam0")
            Text(model.text("Mac 摄像头 2", "Mac camera 2")).tag("webcam1")
        }
        .labelsHidden()
        .frame(width: 180)
        .accessibilityLabel(label)
    }

    private func saveQuality() {
        do {
            guard let path = model.dataDirectory else { return }
            try WindowQualityStore(dataDirectory:path,device:details.device.id).save(UInt8(quality))
            qualityMessage = model.text("画质已保存，下次打开窗口生效。", "Quality saved; it applies next time the window opens.")
        } catch { qualityMessage = error.localizedDescription }
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
                if let existing = sdkStatus?.tools_sdk {
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
        } label: { Label(t("使用现有 SDK", "Use an existing SDK"), systemImage: "folder").font(.system(size: 12, weight: .semibold)) }

        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(t("系统镜像", "System image"))
                    Spacer(minLength: 16)
                    Picker(t("系统镜像", "System image"), selection: $selection) {
                        Text(t("仅安装模拟器工具", "Emulator tools only")).tag("")
                        ForEach(images.filter { $0.installed_in == nil }) { image in
                            Text("Android API \(image.api) · \(Device.imageTagLabel(image.tag)) · \(image.abi)").tag(image.id)
                        }
                    }.labelsHidden().frame(maxWidth: 360).disabled(loading || loadingImages)
                }
                if let location = sdkStatus?.private_sdk {
                    Text(t("下载位置：\(location)", "Download location: \(location)"))
                        .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary).textSelection(.enabled)
                }
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
                            Text("Shell root").tag("adb")
                            Text(model.text("完整 root", "Full root")).tag("magisk")
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
                    .disabled(saving || images.isEmpty || profiles.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 520, height: 520)
        .background(WbColor.raised)
        .onAppear {
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
    let onClose: () -> Void
    private var category: Int { model.settingsCategory }
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
        Section(model.text("设备默认设置", "Device defaults")) {
            Picker(selection: $root) {
                Text(model.text("无", "None")).tag("none")
                Text("Shell root").tag("adb")
                Text(model.text("完整 root", "Full root")).tag("magisk")
            } label: {
                Text(model.text("默认 Root 模式", "Default root mode"))
            }
            Toggle(model.text("停止设备时保存快速启动快照", "Save quick-boot snapshot when stopping"), isOn: $quickBoot)
                .toggleStyle(.switch)
                .tint(WbColor.accent)
            LabeledContent {
                TextField("", text: $budget)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 92)
                    .accessibilityLabel(model.text("设备内存预算 (%)", "Device memory budget (%)"))
            } label: {
                Text(model.text("设备内存预算 (%)", "Device memory budget (%)"))
            }
            LabeledContent {
                TextField("", text: $autoHibernate)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 92)
                    .accessibilityLabel(model.text("自动休眠分钟数", "Idle sleep minutes"))
            } label: {
                Text(model.text("自动休眠分钟数", "Idle sleep minutes"))
            }
            Text(model.text("内存预算 10–100；自动休眠 0 为关闭。", "Memory budget 10–100; idle sleep 0 disables it."))
                .wbFont(WbType.caption)
                .foregroundStyle(WbColor.textSecondary)
        }
        Section {
            HStack(alignment: .center, spacing: WbSpace.md) {
                Text(model.text("更改会应用到之后创建的设备。", "Changes apply to devices created later."))
                    .wbFont(WbType.caption)
                    .foregroundStyle(WbColor.textSecondary)
                Spacer(minLength: WbSpace.sm)
                Button(model.text("保存默认设置", "Save defaults")) {
                    guard let percent = UInt8(budget), (10...100).contains(percent), let minutes = UInt32(autoHibernate) else {
                        message = model.text("内存预算必须为 10–100%，自动休眠时间必须为非负整数。", "Memory budget must be 10–100%; idle sleep must be a nonnegative integer."); return
                    }
                    saving = true
                    model.call("settings.set",["default_root_mode":root,"quick_boot":quickBoot,"budget_percent":percent,"auto_hibernate_minutes":minutes]) { result in
                        saving = false
                        switch result { case .success: message = model.text("已保存", "Saved"); case .failure(let failure): message = failure.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent).controlSize(.regular).tint(WbColor.accent)
                .disabled(!loaded || saving)
            }
        }
    }

    // MARK: - Data and tools

    @ViewBuilder private var dataPage: some View {
        Section(model.text("位置与存储", "Locations & storage")) {
            SettingsPathRow(title: model.text("数据目录", "Data folder"),
                            path: paths?.data ?? model.text("读取中…", "Loading…")) {
                Button(model.text("显示数据目录", "Show data folder")) { showFolder(paths?.data) }
                    .buttonStyle(.bordered).controlSize(.regular)
                    .disabled(paths == nil)
            }
            SettingsPathRow(title: "Android SDK",
                            path: paths?.tools.android_sdk ?? sdkStatus?.tools_sdk ?? model.text("自动选择", "Automatic")) {
                Button(model.text("选择 SDK", "Choose SDK")) { choose("sdk") }
                    .buttonStyle(.bordered).controlSize(.regular)
                    .disabled(paths == nil || saving)
                linkButton(model.text("恢复自动选择", "Restore automatic"), disabled: paths == nil || saving) { tool("sdk",path:NSNull()) }
                linkButton(model.text("显示目录", "Show folder"), disabled: paths?.tools.android_sdk == nil && sdkStatus?.tools_sdk == nil) {
                    showFolder(paths?.tools.android_sdk ?? sdkStatus?.tools_sdk)
                }
                Spacer(minLength: 0)
                Button(model.text("安装 SDK 和系统镜像…", "Install SDK & system images…")) { installing = true }
                    .buttonStyle(.bordered).controlSize(.regular)
                    .disabled(saving)
            }
            SettingsPathRow(title: "JDK",
                            path: paths?.tools.jdk_home ?? model.text("系统默认", "System default")) {
                Button(model.text("选择 JDK", "Choose JDK")) { choose("jdk") }
                    .buttonStyle(.bordered).controlSize(.regular)
                    .disabled(paths == nil || saving)
                linkButton(model.text("恢复系统默认", "Restore system default"), disabled: paths == nil || saving) { tool("jdk",path:NSNull()) }
            }
            SettingsPathRow(title: model.text("迁移目标", "Migration destination"),
                            path: migrationParent.map { $0.appendingPathComponent("Jidr").path } ?? model.text("未选择", "Not selected")) {
                Button(model.text("选择目标位置…", "Choose destination…")) { chooseMigrationParent() }
                    .buttonStyle(.bordered).controlSize(.regular)
                    .disabled(saving || migrationChecking)
                Button(model.text("初步检查", "Preliminary check")) { checkMigration() }
                    .buttonStyle(.bordered).controlSize(.regular)
                    .disabled(migrationParent == nil || saving || migrationChecking)
            }
            Text(model.text("目前仅支持初步检查；尚不能迁移或切换数据位置。", "Only preliminary checks are available; migration and switching are not yet supported."))
                .wbFont(WbType.caption)
                .foregroundStyle(WbColor.textSecondary)
            if !migrationMessage.isEmpty {
                Text(migrationMessage)
                    .wbFont(WbType.caption)
                    .foregroundStyle(WbColor.textSecondary)
                    .textSelection(.enabled)
            }
        }
        Section(model.text("存储用量", "Storage usage")) {
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
                TextField("", text: $tileURL)
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
                TextField("", text: $mcpBinary)
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

struct CenterView: View {
    @ObservedObject var model: CenterModel

    var selectedDevice: Device? { model.devices.first(where: {$0.id == model.selected}) }
    private var filteredDevices: [Device] {
        model.devices.filter { model.deviceQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(model.deviceQuery) }
    }

    // MARK: Body

    var body: some View {
        ZStack {
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
                    if !model.notice.isEmpty {
                        Text(model.displayNotice)
                            .wbFont(WbType.caption)
                            .foregroundStyle(WbColor.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, WbSpace.lg)
                            .padding(.bottom, WbSpace.sm)
                    }
                }
                .background(WbColor.surface)
            }
            if let toast = model.toast {
                VStack { Spacer(); ToastOverlay(toast:toast) { model.dismissToast() } }
            }
        }
        .frame(minWidth:800,minHeight:550)
        .background(WbColor.surface.ignoresSafeArea(.container, edges: .top))
        .background(CenterWindowChrome(model: model).frame(width: 0, height: 0))
        .environment(\.locale, Locale(identifier:model.language == 0 ? "en" : "zh-Hans"))
        .preferredColorScheme(model.colorScheme)
        .onChange(of:model.paletteOpen) { open in
            if !open, model.sheet == nil, !model.tasksOpen { model.searchFocusRequest += 1 }
        }
        .onChange(of:model.tasksOpen) { open in
            if !open, model.sheet == nil, !model.paletteOpen { model.searchFocusRequest += 1 }
        }
        .sheet(item:$model.sheet) { sheet in
            Group {
                switch sheet {
                case .newDevice: NewDeviceView(model:model)
                case .setupSDK: InstallSDKView(model:model)
                case .settings: EmptyView() // Routed to the independent settings window.
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
            let name = prompt.apkName
            let zh = "“\(name)”与设备上已安装的应用签名不一致。继续会先卸载现有应用，并删除其应用数据。"
            let en = "“\(name)” was signed with a different key than the installed app. Continuing uninstalls the existing app first, which deletes its data."
            Text(model.text(zh, en))
        }
    }

    // MARK: Layout

    @ViewBuilder private var layout: some View {
        if model.isEmptyDeviceLibrary {
            emptyDeviceState
        } else {
            HSplitView {
                VStack(spacing: 0) {
                    deviceListCard
                    WbDivider()
                    quickActionsCard
                }
                .frame(minWidth: 300, idealWidth: 330, maxWidth: model.detailsVisible ? 420 : .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                if model.detailsVisible {
                    VStack(spacing: 0) {
                        // Only the inspector scrolls vertically; the app list keeps
                        // its own distinct, bounded list below it.
                        ScrollView { detailCard }.frame(height: 330)
                        WbDivider()
                        appsCard
                    }
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(WbSpace.md)
        }
    }

    // MARK: Device list

    private var deviceListCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: WbSpace.sm) {
                Text(model.text("我的设备", "My devices"))
                    .wbFont(WbType.title)
                    .foregroundStyle(WbColor.textPrimary)
                Text("\(model.devices.count)")
                    .wbFont(WbType.label)
                    .foregroundStyle(WbColor.textSecondary)
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(WbColor.control, in: RoundedRectangle(cornerRadius: WbRadius.xs, style: .continuous))
                Spacer(minLength: WbSpace.sm)
            }
            .padding(.horizontal, WbSpace.lg)
            .padding(.top, WbSpace.md)
            .padding(.bottom, WbSpace.sm)

            if !model.deviceListLoaded {
                CenterQuietState(icon: WbIcon.deviceEmpty,
                                 text: model.text("正在加载设备…", "Loading devices…"),
                                 height: 180, showsProgress: true)
            } else if filteredDevices.isEmpty {
                CenterQuietState(icon: WbIcon.search,
                                 text: model.text("没有匹配的设备", "No matching devices"), height: 140)
            } else {
                List(selection: deviceSelection) {
                    ForEach(filteredDevices) { device in
                        deviceListRow(device)
                            .tag(device.id)
                            .listRowInsets(EdgeInsets(top: 3, leading: WbSpace.sm + 2,
                                                      bottom: 3, trailing: WbSpace.sm + 2))
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)
            }

            if model.deviceListLoaded && !model.devices.isEmpty {
                HStack(spacing: WbSpace.xs) {
                    Image(systemName: WbIcon.info).font(.system(size: 10))
                    Text(model.text("双击设备可直接打开设备窗口", "Double-click a device to open its window"))
                        .wbFont(WbType.caption)
                    Spacer(minLength: WbSpace.sm)
                    Text(model.text("共 \(model.devices.count) 台设备", "\(model.devices.count) devices"))
                        .wbFont(WbType.caption)
                }
                .foregroundStyle(WbColor.textTertiary)
                .padding(.horizontal, WbSpace.lg)
                .padding(.vertical, WbSpace.sm + 2)
                .overlay(alignment: .top) { WbDivider() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var deviceSelection: Binding<String?> {
        Binding(get: { model.selected }, set: { newValue in
            model.setDeviceSelection(newValue)
        })
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

    private func deviceListRow(_ device: Device) -> some View {
        return HStack(spacing: WbSpace.sm + 2) {
            HStack(spacing: WbSpace.sm + 2) {
                WbDeviceThumbnail(name: "device-list", width: 36, height: 62)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .wbFont(WbType.body.weighted(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: WbSpace.xs) {
                        if let holder = model.busyHolder(for: device.id) {
                            statusText(holder, tone: .busy)
                        } else {
                            statusText(device.statusText(language: model.language), tone: statusTone(device))
                        }
                        if let progress = model.progress(for: device.id) {
                            Text(progress)
                                .wbFont(WbType.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text(deviceMeta(device))
                        .wbFont(WbType.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let fraction = model.bootProgressFraction(for: device.id), device.running == false {
                        ProgressView(value: min(max(fraction, 0), 1))
                            .progressViewStyle(.linear)
                            .frame(height: 3)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: WbSpace.sm)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.text("\(device.name)，\(device.statusText(language: model.language))",
                                           "\(device.name), \(device.statusText(language: 0))"))
            .accessibilityHint(model.text("按 Return 打开设备窗口，或选择设备后使用常用操作。",
                                          "Press Return to open the device window, or use the quick actions after selecting it."))
            .accessibilityAction(named: Text(model.text("打开设备窗口", "Open device window"))) {
                model.focusOrOpenDeviceWindow(device.id)
            }
            rowAction(device)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            deviceMenuItems(device)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.focusOrOpenDeviceWindow(device.id)
        })
    }

    @ViewBuilder private func rowAction(_ device: Device) -> some View {
        let busy = model.busy.contains(device.id)
        switch device.status.state {
        case "running":
            rowIconButton("arrow.up.forward.app", help: model.text("打开设备", "Open device"),
                          disabled: false) {
                model.focusOrOpenDeviceWindow(device.id)
            }
        case "starting", "booting":
            rowIconButton("xmark.circle", help: model.text("取消启动", "Cancel start"),
                          disabled: busy) {
                model.stop(device.id)
            }
        case "stopping":
            ProgressView().controlSize(.small).frame(width: 24, height: 24)
        default:
            rowIconButton("play.fill", help: model.text("启动设备", "Start device"),
                          disabled: busy) {
                model.start(device.id)
            }
        }
    }

    private func rowIconButton(_ symbol: String, help: String,
                               disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private func statusText(_ text: String, tone: WbStatusTone) -> some View {
        HStack(spacing: WbSpace.xxs + 2) {
            Circle().fill(tone.color).frame(width: 6, height: 6)
            Text(text).wbFont(WbType.label).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func deviceMenuItems(_ device: Device) -> some View {
        Button(model.text("设备设置…", "Device settings…")) {
            model.select(device.id)
            model.presentDeviceSheet(.edit, device: device.id)
        }
        .disabled(model.busy.contains(device.id))
        Button(model.text("重启", "Restart")) { model.restart(device.id) }
            .disabled(!device.running || model.busy.contains(device.id))
        Divider()
        Button(model.text("删除设备…", "Delete device…"), role: .destructive) {
            model.select(device.id)
            model.deleteRequested = true
        }
        .disabled(!device.stopped || model.busy.contains(device.id))
    }

    // MARK: Direct device actions

    private var quickActionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.text("常用操作", "Quick actions"))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(WbColor.textSecondary)
            ActionFlowLayout(spacing: 8) {
                quickAction(model.text("安装 APK", "Install APK"), WbIcon.installAPK, enabled: selectedDevice?.running == true) {
                    if let device = selectedDevice { model.chooseFile(device: device.id, apk: true) }
                }
                quickAction(model.text("截图", "Screenshot"), WbIcon.camera, enabled: selectedDevice?.running == true) {
                    if let device = selectedDevice { model.screenshot(device: device.id) }
                }
                quickAction(recordingLabel, WbIcon.record, enabled: selectedDevice?.running == true) {
                    if let device = selectedDevice { model.toggleRecording(device: device.id) }
                }
                quickAction(model.text("管理快照", "Snapshots"), WbIcon.quickBoot, enabled: selectedDevice != nil) { model.present(.snapshots) }
                quickAction(model.text("发送文件", "Send file"), WbIcon.folder, enabled: selectedDevice?.running == true) {
                    if let device = selectedDevice { model.chooseFile(device: device.id, apk: false) }
                }
                quickAction(model.text("截图目录", "Screenshots folder"), "photo.on.rectangle", enabled: true) { model.openScreenshotFolder() }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.text("常用操作", "Quick actions"))
    }

    private var recordingLabel: String {
        guard let device = selectedDevice else { return model.text("录屏", "Record") }
        return model.recording.contains(device.id)
            ? model.text("停止录屏", "Stop recording")
            : model.text("录屏", "Record")
    }

    private func quickAction(_ title: String, _ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).font(.system(size: 12)).fixedSize() }
            .buttonStyle(.bordered).controlSize(.regular)
            .disabled(!enabled)
    }

    // MARK: Detail card

    private var detailCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: WbSpace.sm) {
                Text(model.text("设备详情", "Device details"))
                    .wbFont(WbType.title)
                    .foregroundStyle(WbColor.textPrimary)
                Spacer(minLength: WbSpace.sm)
                if selectedDevice != nil {
                    Button {
                        if let device = selectedDevice { model.presentDeviceSheet(.details, device: device.id) }
                    } label: {
                        HStack(spacing: 3) {
                            Text(model.text("查看设备详情", "View details")).wbFont(WbType.label)
                            Image(systemName: WbIcon.chevronRight).font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(WbColor.accentText)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.details == nil)
                }
            }
            .padding(.horizontal, WbSpace.lg)
            .padding(.top, WbSpace.md)
            .padding(.bottom, WbSpace.sm)

            if let device = selectedDevice {
                VStack(alignment: .leading, spacing: WbSpace.sm + 2) {
                    HStack(spacing: WbSpace.sm + 2) {
                        WbDeviceThumbnail(name:"device-detail", width: 36, height: 62)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name)
                                .wbFont(WbType.title)
                                .foregroundStyle(WbColor.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            WbStatusLabel(text: device.statusText(language: model.language), tone: statusTone(device))
                            Text(device.androidVersion)
                                .wbFont(WbType.caption)
                                .foregroundStyle(WbColor.textSecondary)
                        }
                        Spacer(minLength: WbSpace.sm)
                        detailPrimaryAction(device)
                    }
                    WbDivider()
                    if let d = model.details {
                        detailInfoGrid(d, device)
                    } else {
                        CenterQuietState(icon: WbIcon.info,
                                         text: model.text("正在读取设备详情…", "Loading device details…"),
                                         height: 76, showsProgress: true)
                    }
                    ActionFlowLayout(spacing: 8) {
                        if device.running { detailStartStopButton(device).fixedSize() }
                        restartButton(device).fixedSize()
                        settingsButton(device).fixedSize()
                        Button(model.text("删除设备", "Delete device"), systemImage: WbIcon.trash, role: .destructive) {
                            model.select(device.id); model.deleteRequested = true
                        }
                        .buttonStyle(.bordered).controlSize(.regular).fixedSize()
                        .disabled(!device.stopped || model.busy.contains(device.id))
                    }
                    if let holder = model.busyHolder(for: device.id) {
                        Label(holder, systemImage: WbIcon.warning)
                            .wbFont(WbType.caption)
                            .foregroundStyle(WbColor.warning)
                    }
                    if let progress = model.progress(for: device.id) {
                        WbProgressLine(text: progress, value: model.bootProgressFraction(for: device.id))
                    }
                    if model.fullRoot[device.id] != nil {
                        Button(model.text("查看 Root 配置", "View root setup")) {
                            model.rootPresentation = RootPresentation(id:device.id, name:device.name)
                        }
                        .buttonStyle(.bordered).controlSize(.regular)
                    }
                }
                .padding(.horizontal, WbSpace.lg)
                .padding(.bottom, WbSpace.md)
            } else {
                CenterQuietState(icon: WbIcon.deviceEmpty,
                                 text: model.text("选择一台设备查看详情", "Select a device to see its details"),
                                 height: 196)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func detailPrimaryAction(_ device: Device) -> some View {
        switch device.status.state {
        case "running":
            Button(model.text("打开设备", "Open device")) { model.focusOrOpenDeviceWindow(device.id) }
                .buttonStyle(.borderedProminent).controlSize(.regular).tint(WbColor.accent)
        case "starting", "booting":
            Button(model.text("取消启动", "Cancel start")) { model.stop(device.id) }
                .buttonStyle(.bordered).controlSize(.regular)
                .disabled(model.busy.contains(device.id))
        default:
            Button(model.text("启动设备", "Start device")) { model.start(device.id) }
                .buttonStyle(.borderedProminent).controlSize(.regular).tint(WbColor.accent)
                .disabled(model.busy.contains(device.id))
        }
    }

    private func detailInfoGrid(_ d: Details, _ device: Device) -> some View {
        let items: [(String, String)] = [
            (model.text("CPU", "CPU"), model.text("\(d.config["hw.cpu.ncore"] ?? "—") 核", "\(d.config["hw.cpu.ncore"] ?? "—") cores")),
            (model.text("内存", "Memory"), "\(d.config["hw.ramSize"] ?? "—") MB"),
            (model.text("屏幕", "Screen"), "\(d.config["hw.lcd.width"] ?? "—") × \(d.config["hw.lcd.height"] ?? "—")"),
            (model.text("DPI", "DPI"), d.config["hw.lcd.density"] ?? "—"),
            (model.text("镜像", "Image"), device.imageLabel),
            (model.text("配置", "Profile"), device.profileLabel),
            (model.text("磁盘占用", "Disk usage"),
             d.disk_usage.map { ByteCountFormatter.string(fromByteCount:Int64(clamping:$0),countStyle:.file) } ?? "—"),
            (model.text("序列号", "Serial"), device.runtime?.adb_serial ?? "—"),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: WbSpace.md),
                                   GridItem(.flexible(), spacing: WbSpace.md)],
                         alignment: .leading, spacing: 7) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: WbSpace.sm) {
                    Text(item.0)
                        .wbFont(WbType.caption)
                        .foregroundStyle(WbColor.textTertiary)
                    Spacer(minLength: 0)
                    Text(item.1)
                        .wbFont(WbType.label)
                        .foregroundStyle(WbColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    @ViewBuilder private func detailStartStopButton(_ device: Device) -> some View {
        if device.running {
            Button(model.text("停止", "Stop"), systemImage: WbIcon.stop) { model.stop(device.id) }
                .buttonStyle(.bordered).controlSize(.regular)
                .disabled(model.busy.contains(device.id))
        } else {
            Button(model.text("启动", "Start"), systemImage: WbIcon.play) { model.start(device.id) }
                .buttonStyle(.bordered).controlSize(.regular)
                .disabled(model.busy.contains(device.id) || !device.stopped)
        }
    }

    private func restartButton(_ device: Device) -> some View {
        Button(model.text("重启", "Restart"), systemImage: WbIcon.refresh) { model.restart(device.id) }
            .buttonStyle(.bordered).controlSize(.regular)
            .disabled(!device.running || model.busy.contains(device.id))
    }

    private func settingsButton(_ device: Device) -> some View {
        Button(model.text("设备设置", "Device settings"), systemImage: WbIcon.settings) {
            model.presentDeviceSheet(.edit, device: device.id)
        }
        .buttonStyle(.bordered).controlSize(.regular)
        .disabled(model.busy.contains(device.id))
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
        var parts = [device.androidVersion, device.imageLabel]
        if let details = model.details, details.device.id == device.id {
            let width = details.config["hw.lcd.width"] ?? ""
            let height = details.config["hw.lcd.height"] ?? ""
            if !width.isEmpty, !height.isEmpty { parts.append("\(width) × \(height)") }
            if let ram = details.config["hw.ramSize"], !ram.isEmpty { parts.append("\(ram) MB") }
        }
        return parts.joined(separator: " · ")
    }
}
