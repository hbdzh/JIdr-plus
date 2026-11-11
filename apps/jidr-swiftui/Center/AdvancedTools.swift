// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import MapKit
import SwiftUI
import UniformTypeIdentifiers

final class AdvancedToolsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private var appearanceSubscription: AnyCancellable?
    init(model: CenterModel, id: String, name: String, root: Bool) {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:600), styleMask:[.titled,.closable,.miniaturizable,.resizable], backing:.buffered, defer:false)
        super.init(window:window)
        window.title = model.text("高级工具 — \(name)", "Advanced tools — \(name)")
        window.contentView = NSHostingView(rootView:AdvancedToolsView(model:model,id:id,initialRoot:root))
        window.minSize = NSSize(width:680,height:480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.appearance = model.windowAppearance
        appearanceSubscription = model.$appearance.sink { [weak window] value in
            window?.appearance = value == 0 ? nil : NSAppearance(named: value == 2 ? .darkAqua : .aqua)
        }
        window.center()
    }
    required init?(coder: NSCoder) { return nil }
    func windowWillClose(_ notification: Notification) {
        let keepAlive = self
        onClose?()
        DispatchQueue.main.async { _ = keepAlive }
    }
}

struct AdvancedToolsView: View {
    @ObservedObject var model: CenterModel
    let id: String
    @State private var tab: Int
    @State private var working = false
    @State private var message = ""
    @State private var level = ""
    @State private var charger = "none"
    @State private var batteryLoaded = false
    @State private var lat = ""
    @State private var lon = ""
    @State private var wifi = false
    @State private var mobile = false
    @State private var networkLoaded = false
    @State private var profile = "full"
    @State private var proxyHost = ""
    @State private var proxyPort = ""
    @State private var sensor = "acceleration"
    @State private var values = ""
    @State private var log = ""
    @State private var filter = ""
    @State private var logLevel = ""
    @State private var followLog = false
    @State private var logLoading = false
    @StateObject private var logStream = LogStream()
    @State private var phoneNumber = ""
    @State private var smsText = ""
    @State private var signal = 4
    @State private var clipboard = ""
    @State private var showTaps = false
    @State private var pointer = false
    @State private var layoutBounds = false
    @State private var animation = 1.0
    @State private var developerLoaded = false
    @State private var cameraBack = "emulated"
    @State private var cameraFront = "emulated"
    @State private var cameraLoaded = false
    @State private var cameraCurrent = ""
    @State private var pending: PendingAction?
    @State private var showingMap = false
    @State private var routePath = ""
    @State private var routeSpeed = "1"
    @State private var routeLoop = false
    @State private var routeRunning = false
    struct PendingAction: Identifiable { let id = UUID(); let title: String; let detail: String; let method: String; let params: [String:Any] }
    init(model: CenterModel,id: String,initialRoot: Bool) { self.model = model; self.id = id; _tab = State(initialValue:initialRoot ? 4 : 0) }
    private func t(_ zh:String,_ en:String) -> String { model.text(zh,en) }
    private var running: Bool { model.devices.first(where:{$0.id == id})?.running == true }
    private func call(_ method:String,_ params:[String:Any] = [:], complete: ((Any) -> Void)? = nil) {
        guard !working else { return }
        working = true; message = t("处理中…", "Working…")
        var args = params; args["device"] = id
        model.call(method,args) { result in
            working = false
            switch result {
            case .success(let value): message = t("操作完成。", "Completed."); complete?(value)
            case .failure(let error): message = OperationMessages.error(error.localizedDescription,language:model.language)
            }
        }
    }
    private func choose(_ types:[String], done:(URL)->Void) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = types.compactMap { UTType(filenameExtension:$0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }; done(url)
    }
    private func loadInitialState() {
        guard running else { return }
        if tab == 0, !batteryLoaded { loadBattery() }
        if tab == 2, !networkLoaded { loadNetwork() }
    }
    private func loadBattery() { call("battery.get") { value in
        guard let d = value as? [String:Any], let n = d["level"] as? Int, let c = d["charger"] as? String else { message = t("电池状态格式无效。", "Invalid battery response."); return }
        level = String(n); charger = c; batteryLoaded = true
    } }
    private func loadNetwork() { call("network.get") { value in
        guard let d = value as? [String:Any], let w = d["wifi"] as? Bool, let m = d["mobile"] as? Bool else { message = t("网络状态格式无效。", "Invalid network response."); return }
        wifi = w; mobile = m; networkLoaded = true
    } }
    var body: some View {
        HStack(spacing: WbSpace.zero) {
            navigation
            contentColumn
        }
        .preferredColorScheme(model.colorScheme)
        .background(WbColor.surface)
        .tint(WbColor.accent)
        .environment(\.locale,Locale(identifier:model.language == 0 ? "en" : "zh-Hans"))
        .onAppear { loadInitialState() }
        .onChange(of:tab) { value in
            if value != 3 { stopLogStream() }
            loadInitialState()
        }
        .onChange(of:running) { value in if !value { stopLogStream() } }
        .onChange(of:logStream.active) { active in if !active { followLog = false } }
        .onDisappear { stopLogStream() }
        .alert(item:$pending) { action in
            Alert(title:Text(action.title), message:Text(action.detail), primaryButton:.destructive(Text(t("继续", "Continue"))) {
                call(action.method, action.params) { _ in model.refresh() }
            }, secondaryButton:.cancel(Text(t("取消", "Cancel"))))
        }
    }

