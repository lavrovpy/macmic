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
public final class FrameStreamer {
    /// Invoked (on `FrameStreamer`'s internal queue) when a feature report
    /// send fails; the streamer stops itself before this fires.
    public var onError: ((Error) -> Void)?

    public private(set) var isRunning = false

    private let transport: HIDTransport
    private let interval: DispatchTimeInterval
    private let queue = DispatchQueue(label: "dev.alavreniuk.macmic.frame-streamer")
    private var timer: DispatchSourceTimer?
    private var frames: [Frame] = [Frame(color: RGBColor(r: 0, g: 0, b: 0))]
    private var frameIndex = 0

    public init(transport: HIDTransport, interval: DispatchTimeInterval = .milliseconds(55)) {
        self.transport = transport
        self.interval = interval
    }

    /// Swaps the frame sequence played by the display loop. Takes effect on
    /// the next tick; safe to call while streaming.
    public func setMode(_ mode: LightMode, brightness: Double = 1) {
        let newFrames = PresetSequencer.frames(for: mode).map { $0.scaled(brightness: brightness) }
        queue.sync {
            frames = newFrames.isEmpty ? [Frame(color: RGBColor(r: 0, g: 0, b: 0))] : newFrames
            frameIndex = 0
        }
    }

    /// Starts (or, if already running, no-ops) the periodic display loop.
    public func start() {
        queue.sync {
            guard timer == nil else { return }
            isRunning = true
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + interval, repeating: interval)
            source.setEventHandler { [weak self] in
                self?.performTick()
            }
            timer = source
            source.resume()
        }
    }

    /// Stops the display loop; no further reports are sent until `start()`
    /// is called again.
    public func stop() {
        queue.sync {
            isRunning = false
            timer?.cancel()
            timer = nil
        }
    }

    /// Drives one tick synchronously. Internal (not `private`) so tests can
    /// exercise the tick logic deterministically without waiting on the real
    /// timer; production code relies on the timer installed by `start()`.
    func tick() {
        queue.sync { performTick() }
    }

    /// Must only be called on `queue`.
    private func performTick() {
        guard isRunning else { return }
        do {
            try transport.sendFeatureReport(QuadcastPacket.headerPacket())
            try transport.sendFeatureReport(frames[frameIndex].dataPacket())
            frameIndex = (frameIndex + 1) % frames.count
        } catch {
            isRunning = false
            timer?.cancel()
            timer = nil
            deliverError(error)
        }
    }

    /// Delivers `onError` on the main thread, matching how `HIDTransport`
    /// adapters deliver their connect/remove callbacks (so `@Published`
    /// consumers like `AppState` never observe an off-main mutation), while
    /// avoiding the async hop when already on main so `tick()` stays
    /// synchronous and deterministic for tests.
    private func deliverError(_ error: Error) {
        if Thread.isMainThread {
            onError?(error)
        } else {
            DispatchQueue.main.async { [weak self] in self?.onError?(error) }
        }
    }
}
