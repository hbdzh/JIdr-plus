// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Serializes lightweight panel transitions. The active panel remains active
/// until its window has finished disappearing; only then may the next open.
final class PanelCoordinator<Panel: Equatable> {
    private(set) var active: Panel?
    private(set) var desired: Panel?
    private(set) var isClosing = false
    private var generation = 0
    private var afterClose: [() -> Void] = []
    private var stopped = false
    private let present: (Panel) -> Void
    private let dismiss: (Panel, @escaping () -> Void) -> Void
    private let didDismiss: (Panel) -> Void

    init(present: @escaping (Panel) -> Void,
         dismiss: @escaping (Panel, @escaping () -> Void) -> Void,
         didDismiss: @escaping (Panel) -> Void) {
        self.present = present
        self.dismiss = dismiss
        self.didDismiss = didDismiss
    }

    func request(_ panel: Panel?) {
        guard !stopped else { return }
        desired = panel
        advance()
    }

    /// The callback runs after the currently displayed window is gone, even
    /// when another panel is requested while it is closing.
    func dismissCurrent(after completion: @escaping () -> Void = {}) {
        guard !stopped else { return }
        guard active != nil else { desired = nil; completion(); return }
        afterClose.append(completion)
        request(nil)
    }

    func shutdown() {
        stopped = true
        generation += 1
        active = nil
        desired = nil
        isClosing = false
        afterClose.removeAll()
    }

    private func advance() {
        guard !stopped, !isClosing, active != desired else { return }
        if let current = active {
            isClosing = true
            generation += 1
            let token = generation
            dismiss(current) { [weak self] in
                guard let self, !self.stopped, self.isClosing, self.generation == token else { return }
                self.active = nil
                self.isClosing = false
                self.didDismiss(current)
                let callbacks = self.afterClose
                self.afterClose.removeAll()
                callbacks.forEach { $0() }
                self.advance()
            }
        } else if let next = desired {
            active = next
            present(next)
        }
    }
}
