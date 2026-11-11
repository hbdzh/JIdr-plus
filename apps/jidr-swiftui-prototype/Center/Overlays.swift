// SPDX-License-Identifier: GPL-3.0-only
// Center overlays that are not sheets: the task list (jobs + quit guard), the
// toast and the daemon connection status. Slint draws all three in the window
// (shell.slint TasksDialog, app.slint Toast, TitleBar conn pill); the center
// follows the same pattern.
//
// HIG pass: content is flat (no decorative card fills or borders), the task
// dialog uses a system material + standard dialog buttons, and the only
// elevation kept is the popover shadow of the two genuinely floating layers
// (the task dialog and the toast).

import SwiftUI

// MARK: - Connection status

/// Title-bar connection status: icon + label + a standard link button. Shown
/// only when the daemon connection is not online, like Slint's title bar.
struct ConnectionStatusPill: View {
    @ObservedObject var model: CenterModel

    private var tint: Color {
        model.connectionNeedsRetry ? WbColor.negative : WbColor.warning
    }

    var body: some View {
        if model.connection.isOnline {
            EmptyView()
        } else {
            HStack(spacing: WbSpace.sm) {
                if model.connectionNeedsRetry {
                    Image(systemName: WbIcon.warningFill)
                        .font(.system(size: WbIconSize.iconSm, weight: .medium))
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                } else {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                }
                Text(model.connectionLabel)
                    .wbFont(WbType.caption)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                if model.connectionNeedsRetry {
                    Button(model.text("重新连接", "Reconnect")) { model.retryConnection() }
                        .buttonStyle(.link)
                        .wbFont(WbType.caption)
                }
            }
            .help(model.connectionNeedsRetry
                  ? model.text("与后台的连接已断开。点击重新连接。", "The background connection is gone. Click Reconnect.")
                  : model.text("正在重新连接到后台服务…", "Reconnecting to the background service…"))
        }
    }
}

// MARK: - Task list

/// The background-task dialog: a floating layer over the window scrim, so it
/// keeps the popover shadow; its content is a flat list with separators.
struct TaskCenterView: View {
    @ObservedObject var model: CenterModel

    private var rows: [TaskRow] { model.taskRows }

    var body: some View {
        ZStack {
            WbColor.scrim
                .ignoresSafeArea()
                .onTapGesture { model.closeOverlay() }
            VStack(alignment: .leading, spacing: WbSpace.lg) {
                Text(model.text("后台任务", "Background tasks"))
                    .wbFont(WbType.headline)

                if let reason = model.quitReason {
                    Label(reason, systemImage: WbIcon.quitGuard)
                        .wbFont(WbType.body)
                        .foregroundStyle(WbColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = model.jobsError {
                    Label(error, systemImage: WbIcon.warning)
                        .wbFont(WbType.label)
                        .foregroundStyle(WbColor.textSecondary)
                        .textSelection(.enabled)
                }
                if rows.isEmpty {
                    Label(model.text("没有正在运行或最近完成的任务", "No running or recently finished tasks"),
                          systemImage: "checkmark")
                        .foregroundStyle(WbColor.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, WbSpace.xl)
                } else {
                    ScrollView {
                        LazyVStack(spacing: WbSpace.zero) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                                if index > 0 { WbRowDivider() }
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

                Divider()
                HStack(spacing: WbSpace.md) {
                    Text(model.text("取消任务会停止对应的工作，设备保持原状。", "Cancelling a task stops its work and leaves the device as it was."))
                        .wbFont(WbType.caption)
                        .foregroundStyle(WbColor.textTertiary)
                    Spacer(minLength: WbSpace.md)
                    Button(model.text("关闭", "Close")) { model.closeOverlay() }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(WbSpace.xl)
            .frame(width: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: WbRadius.xl, style: .continuous))
            .wbShadow(WbShadow.popover)
            .tint(WbColor.accent)
        }
    }
}

/// One flat task row: status glyph, title, progress and detail; the cancel
/// action is a standard borderless icon button with help + accessibility label.
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
    /// Plain SF Symbols for row status (no circled/self-drawn glyphs).
    private var symbol: String {
        switch row.tone {
        case .queued: return "clock"
        case .running: return "arrow.down"
        case .done: return "checkmark"
        case .failed: return "xmark"
        case .cancelled: return "minus"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: WbSpace.md) {
            Image(systemName: symbol)
                .font(.system(size: WbIconSize.iconSm, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: WbIconSize.iconMd)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WbSpace.xs) {
                Text(row.title).wbFont(WbType.body.weighted(.semibold)).lineLimit(1).truncationMode(.middle)
                if let progress = row.progress {
                    ProgressView(value: min(max(progress, 0), 1)).tint(tint).controlSize(.small)
                } else if row.tone == .running || row.tone == .queued {
                    ProgressView().tint(tint).controlSize(.small)
                }
                Text(row.detail).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                    .lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength: WbSpace.sm)
            if row.cancellable {
                Button(action: cancel) {
                    Image(systemName: WbIcon.close)
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help(model.text("取消任务", "Cancel task"))
                .accessibilityLabel(model.text("取消任务", "Cancel task"))
            }
        }
        .padding(.horizontal, WbSpace.md)
        .padding(.vertical, WbSpace.sm)
    }
}

// MARK: - Toast

/// A floating transient message; keeps its popover shadow and uses a system
/// material instead of a hand-drawn card fill and border.
struct ToastOverlay: View {
    let toast: Toast
    let dismiss: () -> Void

    private var tint: Color { toast.tone == .negative ? WbColor.negative : WbColor.positive }
    /// A plain check / warning triangle; no circled badges.
    private var symbol: String { toast.tone == .negative ? WbIcon.warningFill : "checkmark" }

    var body: some View {
        HStack(alignment: .top, spacing: WbSpace.sm) {
            Image(systemName: symbol)
                .font(.system(size: WbIconSize.iconSm, weight: .medium))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(toast.text).wbFont(WbType.body).lineLimit(4).multilineTextAlignment(.leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(toast.text)
        .padding(.horizontal, WbSpace.lg)
        .padding(.vertical, WbSpace.md)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: WbRadius.lg, style: .continuous))
        .wbShadow(WbShadow.popover)
        .padding(.bottom, WbSpace.xl)
        .onTapGesture(perform: dismiss)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear {
            // Transient feedback would otherwise be missed by VoiceOver.
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                 userInfo: [.announcement: toast.text,
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }
}
