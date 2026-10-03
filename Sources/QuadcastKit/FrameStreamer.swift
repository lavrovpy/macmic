// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Dispatch
import Foundation

/// Streams the QuadCast S display loop: a header packet followed by the next
/// data packet in the current frame sequence, sent once per `interval`
/// (55 ms by default, matching the reference implementation). The mic does
/// not persist software-set colors, so this must keep running for as long as
/// the lighting should stay under host control; stopping it lets the mic
/// revert to its default rainbow.
///
/// Sends run on an internal serial queue (a USB transfer blocks for up to
/// ~1 s); `setMode`, `start` and `stop` may be called from any thread and
/// never wait for an in-flight send.
public final class FrameStreamer {
    public static let defaultInterval: TimeInterval = 0.055

    /// Main thread, via `scheduler`. The streamer has already stopped itself.
    public var onError: ((Error) -> Void)?

    /// Main thread, via `scheduler`, once per run: after the first
    /// successful send of a `start()` that began streaming.
    public var onFirstFrameSent: (() -> Void)?

    /// One `start()` that began streaming. Its scheduled ticks only run
    /// while it is `current`, so a tick left over from a stopped run (or
    /// from a duplicate `start()` while running) is a no-op.
    private final class Run {
        var sentFirstFrame = false
        var nextDue: TimeInterval

        init(nextDue: TimeInterval) {
            self.nextDue = nextDue
        }
    }

    private let transport: HIDTransport
    private let interval: TimeInterval
    private let scheduler: Scheduler
    private let queue = DispatchQueue(label: "dev.alavreniuk.macmic.frame-streamer")
    // Confined to `queue`.
    private var current: Run?
    private var frames: [Frame] = [Frame(color: RGBColor(r: 0, g: 0, b: 0))]
    private var frameIndex = 0
    private var lastMode: LightMode?

    public init(transport: HIDTransport, interval: TimeInterval = defaultInterval, scheduler: Scheduler = DispatchScheduler()) {
        self.transport = transport
        self.interval = interval
        self.scheduler = scheduler
    }

    /// Swaps the frame sequence played by the display loop. Takes effect on
    /// the next tick; safe to call while streaming.
    ///
    /// Only resets playback to the start of the sequence when `mode` itself
    /// changes. `Lighting` calls this on every settings change, brightness
    /// included (e.g. once per `Slider` drag tick) — without this, dragging
    /// the brightness slider while a `.cycle`/`.blink` preset is animating
    /// would restart it from frame 0 on every tick instead of dimming it in
    /// place.
    public func setMode(_ mode: LightMode, brightness: Double = 1) {
        let newFrames = PresetSequencer.frames(for: mode).map { $0.scaled(brightness: brightness) }
        let resolvedFrames = newFrames.isEmpty ? [Frame(color: RGBColor(r: 0, g: 0, b: 0))] : newFrames
        queue.async { [self] in
            if mode != lastMode || frameIndex >= resolvedFrames.count {
                frameIndex = 0
            }
            frames = resolvedFrames
            lastMode = mode
        }
    }

    /// Starts the periodic display loop; a no-op while it is already running.
    public func start() {
        let run = Run(nextDue: scheduler.now + interval)
        queue.async { [self] in
            if current == nil {
                current = run
            }
        }
        // Scheduled from the caller's thread, not from inside the block
        // above, so the first tick is pending as soon as `start()` returns
        // (tests advance a manual clock right after calling it).
        scheduler.schedule(after: interval, on: queue) { [weak self] in self?.fire(run) }
    }

    /// Stops the display loop; no further reports are sent until `start()`
    /// is called again.
    public func stop() {
        queue.async { [self] in
            current = nil
        }
    }

    /// On `queue`.
    private func fire(_ run: Run) {
        guard current === run else { return }
        // Re-arm before sending, against the run's own timeline rather than
        // `after: interval` from now: a transfer can take up to ~1 s, and on
        // a real queue every wake-up is a few ms late (with `after: interval`
        // each tick measured ~64 ms, not 55). A tick later than a whole
        // interval (a blocked send) restarts the timeline instead of firing
        // the missed ticks in a burst. `ManualScheduler` fires exactly on
        // time; only the `LateScheduler` tests in `FrameStreamerTests` see
        // either rule.
        let now = scheduler.now
        run.nextDue += interval
        if run.nextDue <= now {
            run.nextDue = now + interval
        }
        scheduler.schedule(after: run.nextDue - now, on: queue) { [weak self] in self?.fire(run) }
        do {
            try transport.sendFeatureReport(QuadcastPacket.headerPacket())
            try transport.sendFeatureReport(frames[frameIndex].dataPacket())
            frameIndex = (frameIndex + 1) % frames.count
            if !run.sentFirstFrame {
                run.sentFirstFrame = true
                scheduler.schedule(after: 0) { [weak self] in self?.onFirstFrameSent?() }
            }
        } catch {
            current = nil
            scheduler.schedule(after: 0) { [weak self] in self?.onError?(error) }
        }
    }
}
