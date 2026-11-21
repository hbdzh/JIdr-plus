// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import SwiftUI
import Foundation
import UniformTypeIdentifiers

struct HardwareProfile: Decodable, Identifiable {
    let id: String; let name: String
    let ram_mb: Int; let cpus: Int; let data_mb: Int; let audio: Bool
    let width: Int?; let height: Int?; let form_factor: String?
}
struct AvailableImage: Decodable, Identifiable {
    let api: Int; let tag: String; let abi: String; let installed_in: String?
    var id: String { "\(api):\(tag):\(abi)" }
    var package: String { "system-images;android-\(api);\(tag);\(abi)" }
}
struct OnboardingCardMaterial: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let dark = colorScheme == .dark
        content.foregroundStyle(WbColor.textPrimary)
            // The window supplies the blur; the translucent tint preserves
            // its color instead of adding an opaque material on top.
            .background {
                shape.fill(Color.white.opacity(dark ? 0.08 : 0.36))
                    .shadow(color: .black.opacity(dark ? 0.10 : 0.08), radius: 12, y: 5)
                    .allowsHitTesting(false)
            }
            .overlay(shape.strokeBorder(dark ? Color.white.opacity(0.16) : Color.black.opacity(0.12)).allowsHitTesting(false))
    }
}

struct CustomResolutionView: View {
    let language: Int
    let onConfirm: (DeviceResolution) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var width: String
    @State private var height: String

    init(language: Int, initialWidth: Int, initialHeight: Int, onConfirm: @escaping (DeviceResolution) -> Void) {
        self.language = language
        self.onConfirm = onConfirm
        _width = State(initialValue: String(initialWidth))
        _height = State(initialValue: String(initialHeight))
    }

    private func text(_ zh: String, _ en: String) -> String { language == 0 ? en : zh }
    private var resolution: DeviceResolution? { DeviceResolution(width: width, height: height) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text(text("自定义分辨率", "Custom resolution"))
                    .font(.system(size: 20, weight: .semibold))
                Text(text("设置设备屏幕的宽度和高度。", "Set the width and height of the device screen."))
                    .font(.system(size: 12)).foregroundStyle(WbColor.textSecondary)
            }
            HStack(alignment: .top, spacing: 12) {
                resolutionField(text("宽度 (px)", "Width (px)"), value: $width)
                resolutionField(text("高度 (px)", "Height (px)"), value: $height)
            }
            Text(resolution == nil
                 ? text("宽度和高度须为 240–4096 之间的整数。", "Width and height must be whole numbers from 240 to 4096.")
                 : text("宽度和高度范围：240–4096 像素。", "Width and height: 240–4096 pixels."))
                .font(.system(size: 11))
                .foregroundStyle(resolution == nil ? WbColor.negative : WbColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(text("取消", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(text("确认", "Confirm")) {
                    guard let resolution else { return }
                    onConfirm(resolution)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(resolution == nil)
            }
        }
        .padding(24).frame(width: 420)
        .background(WbColor.raised)
    }

    private func resolutionField(_ label: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.system(size: 12, weight: .medium))
            TextField(label, text: value).labelsHidden().textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A compact checkbox matching the onboarding cards while keeping toggle accessibility.
struct OnboardingLicenseToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(configuration.isOn ? WbColor.accentText : Color.clear)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(configuration.isOn ? WbColor.accentText : WbColor.textSecondary.opacity(0.55), lineWidth: 1.3)
                    if configuration.isOn {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    }
                }.frame(width: 17, height: 17)
                configuration.label
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox)
        }
    }
}

