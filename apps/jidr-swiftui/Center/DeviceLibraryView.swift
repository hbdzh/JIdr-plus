// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// System sidebar material and selection follow the user's macOS appearance.
struct DeviceLibrarySidebar: View {
    @ObservedObject var model: CenterModel

    var body: some View {
        VStack(spacing: 12) {
            LibrarySearchField(model: model)
                .frame(height: 30).padding(.horizontal, 12).padding(.top, 12)
            NativeDeviceLibraryList(model: model)
            .padding(.horizontal, 12)
            .overlay {
                if !model.deviceListLoaded {
                    ProgressView().controlSize(.small)
                } else if !model.deviceQuery.isEmpty && model.filteredDevices.isEmpty {
                    VStack(spacing: 10) {
                        Text(model.text("没有匹配的设备", "No matching devices")).font(.callout).foregroundStyle(.secondary)
                        Button(model.text("清除搜索", "Clear search")) { model.deviceQuery = "" }
                    }
                }
            }
            HStack {
                Button { model.present(.settings) } label: {
                    Label(model.text("设置", "Settings"), systemImage: "gearshape")
                }.buttonStyle(.borderless)
                Spacer()
                Text("⌘,").foregroundStyle(.tertiary)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 18).padding(.bottom, 18)
        }
        .frame(maxHeight: .infinity)
    }
}

/// The device search keeps its existing focus/overlay policy on the shared control.
struct LibrarySearchField: View {
    @ObservedObject var model: CenterModel
    private var enabled: Bool {
        model.sidebarVisible && !model.isEmptyDeviceLibrary && !model.paletteOpen && model.sheet == nil && !model.tasksOpen
    }
    var body: some View {
        NativeSearchField(text: $model.deviceQuery,
                          placeholder: model.text("搜索设备", "Search devices"),
                          identifier: "device-search",
                          focusRequest: model.searchFocusRequest,
                          canFocus: { enabled })
            .disabled(!enabled)
    }
}

struct DeviceOverviewView: View {
    @ObservedObject var model: CenterModel
    let device: Device
    var showApps: () -> Void
    @State private var snapshots: [SnapshotRow] = []
    @State private var snapshotsLoading = true
    @State private var snapshotsError: String?
    @State private var snapshotGeneration = 0
    @State private var advancedExpanded = false
    @State private var appQuery = ""
    @State private var savingSnapshot = false
    @State private var apkTargeted = false

    private var canOperate: Bool { device.running && !model.busy.contains(device.id) && model.busyHolder(for: device.id) == nil }
    private var filteredApps: [AndroidApp] {
        model.apps.filter { appQuery.isEmpty || $0.name.localizedCaseInsensitiveContains(appQuery) || $0.package.localizedCaseInsensitiveContains(appQuery) }
    }

