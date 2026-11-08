/// Caps how many directory reads are in flight at once.
///
/// Directory reads are blocking syscalls. Letting a deep tree spawn one task
/// per directory would swamp the cooperative thread pool, so a walk takes a
/// permit before reading and returns it afterwards.
actor ConcurrencyLimiter {
    private let limit: Int
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async {
        if active < limit {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }

    func release() {
        if let next = waiting.first {
            waiting.removeFirst()
            next.resume()
        } else {
            active -= 1
        }
    }
}
