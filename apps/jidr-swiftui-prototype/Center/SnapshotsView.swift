// SPDX-License-Identifier: GPL-3.0-only
// Snapshot list/save/load/delete views, split out of DeviceViews.swift so the
// device-center and root/snapshot work lines stay in separate files.
import SwiftUI
struct SnapshotRow: Decodable, Identifiable {
    var id: String { name }
    let name: String
    let quick_boot: Bool
    let restorable: Bool
    let root_mode: String?
    let size_bytes: UInt64?
}
struct SnapshotList: Decodable { let snapshots: [SnapshotRow] }
struct SnapshotsView: View {
    @ObservedObject var model: CenterModel
    let device: Device
    @Environment(\.dismiss) private var dismiss
    @State private var snapshots: [SnapshotRow] = []
    @State private var newName = ""
    @State private var error = ""
    @State private var running = false
    @State private var loading = true
    @State private var selected: SnapshotRow?
    @State private var deleting = false
    @State private var confirm = false
    func load() {
        loading = true
        model.call("snapshot.list", ["device":device.id]) { result in
            loading = false
            do { snapshots = try model.decode(result.get(),as:SnapshotList.self).snapshots; error = "" }
            catch { self.error = error.localizedDescription }
        }
    }
    func action(_ method:String, _ name:String) {
        running = true
        model.call(method,["device":device.id,"name":name]) { result in
            running = false
            switch result { case .success: newName = ""; load(); model.refresh(); case .failure(let failure): error = failure.localizedDescription }
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                VStack(alignment:.leading, spacing:4) { Text("管理快照").font(.title2.weight(.semibold)); Text(device.name).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(); Button("关闭") { dismiss() }.disabled(running)
            }
            HStack(spacing:8) {
                TextField("新快照名称",text:$newName).textFieldStyle(.roundedBorder)
                Button("保存快照") { action("snapshot.save",newName) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!device.running || newName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || running)
            }
            if !device.running { Text("启动设备后可保存快照。").font(.caption).foregroundStyle(.secondary) }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            if loading {
                ProgressView(model.text("正在读取快照…", "Loading snapshots…")).frame(maxWidth:.infinity,maxHeight:.infinity)
            } else if snapshots.isEmpty && error.isEmpty {
                Label(model.text("暂无快照", "No snapshots"), systemImage:"camera")
                    .foregroundStyle(.secondary).frame(maxWidth:.infinity, maxHeight:.infinity)
            } else { List(snapshots) { snapshot in
                HStack(spacing:12) { Image(systemName:"camera").foregroundStyle(.secondary); VStack(alignment:.leading,spacing:4) {
                    Text(snapshot.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing:8) {
                        Text(snapshot.quick_boot ? "快速启动快照" : "Root：\(snapshot.root_mode ?? "未知")")
                        if let size = snapshot.size_bytes { Text(ByteCountFormatter.string(fromByteCount:Int64(clamping:size),countStyle:.file)) }
                    }.font(.caption).foregroundStyle(.secondary)
                    if !snapshot.restorable { Text(model.text("不可恢复：快照文件可能不完整，或 Root 模式不匹配。", "Cannot restore: snapshot files may be incomplete or the root mode may not match.")).font(.caption).foregroundStyle(.secondary) }
                }; Spacer()
                    Button("恢复") { selected = snapshot; deleting = false; confirm = true }.disabled(!device.running || !snapshot.restorable || running)
                    if !snapshot.quick_boot { Button("删除",role:.destructive) { selected = snapshot; deleting = true; confirm = true }.disabled(running) }
                }.padding(.vertical,4)
            }.listStyle(.inset) }
        }.padding(20).frame(width:620,height:480).onAppear(perform:load)
        .alert(deleting ? "删除快照？" : "恢复快照？",isPresented:$confirm) {
            Button("取消",role:.cancel) { }
            Button(deleting ? "删除" : "恢复",role:.destructive) { if let selected { action(deleting ? "snapshot.delete" : "snapshot.load",selected.name) } }
        } message: { Text(deleting ? "删除后无法恢复该快照。" : "恢复将回退设备状态和应用数据，请先保存当前游戏进度。") }
    }
}