    private func t(_ zh: String, _ en: String) -> String { model.text(zh, en) }
    private var details: Details? { model.details?.device.id == device.id ? model.details : nil }
    private var hardware: DeviceHardware { DeviceHardware(config: details?.config ?? [:]) }
    private var namedSnapshots: [SnapshotRow] { snapshots.filter { !$0.quick_boot } }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if let holder = model.busyHolder(for: device.id) {
                        Label(holder, systemImage: WbIcon.busy).foregroundStyle(.secondary)
                    }
                    if let progress = model.progress(for: device.id) {
                        WbProgressLine(text: progress, value: model.bootProgressFraction(for: device.id))
                    }
                    if let error = model.detailsError {
                        HStack {
                            Label(error, systemImage: WbIcon.warning).foregroundStyle(WbColor.negative)
                            Spacer()
                            Button(t("重新读取", "Retry")) { model.retryDetails() }
                        }
                    }
                    if model.detailsLoading && details == nil {
                        ProgressView(t("正在读取设备详情…", "Loading device details…")).controlSize(.small)
                    }
                    if geometry.size.width >= 920 {
                        HStack(alignment: .top, spacing: 20) {
                            informationColumn.frame(width: min(360, geometry.size.width * 0.32))
                            mainColumn.frame(maxWidth: .infinity)
                        }
                    } else {
                        informationColumn
                        mainColumn
                    }
                }
                .padding(geometry.size.width >= 860 ? 32 : 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .accessibilityIdentifier("device-overview:\(device.id)")
        .sheet(isPresented: $savingSnapshot) {
            SnapshotSaveDialog(model: model, device: device,
                               magiskVersion: device.root.magisk_version ?? "",
                               onCancel: { savingSnapshot = false }, onSaved: { _ in
                savingSnapshot = false
                loadSnapshots()
            })
        }
        .onAppear(perform: loadSnapshots)
        .onChange(of: model.sheet) { sheet in if sheet == nil { loadSnapshots() } }
        .onChange(of: device.root) { _ in loadSnapshots() }
        .onDisappear { snapshotGeneration += 1 }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            DevicePreview(model: model, device: device, width: 64, height: 110)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                Text(device.name).font(.system(size: 30, weight: .bold)).lineLimit(2).textSelection(.enabled)
                ActionFlowLayout(spacing: 8) {
                    overviewBadge(device.statusText(language: model.language),
                                  symbol: "circle.fill", color: .secondary)
                    Text(device.androidVersion).font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                    if device.root.mode != "none" {
                        overviewBadge(rootBadgeText, symbol: "checkmark.seal", color: .purple)
                    }
                }
                Text(device.profileLabel)
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ActionFlowLayout(spacing: 8) {
                    primaryAction
                    Button(t("设备设置", "Device settings"), systemImage: "slider.horizontal.3") {
                        model.presentDeviceSheet(.edit, device: device.id)
                    }.buttonStyle(.bordered).controlSize(.large)
                        .disabled(details == nil || model.busy.contains(device.id))
                    Button(t("设备工具", "Device tools"), systemImage: "wrench.and.screwdriver") {
                        model.openAdvanced(device.id, name: device.name)
                    }.buttonStyle(.bordered).controlSize(.large)
                    DeviceMoreButton(model: model, device: device)
                        .frame(width: 34, height: 32)
                }.padding(.top, 4)
                if device.running || model.recording.contains(device.id) { mediaActions }
            }.frame(maxWidth: .infinity, alignment: .leading)

        }
    }

    private var rootBadgeText: String {
        let mode = device.root.mode == "magisk" ? t("已 Root", "Rooted") : "Shell Root"
        return mode + (device.root.magisk_version.map { " · Magisk \($0)" } ?? "")
    }
    private func overviewBadge(_ title: String, symbol: String, color: Color) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
            .foregroundStyle(color).padding(.horizontal, 10).padding(.vertical, 5)
            .background(color.opacity(0.1), in: Capsule())
    }
    @ViewBuilder private var primaryAction: some View {
        switch DeviceOverviewPrimaryAction(state: device.status.state) {
        case .stop:
            Button(t("停止", "Stop"), systemImage: "stop") { model.stop(device.id) }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(WbColor.accent)
                .disabled(model.busy.contains(device.id))
        case .start:
            Button(t("启动", "Start"), systemImage: "play") { model.start(device.id) }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(WbColor.accent)
                .disabled(model.busy.contains(device.id))
        case .cancelStart:
            Button(t("取消启动", "Cancel start")) { model.stop(device.id) }
                .buttonStyle(.bordered).controlSize(.large).disabled(model.busy.contains(device.id))
        case .progress:
            ProgressView().controlSize(.small)
        }
    }

    private var mainColumn: some View {
        VStack(spacing: 20) {
            installedAppsCard
            OverviewInfoCard(title: "", compact: !snapshotsLoading && snapshotsError == nil && namedSnapshots.isEmpty) { snapshotsSection }
                .accessibilityIdentifier("overview-snapshots")
        }
    }
    private var informationColumn: some View {
        deviceInformationCard
    }
    private var installedAppsCard: some View {
        OverviewInfoCard(title: "", compact: !device.running || (!model.appsLoading && model.appsError == nil && filteredApps.isEmpty)) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    appsHeading
                    Spacer(minLength: 8)
                    appSearch.frame(width: 170)
                    installButton
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack { appsHeading; Spacer(); installButton }
                    appSearch
                }
            }
            if !device.running {
                emptyState("square.grid.2x2", t("启动设备后查看已安装应用。", "Start the device to see installed apps."))
            } else if model.appsLoading {
                ProgressView(t("正在读取应用…", "Loading apps…")).frame(maxWidth: .infinity, minHeight: 110)
            } else if let error = model.appsError {
                Text(error).font(.callout).foregroundStyle(.secondary)
                Button(t("重试", "Retry")) { model.load(device.id) }
            } else if filteredApps.isEmpty {
                emptyState("square.grid.2x2", appQuery.isEmpty
                           ? t("尚未安装可启动的应用。", "No launchable apps installed yet.")
                           : t("没有匹配的应用。", "No matching apps."))
            } else {
                Group {
                    if filteredApps.count > 6 {
                        ScrollView(.vertical) { appsGrid }
                            .frame(height: 171)
                    } else {
                        appsGrid
                    }
                }

            }
            if device.running, let note = model.appsNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if device.running {
                HStack(alignment: .center, spacing: 12) {
                    Label(t("拖入 APK 即可安装", "Drop an APK to install"), systemImage: "shippingbox")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(t("管理应用", "Manage apps"), action: showApps)
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("overview-manage-apps")
                }
            }
        }
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(apkTargeted ? WbColor.accent : .clear, lineWidth: 2) }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $apkTargeted, perform: receiveAPK)
        .accessibilityIdentifier("overview-installed-apps")
    }
    private var appsGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 20)], spacing: 0) {
            ForEach(filteredApps) { app in
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        WbAppIcon(symbol: WbIcon.appEmpty, imagePath: app.icon, size: 36)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text(app.package).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button { model.launch(app, device: device.id) } label: { Image(systemName: "play") }
                            .buttonStyle(.bordered).disabled(!canOperate)
                            .help(t("启动", "Launch") + " " + app.name)
                            .accessibilityLabel(t("启动", "Launch") + " " + app.name)
                    }.padding(.vertical, 10)
                    Divider()
                }
            }
        }
    }
    private var appsHeading: some View {
        HStack(spacing: 8) {
            Text(t("已安装应用", "Installed apps")).font(.system(size: 13, weight: .semibold))
            if device.running && !model.appsLoading && model.appsError == nil {
                Text("\(model.apps.count)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.fixedSize()
    }
    private var appSearch: some View {
        NativeSearchField(text: $appQuery, placeholder: t("搜索应用", "Search apps"), identifier: "overview-app-search")
            .frame(height: 30).disabled(!device.running || model.appsLoading)
    }
    private var installButton: some View {
        Button(t("安装 APK", "Install APK"), systemImage: "square.and.arrow.down") {
            model.chooseFile(device: device.id, apk: true)
        }.buttonStyle(.bordered).disabled(!canOperate)
            .accessibilityIdentifier("overview-install-apk")
    }
    private func receiveAPK(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        guard canOperate else {
            model.showError(t("请先启动设备，并等待当前操作完成。", "Start the device and wait for its current operation to finish."))
            return true
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
            DispatchQueue.main.async {
                guard let url, url.isFileURL, url.pathExtension.lowercased() == "apk" else {
                    model.showError(t("请选择 APK 安装包。", "Choose an APK file.")); return
                }
                guard canOperate, model.selected == device.id else { return }
                model.operation("file.install", id: device.id, params: ["apk": url.path, "replace": true])
            }
        }
        return true
    }
    private var mediaActions: some View {
        ActionFlowLayout(spacing: 16) {
            Button(t("截图", "Screenshot"), systemImage: "camera") { model.screenshot(device: device.id) }
                .disabled(!canOperate)
            Button(model.recording.contains(device.id) ? t("停止录屏", "Stop recording") : t("录屏", "Record"), systemImage: "video") {
                model.toggleRecording(device: device.id)
            }.disabled(!canOperate && !model.recording.contains(device.id))
            Button(t("发送文件", "Send file"), systemImage: "arrow.up.doc") { model.chooseFile(device: device.id, apk: false) }
                .disabled(!canOperate)
        }
        .buttonStyle(.borderless).font(.system(size: 12)).controlSize(.small)
        .accessibilityIdentifier("overview-media-actions")
    }
    private var deviceInformationCard: some View {
        OverviewInfoCard(title: t("设备信息", "Device information")) {
            infoRow("Android", device.androidVersion)
            Divider()
            infoRow("CPU", t("\(hardware.cores) 核", "\(hardware.cores) cores"))
            Divider()
            infoRow(t("内存", "RAM"), hardware.memoryGB)
            Divider()
            infoRow(t("分辨率", "Resolution"), "\(hardware.width) × \(hardware.height)")
            Divider()
            infoRow("DPI", hardware.density)
            Divider()
            infoRow(t("磁盘占用", "Disk usage"), details?.disk_usage.map {
                ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file)
            } ?? "—")
            Divider()
            DeviceAdvancedInformation(model: model, device: device, isExpanded: $advancedExpanded)
            if advancedExpanded { sessionSection }
        }
        .accessibilityIdentifier("overview-device-information")
    }
    private func emptyState(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 2)
    }
    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var snapshotsSection: some View {
        VStack(alignment: .leading, spacing: namedSnapshots.isEmpty ? 10 : 14) {
            HStack(spacing: 12) {
                Text(t("快照", "Snapshots")).font(.system(size: 13, weight: .semibold))
                if !snapshotsLoading && snapshotsError == nil {
                    Text("\(namedSnapshots.count)").foregroundStyle(.secondary)
                }
                Spacer()
                Button(t("创建快照", "Create snapshot")) { savingSnapshot = true }
                    .buttonStyle(.bordered).disabled(!canOperate)
                Button(t("管理快照", "Manage snapshots")) { model.present(.snapshots) }
                    .buttonStyle(.bordered)
            }
            if snapshotsLoading {
                ProgressView().controlSize(.small)
            } else if let error = snapshotsError {
                HStack {
                    Text(error).foregroundStyle(.secondary)
                    Button(t("重试", "Retry"), action: loadSnapshots)
                }
            } else if namedSnapshots.isEmpty {
                emptyState("square.3.layers.3d", t("暂无快照。设备运行时可保存快照，以便恢复。", "No snapshots yet. Save one while the device is running to restore it later."))
            } else {
                if namedSnapshots.count > 4 {
                    ScrollView(.vertical) { snapshotRows }.frame(height: 100)
                } else {
                    snapshotRows
                }
            }
        }.font(.system(size: 13)).padding(.vertical, 2)
    }
    private var snapshotRows: some View {
        VStack(spacing: 10) {
            ForEach(namedSnapshots) { snapshot in
                HStack {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                    Text(snapshot.name).lineLimit(1)
                    Spacer()
                    Text(Snapshots.when(snapshot.created_at, language: model.language)).foregroundStyle(.secondary)
                    Text(Snapshots.size(snapshot.size_bytes)).foregroundStyle(.secondary)
                }
            }
        }
    }
    private var sessionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("会话", "Session")).font(.system(size: 13, weight: .semibold))
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                infoRow(t("运行时长", "Uptime"), model.sessionUptime(device) ?? "—")
            }
            infoRow(t("上次启动", "Last started"), model.sessionStarted(device) ?? "—")
            infoRow(t("控制状态", "Control"), model.busyHolder(for: device.id)
                    ?? (model.players[device.id] != nil ? t("设备窗口已打开", "Device window open") : t("设备中心", "Device Center")))
        }.padding(.top, 14)
    }
    private func loadSnapshots() {
        snapshotGeneration += 1
        let generation = snapshotGeneration
        snapshotsLoading = true; snapshotsError = nil
        model.call("snapshot.list", ["device": device.id]) { result in
            guard generation == snapshotGeneration else { return }
            snapshotsLoading = false
            do { snapshots = Snapshots.sorted(try model.decode(result.get(), as: SnapshotList.self).snapshots) }
            catch { snapshotsError = model.readable(error) }
        }
    }
}

