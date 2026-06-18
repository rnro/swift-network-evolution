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

#if canImport(BasicContainers)
import BasicContainers
internal import DequeModule
#endif

#if canImport(Glibc)
import Glibc
internal import Logging
#elseif canImport(os)
internal import os
#endif

protocol TimerUser {
    var timerID: Timer.TimerID? { get set }
    func timerFired(timeNow: NetworkClock.Instant)
}

protocol NonCopyableTimerUser: ~Copyable {
    var timerID: Timer.TimerID? { get set }
    mutating func timerFired(timeNow: NetworkClock.Instant)
}

private struct TimerEntry: ~Copyable {
    enum State {
        case disabled
        case scheduled(Scheduled)

        struct Scheduled {
            let deadline: NetworkClock.Instant
        }

        mutating func disable() {
            self = .disabled
        }

        mutating func schedule(fromNow: NetworkDuration, timerNow: NetworkClock.Instant = .now) {
            precondition(fromNow != .zero)
            self = .scheduled(Scheduled(deadline: timerNow.advanced(by: fromNow)))
        }
    }

    let identifier: Timer.TimerID
    var state: State = .disabled
    let description: String
    let closure: () -> Void

    init(identifier: Timer.TimerID, description: String, closure: @escaping () -> Void) {
        self.identifier = identifier
        self.description = description
        self.closure = closure
    }

    mutating func disable() {
        self.state.disable()
    }

    mutating func schedule(fromNow: NetworkDuration, timerNow: NetworkClock.Instant = .now) {
        self.state.schedule(fromNow: fromNow, timerNow: timerNow)
    }
}

// TODO: convert timer to ~Copyable
final class Timer: PrefixedLoggable {
    typealias TimerID = UInt8

    /// The Timer's scheduling state.
    ///
    /// `.idle` means no entry is enabled and no OS wakeup is armed.
    /// `.armed(_)` means at least one entry is enabled and the OS wakeup is
    /// scheduled to fire at `armed.nextDeadline`. `.stopped` is terminal: it
    /// is reached only via `stop(final: true)` and locks out further
    /// scheduling.
    private enum SchedulingState: CustomStringConvertible {
        case idle
        case armed(Armed)
        case stopped

        struct Armed {
            let nextDeadline: NetworkClock.Instant
        }

        var nextDeadline: NetworkClock.Instant? {
            switch self {
            case .idle, .stopped: return nil
            case .armed(let schedule): return schedule.nextDeadline
            }
        }

        // MARK: - Transitions

        enum StopAction {
            case noOp
            /// Was `.armed`, now `.idle` — caller must unschedule the OS wakeup.
            case unscheduleOnly
            /// Was `.idle`, now `.stopped` — caller must release entries / reference.
            case cleanupOnly
            /// Was `.armed`, now `.stopped` — caller must unschedule and release.
            case unscheduleAndCleanup
        }

        mutating func stop(final: Bool) -> StopAction {
            switch self {
            case .armed:
                if final {
                    self = .stopped
                    return .unscheduleAndCleanup
                } else {
                    self = .idle
                    return .unscheduleOnly
                }
            case .idle:
                if final {
                    self = .stopped
                    return .cleanupOnly
                } else {
                    return .noOp
                }
            case .stopped:
                return .noOp
            }
        }

        enum ArmAction {
            /// No side effect needed. The associated `IgnoreReason` is purely
            /// diagnostic — the caller should not act, but may want to log it.
            case ignore(IgnoreReason)

            /// Caller must call `scheduleWakeup(milliseconds: delta.milliseconds)`.
            case scheduleWakeup(
                delta: NetworkDuration,
                newDeadline: NetworkClock.Instant,
                oldDeadline: NetworkClock.Instant?
            )

            enum IgnoreReason {
                /// Currently armed within `threshold` of `newDeadline`.
                case alreadyScheduled
                /// Terminal state; the new deadline is silently dropped.
                case stopped
            }
        }

