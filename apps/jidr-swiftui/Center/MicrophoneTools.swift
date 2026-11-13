// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension CenterModel: DeviceToolClient {}

struct MicrophoneToolsView: View {
    @ObservedObject var model: CenterModel
    @ObservedObject var session: MicrophoneSession
    let id: String
    @State private var supported: Bool?
    @State private var capabilityError = ""
    @State private var stopError = ""
    @State private var stoppingExternal = false

    init(model: CenterModel, id: String) {
        self.model = model; self.id = id
        session = model.microphoneSession(for: id)
    }
    private func t(_ zh: String, _ en: String) -> String { model.text(zh, en) }
    private var device: Device? { model.devices.first { $0.id == id } }
    private var externalJob: JobInfo? {
        model.jobs.first { $0.kind == "audio.inject" && $0.device == id && $0.isActive }
    }
    private var busy: Bool { session.active || externalJob != nil }

    var body: some View {
        DeviceToolPageGroup {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(t("音频文件", "Audio file")).fontWeight(.medium)
                    Spacer()
                    Button(t("选择 WAV…", "Choose WAV…"), action: choose)
                        .disabled(busy).accessibilityIdentifier("microphone-choose")
                }
                Text(session.file?.lastPathComponent ?? t("尚未选择文件", "No file selected"))
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    .help(session.file?.path ?? "")
                Divider()
                Toggle(t("循环播放", "Loop playback"), isOn: $session.loop)
                    .disabled(busy).accessibilityIdentifier("microphone-loop")
                Text(t("支持 8–48 kHz、单声道或双声道 WAV。音频作为 Android 麦克风输入，应用需打开麦克风才能接收。",
                       "Supports mono or stereo WAV at 8–48 kHz. The audio feeds Android's microphone; the app must open its microphone to receive it."))
                    .foregroundStyle(WbColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                Text(t("这是音频文件播放，不会使用 Mac 的实时麦克风。关闭此面板后任务继续，可重新打开停止。",
                       "Plays an audio file. It does not use the Mac's live microphone. Playback continues when this panel closes; reopen it to stop."))
                    .foregroundStyle(WbColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                if device?.launch.audio == false {
                    Label(t("设备声音已关闭，请先在设备设置中开启并重启。", "Device audio is disabled. Enable it in device settings and restart first."), systemImage: WbIcon.info)
                }
                if device?.running != true {
                    Text(t("启动设备后可播放音频文件。", "Start the device to play an audio file."))
                        .foregroundStyle(WbColor.textSecondary)
                }
                if supported == false {
                    Text(t("当前后台不支持音频注入，请更新后台。", "Update the daemon to use microphone injection."))
                }
                if supported == nil && capabilityError.isEmpty { ProgressView().controlSize(.small) }
                if !capabilityError.isEmpty {
                    Text(capabilityError).foregroundStyle(WbColor.negative)
                    Button(t("重试", "Retry"), action: loadCapabilities)
                }
                if busy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(session.stopping || stoppingExternal ? t("正在停止…", "Stopping…") : t("正在注入音频…", "Feeding microphone…"))
                    }
                    if let progress = session.progress { ProgressView(value: progress) }
                } else if session.finished && session.error == nil {
                    Text(t("音频注入已结束。", "Microphone playback ended."))
                }
                if let error = session.error { Text(OperationMessages.error(error, language: model.language)).foregroundStyle(WbColor.negative) }
                if !stopError.isEmpty { Text(stopError).foregroundStyle(WbColor.negative) }
            }
        } footer: {
            HStack {
                Button(t("开始播放", "Start playback")) {
                    stopError = ""
                    session.start(device: id, client: model)
                }
                .disabled(busy || session.file == nil || supported != true || device?.running != true || device?.launch.audio == false)
                .accessibilityIdentifier("microphone-start")
                Button(t("停止", "Stop"), action: stop)
                    .disabled(!busy || session.stopping || stoppingExternal)
                    .accessibilityIdentifier("microphone-stop")
            }
        }
        .onAppear { loadCapabilities(); model.refreshJobs() }
        .onChange(of: model.connection.isOnline) { online in
            if online { loadCapabilities(); model.refreshJobs() }
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            // The center stops polling when it knows of no active jobs. While
            // this page is open, also discover new injections from CLI/MCP.
            if model.connection.isOnline && !model.hasActiveJobs { model.refreshJobs() }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType.wav]
        panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        if panel.runModal() == .OK { session.file = panel.url }
    }
    private func loadCapabilities() {
        capabilityError = ""; supported = nil
        model.call("commands.list") { result in
            switch result {
            case .success(let value):
                let ids = RootDevToolsView.commandIDs(value)
                supported = ids.contains("audio.inject") && ids.contains("audio.stop")
            case .failure(let error): capabilityError = OperationMessages.error(error.localizedDescription, language: model.language)
            }
        }
    }
    private func stop() {
        stopError = ""
        if session.active { session.stop(client: model); return }
        // Also stop an injection started by CLI/MCP or before a reconnect.
        stoppingExternal = true
        let job = externalJob?.id
        model.call("audio.stop", ["device": id]) { result in
            if case .success(let value) = result,
               (value as? [String: Any])?["stopped"] as? Bool == false, let job {
                // A CLI/MCP job may also still be reading its input file.
                model.call("jobs.cancel", ["job": job]) { reply in finishStop(reply) }
                return
            }
            finishStop(result)
        }
    }
    private func finishStop(_ result: Result<Any, Error>) {
        stoppingExternal = false
        if case .failure(let error) = result { stopError = OperationMessages.error(error.localizedDescription, language: model.language) }
        model.refreshJobs()
    }
}