private struct OverviewInfoCard<Content: View>: View {
    let title: String
    var compact = false
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 14) {
            if !title.isEmpty { Text(title).font(.system(size: 13, weight: .semibold)).padding(.bottom, 4) }
            content()
        }
        .padding(compact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(WbColor.borderSubtle, lineWidth: 1) }
        .shadow(color: .black.opacity(0.035), radius: 2, y: 1)
    }
}

/// AppKit owns selection emphasis, arrow keys, type-to-select and accessibility.
struct NativeDeviceLibraryList: NSViewRepresentable {
    @ObservedObject var model: CenterModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.identifier = .init("jidr-device-list")
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let table = NSTableView()
        let column = NSTableColumn(identifier: .init("device"))
        table.addTableColumn(column)
        table.headerView = nil
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.style = .sourceList
        table.backgroundColor = .clear
        table.rowHeight = 54
        table.intercellSpacing = .zero
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openDevice(_:))
        table.setAccessibilityLabel(model.text("设备", "Devices"))
        table.setAccessibilityIdentifier("library-devices")
        scroll.documentView = table
        context.coordinator.update(table)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let table = scroll.documentView as? NSTableView { context.coordinator.update(table) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 232, height: proposal.height ?? 0)
    }
    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        let model: CenterModel
        private var devices: [Device] = []
        private var updating = false
        private var language = -1
        private var thumbnailIDs: [String: ObjectIdentifier] = [:]
        init(model: CenterModel) { self.model = model }
        func update(_ table: NSTableView) {
            updating = true
            defer { updating = false }
            let currentThumbnailIDs = model.deviceThumbnails.mapValues { ObjectIdentifier($0) }
            if devices != model.filteredDevices || language != model.language || thumbnailIDs != currentThumbnailIDs {
                devices = model.filteredDevices; language = model.language
                thumbnailIDs = currentThumbnailIDs
                table.reloadData()
            }
            let selected = model.showingAllDevices ? 0 : devices.firstIndex { $0.id == model.selected }.map { $0 + 2 }
            if let selected, table.selectedRow != selected {
                table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
                if table.visibleRect.height > 0 { table.scrollRowToVisible(selected) }
            } else if selected == nil { table.deselectAll(nil) }
            table.setAccessibilityLabel(model.text("设备", "Devices"))
        }
        func numberOfRows(in tableView: NSTableView) -> Int { devices.count + 2 }
        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            if row == 0 { return model.text("全部设备", "All devices") }
            return row == 1 ? nil : devices[row - 2].name
        }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if row == 0 {
                let cell = (tableView.makeView(withIdentifier: .init("library-all"), owner: nil) as? LibraryAllDevicesCell) ?? LibraryAllDevicesCell()
                cell.configure(title: model.text("全部设备", "All devices"))
                return cell
            }
            if row == 1 {
                let cell = (tableView.makeView(withIdentifier: .init("library-heading"), owner: nil) as? LibraryDeviceHeadingCell) ?? LibraryDeviceHeadingCell()
                cell.configure(title: model.text("设备", "Devices"), addTitle: model.text("新建设备", "New device"), target: self)
                return cell
            }
            let cell = (tableView.makeView(withIdentifier: .init("library-device"), owner: nil) as? LibraryDeviceCell) ?? LibraryDeviceCell()
            cell.configure(devices[row - 2], language: language, thumbnail: model.deviceThumbnails[devices[row - 2].id])
            return cell
        }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { NSTableRowView() }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { row == 0 ? 36 : row == 1 ? 48 : 54 }
        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { row != 1 }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table = notification.object as? NSTableView else { return }
            if table.selectedRow == 0 {
                model.showAllDevices()
                return
            }
            let index = table.selectedRow - 2
            guard devices.indices.contains(index) else {
                model.setDeviceSelection(nil)
                return
            }
            let id = devices[index].id
            if id != model.selected { model.select(id) }
        }
        @objc func openDevice(_ table: NSTableView) {
            let index = table.clickedRow - 2
            guard devices.indices.contains(index) else { return }
            model.focusOrOpenDeviceWindow(devices[index].id)
        }
        @objc func addDevice() { model.present(.newDevice) }
    }
}