        mutating func arm(
            at newDeadline: NetworkClock.Instant,
            now: NetworkClock.Instant,
            threshold: NetworkDuration
        ) -> ArmAction {
            var delta = now.duration(to: newDeadline)
            // Don't allow times in the past.
            if delta < .zero { delta = .zero }
            let armedDeadline = now + delta

            switch self {
            case .stopped:
                return .ignore(.stopped)
            case .idle:
                self = .armed(.init(nextDeadline: armedDeadline))
                return .scheduleWakeup(delta: delta, newDeadline: armedDeadline, oldDeadline: nil)
            case .armed:
                // Read the current armed deadline via the non-mutating accessor to avoid a CoW
                guard let oldDeadline = self.nextDeadline else {
                    preconditionFailure("`.armed` must carry a `nextDeadline`")
                }

                // Skip if the existing armed deadline is already within
                // `threshold` of the new one. Only applies when the new
                // deadline is more than `threshold` in the future — urgent
                // (sub-threshold) deadlines always re-arm.
                if delta > threshold {
                    let deadlineDifference = newDeadline.duration(to: oldDeadline)
                    if deadlineDifference < threshold && deadlineDifference > (threshold * -1) {
                        return .ignore(.alreadyScheduled)
                    }
                }
                self = .armed(.init(nextDeadline: armedDeadline))
                return .scheduleWakeup(delta: delta, newDeadline: armedDeadline, oldDeadline: oldDeadline)
            }
        }

        enum TimerFiredAction {
            case proceed
            /// Late wakeup: scheduler is `.stopped`, ignore it.
            case ignore
        }

        func timerFired() -> TimerFiredAction {
            switch self {
            case .stopped: return .ignore
            case .idle, .armed: return .proceed
            }
        }

        var description: String {
            switch self {
            case .idle: return "idle"
            case .armed(let schedule): return "armed(nextDeadline: \(schedule.nextDeadline))"
            case .stopped: return "stopped"
            }
        }
    }

    var log: LogPrefixer
    private var reference: ProtocolInstanceReference? = nil
    private var nextID: TimerID = 1
    private var avoidRecalculate = false
    private var entries: NetworkUniqueDeque<TimerEntry> = .init(minimumCapacity: 4)
    #if DatapathLogging
    private let extraDebugging = true
    #else
    private let extraDebugging = false
    #endif
    private var state: SchedulingState = .idle

    var nextDeadline: NetworkClock.Instant? {
        self.state.nextDeadline
    }

    static let timerThreshold = NetworkDuration.milliseconds(1)

    init(reference: ProtocolInstanceReference, logPrefixer: LogPrefixer) {
        self.log = logPrefixer
        self.reference = reference
    }

    internal init(logPrefixer: LogPrefixer) {
        self.log = logPrefixer
    }

    func insert(
        description: String,
        fromNow: NetworkDuration = .zero,
        timerNow: NetworkClock.Instant = .now,
        closure: @escaping () -> Void
    ) -> TimerID {
        let identifier = nextID
        var entry = TimerEntry(identifier: nextID, description: description, closure: closure)
        if fromNow != .zero {
            entry.schedule(fromNow: fromNow, timerNow: timerNow)
        }
        entries.append(entry)
        nextID += 1
        if !avoidRecalculate {
            recalculate(timerNow)
        }
        log.datapath("added timer [T\(identifier)]")
        return identifier
    }

    func remove(_ identifier: TimerID) {
        // In theory, this should use find(), but that swaps entries which we don't want to do here.
        let entryCount = entries.count
        for i in 0..<entryCount {
            if entries[i].identifier == identifier {
                entries.remove(at: i)
                break
            }
        }
        log.datapath("removing timer [T\(identifier)]")
    }

    func stop(final: Bool = true) {
        switch self.state.stop(final: final) {
        case .noOp:
            break
        case .unscheduleOnly:
            log.debug("Stopping timer")
            reference?.unscheduleWakeup()
        case .cleanupOnly:
            entries.removeAll()
            reference = nil
        case .unscheduleAndCleanup:
            log.debug("Stopping timer")
            reference?.unscheduleWakeup()
            entries.removeAll()
            reference = nil
        }
    }

