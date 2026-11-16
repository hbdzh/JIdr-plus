// SPDX-License-Identifier: GPL-3.0-only
// Snapshot manager: the list with root-mode tags, sizes, thumbnails and the
// cross-root refusal (D29). Slint reference: crates/jidr-ui/src/snapshots/mod.rs
// and crates/jidr-ui/ui/snapshots.slint. Dialogs live in SnapshotDialogs.swift.
import AppKit
import SwiftUI

struct SnapshotsView: View {
    @ObservedObject var model: CenterModel
    let device: Device
    var onPanelClose: ((@escaping () -> Void) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var snapshots: [SnapshotRow] = []
    @State private var deviceMode: String?
    @State private var loading = true
    @State private var error = ""
    @State private var busy = false
    @State private var busyText = ""
    @State private var showSave = false
    @State private var alertItem: SnapshotAlert?

    /// A restore/delete confirmation or the refusal explanation; one alert
    /// modifier keeps the two from replacing each other.
    enum SnapshotAlert: Identifiable {
        case restore(SnapshotRow)
        case delete(SnapshotRow)
        case refusal(SnapshotRefusal)

        var id: String {
            switch self {
            case .restore(let row): return "restore-\(row.id)"
            case .delete(let row): return "delete-\(row.id)"
            case .refusal(let refusal): return "refusal-\(refusal.id.uuidString)"
            }
        }
    }

    private func closePanel(after completion: @escaping () -> Void = {}) {
        if let onPanelClose { onPanelClose(completion) }
        else { dismiss(); DispatchQueue.main.async(execute: completion) }
    }

    private func t(_ chinese: String, _ english: String) -> String { model.text(chinese, english) }

    private var running: Bool { model.devices.first(where: { $0.id == device.id })?.running ?? device.running }
    private var currentDevice: Device { model.devices.first(where: { $0.id == device.id }) ?? device }

    var body: some View {
        ZStack {
            snapshotList.opacity(showSave ? 0 : 1)
                .allowsHitTesting(!showSave).accessibilityHidden(showSave).disabled(showSave)
            if showSave {
                SnapshotSaveDialog(model: model, device: currentDevice,
                                   magiskVersion: verifiedMagiskVersion,
                                   onCancel: { showSave = false }, onSaved: { _ in
                    showSave = false
                    load()
                    model.refresh()
                    model.notice = t("快照已保存。", "Snapshot saved.")
                })
            }
        }
        .frame(width: 600, height: 560)
        .modifier(DeviceSheetGlass())
    }
    private var snapshotList: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, WbSpace.lg)
            WbDivider()
                .padding(.bottom, WbSpace.md)
            if !error.isEmpty {
                Label(error, systemImage: WbIcon.warning).wbFont(WbType.caption)
                    .foregroundStyle(WbColor.negative).textSelection(.enabled)
                    .padding(.bottom, WbSpace.sm)
            }
            if busy {
                HStack(spacing: WbSpace.sm) {
                    ProgressView().controlSize(.small)
                    Text(busyText.isEmpty ? t("正在处理…", "Working…") : busyText)
                        .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.bottom, WbSpace.sm)
            }
            snapshotCard
            WbDivider()
                .padding(.top, WbSpace.md)
            footer
                .padding(.top, WbSpace.md)
        }
        .padding(WbSpace.xl)
        .frame(width: 600, height: 560)
        .onAppear(perform: load)
        .alert(item: $alertItem) { item in
            switch item {
            case .restore(let row): return restoreAlert(row)
            case .delete(let row): return deleteAlert(row)
            case .refusal(let refusal): return refusalAlert(refusal)
            }
        }
    }

    private var verifiedMagiskVersion: String {
        if case .verified(let version) = model.fullRoot[device.id] { return version }
        return ""
    }

    // MARK: header

    private var header: some View {
        HStack(alignment: .top, spacing: WbSpace.md) {
            VStack(alignment: .leading, spacing: WbSpace.xs) {
                Text(t("快照", "Snapshots")).wbFont(WbType.headline).foregroundStyle(WbColor.textPrimary)
                HStack(spacing: WbSpace.sm) {
                    Text(device.name).wbFont(WbType.body).foregroundStyle(WbColor.textSecondary).lineLimit(1)
                        .truncationMode(.middle)
                    Circle()
                        .fill(running ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(running ? t("运行中", "Running") : t("已停止", "Stopped"))
                        .wbFont(WbType.caption)
                        .foregroundStyle(WbColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)
            if loading || busy {
                ProgressView().controlSize(.small)
                    .padding(.trailing, WbSpace.xs)
            } else {
                Button { load() } label: {
                    Image(systemName: WbIcon.refresh)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(WbColor.textSecondary)
                }
                .buttonStyle(.borderless)
                .help(t("刷新", "Refresh"))
                .accessibilityLabel(t("刷新", "Refresh"))
            }
            saveButton

        }
    }

    @ViewBuilder
    private var saveButton: some View {
        let button = Button { showSave = true } label: {
            Label(t("保存当前快照", "Save snapshot"), systemImage: WbIcon.plus)
        }
        .disabled(!running || busy)
        .fixedSize()
        .help(t("保存当前快照", "Save snapshot"))
        if running && !busy {
            button.buttonStyle(.borderedProminent).controlSize(.regular).tint(WbColor.accent)
        } else {
            button.buttonStyle(.bordered).controlSize(.regular)
        }
    }

    // MARK: list card

    private var snapshotCard: some View {
        Group {
            if loading {
                loadingState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: WbSpace.xl) {
                        snapshotSection(t("自动快照", "Automatic snapshots"), rows: snapshots.filter(\.quick_boot), automatic: true)
                        snapshotSection(t("手动快照", "Manual snapshots"), rows: snapshots.filter { !$0.quick_boot }, automatic: false)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func snapshotSection(_ title: String, rows: [SnapshotRow], automatic: Bool) -> some View {
        VStack(alignment: .leading, spacing: WbSpace.md) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).wbFont(WbType.title).foregroundStyle(WbColor.textPrimary)
                Spacer()
                Text(t("\(rows.count) 个", "\(rows.count)"))
                    .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                    .monospacedDigit()
            }
            if rows.isEmpty {
                VStack(spacing: WbSpace.sm) {
                    Image(systemName: automatic ? WbIcon.quickBoot : WbIcon.camera)
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(WbColor.textTertiary)
                    Text(automatic ? t("暂无自动快照", "No automatic snapshots") : t("暂无手动保存的快照", "No manually saved snapshots"))
                        .wbFont(WbType.body).foregroundStyle(WbColor.textSecondary)
                    if !automatic {
                        Text(running ? t("保存快照以保留设备当前状态。", "Save a snapshot to keep the device's current state.") : t("启动设备后，可以保存当前状态。", "Start the device to save its current state."))
                            .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, WbSpace.lg)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, snapshot in
                        if index > 0 { WbDivider() }
                        row(snapshot)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: WbRadius.md))
                .overlay(RoundedRectangle(cornerRadius: WbRadius.md).stroke(Color.primary.opacity(0.10), lineWidth: 1))
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: WbSpace.sm) {
            ProgressView().controlSize(.small)
            Text(t("正在读取快照…", "Loading snapshots…"))
                .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ snapshot: SnapshotRow) -> some View {
        VStack(alignment: .leading, spacing: WbSpace.md) {
            HStack(alignment: .center, spacing: WbSpace.md) {
                Image(systemName: snapshot.quick_boot ? WbIcon.quickBoot : WbIcon.camera)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(WbColor.textSecondary)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: WbSpace.xs) {
                    Text(displayName(snapshot))
                        .wbFont(WbType.body.weighted(.medium))
                        .foregroundStyle(WbColor.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    metaLine(snapshot)
                        .wbFont(WbType.caption)
                        .foregroundStyle(WbColor.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                if !snapshot.restorable {
                    Text(t("不可用", "Unavailable"))
                        .wbFont(WbType.caption.weighted(.medium))
                        .foregroundStyle(WbColor.warning)
                        .padding(.horizontal, WbSpace.sm)
                        .padding(.vertical, WbSpace.xxs)
                        .background(WbColor.warning.opacity(0.12), in: Capsule())
                        .fixedSize()
                }
                Button(t("恢复", "Restore")) { requestRestore(snapshot) }
                    .buttonStyle(.bordered).controlSize(.regular)
                    .fixedSize()
                    .disabled(!running || busy || !snapshot.restorable)
                    .help(snapshot.restorable ? t("恢复此快照", "Restore this snapshot") : refusalLine(snapshot))
                if !snapshot.restorable || !snapshot.quick_boot {
                    Menu {
                        if !snapshot.restorable {
                            Button(t("查看无法恢复的原因", "Why can't this be restored?")) { requestRestore(snapshot) }
                        }
                        if !snapshot.quick_boot {
                            Button(t("删除快照…", "Delete snapshot…"), role: .destructive) { alertItem = .delete(snapshot) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 16))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(busy)
                    .help(t("更多操作", "More actions"))
                    .accessibilityLabel(t("更多操作", "More actions"))
                } else {
                    Color.clear.frame(width: 16, height: 1).accessibilityHidden(true)
                }
            }
            if !snapshot.restorable {
                Label(refusalLine(snapshot), systemImage: WbIcon.warning)
                    .wbFont(WbType.caption)
                    .foregroundStyle(WbColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24 + WbSpace.md)
            }
        }
        .padding(.horizontal, WbSpace.lg)
        .padding(.vertical, WbSpace.lg)
        .frame(minHeight: 78, alignment: .center)
    }

    /// Retain size/date for quick boot, with policy guidance separate from metadata.
    @ViewBuilder
    private func metaLine(_ snapshot: SnapshotRow) -> some View {
        VStack(alignment: .leading, spacing: WbSpace.xs) {
            HStack(spacing: WbSpace.sm) {
                if !snapshot.quick_boot {
                    Text(Snapshots.rootTag(mode: snapshot.root_mode, magisk: snapshot.magisk_version, language: model.language))
                }
                if let size = snapshot.size_bytes, size > 0 {
                    if !snapshot.quick_boot { Text("·") }
                    Text(Snapshots.size(size))
                }
                let when = Snapshots.when(snapshot.created_at, language: model.language)
                if !when.isEmpty {
                    if !snapshot.quick_boot || (snapshot.size_bytes ?? 0) > 0 { Text("·") }
                    Text(when)
                }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: WbSpace.md) {
            Text(summaryText)
                .wbFont(WbType.caption).foregroundStyle(WbColor.textTertiary)
                .lineLimit(1)
            Spacer(minLength: WbSpace.md)
            Button(t("关闭", "Close")) { closePanel() }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
                .disabled(busy)
        }
    }

    private var summaryText: String {
        let count = snapshots.count
        let total = snapshots.compactMap(\.size_bytes).reduce(0, +)
        let size = Snapshots.size(total)
        if size.isEmpty {
            return t("共 \(count) 个快照", "\(count) snapshot\(count == 1 ? "" : "s")")
        }
        return t("共 \(count) 个快照 · 占用 \(size)", "\(count) snapshot\(count == 1 ? "" : "s") · \(size) total")
    }

    private func displayName(_ snapshot: SnapshotRow) -> String {
        snapshot.quick_boot ? t("快速启动", "Quick boot") : snapshot.name
    }

    private func refusalLine(_ snapshot: SnapshotRow) -> String {
        if let mode = snapshot.root_mode, mode != (deviceMode ?? currentDevice.root.mode) {
            return t("不可恢复：该快照保存于\(Snapshots.modeName(mode, language: model.language))模式。",
                     "Can't restore: taken with \(Snapshots.modeName(mode, language: model.language)).")
        }
        return t("不可恢复：快照文件可能不完整。", "Can't restore: the snapshot files may be incomplete.")
    }

    // MARK: actions

    private func requestRestore(_ snapshot: SnapshotRow) {
        // The explanation button also works for stopped devices. Only an
        // actual restore requires the emulator to be running.
        if let refusal = Snapshots.refusal(snapshot, deviceMode: deviceMode ?? currentDevice.root.mode, language: model.language) {
            alertItem = .refusal(refusal)
            return
        }
        guard running else {
            model.notice = t("手动恢复需先启动设备；快速启动遵循设备设置。", "Start the device for manual restore. Quick boot follows device settings.")
            return
        }
        alertItem = .restore(snapshot)
    }

    private func restoreAlert(_ row: SnapshotRow) -> Alert {
        let name = displayName(row)
        return Alert(
            title: Text(t("恢复快照？", "Restore snapshot?")),
            message: Text(t("将把设备回退到“\(name)”保存时的状态和应用数据，请先保存当前游戏进度。",
                            "Restores “\(name)” and its app data. Save your current game progress first.")),
            primaryButton: .destructive(Text(t("恢复", "Restore"))) { restore(row) },
            secondaryButton: .cancel(Text(t("取消", "Cancel"))))
    }

    private func deleteAlert(_ row: SnapshotRow) -> Alert {
        let size = Snapshots.size(row.size_bytes)
        return Alert(
            title: Text(t("删除快照？", "Delete snapshot?")),
            message: Text(size.isEmpty
                          ? t("删除后无法恢复该快照；设备本身不会改变。", "Deleting a snapshot can't be undone. The device itself doesn't change.")
                          : t("将释放 \(size)，删除后无法恢复；设备本身不会改变。", "Frees \(size). This can't be undone. The device itself doesn't change.")),
            primaryButton: .destructive(Text(t("删除", "Delete"))) { delete(row, size: size) },
            secondaryButton: .cancel(Text(t("取消", "Cancel"))))
    }

    private func refusalAlert(_ refusal: SnapshotRefusal) -> Alert {
        switch refusal.kind {
        case .rootMode(let snapshotMode, let deviceMode, let magisk):
            let other = Snapshots.modeName(snapshotMode, language: model.language)
            let current = Snapshots.modeName(deviceMode, language: model.language)
            let tag = Snapshots.rootTag(mode: snapshotMode, magisk: magisk, language: model.language)
            let body = t("保存于：\(tag)\n设备当前：\(current)\n\n恢复会带回 Jidr 尚未在此设备上验证的 Root 状态，因此被拒绝。先设置\(other)，然后再恢复。\(current)下拍摄的快照仍可正常恢复。",
                         "Taken with: \(tag)\nDevice now: \(current)\n\nRestoring would bring back a root setup Jidr hasn't verified on this device, so it is refused. Set up \(other) first, then restore. Snapshots taken while \(current) restore as usual.")
            return Alert(
                title: Text(t("无法恢复“\(refusal.name)”", "Can't restore “\(refusal.name)”")),
                message: Text(body),
                primaryButton: .default(Text(t("设置\(other)…", "Set up \(other)…"))) {
                    setupRootMode(snapshotMode)
                },
                secondaryButton: .cancel(Text(t("取消", "Cancel"))))
        case .incomplete:
            return Alert(
                title: Text(t("无法恢复“\(refusal.name)”", "Can't restore “\(refusal.name)”")),
                message: Text(t("快照文件不完整（缺少元数据或内存文件），后台会在连接模拟器前拒绝恢复。可以删除该快照后重新保存。",
                                "The snapshot files are incomplete (metadata or memory files are missing), so the daemon refuses to restore it. Delete the snapshot and save a new one.")),
                dismissButton: .cancel(Text(t("了解", "OK"))))
        }
    }

    /// "Set up Full root…" from the refusal dialog (snapshots/mod.rs:292-313).
    private func setupRootMode(_ mode: String) {
        closePanel {
            if mode == "magisk" {
                model.setupFullRoot(device.id, name: device.name)
            } else {
                model.operation("root.set", id: device.id, params: ["mode": mode])
            }
        }
    }

    private func restore(_ row: SnapshotRow) {
        busy = true
        busyText = t("正在恢复快照…", "Restoring snapshot…")
        model.call("snapshot.load", ["device": device.id, "name": row.folder ?? row.name],
                   onProgress: { message, _, _ in
            if !message.isEmpty { busyText = OperationMessages.progress(message, language: model.language) }
        }) { result in
            busy = false
            switch result {
            case .success:
                model.notice = t("已恢复“\(displayName(row))”。", "Restored “\(displayName(row))”.")
                load()
                model.refresh()
            case .failure(let failure):
                error = OperationMessages.error(failure.localizedDescription, language: model.language)
            }
        }
    }

    private func delete(_ row: SnapshotRow, size: String) {
        busy = true
        busyText = t("正在删除快照…", "Deleting snapshot…")
        model.call("snapshot.delete", ["device": device.id, "name": row.folder ?? row.name]) { result in
            busy = false
            switch result {
            case .success:
                model.notice = size.isEmpty
                    ? t("已删除快照。", "Deleted the snapshot.")
                    : t("已删除快照，释放 \(size)。", "Deleted the snapshot and freed \(size).")
                load()
            case .failure(let failure):
                error = OperationMessages.error(failure.localizedDescription, language: model.language)
            }
        }
    }

    private func load() {
        if snapshots.isEmpty { loading = true }
        model.call("snapshot.list", ["device": device.id]) { result in
            loading = false
            switch result {
            case .success(let value):
                do {
                    let list = try model.decode(value, as: SnapshotList.self)
                    snapshots = Snapshots.sorted(list.snapshots)
                    deviceMode = list.device_root_mode
                    error = ""
                } catch {
                    self.error = error.localizedDescription
                }
            case .failure(let failure):
                error = OperationMessages.error(failure.localizedDescription, language: model.language)
            }
        }
    }
}