private final class LibraryDeviceHeadingCell: NSTableCellView {
    private let heading = NSTextField(labelWithString: "")
    private let add = NSButton()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = .init("library-heading")
        let divider = NSBox()
        divider.boxType = .separator
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        heading.textColor = .secondaryLabelColor
        add.isBordered = false
        add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        add.action = #selector(NativeDeviceLibraryList.Coordinator.addDevice)
        for view in [divider, heading, add] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            heading.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            add.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            add.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            add.widthAnchor.constraint(equalToConstant: 24),
            add.heightAnchor.constraint(equalToConstant: 24)
        ])
    }
    required init?(coder: NSCoder) { nil }
    func configure(title: String, addTitle: String, target: AnyObject) {
        heading.stringValue = title
        add.target = target
        add.toolTip = addTitle
        add.setAccessibilityLabel(addTitle)
    }
}

private final class LibraryAllDevicesCell: NSTableCellView {
    private let icon = NSImageView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = .init("library-all")
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        icon.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon); addSubview(label); textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityIdentifier("library-all-devices")
    }
    required init?(coder: NSCoder) { nil }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { updateColors() } }
    func configure(title: String) { textField?.stringValue = title; updateColors() }
    private func updateColors() {
        let color: NSColor = backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : .labelColor
        textField?.textColor = color
        icon.contentTintColor = color
    }
}

