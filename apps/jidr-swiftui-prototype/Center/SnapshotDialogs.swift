// SPDX-License-Identifier: GPL-3.0-only
// Snapshot dialogs: the save dialog (name, root tag and the other snapshots'
// sizes) and the D29 refusal explanation. Data and formatting live in
// SnapshotData.swift; the Slint reference is crates/jidr-ui/ui/snapshots.slint.
import AppKit
import SwiftUI

/// The save dialog (snapshots.slint:206-260): name, the root tag it will get,
/// and how much the device's other snapshots use.
struct SnapshotSaveDialog: View {
    @ObservedObject var model: CenterModel
    let device: Device
    let magiskVersion: String
    let onSaved: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var othersLoaded = false
    @State private var others: [SnapshotRow] = []
    @State private var saving = false
    @State private var progress = ""
    @State private var error = ""

    init(model: CenterModel, device: Device, magiskVersion: String = "", onSaved: @escaping (String) -> Void = { _ in }) {
        self.model = model
        self.device = device
        self.magiskVersion = magiskVersion
        self.onSaved = onSaved
        _name = State(initialValue: Snapshots.defaultName(language: model.language))
    }

    private func t(_ chinese: String, _ english: String) -> String { model.text(chinese, english) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("保存 \(device.name) 的快照", "Save snapshot of \(device.name)")).font(.title3.bold())
                Text(t("将按当前状态保存内存和磁盘数据。保存时 Android 会暂停几秒钟。",
                       "Saves memory and disk exactly as they are now. Android pauses for a few seconds while it saves."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(t("名称", "Name")).font(.caption).foregroundStyle(.secondary)
                TextField(t("快照名称", "Snapshot name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(saving)
            }
            HStack {
                Text(t("将标记为", "Will be tagged")).font(.caption).foregroundStyle(.secondary)
                Text(Snapshots.rootTag(mode: device.root.mode, magisk: magiskVersion, language: model.language))
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
            if othersLoaded {
                Text(Snapshots.sizesHint(others, language: model.language))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !device.running {
                Label(t("启动设备后才能保存快照。", "Start the device to save a snapshot."), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if saving {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(progress.isEmpty ? t("正在保存…", "Saving…") : progress).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(t("取消", "Cancel")) { dismiss() }.disabled(saving)
                Button(saving ? t("正在保存…", "Saving…") : t("保存", "Save")) { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || !device.running)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: loadOthers)
    }

    private func loadOthers() {
        guard !othersLoaded else { return }
        model.call("snapshot.list", ["device": device.id]) { result in
            guard case .success(let value) = result, let list = try? model.decode(value, as: SnapshotList.self) else { return }
            others = Snapshots.sorted(list.snapshots)
            othersLoaded = true
        }
    }

    private func save() {
        if let problem = Snapshots.nameProblem(name) {
            error = Snapshots.nameProblemText(problem, language: model.language)
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        error = ""
        saving = true
        progress = t("正在保存…", "Saving…")
        model.call("snapshot.save", ["device": device.id, "name": trimmed],
                   onProgress: { message, _, _ in
            if !message.isEmpty { progress = OperationMessages.progress(message, language: model.language) }
        }) { result in
            saving = false
            switch result {
            case .success:
                dismiss()
                onSaved(trimmed)
            case .failure(let failure):
                error = OperationMessages.error(failure.localizedDescription, language: model.language)
            }
        }
    }
}
