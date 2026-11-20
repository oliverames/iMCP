import Foundation
import XCTest
import os

/// These scripts send no Apple events to other apps.
final class AppleScriptTests: XCTestCase {
    @MainActor
    func testScriptsRunOffTheMainThread() async throws {
        // Hold the serial queue. A script that ran on the main actor
        // would finish anyway; a script on the queue waits.
        let release = DispatchSemaphore(value: 0)
        NSAppleScript.executionQueue.async { release.wait() }

        let finished = OSAllocatedUnfairLock(initialState: false)
        let script = Task { @MainActor in
            defer { finished.withLock { $0 = true } }
            return try await NSAppleScript.execute("return 1 + 1").int32Value
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(finished.withLock { $0 }, "the script did not wait for the queue")

        release.signal()
        let sum = try await script.value
        XCTAssertEqual(sum, 2)
    }

    func testCancelledTasksRunNoScript() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NSAppleScript.execute("return 2").int32Value
        }
        do {
            _ = try await task.value
            XCTFail("expected a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testCancellingAQueuedScriptStopsItBeforeItRuns() async throws {
        // Hold the serial queue, so that the script waits until after it is cancelled.
        let release = DispatchSemaphore(value: 0)
        NSAppleScript.executionQueue.async { release.wait() }

        let queued = Task { try await NSAppleScript.execute("return 2").int32Value }
        try await Task.sleep(for: .milliseconds(50))
        queued.cancel()
        release.signal()

        do {
            let result = try await queued.value
            XCTFail("the queued script ran and returned \(result)")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testScriptErrorsKeepTheirNumberAndMessage() async {
        do {
            _ = try await NSAppleScript.execute("error \"Not allowed.\" number -1743")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(
                error as? NSAppleScript.ExecutionError,
                NSAppleScript.ExecutionError(number: -1743, message: "Not allowed.")
            )
        }

        do {
            _ = try await NSAppleScript.execute("return (")
            XCTFail("expected a compile error")
        } catch {
            XCTAssertNotNil((error as? NSAppleScript.ExecutionError)?.number)
        }
    }

    func testBeforeSendingRunsImmediatelyBeforeTheScript() async throws {
        let marker = OSAllocatedUnfairLock(initialState: 0)
        let result = try await NSAppleScript.execute("return 7") {
            marker.withLock { $0 = 1 }
        }
        XCTAssertEqual(result.int32Value, 7)
        XCTAssertEqual(marker.withLock { $0 }, 1)

        struct Stop: Error {}
        do {
            _ = try await NSAppleScript.execute("error \"ran\" number 1") { throw Stop() }
            XCTFail("expected the hook's error")
        } catch {
            XCTAssertTrue(error is Stop, "\(error)")
        }
    }

    /// A task cancelled while the hook is running must not start the script.
    func testCancellingDuringTheHookStopsTheScript() async throws {
        let started = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            try await NSAppleScript.execute("return 3") {
                started.withLock { $0 = true }
                release.wait()
            }.int32Value
        }
        // Wait until the hook is inside the script queue, then cancel.
        for _ in 0 ..< 1000 where !started.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(started.withLock { $0 }, "the hook never ran")
        task.cancel()
        release.signal()
        do {
            _ = try await task.value
            XCTFail("the script ran after the task was cancelled during the hook")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
