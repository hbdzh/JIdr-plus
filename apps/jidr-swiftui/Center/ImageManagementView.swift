// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

struct ManagedImageDevice: Decodable {
    let id: String
    let name: String
}

struct ManagedSystemImage: Decodable, Identifiable {
    let api: Int
    let tag: String
    let abi: String
    let package: String
    let source: String
    let root: String
    let size_bytes: UInt64?
    let used_by: [ManagedImageDevice]
    let can_delete: Bool
    var id: String { "\(source):\(root):\(package)" }
}

/// Management uses physical SDK copies, rather than the deduplicated image picker.
struct ImageManagementView: View {
    @ObservedObject var model: CenterModel
    var onPanelClose: ((@escaping () -> Void) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var images: [ManagedSystemImage] = []
    @State private var loading = false
    @State private var loaded = false
    @State private var removing = false
    @State private var installing = false
    @State private var error = ""
    @State private var target: ManagedSystemImage?

    private func load() {
        guard !loading else { return }
        loading = true; error = ""
        model.call("image.inventory") { result in
            loading = false; loaded = true
            do { images = try model.decode(result.get(), as: [ManagedSystemImage].self) }
            catch { self.error = model.text("无法读取系统镜像：", "Unable to load system images: ") + model.readable(error) }
        }
    }

    private func remove(_ image: ManagedSystemImage) {
        guard image.can_delete, !removing else { return }
        removing = true; error = ""
        model.call("image.remove", ["image": image.package, "source": image.source, "root": image.root]) { result in
            removing = false
            switch result {
            case .success: load()
            case .failure(let failure):
                error = model.text("无法删除镜像，请刷新后重试：", "Unable to remove the image. Refresh and try again: ") + model.readable(failure)
                loadAfterFailure()
            }
        }
    }

    private func loadAfterFailure() {
        // Refresh stale usage information without hiding the reason for failure.
        let previousError = error
        model.call("image.inventory") { result in
            if let value = try? result.get(), let refreshed = try? model.decode(value, as: [ManagedSystemImage].self) { images = refreshed }
            error = previousError
        }
    }

    private func sourceLabel(_ image: ManagedSystemImage) -> String {
        image.source == "external" ? model.text("外部 SDK · 只读", "External SDK · read-only") : model.text("miko SDK", "miko SDK")
    }

    private func imageRow(_ image: ManagedSystemImage) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "square.3.layers.3d")
                .font(.system(size: 16, weight: .medium)).foregroundStyle(WbColor.accentText)
                .frame(width: 38, height: 38)
                .background(WbColor.accentContainer.opacity(0.8), in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Android API \(image.api) · \(Device.imageTagLabel(image.tag)) · \(image.abi)")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(WbColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(sourceLabel(image))
                    if let bytes = image.size_bytes {
                        Text("·")
                        Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file))
                    }
                }
                .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                Text(image.root).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(WbColor.textSecondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled).help(image.root)
                if !image.used_by.isEmpty {
                    Text(model.text("使用此版本的设备：", "Devices using this image version: ") + image.used_by.map(\.name).joined(separator: "、"))
                        .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if image.source != "external" && !image.can_delete {
                    Text(model.text("此位置当前不可删除", "This location cannot currently be modified"))
                        .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if image.source != "external" {
                Button(model.text("删除…", "Remove…")) { target = image }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(!image.can_delete || loading || removing)
                    .help(image.used_by.isEmpty ? model.text("删除系统镜像", "Remove system image") : model.text("设备正在使用此镜像", "Devices use this image"))
                    .accessibilityLabel(model.text("删除镜像：", "Remove image: ") + "Android API \(image.api) · \(Device.imageTagLabel(image.tag)) · \(image.abi)")
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WbColor.raised.opacity(0.28), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WbColor.borderSubtle))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.text("系统镜像", "System images")).font(.system(size: 20, weight: .semibold))
                    Text(model.text("查看已安装的镜像及使用它们的设备。", "View installed images and the devices that use them."))
                        .font(.system(size: 12)).foregroundStyle(WbColor.textSecondary)
                }
                Spacer(minLength: 12)
                Button(model.text("安装镜像…", "Install image…")) { installing = true }
                    .buttonStyle(.borderedProminent).controlSize(.regular).tint(WbColor.accent).disabled(loading || removing)
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if loading && !loaded {
                        ProgressView(model.text("正在读取镜像…", "Loading images…")).controlSize(.small)
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else if images.isEmpty && error.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "square.3.layers.3d").font(.system(size: 24)).foregroundStyle(WbColor.textSecondary)
                            Text(model.text("没有已安装的系统镜像", "No system images installed"))
                                .font(.system(size: 13, weight: .medium))
                        }.frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        ForEach(images) { image in imageRow(image) }
                    }
                    if !error.isEmpty {
                        Text(error).font(.system(size: 11)).foregroundStyle(WbColor.negative).textSelection(.enabled)
                    }
                }.padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text(model.text("外部 SDK 中的镜像由其所属工具管理。", "Images in external SDKs are managed by their owning tools."))
                    .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                Spacer()
                Button(model.text("刷新", "Refresh"), action: load).disabled(loading || removing)
                Button(model.text("完成", "Done")) {
                    if let onPanelClose { onPanelClose({}) } else { dismiss() }
                }.keyboardShortcut(.cancelAction).disabled(removing)
            }
            .buttonStyle(.bordered).controlSize(.regular)
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 700, height: 500)
        .modifier(DeviceSheetGlass())
        .onAppear(perform: load)
        .interactiveDismissDisabled(removing)
        .sheet(isPresented: $installing, onDismiss: load) {
            NewDeviceView(model: model, initialImageInstall: true, standaloneImageInstall: true)
                .environment(\.locale, Locale(identifier: model.language == 0 ? "en" : "zh-Hans"))
        }
        .alert(model.text("删除系统镜像？", "Remove system image?"),
               isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
               presenting: target) { image in
            Button(model.text("取消", "Cancel"), role: .cancel) { target = nil }
            Button(model.text("删除镜像", "Remove image"), role: .destructive) { target = nil; remove(image) }
        } message: { image in
            Text(model.text("将永久删除此 miko SDK 中的镜像：", "Permanently remove this image from the miko SDK: ")
                 + "\nAndroid API \(image.api) · \(Device.imageTagLabel(image.tag)) · \(image.abi)\n\(image.root)\n\n"
                 + model.text("miko 只检查自身设备的使用情况。", "miko only checks usage by its own devices."))
        }
    }
}
