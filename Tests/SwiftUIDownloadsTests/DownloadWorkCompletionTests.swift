import Foundation
import XCTest
@testable import SwiftUIDownloads

final class DownloadWorkCompletionTests: XCTestCase, @unchecked Sendable {
    func testFinishingBeforeWaitReturnsImmediately() async {
        let completion = DownloadWorkCompletion()
        completion.finish()
        let result = await completion.wait()
        XCTAssertTrue(result)
    }

    func testProducerCompletionReleasesAllWaiters() async {
        let completion = DownloadWorkCompletion()
        let tasks = (0..<100).map { _ in Task { await completion.wait() } }
        completion.finish()
        for task in tasks {
            let result = await task.value
            XCTAssertTrue(result)
        }
    }

    func testWaitDoesNotReportCompletionBeforeProducerFinishes() async {
        let completion = DownloadWorkCompletion()
        let returned = expectation(description: "waiter returned")
        returned.isInverted = true
        let waiter = Task {
            let result = await completion.wait()
            returned.fulfill()
            return result
        }
        await fulfillment(of: [returned], timeout: 0.05)
        completion.finish()
        let result = await waiter.value
        XCTAssertTrue(result)
    }

    func testCancelledWaiterReturnsWhileProducerRemainsHeld() async {
        let completion = DownloadWorkCompletion()
        let returned = expectation(description: "cancelled waiter returned")
        let waiter = Task {
            let result = await completion.wait()
            returned.fulfill()
            return result
        }
        waiter.cancel()
        let outcome = await XCTWaiter.fulfillment(of: [returned], timeout: 2)
        // Always release a broken implementation before awaiting its task.
        completion.finish()
        let result = await waiter.value
        XCTAssertEqual(outcome, .completed)
        XCTAssertFalse(result)
    }

    func testCancellationDoesNotFinishSignalForOtherWaiters() async {
        let completion = DownloadWorkCompletion()
        let cancelled = Task { await completion.wait() }
        cancelled.cancel()
        let returned = expectation(description: "unrelated waiter must remain held")
        returned.isInverted = true
        let survivor = Task {
            let result = await completion.wait()
            returned.fulfill()
            return result
        }
        await fulfillment(of: [returned], timeout: 0.05)
        completion.finish()
        let cancelledResult = await cancelled.value
        let survivorResult = await survivor.value
        XCTAssertFalse(cancelledResult)
        XCTAssertTrue(survivorResult)
    }

    func testAlreadyCancelledCallerCannotLoseCancellationBeforeRegistration() async {
        let completion = DownloadWorkCompletion()
        let start = DownloadWorkCompletion()
        let returned = expectation(description: "already cancelled waiter returned")
        let task = Task {
            _ = await start.wait()
            let result = await completion.wait()
            returned.fulfill()
            return result
        }
        task.cancel()
        start.finish()
        let outcome = await XCTWaiter.fulfillment(of: [returned], timeout: 2)
        completion.finish()
        let result = await task.value
        XCTAssertEqual(outcome, .completed)
        XCTAssertFalse(result)
    }

    func testCancelledCallerDoesNotClaimPreviouslyFinishedSignal() async {
        let completion = DownloadWorkCompletion()
        completion.finish()
        let start = DownloadWorkCompletion()
        let task = Task {
            _ = await start.wait()
            return await completion.wait()
        }
        task.cancel()
        start.finish()
        let result = await task.value
        XCTAssertFalse(result)
    }

    func testRepeatedFinishIsIdempotent() async {
        let completion = DownloadWorkCompletion()
        let task = Task { await completion.wait() }
        for _ in 0..<100 { completion.finish() }
        let result = await task.value
        let subsequent = await completion.wait()
        XCTAssertTrue(result)
        XCTAssertTrue(subsequent)
    }

    func testCompletionAndCancellationRaceResumesEveryWaiterExactlyOnce() async {
        for _ in 0..<100 {
            let completion = DownloadWorkCompletion()
            let tasks = (0..<20).map { _ in Task { await completion.wait() } }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { completion.finish() }
                group.addTask { tasks.forEach { $0.cancel() } }
            }
            for task in tasks { _ = await task.value }
            let subsequent = await completion.wait()
            XCTAssertTrue(subsequent)
        }
    }

    func testSeparateAttemptsNeverShareCompletion() async {
        let old = DownloadWorkCompletion()
        let replacement = DownloadWorkCompletion()
        old.finish()
        let returned = expectation(description: "replacement must await its own completion")
        returned.isInverted = true
        let task = Task {
            let result = await replacement.wait()
            returned.fulfill()
            return result
        }
        await fulfillment(of: [returned], timeout: 0.05)
        replacement.finish()
        let result = await task.value
        XCTAssertTrue(result)
    }
}
