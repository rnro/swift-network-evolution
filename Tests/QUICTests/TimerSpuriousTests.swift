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
#elseif canImport(Network)
@_spi(Essentials) @_spi(ProtocolProvider) @testable import Network
#endif

#if canImport(SwiftNetwork)
private typealias TimerSpuriousTimer = SwiftNetwork.Timer
#elseif canImport(Network)
private typealias TimerSpuriousTimer = Network.Timer
#endif

let timerSpuriousTestsLogPrefixer = LogPrefixer("[TimerSpuriousTests]")

/// Targeted tests for the timer state machine covering the patterns from the
/// `swift-nio-quic` CI hang in `SyncIntegrationTests.testHTTP09ManyStreamsStreaming`.
///
/// CI log just before the wedge:
///
///     Timer [T1] deadline 479.471 s, now 479.471 s
///     Timer [T2] deadline 0 ns,      now 479.471 s
///     Timer [T3] deadline 0 ns,      now 479.471 s
///     Timer [T4] deadline 508.749 s, now 479.471 s
///     Timer [T5] deadline 0 ns,      now 479.471 s
///     Spurious timer at 479.471 s), next deadline 479.471 s, cancelled? false
///
/// Three of five timers were disabled (`deadline == .zero` from `reschedule(.zero)` /
/// `disable()`), one was due, one was future. The "Spurious timer" branch in
/// `Timer.timerFired` fires when no entry is selected, which under nanosecond clock
/// drift can happen even when the millisecond-truncated log makes T1 look due. These
/// tests pin down the post-state invariants for that fleet shape.
final class TimerSpuriousTests: XCTestCase {

