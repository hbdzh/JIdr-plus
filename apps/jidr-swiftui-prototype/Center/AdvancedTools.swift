// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import MapKit
import SwiftUI
import UniformTypeIdentifiers

final class AdvancedToolsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    init(model: CenterModel, id: String, name: String, root: Bool) {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:680,height:570), styleMask:[.titled,.closable,.miniaturizable,.resizable], backing:.buffered, defer:false)
        super.init(window:window)
        window.title = model.text("高级工具 — \(name)", "Advanced tools — \(name)")
        window.contentView = NSHostingView(rootView:AdvancedToolsView(model:model,id:id,initialRoot:root))
        window.minSize = NSSize(width:600,height:480)
        window.isReleasedWhenClosed = false
        window.delegate = self
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
    @State private var certs: [[String:Any]] = []
    @State private var props: [String:String] = [:]
    @State private var propsLoaded = false
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
    private var fullRoot: Bool { model.devices.first(where:{$0.id == id})?.root.mode == "magisk" }
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
    private func loadBattery() { call("battery.get") { value in
        guard let d = value as? [String:Any], let n = d["level"] as? Int, let c = d["charger"] as? String else { message = t("电池状态格式无效。", "Invalid battery response."); return }
        level = String(n); charger = c; batteryLoaded = true
    } }
    private func loadNetwork() { call("network.get") { value in
        guard let d = value as? [String:Any], let w = d["wifi"] as? Bool, let m = d["mobile"] as? Bool else { message = t("网络状态格式无效。", "Invalid network response."); return }
        wifi = w; mobile = m; networkLoaded = true
    } }
    private func loadProps() { call("device.props.get") { value in
        guard let d = value as? [String:Any], let p = d["props"] as? [String:Any] else { message = t("设备属性格式无效。", "Invalid device properties."); return }
        props = p.reduce(into:[:]) { result, item in if let value = item.value as? String { result[item.key] = value } }; propsLoaded = true
    } }
    private func loadCerts() { call("root.cacert.list") { value in
        guard let d = value as? [String:Any], let entries = d["certs"] as? [[String:Any]] else { message = t("证书列表格式无效。", "Invalid certificate list."); return }; certs = entries
    } }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(t("环境模拟", "Simulation")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 4)
                JidrNavigationItem(title:t("电池", "Battery"), symbol:"battery.100", selected:tab == 0) { tab = 0 }
                JidrNavigationItem(title:"GPS", symbol:"location", selected:tab == 1) { tab = 1 }
                JidrNavigationItem(title:t("网络与传感器", "Network"), symbol:"network", selected:tab == 2) { tab = 2 }
                Text(t("开发与调试", "Development")).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 18).padding(.bottom, 4)
                JidrNavigationItem(title:"Logcat", symbol:"text.alignleft", selected:tab == 3) { tab = 3 }
                JidrNavigationItem(title:t("Root 管理", "Root"), symbol:"key", selected:tab == 4) { tab = 4 }
                JidrNavigationItem(title:t("更多", "More"), symbol:"ellipsis.circle", selected:tab == 5) { tab = 5 }
                Spacer()
            }.padding(12).frame(width: 175).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            VStack(alignment:.leading, spacing:14) {
            Text([t("电池", "Battery"), "GPS", t("网络与传感器", "Network & sensors"), "Logcat", t("Root 管理", "Root"), t("更多工具", "More tools")][tab]).font(.title2.weight(.semibold))
            Text([t("模拟设备电量与充电状态。", "Simulate charge and charging state."),
                  t("设置位置或回放路线。", "Set a location or play a route."),
                  t("控制网络连接、代理和传感器。", "Control connectivity, proxy and sensors."),
                  t("查看并筛选设备日志。", "View and filter device logs."),
                  t("管理 Root、证书和系统属性。", "Manage root, certificates and system properties."),
                  t("使用电话、剪贴板和调试工具。", "Use phone, clipboard and debugging tools.")][tab])
                .font(.callout).foregroundStyle(.secondary)
            if !running { Label(t("设备未运行，请启动设备后使用这些工具。", "Start the device to use these tools."), systemImage:"info.circle").font(.callout).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    switch tab {
                    case 0: battery
                    case 1: gps
                    case 2: networkAndSensors
                    case 3: logs
                    case 4: rootTools
                    default: additionalTools
                    }
                }.frame(maxWidth: .infinity, alignment:.leading)
            }.disabled(!running || working)
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }.padding(24).frame(maxWidth:.infinity, maxHeight:.infinity, alignment:.topLeading)
        }
        .environment(\.locale,Locale(identifier:model.language == 0 ? "en" : "zh-Hans"))
        .onChange(of:tab) { _, value in if value != 3 { stopLogStream() } }
        .onChange(of:running) { _, value in if !value { stopLogStream() } }
        .onChange(of:logStream.active) { _, active in if !active { followLog = false } }
        .onDisappear { stopLogStream() }
        .alert(item:$pending) { action in
            Alert(title:Text(action.title), message:Text(action.detail), primaryButton:.destructive(Text(t("继续", "Continue"))) {
                call(action.method, action.params) { _ in
                    model.refresh()
                    if ["root.module.install", "root.cacert.install", "root.cacert.remove"].contains(action.method) { model.reconnectAfterRestart(id) }
                    if action.method == "root.cacert.remove" { certs.removeAll() }
                }
            }, secondaryButton:.cancel(Text(t("取消", "Cancel"))))
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
        VStack(alignment:.leading,spacing:12) {
            HStack { Text(t("电池状态", "Battery status")).font(.headline); Spacer(); Button(t("读取状态", "Read status"),action:loadBattery) }
            Divider()
            Grid(alignment:.leading, horizontalSpacing:24, verticalSpacing:14) {
                GridRow { Text(t("电量（0–100）", "Charge (0–100)")).foregroundStyle(.secondary); TextField("%",text:$level).frame(width:150) }
                GridRow { Text(t("充电方式", "Charger")).foregroundStyle(.secondary); Picker("",selection:$charger) { Text(t("未连接", "None")).tag("none"); Text("AC").tag("ac"); Text("USB").tag("usb"); Text(t("无线", "Wireless")).tag("wireless") }.labelsHidden().frame(width:150, alignment:.leading) }
            }
            Button(t("应用", "Apply")) {
                guard let n = Int(level), (0...100).contains(n) else { message = t("电量必须为 0–100 的整数。", "Charge must be an integer from 0 to 100."); return }
                call("battery.set",["level":n,"charger":charger])
            }.buttonStyle(.borderedProminent).disabled(!batteryLoaded)
        }.frame(maxWidth:480, alignment:.leading)
    }
    private var gps: some View {
        VStack(alignment:.leading,spacing:12) {
            Button(t("读取当前位置", "Read current location")) { call("gps.get") { value in if let d = value as? [String:Any], let a = d["latitude"] as? Double, let o = d["longitude"] as? Double { lat = String(a); lon = String(o) } } }
            HStack { TextField(t("纬度", "Latitude"),text:$lat); TextField(t("经度", "Longitude"),text:$lon) }
            HStack(spacing:8) {
                Button(t("设置位置", "Set location")) {
                    guard let a = Double(lat), a.isFinite, (-90...90).contains(a), let o = Double(lon), o.isFinite, (-180...180).contains(o) else { message = t("请输入有效的经纬度。", "Enter valid latitude and longitude."); return }
                    call("gps.set",["latitude":a,"longitude":o])
                }.buttonStyle(.borderedProminent)
                Button(t("显示地图", "Show map")) { showingMap = true }
                    .sheet(isPresented:$showingMap) { VStack(spacing:0) { LocationMapView(latitude:Double(lat) ?? 0, longitude:Double(lon) ?? 0, tileURL:model.tileURL); if model.tileURL.isEmpty { Text("© OpenStreetMap contributors").font(.caption) } }.frame(width:640,height:450) }
            }
            Divider(); Text(t("路线回放", "Route playback")).font(.headline)
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
        VStack(alignment:.leading,spacing:12) {
            Button(t("读取网络状态", "Read network status"),action:loadNetwork)
            HStack { Toggle("Wi-Fi",isOn:$wifi); Toggle(t("移动数据", "Mobile data"),isOn:$mobile) }
            Picker(t("网络速度", "Network speed"),selection:$profile) { ForEach(["full","lte","hsdpa","umts","edge","gprs","gsm"],id:\.self) { Text($0).tag($0) } }
            HStack {
                Button(t("应用网络开关", "Apply network switches")) { call("network.set",["wifi":wifi,"mobile":mobile]) }.disabled(!networkLoaded)
                Button(t("应用网络速度", "Apply speed")) { call("network.set",["profile":profile]) }
            }
            Divider(); Text(t("设备 HTTP 代理", "Device HTTP proxy")).font(.headline)
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
            Divider(); Text(t("传感器", "Sensors")).font(.headline)
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
        VStack(alignment:.leading,spacing:10) {
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
                    .onChange(of:followLog) { _, enabled in
                        if enabled {
                            logStream.start(executable:model.centerExecutable,device:id,filters:LogFilter.arguments(filter,level:logLevel))
                            if !logStream.active { followLog = false }
                        } else { stopLogStream() }
                    }
                if logLoading { ProgressView().controlSize(.small) }
            }
            if let streamError = logStream.error {
                Text(model.language == 0 ? "Log stream ended or lost messages. Restart it to try again." : streamError)
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollViewReader { reader in
                ScrollView {
                    let displayed = followLog ? logStream.text : log
                    if displayed.isEmpty {
                        Label(t("点击刷新读取设备日志。", "Refresh to load device logs."), systemImage:"text.alignleft")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth:.infinity, minHeight:220)
                    } else {
                        Text(displayed).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                            .frame(maxWidth:.infinity,alignment:.leading).padding(12)
                    }
                    Color.clear.frame(height:1).id("log-end")
                }.onChange(of:logStream.revision) { _, _ in if followLog { reader.scrollTo("log-end",anchor:.bottom) } }
            }.frame(minHeight:280)
                .background(Color(nsColor:.textBackgroundColor), in:RoundedRectangle(cornerRadius:8))
                .overlay(RoundedRectangle(cornerRadius:8).strokeBorder(Color.secondary.opacity(0.15)))
        }
    }
    private var additionalTools: some View {
        VStack(alignment:.leading,spacing:12) {
            Text(t("模拟电话与短信", "Simulated calls and SMS")).font(.headline)
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
            Divider(); Text(t("设备剪贴板", "Device clipboard")).font(.headline)
            TextField(t("剪贴板内容", "Clipboard text"),text:$clipboard)
            HStack {
                Button(t("读取", "Read")) { call("clipboard.get") { value in if let data = value as? [String:Any], let text = data["text"] as? String { clipboard = text } } }
                Button(t("写入设备", "Send to device")) { call("clipboard.set",["text":clipboard]) }
            }
            Divider(); Text(t("指纹", "Fingerprint")).font(.headline)
            HStack {
                Button(t("已注册手指", "Enrolled finger")) { call("fingerprint.touch",["finger":1]) }
                Button(t("未注册手指", "Other finger")) { call("fingerprint.touch",["finger":9]) }
                Button(t("抬起", "Lift")) { call("fingerprint.remove") }
            }
            Text(t("需先在 Android 安全设置中注册指纹。", "Enroll a fingerprint in Android security settings first.")).font(.caption).foregroundStyle(.secondary)
            Divider(); HStack { Text(t("开发者选项", "Developer options")).font(.headline); Spacer(); Button(t("读取", "Read")) { loadDeveloper() } }
            Toggle(t("显示触摸", "Show taps"),isOn:$showTaps).disabled(!developerLoaded)
            Toggle(t("指针位置", "Pointer location"),isOn:$pointer).disabled(!developerLoaded)
            Toggle(t("布局边界", "Layout bounds"),isOn:$layoutBounds).disabled(!developerLoaded)
            Picker(t("动画倍率", "Animation scale"),selection:$animation) { ForEach([0.0,0.5,1.0,1.5,2.0,5.0,10.0],id:\.self) { Text(String($0)).tag($0) } }.disabled(!developerLoaded)
            Button(t("应用开发者选项", "Apply developer options")) { call("dev.set",["show_taps":showTaps,"pointer_location":pointer,"layout_bounds":layoutBounds,"animation_scale":animation]) }.disabled(!developerLoaded)
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
    private var rootTools: some View {
        VStack(alignment:.leading,spacing:12) {
            if !fullRoot { Text(t("以下功能需要完整 Root（Magisk）。", "These tools require Full root (Magisk).")) }
            Group {
                Button(t("安装 Magisk 模块…", "Install Magisk module…")) { choose(["zip"]) { url in pending = PendingAction(title:t("安装模块？", "Install module?"),detail:t("将安装 \(url.lastPathComponent) 并重启设备。请先保存游戏进度。", "Install \(url.lastPathComponent) and reboot the device. Save your game first."),method:"root.module.install",params:["path":url.path]) } }
                HStack {
                    Button(t("启用自动授权…", "Enable automatic grants…")) { pending = PendingAction(title:t("启用自动 Root 授权？", "Enable automatic root grants?"),detail:t("所有应用都将无需询问获得 Root 权限。", "All apps will receive root access without prompting."),method:"root.auto_grant",params:["enabled":true]) }
                    Button(t("关闭自动授权", "Disable automatic grants")) { call("root.auto_grant",["enabled":false]) }
                }
                Button(t("在 Magisk 中管理模块", "Manage modules in Magisk")) {
                    call("app.launch",["package":"com.topjohnwu.magisk"]) { _ in model.openGame(id) }
                }
                Text(t("卸载模块请在 Magisk 应用中操作，然后重启设备。", "Remove modules in the Magisk app, then restart the device.")).font(.caption).foregroundStyle(.secondary)
                Divider(); HStack { Text(t("系统 CA 证书", "System CA certificates")).font(.headline); Spacer(); Button(t("刷新", "Refresh"),action:loadCerts); Button(t("验证", "Verify")) { call("root.cacert.verify") } }
                ForEach(certs.indices,id:\.self) { i in
                    HStack { Text((certs[i]["subject"] as? String) ?? (certs[i]["file"] as? String) ?? "—").lineLimit(1); Spacer()
                        if let file = certs[i]["file"] as? String { Button(t("移除…", "Remove…")) { pending = PendingAction(title:t("移除证书？", "Remove certificate?"),detail:t("将移除 \(file) 并重启设备。", "Remove \(file) and reboot the device."),method:"root.cacert.remove",params:["cert":file]) } }
                    }
                }
                Button(t("安装 CA 证书…", "Install CA certificate…")) { choose(["pem","crt","cer","der"]) { url in pending = PendingAction(title:t("信任此证书？", "Trust this certificate?"),detail:t("将信任 \(url.lastPathComponent) 并重启设备。", "Trust \(url.lastPathComponent) and reboot the device."),method:"root.cacert.install",params:["path":url.path]) } }
                Divider(); HStack { Text(t("设备属性", "Device properties")).font(.headline); Spacer(); Button(t("读取属性", "Read properties"),action:loadProps) }
                ForEach(["model","brand","manufacturer","device","fingerprint","security_patch"],id:\.self) { field in TextField(field,text:Binding(get:{props[field] ?? ""},set:{props[field] = $0})).disabled(!propsLoaded) }
                Text(t("空值使用系统默认值；修改后需要冷启动。", "Empty values use the system defaults; changes require a cold boot.")).font(.caption).foregroundStyle(.secondary)
                Button(t("保存设备属性…", "Save properties…")) { pending = PendingAction(title:t("保存设备属性？", "Save device properties?"),detail:t("下一次启动将冷启动，请先保存游戏进度。", "The next start will be a cold boot. Save your game first."),method:"device.props.set",params:["props":props]) }.disabled(!propsLoaded)
            }.disabled(!fullRoot)
        }
    }
}

struct LocationMapView: NSViewRepresentable {
    let latitude: Double
    let longitude: Double
    let tileURL: String
    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay:tiles) }
            return MKOverlayRenderer(overlay:overlay)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView(); map.delegate = context.coordinator
        let template = tileURL.isEmpty ? "https://tile.openstreetmap.org/{z}/{x}/{y}.png" : tileURL
        let overlay = MKTileOverlay(urlTemplate:template); overlay.canReplaceMapContent = true
        map.addOverlay(overlay,level:.aboveLabels)
        let coordinate = CLLocationCoordinate2D(latitude:latitude,longitude:longitude)
        map.setRegion(MKCoordinateRegion(center:coordinate,latitudinalMeters:10000,longitudinalMeters:10000),animated:false)
        let pin = MKPointAnnotation(); pin.coordinate = coordinate; map.addAnnotation(pin)
        return map
    }
    func updateNSView(_ map: MKMapView, context: Context) { }
}
