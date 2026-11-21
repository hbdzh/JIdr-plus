// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import SwiftUI

struct FolderSyncView: View {
    @ObservedObject var model: CenterModel
    let device: Device
    var onPanelClose: ((@escaping () -> Void) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var folderSyncs: [[String: Any]] = []
    @State private var syncDirection = "bidirectional"
    @State private var customRemote = false
    @State private var remotePath = ""
    @State private var working = false
    @State private var error = ""

    private let syncTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private func t(_ chinese: String, _ english: String) -> String { model.text(chinese, english) }
    private var currentDevice: Device { model.devices.first(where: { $0.id == device.id }) ?? device }
    private var running: Bool { currentDevice.running }

    private func closePanel(after completion: @escaping () -> Void = {}) {
        if let onPanelClose { onPanelClose(completion) }
        else { dismiss(); DispatchQueue.main.async(execute: completion) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            WbDivider()

            Form {
                Section(t("同步设置", "Sync setup")) {
                    LabeledContent(t("同步方向", "Direction")) {
                        Picker("", selection: $syncDirection) {
                            Text(t("双向同步（Mac 与设备互通）", "Bidirectional (Mac & device)")).tag("bidirectional")
                            Text(t("单向同步（Mac 到设备）", "One-way (Mac to device)")).tag("one_way")
                        }
                        .labelsHidden()
                        .frame(width: 220)
                        .accessibilityLabel(t("同步方向", "Direction"))
                    }

                    LabeledContent(t("设备目录", "Device folder")) {
                        if customRemote {
                            HStack(spacing: WbSpace.xs) {
                                TextField("", text: $remotePath, prompt: Text("/sdcard/Download/…"))
                                    .labelsHidden()
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 200)
                                Button(t("默认", "Default")) {
                                    remotePath = ""
                                    customRemote = false
                                }
                                .buttonStyle(WbPillButtonStyle())
                                .controlSize(.small)
                            }
                        } else {
                            HStack(spacing: WbSpace.sm) {
                                Text("/sdcard/Download/…")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(WbColor.textSecondary)
                                Button(t("自定义", "Custom")) {
                                    customRemote = true
                                }
                                .buttonStyle(WbPillButtonStyle())
                                .controlSize(.small)
                            }
                        }
                    }

                    Text(syncDirection == "bidirectional"
                         ? t("双向同步修改与删除；若双方同时修改同一文件，会保留双方内容等待确认。",
                             "Syncs edits and deletions both ways; conflicting changes preserve both versions until resolved.")
                         : t("仅将 Mac 的更改与删除单向同步到设备；设备端已有文件会保留。",
                             "Mirrors Mac edits and deletions to the device; device-only files are preserved."))
                        .wbFont(WbType.caption)
                        .foregroundStyle(WbColor.textSecondary)
                }

                Section {
                    if folderSyncs.isEmpty {
                        HStack(spacing: WbSpace.md) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(WbColor.textTertiary)
                                .frame(width: 24, height: 24)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t("暂无活动同步", "No active folder syncs"))
                                    .wbFont(WbType.body)
                                    .foregroundStyle(WbColor.textSecondary)
                                Text(running
                                     ? t("点击右上角“选择文件夹…”即可添加。", "Click “Choose folder…” above to add one.")
                                     : t("请先启动设备，再添加文件夹同步。", "Start the device to add a folder sync."))
                                    .wbFont(WbType.caption)
                                    .foregroundStyle(WbColor.textTertiary)
                            }
                        }
                        .padding(.vertical, WbSpace.xs)
                    } else {
                        ForEach(folderSyncs.indices, id: \.self) { index in
                            syncRow(folderSyncs[index])
                        }
                    }
                } header: {
                    HStack {
                        Text(t("活动同步", "Active syncs"))
                        Spacer()
                        Text(t("\(folderSyncs.count) 个", "\(folderSyncs.count)"))
                            .foregroundStyle(WbColor.textSecondary)
                            .monospacedDigit()
                    }
                }

