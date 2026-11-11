// SPDX-License-Identifier: GPL-3.0-only
// Connection status, native task-window content and transient toast feedback.

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

/// Supplemental progress in a standard nonmodal window; closing it keeps jobs running.
struct TaskCenterView: View {
    @ObservedObject var model: CenterModel

    private var rows: [TaskRow] { model.taskRows }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: WbIcon.tasks).foregroundStyle(WbColor.textSecondary)
                Text(model.text("后台任务", "Background tasks")).font(.system(size: 14, weight: .semibold))
                Spacer()
                if !rows.isEmpty {
                    Button { model.refreshJobs() } label: { Image(systemName: WbIcon.refresh) }
                        .buttonStyle(.borderless).accessibilityLabel(model.text("刷新任务", "Refresh tasks"))
                }
                PanelCloseButton(label: model.text("关闭", "Close")) { model.taskPanelDidClose() }
            }.padding(.horizontal, 18).frame(height: 50)
            Divider()
            if let reason = model.quitReason {
                Label(reason, systemImage: WbIcon.quitGuard)
                    .font(.system(size: 13)).foregroundStyle(WbColor.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16).background(WbStatus.warning.container)
            }
            if let error = model.jobsError {
                Label(error, systemImage: WbIcon.warning)
                    .font(.system(size: 12)).foregroundStyle(WbColor.negative)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16).textSelection(.enabled)
            }
            if rows.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle").font(.system(size: 26, weight: .light)).accessibilityHidden(true)
                        .foregroundStyle(WbColor.textSecondary)
                    Text(model.text("暂无后台任务", "No background tasks"))
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(WbColor.textPrimary)
                    Text(model.text("下载、安装和设备操作的进度会显示在这里。", "Downloads, installations and device operations appear here."))
                        .font(.system(size: 12)).foregroundStyle(WbColor.textSecondary)
                        .multilineTextAlignment(.center).frame(maxWidth: 340)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
            } else {
                List(rows) { row in TaskRowView(model: model, row: row) { model.cancelJob(row.id) } }
                    .listStyle(.inset).scrollContentBackground(.hidden)
            }
            if model.hasMutations {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.text("正在等待当前设备操作完成…", "Waiting for the current device operation to finish…"))
                        .font(.system(size: 12)).foregroundStyle(WbColor.textSecondary)
                }.padding(16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(LightweightPanelSurface())
        .tint(WbColor.accent)
        .preferredColorScheme(model.colorScheme)
        .environment(\.locale, Locale(identifier: model.language == 0 ? "en" : "zh-Hans"))
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
