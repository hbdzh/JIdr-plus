// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI

/// Compact previews use the existing player frame when one is available.
struct DevicePreview: View {
    @ObservedObject var model: CenterModel
    let device: Device
    let width: CGFloat
    let height: CGFloat

    @ViewBuilder var body: some View {
        if device.running {
            TimelineView(.periodic(from: .now, by: 2)) { _ in preview }
        } else {
            preview
        }
    }

    private var preview: some View {
        ZStack {
            if device.stopped, let image = WbImageCache.image(named: "device-stopped") {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: width * 0.18).fill(Color.black)
                RoundedRectangle(cornerRadius: width * 0.18)
                    .strokeBorder(Color.primary.opacity(0.28), lineWidth: 1)
                if device.running, let frame = model.players[device.id]?.transport.lastFrame ?? model.deviceThumbnails[device.id] {
                    Image(decorative: frame, scale: 1).resizable().scaledToFill()
                        .frame(width: width - 8, height: height - 8)
                        .clipShape(RoundedRectangle(cornerRadius: width * 0.13))
                }
            }
        }.frame(width: width, height: height)
    }
}

/// The library remains a device-management surface; choosing a device opens
/// the existing overview without starting it or opening its player.
struct AllDevicesView: View {
    @ObservedObject var model: CenterModel
    private func t(_ zh: String, _ en: String) -> String { model.text(zh, en) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("全部设备", "All devices")).font(.title2.weight(.semibold))
                    Text(String(format: t("%d 台设备", "%d devices"), model.filteredDevices.count))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker(t("显示方式", "View"), selection: $model.gridView) {
                    Image(systemName: "list.bullet").tag(false)
                    Image(systemName: "square.grid.2x2").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 76)
                .accessibilityLabel(t("设备显示方式", "Device view"))
                Button(t("新建设备", "New device"), systemImage: "plus") { model.present(.newDevice) }
            }
            if model.filteredDevices.isEmpty {
                VStack(spacing: 8) {
                    Text(t("没有匹配的设备", "No matching devices")).foregroundStyle(.secondary)
                    Button(t("清除搜索", "Clear search")) { model.deviceQuery = "" }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    if model.gridView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 420), spacing: 14)], spacing: 14) {
                            ForEach(model.filteredDevices) { device in deviceCard(device) }
                        }
                    } else {
                        LazyVStack(spacing: 8) {
                            ForEach(model.filteredDevices) { device in deviceRow(device) }
                        }
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("all-devices-view")
    }

    private func deviceRow(_ device: Device) -> some View {
        HStack(spacing: 12) {
            deviceLink(device, thumbnailWidth: 32, thumbnailHeight: 56)
            Spacer(minLength: 8)
            deviceAction(device)
            DeviceMoreButton(model: model, device: device).frame(width: 30, height: 28)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .onAppear { model.loadCardHardware(device.id) }
    }

    private func deviceCard(_ device: Device) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            deviceLink(device, thumbnailWidth: 42, thumbnailHeight: 72)
            HStack {
                deviceAction(device)
                Spacer()
                DeviceMoreButton(model: model, device: device).frame(width: 30, height: 28)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .onAppear { model.loadCardHardware(device.id) }
    }

    private func deviceLink(_ device: Device, thumbnailWidth: CGFloat, thumbnailHeight: CGFloat) -> some View {
        Button { model.select(device.id) } label: {
            HStack(spacing: 12) {
                DevicePreview(model: model, device: device, width: thumbnailWidth, height: thumbnailHeight)
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(device.statusText(language: model.language) + " · " + device.androidVersionShort)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let hardware = model.cardHardware[device.id] {
                        Text(hardware.summary(language: model.language)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let app = model.appSearchMatches[device.id] {
                        Text(t("匹配应用：\(app)", "Matching app: \(app)"))
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("查看设备：\(device.name)", "View device: \(device.name)"))
    }

    @ViewBuilder private func deviceAction(_ device: Device) -> some View {
        switch DeviceOverviewPrimaryAction(state: device.status.state) {
        case .start:
            Button(t("启动", "Start"), systemImage: "play") { model.start(device.id) }
                .buttonStyle(.borderedProminent).disabled(model.busy.contains(device.id))
        case .stop:
            Button(t("停止", "Stop"), systemImage: "stop") { model.stop(device.id) }
                .disabled(model.busy.contains(device.id))
        case .cancelStart:
            Button(t("取消启动", "Cancel start")) { model.stop(device.id) }
                .disabled(model.busy.contains(device.id))
        case .progress:
            ProgressView().controlSize(.small)
        }
    }
}
