// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// SwiftUI uses AppKit screen coordinates, so it keeps its own geometry file
/// instead of changing the Slint window's differently scaled coordinates.
struct GameWindowState: Codable, Equatable {
    var version = 1
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var sidebar: Bool
    var onTop: Bool
    var landscape: Bool

    var isValid: Bool {
        version == 1 && x.isFinite && y.isFinite && width.isFinite && height.isFinite &&
        (180...5000).contains(width) && (180...4000).contains(height) && abs(x) < 100000 && abs(y) < 100000
    }
}

enum GameReconnectPolicy {
    static func permits(disconnected:Bool, editing:Bool, recording:Bool, recordingUnknown:Bool) -> Bool {
        disconnected && !editing && !recording && !recordingUnknown
    }
}

final class GameWindowStateStore {
    private struct LegacyState: Decodable { let version:Int; let sidebar:Bool; let on_top:Bool }
    private let path: URL
    private let legacyPath: URL
    private let dataRoot: URL
    private var baseline: Data?
    private var loaded = false
    init(dataDirectory:String,device:String) throws {
        guard let id = UUID(uuidString:device) else { throw StateError.invalidDevice }
        dataRoot = URL(fileURLWithPath:dataDirectory,isDirectory:true)
        let directory = dataRoot.appendingPathComponent("window-state",isDirectory:true)
        let name = id.uuidString.lowercased()
        path = directory.appendingPathComponent("\(name).swiftui.json")
        legacyPath = directory.appendingPathComponent("\(name).json")
    }
    func legacyPreferences() throws -> (sidebar:Bool,onTop:Bool)? {
        let data: Data
        do { data = try Data(contentsOf:legacyPath) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
        let state = try JSONDecoder().decode(LegacyState.self,from:data)
        guard state.version == 1 else { throw StateError.invalidState }
        return (state.sidebar,state.on_top)
    }
    func load() throws -> GameWindowState? {
        let data: Data
        do { data = try Data(contentsOf:path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { baseline = nil; loaded = true; return nil }
        let state = try JSONDecoder().decode(GameWindowState.self,from:data)
        guard state.isValid else { throw StateError.invalidState }
        baseline = data; loaded = true
        return state
    }
    func save(_ state:GameWindowState) throws {
        guard state.isValid else { throw StateError.invalidState }
        guard loaded else { throw StateError.invalidState }
        let current: Data?
        do { current = try Data(contentsOf:path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { current = nil }
        guard current == baseline else { throw StateError.changed }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath:dataRoot.path,isDirectory:&isDirectory), isDirectory.boolValue else { throw StateError.dataUnavailable }
        try FileManager.default.createDirectory(at:path.deletingLastPathComponent(),withIntermediateDirectories:true)
        let bytes = try JSONEncoder().encode(state)
        try bytes.write(to:path,options:.atomic)
        baseline = bytes
    }
    enum StateError: LocalizedError {
        case invalidDevice, invalidState, changed, dataUnavailable
        var errorDescription:String? {
            switch self { case .invalidDevice: return "设备标识无效。"; case .invalidState: return "窗口设置无效，原文件未覆盖。"; case .changed: return "窗口设置已被其他程序修改，未覆盖原文件。"; case .dataUnavailable: return "数据目录不可用，未保存窗口设置。" }
        }
    }
}
