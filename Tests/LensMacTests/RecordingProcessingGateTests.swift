import XCTest
@testable import LensMac

private actor GateTrace {
    private var entries: [Int] = []
    private var exits: [Int] = []
    private var active = 0
    private var maxActive = 0

    func enter(_ id: Int) {
        entries.append(id)
        active += 1
        maxActive = max(maxActive, active)
    }

    func exit(_ id: Int) {
        exits.append(id)
        active -= 1
    }

    func snapshot() -> (entries: [Int], exits: [Int], peakActive: Int) {
        (entries, exits, maxActive)
    }
}

/// Lets the test wait until the first worker actually holds the gate before
/// spawning the queued worker, because `async let` child tasks may start in
/// any order and the queue-order assertions need a deterministic arrival.
private actor StartedSignal {
    private var isStarted = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func start() {
        isStarted = true
        continuations.forEach { $0.resume() }
        continuations = []
    }

    func wait() async {
        if isStarted { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
}

final class RecordingProcessingGateTests: XCTestCase {
    /// Same-package callers must never overlap and must keep their queue
    /// order, while a different package proceeds concurrently instead of
    /// waiting behind unrelated work.
    func testSameKeySerializesInArrivalOrderWhileDifferentKeysOverlap() async throws {
        let gate = RecordingProcessingGate()
        let trace = GateTrace()
        let started = StartedSignal()
        let package = URL(fileURLWithPath: "/tmp/lens-recording.lens")
        let otherPackage = URL(fileURLWithPath: "/tmp/lens-other.lens")

        func work(_ id: Int, key: URL, signal: StartedSignal? = nil) async {
            await gate.acquire(key)
            await trace.enter(id)
            await signal?.start()
            try? await Task.sleep(for: .milliseconds(200))
            await trace.exit(id)
            await gate.release(key)
        }

        async let firstWork = work(1, key: package, signal: started)
        await started.wait()
        async let queuedWork = work(2, key: package)
        async let otherWork = work(3, key: otherPackage)
        _ = await (firstWork, queuedWork, otherWork)

        let snapshot = await trace.snapshot()
        let firstEntry = try XCTUnwrap(snapshot.entries.firstIndex(of: 1))
        let queuedEntry = try XCTUnwrap(snapshot.entries.firstIndex(of: 2))
        XCTAssertEqual(firstEntry, 0, "首个持锁者应最先进入。")
        XCTAssertLessThan(
            firstEntry,
            queuedEntry,
            "同包第二个调用者必须排在第一个之后。"
        )
        let firstExit = try XCTUnwrap(snapshot.exits.firstIndex(of: 1))
        XCTAssertLessThan(
            firstExit,
            queuedEntry,
            "第一个持有者完全退出后，排队者才能进入。"
        )
        XCTAssertGreaterThanOrEqual(
            snapshot.peakActive,
            2,
            "不同包的调用者应能并发执行，而不是互相排队。"
        )
    }
}
