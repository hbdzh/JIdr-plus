// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(AppKit)
import AppKit
#endif

enum MCPConfiguration {
    enum ConfigError: LocalizedError {
        case emptyCommand, codexNotFound, commandFailed(String), invalidWorkBuddyRoot, invalidWorkBuddyServers
        var errorDescription: String? {
            switch self {
            case .emptyCommand: return "Enter the path to the jidr command."
            case .codexNotFound: return "Codex CLI was not found. Install Codex or add its CLI to PATH."
            case .commandFailed(let detail): return "Codex could not save the configuration: \(detail)"
            case .invalidWorkBuddyRoot: return "The existing WorkBuddy configuration must be a JSON object."
            case .invalidWorkBuddyServers: return "The existing WorkBuddy mcpServers value must be a JSON object."
            }
        }
    }

    static func codexExecutable(environment: [String:String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates = (environment["PATH"] ?? "").split(separator:":").map { URL(fileURLWithPath:String($0)).appendingPathComponent("codex") }
        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"].map { URL(fileURLWithPath:$0) }
        #if canImport(AppKit)
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.openai.codex") {
            candidates.append(app.appendingPathComponent("Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"))
        }
        #endif
        return candidates.first { FileManager.default.isExecutableFile(atPath:$0.path) }
    }

    static func configuration(command: String) throws -> String {
        guard !command.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw ConfigError.emptyCommand }
        let encoded = try JSONSerialization.data(withJSONObject:command, options:[.fragmentsAllowed,.withoutEscapingSlashes])
        guard let quoted = String(data:encoded,encoding:.utf8) else { throw ConfigError.emptyCommand }
        return "[mcp_servers.jidr]\ncommand = \(quoted)\nargs = [\"mcp\"]\n"
    }

    static func workBuddyConfiguration(existing: Data? = nil, command: String) throws -> Data {
        guard !command.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw ConfigError.emptyCommand }
        var root: [String:Any] = [:]
        if let existing {
            guard let parsed = try JSONSerialization.jsonObject(with:existing) as? [String:Any] else { throw ConfigError.invalidWorkBuddyRoot }
            root = parsed
        }
        var servers: [String:Any] = [:]
        if let old = root["mcpServers"] {
            guard let parsed = old as? [String:Any] else { throw ConfigError.invalidWorkBuddyServers }
            servers = parsed
        }
        servers["jidr"] = ["command":command,"args":["mcp"]]
        root["mcpServers"] = servers
        return try JSONSerialization.data(withJSONObject:root,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
    }

    static func installWorkBuddy(at url: URL, command: String) throws {
        let existing: Data?
        do { existing = try Data(contentsOf:url) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { existing = nil }
        let data = try workBuddyConfiguration(existing:existing,command:command)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try data.write(to:url,options:.atomic)
    }

    static func install(command: String, executable: URL? = nil, environment: [String:String] = ProcessInfo.processInfo.environment) throws {
        _ = try configuration(command:command)
        guard let executable = executable ?? codexExecutable(environment:environment) else { throw ConfigError.codexNotFound }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["mcp", "add", "jidr", "--", command, "mcp"]
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(data:data,encoding:.utf8)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
            throw ConfigError.commandFailed(detail)
        }
    }
}