    // MARK: - Shell (visual layer only)

    private var tabTitles: [String] {
        [t("电池", "Battery"), "GPS", t("网络与传感器", "Network & sensors"), "Logcat",
         t("Root 管理", "Root"), t("更多工具", "More tools")]
    }

    private var tabDescriptions: [String] {
        [t("模拟设备电量与充电状态。", "Simulate charge and charging state."),
         t("设置位置或回放路线。", "Set a location or play a route."),
         t("控制网络连接、代理和传感器。", "Control connectivity, proxy and sensors."),
         t("查看并筛选设备日志。", "View and filter device logs."),
         t("管理 Root、证书和系统属性。", "Manage root, certificates and system properties."),
         t("使用电话、剪贴板和调试工具。", "Use phone, clipboard and debugging tools.")]
    }

    /// The section-driven side bar is a native sidebar List: AppKit provides the
    /// selection highlight, hover feedback, keyboard navigation and section
    /// headers. `tab` stays the single source of truth for the six tabs.
    private var tabSelection: Binding<Int?> {
        Binding(get: { tab }, set: { value in
            if let value, value != tab { tab = value }
        })
    }

    private var navigation: some View {
        List(selection: tabSelection) {
            Section(header: Text(t("环境模拟", "Simulation")).wbFont(WbType.label)
                        .foregroundStyle(WbColor.textSecondary)) {
                navigationRow(0, t("电池", "Battery"), WbIcon.battery)
                navigationRow(1, "GPS", WbIcon.location)
                navigationRow(2, t("网络与传感器", "Network"), WbIcon.network)
            }
            Section(header: Text(t("开发与调试", "Development")).wbFont(WbType.label)
                        .foregroundStyle(WbColor.textSecondary)) {
                navigationRow(3, "Logcat", WbIcon.logcat)
                navigationRow(4, t("Root 管理", "Root"), WbIcon.rootTab)
                navigationRow(5, t("更多", "More"), WbIcon.more)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 170)
        .accessibilityLabel(t("高级工具分类", "Advanced tool categories"))
    }

    private func navigationRow(_ index: Int, _ title: String, _ icon: String) -> some View {
        Label(title, systemImage: icon)
            .tag(index)
            .accessibilityLabel(title)
    }

    private var contentColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tabTitles[tab])
                .wbFont(WbType.headline)
                .foregroundStyle(WbColor.textPrimary)
            Text(tabDescriptions[tab])
                .wbFont(WbType.body).foregroundStyle(WbColor.textSecondary)
                .padding(.top, WbSpace.xxs)
            if !running {
                Label(t("设备未运行，请启动设备后使用这些工具。", "Start the device to use these tools."), systemImage:WbIcon.info)
                    .wbFont(WbType.body).foregroundStyle(WbColor.textSecondary)
                    .padding(.top, WbSpace.sm)
            }
            ScrollView {
                tabContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, WbSpace.lg)
            }
            .disabled(!running || working)
            if !message.isEmpty {
                Text(message).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
                    .textSelection(.enabled)
                    .padding(.top, WbSpace.sm)
            }
        }
        .padding(WbSpace.xl)
        .frame(maxWidth:.infinity, maxHeight:.infinity, alignment:.topLeading)
    }

    /// The tab content is flat on the utility window surface; no hand-drawn
    /// card background, border or shadow. RootDevToolsView keeps its own
    /// native grouping because it is a separate component.
    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case 0: battery
        case 1: gps
        case 2: networkAndSensors
        case 3: logs
        case 4: RootDevToolsView(model:model, id:id, running:running)
        default: additionalTools
        }
    }

    private func refreshLog() {
        guard !logLoading else { return }
        logLoading = true
        let filters = LogFilter.arguments(filter,level:logLevel)
        var args:[String:Any] = ["device":id, "lines":500]
        if !filters.isEmpty { args["filter"] = filters }
        model.call("logcat.dump",args) { result in
            logLoading = false
            switch result {
            case .success(let value):
                if let text = value as? String { log = text }
                else if let data = value as? [String:Any], let text = data["text"] as? String { log = text }
                else if let data = value as? [String:Any], let lines = data["lines"] as? [String] { log = lines.joined(separator:"\n") }
                else { log = String(describing:value) }
            case .failure(let error):
                message = OperationMessages.error(error.localizedDescription,language:model.language)
            }
        }
    }
    private func stopLogStream() {
        if logStream.active { log = logStream.text }
        followLog = false
        logStream.stop()
    }
    private var battery: some View {
        VStack(alignment:.leading,spacing:WbSpace.md) {
            HStack { Text(t("电池状态", "Battery status")).wbFont(WbType.title); Spacer(); Button(t("读取状态", "Read status"),action:loadBattery).buttonStyle(.bordered).controlSize(.regular) }
            WbDivider()
            Grid(alignment:.leading, horizontalSpacing:24, verticalSpacing:14) {
                GridRow { Text(t("电量（0–100）", "Charge (0–100)")).foregroundStyle(WbColor.textSecondary); TextField("%",text:$level).frame(width:150).accessibilityLabel(t("电量（0–100）", "Charge (0–100)")) }
                GridRow { Text(t("充电方式", "Charger")).foregroundStyle(WbColor.textSecondary); Picker("",selection:$charger) { Text(t("未连接", "None")).tag("none"); Text("AC").tag("ac"); Text("USB").tag("usb"); Text(t("无线", "Wireless")).tag("wireless") }.labelsHidden().frame(width:150, alignment:.leading).accessibilityLabel(t("充电方式", "Charger")) }
            }
            Button(t("应用", "Apply")) {
                guard let n = Int(level), (0...100).contains(n) else { message = t("电量必须为 0–100 的整数。", "Charge must be an integer from 0 to 100."); return }
                call("battery.set",["level":n,"charger":charger])
            }.buttonStyle(.borderedProminent).controlSize(.regular).tint(WbColor.accent).disabled(!batteryLoaded)
        }.frame(maxWidth:480, alignment:.leading)
    }
    private var gps: some View {
        VStack(alignment:.leading,spacing:WbSpace.md) {
            Button(t("读取当前位置", "Read current location")) { call("gps.get") { value in if let d = value as? [String:Any], let a = d["latitude"] as? Double, let o = d["longitude"] as? Double { lat = String(a); lon = String(o) } } }
            HStack { TextField(t("纬度", "Latitude"),text:$lat); TextField(t("经度", "Longitude"),text:$lon) }
            HStack(spacing:WbSpace.sm) {
                Button(t("设置位置", "Set location")) {
                    guard let a = Double(lat), a.isFinite, (-90...90).contains(a), let o = Double(lon), o.isFinite, (-180...180).contains(o) else { message = t("请输入有效的经纬度。", "Enter valid latitude and longitude."); return }
                    call("gps.set",["latitude":a,"longitude":o])
                }.buttonStyle(.borderedProminent).controlSize(.regular).tint(WbColor.accent)
                Button(t("显示地图", "Show map")) { showingMap = true }
                    .sheet(isPresented:$showingMap) {
                        GPSMapSheet(model:model, device:id, latitude:Double(lat) ?? 0, longitude:Double(lon) ?? 0, tileURL:model.tileURL) { latitude, longitude in
                            lat = String(format: "%.4f", latitude)
                            lon = String(format: "%.4f", longitude)
                            call("gps.set", ["latitude":latitude,"longitude":longitude]) { _ in
                                message = t("已设置位置：纬度 \(lat)，经度 \(lon)。", "Location set: latitude \(lat), longitude \(lon).")
                            }
                        }
                        .environment(\.locale, Locale(identifier:model.language == 0 ? "en" : "zh-Hans"))
                    }
            }
            WbDivider(); Text(t("路线回放", "Route playback")).wbFont(WbType.title)
            HStack { Button(t("选择 GPX / KML", "Choose GPX / KML")) { choose(["gpx","kml"]) { routePath = $0.path } }; Text(routePath.isEmpty ? t("未选择文件", "No file selected") : URL(fileURLWithPath:routePath).lastPathComponent).lineLimit(1) }
            HStack { Text(t("速度倍率", "Speed")); TextField("1",text:$routeSpeed).frame(width:70); Toggle(t("循环", "Loop"),isOn:$routeLoop) }
            HStack {
                Button(t("播放", "Play")) {
                    guard let speed = OperationMessages.routeSpeed(routeSpeed) else { message = t("请输入大于 0 且不超过 64 的速度倍率。", "Enter a speed greater than 0 and no greater than 64."); return }
                    routeRunning = true
                    model.call("gps.route",["device":id,"path":routePath,"speed":speed,"loop":routeLoop]) { result in
                        routeRunning = false
                        switch result { case .success: message = t("路线播放结束。", "Route playback ended."); case .failure(let error): message = OperationMessages.error(error.localizedDescription,language:model.language) }
                    }
                }.disabled(routePath.isEmpty || routeRunning)
                Button(t("暂停", "Pause")) { call("gps.route_control",["paused":true]) }.disabled(!routeRunning)
                Button(t("继续", "Resume")) { call("gps.route_control",["paused":false]) }.disabled(!routeRunning)
                Button(t("停止", "Stop")) { call("gps.route_stop") }
            }
        }
    }
    private var networkAndSensors: some View {
        VStack(alignment:.leading,spacing:WbSpace.md) {
            Button(t("读取网络状态", "Read network status"),action:loadNetwork)
            HStack { Toggle("Wi-Fi",isOn:$wifi); Toggle(t("移动数据", "Mobile data"),isOn:$mobile) }
            Picker(t("网络速度", "Network speed"),selection:$profile) { ForEach(["full","lte","hsdpa","umts","edge","gprs","gsm"],id:\.self) { Text($0).tag($0) } }
            HStack {
                Button(t("应用网络开关", "Apply network switches")) { call("network.set",["wifi":wifi,"mobile":mobile]) }.disabled(!networkLoaded)
                Button(t("应用网络速度", "Apply speed")) { call("network.set",["profile":profile]) }
            }
            WbDivider(); Text(t("设备 HTTP 代理", "Device HTTP proxy")).wbFont(WbType.title)
            HStack { TextField(t("主机", "Host"),text:$proxyHost); TextField(t("端口", "Port"),text:$proxyPort).frame(width:90) }
            HStack {
                Button(t("读取代理", "Read proxy")) { call("network.proxy.get") { value in
                    if let d = value as? [String:Any] { proxyHost = d["host"] as? String ?? ""; proxyPort = (d["port"] as? Int).map { String($0) } ?? "" }
                } }
                Button(t("设置代理", "Set proxy")) {
                    guard !proxyHost.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, let port = Int(proxyPort), (1...65535).contains(port) else { message = t("请输入有效的代理主机和端口。", "Enter a valid proxy host and port."); return }
                    call("network.proxy.set",["host":proxyHost,"port":port])
                }
                Button(t("清除代理", "Clear proxy")) { call("network.proxy.clear") { _ in proxyHost = ""; proxyPort = "" } }
            }
            WbDivider(); Text(t("传感器", "Sensors")).wbFont(WbType.title)
            Picker(t("传感器", "Sensor"),selection:$sensor) { ForEach(["acceleration","gyroscope","magnetic_field","temperature","proximity","light","pressure","humidity"],id:\.self) { Text($0).tag($0) } }
            HStack { TextField(t("数值，用逗号分隔", "Values, separated by commas"),text:$values)
                Button(t("读取", "Read")) { call("sensor.get",["sensor":sensor]) { value in if let d = value as? [String:Any], let v = d["values"] as? [Double] { values = v.map { String($0) }.joined(separator:", ") } } }
                Button(t("设置", "Set")) {
                    let numbers = values.split(separator:",").compactMap { Double($0.trimmingCharacters(in:.whitespaces)) }
                    let expected = ["acceleration","gyroscope","magnetic_field"].contains(sensor) ? 3 : 1
                    guard numbers.count == expected, numbers.allSatisfy({ $0.isFinite }), values.split(separator:",").count == expected else { message = t("传感器数值数量或格式不正确。", "Invalid sensor values or count."); return }
                    call("sensor.set",["sensor":sensor,"values":numbers])
                }
            }
        }
    }
    private var logs: some View {
        VStack(alignment:.leading,spacing:WbSpace.md) {
            HStack { TextField(t("过滤条件，例如 ActivityManager:I", "Filter, e.g. ActivityManager:I"),text:$filter).disabled(followLog)
                Button(t("刷新", "Refresh"),action:refreshLog).disabled(logLoading || followLog)
                Button(t("清除设备日志…", "Clear device log…")) { pending = PendingAction(title:t("清除日志？", "Clear log?"),detail:t("设备上的日志会被清除。", "The device log will be cleared."),method:"logcat.clear",params:[:]) }
            }
            HStack {
                Picker(t("级别", "Level"),selection:$logLevel) {
                    Text(t("全部", "All")).tag("")
                    ForEach(["V", "D", "I", "W", "E", "F"], id:\.self) { Text($0).tag($0) }
                }.fixedSize().disabled(followLog)
                Toggle(t("实时跟随", "Follow live"),isOn:$followLog)
                    .onChange(of:followLog) { enabled in
                        if enabled {
                            logStream.start(executable:model.centerExecutable,device:id,filters:LogFilter.arguments(filter,level:logLevel))
                            if !logStream.active { followLog = false }
                        } else { stopLogStream() }
                    }
                if logLoading { ProgressView().controlSize(.small) }
            }
            if let streamError = logStream.error {
                Text(model.language == 0 ? "Log stream ended or lost messages. Restart it to try again." : streamError)
                    .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
            }
            ScrollViewReader { reader in
                ScrollView {
                    let displayed = followLog ? logStream.text : log
                    if displayed.isEmpty {
                        Label(t("点击刷新读取设备日志。", "Refresh to load device logs."), systemImage:WbIcon.logcat)
                            .wbFont(WbType.body).foregroundStyle(WbColor.textSecondary)
                            .frame(maxWidth:.infinity, minHeight:220)
                    } else {
                        Text(displayed).wbFont(WbType.code).textSelection(.enabled)
                            .frame(maxWidth:.infinity,alignment:.leading).padding(WbSpace.md)
                    }
                    Color.clear.frame(height:1).id("log-end")
                }.onChange(of:logStream.revision) { _ in if followLog { reader.scrollTo("log-end",anchor:.bottom) } }
            }.frame(minHeight:280)
                .background(WbColor.sunken, in:RoundedRectangle(cornerRadius: WbRadius.md))
        }
    }
    private var additionalTools: some View {
        VStack(alignment:.leading,spacing:WbSpace.md) {
            Text(t("模拟电话与短信", "Simulated calls and SMS")).wbFont(WbType.title)
            TextField(t("号码", "Phone number"),text:$phoneNumber)
            HStack {
                ForEach([("来电", "Incoming", "incoming"), ("接听", "Accept", "accept"), ("挂断", "End", "end")],id:\.2) { zh, en, action in
                    Button(t(zh,en)) { call("phone.call",["number":phoneNumber,"action":action]) }.disabled(phoneNumber.isEmpty)
                }
            }
            HStack { TextField(t("短信内容", "SMS text"),text:$smsText)
                Button(t("模拟接收", "Simulate receipt")) { call("phone.sms",["from":phoneNumber,"text":smsText]) }.disabled(phoneNumber.isEmpty || smsText.isEmpty)
            }
            HStack { Stepper(t("信号：\(signal) 格", "Signal: \(signal) bars"),value:$signal,in:0...4)
                Button(t("设置信号", "Set signal")) { call("phone.gsm",["signal":signal]) }
            }
            WbDivider(); Text(t("设备剪贴板", "Device clipboard")).wbFont(WbType.title)
            TextField(t("剪贴板内容", "Clipboard text"),text:$clipboard)
            HStack {
                Button(t("读取", "Read")) { call("clipboard.get") { value in if let data = value as? [String:Any], let text = data["text"] as? String { clipboard = text } } }
                Button(t("写入设备", "Send to device")) { call("clipboard.set",["text":clipboard]) }
            }
            WbDivider(); Text(t("指纹", "Fingerprint")).wbFont(WbType.title)
            HStack {
                Button(t("已注册手指", "Enrolled finger")) { call("fingerprint.touch",["finger":1]) }
                Button(t("未注册手指", "Other finger")) { call("fingerprint.touch",["finger":9]) }
                Button(t("抬起", "Lift")) { call("fingerprint.remove") }
            }
            Text(t("需先在 Android 安全设置中注册指纹。", "Enroll a fingerprint in Android security settings first.")).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
            WbDivider(); Text(t("摄像头", "Camera")).wbFont(WbType.title)
            if !cameraCurrent.isEmpty { Text(cameraCurrent).wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary) }
            HStack {
                Text(t("后置", "Back camera")).frame(width: 90, alignment: .leading).foregroundStyle(WbColor.textSecondary)
                Picker("", selection: $cameraBack) { ForEach(cameraBackOptions, id: \.0) { value, label in Text(label).tag(value) } }
                    .labelsHidden().frame(width: 220, alignment: .leading)
            }
            HStack {
                Text(t("前置", "Front camera")).frame(width: 90, alignment: .leading).foregroundStyle(WbColor.textSecondary)
                Picker("", selection: $cameraFront) { ForEach(cameraFrontOptions, id: \.0) { value, label in Text(label).tag(value) } }
                    .labelsHidden().frame(width: 220, alignment: .leading)
            }
            HStack {
                Button(t("读取摄像头配置", "Read cameras"), action: loadCamera)
                Button(t("应用（下次启动生效）", "Apply (next start)")) { applyCamera() }
                    .buttonStyle(.borderedProminent).controlSize(.regular).tint(WbColor.accent).disabled(!cameraLoaded)
            }
            Text(t("摄像头切换在下次启动设备时生效。虚拟场景只支持后置摄像头。",
                   "Camera changes apply the next time the device starts. The virtual scene is a back camera only."))
                .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
            WbDivider(); HStack { Text(t("开发者选项", "Developer options")).wbFont(WbType.title); Spacer(); Button(t("读取", "Read")) { loadDeveloper() } }
            Toggle(t("显示触摸", "Show taps"),isOn:$showTaps).disabled(!developerLoaded)
            Toggle(t("指针位置", "Pointer location"),isOn:$pointer).disabled(!developerLoaded)
            Toggle(t("布局边界", "Layout bounds"),isOn:$layoutBounds).disabled(!developerLoaded)
            Picker(t("动画倍率", "Animation scale"),selection:$animation) { ForEach([0.0,0.5,1.0,1.5,2.0,5.0,10.0],id:\.self) { Text(String($0)).tag($0) } }.disabled(!developerLoaded)
            Button(t("应用开发者选项", "Apply developer options")) { call("dev.set",["show_taps":showTaps,"pointer_location":pointer,"layout_bounds":layoutBounds,"animation_scale":animation]) }.disabled(!developerLoaded)
        }
    }
    private var cameraBackOptions: [(String, String)] {
        [("emulated", t("模拟", "Emulated")), ("virtualscene", t("虚拟场景", "Virtual scene")),
         ("webcam0", t("Mac 摄像头 1", "Mac camera 1")), ("webcam1", t("Mac 摄像头 2", "Mac camera 2")),
         ("none", t("禁用", "None"))]
    }
    private var cameraFrontOptions: [(String, String)] {
        cameraBackOptions.filter { $0.0 != "virtualscene" }
    }
    private func cameraLabel(_ value: String) -> String {
        if value == "default" { return t("默认（未设置）", "Default (unset)") }
        return (cameraBackOptions.first(where: { $0.0 == value })?.1) ?? value
    }
    private func loadCamera() {
        call("camera.get") { value in
            guard let data = value as? [String: Any], let back = data["back"] as? String, let front = data["front"] as? String else {
                message = t("摄像头配置格式无效。", "Invalid camera response.")
                return
            }
            if cameraBackOptions.contains(where: { $0.0 == back }) { cameraBack = back }
            if cameraFrontOptions.contains(where: { $0.0 == front }) { cameraFront = front }
            cameraCurrent = t("当前：后置 \(cameraLabel(back)) · 前置 \(cameraLabel(front))",
                              "Current: back \(cameraLabel(back)) · front \(cameraLabel(front))")
            cameraLoaded = true
        }
    }
    private func applyCamera() {
        call("camera.set", ["back": cameraBack, "front": cameraFront]) { value in
            var back = cameraBack
            var front = cameraFront
            if let data = value as? [String: Any] {
                if let stored = data["back"] as? String { back = stored }
                if let stored = data["front"] as? String { front = stored }
            }
            cameraCurrent = t("当前：后置 \(cameraLabel(back)) · 前置 \(cameraLabel(front))",
                              "Current: back \(cameraLabel(back)) · front \(cameraLabel(front))")
            message = t("摄像头已保存，下次启动设备时生效。", "Camera sources saved; they apply the next time the device starts.")
        }
    }
    private func loadDeveloper() {
        call("dev.get") { value in
            guard let d = value as? [String:Any], let taps = d["show_taps"] as? Bool, let point = d["pointer_location"] as? Bool,
                  let bounds = d["layout_bounds"] as? Bool, let scale = d["animation_scale"] as? Double,
                  [0.0,0.5,1.0,1.5,2.0,5.0,10.0].contains(scale) else { message = t("开发者选项读取失败。", "Could not read developer options."); return }
            showTaps = taps; pointer = point; layoutBounds = bounds; animation = scale; developerLoaded = true
        }
    }
}

