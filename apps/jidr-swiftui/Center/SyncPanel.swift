// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import SwiftUI

/// Owns the non-modal Synchronizer window for the app.
final class SyncPanelCoordinator: ObservableObject {
    private var controller: SyncPanelWindowController?

    func present(model: CenterModel, preselect: [String] = []) {
        if let controller {
            controller.applyPreselection(preselect)
            controller.show()
            return
        }
        let controller = SyncPanelWindowController(model: model, preselect: preselect)
        self.controller = controller
        controller.show()
    }

    func close() {
        controller?.close()
        controller = nil
    }
}

final class SyncPanelState: ObservableObject {
    @Published var selectedIDs: Set<String> = []
    @Published var leaderID: String?
    @Published var options: SyncOptionsModel = SyncOptionsModel()
    private var didInitialAutoSelect = false

    func seed(from devices: [Device], session: SyncSessionModel?, preselect: [String]) {
        if let session {
            didInitialAutoSelect = true
            let nextIDs = Set([session.leader] + session.followers.map(\.device))
            if leaderID != session.leader { leaderID = session.leader }
            if selectedIDs != nextIDs { selectedIDs = nextIDs }
            if options != session.options { options = session.options }
            return
        }
        let runningIDs = Set(devices.filter(\.running).map(\.id))
        if !preselect.isEmpty {
            let valid = preselect.filter { runningIDs.contains($0) }
            if !valid.isEmpty {
                didInitialAutoSelect = true
                selectedIDs = Set(valid)
                if leaderID == nil || !selectedIDs.contains(leaderID ?? "") {
                    leaderID = valid.first
                }
                return
            }
        }
        selectedIDs = selectedIDs.intersection(runningIDs)
        if !didInitialAutoSelect && selectedIDs.isEmpty && runningIDs.count >= 2 {
            selectedIDs = runningIDs
            didInitialAutoSelect = true
        }
        if let current = leaderID, !selectedIDs.contains(current) {
            leaderID = nil
        }
        if leaderID == nil {
            leaderID = devices.first(where: { $0.running && selectedIDs.contains($0.id) })?.id
        }
    }
}

/// Uses the same frosted-glass window chrome as `PlayerScriptsWindowController`.
final class SyncPanelWindowController: NSWindowController, NSWindowDelegate {
    private let model: CenterModel
    private let panelState = SyncPanelState()
    private var languageCancellable: AnyCancellable?

    init(model: CenterModel, preselect: [String] = []) {
        self.model = model
        panelState.seed(from: model.devices, session: model.syncHub.session, preselect: preselect)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = t("同步器", "Synchronizer", model.language)
        window.minSize = NSSize(width: 460, height: 400)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isOpaque = false
        window.backgroundColor = .clear
        super.init(window: window)
        window.delegate = self

        let background = NSVisualEffectView()
        background.material = .underWindowBackground
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState

        let hosting = NSHostingView(
            rootView: SyncPanelView(model: model, hub: model.syncHub, state: panelState)
        )
        window.contentView = background
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            NSLayoutConstraint.Attribute.leading, .trailing, .top, .bottom,
        ].map {
            NSLayoutConstraint(
                item: hosting,
                attribute: $0,
                relatedBy: .equal,
                toItem: window.contentLayoutGuide,
                attribute: $0,
                multiplier: 1,
                constant: 0
            )
        })
        window.toolbarStyle = .unifiedCompact
        window.center()

        languageCancellable = model.$language.sink { [weak self] language in
            self?.window?.title = t("同步器", "Synchronizer", language)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyPreselection(_ preselect: [String]) {
        panelState.seed(from: model.devices, session: model.syncHub.session, preselect: preselect)
    }

    func show() {
        panelState.seed(from: model.devices, session: model.syncHub.session, preselect: [])
        model.refreshSyncStatus()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SyncGlassCardModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var cornerRadius: CGFloat = WbRadius.lg

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(WbColor.raised, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            content.modifier(PlayerGlassSurface(cornerRadius: cornerRadius))
        }
    }
}

