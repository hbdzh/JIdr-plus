// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Reads and writes the existing per-device window-quality preference.
struct WindowQualityStore {
    private struct WindowState: Decodable {
        let version: Int
        let width: Double
        let height: Double
        let x: Int
        let y: Int
        let sidebar: Bool
        let on_top: Bool
        let quality: UInt8?
    }
    private let directory: URL
    private let device: String

    init(dataDirectory: String, device: String) throws {
        guard let id = UUID(uuidString:device) else { throw QualityError.invalidDevice }
        self.device = id.uuidString.lowercased()
        directory = URL(fileURLWithPath:dataDirectory, isDirectory:true).appendingPathComponent("window-state", isDirectory:true)
    }
    private var qualityURL: URL { directory.appendingPathComponent("\(device).quality.json") }
    private var stateURL: URL { directory.appendingPathComponent("\(device).json") }
    private func readIfPresent(_ url:URL) throws -> Data? {
        do { return try Data(contentsOf:url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
    }
    func load() throws -> UInt8 {
        if let data = try readIfPresent(qualityURL) {
            let value = try JSONDecoder().decode(UInt8.self, from:data)
            guard value <= 2 else { throw QualityError.invalidValue }
            return value
        }
        guard let data = try readIfPresent(stateURL) else { return 1 }
        let state = try JSONDecoder().decode(WindowState.self,from:data)
        let quality = state.quality ?? 1
        guard state.version == 1, (180...3840).contains(state.width),
              (240...2160).contains(state.height), quality <= 2 else { throw QualityError.invalidValue }
        return quality
    }
    func save(_ value:UInt8) throws {
        guard value <= 2 else { throw QualityError.invalidValue }
        _ = try load() // Never replace an unreadable existing preference.
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try JSONEncoder().encode(value).write(to:qualityURL,options:.atomic)
    }
    enum QualityError: LocalizedError {
        case invalidDevice, invalidValue
        var errorDescription: String? {
            switch self { case .invalidDevice: return "设备标识无效。"; case .invalidValue: return "游戏画质配置无效。" }
        }
    }
}
