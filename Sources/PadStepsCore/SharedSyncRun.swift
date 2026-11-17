import Foundation

/// Multiple lifecycle triggers may share work, but cancellation belongs to the
/// requesting trigger. The shared operation ends only when no requester remains.
@MainActor
public final class SharedSyncRun {
    private struct Waiter { let generation: Int; let continuation: CheckedContinuation<Bool, Never> }
    private let operation: @MainActor @Sendable () async -> Void
    private var task: Task<Void, Never>?
    private var generation = 0
    private var cancelling = false
    private var waiters: [UUID: Waiter] = [:]
    public var isRunning: Bool { task != nil }
    public var waiterCount: Int { waiters.count }
    public init(operation: @escaping @MainActor @Sendable () async -> Void) { self.operation = operation }

    @discardableResult public func run() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                let target = task == nil ? generation + 1 : generation + (cancelling ? 1 : 0)
                waiters[id] = Waiter(generation: target, continuation: continuation)
                if task == nil { start(target) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }
    public func cancelAll() {
        let pending = waiters; waiters = [:]
        for value in pending.values { value.continuation.resume(returning: false) }
        if task != nil { cancelling = true; task?.cancel() }
    }
    private func cancel(_ id: UUID) {
        guard let value = waiters.removeValue(forKey: id) else { return }
        value.continuation.resume(returning: false)
        if task != nil, !waiters.values.contains(where: { $0.generation == generation }) {
            cancelling = true; task?.cancel()
        }
    }
    private func start(_ number: Int) {
        generation = number; cancelling = false
        task = Task {
            await operation()
            finish(number, completed: !Task.isCancelled)
        }
    }
    private func finish(_ number: Int, completed: Bool) {
        guard generation == number else { return }
        task = nil
        let finished = waiters.filter { $0.value.generation == number }
        for (id, value) in finished { waiters[id] = nil; value.continuation.resume(returning: completed) }
        if let next = waiters.values.map(\.generation).min() { start(next) }
    }
}
