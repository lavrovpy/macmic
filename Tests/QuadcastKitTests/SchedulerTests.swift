// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Dispatch
import Foundation
import Testing
@testable import QuadcastKit

@Suite @MainActor struct SchedulerTests {
    @Test func dispatchSchedulerZeroDelayRunsOnALaterTurnNotInline() async {
        let scheduler = DispatchScheduler()
        var ran = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            scheduler.schedule(after: 0) {
                dispatchPrecondition(condition: .onQueue(.main))
                ran = true
                continuation.resume()
            }
            #expect(ran == false)
        }

        #expect(ran)
    }

    @Test func dispatchSchedulerCancelBeforeRunPreventsIt() async {
        let scheduler = DispatchScheduler()
        var cancelledRuns = 0

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let immediate = scheduler.schedule(after: 0) { cancelledRuns += 1 }
            let delayed = scheduler.schedule(after: 0.02) { cancelledRuns += 1 }
            immediate.cancel()
            immediate.cancel()
            delayed.cancel()
            scheduler.schedule(after: 0.05) { continuation.resume() }
        }

        #expect(cancelledRuns == 0)
    }

    @Test func scheduleRepeatingRunsEveryIntervalUntilCancelled() {
        let scheduler = ManualScheduler()
        var runTimes: [TimeInterval] = []
        var pendingDuringRun: [Int] = []
        let work = scheduler.scheduleRepeating(every: 0.1) {
            runTimes.append(scheduler.now)
            pendingDuringRun.append(scheduler.pendingCount)
        }

        scheduler.advance(by: 0.09)
        #expect(runTimes.isEmpty)

        scheduler.advance(by: 0.02)
        #expect(runTimes.count == 1)

        scheduler.advance(by: 0.25)
        #expect(runTimes.count == 3)
        for (index, time) in runTimes.enumerated() {
            #expect(abs(time - 0.1 * Double(index + 1)) < 1e-9)
        }
        // Re-armed before the action ran.
        #expect(pendingDuringRun == [1, 1, 1])

        work.cancel()
        scheduler.advance(by: 1)
        #expect(runTimes.count == 3)
        #expect(scheduler.pendingCount == 0)
    }

    @Test func manualSchedulerRunsDueActionsInDueThenSchedulingOrder() {
        let scheduler = ManualScheduler()
        var order: [String] = []
        var timeOfA: TimeInterval?
        scheduler.schedule(after: 0.2) {
            order.append("a")
            timeOfA = scheduler.now
        }
        scheduler.schedule(after: 0.1) { order.append("b") }
        scheduler.schedule(after: 0.1) { order.append("c") }
        scheduler.schedule(after: 0.3) { order.append("d") }

        scheduler.advance(by: 0.25)

        #expect(order == ["b", "c", "a"])
        #expect(abs((timeOfA ?? -1) - 0.2) < 1e-9)
        #expect(abs(scheduler.now - 0.25) < 1e-9)
        #expect(scheduler.pendingCount == 1)
    }

    @Test func manualSchedulerRunsActionsScheduledDuringAdvance() {
        let scheduler = ManualScheduler()
        var order: [String] = []
        scheduler.schedule(after: 0.1) {
            order.append("first")
            scheduler.schedule(after: 0) { order.append("zero") }
            scheduler.schedule(after: 0.05) { order.append("soon") }
            scheduler.schedule(after: 0.5) { order.append("late") }
        }
        scheduler.schedule(after: 0.12) { order.append("second") }

        scheduler.advance(by: 0.2)

        #expect(order == ["first", "zero", "second", "soon"])
        #expect(scheduler.pendingCount == 1)
    }

    @Test func manualSchedulerRunsQueueTargetedActionsOnThatQueue() {
        let scheduler = ManualScheduler()
        let key = DispatchSpecificKey<String>()
        let queue = DispatchQueue(label: "dev.alavreniuk.macmic.tests.scheduler-target")
        queue.setSpecific(key: key, value: "target")
        var queueSeen: [String?] = []
        var ranOnMain = false
        scheduler.schedule(after: 0.1, on: queue) { queueSeen.append(DispatchQueue.getSpecific(key: key)) }
        scheduler.schedule(after: 0.1) { ranOnMain = Thread.isMainThread }

        scheduler.advance(by: 0.1)

        #expect(queueSeen == ["target"])
        #expect(ranOnMain)
    }

    @Test func manualSchedulerZeroDelayDoesNotRunInline() {
        let scheduler = ManualScheduler()
        var runs = 0
        scheduler.schedule(after: 0) { runs += 1 }
        scheduler.schedule(after: -1) { runs += 1 }

        #expect(runs == 0)
        #expect(scheduler.pendingCount == 2)

        scheduler.runUntilIdle()

        #expect(runs == 2)
        #expect(scheduler.now == 0)
    }

    @Test func mainActorTestsRunOnTheMainQueue() async {
        dispatchPrecondition(condition: .onQueue(.main))
        await Task.yield()
        dispatchPrecondition(condition: .onQueue(.main))
    }
}
