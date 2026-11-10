// SPDX-License-Identifier: GPL-3.0-only
import Foundation

let root = FileManager.default.temporaryDirectory.appendingPathComponent("jidr-window-state-\(UUID().uuidString)")
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:root) }
let device = UUID().uuidString.lowercased()
let store = try GameWindowStateStore(dataDirectory:root.path,device:device)
let missing = try store.load(); precondition(missing == nil)
let legacyDir = root.appendingPathComponent("window-state",isDirectory:true)
try FileManager.default.createDirectory(at:legacyDir,withIntermediateDirectories:true)
let legacyFile = legacyDir.appendingPathComponent("\(device).json")
let legacyData = Data("{\"version\":1,\"sidebar\":false,\"on_top\":true}".utf8)
try legacyData.write(to:legacyFile)
let legacy = try store.legacyPreferences(); precondition(legacy?.sidebar == false && legacy?.onTop == true)
let state = GameWindowState(x:100,y:200,width:460,height:780,sidebar:false,onTop:true,landscape:false)
try store.save(state)
let copy = try GameWindowStateStore(dataDirectory:root.path,device:device)
let loaded = try copy.load(); precondition(loaded == state)
let file = root.appendingPathComponent("window-state/\(device).swiftui.json")
try Data("external".utf8).write(to:file)
do { try store.save(state); fatalError("external state overwritten") } catch { }
let contents = try Data(contentsOf:file); precondition(contents == Data("external".utf8))
let retainedLegacy = try Data(contentsOf:legacyFile); precondition(retainedLegacy == legacyData)
let broken = try GameWindowStateStore(dataDirectory:root.path,device:device)
do { _ = try broken.load(); fatalError("invalid state accepted") } catch { }
do { try broken.save(state); fatalError("invalid state overwritten") } catch { }
precondition(!GameWindowState(x:0,y:0,width:0,height:780,sidebar:true,onTop:false,landscape:false).isValid)
precondition(GameReconnectPolicy.permits(disconnected:true,editing:false,recording:false,recordingUnknown:false))
precondition(!GameReconnectPolicy.permits(disconnected:true,editing:true,recording:false,recordingUnknown:false))
precondition(!GameReconnectPolicy.permits(disconnected:true,editing:false,recording:true,recordingUnknown:false))
precondition(!GameReconnectPolicy.permits(disconnected:true,editing:false,recording:false,recordingUnknown:true))
precondition(!GameReconnectPolicy.permits(disconnected:false,editing:false,recording:false,recordingUnknown:false))
let missingRoot = root.appendingPathComponent("disconnected")
let disconnected = try GameWindowStateStore(dataDirectory:missingRoot.path,device:UUID().uuidString)
_ = try disconnected.load()
do { try disconnected.save(state); fatalError("missing data root recreated") } catch { }
precondition(!FileManager.default.fileExists(atPath:missingRoot.path))
print("Game window state tests passed")