struct SyncPanelView: View {
    @ObservedObject var model: CenterModel
    @ObservedObject var hub: SyncHub
    @ObservedObject var state: SyncPanelState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var language: Int { model.language }
    private var runningDevices: [Device] { model.devices.filter(\.running) }
    private var activeSession: SyncSessionModel? { hub.session }
    private var isSyncing: Bool { activeSession != nil }

    private var leaderDisplay: SyncDisplaySize? {
        guard let leader = state.leaderID else { return nil }
        if let d = activeSession?.leader_display, activeSession?.leader == leader {
            return d
        }
        return displaySize(for: leader)
    }

    private func displaySize(for deviceID: String) -> SyncDisplaySize? {
        if let hw = model.cardHardware[deviceID], let w = Int(hw.width), let h = Int(hw.height), w > 0, h > 0 {
            return SyncDisplaySize(width: w, height: h)
        }
        return nil
    }

    private var validationError: String? {
        guard !isSyncing else { return nil }
        let selectedRunning = runningDevices.filter { state.selectedIDs.contains($0.id) }
        if selectedRunning.count < 2 {
            return t("请至少选择两台运行中的设备", "Select at least two running devices", language)
        }
        guard let leader = state.leaderID, selectedRunning.contains(where: { $0.id == leader }) else {
            return t("请选择一台主控设备", "Choose a leader device", language)
        }
        return nil
    }

