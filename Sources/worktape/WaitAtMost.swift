import Synchronization

func waitAtMost<Value: Sendable>(
    _ timeout: Duration,
    orReturn fallback: Value,
    for start: (@escaping @Sendable (Value) -> Void) -> Void
) async -> Value {
    await withCheckedContinuation { continuation in
        let once = ResumeOnce(continuation)
        start { once.resume(returning: $0) }
        Task {
            try? await Task.sleep(for: timeout)
            once.resume(returning: fallback)
        }
    }
}

private final class ResumeOnce<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<Value, Never>?>

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(returning value: Value) {
        continuation.withLock { $0.take() }?.resume(returning: value)
    }
}
