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

/// `FrameStreamer` on a `ManualScheduler`: each `tick()` advances the clock
/// by one interval, which runs that tick's send on the streamer's queue and
/// delivers its callbacks on main before returning.
@Suite @MainActor struct FrameStreamerTests {
    private final class Harness {
        let transport = MockHIDTransport()
        let scheduler = ManualScheduler()
        let streamer: FrameStreamer

        init() {
            try! transport.open()
            streamer = FrameStreamer(transport: transport, scheduler: scheduler)
        }

        func tick(_ count: Int = 1) {
            for _ in 0..<count {
                scheduler.advance(by: FrameStreamer.defaultInterval)
            }
        }

        var dataPackets: [[UInt8]] {
            transport.sentReports.enumerated().compactMap { index, report in
                index % 2 == 1 ? report : nil
            }
        }
    }

    @Test func sendsHeaderThenDataPacketEachTick() throws {
        let harness = Harness()

        harness.streamer.start()
        harness.tick(1)

        #expect(harness.transport.sentReports == [
            QuadcastPacket.headerPacket(),
            Frame(color: RGBColor(r: 0, g: 0, b: 0)).dataPacket(),
        ])
    }

    @Test func loopsSequenceBackToTheStart() throws {
        let harness = Harness()
        let color = RGBColor(r: 0x11, g: 0x22, b: 0x33)

        harness.streamer.setMode(.blink(colors: [color], speed: 100))
        harness.streamer.start()
        harness.tick(3)

        #expect(harness.dataPackets == [
            Frame(color: color).dataPacket(),
            Frame(color: RGBColor(r: 0, g: 0, b: 0)).dataPacket(),
            Frame(color: color).dataPacket(),
        ])
    }

    @Test func setModeSwapsSequenceCleanlyMidStream() throws {
        let harness = Harness()
        let red = RGBColor(r: 0xFF, g: 0, b: 0)
        let blue = RGBColor(r: 0, g: 0, b: 0xFF)

        harness.streamer.setMode(.solid(red))
        harness.streamer.start()
        harness.tick(1)
        harness.streamer.setMode(.solid(blue))
        harness.tick(1)

        #expect(harness.transport.sentReports == [
            QuadcastPacket.headerPacket(),
            Frame(color: red).dataPacket(),
            QuadcastPacket.headerPacket(),
            Frame(color: blue).dataPacket(),
        ])
    }

    /// Regression test: `Lighting` calls `setMode` on every brightness change
    /// too (e.g. once per `Slider` drag tick), with the same `LightMode` each
    /// time. That must dim the in-progress animation in place, not restart
    /// it from frame 0.
    @Test func brightnessOnlyChangeDoesNotResetPlaybackPosition() throws {
        let harness = Harness()
        let mode = LightMode.cycle(speed: 0)
        let expectedFrames = PresetSequencer.frames(for: mode)

        harness.streamer.setMode(mode, brightness: 1)
        harness.streamer.start()
        harness.tick(1) // frame 0

        harness.streamer.setMode(mode, brightness: 0.5)
        harness.tick(1) // frame 1 at half brightness, not frame 0 again

        #expect(harness.dataPackets == [
            expectedFrames[0].dataPacket(),
            expectedFrames[1].scaled(brightness: 0.5).dataPacket(),
        ])
    }

    @Test func emptyFrameSequenceFallsBackToBlackInsteadOfCrashing() throws {
        let harness = Harness()

        harness.streamer.setMode(.blink(colors: [], speed: 50))
        harness.streamer.start()
        harness.tick(2)

        #expect(harness.transport.sentReports.last == Frame(color: RGBColor(r: 0, g: 0, b: 0)).dataPacket())
    }

    @Test func stopCeasesSends() throws {
        let harness = Harness()

        harness.streamer.start()
        harness.tick(1)
        let countBeforeStop = harness.transport.sentReports.count

        harness.streamer.stop()
        harness.tick(3)

        #expect(harness.transport.sentReports.count == countBeforeStop)
        #expect(harness.scheduler.pendingCount == 0)
    }

    @Test func stopsAndSurfacesErrorOnSendFailure() throws {
        let harness = Harness()
        var captured: [HIDTransportError] = []
        harness.streamer.onError = { captured.append($0 as! HIDTransportError) }

        harness.streamer.start()
        harness.transport.nextSendError = .sendFailed(-1)
        harness.tick(1)

        #expect(captured == [.sendFailed(-1)])

        harness.tick(3)

        #expect(harness.transport.sendAttempts == 1)
        #expect(captured.count == 1)
    }

    @Test func reportsFirstFrameSentOncePerRun() throws {
        let harness = Harness()
        var firstFrames = 0
        harness.streamer.onFirstFrameSent = { firstFrames += 1 }

        harness.streamer.start()
        #expect(firstFrames == 0)
        harness.tick(3)
        #expect(firstFrames == 1)

        harness.streamer.start() // already running: not a new run
        harness.tick(2)
        #expect(firstFrames == 1)

        harness.streamer.stop()
        harness.streamer.start()
        harness.tick(2)
        #expect(firstFrames == 2)
    }

    /// A run that failed before sending anything reports no first frame;
    /// the next run that succeeds does.
    @Test func failedRunReportsNoFirstFrame() throws {
        let harness = Harness()
        var firstFrames = 0
        harness.streamer.onFirstFrameSent = { firstFrames += 1 }
        harness.transport.nextSendError = .sendFailed(-1)

        harness.streamer.start()
        harness.tick(1)
        #expect(firstFrames == 0)

        harness.streamer.start()
        harness.tick(1)
        #expect(firstFrames == 1)
    }

    @Test func repeatedStartWhileRunningDoesNotAddTicks() throws {
        let harness = Harness()

        harness.streamer.start()
        harness.streamer.start()
        harness.tick(1)
        harness.streamer.start()
        harness.tick(2)

        #expect(harness.transport.sentReports.count == 6)
    }

    @Test func stopThenStartBeforeStaleTickFiresKeepsOneLoop() throws {
        let harness = Harness()
        let interval = FrameStreamer.defaultInterval

        harness.streamer.start() // first tick due at 1 interval
        harness.scheduler.advance(by: interval / 2)
        harness.streamer.stop()
        harness.streamer.start() // new loop due at 1.5 intervals

        harness.scheduler.advance(by: interval / 2 + 0.005) // the stale tick's time
        #expect(harness.transport.sentReports.isEmpty)

        harness.scheduler.advance(by: interval / 2) // 1.5 intervals and a bit
        #expect(harness.transport.sentReports.count == 2)

        harness.scheduler.advance(by: interval * 4)
        #expect(harness.transport.sentReports.count == 10)
    }

    /// A real queue runs every action a little after its deadline. Each
    /// tick's lateness must not carry into the next period, or the 55 ms
    /// loop drifts (measured ~64 ms per tick on macOS 15) and every
    /// animation slows down.
    @Test func lateTicksDoNotStretchTheCadence() throws {
        let transport = MockHIDTransport()
        try transport.open()
        let manual = ManualScheduler()
        let streamer = FrameStreamer(transport: transport, scheduler: LateScheduler(manual, lateness: 0.008))

        streamer.start()
        // Tick k runs at k × 55 ms + 8 ms; re-arming relative to each tick
        // would put it at k × 63 ms and fit only 17 ticks.
        manual.advance(by: 20 * FrameStreamer.defaultInterval + 0.01)

        #expect(transport.sentReports.count == 40)
    }

    /// A tick more than a whole interval late (a send blocked for ~1 s)
    /// resumes the cadence from that tick instead of firing the missed
    /// ticks back to back.
    @Test func aTickLateByMoreThanAnIntervalDoesNotCatchUpInABurst() throws {
        let transport = MockHIDTransport()
        try transport.open()
        let manual = ManualScheduler()
        let streamer = FrameStreamer(transport: transport, scheduler: LateScheduler(manual, lateness: 0.1))

        streamer.start()
        // Every tick is 100 ms late, so they run every 155 ms: at 0.155,
        // 0.310 and 0.465 s.
        manual.advance(by: 0.5)

        #expect(transport.sentReports.count == 6)
    }

    @Test func realTimerFiresPeriodicallyAndStopsOnStop() async throws {
        let transport = MockHIDTransport()
        try transport.open()
        let streamer = FrameStreamer(transport: transport, interval: 0.01, scheduler: DispatchScheduler())

        streamer.start()
        try await Task.sleep(nanoseconds: 120_000_000)
        streamer.stop()
        // Let the stop land and any tick already in flight finish.
        try await Task.sleep(nanoseconds: 30_000_000)
        let countAfterStop = transport.sentReports.count
        #expect(countAfterStop >= 4) // at least two ticks: periodic, not one-shot

        try await Task.sleep(nanoseconds: 60_000_000)
        #expect(transport.sentReports.count == countAfterStop)
    }
}

/// Runs every positive-delay action `lateness` seconds after its deadline,
/// as a real queue's timer does by a few milliseconds.
private final class LateScheduler: Scheduler {
    private let base: ManualScheduler
    private let lateness: TimeInterval

    init(_ base: ManualScheduler, lateness: TimeInterval) {
        self.base = base
        self.lateness = lateness
    }

    var now: TimeInterval {
        base.now
    }

    @discardableResult
    func schedule(after delay: TimeInterval, on queue: DispatchQueue, _ action: @escaping () -> Void) -> ScheduledWork {
        base.schedule(after: delay > 0 ? delay + lateness : delay, on: queue, action)
    }
}