private final class LibraryDeviceCell: NSTableCellView {
    private let subtitle = NSTextField(labelWithString: "")
    private let icon = NSHostingView(rootView: DeviceArtwork(state: .stopped, frame: nil, width: 17, height: 30))
    private let badge = NSImageView()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = .init("library-device")
        let name = NSTextField(labelWithString: "")
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.lineBreakMode = .byTruncatingTail
        for view in [name, subtitle, icon, badge] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        textField = name
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 32),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6),
            name.bottomAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            subtitle.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            subtitle.topAnchor.constraint(equalTo: centerYAnchor, constant: 3),
            badge.widthAnchor.constraint(equalToConstant: 14), badge.heightAnchor.constraint(equalToConstant: 14),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        ])
    }
    required init?(coder: NSCoder) { nil }
    override var backgroundStyle: NSView.BackgroundStyle { didSet { applyColors() } }
    func configure(_ device: Device, language: Int, thumbnail: CGImage?) {
        textField?.stringValue = device.name
        subtitle.stringValue = device.statusText(language: language)
        icon.rootView = DeviceArtwork(state: DeviceArtworkState(deviceState: device.status.state),
                                      frame: device.running ? thumbnail : nil, width: 17, height: 30)
        badge.image = device.root.mode == "none" ? nil : NSImage(systemSymbolName: device.root.mode == "magisk" ? "checkmark.seal" : "terminal", accessibilityDescription: nil)
        toolTip = device.name + " · " + subtitle.stringValue
        setAccessibilityIdentifier("library-device:\(device.id)")
        applyColors()
    }
    private func applyColors() {
        let emphasized = backgroundStyle == .emphasized
        textField?.textColor = emphasized ? .alternateSelectedControlTextColor : .labelColor
        subtitle.textColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        badge.contentTintColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }
}

