// SPDX-License-Identifier: GPL-3.0-only
// Full-root setup sheet, split out of DeviceViews.swift so the device-center
// and root/snapshot work lines stay in separate files.
import SwiftUI
struct FullRootView: View {
    @ObservedObject var model: CenterModel
    let target: RootPresentation
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("完整 Root 配置").font(.title2.bold())
            Text(target.name).foregroundStyle(.secondary)
            switch model.fullRoot[target.id] {
            case .running:
                HStack { ProgressView().controlSize(.small); Text(model.progress(for:target.id) ?? model.text("正在准备…", "Preparing…")) }
                Text("设备可能多次重启。Play 商店镜像可能需要在 Magisk 中为 Shell 手动授权。")
                    .font(.callout).foregroundStyle(.secondary)
                Button("打开设备窗口",systemImage:"macwindow") { model.openGame(target.id) }
                    .disabled(model.devices.first(where: { $0.id == target.id })?.running != true)
                Text("如设备重启后窗口断开，可再次点击此按钮。关闭此面板不会取消配置。")
                    .font(.caption).foregroundStyle(.secondary)
            case .verified(let version):
                Label("Root 验证成功",systemImage:"checkmark.circle.fill").foregroundStyle(.green)
                if !version.isEmpty { Text("Magisk \(version)") }
            case .failed(let error):
                Label("Root 配置未完成",systemImage:"exclamationmark.triangle.fill").foregroundStyle(.red)
                Text("请检查网络、游戏进度和快照状态后，再决定是否重试。")
                Text(error).font(.caption).textSelection(.enabled)
                Button("重试") { model.setupFullRoot(target.id,name:target.name) }.disabled(model.busy.contains(target.id))
            case nil:
                Text("没有正在进行的 Root 配置。")
            }
            HStack { Spacer(); Button("关闭") { dismiss() } }
        }.padding(24).frame(width:560)
    }
}
