// SPDX-License-Identifier: GPL-3.0-only
// The "Root" tab of the advanced-tools window: root status + Verify/Revert,
// the opt-in auto-grant toggle (D22), Magisk modules, build props (Phase 9f)
// and system CA certificates. Slint reference: crates/jidr-ui/src/root/mod.rs,
// ui/root/root.slint (RootDevTools), props/props.slint and cacerts/cacerts.slint.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// `root.status` (crates/jidr-root/src/lib.rs:status).
struct RootStatus: Decodable {
    struct Root: Decodable {
        let mode: String
        let health: String?
        let magisk_version: String?
        let verified_at: String?
        let auto_grant_all: Bool?
    }
    let root: Root
    let adb_root_allowed: Bool?
    let play_integrity: String?
}

/// One `root.cacert.list` row (cacerts/mod.rs:rows_of).
struct CertRow: Decodable, Identifiable {
    var id: String { file }
    let file: String
    let subject: String?
    let trusted: Bool?
}

struct CertList: Decodable { let certs: [CertRow] }

struct RootDevToolsView: View {
    @ObservedObject var model: CenterModel
    let id: String
    let running: Bool

    @State private var status: RootStatus?
    @State private var capabilities: Set<String> = []
    @State private var capabilitiesLoaded = false
    @State private var statusError = ""
    @State private var statusLoading = true

    @State private var autoGrant = false
    @State private var autoGrantSaving = false

    @State private var props: [String: String] = [:]
    @State private var propsLoaded = false
    @State private var propsEditing = false
    @State private var propsDraft: [String: String] = [:]
    @State private var propsSaving = false
    @State private var propsPendingRestart = false
    @State private var propsError = ""

    @State private var certs: [CertRow] = []
    @State private var certsError = ""
    @State private var certsBusy = false

    @State private var working = false
    @State private var statusText = ""
    @State private var errorText = ""
    @State private var pending: PendingRootAction?

    /// The six build props in form order (props/mod.rs:FIELDS).
    private static let propFields = ["model", "brand", "manufacturer", "device", "fingerprint", "security_patch"]

    struct PendingRootAction: Identifiable {
        enum Kind {
            case installModule(URL)
            case installCert(URL)
            case removeCert(String)
            case saveProps([String: String], reset: Bool)
            case revert
        }
        let id = UUID()
        let kind: Kind
        let title: String
        let detail: String
    }

    private func t(_ chinese: String, _ english: String) -> String { model.text(chinese, english) }
    private var device: Device? { model.devices.first(where: { $0.id == id }) }
    private var fullRoot: Bool { (status?.root.mode ?? device?.root.mode) == "magisk" }
    private var playStore: Bool { device?.image.tag.contains("playstore") ?? false }
    private var canAutoGrant: Bool { capabilities.contains("root.auto_grant") }
    private var canProps: Bool { capabilities.contains("device.props.get") }
    private var canCerts: Bool { capabilities.contains("root.cacert.install") }

