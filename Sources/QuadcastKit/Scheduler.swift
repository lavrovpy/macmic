// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Dispatch
import Foundation

/// The time seam: code that schedules through this is driven by a manual
/// clock in tests instead of waiting. An action runs on the queue it was
/// scheduled on, never inside `schedule`.
public protocol Scheduler: AnyObject {
    /// Monotonic seconds; only differences mean anything. Any thread.
    var now: TimeInterval { get }

    /// Runs `action` on `queue` after `delay` (≤ 0 = as soon as possible).
    /// Never inside this call, even for 0 — restart coalescing relies on 0
    /// meaning "a later turn of `queue`", so an implementation that runs a
    /// zero delay inline breaks it silently. Any thread.
    @discardableResult
    func schedule(after delay: TimeInterval, on queue: DispatchQueue, _ action: @escaping () -> Void) -> ScheduledWork
}

public extension Scheduler {
    /// `schedule(after:on:_:)` on the main queue.
    @discardableResult
    func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> ScheduledWork {
        schedule(after: delay, on: .main, action)
    }

    /// First run one `interval` from now; re-arms before running `action`.
    /// Call and cancel on `queue`.
    @discardableResult
    func scheduleRepeating(
        every interval: TimeInterval,
        on queue: DispatchQueue = .main,
        _ action: @escaping () -> Void
    ) -> ScheduledWork {
        let box = RepeatingWorkBox()
        func arm() {
            box.current = schedule(after: interval, on: queue) {
                guard !box.isCancelled else { return }
                arm()
                action()
            }
        }
        arm()
        return ScheduledWork {
            box.isCancelled = true
            box.current?.cancel()
            box.current = nil
        }
    }
}

/// The pending occurrence of one `scheduleRepeating` chain; touched only on
/// the chain's queue.
private final class RepeatingWorkBox {
    var current: ScheduledWork?
    var isCancelled = false
}

/// Idempotent and thread-safe. Cancelling on the action's own queue before
/// it starts guarantees it never runs.
public final class ScheduledWork {
    private let lock = NSLock()
    private var cancelAction: (() -> Void)?

    public init(cancel: @escaping () -> Void) {
        cancelAction = cancel
    }

    public func cancel() {
        lock.lock()
        let action = cancelAction
        cancelAction = nil
        lock.unlock()
        action?()
    }
}

/// The production `Scheduler`: `now` is `ProcessInfo.systemUptime`; each
/// action is a `DispatchWorkItem` on its queue.
public final class DispatchScheduler: Scheduler {
    public init() {}

    public var now: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    @discardableResult
    public func schedule(after delay: TimeInterval, on queue: DispatchQueue, _ action: @escaping () -> Void) -> ScheduledWork {
        let item = DispatchWorkItem(block: action)
        if delay <= 0 {
            queue.async(execute: item)
        } else {
            queue.asyncAfter(deadline: .now() + delay, execute: item)
        }
        return ScheduledWork(cancel: item.cancel)
    }
}
