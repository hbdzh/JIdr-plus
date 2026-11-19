// SPDX-License-Identifier: GPL-3.0-only
import Foundation

let text = try MCPConfiguration.configuration(command:"/test/a \"quoted\"/miko")
assert(text.contains("[mcp_servers.miko]"))
assert(text.contains("command = \"/test/a \\\"quoted\\\"/miko\""))
assert(text.contains("args = [\"mcp\"]"))
do { _ = try MCPConfiguration.configuration(command:"  "); fatalError("empty command accepted") } catch { }

let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:temp) }
let script = temp.appendingPathComponent("codex")
let capture = temp.appendingPathComponent("args")
try "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$CAPTURE\"\n".write(to:script,atomically:true,encoding:.utf8)
try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:script.path)
let environment = ["PATH":temp.path,"CAPTURE":capture.path]
assert(MCPConfiguration.codexExecutable(environment:environment) == script)
try MCPConfiguration.install(command:"/test/path with spaces/miko",executable:script,environment:environment)
let arguments = try String(contentsOf:capture,encoding:.utf8)
assert(arguments == "mcp\nadd\nmiko\n--\n/test/path with spaces/miko\nmcp\n")
try "#!/bin/sh\necho failed >&2\nexit 1\n".write(to:script,atomically:true,encoding:.utf8)
do { try MCPConfiguration.install(command:"miko",executable:script,environment:environment); fatalError("failed command accepted") } catch { }
let workBuddyFile = temp.appendingPathComponent(".workbuddy/mcp.json")
try MCPConfiguration.installWorkBuddy(at:workBuddyFile,command:"/test/miko")
var workBuddy = try JSONSerialization.jsonObject(with:Data(contentsOf:workBuddyFile)) as! [String:Any]
var servers = workBuddy["mcpServers"] as! [String:Any]
assert((servers["miko"] as? [String:Any])?["command"] as? String == "/test/miko")
let existing = Data(#"{"theme":"dark","mcpServers":{"other":{"command":"keep"},"miko":{"command":"old"}}}"#.utf8)
try existing.write(to:workBuddyFile)
try MCPConfiguration.installWorkBuddy(at:workBuddyFile,command:"/new/miko")
workBuddy = try JSONSerialization.jsonObject(with:Data(contentsOf:workBuddyFile)) as! [String:Any]
servers = workBuddy["mcpServers"] as! [String:Any]
assert(workBuddy["theme"] as? String == "dark")
assert((servers["other"] as? [String:String])?["command"] == "keep")
assert((servers["miko"] as? [String:Any])?["command"] as? String == "/new/miko")
for invalid in [Data("{".utf8),Data(#"{"mcpServers":[]}"#.utf8)] {
    try invalid.write(to:workBuddyFile)
    do { try MCPConfiguration.installWorkBuddy(at:workBuddyFile,command:"miko"); fatalError("invalid configuration accepted") } catch { }
    let unchanged = try Data(contentsOf:workBuddyFile)
    assert(unchanged == invalid)
}
print("MCP configuration tests passed")