/// The GPS map sheet: shows the OSM map around the fix and turns a click on
/// the map into a latitude/longitude (crates/jidr-ui/src/widgets/gps.rs:
/// map_click, 245-259), confirmed before it is sent to the device.
struct GPSMapSheet: View {
    @ObservedObject var model: CenterModel
    let device: String
    let latitude: Double
    let longitude: Double
    let tileURL: String
    let onApply: (Double, Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pick: MapPick?
    @State private var recenter = 0

    struct MapPick: Identifiable {
        let id = UUID()
        let latitude: Double
        let longitude: Double
    }

    private func t(_ chinese: String, _ english: String) -> String { model.text(chinese, english) }

    var body: some View {
        VStack(alignment: .leading, spacing: WbSpace.md) {
            HStack {
                Text(t("在地图上选择位置", "Pick a location on the map")).wbFont(WbType.title)
                Spacer()
                Button(t("关闭", "Close")) { dismiss() }
            }
            Text(t("点击地图选择新的定位点，确认后会发送到设备。滚轮可以缩放。",
                   "Click the map to choose a new fix; it is sent to the device after you confirm. Scroll to zoom."))
                .wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary)
            LocationMapView(latitude: latitude, longitude: longitude, tileURL: tileURL, recenter: recenter) { lat, lon in
                pick = MapPick(latitude: lat, longitude: lon)
            }
            .frame(width: 620, height: 380)
            .clipShape(RoundedRectangle(cornerRadius: WbRadius.md))
            HStack(spacing: WbSpace.sm) {
                if tileURL.isEmpty { Text("© OpenStreetMap contributors").wbFont(WbType.caption).foregroundStyle(WbColor.textSecondary) }
                Spacer()
                Text(t("纬度 \(String(format: "%.4f", latitude)) · 经度 \(String(format: "%.4f", longitude))",
                       "Latitude \(String(format: "%.4f", latitude)) · longitude \(String(format: "%.4f", longitude))"))
                    .wbFont(WbType.code).foregroundStyle(WbColor.textSecondary)
            }
        }
        .padding(WbSpace.lg)
        .frame(width: 660)
        .tint(WbColor.accent)
        .alert(item: $pick) { pick in
            Alert(
                title: Text(t("设置此位置？", "Set this location?")),
                message: Text(t("纬度 \(String(format: "%.4f", pick.latitude)) · 经度 \(String(format: "%.4f", pick.longitude))\n设备的位置将立即更改。",
                                "Latitude \(String(format: "%.4f", pick.latitude)) · longitude \(String(format: "%.4f", pick.longitude))\nThe device's location changes immediately.")),
                primaryButton: .default(Text(t("设置", "Set"))) {
                    onApply(pick.latitude, pick.longitude)
                    dismiss()
                },
                secondaryButton: .cancel(Text(t("取消", "Cancel"))) {
                    recenter += 1
                })
        }
    }
}

