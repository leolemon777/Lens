import Foundation

/// Serializes per-package recording post-processing without polling. A caller
/// that arrives while its package key is held suspends on a continuation
/// until the holder hands the key over; different packages never wait on
/// each other. This replaces a 120 ms `Task.sleep` spin loop that kept the
/// main actor busy between checks.
actor RecordingProcessingGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var holders: Set<URL> = []
    private var waiters: [URL: [Waiter]] = [:]
    private var pendingRegistrations: Set<UUID> = []
    private var cancelledRegistrations: Set<UUID> = []

    /// Returns whether the caller owns a gate slot. A canceled waiter is
    /// removed without consuming the slot, so a canceled render cannot keep
    /// a later task blocked forever.
    @discardableResult
    func acquire(_ key: URL) async -> Bool {
        if Task.isCancelled { return false }
        if holders.insert(key).inserted { return true }
        let waiterID = UUID()
        pendingRegistrations.insert(waiterID)
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || cancelledRegistrations.remove(waiterID) != nil {
                    pendingRegistrations.remove(waiterID)
                    continuation.resume(returning: false)
                } else {
                    pendingRegistrations.remove(waiterID)
                    waiters[key, default: []].append(
                        Waiter(id: waiterID, continuation: continuation)
                    )
                }
            }
        }, onCancel: {
            Task { await self.cancel(waiterID, for: key) }
        })
    }

    private func cancel(_ waiterID: UUID, for key: URL) {
        if var queued = waiters[key],
           let index = queued.firstIndex(where: { $0.id == waiterID }) {
            let waiter = queued.remove(at: index)
            waiters[key] = queued.isEmpty ? nil : queued
            waiter.continuation.resume(returning: false)
            return
        }
        if pendingRegistrations.contains(waiterID) {
            cancelledRegistrations.insert(waiterID)
        }
    }

    /// Hands the key directly to the first waiter rather than dropping it,
    /// so release-and-reacquire races cannot cut ahead of queued callers.
    func release(_ key: URL) {
        guard holders.contains(key) else { return }
        if let first = waiters[key]?.first {
            waiters[key]?.removeFirst()
            if waiters[key]?.isEmpty == true { waiters[key] = nil }
            first.continuation.resume(returning: true)
        } else {
            holders.remove(key)
            waiters[key] = nil
        }
    }
}
