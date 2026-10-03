// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Dispatch
import Foundation
@testable import QuadcastKit

/// A `Scheduler` whose clock moves only in `advance(by:)`. `schedule` just
/// records. `advance` runs every action that falls due, ordered by (due
/// time, scheduling order) and including actions scheduled while it runs,
/// with `now` set to each action's due time. `.main` actions run inline, so
/// the caller must be on the main queue; other queues' actions run through
/// `queue.sync`. No lock is held while an action runs.
final class ManualScheduler: Scheduler {
    private struct Entry {
        let sequence: Int
        let due: TimeInterval
        let queue: DispatchQueue
        let action: () -> Void
    }

    private let lock = NSLock()
    private var clock: TimeInterval = 0
    private var lastSequence = 0
    private var pending: [Entry] = []

    var now: TimeInterval {
        locked { clock }
    }

    var pendingCount: Int {
        locked { pending.count }
    }

    @discardableResult
    func schedule(after delay: TimeInterval, on queue: DispatchQueue, _ action: @escaping () -> Void) -> ScheduledWork {
        let sequence: Int = locked {
            lastSequence += 1
            pending.append(Entry(sequence: lastSequence, due: clock + max(delay, 0), queue: queue, action: action))
            return lastSequence
        }
        return ScheduledWork { [weak self] in self?.cancel(sequence) }
    }

    func advance(by interval: TimeInterval) {
        let target = locked { clock + max(interval, 0) }
        while let entry = takeNext(dueBy: target) {
            if entry.queue === DispatchQueue.main {
                dispatchPrecondition(condition: .onQueue(.main))
                entry.action()
            } else {
                entry.queue.sync(execute: entry.action)
            }
        }
        locked { clock = max(clock, target) }
    }

    func runUntilIdle() {
        advance(by: 0)
    }

    private func takeNext(dueBy target: TimeInterval) -> Entry? {
        locked {
            let due = pending.indices.filter { pending[$0].due <= target }
            guard let index = due.min(by: {
                (pending[$0].due, pending[$0].sequence) < (pending[$1].due, pending[$1].sequence)
            }) else { return nil }
            let entry = pending.remove(at: index)
            clock = max(clock, entry.due)
            return entry
        }
    }

    private func cancel(_ sequence: Int) {
        locked { pending.removeAll { $0.sequence == sequence } }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
