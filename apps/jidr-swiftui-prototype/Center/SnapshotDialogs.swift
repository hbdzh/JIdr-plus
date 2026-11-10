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
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: WbSpace.xs) {
                Text(t("保存 \(device.name) 的快照", "Save snapshot of \(device.name)"))
                    .wbFont(WbType.title)
                    .foregroundStyle(WbColor.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Text(t("将按当前状态保存内存和磁盘数据。保存时 Android 会暂停几秒钟。",
                       "Saves memory and disk exactly as they are now. Android pauses for a few seconds while it saves."))
                    .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, WbSpace.lg)

            WbGroupLabel(text: t("快照信息", "Snapshot"))
                .padding(.bottom, WbSpace.sm)
            WbFormGroup {
                WbFormRow(label: t("名称", "Name")) {
                    TextField(t("快照名称", "Snapshot name"), text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .disabled(saving)
                        .accessibilityLabel(t("名称", "Name"))
                }
                WbRowDivider()
                WbFormRow(label: t("将标记为", "Will be tagged")) {
                    Text(Snapshots.rootTag(mode: device.root.mode, magisk: magiskVersion, language: model.language))
                        .wbFont(WbType.caption.weighted(.medium))
                        .foregroundStyle(WbColor.textSecondary)
                        .padding(.horizontal, WbSpace.sm)
                        .padding(.vertical, WbSpace.xs)
                        .background(WbColor.control, in: Capsule())
                        .lineLimit(1).truncationMode(.middle)
                }
            }

            if othersLoaded {
                Text(Snapshots.sizesHint(others, language: model.language))
                    .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, WbSpace.md)
            }
            if !device.running {
                Label(t("启动设备后才能保存快照。", "Start the device to save a snapshot."), systemImage: WbIcon.info)
                    .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                    .padding(.top, WbSpace.md)
            }
            if saving {
                HStack(spacing: WbSpace.sm) {
                    ProgressView().controlSize(.small)
                    Text(progress.isEmpty ? t("正在保存…", "Saving…") : progress)
                        .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.top, WbSpace.md)
            }
            if !error.isEmpty {
                Text(error).wbFont(WbType.caption).foregroundStyle(WbColor.negative).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, WbSpace.md)
            }

            HStack(spacing: WbSpace.sm) {
                Spacer()
                Button(t("取消", "Cancel")) { dismiss() }
                    .buttonStyle(WbSecondaryButtonStyle())
                    .disabled(saving)
                Button(saving ? t("正在保存…", "Saving…") : t("保存", "Save")) { save() }
                    .buttonStyle(WbPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || !device.running)
            }
            .padding(.top, WbSpace.lg)
        }
        .padding(WbSpace.xl)
        .frame(width: 460)
        .tint(WbColor.accent)
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
