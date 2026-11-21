// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers

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
                        .buttonStyle(WbPillButtonStyle())
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
                .buttonStyle(WbPillButtonStyle()).controlSize(.regular)
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
                                    .buttonStyle(WbPillButtonStyle()).controlSize(.regular)
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