    var body: some View {
        VStack(alignment: .leading, spacing: WbSpace.lg) {
            statusCard
            if !fullRoot {
                Label(t("以下功能需要完整 Root（Magisk）。请在设备详情中设置完整 Root。",
                        "These tools require Full root (Magisk). Set up Full root in the device details."),
                      systemImage: WbIcon.rootTab)
                    .wbFont(WbType.body).foregroundStyle(WbColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if fullRoot {
                    autoGrantBlock
                    modulesBlock
                    propsBlock
                    if canCerts {
                        certsBlock
                    } else if capabilitiesLoaded {
                        HStack(alignment: .top, spacing: WbSpace.sm) {
                            Image(systemName: WbIcon.lock).foregroundStyle(WbColor.textSecondary)
                            Text(t("需要更新 Jidr 后台才支持系统 CA 证书。", "Needs a newer Jidr daemon to manage system CA certificates."))
                                .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                        }.padding(WbSpace.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(WbColor.raised, in: RoundedRectangle(cornerRadius: WbRadius.md))
                    }
                }
            }.disabled(!fullRoot || !running || working)
            if !statusText.isEmpty {
                Label(statusText, systemImage: WbIcon.info).wbFont(WbType.caption)
                    .foregroundStyle(WbColor.textSecondary).textSelection(.enabled)
            }
            if !errorText.isEmpty {
                Label(errorText, systemImage: WbIcon.warning).wbFont(WbType.caption)
                    .foregroundStyle(WbColor.negative).textSelection(.enabled)
            }
        }
        .onAppear(perform: load)
        .alert(item: $pending) { action in confirmAlert(action) }
    }

    // MARK: status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: WbSpace.sm) {
            HStack {
                Text(t("Root 状态", "Root status")).wbFont(WbType.title)
                if playStore, fullRoot {
                    Text(t("Beta · Play 商店镜像", "Beta · Play Store image"))
                        .wbFont(WbType.caption.weighted(.medium)).foregroundStyle(WbColor.warning)
                        .padding(.horizontal, WbSpace.sm).padding(.vertical, WbSpace.xxs)
                        .background(WbStatus.warning.container, in: Capsule())
                }
                Spacer()
                if statusLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button(t("刷新", "Refresh"), systemImage: WbIcon.refresh) { load() }.disabled(working)
                }
            }
            if !statusError.isEmpty {
                Label(statusError, systemImage: WbIcon.warning).wbFont(WbType.caption).foregroundStyle(WbColor.negative)
            }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow {
                    Text(t("模式", "Mode")).foregroundStyle(WbColor.textSecondary)
                    Text(modeLabel).fontWeight(.medium)
                    Text(t("健康", "Health")).foregroundStyle(WbColor.textSecondary)
                    Text(healthLabel)
                }
                GridRow {
                    Text("Magisk").foregroundStyle(WbColor.textSecondary)
                    Text(status?.root.magisk_version ?? "—")
                    Text(t("上次验证", "Verified")).foregroundStyle(WbColor.textSecondary)
                    Text(verifiedLabel)
                }
            }.wbFont(WbType.body)
            if fullRoot {
                HStack(spacing: WbSpace.sm) {
                    Button(t("再次验证", "Verify again")) { verify() }
                        .disabled(!running || working)
                    Button(t("回退到无 Root…", "Revert to unrooted…"), role: .destructive) {
                        pending = PendingRootAction(kind: .revert,
                                                    title: t("回退到无 Root？", "Revert to unrooted?"),
                                                    detail: t("将移除 Magisk 并冷启动设备，可能需要一些时间。游戏数据会保留。",
                                                              "Magisk is removed and the device cold-boots, which can take a while. Your game data is kept."))
                    }.disabled(working)
                }
            }
            if playStore, fullRoot, let notice = status?.play_integrity, !notice.isEmpty {
                Label(t("已 Root 的模拟器无法通过 Play Integrity。银行应用和部分 Play 商店游戏会拒绝运行。",
                        "Rooted emulators can't pass Play Integrity. Banking apps and some Play Store games will refuse to run."),
                      systemImage: WbIcon.integrity).wbFont(WbType.caption).foregroundStyle(WbColor.warning)
            }
        }.padding(WbSpace.md)
            .background(WbColor.raised, in: RoundedRectangle(cornerRadius: WbRadius.md))
    }

    private var modeLabel: String {
        switch status?.root.mode ?? device?.root.mode {
        case "magisk": return t("完整 Root", "Full root")
        case "adb": return "Shell root"
        default: return t("无 Root", "Not rooted")
        }
    }

    private var healthLabel: String {
        switch status?.root.health ?? device?.root.health {
        case "ok": return t("正常", "OK")
        case "failed": return t("失败", "Failed")
        case "unverified", nil: return t("未验证", "Unverified")
        default: return status?.root.health ?? "—"
        }
    }

    private var verifiedLabel: String {
        guard let raw = status?.root.verified_at, let date = Snapshots.created(raw) else {
            return t("尚未验证", "Not verified yet")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: model.language == 0 ? "en_US_POSIX" : "zh_CN")
        formatter.dateFormat = model.language == 0 ? "MMM d, HH:mm" : "M月d日 HH:mm"
        return formatter.string(from: date)
    }

    // MARK: auto-grant (D22)

    private var autoGrantBlock: some View {
        VStack(alignment: .leading, spacing: WbSpace.sm) {
            Toggle(t("自动授权所有应用（无需询问）", "Auto-grant root to all apps"), isOn: Binding(
                get: { autoGrant },
                set: { value in setAutoGrant(value) }))
                .disabled(!canAutoGrant || autoGrantSaving || working)
            Text(autoGrantHint).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var autoGrantHint: String {
        if !canAutoGrant { return t("需要更新 Jidr 后台才支持自动授权。", "Needs a newer Jidr daemon.") }
        if autoGrant {
            return t("开启：所有请求 Root 的应用都会直接获得权限，不再弹出询问。", "On: every app that asks gets root without a prompt.")
        }
        return t("关闭：应用请求 Root 时会弹出询问。adb shell 始终已授权。", "Off: apps ask and you tap Grant. adb shell is always granted.")
    }

    private func setAutoGrant(_ value: Bool) {
        guard canAutoGrant else { return }
        autoGrant = value
        autoGrantSaving = true
        model.call("root.auto_grant", ["device": id, "enabled": value]) { result in
            autoGrantSaving = false
            switch result {
            case .success:
                statusText = value
                    ? t("已开启自动授权。", "Apps now get root without asking.")
                    : t("已关闭自动授权。", "Apps ask before they get root.")
            case .failure(let error):
                autoGrant = !value
                errorText = OperationMessages.error(error.localizedDescription, language: model.language)
            }
        }
    }

    // MARK: modules

    private var modulesBlock: some View {
        VStack(alignment: .leading, spacing: WbSpace.sm) {
            Text(t("Magisk 模块", "Magisk modules")).wbFont(WbType.title)
            HStack(spacing: WbSpace.sm) {
                Button(t("安装模块…", "Install module…")) { choose(["zip"]) { pending = .init(kind: .installModule($0), title: t("安装模块？", "Install module?"), detail: t("将安装 \($0.lastPathComponent) 并重启设备。请先保存游戏进度。", "Install \($0.lastPathComponent) and reboot the device. Save your game first.")) } }
                    .disabled(!running || working)
                Button(t("在 Magisk 中管理模块", "Manage modules in Magisk")) {
                    model.call("app.launch", ["device": id, "package": "com.topjohnwu.magisk"]) { result in
                        if case .failure(let error) = result {
                            errorText = OperationMessages.error(error.localizedDescription, language: model.language)
                        }
                    }
                    model.openGame(id)
                }.disabled(!running || working)
            }
            Text(t("卸载模块请在 Magisk 应用中操作，然后重启设备。", "Remove modules in the Magisk app, then restart the device."))
                .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
        }
    }

    // MARK: build props (Phase 9f)

    private var propsBlock: some View {
        VStack(alignment: .leading, spacing: WbSpace.sm) {
            HStack {
                Text(t("设备标识（构建属性）", "Build identity")).wbFont(WbType.title)
                Spacer()
                if canProps, !propsEditing {
                    Button(t("编辑…", "Edit…"), systemImage: WbIcon.advancedTools) {
                        propsDraft = props
                        propsEditing = true
                        propsError = ""
                    }.disabled(working)
                }
            }
            if !capabilitiesLoaded {
                HStack { ProgressView().controlSize(.small); Text(t("正在检查后台能力…", "Checking daemon capabilities…")).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary) }
            } else if !canProps {
                Text(t("需要更新 Jidr 后台才支持修改构建属性。", "Needs a newer Jidr daemon to edit build props."))
                    .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
            } else if !propsLoaded && props.isEmpty {
                HStack { ProgressView().controlSize(.small); Text(t("正在读取属性…", "Loading properties…")).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary) }
            } else if !propsEditing {
                Text(propsSummary).wbFont(WbType.body).lineLimit(2).textSelection(.enabled)
                if propsPendingRestart {
                    HStack(spacing: WbSpace.sm) {
                        Label(t("已保存，下次启动（冷启动）时生效。", "Saved; applies on the next start (a cold boot)."),
                              systemImage: WbIcon.clock).wbFont(WbType.caption).foregroundStyle(WbColor.warning)
                        Button(t("立即重启", "Restart now")) { model.restart(id) }
                            .disabled(!running || working)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: WbSpace.sm) {
                    ForEach(Self.propFields, id: \.self) { field in
                        HStack {
                            Text(propLabel(field)).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary).frame(width: 90, alignment: .leading)
                            TextField(propPlaceholder(field), text: Binding(
                                get: { propsDraft[field] ?? "" },
                                set: { propsDraft[field] = $0 }))
                                .textFieldStyle(.roundedBorder)
                                .disabled(propsSaving)
                        }
                    }
                    Text(t("留空则使用镜像自带的值。更改在下次启动时生效（冷启动）。",
                           "Empty fields keep the image's value. Changes apply on the next start, which is a cold boot."))
                        .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !propsError.isEmpty {
                        Text(propsError).wbFont(WbType.caption).foregroundStyle(WbColor.negative)
                    }
                    HStack(spacing: WbSpace.sm) {
                        Button(propsSaving ? t("正在保存…", "Saving…") : t("保存", "Save")) {
                            pending = .init(kind: .saveProps(trimmedProps(propsDraft), reset: false),
                                            title: t("保存设备标识？", "Save build identity?"),
                                            detail: t("之后的下一次启动会执行冷启动。请先保存游戏进度。",
                                                      "The next start will be a cold boot. Save your game first."))
                        }.buttonStyle(.borderedProminent).disabled(propsSaving)
                        Button(t("取消", "Cancel")) { propsEditing = false; propsError = "" }.disabled(propsSaving)
                        Spacer()
                        if !props.isEmpty {
                            Button(t("恢复为镜像默认值", "Reset to stock")) {
                                pending = .init(kind: .saveProps([:], reset: true),
                                                title: t("恢复镜像默认值？", "Reset to stock values?"),
                                                detail: t("移除 Jidr 保存的构建属性；下一次启动会冷启动。", "Removes the build props Jidr saved; the next start is a cold boot."))
                            }.disabled(propsSaving)
                        }
                    }
                }
            }
        }.padding(WbSpace.md)
            .background(WbColor.raised, in: RoundedRectangle(cornerRadius: WbRadius.md))
    }

    private var propsSummary: String {
        let parts = Self.propFields.filter { $0 != "security_patch" }.compactMap { field -> String? in
            let value = (props[field] ?? "").trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        let patch = (props["security_patch"] ?? "").trimmingCharacters(in: .whitespaces)
        if parts.isEmpty && patch.isEmpty { return t("镜像默认值", "Stock values") }
        return parts.joined(separator: " · ") + (patch.isEmpty ? "" : " · \(t("补丁", "patch")) \(patch)")
    }

    private func propLabel(_ field: String) -> String {
        switch field {
        case "model": return t("型号", "Model")
        case "brand": return t("品牌", "Brand")
        case "manufacturer": return t("制造商", "Manufacturer")
        case "device": return t("设备代号", "Device")
        case "fingerprint": return t("指纹", "Fingerprint")
        default: return t("安全补丁", "Security patch")
        }
    }

    private func propPlaceholder(_ field: String) -> String {
        field == "security_patch" ? "YYYY-MM-DD" : t("镜像默认", "Stock")
    }

    private func trimmedProps(_ values: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out[key] = trimmed }
        }
        return out
    }

    // MARK: CA certificates

    private var certsBlock: some View {
        VStack(alignment: .leading, spacing: WbSpace.sm) {
            HStack {
                Text(t("系统 CA 证书", "System CA certificates")).wbFont(WbType.title)
                Spacer()
                Button(t("添加…", "Add…")) { choose(["pem", "crt", "cer", "der"]) { url in
                    pending = .init(kind: .installCert(url),
                                    title: t("信任此证书？", "Trust this certificate?"),
                                    detail: t("将信任 \(url.lastPathComponent) 并重启设备。请先保存游戏进度。",
                                              "Trust \(url.lastPathComponent) and reboot the device. Save your game first."))
                } }.disabled(!running || working || certsBusy)
                Button(t("验证", "Verify")) { verifyCerts() }.disabled(!running || working || certsBusy || certs.isEmpty)
            }
            if !certs.isEmpty {
                ForEach(certs) { cert in
                    HStack(spacing: WbSpace.sm) {
                        VStack(alignment: .leading, spacing: WbSpace.xxs) {
                            Text(certSubject(cert)).wbFont(WbType.body).lineLimit(1)
                            Text(cert.file).wbFont(WbType.code).foregroundStyle(WbColor.textSecondary)
                        }
                        Spacer()
                        Text(cert.trusted == false ? t("重启后生效", "After restart") : t("已信任", "Trusted"))
                            .wbFont(WbType.caption.weighted(.medium))
                            .foregroundStyle(cert.trusted == false ? WbStatus.warning.onContainer : WbStatus.positive.onContainer)
                            .padding(.horizontal, WbSpace.sm).padding(.vertical, WbSpace.xxs)
                            .background(cert.trusted == false ? WbStatus.warning.container : WbStatus.positive.container, in: Capsule())
                        Button(t("移除", "Remove")) {
                            pending = .init(kind: .removeCert(cert.file),
                                            title: t("移除证书？", "Remove certificate?"),
                                            detail: t("将移除 \(cert.file) 并重启设备。请先保存游戏进度。",
                                                      "Remove \(cert.file) and reboot the device. Save your game first."))
                        }.disabled(!running || working || certsBusy)
                    }
                    .padding(.vertical, WbSpace.xxs)
                }
            }
            Text(certsHint).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if certsBusy {
                HStack(spacing: WbSpace.sm) {
                    ProgressView().controlSize(.small)
                    Text(statusText.isEmpty ? t("正在处理…", "Working…") : statusText).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                }
            }
            if !certsError.isEmpty {
                Text(certsError).wbFont(WbType.caption).foregroundStyle(WbColor.negative)
            }
        }.padding(WbSpace.md)
            .background(WbColor.raised, in: RoundedRectangle(cornerRadius: WbRadius.md))
    }

    private func certSubject(_ cert: CertRow) -> String {
        if let subject = cert.subject, !subject.isEmpty { return subject }
        return cert.file
    }

    private var certsHint: String {
        if !running { return t("启动设备后才能添加或移除 CA 证书。", "Start the device to add or remove CA certificates.") }
        if certs.isEmpty {
            return t("把 Burp 或 mitmproxy 的 CA 证书信任为系统证书。添加或移除会重启设备。",
                     "Trust Burp's or mitmproxy's CA as a system certificate. Adding or removing one restarts the device.")
        }
        return t("应用会把这些证书当作系统证书信任。添加或移除会重启设备。",
                 "Apps trust these as system certificates. Adding or removing one restarts the device.")
    }

    // MARK: actions

    private func load() {
        statusLoading = true
        model.call("root.status", ["device": id]) { result in
            statusLoading = false
            switch result {
            case .success(let value):
                if let decoded = try? model.decode(value, as: RootStatus.self) {
                    status = decoded
                    autoGrant = decoded.root.auto_grant_all ?? false
                    statusError = ""
                    if running, decoded.root.mode == "magisk" { loadCerts() }
                } else {
                    statusError = t("Root 状态格式无效。", "Invalid root status response.")
                }
            case .failure(let error):
                statusError = OperationMessages.error(error.localizedDescription, language: model.language)
            }
        }
        model.call("commands.list") { result in
            capabilitiesLoaded = true
            if case .success(let value) = result {
                capabilities = Self.commandIDs(value)
                if canCerts { loadCerts() }
            }
        }
        model.call("device.props.get", ["device": id]) { result in
            switch result {
            case .success(let value):
                if let object = value as? [String: Any], let raw = object["props"] as? [String: Any] {
                    props = raw.reduce(into: [:]) { out, item in
                        if let text = item.value as? String { out[item.key] = text }
                    }
                }
                propsLoaded = true
            case .failure:
                propsLoaded = true
            }
        }
    }

    /// `commands.list` is `["commands": [{"id": …}]]` on this daemon and a
    /// bare array on newer ones (root/mod.rs:117-133).
    static func commandIDs(_ value: Any) -> Set<String> {
        let list = (value as? [String: Any])?["commands"] ?? value
        guard let entries = list as? [[String: Any]] else { return [] }
        return Set(entries.compactMap { $0["id"] as? String })
    }

    private func loadCerts() {
        guard canCerts else { return }
        model.call("root.cacert.list", ["device": id]) { result in
            switch result {
            case .success(let value):
                if let list = try? model.decode(value, as: CertList.self) {
                    certs = list.certs
                    certsError = ""
                }
            case .failure(let error):
                certsError = OperationMessages.error(error.localizedDescription, language: model.language)
            }
        }
    }

    private func verify() {
        guard !working else { return }
        working = true
        statusText = t("正在验证 Root…", "Verifying root…")
        model.call("root.verify", ["device": id]) { result in
            working = false
            switch result {
            case .success:
                statusText = t("Root 验证通过。", "Root verified.")
                model.refresh()
                load()
            case .failure(let error):
                statusText = ""
                errorText = OperationMessages.error(error.localizedDescription, language: model.language)
            }
        }
    }

    private func verifyCerts() {
        guard !certsBusy else { return }
        certsBusy = true
        statusText = t("正在验证证书…", "Verifying certificates…")
        model.call("root.cacert.verify", ["device": id]) { result in
            certsBusy = false
            switch result {
            case .success:
                statusText = t("证书已位于系统证书库中。", "The certificates are in the system store.")
                loadCerts()
            case .failure(let error):
                statusText = ""
                certsError = OperationMessages.error(error.localizedDescription, language: model.language)
            }
        }
    }

    private func confirmAlert(_ action: PendingRootAction) -> Alert {
        Alert(
            title: Text(action.title),
            message: Text(action.detail),
            primaryButton: .destructive(Text(t("继续", "Continue"))) { perform(action) },
            secondaryButton: .cancel(Text(t("取消", "Cancel"))))
    }

    private func perform(_ action: PendingRootAction) {
        switch action.kind {
        case .installModule(let url):
            run("root.module.install", ["device": id, "path": url.path], restart: true)
        case .installCert(let url):
            run("root.cacert.install", ["device": id, "path": url.path], restart: true) { loadCerts() }
        case .removeCert(let file):
            run("root.cacert.remove", ["device": id, "cert": file], restart: true) { loadCerts() }
        case .revert:
            run("root.set", ["device": id, "mode": "none"]) { statusText = ""; load() }
        case .saveProps(let values, let reset):
            propsSaving = true
            propsError = ""
            model.call("device.props.set", ["device": id, "props": values]) { result in
                propsSaving = false
                switch result {
                case .success:
                    props = values
                    propsEditing = false
                    propsPendingRestart = running
                    statusText = reset
                        ? t("已恢复镜像默认值。", "Restored the stock values.")
                        : t("设备标识已保存。", "Build identity saved.")
                    if propsPendingRestart {
                        statusText += t("重启后生效。", " Restart to apply it.")
                    }
                case .failure(let error):
                    propsError = OperationMessages.error(error.localizedDescription, language: model.language)
                }
            }
        }
    }

    private func run(_ method: String, _ params: [String: Any], restart: Bool = false, then: (() -> Void)? = nil) {
        guard !working else { return }
        working = true
        statusText = t("正在处理…", "Working…")
        errorText = ""
        var args = params
        args["device"] = id
        model.call(method, args, onProgress: { message, _, _ in
            if !message.isEmpty {
                statusText = OperationMessages.progress(message, language: model.language)
            }
        }) { result in
            working = false
            switch result {
            case .success:
                statusText = t("操作完成。", "Completed.")
                model.refresh()
                load()
                then?()
                if restart { model.reconnectAfterRestart(id) }
            case .failure(let error):
                statusText = ""
                errorText = OperationMessages.error(error.localizedDescription, language: model.language)
            }
        }
    }

    private func choose(_ types: [String], done: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        done(url)
    }
}
