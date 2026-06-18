//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if !NETWORK_NO_SWIFT_QUIC

import XCTest

#if canImport(SwiftNetwork)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import SwiftNetwork
typealias QUICTimer = SwiftNetwork.Timer
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
typealias QUICTimer = Network.Timer
#endif

let timerTestsLogPrefixer = LogPrefixer("[TimerTests]")

final class TimerTests: XCTestCase {

    func testOneTimer() {
        let timer = QUICTimer(logPrefixer: timerTestsLogPrefixer)
        let semaphore = DispatchSemaphore(value: 0)
        let oneId = timer.insert(description: "one", fromNow: .milliseconds(1000), timerNow: .zero) {
            semaphore.signal()
        }
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 1000))
        timer.timerFired(timeNow: .init(milliseconds: 1000))
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(1)),
            DispatchTimeoutResult.success
        )
        timer.remove(oneId)
    }

    func testReschedule() {
        let timer = QUICTimer(logPrefixer: timerTestsLogPrefixer)
        let semaphore = DispatchSemaphore(value: 0)
        let oneId = timer.insert(description: "one-reschedule", timerNow: .zero) {
            semaphore.signal()
        }
        XCTAssertNil(timer.nextDeadline)
        timer.reschedule(identifier: oneId, fromNow: .milliseconds(1000), timerNow: .zero)
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 1000))
        timer.timerFired(timeNow: .init(milliseconds: 1000))
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(1)),
            DispatchTimeoutResult.success
        )
        timer.remove(oneId)
    }

    func testTwoTimersAtSameTime() throws {
        let timer = QUICTimer(logPrefixer: timerTestsLogPrefixer)
        let semaphore = DispatchSemaphore(value: 0)
        let oneId = timer.insert(description: "one", fromNow: .milliseconds(1000), timerNow: .zero) {
            semaphore.signal()
        }
        let twoId = timer.insert(description: "two", fromNow: .milliseconds(1000), timerNow: .zero) {
            semaphore.signal()
        }
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 1000))
        timer.timerFired(timeNow: .init(milliseconds: 1000))
        XCTAssertNotEqual(oneId, twoId)
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(2)),
            DispatchTimeoutResult.success
        )
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(2)),
            DispatchTimeoutResult.success
        )
        timer.remove(oneId)
        timer.remove(twoId)
    }

    func testTwoTimersAtDifferentTimes() throws {
        let timer = QUICTimer(logPrefixer: timerTestsLogPrefixer)
        let semaphore = DispatchSemaphore(value: 0)
        let oneId = timer.insert(description: "one", fromNow: .milliseconds(2000), timerNow: .zero) {
            semaphore.signal()
        }
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 2000))
        let twoId = timer.insert(description: "two", fromNow: .milliseconds(1000), timerNow: .zero) {
            semaphore.signal()
        }
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 1000))
        timer.timerFired(timeNow: .init(milliseconds: 1000))
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 2000))
        timer.timerFired(timeNow: .init(milliseconds: 2000))
        XCTAssertNotEqual(oneId, twoId)
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(2)),
            DispatchTimeoutResult.success
        )
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(2)),
            DispatchTimeoutResult.success
        )
        timer.remove(oneId)
        timer.remove(twoId)
    }

    func testRecalculateAfterMissingTimer() throws {
        let timer = QUICTimer(logPrefixer: timerTestsLogPrefixer)
        let semaphore = DispatchSemaphore(value: 0)
        let oneId = timer.insert(description: "one", fromNow: .milliseconds(1000), timerNow: .zero) {
            semaphore.signal()
        }
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 1000))
        let twoId = timer.insert(description: "two", fromNow: .milliseconds(1000), timerNow: .init(milliseconds: 1500))
        {
            semaphore.signal()
        }
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 1500))
        timer.timerFired(timeNow: .init(milliseconds: 1500))
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 2500))
        timer.timerFired(timeNow: .init(milliseconds: 2500))
        XCTAssertNotEqual(oneId, twoId)
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(2)),
            DispatchTimeoutResult.success
        )
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(2)),
            DispatchTimeoutResult.success
        )
        timer.remove(oneId)
        timer.remove(twoId)
    }

    // Test that recalculating within 1ms for future times doesn't update the timer
    func testRecalculateWithinThreshold() throws {
        let timer = QUICTimer(logPrefixer: timerTestsLogPrefixer)
        let semaphore = DispatchSemaphore(value: 0)
        let oneId = timer.insert(description: "one", fromNow: .microseconds(1_000_000), timerNow: .zero) {
            semaphore.signal()
        }
        XCTAssertEqual(timer.nextDeadline, .init(microseconds: 1_000_000))

        // Start a similar timer only 2 microseconds in the future
        let twoId = timer.insert(
            description: "two",
            fromNow: .microseconds(1_000_000),
            timerNow: .init(microseconds: 2)
        ) {
            semaphore.signal()
        }

        // Timer should stay the same
        XCTAssertEqual(timer.nextDeadline, .init(microseconds: 1_000_000))
        timer.timerFired(timeNow: .init(microseconds: 1_000_000))
        XCTAssertNotEqual(oneId, twoId)
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(2)),
            DispatchTimeoutResult.success
        )
        XCTAssertEqual(
            semaphore.wait(timeout: DispatchTime.now() + .seconds(2)),
            DispatchTimeoutResult.success
        )
        timer.remove(oneId)
        timer.remove(twoId)
    }

    func testAbsoluteNow() {
        XCTAssertGreaterThan(System.Time.nowAbsoluteNanoseconds(), 0)
    }
}

#endif
