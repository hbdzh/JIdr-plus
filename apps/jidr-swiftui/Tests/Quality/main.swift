// SPDX-License-Identifier: GPL-3.0-only
import Foundation

let root = FileManager.default.temporaryDirectory.appendingPathComponent("jidr-quality-\(UUID().uuidString)")
try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
defer { try? FileManager.default.removeItem(at:root) }
let device = UUID().uuidString.lowercased()
let store = try WindowQualityStore(dataDirectory:root.path,device:device)
let initial = try store.load()
precondition(initial == 1)
let dir = root.appendingPathComponent("window-state",isDirectory:true)
try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
let legacy = """
{"version":1,"width":400,"height":740,"x":20,"y":20,"sidebar":true,"on_top":false,"quality":2}
"""
try Data(legacy.utf8).write(to:dir.appendingPathComponent("\(device).json"))
let restored = try store.load()
precondition(restored == 2)
try store.save(0)
let saved = try store.load()
precondition(saved == 0)
let quality = dir.appendingPathComponent("\(device).quality.json")
try Data("broken".utf8).write(to:quality)
do { try store.save(1); fatalError("invalid preference was overwritten") } catch { }
let remaining = try Data(contentsOf:quality)
precondition(remaining == Data("broken".utf8))
do { _ = try WindowQualityStore(dataDirectory:root.path,device:"../other"); fatalError("invalid identifier accepted") } catch { }
print("Window quality tests passed")
