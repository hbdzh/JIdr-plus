// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Retries a transient app-list failure without letting an old device request
/// update a newer selection. All methods and callbacks run on the main queue.
final class AppListLoader<Value> {
    typealias Request = (@escaping (Result<Value,Error>) -> Void) -> Void
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Void
    private var generation: UInt64 = 0
    private let delays: [TimeInterval]
    private let schedule: Scheduler

    init(delays: [TimeInterval] = [1, 2, 4, 8], schedule: @escaping Scheduler = { delay, action in
        DispatchQueue.main.asyncAfter(deadline:.now() + delay, execute:action)
    }) {
        self.delays = delays
        self.schedule = schedule
    }
    func cancel() { generation &+= 1 }
    func load(isCurrent: @escaping () -> Bool, request: @escaping Request,
              onRetry: @escaping () -> Void, completion: @escaping (Result<Value,Error>) -> Void) {
        cancel()
        let token = generation
        func attempt(_ index: Int) {
            guard generation == token, isCurrent() else { return }
            request { [weak self] result in
                guard let self, self.generation == token, isCurrent() else { return }
                switch result {
                case .success: completion(result)
                case .failure where index < self.delays.count:
                    onRetry()
                    self.schedule(self.delays[index]) { [weak self] in
                        guard let self, self.generation == token, isCurrent() else { return }
                        attempt(index + 1)
                    }
                case .failure: completion(result)
                }
            }
        }
        attempt(0)
    }
}
