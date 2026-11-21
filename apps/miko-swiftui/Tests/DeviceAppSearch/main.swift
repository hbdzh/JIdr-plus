import Foundation
func check(_ condition: @autoclosure () -> Bool, _ label: String) { precondition(condition(), label) }
let appA = DeviceSearchApp(name:"Alpha Game", package:"com.example.alpha")
let appB = DeviceSearchApp(name:"Beta", package:"com.example.beta")
var now: TimeInterval = 100
var requests: [String] = []
var callbacks: [String: [(Result<[DeviceSearchApp], Error>) -> Void]] = [:]
var matches: [String:String] = [:]
let search = DeviceAppSearch(ttl:30, limit:3, clock:{ now }, request:{ id, done in
    requests.append(id); callbacks[id, default: []].append(done)
}, publish:{ matches = $0 })
func complete(_ id: String, _ apps: [DeviceSearchApp]) { callbacks[id]!.removeFirst()(.success(apps)) }
search.update(query:"alpha",running:["a","b","c","d"])
check(requests.isEmpty, "debounce")
search.startRequests()
check(requests == ["a","b","c"], "bounded first wave")
complete("a",[appA]); check(matches == ["a":"Alpha Game"], "name match")
check(requests == ["a","b","c","d"], "next device after completion")
search.update(query:"example.beta",running:["a","b","c","d"])
check(matches.isEmpty, "query updates cached results")
complete("b",[appB]); check(matches == ["b":"Beta"], "old in-flight answer matched against current query")
complete("c",[appA]); complete("d",[appB]); search.startRequests()
check(matches == ["b":"Beta","d":"Beta"], "package matching")
check(requests.count == 4, "query changes reuse fresh results")
search.update(query:"alpha",running:["a","b","c","d"]); search.startRequests()
check(matches == ["a":"Alpha Game","c":"Alpha Game"] && requests.count == 4, "cached search")
search.invalidate("a"); check(matches == ["c":"Alpha Game"] && requests.count == 5, "installation invalidates cache")
search.invalidate("a"); complete("a",[appA]); check(requests.count == 6 && matches["a"] == nil, "invalidated in-flight response ignored")
complete("a",[appB]); check(matches["a"] == nil, "new result applies")
search.update(query:"beta",running:["b","c","d"]); search.startRequests()
check(matches == ["b":"Beta","d":"Beta"], "stopped device removed")
search.update(query:"beta",running:["a","b","c","d"]); search.startRequests()
check(requests.last == "a" && requests.count == 7, "restarted device is reloaded")
complete("a",[appB]); check(matches["a"] == "Beta", "restarted device visible")
now += 31
search.update(query:"beta",running:["a","b","c","d"]); search.startRequests()
check(matches.isEmpty && requests.count == 10, "expired entries and concurrency")
complete("a",[appB]); check(requests.count == 11, "expired fourth device queued")
complete("b",[appB]); complete("c",[appA]); complete("d",[appB])
search.reset(); check(matches.isEmpty, "disconnect invalidates")
search.update(query:"",running:["a","b","c","d"]); search.startRequests()
check(requests.count == 11, "empty search makes no requests")
// Failed requests do not spin; a scheduled refresh can retry them.
var failedCallbacks: [(Result<[DeviceSearchApp], Error>)->Void] = []
var failureRequests = 0
let retry = DeviceAppSearch(clock:{now}, request:{ _, callback in failureRequests += 1; failedCallbacks.append(callback) }, publish:{ _ in })
retry.update(query:"x",running:["a"]); retry.startRequests()
failedCallbacks.removeFirst()(.failure(NSError(domain:"test",code:1)))
check(failureRequests == 1, "failure does not loop")
retry.update(query:"x",running:["a"]); retry.retryFailed(); retry.startRequests()
check(failureRequests == 2, "scheduled retry")
// Scheduling belongs to the search coordinator: cancelled or superseded typing
// must not start a stale request, and a later retry can recover a failed request.
var scheduledRequests: [String] = []
var scheduledCallback: ((Result<[DeviceSearchApp], Error>) -> Void)?
let scheduled = DeviceAppSearch(debounceInterval: 0.02, retryInterval: 0.08, request: { id, done in
    scheduledRequests.append(id); scheduledCallback = done
}, publish: { _ in })
scheduled.scheduleUpdate(query: "first", running: ["old"])
scheduled.scheduleUpdate(query: "second", running: ["new"])
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
check(scheduledRequests == ["new"], "only latest debounced search starts")
scheduledCallback?(.failure(NSError(domain: "test", code: 1)))
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
check(scheduledRequests == ["new", "new"], "timer retries failed requests")
scheduled.reset()
scheduled.scheduleUpdate(query: "cancel", running: ["cancelled"])
scheduled.reset()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
check(!scheduledRequests.contains("cancelled"), "reset cancels pending debounce")
print("Device app search tests passed")
