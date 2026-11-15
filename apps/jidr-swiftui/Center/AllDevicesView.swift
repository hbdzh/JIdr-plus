// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import SwiftUI

/// The same device silhouette is used in the sidebar, cards and overview.
enum DeviceArtworkState {
    case stopped, starting, running

    init(deviceState: String) {
        switch deviceState {
        case "running": self = .running
        case "starting", "booting": self = .starting
        default: self = .stopped
        }
    }
}

struct DeviceArtwork: View {
    let state: DeviceArtworkState
    let frame: CGImage?
    let width: CGFloat
    let height: CGFloat

    private var bodyRadius: CGFloat { width * 0.19 }
    private var inset: CGFloat { max(1.5, width * 0.065) }
    private var screenRadius: CGFloat { width * 0.135 }
    private var statusColor: Color {
        switch state {
        case .running: return Color(nsColor: .systemGreen)
        case .starting: return Color(nsColor: .systemOrange)
        case .stopped: return Color(nsColor: .systemGray)
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: bodyRadius, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.38), Color(white: 0.13), Color(white: 0.26)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            RoundedRectangle(cornerRadius: bodyRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: max(0.5, width * 0.015))
            screen
                .frame(width: width - inset * 2, height: height - inset * 2)
                .clipShape(RoundedRectangle(cornerRadius: screenRadius, style: .continuous))
            Circle()
                .fill(Color.black.opacity(0.72))
                .frame(width: max(1.5, width * 0.065), height: max(1.5, width * 0.065))
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, inset + width * 0.08)
        }
        .frame(width: width, height: height)
        .overlay(alignment: .bottomTrailing) {
            Circle().fill(statusColor)
                .frame(width: max(5, width * 0.14), height: max(5, width * 0.14))
                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: max(1, width * 0.025)))
                .padding(.trailing, max(0.5, width * 0.015))
                .padding(.bottom, max(0.5, width * 0.015))
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var screen: some View {
        if state == .running, let frame {
            Image(decorative: frame, scale: 1).resizable().scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: state == .running
                               ? [Color(red: 0.25, green: 0.32, blue: 0.40), Color(red: 0.12, green: 0.16, blue: 0.22)]
                               : [Color(white: 0.17), Color(white: 0.075)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if state == .stopped {
                    LinearGradient(colors: [.white.opacity(0.09), .clear, .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                } else if state == .starting {
                    ProgressView().controlSize(.mini).tint(.white.opacity(0.8))
                        .scaleEffect(min(1, width / 40))
                }
            }
        }
    }
}

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
        DeviceArtwork(state: DeviceArtworkState(deviceState: device.status.state),
                      frame: device.running ? (model.players[device.id]?.transport.lastFrame ?? model.deviceThumbnails[device.id]) : nil,
                      width: width, height: height)
    }
}

/// The library remains a device-management surface; choosing a device opens
/// the existing overview without starting it or opening its player.
struct AllDevicesView: View {
    @ObservedObject var model: CenterModel
    @State private var budget: DeviceBudget?
    @State private var budgetError = false
    @State private var budgetLoading = false
    @State private var budgetRefreshPending = false
    @State private var budgetGeneration = 0
    private let budgetTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
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
                if #available(macOS 26.0, *) {
                    viewPicker
                        .controlSize(.large)
                        .clipShape(Capsule())
                        .glassEffect(.regular, in: Capsule())
                    newDeviceButton
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                } else {
                    viewPicker
                    newDeviceButton
                }
            }
            budgetSummary
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
        .onAppear { refreshBudget() }
        .onDisappear { budgetGeneration += 1; budgetLoading = false; budgetRefreshPending = false }
        .onReceive(budgetTimer) { _ in refreshBudget() }
        .onChange(of: model.devices.map { "\($0.id):\($0.status.state)" }) { _ in refreshBudget() }
    }

    private func refreshBudget() {
        if budgetLoading { budgetRefreshPending = true; return }
        budgetLoading = true
        budgetGeneration += 1
        let generation = budgetGeneration
        model.call("host.budget") { result in
            guard generation == budgetGeneration else { return }
            budgetLoading = false
            if case .success(let value) = result, let next = try? model.decode(value, as: DeviceBudget.self) {
                budget = next; budgetError = false
            } else {
                budget = nil; budgetError = true
            }
            if budgetRefreshPending { budgetRefreshPending = false; refreshBudget() }
        }
    }

    private var budgetSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(t("设备内存预算", "Device memory budget"), systemImage: "memorychip")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let budget {
                    Text("\(DeviceBudget.gigabytes(budget.used_mb)) / \(DeviceBudget.gigabytes(budget.budget_mb))")
                        .font(.subheadline.monospacedDigit())
                } else if budgetLoading {
                    ProgressView().controlSize(.small)
                } else if budgetError {
                    Button(t("重试", "Retry")) { refreshBudget() }
                }
            }
            if let budget {
                ProgressView(value: budget.fraction).tint(budget.used_mb > budget.budget_mb ? .orange : .accentColor)
                Text(t("预算为 Mac 内存的 \(budget.budget_percent)%；占用取预估值与最近测量值的较大者。", "Budget is \(budget.budget_percent)% of Mac memory; usage is the greater of estimated and last measured values."))
                    .font(.caption).foregroundStyle(.secondary)
                if !budget.devices.isEmpty {
                    DisclosureGroup(t("查看各设备占用", "Device usage")) {
                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach(budget.devices) { usage in
                                    HStack {
                                        Text(usage.name).lineLimit(1)
                                        Spacer()
                                        Text(DeviceBudget.gigabytes(usage.countedMB)).monospacedDigit()
                                        if let device = model.devices.first(where: { $0.id == usage.id }), device.running {
                                            Button(t("休眠", "Hibernate")) { model.hibernate(device.id) }
                                                .disabled(model.busy.contains(device.id) || model.busyHolder(for: device.id) != nil)
                                        }
                                    }.font(.caption)
                                }
                            }.padding(.top, 6)
                        }.frame(maxHeight: 130)
                    }.font(.caption)
                }
            } else if budgetError {
                Text(t("无法读取设备内存预算。", "Could not load the device memory budget."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("device-memory-budget")
    }

    private var viewPicker: some View {
        Picker(t("显示方式", "View"), selection: $model.gridView) {
            Image(systemName: "list.bullet").accessibilityLabel(t("列表", "List")).tag(false)
            Image(systemName: "square.grid.2x2").accessibilityLabel(t("网格", "Grid")).tag(true)
        }
        .pickerStyle(.segmented).labelsHidden()
        .accessibilityLabel(t("设备显示方式", "Device view"))
    }

    private var newDeviceButton: some View {
        Button(t("新建设备", "New device"), systemImage: "plus") { model.present(.newDevice) }
    }

    private func deviceRow(_ device: Device) -> some View {
        HStack(spacing: 12) {
            deviceLink(device, thumbnailWidth: 32, thumbnailHeight: 56)
            Spacer(minLength: 8)
            deviceAction(device)
            DeviceMoreButton(model: model, device: device).frame(width: 30, height: 28)
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(device.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    Text(device.statusText(language: model.language) + " · " + device.androidVersionShort)
                        .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    if let hardware = model.cardHardware[device.id] {
                        Text(hardware.summary(language: model.language)).font(.caption).lineSpacing(2).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if let app = model.appSearchMatches[device.id] {
                        Text(t("匹配应用：\(app)", "Matching app: \(app)"))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
