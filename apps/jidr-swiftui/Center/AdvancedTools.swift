// SPDX-License-Identifier: GPL-3.0-only
import AppKit
import Combine
import MapKit
import SwiftUI
import UniformTypeIdentifiers

struct AdvancedToolsView: View {
    @ObservedObject var model: CenterModel
    let id: String
    @StateObject private var selection: DeviceToolsSelection
    private let onClose: () -> Void
    @State private var working = false
    @State private var reads: Set<String> = []
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
    @State private var cameraEdits = DeviceCameraEdits()
    private var cameraDirty: Bool { cameraEdits.hasChanges }
    private var cameraLoaded: Bool { cameraEdits.saved != nil }
    @State private var pending: PendingAction?
    @State private var showingMap = false
    @State private var routePath = ""
    @State private var routeSpeed = "1"
    @State private var routeLoop = false
    @State private var routePlayback = RoutePlaybackState()
    private var routeRunning: Bool { routePlayback.isRunning }
    struct PendingAction: Identifiable { let id = UUID(); let title: String; let detail: String; let method: String; let params: [String:Any] }
    init(model: CenterModel, id: String, initialRoot: Bool, initialSection: Int? = nil,
         selection: DeviceToolsSelection? = nil, onClose: @escaping () -> Void = {}) {
        self.model = model; self.id = id; self.onClose = onClose
        _selection = StateObject(wrappedValue: selection ?? DeviceToolsSelection(section: initialSection ?? (initialRoot ? 4 : 0)))
    }
    private func t(_ zh:String,_ en:String) -> String { model.text(zh,en) }
    private var running: Bool { model.devices.first(where:{$0.id == id})?.running == true }
    private func call(_ method:String,_ params:[String:Any] = [:], complete: ((Any) -> Void)? = nil) {
        guard !working else { return }
        let reading = method.hasSuffix(".get")
        working = true; message = reading ? "" : t("处理中…", "Working…")
        var args = params; args["device"] = id
        model.call(method,args) { result in
            working = false
            switch result {
            case .success(let value): message = reading ? "" : t("操作完成。", "Completed."); complete?(value)
            case .failure(let error): message = OperationMessages.error(error.localizedDescription,language:model.language)
            }
        }
    }
    private func choose(_ types:[String], done:(URL)->Void) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = types.compactMap { UTType(filenameExtension:$0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }; done(url)
    }
    private func readState(_ method: String, complete: @escaping (Any) -> Void) {
        guard !reads.contains(method) else { return }
        reads.insert(method)
        model.call(method, ["device": id]) { result in
            reads.remove(method)
            switch result {
            case .success(let value): complete(value)
            case .failure(let error): message = OperationMessages.error(error.localizedDescription, language: model.language)
            }
        }
    }
    private func loadInitialState() {
        if selection.section == 8, !cameraLoaded,
           model.devices.contains(where: { $0.id == id && ($0.stopped || $0.running) }) {
            loadCamera()
        }
        guard running else { return }
        if selection.section == 0, !batteryLoaded { loadBattery() }
        if selection.section == 2, !networkLoaded { loadNetwork() }
    }
    private func loadBattery() { readState("battery.get") { value in
        guard let d = value as? [String:Any], let n = d["level"] as? Int, let c = d["charger"] as? String else { message = t("电池状态格式无效。", "Invalid battery response."); return }
        level = String(n); charger = c; batteryLoaded = true
    } }
    private func loadNetwork() { readState("network.get") { value in
        guard let d = value as? [String:Any], let w = d["wifi"] as? Bool, let m = d["mobile"] as? Bool else { message = t("网络状态格式无效。", "Invalid network response."); return }
        wifi = w; mobile = m; networkLoaded = true
    } }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("设备工具", "Device tools")).font(.system(size: 15, weight: .medium))
                        .foregroundStyle(WbColor.textPrimary)
                    Text(model.devices.first(where: { $0.id == id })?.name ?? "—")
                        .font(.system(size: 12)).foregroundStyle(WbColor.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 10)
                navigation
                HStack(spacing: 6) {
                    Circle().fill(running ? WbColor.positive : WbColor.textTertiary).frame(width: 5, height: 5)
                    Text(model.devices.first(where: { $0.id == id })?.statusText(language: model.language) ?? "—")
                        .font(.system(size: 11)).foregroundStyle(WbColor.textSecondary).lineLimit(1)
                }
                .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 14)
            }
            .frame(width: 168).frame(maxHeight: .infinity)
            .background(WbColor.control)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                toolPage
                HStack(alignment: .center, spacing: 10) {
                    if !message.isEmpty {
                        Text(message).font(.system(size: 11)).foregroundStyle(WbColor.textSecondary)
                            .textSelection(.enabled).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    // Keep Escape in the native responder chain for IME cancellation.
                    Button(t("关闭", "Close"), action: onClose)
                        .buttonStyle(.bordered).controlSize(.regular)
                        .accessibilityIdentifier("device-tools-close")
                }
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 14)
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .background(WbColor.raised)
        }
        .modifier(LightweightPanelSurface())
        .preferredColorScheme(model.colorScheme)
        .background(WbColor.raised)
        .controlSize(.regular)
        .textFieldStyle(.roundedBorder)
        .environment(\.locale,Locale(identifier:model.language == 0 ? "en" : "zh-Hans"))
        .onAppear { loadInitialState() }
        .onChange(of: selection.section) { section in
            message = ""
            if section != 3 { stopLogStream() }
            loadInitialState()
        }
        .onChange(of:running) { value in
            if !value { stopLogStream(); routePlayback.stop(routePlayback.token) }
            loadInitialState()
        }
        .onChange(of: cameraEdits.draft) { _ in if cameraDirty { message = "" } }
        .onChange(of:logStream.active) { active in if !active { followLog = false } }
        .onDisappear { stopLogStream() }
        .alert(item:$pending) { action in
            Alert(title:Text(action.title), message:Text(action.detail), primaryButton:.destructive(Text(t("继续", "Continue"))) {
                call(action.method, action.params) { _ in model.refresh() }
            }, secondaryButton:.cancel(Text(t("取消", "Cancel"))))
        }
    }

    // MARK: - Shell (visual layer only)

    private var toolTitles: [String] {
        [t("电池", "Battery"), "GPS", t("网络与传感器", "Network & sensors"), "Logcat",
         t("Root 管理", "Root"), t("电话与短信", "Calls & SMS"),
         t("剪贴板", "Clipboard"), t("指纹", "Fingerprint"), t("摄像头", "Cameras"), t("开发者选项", "Developer options")]
    }

    private var toolDescriptions: [String] {
        [t("模拟设备电量与充电状态。", "Simulate charge and charging state."),
         t("设置位置或回放路线。", "Set a location or play a route."),
         t("控制网络连接、代理和传感器。", "Control connectivity, proxy and sensors."),
         t("查看并筛选设备日志。", "View and filter device logs."),
         t("管理 Root、证书和系统属性。", "Manage root, certificates and system properties."),
         t("模拟来电、短信与蜂窝信号。", "Simulate calls, messages and cellular signal."),
         t("在 Mac 和设备间传递文字。", "Transfer text between your Mac and device."),
         t("测试已注册和未注册的指纹。", "Test enrolled and unrecognized fingerprints."),
         t("配置前后置摄像头来源。", "Choose sources for the front and back cameras."),
         t("检查触摸反馈、布局与动画。", "Inspect touch feedback, layouts and animations.")]
    }

    private var navigation: some View {
        CompactDeviceToolsSidebar(items: [
            .init(section: nil, title: t("环境模拟", "Simulation")),
            .init(section: 0, title: toolTitles[0], symbol: WbIcon.battery),
            .init(section: 1, title: toolTitles[1], symbol: WbIcon.location),
            .init(section: 2, title: toolTitles[2], symbol: WbIcon.network),
            .init(section: 5, title: toolTitles[5], symbol: "phone"),
            .init(section: nil, title: t("输入与外设", "Input & peripherals")),
            .init(section: 6, title: toolTitles[6], symbol: "doc.on.clipboard"),
            .init(section: 7, title: toolTitles[7], symbol: "touchid"),
            .init(section: 8, title: toolTitles[8], symbol: "camera"),
            .init(section: nil, title: t("开发与调试", "Development")),
            .init(section: 3, title: toolTitles[3], symbol: WbIcon.logcat),
            .init(section: 4, title: toolTitles[4], symbol: WbIcon.rootTab),
            .init(section: 9, title: toolTitles[9], symbol: "hammer")
        ], selection: $selection.section, label: t("设备工具分类", "Device tool categories"))
    }

    private var toolPage: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(toolTitles[selection.section]).font(.system(size: 18, weight: .medium))
                        .foregroundStyle(WbColor.textPrimary)
                    Text(toolDescriptions[selection.section]).font(.system(size: 12))
                        .foregroundStyle(WbColor.textSecondary).fixedSize(horizontal: false, vertical: true)
                }
                if !running && selection.section != 4 && selection.section != 8 {
                    Label(t("启动设备后可调整此项设置。", "Start the device to adjust these settings."), systemImage: WbIcon.info)
                        .font(.system(size: 12)).foregroundStyle(WbColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                selectedTool
                    .disabled(working || (!running && selection.section != 4 && selection.section != 8))
                    .controlSize(.small)
            }
            .frame(maxWidth: 430, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(WbColor.raised)
        .toggleStyle(.switch)
        .labeledContentStyle(DeviceToolFieldStyle())
        .id(selection.section)
        .accessibilityIdentifier("device-tools-page")
    }

    @ViewBuilder
    private var selectedTool: some View {
        switch selection.section {
        case 0:
            DeviceToolPageGroup { battery } footer: { batteryActions }
        case 1: gps
        case 2: networkAndSensors
        case 3:
            DeviceToolPageGroup { logs }
        case 4: RootDevToolsView(model: model, id: id, running: running, embedded: true)
        case 5:
            DeviceToolPageGroup { phoneTools }
        case 6:
            DeviceToolPageGroup { clipboardTools } footer: { clipboardActions }
        case 7:
            DeviceToolPageGroup { fingerprintTools }
        case 8:
            DeviceToolPageGroup { cameraTools }
                footer: {
                    VStack(alignment: .leading, spacing: 12) {
                        cameraActions
                        Text(t("摄像头切换在下次启动设备时生效。虚拟场景只支持后置摄像头。",
                               "Camera changes apply the next time the device starts. The virtual scene is a back camera only."))
                            .foregroundStyle(WbColor.textSecondary)
                    }
                }
        default:
            DeviceToolPageGroup { developerTools } footer: { developerActions }
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
    private func toolField(_ title: String, placeholder: String, text: Binding<String>, width: CGFloat = 220, alignment: TextAlignment = .leading) -> some View {
        LabeledContent(title) {
            TextField("", text: text, prompt: Text(placeholder))
                .frame(width: width).multilineTextAlignment(alignment).accessibilityLabel(title)
        }
    }

    private func sensorTitle(_ value: String) -> String {
        switch value {
        case "acceleration": return t("加速度", "Acceleration")
        case "gyroscope": return t("陀螺仪", "Gyroscope")
        case "magnetic_field": return t("磁场", "Magnetic field")
        case "temperature": return t("温度", "Temperature")
        case "proximity": return t("距离", "Proximity")
        case "light": return t("环境光", "Ambient light")
        case "pressure": return t("气压", "Pressure")
        case "humidity": return t("相对湿度", "Relative humidity")
        default: return value
        }
    }
    // Units match the public AOSP emulator SensorType comments in jidr-proto.
    private var sensorHint: String {
        let units = ["acceleration": "m/s²", "gyroscope": "rad/s", "magnetic_field": "µT",
                     "temperature": "°C", "proximity": "cm", "light": "lx", "pressure": "hPa", "humidity": "%"]
        let unit = units[sensor] ?? ""
        return ["acceleration", "gyroscope", "magnetic_field"].contains(sensor)
            ? t("按 X、Y、Z 顺序输入三个数值，用逗号分隔。单位：\(unit)。", "Enter X, Y, Z separated by commas. Unit: \(unit).")
            : t("输入一个数值。单位：\(unit)。", "Enter one value. Unit: \(unit).")
    }

    private var battery: some View {
        Group {
            LabeledContent(t("电量（0–100）", "Charge (0–100)")) {
                TextField("", text: $level).frame(width: 110)
                    .accessibilityLabel(t("电量（0–100）", "Charge (0–100)"))
                    .accessibilityIdentifier("battery-charge")
            }
            Divider()
            LabeledContent(t("充电方式", "Charger")) {
                Picker("", selection: $charger) {
                    Text(t("未连接", "None")).tag("none"); Text("AC").tag("ac")
                    Text("USB").tag("usb"); Text(t("无线", "Wireless")).tag("wireless")
                }.labelsHidden().frame(width: 180).accessibilityLabel(t("充电方式", "Charger"))
            }
        }
    }
    private var batteryActions: some View {
        DeviceToolActions {
            Button(t("读取状态", "Read status"), action: loadBattery).disabled(reads.contains("battery.get"))
            Button(t("应用", "Apply")) {
                guard let n = Int(level), (0...100).contains(n) else { message = t("电量必须为 0–100 的整数。", "Charge must be an integer from 0 to 100."); return }
                call("battery.set", ["level": n, "charger": charger])
            }.disabled(!batteryLoaded || reads.contains("battery.get"))
        }
    }

    private var gps: some View {
        Group {
            DeviceToolPageGroup {
                Group {
                    toolField(t("纬度（°）", "Latitude (°)"), placeholder: "−90 … 90", text: $lat, width: 180, alignment: .trailing)
                    toolField(t("经度（°）", "Longitude (°)"), placeholder: "−180 … 180", text: $lon, width: 180, alignment: .trailing)
                }
                DeviceToolActions {
                    Button(t("读取当前位置", "Read current location")) { call("gps.get") { value in if let d = value as? [String:Any], let a = d["latitude"] as? Double, let o = d["longitude"] as? Double { lat = String(a); lon = String(o) } } }
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
            } header: { Text(t("位置", "Location")) }
            DeviceToolPageGroup(t("路线回放", "Route playback")) {
                HStack { Button(t("选择 GPX / KML", "Choose GPX / KML")) { choose(["gpx","kml"]) { routePath = $0.path } }; Text(routePath.isEmpty ? t("未选择文件", "No file selected") : URL(fileURLWithPath:routePath).lastPathComponent).lineLimit(1) }
                Group {
                    toolField(t("速度倍率", "Speed"), placeholder: "1", text: $routeSpeed, width: 110, alignment: .trailing)
                    Toggle(t("循环", "Loop"), isOn: $routeLoop)
                }
                DeviceToolActions {
                    Button(t("播放", "Play")) {
                        guard let speed = OperationMessages.routeSpeed(routeSpeed) else { message = t("请输入大于 0 且不超过 64 的速度倍率。", "Enter a speed greater than 0 and no greater than 64."); return }
                        let token = routePlayback.start()
                        model.call("gps.route",["device":id,"path":routePath,"speed":speed,"loop":routeLoop]) { result in
                            guard token == routePlayback.token else { return }
                            routePlayback.complete(token)
                            switch result { case .success: message = t("路线播放结束。", "Route playback ended."); case .failure(let error): message = OperationMessages.error(error.localizedDescription,language:model.language) }
                        }
                    }.disabled(routePath.isEmpty || routeRunning)
                    Button(routePlayback.isPaused ? t("继续", "Resume") : t("暂停", "Pause")) {
                        let token = routePlayback.token
                        let paused = !routePlayback.isPaused
                        call("gps.route_control", ["paused": paused]) { _ in routePlayback.setPaused(paused, token: token) }
                    }.disabled(!routeRunning)
                    Button(t("停止", "Stop")) {
                        let token = routePlayback.token
                        call("gps.route_stop") { _ in routePlayback.stop(token) }
                    }.disabled(!routeRunning)
                }
            }
        }
    }
    private var networkAndSensors: some View {
        Group {
            DeviceToolPageGroup {
                Group {
                    Toggle("Wi-Fi", isOn: $wifi)
                    Toggle(t("移动数据", "Mobile data"), isOn: $mobile)
                    LabeledContent(t("网络速度", "Network speed")) {
                        Picker("", selection: $profile) {
                            ForEach(["full","lte","hsdpa","umts","edge","gprs","gsm"], id: \.self) { value in
                                Text(value == "full" ? t("不限速", "Unrestricted") : value.uppercased()).tag(value)
                            }
                        }.labelsHidden().frame(width: 180).accessibilityLabel(t("网络速度", "Network speed"))
                    }
                }
                DeviceToolActions {
                    Button(t("读取网络状态", "Read network status"),action:loadNetwork).disabled(reads.contains("network.get"))
                    Button(t("应用网络开关", "Apply network switches")) { call("network.set",["wifi":wifi,"mobile":mobile]) }.disabled(!networkLoaded)
                    Button(t("应用网络速度", "Apply speed")) { call("network.set",["profile":profile]) }
                }
            } header: { Text(t("网络连接", "Connectivity")).id("device-tool-2") }
            DeviceToolPageGroup(t("设备 HTTP 代理", "Device HTTP proxy")) {
                Group {
                    toolField(t("代理主机", "Proxy host"), placeholder: "127.0.0.1", text: $proxyHost)
                    toolField(t("端口", "Port"), placeholder: "1–65535", text: $proxyPort, width: 110, alignment: .trailing)
                }
                DeviceToolActions {
                    Button(t("读取代理", "Read proxy")) { call("network.proxy.get") { value in
                        if let d = value as? [String:Any] { proxyHost = d["host"] as? String ?? ""; proxyPort = (d["port"] as? Int).map { String($0) } ?? "" }
                    } }
                    Button(t("设置代理", "Set proxy")) {
                        guard !proxyHost.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, let port = Int(proxyPort), (1...65535).contains(port) else { message = t("请输入有效的代理主机和端口。", "Enter a valid proxy host and port."); return }
                        call("network.proxy.set",["host":proxyHost,"port":port])
                    }
                    Button(t("清除代理", "Clear proxy")) { call("network.proxy.clear") { _ in proxyHost = ""; proxyPort = "" } }
                }
            }
            DeviceToolPageGroup(t("传感器", "Sensors")) {
                Group {
                    LabeledContent(t("传感器", "Sensor")) {
                        Picker("", selection: $sensor) {
                            ForEach(["acceleration","gyroscope","magnetic_field","temperature","proximity","light","pressure","humidity"], id: \.self) { value in Text(sensorTitle(value)).tag(value) }
                        }.labelsHidden().frame(width: 180).accessibilityLabel(t("传感器", "Sensor"))
                    }
                }
                Text(sensorHint).font(.caption).foregroundStyle(WbColor.textSecondary)
                toolField(t("传感器数值", "Sensor values"), placeholder: ["acceleration", "gyroscope", "magnetic_field"].contains(sensor) ? "0, 0, 0" : "0", text: $values)
                DeviceToolActions {
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
    }
    private var logs: some View {
        Group {
            toolField(t("过滤条件", "Filter"), placeholder: t("例如 ActivityManager:I", "e.g. ActivityManager:I"), text: $filter)
                .disabled(followLog)
            LabeledContent(t("级别", "Level")) {
                Picker("", selection: $logLevel) {
                    Text(t("全部", "All")).tag("")
                    ForEach(["V", "D", "I", "W", "E", "F"], id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 180).disabled(followLog)
                    .accessibilityLabel(t("级别", "Level"))
            }
            Toggle(t("实时跟随", "Follow live"), isOn: $followLog)
                .onChange(of: followLog) { enabled in
                    if enabled {
                        logStream.start(executable: model.centerExecutable, device: id, filters: LogFilter.arguments(filter, level: logLevel))
                        if !logStream.active { followLog = false }
                    } else { stopLogStream() }
                }
            DeviceToolActions {
                if logLoading { ProgressView().controlSize(.small) }
                Button(t("刷新", "Refresh"), action: refreshLog).disabled(logLoading || followLog)
                Button(t("清除设备日志…", "Clear device log…")) {
                    pending = PendingAction(title: t("清除日志？", "Clear log?"), detail: t("设备上的日志会被清除。", "The device log will be cleared."), method: "logcat.clear", params: [:])
                }
            }
            if let streamError = logStream.error {
                Text(model.language == 0 ? "Log stream ended or lost messages. Restart it to try again." : streamError)
                    .font(.caption).foregroundStyle(WbColor.textSecondary)
            }
            ScrollViewReader { reader in
                ScrollView {
                    let displayed = followLog ? logStream.text : log
                    if displayed.isEmpty {
                        Label(t("点击刷新读取设备日志。", "Refresh to load device logs."), systemImage:WbIcon.logcat)
                            .font(.body).foregroundStyle(WbColor.textSecondary)
                            .frame(maxWidth:.infinity, minHeight:180)
                    } else {
                        Text(displayed).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth:.infinity,alignment:.leading).padding(WbSpace.md)
                    }
                    Color.clear.frame(height:1).id("log-end")
                }.onChange(of:logStream.revision) { _ in if followLog { reader.scrollTo("log-end",anchor:.bottom) } }
            }.frame(height:220)
                .background(WbColor.sunken, in:RoundedRectangle(cornerRadius: WbRadius.md))
        }
    }
    private var phoneTools: some View {
        Group {
            toolField(t("电话号码", "Phone number"), placeholder: "+1 555 1234", text: $phoneNumber)
            DeviceToolActions {
                ForEach([("来电", "Incoming", "incoming"), ("接听", "Accept", "accept"), ("挂断", "End", "end")], id: \.2) { zh, en, action in
                    Button(t(zh, en)) { call("phone.call", ["number": phoneNumber, "action": action]) }.disabled(phoneNumber.isEmpty)
                }
            }
            toolField(t("短信内容", "SMS text"), placeholder: t("输入短信", "Enter a message"), text: $smsText)
            DeviceToolActions {
                Button(t("模拟接收", "Simulate receipt")) { call("phone.sms", ["from": phoneNumber, "text": smsText]) }.disabled(phoneNumber.isEmpty || smsText.isEmpty)
            }
            LabeledContent(t("信号", "Signal")) {
                Stepper(t("\(signal) 格", "\(signal) bars"), value: $signal, in: 0...4).fixedSize()
            }
            DeviceToolActions { Button(t("设置信号", "Set signal")) { call("phone.gsm", ["signal": signal]) } }
        }
    }

    private var clipboardTools: some View {
        Group {
            Text(t("设备剪贴板内容", "Device clipboard contents")).font(.subheadline)
            TextEditor(text: $clipboard)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 180, maxHeight: 300)
                .background(WbColor.raised, in: RoundedRectangle(cornerRadius: WbRadius.sm))
                .overlay(RoundedRectangle(cornerRadius: WbRadius.sm).stroke(WbColor.borderSubtle))
                .accessibilityLabel(t("设备剪贴板内容", "Device clipboard contents"))
        }
    }
    private var clipboardActions: some View {
        DeviceToolActions {
            Button(t("读取设备剪贴板", "Read device clipboard")) { call("clipboard.get") { value in if let data = value as? [String:Any], let text = data["text"] as? String { clipboard = text } } }
            Button(t("写入设备剪贴板", "Write device clipboard")) { call("clipboard.set",["text":clipboard]) }
        }
    }

    private var fingerprintTools: some View {
        Group {
            DeviceToolActions {
                Button(t("已注册手指", "Enrolled finger")) { call("fingerprint.touch",["finger":1]) }
                Button(t("未注册手指", "Other finger")) { call("fingerprint.touch",["finger":9]) }
                Button(t("抬起", "Lift")) { call("fingerprint.remove") }
            }
            Text(t("需先在 Android 安全设置中注册指纹。", "Enroll a fingerprint in Android security settings first.")).font(.caption).foregroundStyle(WbColor.textSecondary)
        }
    }

    private var cameraTools: some View {
        Group {
            if cameraLoaded {
                Group {
                    LabeledContent(t("后置摄像头", "Back camera")) {
                        DeviceToolPopUp(label: t("后置摄像头", "Back camera"), identifier: "camera-back",
                                        options: cameraBackOptions, selection: $cameraEdits.draft.back).frame(width: 180)
                    }
                    Divider()
                    LabeledContent(t("前置摄像头", "Front camera")) {
                        DeviceToolPopUp(label: t("前置摄像头", "Front camera"), identifier: "camera-front",
                                        options: cameraFrontOptions, selection: $cameraEdits.draft.front).frame(width: 180)
                    }
                }
                if cameraDirty {
                    Text(t("有未保存的更改", "Unsaved changes")).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("camera-unsaved")
                }

            } else {
                Label(t("尚未读取摄像头配置。", "Camera settings have not been loaded."), systemImage: WbIcon.info)
                    .foregroundStyle(.secondary)
                Button(t("重新读取", "Retry"), action: loadCamera)
            }
        }
    }
    private var cameraActions: some View {
        Group {
            if cameraLoaded {
                DeviceToolActions {
                    Button(t("重新读取", "Reload"), action: loadCamera).disabled(cameraDirty)
                    Button(t("还原更改", "Revert changes")) {
                        cameraEdits.revert(); message = ""
                    }.disabled(!cameraDirty)
                    Button(t("应用", "Apply"), action: applyCamera)
                        .disabled(!cameraDirty || reads.contains("camera.get"))
                        .accessibilityIdentifier("camera-apply")
                }
            }
        }
    }

    private var developerTools: some View {
        Group {
            Group {
                Toggle(t("显示触摸", "Show taps"),isOn:$showTaps).disabled(!developerLoaded)
                Toggle(t("指针位置", "Pointer location"),isOn:$pointer).disabled(!developerLoaded)
                Toggle(t("布局边界", "Layout bounds"),isOn:$layoutBounds).disabled(!developerLoaded)
                LabeledContent(t("动画倍率", "Animation scale")) {
                    Picker("", selection: $animation) { ForEach([0.0,0.5,1.0,1.5,2.0,5.0,10.0], id: \.self) { Text(String($0)).tag($0) } }
                        .labelsHidden().frame(width: 180).disabled(!developerLoaded)
                        .accessibilityLabel(t("动画倍率", "Animation scale"))
                }
            }
        }
    }
    private var developerActions: some View {
        DeviceToolActions {
            Button(t("读取开发者选项", "Read developer options")) { loadDeveloper() }
            Button(t("应用开发者选项", "Apply developer options")) { call("dev.set",["show_taps":showTaps,"pointer_location":pointer,"layout_bounds":layoutBounds,"animation_scale":animation]) }.disabled(!developerLoaded)
        }
    }

    private var cameraBackOptions: [(String, String)] {
        [("default", t("跟随设备默认值", "Device default")), ("emulated", t("模拟", "Emulated")), ("virtualscene", t("虚拟场景", "Virtual scene")),
         ("webcam0", t("Mac 摄像头 1", "Mac camera 1")), ("webcam1", t("Mac 摄像头 2", "Mac camera 2")),
         ("none", t("禁用", "None"))]
    }
    private var cameraFrontOptions: [(String, String)] {
        cameraBackOptions.filter { $0.0 != "virtualscene" }
    }
    private func loadCamera() {
        readState("camera.get") { value in
            guard let data = value as? [String: Any], let back = data["back"] as? String, let front = data["front"] as? String else {
                message = t("摄像头配置格式无效。", "Invalid camera response.")
                return
            }
            guard cameraBackOptions.contains(where: { $0.0 == back }), cameraFrontOptions.contains(where: { $0.0 == front }) else {
                cameraEdits = DeviceCameraEdits()
                message = t("当前摄像头来源暂不受支持，请使用设备设置检查配置。", "The current camera source is unsupported. Review it in device settings.")
                return
            }
            cameraEdits.load(DeviceCameraDraft(back: back, front: front))
        }
    }
    private func applyCamera() {
        guard cameraDirty else { return }
        let submitted = cameraEdits.draft
        call("camera.set", ["back": submitted.back, "front": submitted.front]) { value in
            let data = value as? [String: Any]
            let stored = DeviceCameraDraft(back: data?["back"] as? String ?? submitted.back,
                                           front: data?["front"] as? String ?? submitted.front)
            cameraEdits.acknowledge(stored, submitted: submitted)
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