/// Less frequently used identifiers and connection details stay on the overview.
struct DeviceAdvancedInformation: View {
    @ObservedObject var model: CenterModel
    let device: Device
    @Binding var isExpanded: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                row(model.text("Root 模式", "Root mode"), Snapshots.modeName(device.root.mode, language: model.language))
                row(model.text("镜像", "Image"), device.imageLabel)
                row(model.text("序列号", "Serial"), device.runtime?.adb_serial ?? "—")
                row("Magisk", device.root.magisk_version ?? "—")
                row(model.text("验证", "Verified"), verificationText)
                row(model.text("设备 ID", "Device ID"), device.id, canCopy: true)
                row(model.text("SDK 路径", "SDK path"), device.sdk_root, canCopy: true)
                row(model.text("控制台端口", "Console port"), device.runtime?.console_port.map(String.init) ?? "—")
                row(model.text("gRPC 端口", "gRPC port"), device.runtime?.grpc_port.map(String.init) ?? "—")
                row(model.text("进程 ID", "Process ID"), device.runtime?.pid.map(String.init) ?? "—")
            }
            .padding(.top, 16)
            .padding(.bottom, 4)
        } label: {
            Text(model.text("高级信息", "Advanced information"))
                .font(.system(size: 13, weight: .semibold))
        }
        .accessibilityIdentifier("device-advanced-information")
        .padding(.top, 8)
    }

    private var verificationText: String {
        switch device.root.health {
        case "ok":
            let date = Snapshots.when(device.root.verified_at, language: model.language)
            return date.isEmpty ? model.text("已验证", "Verified") : model.text("已验证 · \(date)", "Verified · \(date)")
        case "failed": return model.text("验证失败", "Verification failed")
        default: return model.text("尚未验证", "Not verified")
        }
    }

    private func row(_ label: String, _ value: String, canCopy: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value).font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if canCopy {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: {
                    Image(systemName: WbIcon.copy)
                }
                .buttonStyle(.bordered)
                .help(model.text("复制", "Copy") + " " + label)
                .accessibilityLabel(model.text("复制", "Copy") + " " + label)
            }
        }
    }
}
