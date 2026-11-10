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
            HStack(spacing: 6) {
                if model.connectionNeedsRetry {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption2)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(model.connectionLabel).font(.caption).lineLimit(1)
                if model.connectionNeedsRetry {
                    Button(model.text("重新连接", "Reconnect")) { model.retryConnection() }
                        .buttonStyle(.borderless)
                        .font(.caption.weight(.semibold))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(model.connectionNeedsRetry ? Color.red : Color.orange)
            .background((model.connectionNeedsRetry ? Color.red : Color.orange).opacity(0.12), in: Capsule())
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
            Color.black.opacity(0.32)
                .ignoresSafeArea()
                .onTapGesture { model.closeOverlay() }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.text("后台任务", "Background tasks"))
                        .font(.title3.weight(.semibold))
                    Spacer()
                    Button(model.text("关闭", "Close")) { model.closeOverlay() }
                }
                if let reason = model.quitReason {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                        Text(reason).font(.callout)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }
                if let error = model.jobsError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if rows.isEmpty {
                    Label(model.text("没有正在运行或最近完成的任务", "No running or recently finished tasks"),
                          systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 26)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(rows) { row in
                                TaskRowView(model: model, row: row) { model.cancelJob(row.id) }
                            }
                        }
                    }
                    .frame(maxHeight: 380)
                }
                if model.hasMutations {
                    Text(model.text("正在等待当前设备操作完成…", "Waiting for the current device operation to finish…"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(model.text("取消任务会停止对应的工作，设备保持原状。", "Cancelling a task stops its work and leaves the device as it was."))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(20)
            .frame(width: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.secondary.opacity(0.25)))
            .shadow(color: .black.opacity(0.25), radius: 22, y: 10)
        }
    }
}

private struct TaskRowView: View {
    @ObservedObject var model: CenterModel
    let row: TaskRow
    let cancel: () -> Void

    private var tint: Color {
        switch row.tone {
        case .queued: return .secondary
        case .running: return .accentColor
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .secondary
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
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(row.title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                if let progress = row.progress {
                    ProgressView(value: min(max(progress, 0), 1)).tint(tint).controlSize(.small)
                } else if row.tone == .running || row.tone == .queued {
                    ProgressView().tint(tint).controlSize(.small)
                }
                Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
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
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.18)))
    }
}

// MARK: - Toast

struct ToastOverlay: View {
    let toast: Toast
    let dismiss: () -> Void

    private var tint: Color { toast.tone == .negative ? .red : .green }
    private var symbol: String { toast.tone == .negative ? "exclamationmark.triangle.fill" : "checkmark.circle.fill" }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(toast.text).font(.callout).lineLimit(4).multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.45)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.bottom, 18)
        .onTapGesture(perform: dismiss)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