/// The OSM map view. Tiles never mirror and the attribution stays visible
/// (D14); clicks are converted to coordinates by MapKit.
struct LocationMapView: NSViewRepresentable {
    let latitude: Double
    let longitude: Double
    let tileURL: String
    var recenter = 0
    var onPick: ((Double, Double) -> Void)?

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onPick: ((Double, Double) -> Void)?
        var pin: MKPointAnnotation?
        var lastCenter: CLLocationCoordinate2D?
        var lastRecenter = 0

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay:tiles) }
            return MKOverlayRenderer(overlay:overlay)
        }

        @objc func clicked(_ gesture: NSClickGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            let coordinate = map.convert(gesture.location(in: map), toCoordinateFrom: map)
            pin?.coordinate = coordinate
            onPick?(coordinate.latitude, coordinate.longitude)
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.onPick = onPick
        return coordinator
    }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        let template = tileURL.isEmpty ? "https://tile.openstreetmap.org/{z}/{x}/{y}.png" : tileURL
        let overlay = MKTileOverlay(urlTemplate:template)
        overlay.canReplaceMapContent = true
        map.addOverlay(overlay,level:.aboveLabels)
        let coordinate = CLLocationCoordinate2D(latitude:latitude,longitude:longitude)
        context.coordinator.lastCenter = coordinate
        map.setRegion(MKCoordinateRegion(center:coordinate,latitudinalMeters:10000,longitudinalMeters:10000),animated:false)
        let pin = MKPointAnnotation()
        pin.coordinate = coordinate
        map.addAnnotation(pin)
        context.coordinator.pin = pin
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        map.addGestureRecognizer(click)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onPick = onPick
        let coordinate = CLLocationCoordinate2D(latitude:latitude,longitude:longitude)
        let moved = coordinator.lastCenter.map {
            abs($0.latitude - coordinate.latitude) > 1e-9 || abs($0.longitude - coordinate.longitude) > 1e-9
        } ?? true
        if moved || coordinator.lastRecenter != recenter {
            coordinator.lastCenter = coordinate
            coordinator.lastRecenter = recenter
            coordinator.pin?.coordinate = coordinate
            map.setRegion(MKCoordinateRegion(center:coordinate,latitudinalMeters:10000,longitudinalMeters:10000),animated:false)
        }
    }
}
