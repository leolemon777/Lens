import Foundation

/// Serializes per-package recording post-processing without polling. A caller
/// that arrives while its package key is held suspends on a continuation
/// until the holder hands the key over; different packages never wait on
/// each other. This replaces a 120 ms `Task.sleep` spin loop that kept the
/// main actor busy between checks.
actor RecordingProcessingGate {
    private var holders: Set<URL> = []
    private var waiters: [URL: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ key: URL) async {
        if holders.insert(key).inserted { return }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    /// Hands the key directly to the first waiter rather than dropping it,
    /// so release-and-reacquire races cannot cut ahead of queued callers.
    func release(_ key: URL) {
        guard holders.contains(key) else { return }
        if let first = waiters[key]?.first {
            waiters[key]?.removeFirst()
            first.resume()
        } else {
            holders.remove(key)
            waiters[key] = nil
        }
    }
}