                if !error.isEmpty {
                    Section {
                        Label(error, systemImage: WbIcon.warning)
                            .wbFont(WbType.caption)
                            .foregroundStyle(WbColor.negative)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            DeviceSheetFooter(note: t("同步仅在设备运行期间保持活动。", "Sync stays active while the device is running.")) {
                Button(t("关闭", "Close")) { closePanel() }
                    .buttonStyle(WbPillButtonStyle())
                    .controlSize(.regular)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(width: 580, height: 560)
        .modifier(DeviceSheetGlass())
        .onAppear { load() }
        .onReceive(syncTimer) { _ in
            if running && !working { load(silent: true) }
        }
        .onChange(of: running) { _ in load(silent: true) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: WbSpace.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text(t("文件夹同步", "Folder sync"))
                    .wbFont(WbType.headline)
                    .foregroundStyle(WbColor.textPrimary)
                HStack(spacing: WbSpace.xs) {
                    Circle()
                        .fill(running ? Color.green : Color.secondary)
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text("\(currentDevice.name) · \(running ? t("运行中", "Running") : t("已停止", "Stopped"))")
                        .wbFont(WbType.body)
                        .foregroundStyle(WbColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .center, spacing: WbSpace.sm) {
                Button { load() } label: {
                    Image(systemName: WbIcon.refresh)
                }
                .buttonStyle(WbPillButtonStyle())
                .controlSize(.regular)
                .disabled(working)
                .help(t("刷新", "Refresh"))
                .accessibilityLabel(t("刷新", "Refresh"))

                startSyncButton
            }
        }
        .padding(.horizontal, WbSpace.xl)
        .padding(.top, WbSpace.lg)
        .padding(.bottom, WbSpace.md)
    }

    @ViewBuilder
    private var startSyncButton: some View {
        let button = Button { pickAndStartSync() } label: {
            Label(t("选择文件夹…", "Choose folder…"), systemImage: WbIcon.plus)
        }
        .disabled(!running || working)
        .fixedSize()
        .help(t("选择 Mac 文件夹开始同步", "Choose a Mac folder to sync"))

        if running && !working {
            button.buttonStyle(.borderedProminent).controlSize(.regular).tint(WbColor.accent)
        } else {
            button.buttonStyle(WbPillButtonStyle()).controlSize(.regular)
        }
    }

    // MARK: - Row

    private func syncRow(_ item: [String: Any]) -> some View {
        let isBidi = (item["direction"] as? String) == "bidirectional"
        let arrow = isBidi ? "↔" : "→"
        let local = item["local"] as? String ?? "—"
        let folderName = local == "—" ? "—" : URL(fileURLWithPath: local).lastPathComponent
        let remote = item["remote"] as? String ?? "—"
        let syncID = item["id"] as? String ?? ""
        let state = item["state"] as? String ?? ""
        let pushed = item["pushed"] as? Int ?? 0
        let pulled = item["pulled"] as? Int ?? 0
        let files = item["files"] as? Int ?? 0
        let conflicts = item["conflicts"] as? [[String: Any]] ?? []

        return VStack(alignment: .leading, spacing: WbSpace.sm) {
            HStack(alignment: .center, spacing: WbSpace.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill((isBidi ? WbColor.accent : Color.secondary).opacity(0.12))
                        .frame(width: 28, height: 28)
                    Image(systemName: isBidi ? "arrow.left.arrow.right" : "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isBidi ? WbColor.accent : WbColor.textSecondary)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: WbSpace.xs) {
                        Text(folderName)
                            .wbFont(WbType.body.weighted(.medium))
                            .foregroundStyle(WbColor.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(isBidi ? t("双向", "2-way") : t("单向", "1-way"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(isBidi ? WbColor.accent : WbColor.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background((isBidi ? WbColor.accent : Color.secondary).opacity(0.12), in: Capsule())
                    }
                    Text("\(local) \(arrow) \(remote)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(WbColor.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if !state.isEmpty {
                        let statsText = isBidi
                            ? t("\(syncStateText(state)) · ↑\(pushed) ↓\(pulled) · \(files) 个文件",
                                "\(syncStateText(state)) · ↑\(pushed) ↓\(pulled) · \(files) files")
                            : t("\(syncStateText(state)) · 已推送 \(pushed) / \(files)",
                                "\(syncStateText(state)) · Pushed \(pushed) / \(files)")
                        Text(statsText)
                            .wbFont(WbType.caption)
                            .foregroundStyle(WbColor.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: WbSpace.xs) {
                    if local != "—" {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: local)])
                        } label: {
                            Image(systemName: WbIcon.folder)
                        }
                        .buttonStyle(WbPillButtonStyle())
                        .controlSize(.small)
                        .help(t("在访达中显示", "Reveal in Finder"))
                        .accessibilityLabel(t("在访达中显示", "Reveal in Finder"))
                    }

                    if !syncID.isEmpty {
                        Button(t("停止", "Stop")) { stopSync(syncID) }
                            .buttonStyle(WbPillButtonStyle())
                            .controlSize(.small)
                            .disabled(working)
                    }
                }
            }

            if let lastError = item["last_error"] as? String, !lastError.isEmpty {
                Label(lastError, systemImage: WbIcon.warning)
                    .wbFont(WbType.caption)
                    .foregroundStyle(WbColor.negative)
                    .textSelection(.enabled)
                    .padding(.leading, 40)
            }

            if !syncID.isEmpty && !conflicts.isEmpty {
                VStack(alignment: .leading, spacing: WbSpace.xs) {
                    ForEach(conflicts.indices, id: \.self) { cIndex in
                        if let path = conflicts[cIndex]["path"] as? String {
                            HStack(spacing: WbSpace.xs) {
                                Image(systemName: WbIcon.warning)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.orange)
                                Text(t("冲突：", "Conflict: ") + path)
                                    .wbFont(WbType.caption)
                                    .foregroundStyle(WbColor.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: WbSpace.xs)
                                Button(t("保留 Mac", "Keep Mac")) {
                                    resolveConflict(id: syncID, path: path, resolution: "keep_local")
                                }.buttonStyle(WbPillButtonStyle()).controlSize(.small).disabled(working)
                                Button(t("保留设备", "Keep device")) {
                                    resolveConflict(id: syncID, path: path, resolution: "keep_remote")
                                }.buttonStyle(WbPillButtonStyle()).controlSize(.small).disabled(working)
                                Button(t("保留两者", "Keep both")) {
                                    resolveConflict(id: syncID, path: path, resolution: "keep_both")
                                }.buttonStyle(WbPillButtonStyle()).controlSize(.small).disabled(working)
                            }
                        }
                    }
                }
                .padding(WbSpace.sm)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: WbRadius.sm))
                .padding(.leading, 40)
            }
        }
        .padding(.vertical, WbSpace.xxs)
    }

    // MARK: - Helpers & RPC

    private func syncStateText(_ state: String) -> String {
        switch state {
        case "mirroring": return t("首次同步", "Initial sync")
        case "syncing": return t("正在同步", "Syncing")
        case "watching": return t("已同步", "Up to date")
        default: return state
        }
    }

    private func load(silent: Bool = false) {
        model.call("file.sync.list", ["device": device.id]) { result in
            switch result {
            case .success(let value):
                folderSyncs = value as? [[String: Any]] ?? []
                if !silent { error = "" }
            case .failure(let failure):
                if !silent {
                    error = OperationMessages.error(failure.localizedDescription, language: model.language)
                }
            }
        }
    }

    private func pickAndStartSync() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let alert = NSAlert()
        if syncDirection == "bidirectional" {
            alert.messageText = t("开始双向同步？", "Start bidirectional sync?")
            alert.informativeText = t("Mac 与设备上的更改和删除会互相同步，发生冲突时会保留双方文件。",
                                    "Changes and deletions will sync in both directions. Conflicts preserve both versions.")
        } else {
            alert.messageText = t("开始单向同步？", "Start one-way sync?")
            alert.informativeText = t("Mac 文件夹中的删除会同步到设备上的对应目录。",
                                    "Deletions in this Mac folder will be mirrored to the corresponding folder on the device.")
        }
        alert.addButton(withTitle: t("开始同步", "Start sync"))
        alert.addButton(withTitle: t("取消", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var params: [String: Any] = [
            "device": device.id,
            "local": url.path,
            "direction": syncDirection
        ]
        if customRemote {
            let trimmedRemote = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedRemote.isEmpty { params["remote"] = trimmedRemote }
        }

        working = true
        error = ""
        model.call("file.sync.start", params) { result in
            working = false
            switch result {
            case .success:
                load()
            case .failure(let failure):
                error = OperationMessages.error(failure.localizedDescription, language: model.language)
            }
        }
    }

    private func stopSync(_ syncID: String) {
        working = true
        error = ""
        model.call("file.sync.stop", ["id": syncID]) { result in
            working = false
            if case .failure(let failure) = result {
                error = OperationMessages.error(failure.localizedDescription, language: model.language)
            }
            load()
        }
    }

    private func resolveConflict(id: String, path: String, resolution: String) {
        working = true
        error = ""
        model.call("file.sync.resolve", ["id": id, "path": path, "resolution": resolution]) { result in
            working = false
            if case .failure(let failure) = result {
                error = OperationMessages.error(failure.localizedDescription, language: model.language)
            }
            load()
        }
    }
}