struct EnvironmentLicensesView: View {
    let language: Int
    let licenses: [PendingLicense]?
    let loading: Bool
    let error: String
    let canAgree: Bool
    let retry: () -> Void
    let onAgree: () -> Bool
    @Environment(\.dismiss) private var dismiss
    private func t(_ zh: String, _ en: String) -> String { language == 1 ? zh : en }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(t("Android SDK 许可说明", "Android SDK licence details"))
                    .font(.system(size: 18, weight: .semibold))
                Text(t("以下是所选组件实际需要确认的许可。", "These licences apply to the selected components."))
                    .font(.system(size: 12)).foregroundStyle(WbColor.textSecondary)
            }.padding(22)
            Divider()
            Group {
                if loading {
                    ProgressView(t("正在读取许可…", "Loading licences…")).controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !error.isEmpty {
                    VStack(spacing: 12) {
                        Text(error).foregroundStyle(WbColor.negative).textSelection(.enabled)
                        Button(t("重试", "Retry"), action: retry)
                            .buttonStyle(WbPillButtonStyle())
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let licenses, licenses.isEmpty {
                    Text(t("所选组件没有关联的许可文本。", "No licence text is associated with the selected components."))
                        .foregroundStyle(WbColor.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let licenses {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(licenses) { license in
                                HStack {
                                    Text(license.id).font(.system(size: 13, weight: .semibold))
                                    if license.accepted == true {
                                        Text(t("已接受", "Accepted")).font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(WbColor.positive)
                                    }
                                }
                                Text(license.text).font(.system(size: 12)).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }
                } else {
                    Text(t("许可尚未读取。", "Licences have not been loaded."))
                        .foregroundStyle(WbColor.textSecondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                Spacer()
                Button(t("关闭", "Close")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(t("同意", "Agree")) {
                    if onAgree() { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(loading || !error.isEmpty || licenses == nil || !canAgree)
            }
            .tint(WbColor.accent)
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 560, height: 420)
        .background(WbColor.raised)
    }
}

struct OnboardingInstallProgressView: View {
    let language: Int
    let state: SDKOnboardingInstallState
    let fraction: Double?
    let message: String
    let error: String?
    private func t(_ zh: String, _ en: String) -> String { language == 1 ? zh : en }

    private var title: String {
        switch state {
        case .skipped: return t("需要确认许可", "Licence confirmation required")
        case .preparing, .installing: return t("正在准备 Android 运行环境", "Preparing the Android environment")
        case .completed: return t("Android 运行环境已准备好", "Android environment is ready")
        case .failed: return t("安装未完成", "Installation did not complete")
        case .cancelled: return t("安装已取消", "Installation cancelled")
        }
    }
    private var subtitle: String {
        switch state {
        case .skipped: return t("请返回上一步，查看并同意许可后继续。", "Go back, review the licences, and agree before continuing.")
        case .preparing: return t("正在确认安装许可。", "Confirming installation licences.")
        case .installing: return t("安装所需组件，请稍候。", "Installing the required components.")
        case .completed: return t("现在可以继续配置设备。", "You can now configure your device.")
        case .failed, .cancelled: return t("返回上一步可调整设置并重试。", "Go back to change your settings and try again.")
        }
    }
    private var symbol: String {
        switch state {
        case .skipped, .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "xmark.circle"
        case .preparing, .installing: return "arrow.down.to.line"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            VStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 29, weight: .medium))
                    .foregroundStyle(state == .failed ? WbColor.negative : WbColor.accentText)
                    .frame(width: 72, height: 72)
                    .background(WbColor.accentContainer.opacity(0.65), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                Text(title).font(.system(size: 25, weight: .semibold)).foregroundStyle(WbColor.textPrimary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text(subtitle).font(.system(size: 13)).foregroundStyle(WbColor.textSecondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity)
            if state == .preparing || state == .installing {
                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        Text(t("当前任务进度", "Current task progress")).font(.system(size: 12, weight: .semibold))
                        Spacer()
                        if let fraction {
                            Text("\(Int(fraction * 100))%")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                        }
                    }
                    if let fraction { ProgressView(value: fraction).labelsHidden().tint(WbColor.accent) }
                    else { ProgressView().controlSize(.small) }
                    if !message.isEmpty {
                        Text(message).font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }.frame(maxWidth: 500, alignment: .leading).padding(.top, 38)
            }
            if let error, !error.isEmpty, state == .failed {
                Text(error).font(.system(size: 12)).foregroundStyle(WbColor.negative)
                    .textSelection(.enabled).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 500).padding(.top, 20)
            }
            Spacer(minLength: 20)
        }.padding(.horizontal, 32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OnboardingInstallFooterView: View {
    let language: Int
    let state: SDKOnboardingInstallState
    let cancelPending: Bool
    let canCancel: Bool
    let onCancel: () -> Void
    let onReview: () -> Void
    var onReturnToSetup: (() -> Void)? = nil
    private func t(_ zh: String, _ en: String) -> String { language == 1 ? zh : en }

    var body: some View {
        HStack(spacing: 10) {
            Spacer()
            if state.showsCancel {
                Button(cancelPending ? t("正在取消…", "Cancelling…") : t("取消安装", "Cancel installation"), action: onCancel)
                    .disabled(!canCancel || cancelPending)
            } else if state.showsReviewSettings {
                Button(t("返回修改", "Review settings"), action: onReview)
                if let onReturnToSetup {
                    Button(t("返回设备配置", "Return to device setup"), action: onReturnToSetup)
                }
            }
        }
        .buttonStyle(WbPillButtonStyle()).controlSize(.regular)
        .padding(.horizontal, 32).padding(.vertical, 18)
    }
}

struct OnboardingEnvironmentChecking: View {
    let language: Int
    var body: some View {
        ProgressView(language == 1 ? "正在检查环境…" : "Checking the environment…").controlSize(.small)
    }
}

struct NewDeviceView: View {
    @ObservedObject var model: CenterModel
    var initialStep = 0
    var inline = false
    var initialShowAdvanced = false
    var automaticallySkipReadyEnvironment = true
    var initialImageInstall = false
    var startAtDeviceSetup = false
    var standaloneImageInstall = false
    var standaloneSDKSetup = false
    private var standaloneEnvironment: Bool { standaloneImageInstall || standaloneSDKSetup }
    var reduceMotionOverride: Bool? = nil
    var onPanelClose: ((@escaping () -> Void) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @State private var step: Int
    @State private var name = ""
    @State private var profiles: [HardwareProfile] = []
    @State private var profilesLoaded = false
    @State private var images: [AvailableImage] = []
    @State private var imagesLoaded = false
    @State private var profile = ""
    @State private var customSelection = DeviceResolutionSelection()
    @State private var showingCustomResolution = false
    @State private var image = ""
    @State private var ram = "4096"
    @State private var cpus = "4"
    @State private var storage = "6"
    @State private var root = "none"
    @State private var audio = true
    @State private var error = ""
    @State private var submission = DeviceCreationSubmission()
    @State private var imageInstallReturnStep: Int?
    @State private var environmentReturnStep: Int?
    @State private var showAdvanced = false
    @State private var environmentStatus: SDKStatus?
    @State private var initialImagesChecked = false
    @State private var initialSDKChecked = false
    @State private var initialRouteResolved = false
    @State private var directDeviceSetup = false
    @State private var initialized = false
    @State private var environmentError = ""
    @State private var environmentBusy = false
    @State private var availableImages: [AvailableImage] = []
    @State private var availableImagesLoading = false
    @State private var availableImagesError = ""
    @State private var installImageID = ""
    @State private var onboardingInstallRequested = false
    @State private var preparationAttempt = SDKPreparationAttempt()
    @State private var environmentReview = SDKLicenseReview()
    @State private var showingEnvironmentLicenses = false
    @State private var environmentLicenseLoading = false
    @State private var environmentLicenseError = ""
    @State private var onboardingStorageEstimate: StorageEstimateInfo?
    @State private var onboardingStorageProgress = ""

    init(model: CenterModel, initialStep: Int = 0, inline: Bool = false,
         initialShowAdvanced: Bool = false, automaticallySkipReadyEnvironment: Bool = true,
         initialImageInstall: Bool = false, startAtDeviceSetup: Bool = false,
         standaloneImageInstall: Bool = false, standaloneSDKSetup: Bool = false,
         reduceMotionOverride: Bool? = nil, onPanelClose: ((@escaping () -> Void) -> Void)? = nil) {
        self.model = model
        self.initialStep = initialStep
        self.inline = inline
        self.initialShowAdvanced = initialShowAdvanced
        self.automaticallySkipReadyEnvironment = automaticallySkipReadyEnvironment
        self.initialImageInstall = initialImageInstall
        self.startAtDeviceSetup = startAtDeviceSetup
        self.standaloneImageInstall = standaloneImageInstall
        self.standaloneSDKSetup = standaloneSDKSetup
        self.reduceMotionOverride = reduceMotionOverride
        self.onPanelClose = onPanelClose
        _step = State(initialValue: startAtDeviceSetup ? 3 : min(3, max(0, initialStep)))
        _directDeviceSetup = State(initialValue: startAtDeviceSetup)
        _showAdvanced = State(initialValue: initialShowAdvanced)
    }
    private func closePanel(after completion: @escaping () -> Void = {}) {
        if let onPanelClose { onPanelClose(completion) }
        else { dismiss(); DispatchQueue.main.async(execute: completion) }
    }
    private var saving: Bool { submission.isSaving }
    private var createdSuccessfully: Bool { submission.didCreate }
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }
    private var resolvingInitialRoute: Bool {
        inline && initialStep == 0 && automaticallySkipReadyEnvironment && !initialRouteResolved
    }

    private func resolveInitialRoute() {
        guard resolvingInitialRoute, initialImagesChecked, initialSDKChecked else { return }
        directDeviceSetup = DeviceOnboardingRoute.useDeviceSetup(hasTools: environmentStatus?.tools_sdk != nil && !preparesRuntime,
                                                                  installedImageCount: images.count)
        if directDeviceSetup { step = 3 }
        initialRouteResolved = true
    }

    private var creation: DeviceCreation {
        DeviceCreation(name: name, image: image, profile: profile, ram: ram, cpus: cpus,
                       storage: storage, root: root, audio: audio,
                       resolution: customSelection.active)
    }
    private var steps: [String] {
        [model.text("运行环境", "Environment"), model.text("安装环境", "Install environment"), model.text("设备配置", "Device setup")]
    }
    private var validationMessage: String? {
        guard imagesLoaded && !profiles.isEmpty else { return nil }
        do { _ = try creation.parameters(); return nil }
        catch { return model.creationError(error) }
    }

    private func applyProfile(_ id: String) {
        guard let value = profiles.first(where: { $0.id == id }) else { return }
        ram = String(value.ram_mb); cpus = String(value.cpus)
        storage = String(max(2, value.data_mb / 1024))
    }
    private func loadImages(preferredImageID: String? = nil, onComplete: @escaping (Bool) -> Void = { _ in }) {
        imagesLoaded = false
        model.call("image.list", ["available": false]) { result in
            do {
                let available = try model.decode(result.get(), as: [AvailableImage].self).filter { $0.installed_in != nil }
                images = available
                image = DeviceOnboardingRoute.selectedImage(installed: available.map(\.id), current: image, preferred: preferredImageID)
                imagesLoaded = true
                onComplete(true)
            } catch { self.error = error.localizedDescription; onComplete(false) }
            initialImagesChecked = true
            resolveInitialRoute()
        }
    }
    private func advance() {
        error = ""
        if step == 0 {
            guard canBeginEnvironmentInstallation else { return }
            beginEnvironmentInstallation()
        } else { step = 3 }
    }

    var body: some View {
        GeometryReader { geometry in
            let wide = inline && geometry.size.width >= 900 && geometry.size.height >= 600
            VStack(spacing: 0) {
                wizardHeader
                ZStack {
                if resolvingInitialRoute {
                    VStack {
                        Spacer()
                        ProgressView(model.text("正在检查 Android 环境…", "Checking Android environment…"))
                        Spacer()
                    }
                    .transition(.opacity)
                } else if step == 1 {
                    VStack(spacing: 0) {
                    OnboardingInstallProgressView(language: model.language, state: onboardingInstallState,
                                                  fraction: onboardingInstallState.displayedFraction(model.sdkInstallFraction),
                                                  message: onboardingInstallMessage,
                                                  error: environmentError.isEmpty ? model.sdkInstallError : environmentError)
                    onboardingInstallFooter
                    }
                    .transition(.opacity)
                } else {
                    VStack(spacing: 0) {
                    ScrollViewReader { scroll in
                    ScrollView {
                        HStack(spacing: wide ? 48 : 0) {
                            if wide {
                                ZStack {
                                    OnboardingArtwork(step: step == 3 ? 1 : 0)
                                        .id(step == 3)
                                        .transition(.opacity)
                                }
                            }
                            VStack(alignment: .leading, spacing: 18) {
                                ZStack(alignment: .topLeading) {
                                    if step == 0 { environmentStep.transition(.opacity) }
                                    else { configurationStep.transition(.opacity) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if !error.isEmpty {
                                    Text(error).wbFont(WbType.caption).foregroundStyle(WbColor.negative).textSelection(.enabled)
                                }
                                if createdSuccessfully {
                                    HStack {
                                        Text(model.text("设备已创建，正在刷新设备列表。", "Device created. Refreshing the device list."))
                                            .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                                        Button(model.text("刷新", "Refresh")) { model.refresh() }.buttonStyle(.link)
                                    }
                                }
                            }
                            .frame(maxWidth: wide ? 390 : 470, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - 164), alignment: .center)
                        .padding(.horizontal, wide ? 24 : 28)
                        .padding(.top, 8).padding(.bottom, 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: showAdvanced) { expanded in
                        guard expanded else { return }
                        DispatchQueue.main.async {
                            withAnimation(WbMotion.scroll.animation(reduceMotion: reduceMotion)) {
                                scroll.scrollTo("onboarding-advanced-fields", anchor: .bottom)
                            }
                        }
                    }
                    }
                    wizardFooter
                    }
                    .transition(.opacity)
                }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(WbMotion.status.animation(reduceMotion: reduceMotion), value: step)
            }
        }
        .frame(width: inline ? nil : 650, height: inline ? nil : 580)
        .frame(maxWidth: inline ? 1100 : nil, maxHeight: inline ? .infinity : nil)
        .background(!inline && standaloneEnvironment ? WbColor.raised : Color.clear)
        .modifier(DeviceSheetGlass(enabled: !inline && !standaloneEnvironment))
        .sheet(isPresented: $showingEnvironmentLicenses) {
            EnvironmentLicensesView(language: model.language, licenses: environmentReview.licenses,
                                    loading: environmentLicenseLoading, error: environmentLicenseError,
                                    canAgree: !environmentBusy && environmentReview.canAgree(to: environmentSelection),
                                    retry: { loadEnvironmentLicenses() },
                                    onAgree: {
                                        guard environmentReview.agree(to: environmentSelection) else { return false }
                                        if preparesRuntime { DispatchQueue.main.async { beginEnvironmentInstallation() } }
                                        return true
                                    })
        }
        .sheet(isPresented: $showingCustomResolution) {
            let selected = profiles.first(where: { $0.id == profile })
            CustomResolutionView(language: model.language,
                                 initialWidth: customSelection.saved?.width ?? selected?.width ?? 1080,
                                 initialHeight: customSelection.saved?.height ?? selected?.height ?? 1920) { resolution in
                customSelection.apply(resolution)
            }
        }
        .onAppear {
            guard !initialized else { return }
            initialized = true
            if name.isEmpty {
                var number = 1
                while model.devices.contains(where: { $0.name == model.text("我的安卓手机 \(number)", "My Android phone \(number)") }) { number += 1 }
                name = model.text("我的安卓手机 \(number)", "My Android phone \(number)")
            }
            model.call("profile.list") { result in
                profilesLoaded = true
                do {
                    profiles = try model.decode(result.get(), as: [HardwareProfile].self)
                    profile = profiles.first?.id ?? ""
                    applyProfile(profile)
                }
                catch { self.error = error.localizedDescription }
            }
            model.call("settings.get") { result in
                if let data = try? result.get(), let value = try? model.decode(data, as: DaemonSettings.self) { root = value.default_root_mode }
            }
            loadImages()
            if initialImageInstall { openImageInstaller() } else { loadEnvironment() }
        }
        .alert(model.text("更改存储位置？", "Change storage location?"),
               isPresented: Binding(get: { onboardingStorageEstimate != nil }, set: { if !$0 { onboardingStorageEstimate = nil } }),
               presenting: onboardingStorageEstimate) { estimate in
            Button(model.text("取消", "Cancel"), role: .cancel) { onboardingStorageEstimate = nil }
            Button(model.text("开始迁移", "Move data")) { onboardingStorageEstimate = nil; moveOnboardingStorage(estimate) }
        } message: { estimate in
            Text(model.text("设备、镜像和缓存将迁移到所选目录。运行中的设备会先停止。", "Devices, images and cache will move to the selected folder. Running devices will be stopped first."))
        }
        .interactiveDismissDisabled(model.onboardingInstallForegroundRequired || model.migratingStorage)
        .onChange(of: installImageID) { _ in environmentSelectionChanged() }
        .onChange(of: environmentStatus?.install_sdk ?? environmentStatus?.private_sdk) { _ in environmentSelectionChanged() }
    }

    private var wizardHeader: some View {
        HStack(alignment: .center) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(WbColor.accentText)
                Text(model.text("miko 模拟器", "miko simulator")).font(.system(size: 15, weight: .semibold))
            }
            Spacer()
            if !standaloneEnvironment && !directDeviceSetup && !resolvingInitialRoute {
            HStack(spacing: 7) {
                ForEach(0..<steps.count, id: \.self) { index in
                    Capsule()
                        .fill(index == min(step, 2) ? WbColor.textPrimary : WbColor.textSecondary.opacity(0.22))
                        .frame(width: index == min(step, 2) ? 21 : 6, height: 6)
                }
                Text("\(min(step, 2) + 1) / \(steps.count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(WbColor.textSecondary)
                    .padding(.leading, 5)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.text("第 \(min(step, 2) + 1) 步，共 \(steps.count) 步：\(steps[min(step, 2)])", "Step \(min(step, 2) + 1) of \(steps.count): \(steps[min(step, 2)])"))
            }
        }
        .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stepEyebrow: some View {
        Text(standaloneImageInstall ? model.text("系统镜像  /  安装镜像", "SYSTEM IMAGES  /  INSTALL IMAGE") : standaloneSDKSetup ? model.text("Android 环境  /  设置", "ANDROID ENVIRONMENT  /  SETUP") : directDeviceSetup ? (step == 0 ? (imageInstallReturnStep != nil ? model.text("创建设备  /  安装镜像", "CREATE DEVICE  /  INSTALL IMAGE") : model.text("创建设备  /  运行环境", "CREATE DEVICE  /  ENVIRONMENT")) : model.text("创建设备  /  设备配置", "CREATE DEVICE  /  DEVICE SETUP"))
             : step == 0 ? model.text("第 1 步  /  运行环境", "STEP 1  /  ENVIRONMENT")
                         : model.text("第 3 步  /  设备配置", "STEP 3  /  DEVICE SETUP"))
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(0.7)
            .foregroundStyle(WbColor.textSecondary)
    }

    private func loadEnvironment(onStatus: @escaping (Bool) -> Void = { _ in }) {
        environmentError = ""
        model.call("sdk.status") { result in
            do { environmentStatus = try model.decode(result.get(), as: SDKStatus.self); onStatus(true) }
            catch { environmentStatus = nil; environmentError = model.text("无法检查 SDK 状态：", "Unable to check SDK status: ") + error.localizedDescription; onStatus(false) }
            initialSDKChecked = true
            resolveInitialRoute()
            if step == 0 && preparesRuntime && !environmentBusy && !environmentLicenseLoading && environmentReview.licenses == nil {
                loadEnvironmentLicenses(automaticallyPrepare: true)
            }
        }
        guard !availableImagesLoading else { return }
        availableImagesLoading = true; availableImagesError = ""
        model.call("image.list", ["available": true]) { result in
            availableImagesLoading = false
            do {
                availableImages = try model.decode(result.get(), as: [AvailableImage].self).filter { $0.installed_in == nil }
                installImageID = SDKImageSelection.afterRefresh(current: installImageID, available: availableImages.map(\.id))
            } catch { availableImagesError = model.text("无法读取可下载镜像：", "Unable to load downloadable images: ") + error.localizedDescription }
        }
    }

    private func onboardingStorageButton(_ title: String) -> some View {
        Button(action: chooseOnboardingStorage) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WbColor.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(WbColor.borderDefault.opacity(0.8)))
        }
        .buttonStyle(.plain)
        .disabled(saving || environmentBusy || model.migratingStorage || model.dataDirectory == nil)
    }

    private func chooseOnboardingStorage() {
        guard !environmentBusy, !model.migratingStorage else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = model.text("选择存储目录", "Choose storage folder")
        panel.message = model.text("选择保存设备、系统镜像和缓存的目录。", "Choose the folder for devices, system images and cache.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let data = model.dataDirectory, MikoStorageRoot.root(forData: data) == url.standardizedFileURL.path { return }
        environmentBusy = true; environmentError = ""
        model.estimateStorageMigration(to: MikoStorageRoot.destination(forRoot: url)) { result in
            environmentBusy = false
            switch result {
            case .success(let estimate): onboardingStorageEstimate = estimate
            case .failure(let error): environmentError = OperationMessages.storageError(code: (error as? CenterMessageError)?.code, message: error.localizedDescription, language: model.language)
            }
        }
    }

    private func moveOnboardingStorage(_ estimate: StorageEstimateInfo) {
        environmentBusy = true; onboardingStorageProgress = model.text("正在迁移数据…", "Moving data…")
        model.migrateStorage(to: estimate.destination, onProgress: { message, _ in onboardingStorageProgress = message }) { result in
            environmentBusy = false; onboardingStorageProgress = ""
            switch result {
            case .success: loadImages(); loadEnvironment()
            case .failure(let error): environmentError = OperationMessages.storageError(code: (error as? CenterMessageError)?.code, message: error.localizedDescription, language: model.language)
            }
        }
    }

    private var preparesRuntime: Bool {
        guard let status = environmentStatus, !standaloneImageInstall, imageInstallReturnStep == nil else { return false }
        return status.tools_sdk == nil || status.runtime_needs_install == true
    }

    private var environmentSelection: SDKInstallSelection? {
        guard let status = environmentStatus, let destination = status.install_sdk ?? status.private_sdk else { return nil }
        if preparesRuntime {
            return SDKInstallSelection(imagePackage: nil, destination: destination)
        }
        let selectedImage = availableImages.first(where: { $0.id == installImageID })
        return SDKImageSelection.planSelection(selectedID: installImageID, selectedPackage: selectedImage?.package,
                                               requiresImage: true,
                                               destination: destination)
    }

    private func environmentSelectionChanged() {
        guard let reviewed = environmentReview.selection, reviewed != environmentSelection else { return }
        invalidateEnvironmentReview()
    }

    private func invalidateEnvironmentReview() {
        environmentReview.reset(); environmentLicenseLoading = false; environmentLicenseError = ""
    }

    private func loadEnvironmentLicenses(automaticallyPrepare: Bool = false) {
        guard !environmentLicenseLoading, let selection = environmentSelection else { return }
        let revision = environmentReview.begin(selection)
        environmentLicenseLoading = true; environmentLicenseError = ""
        let packages = selection.imagePackage.map { [$0] } ?? ["emulator", "platform-tools"]
        model.call("sdk.license_details", ["packages": packages]) { result in
            guard environmentReview.revision == revision, environmentSelection == selection else { return }
            environmentLicenseLoading = false
            do {
                let licenses = try model.decode(result.get(), as: [PendingLicense].self)
                guard environmentReview.complete(licenses, selection: selection, revision: revision),
                      automaticallyPrepare else { return }
                if licenses.allSatisfy({ $0.accepted == true }), environmentReview.agree(to: environmentSelection) {
                    beginEnvironmentInstallation()
                } else if !licenses.isEmpty {
                    showingEnvironmentLicenses = true
                }
            } catch {
                environmentLicenseError = model.text("无法读取许可，请检查网络后重试。", "Unable to load licences. Check your connection and retry.") + "\n" + error.localizedDescription
            }
        }
    }

    private var canBeginEnvironmentInstallation: Bool {
        (preparesRuntime || environmentStatus?.tools_sdk != nil) && environmentReview.canBeginInstallation(for: environmentSelection, busy: environmentBusy,
                                               installing: model.sdkInstalling,
                                               imagesLoading: !preparesRuntime && availableImagesLoading)
    }

    private func beginEnvironmentInstallation() {
        guard canBeginEnvironmentInstallation,
              let selection = environmentSelection,
              let plan = environmentReview.authorizedPlan(for: selection) else { return }
        let requests: [[String: String]]
        do { requests = try plan.consentRequests(reviewed: true) }
        catch { environmentError = model.text("许可信息无效，请重新查看。", "Licence information is invalid. Review it again."); invalidateEnvironmentReview(); return }
        onboardingInstallRequested = true; step = 1
        let attempt = preparationAttempt.begin()
        model.onboardingInstallForegroundRequired = true
        environmentBusy = true; environmentError = ""
        model.call("sdk.status") { result in
            guard preparationAttempt.isCurrent(attempt) else { return }
            do {
                let current = try model.decode(result.get(), as: SDKStatus.self)
                guard (current.install_sdk ?? current.private_sdk) == selection.destination,
                      environmentSelection == selection,
                      environmentReview.authorizedPlan(for: selection) != nil else {
                    environmentBusy = false; model.onboardingInstallForegroundRequired = false
                    environmentStatus = current; invalidateEnvironmentReview()
                    environmentError = model.text("SDK 配置已更改，请重新查看许可。", "SDK configuration changed. Review the licences again.")
                    return
                }
                acceptEnvironmentLicenses(requests, index: 0, plan: plan, attempt: attempt)
            } catch {
                environmentBusy = false; model.onboardingInstallForegroundRequired = false
                environmentError = model.text("无法检查 SDK 状态：", "Unable to check SDK status: ") + error.localizedDescription
            }
        }
    }

    private func acceptEnvironmentLicenses(_ requests: [[String: String]], index: Int, plan: SDKInstallPlan, attempt: Int) {
        guard preparationAttempt.isCurrent(attempt) else { return }
        if index == requests.count {
            guard !model.sdkInstalling else {
                environmentBusy = false; model.onboardingInstallForegroundRequired = false
                environmentError = model.text("已有安装任务正在运行。", "An installation is already running.")
                return
            }
            let installedImageID = plan.imagePackage == nil ? nil : installImageID
            model.startSDKInstall(plan) { succeeded in
                if succeeded {
                    if plan.imagePackage == nil {
                        invalidateEnvironmentReview()
                        imageInstallReturnStep = nil; environmentReturnStep = nil
                        loadEnvironment()
                        loadImages { _ in
                            if standaloneSDKSetup { closePanel() }
                            else if images.isEmpty { step = 0; onboardingInstallRequested = false }
                            else { directDeviceSetup = true; step = 3 }
                        }
                        return
                    }
                    loadImages(preferredImageID: installedImageID); loadEnvironment()
                    if SDKOnboardingInstallState.shouldDismissAfterSuccess(requested: onboardingInstallRequested, step: step, succeeded: succeeded, standalone: standaloneEnvironment) {
                        closePanel()
                    } else if !standaloneEnvironment, let next = SDKOnboardingInstallState.nextStepAfterSuccess(requested: onboardingInstallRequested, step: step, succeeded: succeeded) { step = next }
                    imageInstallReturnStep = nil
                    environmentReturnStep = nil
                }
            }
            environmentBusy = false
            return
        }
        model.call("sdk.accept_license", requests[index]) { result in
            guard preparationAttempt.isCurrent(attempt) else { return }
            switch result {
            case .success: acceptEnvironmentLicenses(requests, index: index + 1, plan: plan, attempt: attempt)
            case .failure(let failure):
                environmentBusy = false; model.onboardingInstallForegroundRequired = false; invalidateEnvironmentReview()
                environmentError = model.text("无法记录许可确认，请重新查看后重试。", "Unable to record licence consent. Review and try again.") + "\n" + failure.localizedDescription
            }
        }
    }

    private func environmentSectionHeader(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(WbColor.textPrimary)
            Spacer(minLength: 8)
            Text(detail).font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
        }
        .padding(.horizontal, 2)
    }

    private func environmentIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium)).foregroundStyle(WbColor.accentText)
            .frame(width: 38, height: 38)
            .background(WbColor.accentContainer.opacity(0.9), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .accessibilityHidden(true)
    }

    private var environmentStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepEyebrow.padding(.bottom, 12)
            Text(imageInstallReturnStep == nil ? model.text("准备 Android 环境", "Prepare your Android environment") : model.text("安装其他系统镜像", "Install another system image"))
                .font(.system(size: 28, weight: .semibold)).foregroundStyle(WbColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.text("首次设置会准备模拟器和 ADB。系统镜像按需下载。", "Set up the emulator and ADB, then download system images as needed."))
                .font(.system(size: 13)).foregroundStyle(WbColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)

            environmentSectionHeader(model.text("存储位置", "Storage location"), detail: "")
                .padding(.top, 22).padding(.bottom, 9)
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        let location = model.dataDirectory.map(MikoStorageRoot.root(forData:)) ?? model.text("读取中…", "Loading…")
                        Text(location)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(location)
                        Text(model.text("设备、系统镜像和缓存保存在这里。", "Devices, system images and cache are stored here."))
                            .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    onboardingStorageButton(model.text("更改位置…", "Change location…"))
                }
                if !onboardingStorageProgress.isEmpty { Text(onboardingStorageProgress).font(.caption) }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).modifier(OnboardingCardMaterial())

            environmentSectionHeader(model.text("安装所需组件", "Install components"),
                                     detail: model.text("按需准备", "As needed"))
                .padding(.top, 14).padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 11) {
                    environmentIcon("arrow.down.to.line")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preparesRuntime ? model.text("模拟器和 ADB", "Emulator and ADB") : model.text("系统镜像", "System image"))
                            .font(.system(size: 12, weight: .semibold))
                        Text(preparesRuntime ? model.text("先准备运行工具，稍后再选择系统镜像。", "Prepare the tools, then choose a system image.") : model.text("系统镜像会保存在 miko 的目录。", "System images are stored in the miko folder."))
                            .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !preparesRuntime {
                Picker(model.text("安装组件", "Components to install"), selection: $installImageID) {
                    Text(availableImages.isEmpty ? model.text("没有可安装的系统镜像", "No system images available to install")
                                                 : model.text("请选择要安装的镜像", "Choose a system image to install")).tag("")
                    ForEach(availableImages) { image in
                        Text("API \(image.api) · \(Device.imageTagLabel(image.tag)) · \(image.abi)").tag(image.id)
                    }
                }
                .pickerStyle(.menu).buttonStyle(.borderless).controlSize(.regular)
                .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(model.text("安装组件", "Components to install"))
                .disabled(environmentBusy)
                }
                HStack(alignment: .center, spacing: 8) {
                    if preparesRuntime {
                        Text(model.text("工具会安装到 miko 的目录。", "Tools will be installed in the miko folder."))
                    } else if availableImagesLoading {
                        ProgressView().controlSize(.small)
                        Text(model.text("正在读取镜像列表…", "Loading images…"))
                    } else {
                        Image(systemName: !availableImagesError.isEmpty ? "exclamationmark.circle" : "checkmark.circle")
                            .foregroundStyle(!availableImagesError.isEmpty ? WbColor.negative : WbColor.positive)
                        Text(!availableImagesError.isEmpty ? availableImagesError
                             : installImageID.isEmpty ? (availableImages.isEmpty ? model.text("没有可安装的系统镜像", "No system images available to install") : model.text("请选择要安装的镜像", "Choose a system image to install"))
                             : model.text("已读取系统镜像列表", "System images loaded"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    Button(model.text("重新检测", "Check again")) {
                        loadEnvironment()
                        loadImages()
                    }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(WbColor.accentText)
                        .disabled(environmentBusy || availableImagesLoading)
                }
                .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).modifier(OnboardingCardMaterial())
            environmentSectionHeader(model.text("许可确认", "Licence confirmation"), detail: "")
                .padding(.top, 14).padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 7) {
                Toggle(model.text("我已阅读并同意相关许可", "I have read and agree to the licences"), isOn: Binding(
                    get: { environmentReview.agreed },
                    set: { agreed in
                        if agreed && environmentReview.licenses == nil {
                            showingEnvironmentLicenses = true
                            loadEnvironmentLicenses()
                        } else { environmentReview.setAgreed(agreed) }
                    }
                ))
                .toggleStyle(OnboardingLicenseToggleStyle()).font(.system(size: 12, weight: .semibold))
                .disabled(environmentBusy || environmentSelection == nil || availableImagesLoading)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(model.text("安装组件可能涉及 Android SDK 许可。", "Installing components may require Android SDK licences."))
                        .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(model.text("查看许可说明", "View licence details")) {
                        showingEnvironmentLicenses = true
                        if environmentReview.licenses == nil { loadEnvironmentLicenses() }
                    }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(WbColor.accentText)
                    .disabled(environmentBusy || environmentSelection == nil || availableImagesLoading)
                }.padding(.leading, 27).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading).modifier(OnboardingCardMaterial())
            if environmentBusy { OnboardingEnvironmentChecking(language: model.language).padding(.top, 8) }
            if !environmentError.isEmpty { Text(environmentError).font(.system(size: 11)).foregroundStyle(WbColor.negative).textSelection(.enabled).padding(.top, 8) }
        }
    }

    private func openImageInstaller() {
        imageInstallReturnStep = 3
        directDeviceSetup = true
        environmentError = ""; error = ""
        invalidateEnvironmentReview()
        installImageID = ""
        step = 0
        loadEnvironment()
    }

    private var configurationStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            stepEyebrow.padding(.bottom, 12)
            Text(model.text("配置你的设备", "Configure your device"))
                .font(.system(size: 28, weight: .semibold)).foregroundStyle(WbColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.text("设置名称、硬件和 Root 模式，之后也可以调整。", "Choose a name, hardware profile and root mode. You can adjust them later."))
                .font(.system(size: 13)).foregroundStyle(WbColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(model.text("存储目录", "Storage folder"))
                        Spacer()
                        onboardingStorageButton(model.text("更改目录…", "Change folder…"))
                    }
                    Text(model.dataDirectory.map(MikoStorageRoot.root(forData:)) ?? model.text("读取中…", "Loading…"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(WbColor.textSecondary)
                        .textSelection(.enabled)
                    Text(model.text("设备数据、系统镜像和缓存保存在此目录。", "Device data, system images and caches are stored here."))
                        .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "square.3.layers.3d")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(WbColor.accentText)
                                .accessibilityHidden(true)
                            Text(model.text("系统镜像", "System image"))
                            Spacer(minLength: 8)
                            Button(action: openImageInstaller) {
                                Label(images.isEmpty ? model.text("安装镜像…", "Install image…") : model.text("安装其他镜像…", "Install another image…"),
                                      systemImage: "arrow.down.circle")
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(WbColor.accentText)
                            .disabled(saving)
                            .accessibilityIdentifier("onboarding-install-other-image")
                        }
                        if !imagesLoaded && error.isEmpty {
                            ProgressView(model.text("正在读取系统镜像…", "Loading system images…")).controlSize(.small)
                        } else if images.isEmpty {
                            Text(model.text("没有已安装的系统镜像，请先安装。", "No system images are installed. Install one first."))
                                .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                        } else {
                            Picker(model.text("系统镜像", "System image"), selection: $image) {
                                ForEach(images) { item in
                                    Text("Android API \(item.api) · \(Device.imageTagLabel(item.tag)) · \(item.abi)").tag(item.id)
                                }
                            }
                            .pickerStyle(.menu).buttonStyle(.borderless).labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(saving)
                            .accessibilityLabel(model.text("系统镜像", "System image"))
                        }
                        if initialSDKChecked && environmentStatus?.tools_sdk == nil {
                            Text(model.text("未找到可用的模拟器工具。", "Emulator tools are unavailable."))
                                .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                            Button(model.text("配置运行环境…", "Configure environment…")) {
                                environmentReturnStep = 3
                                directDeviceSetup = true
                                invalidateEnvironmentReview()
                                step = 0
                                loadEnvironment()
                            }
                            .buttonStyle(.link).disabled(saving)
                        }
                    }
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.text("设备名称", "Device name"))
                    TextField(model.text("例如：Pixel 9 Pro", "e.g. Pixel 9 Pro"), text: $name)
                        .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity).disabled(saving)
                        .accessibilityLabel(model.text("设备名称", "Device name"))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.text("设备规格", "Device profile"))
                    if profiles.isEmpty {
                        Text(profilesLoaded ? model.text("没有可用的设备规格。", "No device profiles are available.")
                                            : model.text("正在读取设备规格…", "Loading device profiles…"))
                            .font(.system(size: 12)).foregroundStyle(WbColor.textSecondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
                            ForEach(profiles) { item in profileCard(item) }
                            customProfileCard
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.text("Root 模式", "Root mode"))
                    rootModeControl
                    Text(rootExplanation)
                        .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.system(size: 13)).padding(17)
            .modifier(OnboardingCardMaterial())
            .padding(.top, 22)
            Button { showAdvanced.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text(model.text("高级配置", "Advanced configuration"))
                    Spacer(minLength: 0)
                    Text(model.text("内存、CPU、存储与声音", "Memory, CPU, storage and audio"))
                        .font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
                        .foregroundStyle(WbColor.textSecondary.opacity(0.8))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).font(.system(size: 12, weight: .medium))
            .foregroundStyle(WbColor.textSecondary).padding(.top, 16)
            .accessibilityLabel(model.text("高级配置", "Advanced configuration"))
            .accessibilityValue(showAdvanced ? model.text("已展开", "Expanded") : model.text("已收起", "Collapsed"))
            if showAdvanced {
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 10) {
                        advancedNumberField(model.text("内存 (MB)", "Memory (MB)"), value: $ram)
                        advancedNumberField(model.text("CPU 核心数", "CPU cores"), value: $cpus)
                        advancedNumberField(model.text("设备存储 (GB)", "Storage (GB)"), value: $storage)
                    }
                    Divider()
                    HStack {
                        Text(model.text("设备声音", "Device audio"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Toggle(model.text("设备声音", "Device audio"), isOn: $audio)
                            .labelsHidden().toggleStyle(.switch).tint(Color(nsColor: .controlAccentColor))
                    }
                }
                .font(.system(size: 12, weight: .medium)).foregroundStyle(WbColor.textSecondary)
                .padding(17).frame(maxWidth: .infinity, alignment: .leading)
                .modifier(OnboardingCardMaterial())
                .padding(.top, 10)
                .id("onboarding-advanced-fields")
            }
            if let validationMessage {
                Text(validationMessage).wbFont(WbType.caption).foregroundStyle(WbColor.negative).padding(.top, 12)
            }
        }
    }

    @ViewBuilder private var rootModeControl: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        let segments = HStack(spacing: 0) {
            rootModeButton(model.text("关闭", "Off"), value: "none")
            rootModeButton("Shell Root", value: "adb")
            rootModeButton(model.text("完整 Root", "Full Root"), value: "magisk")
        }
        .padding(3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.text("Root 模式", "Root mode"))
        .onMoveCommand { direction in
            let values = ["none", "adb", "magisk"]
            guard !saving, let index = values.firstIndex(of: root) else { return }
            switch direction {
            case .left: root = values[max(0, index - 1)]
            case .right: root = values[min(values.count - 1, index + 1)]
            default: break
            }
        }
        if #available(macOS 26.0, *) {
            segments.glassEffect(.regular, in: shape)
        } else {
            segments.background(.regularMaterial, in: shape)
        }
    }

    private func rootModeButton(_ title: String, value: String) -> some View {
        let selected = root == value
        return Button { root = value } label: {
            Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                .foregroundStyle(selected ? Color(nsColor: .alternateSelectedControlTextColor) : WbColor.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(selected ? Color(nsColor: .controlAccentColor).opacity(0.88) : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(saving)
        .help(title)
        .accessibilityValue(selected ? model.text("已选择", "Selected") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var rootExplanation: String {
        switch root {
        case "adb": return model.text("通过 Root Shell 使用高级功能。", "Use advanced features through a root shell.")
        case "magisk": return model.text("创建后将安装并配置 Magisk，期间设备会启动并重启。", "After creation Magisk is installed and configured; the device starts and reboots in the process.")
        default: return model.text("设备不会启用 Root。", "Root access is disabled.")
        }
    }
    private func profileCard(_ item: HardwareProfile) -> some View {
        let detail = item.width.flatMap { width in item.height.map { "\(width) × \($0)" } }
        return profileOption(item.name, detail: detail,
                             symbol: item.form_factor == "tablet" ? "ipad" : "iphone",
                             selected: !customSelection.isCustom && profile == item.id) {
            profile = item.id
            customSelection.selectPreset()
            applyProfile(item.id)
        }
    }
    private var customProfileCard: some View {
        let detail = customSelection.saved.map { "\($0.width) × \($0.height)" }
            ?? model.text("设置分辨率", "Set resolution")
        return profileOption(model.text("自定义", "Custom"), detail: detail,
                             symbol: "slider.horizontal.3", selected: customSelection.isCustom) {
            showingCustomResolution = true
        }
        .accessibilityIdentifier("device-profile-custom")
    }
    private func profileOption(_ title: String, detail: String?, symbol: String, selected: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .medium))
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                }
                .foregroundStyle(selected ? WbColor.accentText : WbColor.textSecondary)
                Text(title).font(.system(size: 11, weight: .medium))
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                if let detail {
                    Text(verbatim: detail).font(.system(size: 10))
                        .foregroundStyle(WbColor.textSecondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 65, alignment: .topLeading)
            .padding(9)
            .background(selected ? WbColor.accentContainer.opacity(0.65) : Color.primary.opacity(0.025),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? WbColor.accentText.opacity(0.65) : WbColor.borderSubtle))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain).disabled(saving)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? model.text("已选择", "Selected") : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func advancedNumberField(_ label: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .bottomLeading)
            TextField("", text: value).textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading).foregroundStyle(WbColor.textPrimary)
                .disabled(saving).accessibilityLabel(label)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var onboardingInstallState: SDKOnboardingInstallState {
        SDKOnboardingInstallState.resolve(requested: onboardingInstallRequested,
                                          preparing: environmentBusy,
                                          running: model.sdkInstalling,
                                          succeeded: model.sdkInstallSucceeded,
                                          error: environmentError.isEmpty ? model.sdkInstallError : environmentError)
    }
    private var onboardingInstallMessage: String {
        if onboardingInstallState == .preparing { return model.text("正在确认许可…", "Confirming licences…") }
        return model.sdkInstallMessage
    }
    private var onboardingInstallFooter: some View {
        OnboardingInstallFooterView(language: model.language, state: onboardingInstallState,
                                    cancelPending: model.sdkCancelPending,
                                    canCancel: (onboardingInstallState == .preparing && environmentBusy && !model.sdkInstalling) || onboardingInstallState == .installing,
                                    onCancel: {
                                        if environmentBusy && !model.sdkInstalling {
                                            preparationAttempt.cancel()
                                            environmentBusy = false; model.onboardingInstallForegroundRequired = false
                                            onboardingInstallRequested = false; environmentReview.reset(); step = 0
                                        } else { model.cancelSDKInstall() }
                                    },
                                    onReview: { step = 0; environmentError = ""; environmentReview.reset() },
                                    onReturnToSetup: standaloneEnvironment ? nil : {
                                        environmentError = ""; environmentReview.reset()
                                        imageInstallReturnStep = nil; environmentReturnStep = nil
                                        directDeviceSetup = true; step = 3
                                    })
    }
    private var wizardFooter: some View {
        HStack(spacing: 8) {
            if !standaloneEnvironment && step == 0 && (imageInstallReturnStep != nil || environmentReturnStep != nil) {
                Button {
                    error = ""
                    if step == 0, let returnStep = imageInstallReturnStep {
                        imageInstallReturnStep = nil; invalidateEnvironmentReview(); step = returnStep
                    } else if step == 0, let returnStep = environmentReturnStep {
                        environmentReturnStep = nil; invalidateEnvironmentReview(); step = returnStep
                    }
                } label: {
                    Label(model.text("返回设备配置", "Return to device setup"), systemImage: "arrow.left")
                }
                .buttonStyle(.plain).foregroundStyle(WbColor.textSecondary).disabled(saving || environmentBusy)
                .accessibilityIdentifier("onboarding-back")
            }
            Spacer()
            if !inline {
                Button(model.text("取消", "Cancel")) { closePanel() }.disabled(saving).keyboardShortcut(.cancelAction)
            }
            if step < 3 {
                if step == 0 && !environmentReview.agreed {
                    Text(model.text("请先查看并同意许可", "Review and agree to the licences first"))
                        .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                }
                onboardingAction(model.text("开始安装", "Install"), action: advance,
                                 disabled: saving || environmentBusy || !canBeginEnvironmentInstallation)
            } else {
                onboardingAction(model.text("创建设备", "Create device"), action: create,
                                 disabled: saving || createdSuccessfully || !imagesLoaded || !creation.isValid || images.isEmpty || profiles.isEmpty || environmentStatus?.tools_sdk == nil)
            }
        }
        .buttonStyle(WbPillButtonStyle()).controlSize(.regular)
        .padding(.horizontal, 32).padding(.vertical, 18)
    }

    @ViewBuilder private func onboardingAction(_ title: String, action: @escaping () -> Void, disabled: Bool) -> some View {
        let button = Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .frame(minWidth: 86, minHeight: 20)
        }
        .disabled(disabled)
        .keyboardShortcut(.defaultAction)
        .tint(Color(nsColor: .controlAccentColor))

        if #available(macOS 26.0, *) {
            button.buttonStyle(.glassProminent).buttonBorderShape(.roundedRectangle).controlSize(.regular)
        } else {
            button.buttonStyle(.borderedProminent).controlSize(.regular)
        }
    }
    private func create() {
        let parameters: [String: Any]
        do { parameters = try creation.parameters() }
        catch { self.error = model.creationError(error); return }
        guard submission.begin() else { return }
        model.call("device.create", parameters) { result in
            switch result {
            case .success(let data):
                submission.finish(succeeded: true)
                do {
                    let created = try model.decode(data, as: Device.self)
                    model.selected = created.id; model.details = nil; model.apps = []
                    model.refresh()
                    let afterClose = {
                        if root == "magisk" { model.setupFullRoot(created.id, name: created.name) }
                    }
                    if !inline { closePanel(after: afterClose) } else { afterClose() }
                } catch { self.error = model.text("设备已创建，但读取结果失败：", "Device created, but its result could not be read: ") + error.localizedDescription; model.refresh() }
            case .failure(let failure): submission.finish(succeeded: false); error = failure.localizedDescription
            }
        }
    }
}
