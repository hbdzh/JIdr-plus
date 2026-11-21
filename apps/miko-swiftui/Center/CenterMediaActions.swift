// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers

extension CenterModel {
    func setPreference(_ field:String, _ value:Int) {
        call("center.prefs.set",[field:value]) { [weak self] result in
            switch result {
            case .success:
                if field == "language" { self?.language = value; self?.players.values.forEach { $0.transport.language = value } }
                if field == "appearance" { self?.appearance = value }
            case .failure(let error): self?.showError(self?.readable(error) ?? error.localizedDescription)
            }
        }
    }
    func setRecordAudio(_ enabled: Bool) {
        call("center.prefs.set", ["record_audio": enabled]) { [weak self] result in
            switch result {
            case .success:
                self?.recordAudio = enabled
                self?.players.values.forEach { $0.transport.recordAudio = enabled }
            case .failure(let error):
                self?.showError(self?.readable(error) ?? error.localizedDescription)
            }
        }
    }
    func chooseFile(device:String, apk:Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if apk, let type = UTType(filenameExtension:"apk") { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        operation(apk ? "file.install" : "file.push",id:device,params:apk ? ["apk":url.path,"replace":true] : ["local":url.path])
    }
    func screenshot(device:String) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = text("miko 截图.png", "miko screenshot.png")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        operation("media.screenshot",id:device,params:["path":url.path])
    }
    func openScreenshotFolder() {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/miko",isDirectory:true)
        do {
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            if !NSWorkspace.shared.open(folder) { showError(text("无法打开截图目录。", "Cannot open the screenshots folder.")) }
        } catch { showError(error) }
    }
    func toggleRecording(device:String) {
        if recording.contains(device) {
            call("media.record_stop",["device":device]) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success: self.showToast(self.text("正在保存录屏…", "Saving recording…"))
                case .failure(let error): self.showError(self.readable(error))
                }
            }
            return
        }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]; panel.nameFieldStringValue = text("miko 录屏.mp4", "miko recording.mp4")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !FileManager.default.fileExists(atPath:url.path) else { showError(text("录屏文件已存在，请选择新文件名。", "The recording file already exists. Choose a new name.")); return }
        let includeAudio = recordAudio
        recording.insert(device); showToast(text("正在启动录屏…", "Starting recording…"))
        call("media.record",["device":device,"path":url.path,"audio":includeAudio]) { [weak self] result in
            guard let self else { return }; self.recording.remove(device)
            switch result {
            case .success(let value):
                if includeAudio, let result = value as? [String: Any], result["audio"] as? Bool == false {
                    self.showToast(self.text("录屏已保存，但设备音频不可用。", "Recording saved, but device audio was unavailable."))
                } else if includeAudio, let result = value as? [String: Any], result["audio_received"] as? Bool == false {
                    self.showToast(self.text("录屏已保存，但未收到设备音频。", "Recording saved, but no device audio was received."))
                } else {
                    self.showToast(self.text("录屏已保存", "Recording saved"))
                }
            case .failure(let error): self.showError(self.readable(error))
            }
        }
    }
    func launch(_ app:AndroidApp, device:String) {
        openGame(device)
        call("app.launch", ["device":device,"package":app.package]) { [weak self] result in
            if case .failure(let error) = result { self?.showError(self?.readable(error) ?? error.localizedDescription) }
        }
    }
}
