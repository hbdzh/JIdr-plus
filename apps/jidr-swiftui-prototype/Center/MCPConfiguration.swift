// SPDX-License-Identifier: GPL-3.0-only
import Foundation

enum MCPConfiguration {
    enum ConfigError: LocalizedError {
        case invalidRoot, invalidServers, missingDirectory, emptyCommand
        var errorDescription: String? {
            switch self {
            case .invalidRoot: return "The existing configuration must be a JSON object."
            case .invalidServers: return "The existing mcpServers value must be a JSON object."
            case .missingDirectory: return "Claude's configuration directory does not exist."
            case .emptyCommand: return "Enter the path to the jidr command."
            }
        }
    }
    static func merged(existing: Data?, command: String) throws -> Data {
        guard !command.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw ConfigError.emptyCommand }
        var root: [String:Any] = [:]
        if let existing {
            guard let parsed = try JSONSerialization.jsonObject(with:existing) as? [String:Any] else { throw ConfigError.invalidRoot }
            root = parsed
        }
        var servers: [String:Any] = [:]
        if let old = root["mcpServers"] {
            guard let parsed = old as? [String:Any] else { throw ConfigError.invalidServers }
            servers = parsed
        }
        servers["jidr"] = ["command":command,"args":["mcp"]]
        root["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject:root, options:[.prettyPrinted,.sortedKeys])
    }
    static func install(at url: URL, command: String) throws {
        guard FileManager.default.fileExists(atPath:url.deletingLastPathComponent().path) else { throw ConfigError.missingDirectory }
        let existing: Data?
        do { existing = try Data(contentsOf:url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { existing = nil }
        let data = try merged(existing:existing,command:command)
        try data.write(to:url,options:.atomic)
    }
}
