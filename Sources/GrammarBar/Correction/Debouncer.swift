import Foundation

final class Debouncer {
    private var workItem: DispatchWorkItem?
    var delay: TimeInterval

    init(delay: TimeInterval = 0.4) {
        self.delay = delay
    }

    func schedule(action: @escaping @Sendable () -> Void) {
        workItem?.cancel()
        let item = DispatchWorkItem(block: action)
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        workItem?.cancel()
        workItem = nil
    }
}
