// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import CoreGraphics
import Foundation
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers

private let sidebarWidth: CGFloat = WbLayout.windowDeviceToolbarWidth
private let mappingPanelWidth: CGFloat = 288
private let playerTitlebarHeight: CGFloat = sidebarWidth

final class SidebarState: ObservableObject {
    @Published var visible = true
}

final class GameWindowController: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onStopRequested: (() -> Void)?
    var canClose: (() -> Bool)?
    var stopDeviceOnClose = true
    var onWarning: ((String) -> Void)?
    let transport = PlayerTransport()
    let chrome = PlayerChromeState()
    /// The daemon device this window shows; the Device menu uses it to act on
    /// the key window's device (same id the center opened the window for).
    private(set) var deviceID = ""
    /// Human name in the window title; kept for the Window menu.
    private(set) var displayTitle = ""
    private let sidebar = SidebarState()
    private var sidebarButton: NSButton?
    private weak var titleLabel: NSTextField?
    private var stateStore: GameWindowStateStore?
    private var visibilityObservers: [NSObjectProtocol] = []
    /// Raw occlusion state observed while the window was known to be on screen.
    /// Some host/SDK combinations (seen on macOS 27 with an older SDK) report an
    /// unrecognised flag instead of `OcclusionState.visible`, so compare against
    /// this baseline rather than trusting the flag alone.
    private var occlusionBaseline: UInt?
    var window: NSWindow?
    private var aspect: CGFloat = 720.0 / 1280.0
    private var side: CGFloat = sidebarWidth
    private(set) var titlebarInset: CGFloat = 0
    private var contentTopConstraint: NSLayoutConstraint?
    private var didReceiveSize = false
    private var frameWidth = 0
    private var frameHeight = 0
    private var keyMonitor: Any?
    private var languageCancellable: AnyCancellable?
    private var mappingEditingCancellable: AnyCancellable?
    private var fullscreenObservers: [NSObjectProtocol] = []
    /// Re-clamps the window when displays are plugged in, unplugged or resized.
    private var screenChangeObserver: NSObjectProtocol?
    private weak var hostingView: NSView?
    private var panelAnimation: PanelSlideAnimation?

    private final class PanelSlideAnimation: NSAnimation {
        private let onStep: (CGFloat) -> Void
        private let onFinish: () -> Void
        private var finished = false

        init(duration: TimeInterval = 0.22, onStep: @escaping (CGFloat) -> Void, onFinish: @escaping () -> Void) {
            self.onStep = onStep
            self.onFinish = onFinish
            super.init(duration: duration, animationCurve: .easeInOut)
            animationBlockingMode = .nonblocking
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var currentProgress: NSAnimation.Progress {
            didSet {
                onStep(CGFloat(currentValue))
                if currentProgress >= 1, !finished {
                    finished = true
                    onFinish()
                }
            }
        }

        func cancel() {
            finished = true
            stop()
        }
    }

    private func updateSideWidth(fit: Bool) {
        let base = sidebar.visible ? sidebarWidth : 0
        let panel = (chrome.mappingPanelMounted && !chrome.fullscreen) ? chrome.mappingPanelWidth : 0
        side = base + panel
        if fit, let window, !window.styleMask.contains(.fullScreen) {
            fitWindow()
        }
    }

    private func fittedWindowFrame(forSide nextSide: CGFloat) -> NSRect? {
        guard let window else { return nil }
        let current = NSSize(width: window.contentLayoutRect.width, height: window.contentLayoutRect.height - titlebarInset)
        let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let maxHeight = max(200, visible.height - (window.frame.height - current.height) - 24)
        let maxWidth = max(200, visible.width - 24)
        let height = floor(min(current.height, maxHeight, (maxWidth - nextSide) / aspect))
        let contentSize = NSSize(width: round(height * aspect) + nextSide, height: height)
        var frame = window.frame
        frame.size = NSSize(
            width: contentSize.width,
            height: contentSize.height + titlebarInset + window.frame.height - window.contentLayoutRect.height
        )
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return frame
    }

    private func fitWindow() {
        guard let window, let frame = fittedWindowFrame(forSide: side) else { return }
        window.setFrame(frame, display: true)
    }

    private func animateMappingPanel(editing: Bool) {
        panelAnimation?.cancel()
        panelAnimation = nil

        let base = sidebar.visible ? sidebarWidth : 0
        let targetPanel: CGFloat = (editing && !chrome.fullscreen) ? mappingPanelWidth : 0
        let targetSide = base + targetPanel

        guard !chrome.fullscreen, let window, window.isVisible, !window.styleMask.contains(.fullScreen) else {
            chrome.mappingPanelMounted = !chrome.fullscreen && editing
            chrome.mappingPanelWidth = targetPanel
            side = targetSide
            if !chrome.fullscreen { fitWindow() }
            return
        }

        let startPanel = chrome.mappingPanelWidth
        let startFrame = window.frame
        guard abs(targetPanel - startPanel) > 0.5, let endFrame = fittedWindowFrame(forSide: targetSide) else {
            chrome.mappingPanelMounted = editing
            chrome.mappingPanelWidth = targetPanel
            side = targetSide
            return
        }

        chrome.mappingPanelMounted = true
        let animation = PanelSlideAnimation(
            duration: 0.22,
            onStep: { [weak self] eased in
                guard let self, let window = self.window else { return }
                let panel = startPanel + (targetPanel - startPanel) * eased
                let frame = NSRect(
                    x: startFrame.origin.x + (endFrame.origin.x - startFrame.origin.x) * eased,
                    y: startFrame.origin.y + (endFrame.origin.y - startFrame.origin.y) * eased,
                    width: startFrame.width + (endFrame.width - startFrame.width) * eased,
                    height: startFrame.height + (endFrame.height - startFrame.height) * eased
                )
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.side = base + panel
                self.chrome.mappingPanelWidth = panel
                window.setFrame(frame, display: false)
                self.hostingView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                CATransaction.commit()
                NSAnimationContext.endGrouping()
            },
            onFinish: { [weak self] in
                guard let self else { return }
                self.panelAnimation = nil
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.side = targetSide
                self.chrome.mappingPanelWidth = targetPanel
                if !editing {
                    self.chrome.mappingPanelMounted = false
                }
                self.window?.setFrame(endFrame, display: true)
                self.hostingView?.layoutSubtreeIfNeeded()
                CATransaction.commit()
                NSAnimationContext.endGrouping()
            }
        )
        panelAnimation = animation
        animation.start()
    }

    /// contentLayoutRect excludes the titlebar even with fullSizeContentView.
    private func setPlayerContentSize(_ size: NSSize) {
        guard let window else { return }
        var frame = window.frame
        frame.size = NSSize(width: size.width,
                            height: size.height + titlebarInset + window.frame.height - window.contentLayoutRect.height)
        window.setFrame(frame, display: true)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard !sender.styleMask.contains(.fullScreen) else { return frameSize }
        let decorations = sender.frame.height - sender.contentLayoutRect.height + titlebarInset
        let old = NSSize(width: sender.contentLayoutRect.width, height: sender.contentLayoutRect.height - titlebarInset)
        let proposedHeight = max(180, frameSize.height - decorations)
        let widthHeight = max(180, (frameSize.width - side) / aspect)
        let height = round(abs(proposedHeight - old.height) >= abs(widthHeight - old.height) ? proposedHeight : widthHeight)
        return NSSize(width: round(height * aspect) + side, height: height + decorations)
    }

    @objc private func toggleSidebar() {
        panelAnimation?.cancel()
        panelAnimation = nil
        let editing = transport.mapping.editing
        chrome.mappingPanelMounted = !chrome.fullscreen && editing
        chrome.mappingPanelWidth = (!chrome.fullscreen && editing) ? mappingPanelWidth : 0
        sidebar.visible.toggle()
        updateSidebarButton()
        updateSideWidth(fit: true)
    }

    /// The native titlebar accessory symbols follow the effective appearance.
    private func styleTitlebarButton(_ button: NSButton, symbol: String, label: String,
                                     tint: NSColor = .secondaryLabelColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(configuration)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = tint
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    private func updateSidebarButton() {
        let label = sidebar.visible
            ? t("隐藏侧边栏", "Hide sidebar", transport.language)
            : t("显示侧边栏", "Show sidebar", transport.language)
        guard let sidebarButton else { return }
        styleTitlebarButton(sidebarButton,
                            symbol: sidebar.visible ? WbIcon.hideDetails : WbIcon.showDetails,
                            label: label)
    }

    private func addSidebarButton(to window: NSWindow) {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: sidebarWidth, height: 28))
        button.bezelStyle = .inline
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(toggleSidebar)
        button.setAccessibilityRole(.button)
        accessory.view = button
        sidebarButton = button
        window.addTitlebarAccessoryViewController(accessory)
        updateSidebarButton()
    }

    private func togglePin() {
        guard let window else { return }
        window.level = window.level == .floating ? .normal : .floating
        chrome.pinned = window.level == .floating
    }

    private func addCompactActions(to window: NSWindow) {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .right
        let view = NSHostingView(rootView: PlayerTitlebarActions(transport: transport, mapping: transport.mapping, chrome: chrome))
        view.frame = NSRect(x: 0, y: 0, width: 108, height: 28)
        accessory.view = view
        window.addTitlebarAccessoryViewController(accessory)
    }

    private func saveState() {
        guard let window, let stateStore, !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
        let frame = window.frame
        let savedWidth = frame.width - (chrome.fullscreen ? 0 : chrome.mappingPanelWidth)
        let state = GameWindowState(x: frame.minX, y: frame.minY, width: savedWidth, height: frame.height,
                                    sidebar: sidebar.visible, onTop: window.level == .floating, landscape: aspect > 1,
                                    screen: displayIdentifier(window.screen))
        do { try stateStore.save(state) } catch { onWarning?(windowStateMessage(error)) }
    }

    /// Display text for a window-state error: the store reports stable codes,
    /// the player window is where the current language is known.
    private func windowStateMessage(_ error: Error) -> String {
        guard let state = error as? GameWindowStateStore.StateError else { return error.localizedDescription }
        switch state.code {
        case "windowstate.invalid_device":
            return t("设备标识无效。", "Invalid device identifier.", transport.language)
        case "windowstate.invalid_state":
            return t("窗口设置无效，原文件未覆盖。", "The window settings are invalid; the file was not overwritten.", transport.language)
        case "windowstate.changed":
            return t("窗口设置已被其他程序修改，未覆盖原文件。", "The window settings were changed by another program; the file was not overwritten.", transport.language)
        case "windowstate.data_unavailable":
            return t("数据目录不可用，未保存窗口设置。", "The data directory is unavailable; the window settings were not saved.", transport.language)
        default:
            return state.code
        }
    }

    func open(device: String, width: Int, height: Int, executable: String, displayName: String? = nil,
              quality: UInt8 = 1, dataDirectory: String? = nil,
              launch: PlayerLaunchState = .running, hidden: Bool = false,
              onStartDevice: (() -> Void)? = nil) {
        guard width > 0, height > 0 else { return }
        deviceID = device
        displayTitle = displayName ?? device
        aspect = CGFloat(width) / CGFloat(height)
        var saved: GameWindowState?
        var legacy: (sidebar: Bool, onTop: Bool)?
        if let dataDirectory {
            do {
                let store = try GameWindowStateStore(dataDirectory: dataDirectory, device: device)
                saved = try store.load()
                stateStore = store
                if saved == nil { legacy = try store.legacyPreferences() }
            } catch {
                onWarning?(windowStateMessage(error))
            }
            transport.shortcuts.load(dataDirectory: dataDirectory, device: device)
            if ProcessInfo.processInfo.environment["MIKO_PLAYER_FIXTURE"] == "1" {
                // The fixture has no daemon connect_info response to supply
                // this path. Keep local mapping editing usable in its temp home.
                transport.mapping.load(path: URL(fileURLWithPath: dataDirectory)
                    .appendingPathComponent("keymaps").appendingPathComponent("\(device).json").path)
            }
        }
        if let sidebarVisible = saved?.sidebar ?? legacy?.sidebar {
            sidebar.visible = sidebarVisible
            side = sidebarVisible ? sidebarWidth : 0
        }
        let initialHeight: CGFloat = 740
        occlusionBaseline = nil
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: initialHeight * aspect + side, height: initialHeight),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "\(displayName ?? device) — miko simulator"
        window.titleVisibility = .hidden
        window.delegate = self
        // Both chrome regions expose one behind-window native material. The
        // video remains opaque; the titlebar and hosting view add no solid fill.
        window.backgroundColor = .clear
        window.isOpaque = false
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.toolbar = NSToolbar(identifier: "miko.player.titlebar")
        window.toolbarStyle = .unifiedCompact
        let background = PlayerWindowBackgroundView()
        let hosting = NSHostingView(rootView: ContentView(transport: transport, mapping: transport.mapping, sidebar: sidebar, chrome: chrome))
        hostingView = hosting
        window.contentView = background
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        let title = NSTextField(labelWithString: window.title)
        title.identifier = NSUserInterfaceItemIdentifier("miko.player.title")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(title)
        titleLabel = title
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 78),
            title.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -(sidebarWidth + 80)),
            title.centerYAnchor.constraint(equalTo: background.topAnchor, constant: playerTitlebarHeight / 2)
        ])
        titlebarInset = max(0, playerTitlebarHeight - (window.frame.height - window.contentLayoutRect.height))
        let constraints = [NSLayoutConstraint.Attribute.leading, .trailing, .top, .bottom].map {
            NSLayoutConstraint(item: hosting, attribute: $0, relatedBy: .equal,
                               toItem: window.contentLayoutGuide, attribute: $0,
                               multiplier: 1, constant: $0 == .top ? titlebarInset : 0)
        }
        contentTopConstraint = constraints[2]
        NSLayoutConstraint.activate(constraints)
        addSidebarButton(to: window)
        self.window = window
        window.level = (saved?.onTop ?? legacy?.onTop ?? false) ? .floating : .normal
        chrome.pinned = window.level == .floating
        addCompactActions(to: window)
        updateSidebarButton()
        observeFullscreen(window)
        observeDisplayVisibility(window)
        installKeyMonitor()
        languageCancellable = transport.$language.sink { [weak self] _ in
            self?.updateSidebarButton()
        }
        mappingEditingCancellable = transport.mapping.$editing
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] editing in
                self?.animateMappingPanel(editing: editing)
            }
        wireChrome()
        transport.onPixelPerfect = { [weak self] in self?.applyPixelPerfectSize() }
        transport.onFitScreen = { [weak self] in self?.fitScreen() }
        transport.onFrameSize = { [weak self] width, height in
            guard let self, width > 0, height > 0 else { return }
            self.frameWidth = width
            self.frameHeight = height
            let next = CGFloat(width) / CGFloat(height)
            if !self.didReceiveSize || abs(next - self.aspect) > 0.001 {
                self.aspect = next
                self.didReceiveSize = true
                self.fitWindow()
                if self.chrome.pixelPerfect { self.applyPixelPerfectSize() }
            }
        }
        transport.onDataDirectory = { [weak self] path in
            guard let self else { return }
            self.transport.shortcuts.load(dataDirectory: path, device: device)
        }
        transport.onStartDevice = onStartDevice
        if let saved, let frame = restoredFrame(saved) {
            // Restores the saved display when it still exists and clamps the
            // frame into that display's visible area (multi-display + Retina:
            // everything here is AppKit points, never pixels).
            window.setFrame(frame, display: false)
            // Old saved frames may use another sidebar or titlebar size.
            // Refit every restored frame so the video fills its viewport.
            fitWindow()
        } else {
            let decorations = window.frame.height - window.contentLayoutRect.height + titlebarInset
            let size = GameWindowDefaultSize.content(visible: NSScreen.main?.visibleFrame,
                                                     aspect: aspect, side: side, decorations: decorations)
            setPlayerContentSize(size)
            fitWindow()
            window.center()
        }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.clampToVisibleScreen() }
        if !hidden {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            transport.setDisplayVisible(false)
        }
        switch launch {
        case .running:
            do {
                try transport.start(device: device, width: width, height: height, executable: executable, quality: quality)
            } catch {
                transport.onStatus?(t("无法启动桥接：", "Unable to start the connection: ", transport.language) + error.localizedDescription)
            }
        case .booting, .stopped:
            transport.prepareStreaming(device: device, width: width, height: height,
                                       executable: executable, quality: quality)
            transport.applyLaunchState(launch)
        }
    }

    /// The `NSScreenNumber` of a display, as stored in the window state.
    private func displayIdentifier(_ screen: NSScreen?) -> String? {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return number.stringValue
    }

    private var screenGeometries: [GameWindowScreen] {
        NSScreen.screens.map { GameWindowScreen(id: displayIdentifier($0), visible: $0.visibleFrame) }
    }

    /// Frame to restore: same display when it exists, clamped into its visible
    /// area; falls back to the main display when that monitor is gone.
    private func restoredFrame(_ saved: GameWindowState) -> NSRect? {
        GameWindowRestore.restoreFrame(saved, screens: screenGeometries, fallback: NSScreen.main?.visibleFrame)
    }

    /// Displays changed (unplugged, resolution change): keep the window fully
    /// reachable and keep the device aspect after the clamp.
    private func clampToVisibleScreen() {
        guard let window, !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
        let visible = screenGeometries.first { $0.id == displayIdentifier(window.screen) }?.visible
            ?? NSScreen.main?.visibleFrame
        guard let visible else { return }
        let clamped = GameWindowRestore.clamp(window.frame, to: visible)
        if clamped != window.frame { window.setFrame(clamped, display: true) }
        fitWindow()
    }

    // MARK: Menu accessors

    /// "View ▸ Show/Hide Sidebar" for the key window.
    var sidebarVisible: Bool { sidebar.visible }
    func toggleSidebarFromMenu() { toggleSidebar() }

    /// Dock/menu "open this device": never opens a duplicate window.
    func focusFromMenu() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        transport.setDisplayVisible(true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Chrome state

    private func wireChrome() {
        chrome.togglePinAction = { [weak self] in self?.togglePin() }
        chrome.pixelPerfectAction = { [weak self] in self?.applyPixelPerfectSize() }
        chrome.fitAction = { [weak self] in self?.fitScreen() }
        chrome.toggleSidebarAction = { [weak self] in self?.toggleSidebar() }
        chrome.chooseScreenshotAction = { [weak self] in self?.transport.chooseScreenshot() }
        chrome.toggleRecordingAction = { [weak self] in self?.transport.toggleRecording() }
        chrome.chooseAPKAction = { [weak self] in self?.transport.chooseFile(apkOnly: true) }
        chrome.chooseFileAction = { [weak self] in self?.transport.chooseFile(apkOnly: false) }
    }

    private func fitScreen() {
        chrome.pixelPerfect = false
        fitWindow()
    }

    private func applyPixelPerfectSize() {
        guard let window, frameWidth > 0, frameHeight > 0, let screen = window.screen else { return }
        let scale = window.backingScaleFactor
        let size = NSSize(width: CGFloat(frameWidth) / scale + side, height: CGFloat(frameHeight) / scale)
        let full = NSSize(width: size.width,
                          height: size.height + titlebarInset + window.frame.height - window.contentLayoutRect.height)
        guard !window.styleMask.contains(.fullScreen),
              full.width <= screen.visibleFrame.width, full.height <= screen.visibleFrame.height else {
            transport.onStatus?(t("原始像素大小超出当前屏幕", "The original size does not fit this display", transport.language))
            return
        }
        setPlayerContentSize(size)
        let frame = window.frame, visible = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: min(max(frame.minX, visible.minX), visible.maxX - frame.width),
                                      y: min(max(frame.minY, visible.minY), visible.maxY - frame.height)))
        chrome.pixelPerfect = true
    }

    private func toggleFullscreen() {
        window?.toggleFullScreen(nil)
    }

    private func toggleOverlay() {
        chrome.overlay.toggle()
    }

    /// Mirrors the window's on-screen visibility into the transport. Frames
    /// keep being parsed while hidden, but no CGImage or display work happens
    /// until the window is visible again.
    private func observeDisplayVisibility(_ window: NSWindow) {
        let center = NotificationCenter.default
        let update: (Notification) -> Void = { [weak self] _ in self?.refreshDisplayVisibility() }
        for name in [NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification] {
            visibilityObservers.append(center.addObserver(forName: name, object: window, queue: .main, using: update))
        }
        for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            visibilityObservers.append(center.addObserver(forName: name, object: nil, queue: .main, using: update))
        }
    }

    /// A window counts as shown when it is on the active Space, ordered in, not
    /// miniaturized, the app is not hidden and the occlusion state does not
    /// contradict that.
    private func refreshDisplayVisibility() {
        guard let window else {
            transport.setDisplayVisible(false)
            return
        }
        let onScreen = window.isVisible && !window.isMiniaturized && window.isOnActiveSpace && !NSApp.isHidden
        guard onScreen else {
            transport.setDisplayVisible(false)
            return
        }
        let state = window.occlusionState
        if occlusionBaseline == nil, state.contains(.visible) || state.rawValue != 0 {
            occlusionBaseline = state.rawValue
        }
        // A different, non-visible state than the known on-screen baseline means
        // AppKit reports the window as fully occluded. When the host does not
        // expose a usable state at all (baseline nil) stay visible instead of
        // freezing on a value we cannot interpret.
        if let baseline = occlusionBaseline,
           state.rawValue != baseline,
           !state.contains(.visible) {
            transport.setDisplayVisible(false)
            return
        }
        transport.setDisplayVisible(true)
    }

    private func observeFullscreen(_ window: NSWindow) {
        let center = NotificationCenter.default
        fullscreenObservers.append(center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.panelAnimation?.cancel()
            self.panelAnimation = nil
            self.chrome.fullscreen = true
            self.chrome.mappingPanelMounted = false
            self.chrome.mappingPanelWidth = 0
            self.titleLabel?.isHidden = true
            self.contentTopConstraint?.constant = 0
            self.chrome.reveal = false
            self.updateSideWidth(fit: false)
        })
        fullscreenObservers.append(center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.panelAnimation?.cancel()
            self.panelAnimation = nil
            self.chrome.fullscreen = false
            let editing = self.transport.mapping.editing
            self.chrome.mappingPanelMounted = editing
            self.chrome.mappingPanelWidth = editing ? mappingPanelWidth : 0
            self.titleLabel?.isHidden = false
            self.contentTopConstraint?.constant = self.titlebarInset
            self.chrome.reveal = false
            self.updateSideWidth(fit: true)
        })
    }

    // MARK: Window shortcuts

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.window != nil, event.window === self.window else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func removeMonitors() {
        panelAnimation?.cancel()
        panelAnimation = nil
        languageCancellable?.cancel()
        languageCancellable = nil
        mappingEditingCancellable?.cancel()
        mappingEditingCancellable = nil
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        for observer in fullscreenObservers { NotificationCenter.default.removeObserver(observer) }
        fullscreenObservers.removeAll()
        for observer in visibilityObservers { NotificationCenter.default.removeObserver(observer) }
        visibilityObservers.removeAll()
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
    }

    /// Returns true when the player consumed the key (it then never reaches the
    /// device). Esc only leaves fullscreen; otherwise it is a game key.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let characters = event.charactersIgnoringModifiers ?? ""
        let key = characters.lowercased()
        let language = transport.language
        if transport.shortcuts.capture != nil {
            if event.keyCode == 53 {
                transport.shortcuts.cancelCapture()
                return true
            }
            if let failure = transport.shortcuts.assign(key: characters,
                                                        command: flags.contains(.command),
                                                        control: flags.contains(.control),
                                                        shift: flags.contains(.shift),
                                                        alt: flags.contains(.option)) {
                onStatusNotice(ShortcutFailure.describe(failure, language: language))
            } else {
                onStatusNotice(t("快捷键已更新。", "Shortcut updated.", language))
            }
            return true
        }
        if event.keyCode == 53 && chrome.fullscreen, NSApp.modalWindow == nil, window?.attachedSheet == nil {
            toggleFullscreen()
            return true
        }
        if flags == [.control, .command], key == "f" {
            toggleFullscreen()
            return true
        }
        if flags == [.command, .option], key == "i" {
            toggleOverlay()
            return true
        }
        if flags == [.command, .option], key == "0" {
            applyPixelPerfectSize()
            return true
        }
        if let binding = ShortcutBinding.make(key: characters,
                                              command: flags.contains(.command),
                                              control: flags.contains(.control),
                                              shift: flags.contains(.shift),
                                              alt: flags.contains(.option)),
           let action = transport.shortcuts.action(for: binding) {
            perform(action)
            return true
        }
        if flags == [.command, .option], key == "k", !transport.mapping.editing {
            if transport.mapping.scheme.isEmpty {
                onStatusNotice(t("当前没有已保存的键位方案", "No saved key mapping", language))
            } else {
                transport.mapping.enabled.toggle()
                onStatusNotice(transport.mapping.enabled
                    ? t("已启用键位 (⌥⌘K)", "Key mapping enabled (⌥⌘K)", language)
                    : t("已停用键位 (⌥⌘K)", "Key mapping disabled (⌥⌘K)", language))
            }
            return true
        }
        return false
    }

    private func perform(_ action: GameShortcutAction) {
        switch action {
        case .screenshot: transport.chooseScreenshot()
        case .fullscreen: toggleFullscreen()
        case .sidebar: toggleSidebar()
        case .overlay: toggleOverlay()
        case .advanced: transport.onAdvanced?()
        }
    }

    private func onStatusNotice(_ text: String) {
        transport.onStatus?(text)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard transport.recording == .idle else {
            transport.onStatus?(t("请先停止录屏并等待保存完成", "Stop recording and wait for it to finish saving first", transport.language))
            return false
        }
        if transport.mapping.hasUnsavedChanges {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = t("放弃未保存的键位修改？", "Discard unsaved key mapping changes?", transport.language)
            alert.informativeText = t("当前键位编辑尚未保存，关闭窗口将丢失这些修改。",
                                      "Your key mapping edits have not been saved and will be lost if you close the window.",
                                      transport.language)
            alert.addButton(withTitle: t("继续编辑", "Keep Editing", transport.language))
            let discard = alert.addButton(withTitle: t("放弃并关闭", "Discard & Close", transport.language))
            discard.hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else { return false }
            transport.mapping.cancel()
        } else if transport.mapping.editing {
            transport.mapping.cancel()
        }
        guard canClose?() ?? true else { return false }
        if stopDeviceOnClose, let onStopRequested {
            onStopRequested()
            return false
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        saveState()
        removeMonitors()
        transport.setDisplayVisible(false)
        transport.stop()
        onClose?()
        // AppKit may still be processing the close event after its delegate returns.
        DispatchQueue.main.async { [self] in _ = self }
    }

    deinit {
        if let screenChangeObserver { NotificationCenter.default.removeObserver(screenChangeObserver) }
    }
}
