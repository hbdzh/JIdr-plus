// SPDX-License-Identifier: GPL-3.0-only
// Snapshot manager: the list with root-mode tags, sizes, thumbnails and the
// cross-root refusal (D29). Slint reference: crates/jidr-ui/src/snapshots/mod.rs
// and crates/jidr-ui/ui/snapshots.slint. Dialogs live in SnapshotDialogs.swift.
import AppKit
import SwiftUI

struct SnapshotsView: View {
    @ObservedObject var model: CenterModel
    let device: Device
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

    private func t(_ chinese: String, _ english: String) -> String { model.text(chinese, english) }

    private var running: Bool { model.devices.first(where: { $0.id == device.id })?.running ?? device.running }
    private var currentDevice: Device { model.devices.first(where: { $0.id == device.id }) ?? device }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.bottom, WbSpace.lg)
            if let banner = banner {
                bannerView(banner)
                    .padding(.bottom, WbSpace.md)
            }
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
            footer
                .padding(.top, WbSpace.md)
        }
        .padding(WbSpace.xl)
        .frame(width: 600, height: 560)
        .tint(WbColor.accent)
        .onAppear(perform: load)
        .sheet(isPresented: $showSave) {
            SnapshotSaveDialog(model: model, device: currentDevice,
                               magiskVersion: verifiedMagiskVersion) { _ in
                showSave = false
                load()
                model.refresh()
                model.notice = t("快照已保存。", "Snapshot saved.")
            }
            .environment(\.locale, Locale(identifier: model.language == 0 ? "en" : "zh-Hans"))
        }
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
                    Text(Snapshots.modeName(currentDevice.root.mode, language: model.language))
                        .wbFont(WbType.caption.weighted(.medium))
                        .foregroundStyle(WbColor.textSecondary)
                        .padding(.horizontal, WbSpace.sm)
                        .padding(.vertical, WbSpace.xxs)
                        .background(WbColor.control, in: Capsule())
                }
            }
            Spacer(minLength: WbSpace.sm)
            if loading || busy {
                ProgressView().controlSize(.small)
                    .padding(.trailing, WbSpace.xs)
            } else {
                SnapshotsIconButton(icon: WbIcon.refresh, label: t("刷新", "Refresh")) { load() }
            }
            Button { showSave = true } label: {
                Label(t("保存当前快照", "Save snapshot"), systemImage: WbIcon.plus)
            }
            .buttonStyle(.borderedProminent).controlSize(.regular).tint(WbColor.accent)
            .disabled(!running || busy)
            .help(t("保存当前快照", "Save snapshot"))
            .accessibilityLabel(t("保存当前快照", "Save snapshot"))
            SnapshotsIconButton(icon: WbIcon.close, label: t("关闭", "Close")) { dismiss() }
                .disabled(busy)
        }
    }

    // MARK: list card

    private var snapshotCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: WbSpace.sm) {
                Text(t("已保存的快照", "Saved snapshots")).wbFont(WbType.title)
                    .foregroundStyle(WbColor.textPrimary)
                Spacer(minLength: WbSpace.sm)
                Text("\(snapshots.count)")
                    .wbFont(WbType.caption)
                    .foregroundStyle(WbColor.textTertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, WbSpace.lg)
            .padding(.vertical, WbSpace.md)

            WbDivider()

            if loading {
                loadingState
            } else if snapshots.isEmpty {
                emptyState
            } else {
                // Native list: row separators, scrolling and hover feedback come
                // from AppKit; the sheet keeps its card surface behind it.
                List {
                    ForEach(snapshots) { snapshot in
                        row(snapshot)
                            .listRowInsets(EdgeInsets(top: 0, leading: WbSpace.md,
                                                      bottom: 0, trailing: WbSpace.md))
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .wbCardSurface()
    }

    private var loadingState: some View {
        VStack(spacing: WbSpace.sm) {
            ProgressView().controlSize(.small)
            Text(t("正在读取快照…", "Loading snapshots…"))
                .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: WbSpace.sm) {
            Image(systemName: WbIcon.camera)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(WbColor.textTertiary)
                .frame(width: 44, height: 44)
                .background(WbColor.control, in: Circle())
            Text(t("暂无快照", "No snapshots"))
                .wbFont(WbType.body.weighted(.medium)).foregroundStyle(WbColor.textPrimary)
            Text(t("快照会按当前状态保存内存和磁盘，并记录保存时的 Root 模式。",
                   "A snapshot saves memory and disk as they are, tagged with the root mode."))
                .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ snapshot: SnapshotRow) -> some View {
        HStack(alignment: .top, spacing: WbSpace.md) {
            ZStack {
                Circle()
                    .fill(snapshot.quick_boot ? WbColor.accentContainer : WbColor.control)
                    .frame(width: 36, height: 36)
                Image(systemName: snapshot.quick_boot ? WbIcon.quickBoot : WbIcon.camera)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(snapshot.quick_boot ? WbColor.accentText : WbColor.textSecondary)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: WbSpace.xxs + 1) {
                Text(displayName(snapshot))
                    .wbFont(WbType.body.weighted(.medium))
                    .foregroundStyle(WbColor.textPrimary)
                    .lineLimit(1).truncationMode(.middle)

                metaLine(snapshot)
                    .wbFont(WbType.caption)
                    .foregroundStyle(WbColor.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !snapshot.restorable {
                    Label(refusalLine(snapshot), systemImage: WbIcon.warning)
                        .wbFont(WbType.caption).foregroundStyle(WbColor.warning)
                }
            }

            Spacer(minLength: WbSpace.sm)

            HStack(spacing: WbSpace.sm) {
                Button(t("恢复", "Restore")) { requestRestore(snapshot) }
                    .buttonStyle(.bordered).controlSize(.regular)
                    .disabled(!running || busy)
                    .help(t("恢复此快照", "Restore this snapshot"))
                if !snapshot.quick_boot {
                    Button {
                        alertItem = .delete(snapshot)
                    } label: {
                        Image(systemName: WbIcon.trash)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(WbColor.negative)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(busy)
                    .help(t("删除此快照", "Delete this snapshot"))
                    .accessibilityLabel(t("删除此快照", "Delete this snapshot"))
                }
            }
        }
        .padding(.vertical, WbSpace.sm)
    }

    /// One line of real data: auto-save description, or root tag · size · time.
    @ViewBuilder
    private func metaLine(_ snapshot: SnapshotRow) -> some View {
        if snapshot.quick_boot {
            Text(t("每次停止时保存 · 用于快速启动", "Saved on every stop · used for fast start"))
        } else {
            HStack(spacing: WbSpace.sm) {
                Text(Snapshots.rootTag(mode: snapshot.root_mode, magisk: snapshot.magisk_version, language: model.language))
                if let size = snapshot.size_bytes, size > 0 {
                    Text("·")
                    Text(Snapshots.size(size))
                }
                let when = Snapshots.when(snapshot.created_at, language: model.language)
                if !when.isEmpty {
                    Text("·")
                    Text(when)
                }
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: WbSpace.md) {
            Text(summaryText)
                .wbFont(WbType.caption).foregroundStyle(WbColor.textTertiary)
                .lineLimit(1)
            Spacer(minLength: WbSpace.md)
            Text(footerNote)
                .wbFont(WbType.caption).foregroundStyle(WbColor.textTertiary)
                .lineLimit(1)
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

    private var footerNote: String {
        running
            ? t("恢复快照会覆盖设备当前状态。", "Restoring replaces the device's current state.")
            : t("启动设备后才能恢复快照。", "Start the device to restore a snapshot.")
    }

    private var banner: (String, Bool)? {
        let (text, warning) = Snapshots.banner(snapshots, deviceMode: deviceMode ?? currentDevice.root.mode, language: model.language)
        return text.isEmpty ? nil : (text, warning)
    }

    private func bannerView(_ banner: (String, Bool)) -> some View {
        let tone = banner.1 ? WbStatus.warning : WbStatus.neutral
        return HStack(alignment: .top, spacing: WbSpace.sm) {
            Image(systemName: banner.1 ? WbIcon.warning : WbIcon.info)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tone.onContainer)
                .padding(.top, 1)
            Text(banner.0).wbFont(WbType.caption)
                .foregroundStyle(tone.onContainer)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(WbSpace.md)
        .background(tone.container, in: RoundedRectangle(cornerRadius: WbRadius.md, style: .continuous))
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
        guard running else {
            model.notice = t("启动设备后才能恢复快照。", "Start the device to restore a snapshot.")
            return
        }
        if let refusal = Snapshots.refusal(snapshot, deviceMode: deviceMode ?? currentDevice.root.mode, language: model.language) {
            alertItem = .refusal(refusal)
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
        dismiss()
        DispatchQueue.main.async {
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

/// Small square icon button used by the sheet header (refresh / close). Kept
/// local to this file because it is the only header that needs it.
private struct SnapshotsIconButton: View {
    var icon: String
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(WbColor.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
        .help(label)
    }
}
