// SPDX-License-Identifier: GPL-3.0-only
import Foundation

let original = Data(#"{"theme":"dark","mcpServers":{"other":{"command":"keep"},"jidr":{"command":"old"}}}"#.utf8)
let merged = try MCPConfiguration.merged(existing:original,command:"/test/jidr")
let root = try JSONSerialization.jsonObject(with:merged) as! [String:Any]
let servers = root["mcpServers"] as! [String:Any]
assert(root["theme"] as? String == "dark")
assert((servers["other"] as? [String:String])?["command"] == "keep")
assert((servers["jidr"] as? [String:Any])?["command"] as? String == "/test/jidr")
do { _ = try MCPConfiguration.merged(existing:Data(#"{"mcpServers":[]}"#.utf8),command:"jidr"); fatalError("invalid servers accepted") } catch { }
do { _ = try MCPConfiguration.merged(existing:Data("{".utf8),command:"jidr"); fatalError("invalid JSON accepted") } catch { }
print("MCP configuration tests passed")
