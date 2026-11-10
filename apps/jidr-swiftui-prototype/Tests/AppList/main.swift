// SPDX-License-Identifier: GPL-3.0-only
import Foundation
struct Failure: Error {}
var scheduled: [() -> Void] = []
var calls = 0
var retries = 0
var output: [String] = []
var active = true
let loader = AppListLoader<String>(delays:[1,2,4],schedule:{ _, action in scheduled.append(action) })
loader.load(isCurrent:{ active },request:{ done in
    calls += 1
    if calls < 3 { done(.failure(Failure())) } else { done(.success("device-a")) }
},onRetry:{ retries += 1 },completion:{ result in if case .success(let value) = result { output.append(value) } })
precondition(calls == 1 && retries == 1)
scheduled.removeFirst()(); scheduled.removeFirst()()
precondition(calls == 3 && retries == 2 && output == ["device-a"])
var previousCompletion: ((Result<String,Error>) -> Void)?
loader.load(isCurrent:{ active },request:{ previousCompletion = $0 },onRetry:{ },completion:{ _ in fatalError("stale result accepted") })
loader.load(isCurrent:{ active },request:{ $0(.success("device-b")) },onRetry:{ },completion:{ if case .success(let value) = $0 { output.append(value) } })
previousCompletion?(.success("device-a"))
precondition(output == ["device-a","device-b"])
var pending: ((Result<String,Error>) -> Void)?
loader.load(isCurrent:{ active },request:{ pending = $0 },onRetry:{ },completion:{ _ in fatalError("stopped request completed") })
active = false; loader.cancel()
pending?(.failure(Failure()))
precondition(scheduled.isEmpty)
active = true
var stoppedCalls = 0
loader.load(isCurrent:{ active },request:{ done in stoppedCalls += 1; done(.failure(Failure())) },onRetry:{ },completion:{ _ in fatalError("cancelled retry completed") })
active = false; loader.cancel(); scheduled.removeFirst()()
precondition(stoppedCalls == 1)
active = true
calls = 0; scheduled.removeAll(); var finalFailure = false
loader.load(isCurrent:{ active },request:{ done in calls += 1; done(.failure(Failure())) },onRetry:{ },completion:{ if case .failure = $0 { finalFailure = true } })
while !scheduled.isEmpty { scheduled.removeFirst()() }
precondition(calls == 4 && finalFailure)
print("App list retry tests passed")