    var body: some View {
        VStack(spacing: WbSpace.md) {
            header
            deviceSection
            optionsSection
            actionRow
            footer
        }
        .padding(WbSpace.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: model.devices) { _ in
            state.seed(from: model.devices, session: hub.session, preselect: [])
        }
        .onChange(of: hub.session) { session in
            state.seed(from: model.devices, session: session, preselect: [])
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: WbSpace.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(t("多设备同步器", "Multi-device synchronizer", language))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(WbColor.textPrimary)
                Text(t("主控设备的操作将实时同步到所有已选跟随设备",
                       "Actions on the leader mirror to all selected followers in real time",
                       language))
                    .font(.system(size: 12))
                    .foregroundStyle(WbColor.textSecondary)
            }
            Spacer(minLength: 8)
            statusCapsule
        }
    }

    private var statusCapsule: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isSyncing ? WbColor.positive : WbColor.textTertiary)
                .frame(width: 7, height: 7)
            Text(isSyncing
                 ? String(format: t("同步中 · %d 台", "Syncing · %d", language), activeSession?.memberCount ?? 0)
                 : t("未开启", "Idle", language))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSyncing ? WbColor.textPrimary : WbColor.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .modifier(SyncGlassCardModifier(cornerRadius: 999))
        .overlay(
            Capsule().strokeBorder(WbColor.borderSubtle, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var deviceSection: some View {
        if runningDevices.isEmpty {
            VStack(spacing: WbSpace.sm) {
                Image(systemName: "rectangle.on.rectangle.slash")
                    .font(.system(size: 24))
                    .foregroundStyle(WbColor.textTertiary)
                Text(t("没有运行中的设备", "No running devices", language))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WbColor.textPrimary)
                Text(t("请先启动至少两台设备再开启同步。", "Start at least two devices before starting sync.", language))
                    .font(.system(size: 12))
                    .foregroundStyle(WbColor.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .modifier(SyncGlassCardModifier(cornerRadius: WbRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: WbRadius.lg).strokeBorder(WbColor.borderSubtle, lineWidth: 1))
        } else {
            ScrollView {
                LazyVStack(spacing: WbSpace.xs) {
                    ForEach(runningDevices) { device in
                        deviceRow(device)
                    }
                }
                .padding(2)
            }
            .frame(minHeight: 140, maxHeight: 230)
        }
    }

    private func deviceRow(_ device: Device) -> some View {
        let isMember: Bool = {
            if let session = activeSession {
                return session.leader == device.id || session.followers.contains(where: { $0.device == device.id })
            }
            return state.selectedIDs.contains(device.id)
        }()
        let isLeader: Bool = {
            if let session = activeSession { return session.leader == device.id }
            return state.leaderID == device.id && isMember
        }()
        let followerModel = activeSession?.followers.first(where: { $0.device == device.id })
        let size = displaySize(for: device.id)
        let hasMismatch: Bool = {
            guard !isLeader, isMember, let l = leaderDisplay, let f = followerModel?.display ?? size else { return false }
            return l.differsSignificantly(from: f)
        }()

        return SyncDeviceRow(
            device: device,
            language: language,
            isMember: isMember,
            isLeader: isLeader,
            isSyncing: isSyncing,
            followerStatus: followerModel?.status,
            resolutionText: size.map { "\($0.width)×\($0.height)" },
            hasMismatch: hasMismatch,
            onToggleMember: { toggleMember(device.id, currentlyMember: isMember) },
            onSetLeader: { promoteLeader(device.id, currentlyMember: isMember) }
        )
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: WbSpace.sm) {
            HStack {
                Text(t("坐标适配", "Coordinate mapping", language))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WbColor.textSecondary)
                Spacer()
                Picker("", selection: adaptationBinding) {
                    Text(t("拉伸匹配", "Stretch", language)).tag(SyncAdaptation.stretch)
                    Text(t("等比留黑", "Letterbox", language)).tag(SyncAdaptation.letterbox)
                }
                .pickerStyle(.segmented)
                .frame(width: 210)
            }
            Divider().opacity(0.4)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                Toggle(t("同步键盘按键", "Sync keyboard", language), isOn: optionBinding(\.sync_keyboard))
                Toggle(t("同步文本与粘贴", "Sync text & paste", language), isOn: optionBinding(\.sync_text))
                Toggle(t("同步系统功能键", "Sync tool keys", language), isOn: optionBinding(\.sync_tool_keys))
                Toggle(t("锁定跟随端输入", "Lock follower input", language), isOn: optionBinding(\.lock_followers))
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
        }
        .padding(WbSpace.md)
        .modifier(SyncGlassCardModifier(cornerRadius: WbRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: WbRadius.lg).strokeBorder(WbColor.borderSubtle, lineWidth: 1))
    }

    private var actionRow: some View {
        VStack(spacing: 6) {
            Button(action: primaryAction) {
                HStack(spacing: 8) {
                    Image(systemName: isSyncing ? "stop.fill" : "rectangle.on.rectangle")
                        .font(.system(size: 13, weight: .semibold))
                    Text(isSyncing
                         ? t("停止同步", "Stop sync", language)
                         : t("开始同步", "Start sync", language))
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(isSyncing ? WbColor.negativeFill : (validationError == nil ? WbColor.accent : WbColor.textTertiary.opacity(0.45)))
                )
            }
            .buttonStyle(.plain)
            .disabled(!isSyncing && validationError != nil)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isSyncing)

            if let validationError {
                Text(validationError)
                    .font(.system(size: 11))
                    .foregroundStyle(WbColor.textSecondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let session = activeSession {
                Text(String(
                    format: t("%d 台设备 · %d 次事件 · 平均 %d ms",
                              "%d devices · %d events · %d ms avg",
                              language),
                    session.memberCount,
                    hub.totalEventsRelayed,
                    hub.averageLatencyMs
                ))
            } else {
                Text(t("提示：点击任意设备右侧的「设为主控」可切换主控端。",
                       "Tip: click “Set as leader” on any row to switch control.",
                       language))
            }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(WbColor.textTertiary)
    }

    private var adaptationBinding: Binding<SyncAdaptation> {
        Binding(
            get: { activeSession?.options.adaptation ?? state.options.adaptation },
            set: { value in
                var next = activeSession?.options ?? state.options
                next.adaptation = value
                state.options = next
                if isSyncing { model.setSyncOptions(next) }
            }
        )
    }

    private func optionBinding(_ keyPath: WritableKeyPath<SyncOptionsModel, Bool>) -> Binding<Bool> {
        Binding(
            get: { (activeSession?.options ?? state.options)[keyPath: keyPath] },
            set: { value in
                var next = activeSession?.options ?? state.options
                next[keyPath: keyPath] = value
                state.options = next
                if isSyncing { model.setSyncOptions(next) }
            }
        )
    }

    private func toggleMember(_ id: String, currentlyMember: Bool) {
        if isSyncing {
            if activeSession?.leader == id { return }
            if currentlyMember {
                model.removeSyncFollower(id)
            } else {
                model.addSyncFollower(id)
            }
            return
        }
        if currentlyMember {
            state.selectedIDs.remove(id)
            if state.leaderID == id {
                state.leaderID = runningDevices.first(where: { state.selectedIDs.contains($0.id) })?.id
            }
        } else {
            state.selectedIDs.insert(id)
            if state.leaderID == nil { state.leaderID = id }
        }
    }

    private func promoteLeader(_ id: String, currentlyMember: Bool) {
        if isSyncing {
            if !currentlyMember {
                model.addSyncFollower(id) { ok in
                    if ok { model.setSyncLeader(id) }
                }
            } else {
                model.setSyncLeader(id)
            }
            return
        }
        state.selectedIDs.insert(id)
        state.leaderID = id
    }

    private func primaryAction() {
        if isSyncing {
            model.stopSync()
            return
        }
        guard let leader = state.leaderID else { return }
        let followers = runningDevices
            .map(\.id)
            .filter { state.selectedIDs.contains($0) && $0 != leader }
        guard !followers.isEmpty else { return }
        model.startSync(leader: leader, followers: followers, options: state.options)
    }
}

private struct SyncDeviceRow: View {
    let device: Device
    let language: Int
    let isMember: Bool
    let isLeader: Bool
    let isSyncing: Bool
    let followerStatus: SyncFollowerStatus?
    let resolutionText: String?
    let hasMismatch: Bool
    let onToggleMember: () -> Void
    let onSetLeader: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: WbSpace.sm) {
            Button(action: onToggleMember) {
                Image(systemName: isMember ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(isMember ? WbColor.accent : WbColor.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(isSyncing && isLeader)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(WbColor.textPrimary)
                        .lineLimit(1)
                    if isLeader {
                        Label(t("主控", "Leader", language), systemImage: "star.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(WbColor.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(WbColor.accent.opacity(0.14), in: Capsule())
                    }
                    if hasMismatch {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(WbColor.warning)
                            .help(t("分辨率比例或屏幕方向与主控不一致，建议使用「等比留黑」或调整方向",
                                    "Aspect ratio or orientation differs from leader",
                                    language))
                    }
                }
                HStack(spacing: 6) {
                    if let resolutionText {
                        Text(resolutionText)
                    }
                    Text("Android \(device.image.api)")
                }
                .font(.system(size: 11))
                .foregroundStyle(WbColor.textSecondary)
            }

            Spacer(minLength: 8)

            if let followerStatus {
                statusDot(followerStatus)
            }

            if !isLeader && (hovered || !isMember) {
                Button(t("设为主控", "Set as leader", language), action: onSetLeader)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, WbSpace.md)
        .padding(.vertical, 8)
        .modifier(SyncGlassCardModifier(cornerRadius: WbRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: WbRadius.md)
                .strokeBorder(isLeader ? WbColor.accent.opacity(0.55) : WbColor.borderSubtle, lineWidth: 1)
        )
        .onHover { hovered = $0 }
        .contextMenu {
            if !isLeader {
                Button(t("设为主控", "Set as leader", language), action: onSetLeader)
            }
            if !(isSyncing && isLeader) {
                Button(isMember ? t("移出同步", "Remove from sync", language) : t("加入同步", "Add to sync", language),
                       action: onToggleMember)
            }
        }
    }

    @ViewBuilder
    private func statusDot(_ status: SyncFollowerStatus) -> some View {
        switch status {
        case .ready:
            Circle()
                .fill(WbColor.positive)
                .frame(width: 8, height: 8)
                .help(t("已同步", "Synced", language))
        case .lagging:
            Circle()
                .fill(WbColor.warning)
                .frame(width: 8, height: 8)
                .help(t("延迟较高", "Lagging", language))
        case .detached:
            Circle()
                .fill(WbColor.textTertiary)
                .frame(width: 8, height: 8)
                .help(t("已断开", "Detached", language))
        case .error(let message):
            Circle()
                .fill(WbColor.negative)
                .frame(width: 8, height: 8)
                .help(message.isEmpty ? t("同步错误", "Sync error", language) : message)
        }
    }
}
