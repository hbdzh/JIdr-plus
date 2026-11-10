// SPDX-License-Identifier: GPL-3.0-only
// Center overlays that are not sheets: the task list (jobs + quit guard), the
// toast and the daemon connection pill. Slint draws all three in the window
// (shell.slint TasksDialog, app.slint Toast, TitleBar conn pill); the center
// follows the same pattern.

import SwiftUI

// MARK: - Connection status

/// Titlebar pill for "connecting / reconnecting / disconnected". Hidden when
/// online, like Slint's title bar (a pill only appears for a non-online conn).
struct ConnectionStatusPill: View {
    @ObservedObject var model: CenterModel

    var body: some View {
        if model.connection.isOnline {
            EmptyView()
        } else {
            HStack(spacing: WbSpace.sm) {
                if model.connectionNeedsRetry {
                    Image(systemName: "exclamationmark.triangle.fill").wbFont(WbType.caption)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(model.connectionLabel).wbFont(WbType.caption).lineLimit(1)
                if model.connectionNeedsRetry {
                    Button(model.text("重新连接", "Reconnect")) { model.retryConnection() }
                        .buttonStyle(.borderless)
                        .wbFont(WbType.label.weighted(.semibold))
                }
            }
            .padding(.horizontal, WbSpace.md)
            .padding(.vertical, WbSpace.xs)
            .foregroundStyle(model.connectionNeedsRetry ? WbColor.negative : WbColor.warning)
            .background(model.connectionNeedsRetry ? WbStatus.negative.container : WbStatus.warning.container, in: Capsule())
            .help(model.connectionNeedsRetry
                  ? model.text("与后台的连接已断开。点击重新连接。", "The background connection is gone. Click Reconnect.")
                  : model.text("正在重新连接到后台服务…", "Reconnecting to the background service…"))
        }
    }
}

// MARK: - Task list

struct TaskCenterView: View {
    @ObservedObject var model: CenterModel

    private var rows: [TaskRow] { model.taskRows }

    var body: some View {
        ZStack {
            WbColor.scrim
                .ignoresSafeArea()
                .onTapGesture { model.closeOverlay() }
            VStack(alignment: .leading, spacing: WbSpace.md) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.text("后台任务", "Background tasks"))
                        .wbFont(WbType.title)
                    Spacer()
                    Button(model.text("关闭", "Close")) { model.closeOverlay() }
                }
                if let reason = model.quitReason {
                    HStack(alignment: .top, spacing: WbSpace.sm) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(WbColor.warning)
                        Text(reason).wbFont(WbType.body)
                    }
                    .padding(WbSpace.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(WbStatus.warning.container, in: RoundedRectangle(cornerRadius: WbRadius.md))
                }
                if let error = model.jobsError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary).textSelection(.enabled)
                }
                if rows.isEmpty {
                    Label(model.text("没有正在运行或最近完成的任务", "No running or recently finished tasks"),
                          systemImage: "checkmark.circle")
                        .foregroundStyle(WbColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, WbSpace.xl)
                } else {
                    ScrollView {
                        LazyVStack(spacing: WbSpace.sm) {
                            ForEach(rows) { row in
                                TaskRowView(model: model, row: row) { model.cancelJob(row.id) }
                            }
                        }
                    }
                    .frame(maxHeight: 380)
                }
                if model.hasMutations {
                    Text(model.text("正在等待当前设备操作完成…", "Waiting for the current device operation to finish…"))
                        .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                }
                Text(model.text("取消任务会停止对应的工作，设备保持原状。", "Cancelling a task stops its work and leaves the device as it was."))
                    .wbFont(WbType.caption).foregroundStyle(WbColor.textTertiary)
            }
            .padding(WbSpace.xl)
            .frame(width: 520)
            .background(WbColor.overlay, in: RoundedRectangle(cornerRadius: WbRadius.lg))
            .overlay(RoundedRectangle(cornerRadius: WbRadius.lg).strokeBorder(WbColor.borderDefault, lineWidth: WbBorder.hairline))
            .wbShadow(WbShadow.popover)
            .tint(WbColor.accent)
        }
    }
}

private struct TaskRowView: View {
    @ObservedObject var model: CenterModel
    let row: TaskRow
    let cancel: () -> Void

    private var tint: Color {
        switch row.tone {
        case .queued: return WbStatus.jobQueued.onContainer
        case .running: return WbStatus.jobRunning.onContainer
        case .done: return WbStatus.jobDone.onContainer
        case .failed: return WbStatus.jobFailed.onContainer
        case .cancelled: return WbStatus.jobCancelled.onContainer
        }
    }
    private var symbol: String {
        switch row.tone {
        case .queued: return "clock"
        case .running: return "arrow.down.circle"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "slash.circle"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: WbSpace.md) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: WbIcon.iconLg)
            VStack(alignment: .leading, spacing: WbSpace.xs) {
                Text(row.title).wbFont(WbType.body.weighted(.semibold)).lineLimit(1).truncationMode(.middle)
                if let progress = row.progress {
                    ProgressView(value: min(max(progress, 0), 1)).tint(tint).controlSize(.small)
                } else if row.tone == .running || row.tone == .queued {
                    ProgressView().tint(tint).controlSize(.small)
                }
                Text(row.detail).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary).lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if row.cancellable {
                Button(action: cancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help(model.text("取消任务", "Cancel task"))
            }
        }
        .padding(WbSpace.md)
        .background(WbColor.raised, in: RoundedRectangle(cornerRadius: WbRadius.md))
        .overlay(RoundedRectangle(cornerRadius: WbRadius.md).strokeBorder(WbColor.borderDefault, lineWidth: WbBorder.hairline))
    }
}

// MARK: - Toast

struct ToastOverlay: View {
    let toast: Toast
    let dismiss: () -> Void

    private var tint: Color { toast.tone == .negative ? WbColor.negative : WbColor.positive }
    private var symbol: String { toast.tone == .negative ? "exclamationmark.triangle.fill" : "checkmark.circle.fill" }

    var body: some View {
        HStack(alignment: .top, spacing: WbSpace.sm) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(toast.text).wbFont(WbType.body).lineLimit(4).multilineTextAlignment(.leading)
        }
        .padding(.horizontal, WbSpace.lg)
        .padding(.vertical, WbSpace.md)
        .background(WbColor.overlay, in: RoundedRectangle(cornerRadius: WbRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: WbRadius.lg).strokeBorder(WbColor.borderDefault, lineWidth: WbBorder.hairline))
        .wbShadow(WbShadow.popover)
        .padding(.bottom, WbSpace.xl)
        .onTapGesture(perform: dismiss)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