    private func recalculate(_ now: NetworkClock.Instant) {
        if extraDebugging {
            let entryCount = entries.count
            for i in 0..<entryCount {
                switch entries[i].state {
                case .disabled:
                    log.datapath(
                        "timer [T\(entries[i].identifier)] desc \(entries[i].description) (no deadline)"
                    )
                case .scheduled(let entry):
                    var fromNow: NetworkDuration = .zero
                    if entry.deadline > now {
                        fromNow = now.duration(to: entry.deadline)
                    }
                    log.datapath(
                        "timer [T\(entries[i].identifier)] desc \(entries[i].description) deadline \(entry.deadline) (\(fromNow) from now)"
                    )
                }
            }
        }

        // Find the earliest enabled deadline, if any.
        let entryCount = entries.count
        var earliestDeadline: NetworkClock.Instant? = nil
        for i in 0..<entryCount {
            switch entries[i].state {
            case .disabled:
                continue
            case .scheduled(let entry):
                if let current = earliestDeadline, current <= entry.deadline {
                    continue
                }
                earliestDeadline = entry.deadline
            }
        }

        guard let earliestDeadline else {
            log.debug("No more timers to run")
            stop(final: false)
            return
        }

        switch self.state.arm(at: earliestDeadline, now: now, threshold: Timer.timerThreshold) {
        case .ignore(.alreadyScheduled):
            log.datapath("timer already scheduled")
        case .ignore(.stopped):
            // `.stopped` is terminal — preserve the historical best-effort
            // behaviour of arming nothing rather than crashing if a stray
            // `recalculate` lands after `stop(final: true)`.
            break
        case .scheduleWakeup(let delta, let newDeadline, let oldDeadline):
            log.datapath(
                "arming timer for the next \(delta) (now \(now)), new deadline \(newDeadline) old deadline \(oldDeadline.map(String.init(describing:)) ?? "none")"
            )
            reference?.scheduleWakeup(milliseconds: UInt64(delta.milliseconds))
        }
    }

    private func find(_ identifier: TimerID) -> Int? {
        let entryCount = entries.count
        for i in 0..<entryCount {
            if entries[i].identifier == identifier {
                if i != 0 {
                    entries.swapAt(0, i)
                }
                return 0
            }
        }
        return nil
    }

    func reschedule(
        identifier: TimerID,
        fromNow: NetworkDuration,
        timerNow: NetworkClock.Instant = .now
    ) {
        guard let index = find(identifier) else {
            return
        }
        if fromNow == .zero {
            switch entries[index].state {
            case .disabled:
                // Already disabled — leave the scheduling state untouched.
                return
            case .scheduled:
                entries[index].disable()
            }
        } else {
            entries[index].schedule(fromNow: fromNow, timerNow: timerNow)
        }
        if !avoidRecalculate {
            recalculate(timerNow)
        }
    }

    public func timerFired(timeNow: NetworkClock.Instant = .now) {
        // `.stopped` is terminal — wakeups should not fire after
        // `stop(final: true)`, but if one races through, ignore it.
        switch self.state.timerFired() {
        case .ignore:
            log.fault("Timer fired after it was cancelled")
            return
        case .proceed:
            break
        }
        // Due to timer leeway, we might actually be running a bit early, so
        // allow 1ms of leeway.
        let now = timeNow.advanced(by: Timer.timerThreshold)
        var ranOne = false

        avoidRecalculate = true
        if extraDebugging {
            log.datapath("running quic timer, now \(now)")
        }
        var index = 0
        while index < entries.count {
            switch entries[index].state {
            case .disabled:
                break
            case .scheduled(let entry):
                if entry.deadline <= now {
                    if extraDebugging {
                        log.datapath(
                            "calling timer closure for [T\(entries[index].identifier)] (\(entries[index].description)) (deadline \(entry.deadline) <= now \(now))"
                        )
                    }
                    entries[index].disable()
                    entries[index].closure()
                    ranOne = true
                } else if extraDebugging {
                    log.datapath(
                        "timer [T\(entries[index].identifier)] desc \(entries[index].description) has deadline \(entry.deadline) > now \(now)"
                    )
                }
            }
            index += 1
        }

        if _slowPath(!ranOne) {
            let entryCount = entries.count
            for i in 0..<entryCount {
                switch entries[i].state {
                case .disabled:
                    log.error("Timer [T\(entries[i].identifier)] disabled, now \(now)")
                case .scheduled(let entry):
                    log.error("Timer [T\(entries[i].identifier)] deadline \(entry.deadline), now \(now)")
                }
            }
            log.fault(
                "Spurious timer at \(now)), state \(self.state), next deadline \(self.nextDeadline.map(String.init(describing:)) ?? "none")"
            )
        }
        recalculate(timeNow)
        avoidRecalculate = false
    }
}
#endif
