// SPDX-License-Identifier: GPL-3.0-only
// Native integration for the device center: the menu bar (app/device/view/
// window/help), the Dock menu and the small CenterModel helpers those need.
// Every action goes through the existing CenterModel/palette actions, so the
// menus cannot drift from the window UI; the Device menu acts on the key
// window's device (a player window) and falls back to the center's selection.

import AppKit
import Combine
import Foundation

/// What the menus need from the app delegate (window ownership stays there).
protocol CenterWindowPresenting: AnyObject {
    var centerWindow: NSWindow? { get }
    func showCenterWindow()
}

extension CenterModel {
    /// "Open device": focus the existing window for this device (deminiaturise
    /// a minimized one) instead of opening a second window for the same device.
    func focusOrOpenDeviceWindow(_ id: String) {
        if let window = players[id]?.window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        openGame(id)
    }
}

/// Builds and validates the native menus. Owned by the app delegate; retained
/// for the life of the process.
final class CenterMenuController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private weak var model: CenterModel?
    private weak var presenter: CenterWindowPresenting?
    private var cancellables = Set<AnyCancellable>()
    private weak var deviceMenu: NSMenu?
    private weak var viewMenu: NSMenu?
    private weak var windowMenu: NSMenu?
    private weak var appearanceMenu: NSMenu?

    private enum DeviceCommand: Int {
        case open = 100
        case start
        case stop
        case restart
        case edit
        case delete
        case details
        case snapshots
        case rootTools
        case installAPK
        case sendFile
        case screenshot
        case record
    }

    init(model: CenterModel, presenter: CenterWindowPresenting) {
        self.model = model
        self.presenter = presenter
        super.init()
        // Menu titles are localized, so a language switch rebuilds the menu bar.
        model.$language
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.install() }
            .store(in: &cancellables)
    }

    private func t(_ chinese: String, _ english: String) -> String {
        model?.text(chinese, english) ?? english
    }

    // MARK: - Menu bar

    /// Installs the complete main menu (also called again on language change).
    func install() {
        let mainMenu = NSMenu(title: "Main")
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        appMenuItem.submenu = buildAppMenu()

        let editItem = NSMenuItem()
        editItem.submenu = buildEditMenu()
        mainMenu.addItem(editItem)

        let deviceItem = NSMenuItem()
        let devices = buildDeviceMenu()
        deviceMenu = devices
        deviceItem.submenu = devices
        mainMenu.addItem(deviceItem)

        let viewItem = NSMenuItem()
        let view = buildViewMenu()
        viewMenu = view
        viewItem.submenu = view
        mainMenu.addItem(viewItem)

        let windowItem = NSMenuItem()
        let window = buildWindowMenu()
        windowMenu = window
        windowItem.submenu = window
        mainMenu.addItem(windowItem)

        let helpItem = NSMenuItem()
        let help = buildHelpMenu()
        helpItem.submenu = help
        mainMenu.addItem(helpItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = window
        NSApp.helpMenu = help
    }

    private func menuItem(_ title: String, _ action: Selector, _ key: String = "",
                          target: AnyObject? = nil, modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        // Standard editing/window commands must reach the first responder.
        let responderActions: Set<String> = ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:",
                                             "performMiniaturize:", "performZoom:", "performClose:", "toggleFullScreen:"]
        item.target = responderActions.contains(NSStringFromSelector(action)) ? target : (target ?? self)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }

    private func buildAppMenu() -> NSMenu {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Jidr"
        let menu = NSMenu(title: appName)
        menu.addItem(menuItem(t("关于 Jidr", "About Jidr"),
                              #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp))
        menu.addItem(.separator())
        let services = NSMenu(title: t("服务", "Services"))
        let servicesItem = NSMenuItem(title: t("服务", "Services"), action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(menuItem(t("设置…", "Settings…"), #selector(openSettings), ","))
        menu.addItem(.separator())
        menu.addItem(menuItem(t("隐藏 Jidr", "Hide Jidr"), #selector(NSApplication.hide(_:)), "h", target: NSApp))
        menu.addItem(menuItem(t("隐藏其他", "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h",
                              target: NSApp, modifiers: [.command, .option]))
        menu.addItem(menuItem(t("显示全部", "Show All"), #selector(NSApplication.unhideAllApplications(_:)), target: NSApp))
        menu.addItem(.separator())
        menu.addItem(menuItem(t("退出 Jidr", "Quit Jidr"), #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        return menu
    }

    /// Standard editing commands; the selectors travel the responder chain to
    /// the focused field, so text inputs keep their native shortcuts.
    private func buildEditMenu() -> NSMenu {
        let menu = NSMenu(title: t("编辑", "Edit"))
        menu.addItem(menuItem(t("撤销", "Undo"), Selector(("undo:")), "z", target: nil))
        menu.addItem(menuItem(t("重做", "Redo"), Selector(("redo:")), "z", target: nil, modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(menuItem(t("剪切", "Cut"), #selector(NSText.cut(_:)), "x", target: nil))
        menu.addItem(menuItem(t("拷贝", "Copy"), #selector(NSText.copy(_:)), "c", target: nil))
        menu.addItem(menuItem(t("粘贴", "Paste"), #selector(NSText.paste(_:)), "v", target: nil))
        menu.addItem(menuItem(t("全选", "Select All"), #selector(NSText.selectAll(_:)), "a", target: nil))
        return menu
    }

    private func buildDeviceMenu() -> NSMenu {
        let menu = NSMenu(title: t("设备", "Device"))
        menu.delegate = self
        rebuildDeviceMenu(menu)
        return menu
    }

    /// The Device menu is rebuilt whenever it opens so it reflects the key
    /// window's device and the live device list.
    private func rebuildDeviceMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let keyDevice = targetDevice()
        let header = NSMenuItem(title: keyDevice.map { t("当前设备：\($0.name)", "Current device: \($0.name)") }
                                      ?? t("没有选中的设备", "No device selected"),
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(deviceMenuItem(t("打开设备窗口", "Open Device Window"), .open, ""))
        menu.addItem(deviceMenuItem(t("启动", "Start"), .start, ""))
        menu.addItem(deviceMenuItem(t("停止", "Stop"), .stop, ""))
        menu.addItem(deviceMenuItem(t("重启", "Restart"), .restart, ""))
        menu.addItem(.separator())
        menu.addItem(deviceMenuItem(t("编辑设备…", "Edit Device…"), .edit, ""))
        menu.addItem(deviceMenuItem(t("设备详情…", "Device Details…"), .details, ""))
        menu.addItem(deviceMenuItem(t("管理快照…", "Manage Snapshots…"), .snapshots, ""))
        menu.addItem(deviceMenuItem(t("Root 工具", "Root Tools"), .rootTools, ""))
        menu.addItem(.separator())
        menu.addItem(deviceMenuItem(t("安装 APK…", "Install APK…"), .installAPK, ""))
        menu.addItem(deviceMenuItem(t("发送文件…", "Send File…"), .sendFile, ""))
        menu.addItem(deviceMenuItem(t("截图", "Screenshot"), .screenshot, ""))
        menu.addItem(deviceMenuItem(t("录屏", "Record Screen"), .record, ""))
        menu.addItem(.separator())
        menu.addItem(deviceMenuItem(t("删除设备…", "Delete Device…"), .delete, ""))
        menu.addItem(.separator())
        let newDevice = menuItem(t("新建设备…", "New Device…"), #selector(newDeviceAction), "n")
        menu.addItem(newDevice)
    }

    private func deviceMenuItem(_ title: String, _ command: DeviceCommand, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(deviceAction(_:)), keyEquivalent: key)
        item.tag = command.rawValue
        item.target = self
        if !key.isEmpty { item.keyEquivalentModifierMask = [.command] }
        return item
    }

    private func buildViewMenu() -> NSMenu {
        let menu = NSMenu(title: t("视图", "View"))
        menu.addItem(menuItem(t("命令面板…", "Command Palette…"), #selector(openPaletteAction), "k"))
        menu.addItem(menuItem(t("后台任务…", "Background Tasks…"), #selector(openTasksAction), "j"))
        menu.addItem(menuItem(t("刷新设备", "Refresh Devices"), #selector(refreshDevicesAction), "r"))
        menu.addItem(.separator())
        let appearance = NSMenu(title: t("外观", "Appearance"))
        for (tag, title) in [(0, t("跟随系统", "System")), (1, t("浅色", "Light")), (2, t("深色", "Dark"))] {
            let item = NSMenuItem(title: title, action: #selector(appearanceAction(_:)), keyEquivalent: "")
            item.tag = tag
            item.target = self
            appearance.addItem(item)
        }
        appearanceMenu = appearance
        let appearanceItem = NSMenuItem(title: t("外观", "Appearance"), action: nil, keyEquivalent: "")
        appearanceItem.submenu = appearance
        menu.addItem(appearanceItem)
        menu.addItem(.separator())
        menu.addItem(menuItem(t("显示/隐藏设备检查器", "Show/Hide Device Inspector"), #selector(toggleCenterDetails), ""))
        menu.addItem(menuItem(t("搜索设备", "Search Devices"), #selector(focusDeviceSearch), "f"))
        menu.addItem(menuItem(t("显示/隐藏侧边栏", "Show/Hide Sidebar"), #selector(toggleSidebarAction), ""))
        menu.addItem(.separator())
        menu.addItem(menuItem(t("进入全屏", "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f",
                              target: nil, modifiers: [.control, .command]))
        return menu
    }

    private func buildWindowMenu() -> NSMenu {
        let menu = NSMenu(title: t("窗口", "Window"))
        menu.addItem(menuItem(t("最小化", "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m", target: nil))
        menu.addItem(menuItem(t("缩放", "Zoom"), #selector(NSWindow.performZoom(_:)), "", target: nil))
        menu.addItem(.separator())
        menu.addItem(menuItem(t("关闭窗口", "Close Window"), #selector(NSWindow.performClose(_:)), "w", target: nil))
        menu.addItem(.separator())
        menu.addItem(menuItem(t("前置全部窗口", "Bring All to Front"),
                              #selector(NSApplication.arrangeInFront(_:)), target: NSApp))
        return menu
    }

    private func buildHelpMenu() -> NSMenu {
        let menu = NSMenu(title: t("帮助", "Help"))
        menu.addItem(menuItem(t("Jidr 文档", "Jidr Documentation"), #selector(openDocumentation)))
        menu.addItem(menuItem(t("GitHub 仓库", "GitHub Repository"), #selector(openRepository)))
        menu.addItem(menuItem(t("报告问题…", "Report an Issue…"), #selector(openIssues)))
        return menu
    }

    // MARK: - Dock menu

    /// Right-click Dock menu: open the center, common actions and one entry per
    /// device (running devices first) that focuses or opens its window.
    func dockMenu() -> NSMenu? {
        guard let model else { return nil }
        let menu = NSMenu(title: t("Jidr", "Jidr"))
        menu.addItem(menuItem(t("打开设备中心", "Open Device Center"), #selector(openCenterAction)))
        menu.addItem(menuItem(t("命令面板", "Command Palette"), #selector(openPaletteAction)))
        menu.addItem(menuItem(t("后台任务", "Background Tasks"), #selector(openTasksAction)))
        menu.addItem(menuItem(t("新建设备", "New Device"), #selector(newDeviceAction)))
        guard !model.devices.isEmpty else { return menu }
        menu.addItem(.separator())
        let ordered = model.devices.sorted { lhs, rhs in
            if lhs.running != rhs.running { return lhs.running }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        for device in ordered.prefix(6) {
            let title = (device.running ? "● " : "") + device.name
            let item = NSMenuItem(title: title, action: #selector(openDockDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.id
            menu.addItem(item)
        }
        return menu
    }

    // MARK: - Key window context

    /// The device a menu command applies to: the key player window's device,
    /// else the center's selected device.
    func targetDevice() -> Device? { targetDevice(for: NSApp.keyWindow) }

    /// The same rule with an explicit window, so the key-window mapping can be
    /// exercised without relying on the app being active.
    func targetDevice(for window: NSWindow?) -> Device? {
        guard let model else { return nil }
        if let window, let id = playerDeviceID(for: window) {
            return model.devices.first { $0.id == id }
        }
        return model.devices.first { $0.id == model.selected }
    }

    /// The player window for `window`, when it is one.
    func player(for window: NSWindow?) -> GameWindowController? {
        guard let window else { return nil }
        return model?.players.first { $0.value.window === window }?.value
    }

    private func playerDeviceID(for window: NSWindow) -> String? {
        model?.players.first { $0.value.window === window }?.key
    }

    private func keyPlayer() -> GameWindowController? { player(for: NSApp.keyWindow) }

    private func showCenter() {
        presenter?.showCenterWindow()
    }

    // MARK: - Actions

    @objc private func openSettings() {
        showCenter()
        model?.runPaletteAction(.settings)
    }
    @objc private func openCenterAction() { showCenter() }
    @objc private func openPaletteAction() {
        guard model?.sheet == nil else { return }
        showCenter()
        model?.openPalette()
    }
    @objc private func openTasksAction() {
        guard model?.sheet == nil else { return }
        showCenter()
        model?.openTasks()
    }
    @objc private func newDeviceAction() {
        showCenter()
        model?.runPaletteAction(.newDevice)
    }
    @objc private func refreshDevicesAction() {
        model?.refresh()
        model?.refreshJobs()
    }
    @objc private func toggleCenterDetails() { showCenter(); model?.detailsVisible.toggle() }
    @objc private func focusDeviceSearch() { showCenter(); model?.hidePalette(); model?.searchFocusRequest += 1 }
    @objc private func toggleSidebarAction() {
        keyPlayer()?.toggleSidebarFromMenu()
    }
    @objc private func appearanceAction(_ sender: NSMenuItem) {
        model?.setPreference("appearance", sender.tag)
    }
    @objc private func openDocumentation() {
        open(URL(string: "https://github.com/hbdzh/JIdr-plus/tree/master/docs"))
    }
    @objc private func openRepository() {
        open(URL(string: "https://github.com/hbdzh/JIdr-plus"))
    }
    @objc private func openIssues() {
        open(URL(string: "https://github.com/hbdzh/JIdr-plus/issues/new"))
    }
    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    private func run(_ command: DeviceCommand, device: Device) {
        switch command {
        case .open:
            showCenter()
            model?.focusOrOpenDeviceWindow(device.id)
        case .start:
            model?.runPaletteAction(.startDevice(device.id))
        case .stop:
            model?.runPaletteAction(.stopDevice(device.id))
        case .restart:
            model?.runPaletteAction(.restartDevice(device.id))
        case .edit:
            showCenter()
            model?.runPaletteAction(.editDevice(device.id))
        case .delete:
            showCenter()
            model?.runPaletteAction(.deleteDevice(device.id))
        case .details:
            showCenter()
            model?.runPaletteAction(.deviceDetails(device.id))
        case .snapshots:
            showCenter()
            model?.runPaletteAction(.snapshots(device.id))
        case .rootTools:
            model?.runPaletteAction(.rootTools(device.id))
        case .installAPK:
            model?.runPaletteAction(.installAPK(device.id))
        case .sendFile:
            model?.runPaletteAction(.sendFile(device.id))
        case .screenshot:
            model?.runPaletteAction(.screenshot(device.id))
        case .record:
            model?.runPaletteAction(.record(device.id))
        }
    }

    @objc private func deviceAction(_ sender: NSMenuItem) {
        guard let command = DeviceCommand(rawValue: sender.tag), let device = targetDevice() else { return }
        run(command, device: device)
    }

    @objc private func openDockDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        showCenter()
        model?.focusOrOpenDeviceWindow(id)
    }

    // MARK: - Validation

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === deviceMenu { rebuildDeviceMenu(menu) }
        if menu === appearanceMenu {
            for entry in menu.items { entry.state = (model?.appearance == entry.tag) ? .on : .off }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let model else { return false }
        // Overlays stay behind a modal sheet; disabling them keeps the key
        // equivalent from opening a window the user cannot see.
        if item.action == #selector(openPaletteAction) || item.action == #selector(openTasksAction) {
            return model.sheet == nil
        }
        if item.action == #selector(appearanceAction(_:)) { item.state = model.appearance == item.tag ? .on : .off; return true }
        if item.action == #selector(toggleSidebarAction) {
            guard let player = keyPlayer() else { return false }
            item.title = player.sidebarVisible ? t("隐藏侧边栏", "Hide Sidebar") : t("显示侧边栏", "Show Sidebar")
            return true
        }
        if item.action == #selector(deviceAction(_:)) {
            guard let command = DeviceCommand(rawValue: item.tag), let device = targetDevice() else { return false }
            switch command {
            case .open, .details, .snapshots: return true
            case .start: return device.stopped
            case .stop: return !device.stopped
            case .restart: return device.running
            case .edit, .delete: return device.stopped
            case .rootTools, .installAPK, .sendFile, .screenshot, .record: return device.running
            }
        }
        return true
    }
}
