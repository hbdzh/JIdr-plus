// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

/// Root configuration lives beside Root status and diagnostics. Confirmation
/// captures the requested mode and device, independent of later UI selection.
struct DeviceRootControls: View {
    @ObservedObject var model: CenterModel
    let device: Device
    @State private var mode = "none"
    @State private var pending: Change?
    private struct Change: Identifiable {
        let id = UUID()
        let mode: String? // nil opens the guided Full Root flow
    }
    private func t(_ zh: String, _ en: String) -> String { model.text(zh, en) }
    private var busy: Bool { model.busy.contains(device.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: WbSpace.sm) {
            LabeledContent(t("Root 模式", "Root mode")) {
                Picker("", selection: $mode) {
                    Text(t("无", "None")).tag("none")
                    Text("Shell Root").tag("adb")
                    Text(t("完整 Root", "Full Root")).tag("magisk")
                }
                .labelsHidden().frame(width: 170)
                .accessibilityLabel(t("Root 模式", "Root mode"))
                .disabled(!device.stopped || busy)
            }
            ActionFlowLayout(spacing: 8) {
                Button(t("更改模式…", "Change mode…")) { pending = Change(mode: mode) }
                    .disabled(!device.stopped || busy || mode == device.root.mode)
                if device.root.mode == "magisk" {
                    Button(t("设置或修复完整 Root…", "Set up or repair Full Root…")) { pending = Change(mode: nil) }
                        .disabled(busy)
                    Button(t("恢复为无 Root…", "Revert to no Root…"), role: .destructive) { pending = Change(mode: "none") }
                        .disabled(!device.stopped || busy)
                }
            }
            .buttonStyle(.bordered).controlSize(.regular)
            Text(device.stopped
                 ? t("更改模式可能需要冷启动，并影响快照兼容性。", "Changing modes may require a cold boot and affect snapshot compatibility.")
                 : t("停止设备后可更改 Root 模式。", "Stop the device to change its Root mode."))
                .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
        }
        .onAppear { mode = device.root.mode }
        .onChange(of: device.root.mode) { mode = $0 }
        .alert(item: $pending) { change in
            let title = change.mode == nil
                ? t("设置“\(device.name)”的完整 Root？", "Set up Full Root for “\(device.name)”?")
                : t("更改“\(device.name)”的 Root 模式？", "Change the Root mode for “\(device.name)”?")
            let detail = change.mode == nil || change.mode == "magisk"
                ? t("将下载并配置 Magisk，设备可能重启。请先保存游戏进度。", "Downloads and configures Magisk; the device may restart. Save your game progress first.")
                : t("设备可能需要冷启动，部分快照可能无法恢复。请先保存游戏进度。", "A cold boot may be needed, and some snapshots may become incompatible. Save your game progress first.")
            let action: Alert.Button = change.mode == "none"
                ? .destructive(Text(t("更改", "Change"))) { perform(change) }
                : .default(Text(t("继续", "Continue"))) { perform(change) }
            return Alert(title: Text(title), message: Text(detail), primaryButton: action,
                         secondaryButton: .cancel(Text(t("取消", "Cancel"))))
        }
    }

    private func perform(_ change: Change) {
        guard let current = model.devices.first(where: { $0.id == device.id }), !model.busy.contains(device.id) else { return }
        if change.mode == nil || change.mode == "magisk" {
            model.closeDeviceTools(device.id)
            model.centerWindow?.makeKeyAndOrderFront(nil)
            model.setupFullRoot(device.id, name: device.name)
        } else if current.stopped, let mode = change.mode {
            model.operation("root.set", id: device.id, params: ["mode": mode])
        } else {
            model.showError(t("设备状态已变化，请停止设备后重试。", "The device state changed. Stop it and try again."))
        }
    }
}
