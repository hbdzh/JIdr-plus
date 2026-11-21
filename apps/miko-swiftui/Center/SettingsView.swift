// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers

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

/// Match settings actions to the shared pill buttons used by the agent page.
private struct SettingsPanelButtonStyle: ViewModifier {
    var prominent = false
    func body(content: Content) -> some View {
        content.buttonStyle(WbPillButtonStyle(prominent: prominent))
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
                .buttonStyle(WbPillButtonStyle(prominent: false))
            Button(model.text("配置…", "Configure…"), action: onConfigure)
                .buttonStyle(WbPillButtonStyle(prominent: true))
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
