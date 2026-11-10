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
        VStack(alignment: .leading, spacing: 12) {
            header
            if let banner = banner { bannerView(banner) }
            if !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption)
                    .foregroundStyle(.red).textSelection(.enabled)
            }
            if busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busyText.isEmpty ? t("正在处理…", "Working…") : busyText)
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            list
        }
        .padding(20)
        .frame(width: 660, height: 540)
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

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(t("快照", "Snapshots")).font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Text(device.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Text(Snapshots.modeName(currentDevice.root.mode, language: model.language))
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
            Spacer()
            if loading || busy {
                ProgressView().controlSize(.small)
            } else {
                Button(t("刷新", "Refresh"), systemImage: "arrow.clockwise") { load() }
            }
            Button(t("保存快照…", "Save snapshot…")) { showSave = true }
                .buttonStyle(.borderedProminent)
                .disabled(!running || busy)
            Button(t("关闭", "Close")) { dismiss() }.disabled(busy)
        }
    }

    private var banner: (String, Bool)? {
        let (text, warning) = Snapshots.banner(snapshots, deviceMode: deviceMode ?? currentDevice.root.mode, language: model.language)
        return text.isEmpty ? nil : (text, warning)
    }

    private func bannerView(_ banner: (String, Bool)) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: banner.1 ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(banner.1 ? .orange : .secondary)
            Text(banner.0).font(.caption)
                .foregroundStyle(banner.1 ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background((banner.1 ? Color.orange : Color.secondary).opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var list: some View {
        if loading {
            ProgressView(t("正在读取快照…", "Loading snapshots…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if snapshots.isEmpty {
            VStack(spacing: 8) {
                Label(t("暂无快照", "No snapshots"), systemImage: "camera")
                    .font(.callout).foregroundStyle(.secondary)
                Text(t("快照会按当前状态保存内存和磁盘，并记录保存时的 Root 模式。",
                       "A snapshot saves memory and disk as they are, tagged with the root mode."))
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(snapshots) { snapshot in
                row(snapshot)
            }.listStyle(.inset)
            if !running {
                Text(t("启动设备后才能恢复快照。", "Start the device to restore a snapshot."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ snapshot: SnapshotRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail(snapshot)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(displayName(snapshot)).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if snapshot.quick_boot {
                        Text(t("自动", "Auto")).font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                    } else {
                        Text(Snapshots.modeName(snapshot.root_mode, language: model.language))
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.14), in: Capsule())
                    }
                }
                HStack(spacing: 8) {
                    if snapshot.quick_boot {
                        Text(t("每次停止时保存 · 用于快速启动", "Saved on every stop · used for fast start"))
                    } else {
                        Text(Snapshots.rootTag(mode: snapshot.root_mode, magisk: snapshot.magisk_version, language: model.language))
                        if let size = snapshot.size_bytes, size > 0 { Text("·"); Text(Snapshots.size(size)) }
                        let when = Snapshots.when(snapshot.created_at, language: model.language)
                        if !when.isEmpty { Text("·"); Text(when) }
                    }
                }.font(.caption).foregroundStyle(.secondary)
                if !snapshot.restorable {
                    Label(refusalLine(snapshot), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Button(t("恢复", "Restore")) { requestRestore(snapshot) }
                    .disabled(!running || busy)
                if !snapshot.quick_boot {
                    Button(t("删除", "Delete"), role: .destructive) {
                        alertItem = .delete(snapshot)
                    }.disabled(busy)
                }
            }
        }
        .padding(.vertical, 5)
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

    @ViewBuilder
    private func thumbnail(_ snapshot: SnapshotRow) -> some View {
        if let path = snapshot.thumbnail, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 78).clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.2)))
        } else {
            Image(systemName: snapshot.quick_boot ? "bolt.fill" : "camera")
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 78)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        }
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