    /// Repro of the CI fleet: 5 entries, three disabled, one due, one future. The due
    /// timer must fire on the next `timerFired`, and the disabled entries must not
    /// trip the `Spurious timer` branch.
    func testFleetWithDisabledEntriesFiresTheDueOne() {
        let timer = TimerSpuriousTimer(logPrefixer: timerSpuriousTestsLogPrefixer)
        let dueSemaphore = DispatchSemaphore(value: 0)
        let futureSemaphore = DispatchSemaphore(value: 0)
        let disabledSemaphore = DispatchSemaphore(value: 0)

        // T1 — due timer at 1000 ms.
        let t1 = timer.insert(
            description: "due",
            fromNow: .milliseconds(1000),
            timerNow: .zero
        ) {
            dueSemaphore.signal()
        }
        // T2 — initially disabled (inserted with `fromNow: .zero`).
        let t2 = timer.insert(description: "disabled-2", timerNow: .zero) {
            disabledSemaphore.signal()
        }
        // T3 — scheduled then disabled via `reschedule(.zero)`.
        let t3 = timer.insert(
            description: "disabled-3",
            fromNow: .milliseconds(750),
            timerNow: .zero
        ) {
            disabledSemaphore.signal()
        }
        timer.reschedule(identifier: t3, fromNow: .zero, timerNow: .zero)
        // T4 — future timer at 5000 ms (should not fire yet).
        let t4 = timer.insert(
            description: "future",
            fromNow: .milliseconds(5000),
            timerNow: .zero
        ) {
            futureSemaphore.signal()
        }
        // T5 — initially disabled.
        let t5 = timer.insert(description: "disabled-5", timerNow: .zero) {
            disabledSemaphore.signal()
        }

        // Fleet's earliest deadline must be T1's 1000 ms.
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 1000))

        // Fire at exactly the due timer's deadline — only T1 should run.
        timer.timerFired(timeNow: .init(milliseconds: 1000))

        XCTAssertEqual(
            dueSemaphore.wait(timeout: .now() + .seconds(1)),
            .success,
            "Due timer must run when fired at its deadline"
        )
        XCTAssertEqual(
            disabledSemaphore.wait(timeout: .now() + .milliseconds(50)),
            .timedOut,
            "Disabled timers must not fire"
        )
        XCTAssertEqual(
            futureSemaphore.wait(timeout: .now() + .milliseconds(50)),
            .timedOut,
            "Future timer must not fire yet"
        )

        // After T1 fires, nextDeadline should advance to T4's 5000 ms.
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 5000))

        timer.remove(t1)
        timer.remove(t2)
        timer.remove(t3)
        timer.remove(t4)
        timer.remove(t5)
    }

    /// `reschedule(.zero)` on the only enabled entry must clear `nextDeadline` —
    /// otherwise a stale `nextDeadline` survives and trips the spurious-timer branch
    /// when the OS later fires the (now disabled) wakeup.
    func testRescheduleZeroOnSoleEnabledEntryClearsNextDeadline() {
        let timer = TimerSpuriousTimer(logPrefixer: timerSpuriousTestsLogPrefixer)
        let semaphore = DispatchSemaphore(value: 0)
        let id = timer.insert(
            description: "lone",
            fromNow: .milliseconds(1000),
            timerNow: .zero
        ) {
            semaphore.signal()
        }
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 1000))

        // Disable it. nextDeadline should fall back to nil (no scheduled work).
        timer.reschedule(identifier: id, fromNow: .zero, timerNow: .zero)
        XCTAssertNil(
            timer.nextDeadline,
            "nextDeadline must clear when the only enabled entry is disabled"
        )

        // Confirm the closure does not fire.
        timer.timerFired(timeNow: .init(milliseconds: 1000))
        XCTAssertEqual(
            semaphore.wait(timeout: .now() + .milliseconds(50)),
            .timedOut,
            "Disabled timer must not fire"
        )
        timer.remove(id)
    }

    /// `reschedule(.zero)` on one of several enabled entries must leave
    /// `nextDeadline` aligned with the remaining earliest enabled deadline, not stuck
    /// at the disabled entry's old deadline.
    func testRescheduleZeroOnEarliestPicksNextEarliest() {
        let timer = TimerSpuriousTimer(logPrefixer: timerSpuriousTestsLogPrefixer)
        let earlySem = DispatchSemaphore(value: 0)
        let lateSem = DispatchSemaphore(value: 0)

        let early = timer.insert(
            description: "early",
            fromNow: .milliseconds(1000),
            timerNow: .zero
        ) {
            earlySem.signal()
        }
        let late = timer.insert(
            description: "late",
            fromNow: .milliseconds(3000),
            timerNow: .zero
        ) {
            lateSem.signal()
        }
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 1000))

        // Disable the earliest. nextDeadline should advance to the late entry.
        timer.reschedule(identifier: early, fromNow: .zero, timerNow: .zero)
        XCTAssertEqual(
            timer.nextDeadline,
            .init(milliseconds: 3000),
            "nextDeadline must follow the next earliest enabled entry after a disable"
        )

        // Fire at the disabled entry's old deadline — nothing runs, but no crash.
        timer.timerFired(timeNow: .init(milliseconds: 1000))
        XCTAssertEqual(
            earlySem.wait(timeout: .now() + .milliseconds(50)),
            .timedOut,
            "Disabled early timer must not fire"
        )
        XCTAssertEqual(
            lateSem.wait(timeout: .now() + .milliseconds(50)),
            .timedOut,
            "Late timer must not fire yet"
        )

        // The late timer must still run when its deadline arrives.
        timer.timerFired(timeNow: .init(milliseconds: 3000))
        XCTAssertEqual(
            lateSem.wait(timeout: .now() + .seconds(1)),
            .success,
            "Late timer must fire at its deadline after the early one was disabled"
        )

        timer.remove(early)
        timer.remove(late)
    }

    /// The spurious-timer path: `timerFired` called slightly *before* the only enabled
    /// entry's deadline (i.e. an early OS wakeup beyond the 1 ms leeway). The entry
    /// must NOT be lost — a later `timerFired` at the real deadline must still run it.
    func testEarlyTimerFiredDoesNotDropPendingEntry() {
        let timer = TimerSpuriousTimer(logPrefixer: timerSpuriousTestsLogPrefixer)
        let semaphore = DispatchSemaphore(value: 0)
        let id = timer.insert(
            description: "due",
            fromNow: .milliseconds(1000),
            timerNow: .zero
        ) {
            semaphore.signal()
        }
        XCTAssertEqual(timer.nextDeadline, .init(milliseconds: 1000))

        // Fire 5 ms early — beyond the 1 ms leeway, so the entry must not fire here.
        // This is the "spurious" path: no entry runs, recalculate re-arms.
        timer.timerFired(timeNow: .init(milliseconds: 995))
        XCTAssertEqual(
            semaphore.wait(timeout: .now() + .milliseconds(50)),
            .timedOut,
            "Early-fire below leeway must not run the entry"
        )

        // The entry must still be enabled and `nextDeadline` must still point at 1000ms.
        XCTAssertEqual(
            timer.nextDeadline,
            .init(milliseconds: 1000),
            "nextDeadline must remain at the original deadline after a spurious early fire"
        )

        // Now fire at the real deadline — entry must run.
        timer.timerFired(timeNow: .init(milliseconds: 1000))
        XCTAssertEqual(
            semaphore.wait(timeout: .now() + .seconds(1)),
            .success,
            "Entry must fire at its real deadline after an earlier spurious wakeup"
        )

        timer.remove(id)
    }
}

#endif
