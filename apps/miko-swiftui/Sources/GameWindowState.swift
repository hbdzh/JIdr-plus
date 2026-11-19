// SPDX-License-Identifier: GPL-3.0-only
import CoreGraphics
import Foundation

/// SwiftUI uses AppKit screen coordinates, so it keeps its own geometry file
/// instead of changing the Slint window's differently scaled coordinates.
/// Frames are in points (Retina independent); the display is recorded by its
/// CGDirectDisplayID string so a window can be restored to the same monitor.
struct GameWindowState: Codable, Equatable {
    var version = 1
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var sidebar: Bool
    var onTop: Bool
    var landscape: Bool
    /// `NSScreenNumber` of the display the window was on; nil in legacy files.
    var screen: String? = nil

    var isValid: Bool {
        version == 1 && x.isFinite && y.isFinite && width.isFinite && height.isFinite &&
        (180...5000).contains(width) && (180...4000).contains(height) && abs(x) < 100000 && abs(y) < 100000
    }
}

/// The visible area of one display, in the same point coordinates as
/// `NSScreen.visibleFrame`. Passed in by the window so the restore rules stay
/// testable without a GUI session.
struct GameWindowScreen: Equatable {
    let id: String?
    let visible: CGRect
}

/// Restoring a saved device-window frame on the current set of displays.
///
/// Rules (all in AppKit points, so Retina backing scale never enters):
/// 1. The saved display wins when it still exists (multi-monitor restore).
/// 2. Otherwise the display containing the saved title bar is used.
/// 3. Otherwise the main display is the fallback (a monitor was unplugged).
/// 4. The frame is clamped into that display's visible area, keeping at least
///    a readable window size; the caller re-fits the device aspect afterwards.
enum GameWindowRestore {
    /// Space kept free around the restored window (Dock/menu bar breathing room).
    static let margin: CGFloat = 24
    static let minimumSize = CGSize(width: 320, height: 240)

    static func restoreFrame(_ state: GameWindowState, screens: [GameWindowScreen], fallback: CGRect?) -> CGRect? {
        guard !screens.isEmpty || fallback != nil else { return nil }
        let saved = CGRect(x: state.x, y: state.y, width: state.width, height: state.height)
        let title = CGRect(x: saved.minX, y: saved.maxY - 24, width: saved.width, height: 24)
        let target: CGRect
        if let id = state.screen, let match = screens.first(where: { $0.id == id }) {
            target = match.visible
        } else if let containing = screens.first(where: { $0.visible.intersects(title) || $0.visible.contains(CGPoint(x: saved.midX, y: saved.midY)) }) {
            target = containing.visible
        } else if let fallback {
            target = fallback
        } else {
            target = screens[0].visible
        }
        return clamp(saved, to: target)
    }

    /// Centers `frame` inside `visible` after shrinking it to fit, never
    /// smaller than `minimumSize` in either axis (unless the display is).
    static func clamp(_ frame: CGRect, to visible: CGRect) -> CGRect {
        guard visible.width > 0, visible.height > 0 else { return frame }
        let usableWidth = max(1, visible.width - margin)
        let usableHeight = max(1, visible.height - margin)
        let minimumWidth = min(minimumSize.width, usableWidth)
        let minimumHeight = min(minimumSize.height, usableHeight)
        let size = CGSize(width: min(max(frame.width, minimumWidth), usableWidth),
                          height: min(max(frame.height, minimumHeight), usableHeight))
        let origin = CGPoint(x: min(max(frame.minX, visible.minX + margin / 2), visible.minX + visible.width - size.width - margin / 2),
                             y: min(max(frame.minY, visible.minY + margin / 2), visible.minY + visible.height - size.height - margin / 2))
        return CGRect(origin: origin, size: size)
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
    /// Stable codes instead of display strings: the window/center UI maps them to
    /// the current language (see `GameWindowController.windowStateMessage`), so
    /// English mode never shows Chinese and logs/tests stay language-neutral.
    enum StateError: LocalizedError, CaseIterable {
        case invalidDevice, invalidState, changed, dataUnavailable
        var code: String {
            switch self {
            case .invalidDevice: return "windowstate.invalid_device"
            case .invalidState: return "windowstate.invalid_state"
            case .changed: return "windowstate.changed"
            case .dataUnavailable: return "windowstate.data_unavailable"
            }
        }
        var errorDescription: String? { code }
    }
}
