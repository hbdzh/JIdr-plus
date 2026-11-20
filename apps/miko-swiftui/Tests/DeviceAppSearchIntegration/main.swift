import AppKit
import Foundation
func pump(_ s:Double = 0.02) { RunLoop.main.run(until:Date().addingTimeInterval(s)) }
func eventually(_ text:String, _ fn:()->Bool) { let end = Date().addingTimeInterval(8); while !fn() && Date() < end { pump() }; precondition(fn(),text) }
let home = URL(fileURLWithPath:ProcessInfo.processInfo.environment["MIKO_HOME"]!)
func requestCount() -> Int {
 let text = (try? String(contentsOf:home.appendingPathComponent("requests.jsonl"),encoding:.utf8)) ?? ""
 return text.split(separator:"\n").filter { line in
  guard let data = String(line).data(using:.utf8), let json = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return false }
  return json["method"] as? String == "app.list"
 }.count
}
let app=NSApplication.shared
app.setActivationPolicy(.accessory)
let model = try CenterModel(center:CommandLine.arguments[1],bridge:"/usr/bin/false")
eventually("four devices loaded") { model.devices.count == 4 && model.connection.isOnline }
model.showAllDevices(); pump(0.8)
let initial=requestCount()
model.deviceQuery="示例应用"
eventually("all matching apps") { model.appSearchMatches.count == 4 }
let afterFirst=requestCount()
model.deviceQuery="com.example.test"
eventually("cached package matches") { model.appSearchMatches.count == 4 }
pump(0.6)
let afterSecond=requestCount()
precondition(afterFirst-initial == 4, "one query per running device")
precondition(afterSecond == afterFirst, "query refinement reused cache")
let id=model.devices[0].id
var complete=false
model.call("app.uninstall",["device":id,"package":"com.example.test"]) { _ in complete=true }
eventually("uninstall completed") { complete }
eventually("invalidated search refreshed") { requestCount() == afterSecond+1 && model.appSearchMatches.count == 4 }
model.deviceQuery = ""
complete=false
model.call("test.stop",["device":id]) { _ in complete=true }
eventually("fixture stop") { complete };model.refresh()
eventually("device stopped") { model.devices.first(where:{$0.id == id})?.running == false }
complete=false
model.call("test.start",["device":id]) { _ in complete=true }
eventually("fixture start") { complete };model.refresh()
eventually("device restarted") { model.devices.first(where:{$0.id == id})?.running == true }
model.deviceQuery = "com.example.test"
eventually("restarted device reloaded") { requestCount() == afterSecond+2 && model.appSearchMatches.count == 4 }
print("SEARCH first_requests=\(afterFirst-initial) refined_requests=\(afterSecond-afterFirst) invalidated_requests=1 restart_refreshed=true")
model.close()
