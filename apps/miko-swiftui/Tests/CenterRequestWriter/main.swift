import Foundation
import Dispatch
func check(_ v: @autoclosure () -> Bool, _ message: String) { precondition(v(), message) }
let began = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
let lock = NSLock(); var writes: [Int] = []
let writer = CenterRequestWriter(maxBytes: 12, maxRequests: 3, write: { data in
 let value = Int(String(decoding:data,as:UTF8.self))!
 if value == 1 { began.signal(); _ = release.wait(timeout:.now()+3) }
 lock.lock(); writes.append(value); lock.unlock()
}, close: { closed.signal() })
let noError: (Error)->Void = { _ in preconditionFailure("unexpected write error") }
check(writer.send(id:1,data:Data("1".utf8),onFailure:noError), "first accepted")
check(began.wait(timeout:.now()+2) == .success, "first started")
check(writer.send(id:2,data:Data("2".utf8),onFailure:noError), "second accepted")
check(writer.send(id:3,data:Data("3".utf8),onFailure:noError), "third accepted")
check(!writer.send(id:4,data:Data("4".utf8),onFailure:noError), "bounded count")
writer.cancel(id:2)
check(writer.send(id:4,data:Data("4".utf8),onFailure:noError), "cancel frees capacity")
release.signal()
writer.stop()
check(closed.wait(timeout:.now()+3) == .success, "close does not wait on unsent writes")
lock.lock(); let observed = writes; lock.unlock()
check(observed == [1], "stop discards queued work")
check(!writer.send(id:5,data:Data("5".utf8),onFailure:noError), "closed rejects")
let entered = DispatchSemaphore(value:0), unblock = DispatchSemaphore(value:0), completed = DispatchSemaphore(value:0)
let cancelLock = NSLock(); var cancelledWrites: [Int] = []
let cancellation = CenterRequestWriter(maxBytes:32,maxRequests:4,write:{ d in
 let value = Int(String(decoding:d,as:UTF8.self))!
 if value == 1 { entered.signal(); _ = unblock.wait(timeout:.now()+3) }
 cancelLock.lock(); cancelledWrites.append(value); cancelLock.unlock()
 if value == 3 { completed.signal() }
})
check(cancellation.send(id:1,data:Data("1".utf8),onFailure:noError), "cancel setup")
check(entered.wait(timeout:.now()+3) == .success, "cancel blocked")
check(cancellation.send(id:2,data:Data("2".utf8),onFailure:noError), "cancel candidate")
cancellation.cancel(id:2)
check(cancellation.send(id:3,data:Data("3".utf8),onFailure:noError), "post cancel")
unblock.signal()
check(completed.wait(timeout:.now()+3) == .success, "post cancel completed")
cancelLock.lock(); let cancelResult = cancelledWrites; cancelLock.unlock()
check(cancelResult == [1,3], "cancelled request is not written")
cancellation.stop()
let all = DispatchSemaphore(value:0), orderLock = NSLock(); var order:[Int] = []
let ordered = CenterRequestWriter(maxBytes:64,maxRequests:20,write:{ d in
 orderLock.lock(); order.append(Int(String(decoding:d,as:UTF8.self))!); let count = order.count; orderLock.unlock()
 if count == 10 { all.signal() }
})
for i in 0..<10 { check(ordered.send(id:i,data:Data("\(i)".utf8),onFailure:noError), "ordered send") }
check(all.wait(timeout:.now()+3) == .success, "ordered completion")
orderLock.lock(); let actual = order; orderLock.unlock()
check(actual == Array(0..<10), "FIFO")
ordered.stop()
let failed = DispatchSemaphore(value:0), failureClose = DispatchSemaphore(value:0)
let broken = CenterRequestWriter(maxBytes:10,maxRequests:2,write:{ _ in throw NSError(domain:"test",code:1) },close:{ failureClose.signal() })
check(!broken.send(id:0,data:Data(repeating:0,count:11),onFailure:noError), "bounded bytes")
check(broken.send(id:1,data:Data("x".utf8),onFailure:{ _ in failed.signal() }), "error accepted")
check(failed.wait(timeout:.now()+3) == .success, "failure delivered")
check(failureClose.wait(timeout:.now()+3) == .success, "failure closes")
check(!broken.send(id:2,data:Data("x".utf8),onFailure:noError), "failure rejects subsequent")
let pipe = Pipe(), brokenPipe = DispatchSemaphore(value:0)
try pipe.fileHandleForReading.close()
let pipeWriter = try CenterRequestWriter(handle:pipe.fileHandleForWriting)
check(pipeWriter.send(id:1,data:Data("x".utf8),onFailure:{ _ in brokenPipe.signal() }), "broken pipe accepted")
check(brokenPipe.wait(timeout:.now()+3) == .success, "broken pipe fails without SIGPIPE termination")
print("Center request writer tests passed")
