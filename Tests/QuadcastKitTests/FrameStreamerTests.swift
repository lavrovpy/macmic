// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Dispatch
import Testing
@testable import QuadcastKit

@Suite struct FrameStreamerTests {
    /// A very long interval so the real `DispatchSourceTimer` installed by
    /// `start()` never fires during these tests; `tick()` drives ticks
    /// deterministically instead.
    private static let dormantInterval: DispatchTimeInterval = .seconds(3600)

    @Test func sendsHeaderThenDataPacketEachTick() throws {
        let transport = MockHIDTransport()
        try transport.open()
        let streamer = FrameStreamer(transport: transport, interval: Self.dormantInterval)

        streamer.start()
        streamer.tick()

        #expect(transport.sentReports == [
            QuadcastPacket.headerPacket(),
            Frame(color: RGBColor(r: 0, g: 0, b: 0)).dataPacket(),
        ])
    }

    @Test func loopsSequenceBackToTheStart() throws {
        let transport = MockHIDTransport()
        try transport.open()
        let streamer = FrameStreamer(transport: transport, interval: Self.dormantInterval)
        let color = RGBColor(r: 0x11, g: 0x22, b: 0x33)

        streamer.setMode(.blink(colors: [color], speed: 100))
        streamer.start()
        streamer.tick()
        streamer.tick()
        streamer.tick()

        let dataPackets = transport.sentReports.enumerated().compactMap { index, report in
            index % 2 == 1 ? report : nil
        }
        #expect(dataPackets == [
            Frame(color: color).dataPacket(),
            Frame(color: RGBColor(r: 0, g: 0, b: 0)).dataPacket(),
            Frame(color: color).dataPacket(),
        ])
    }

    @Test func setModeSwapsSequenceCleanlyMidStream() throws {
        let transport = MockHIDTransport()
        try transport.open()
        let streamer = FrameStreamer(transport: transport, interval: Self.dormantInterval)
        let red = RGBColor(r: 0xFF, g: 0, b: 0)
        let blue = RGBColor(r: 0, g: 0, b: 0xFF)

        streamer.setMode(.solid(red))
        streamer.start()
        streamer.tick()
        streamer.setMode(.solid(blue))
        streamer.tick()

        #expect(transport.sentReports == [
            QuadcastPacket.headerPacket(),
            Frame(color: red).dataPacket(),
            QuadcastPacket.headerPacket(),
            Frame(color: blue).dataPacket(),
        ])
    }

    /// Regression test: `AppState.applyEnabledState()` calls `setMode` on
    /// every brightness change too (e.g. once per `Slider` drag tick), with
    /// the same `LightMode` each time. That must dim the in-progress
    /// animation in place, not restart it from frame 0.
    @Test func brightnessOnlyChangeDoesNotResetPlaybackPosition() throws {
        let transport = MockHIDTransport()
        try transport.open()
        let streamer = FrameStreamer(transport: transport, interval: Self.dormantInterval)
        let mode = LightMode.cycle(speed: 0)
        let expectedFrames = PresetSequencer.frames(for: mode)

        streamer.setMode(mode, brightness: 1)
        streamer.start()
        streamer.tick() // sends frame 0, advances frameIndex to 1

        streamer.setMode(mode, brightness: 0.5) // same mode, brightness-only change
        streamer.tick() // should send frame 1 scaled at 0.5, not frame 0 again

        let dataPackets = transport.sentReports.enumerated().compactMap { index, report in
            index % 2 == 1 ? report : nil
        }
        #expect(dataPackets == [
            expectedFrames[0].dataPacket(),
            expectedFrames[1].scaled(brightness: 0.5).dataPacket(),
        ])
    }

    @Test func stopsAndSurfacesErrorOnSendFailure() async throws {
        let transport = MockHIDTransport()
        try transport.open()
        let streamer = FrameStreamer(transport: transport, interval: Self.dormantInterval)
        var captured: HIDTransportError?
        streamer.onError = { captured = $0 as? HIDTransportError }

        streamer.start()
        transport.nextSendError = .sendFailed(-1)
        streamer.tick()
        #expect(streamer.isRunning == false) // set synchronously, before onError is delivered

        // onError is delivered on the main queue (see FrameStreamer.deliverError),
        // so give it a beat to run before asserting.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(captured == .sendFailed(-1))
    }

    @Test func emptyFrameSequenceFallsBackToBlackInsteadOfCrashing() throws {
        let transport = MockHIDTransport()
        try transport.open()
        let streamer = FrameStreamer(transport: transport, interval: Self.dormantInterval)

        streamer.setMode(.blink(colors: [], speed: 50))
        streamer.start()
        streamer.tick()
        streamer.tick()

        #expect(transport.sentReports.last == Frame(color: RGBColor(r: 0, g: 0, b: 0)).dataPacket())
    }

    @Test func stopCeasesSends() throws {
        let transport = MockHIDTransport()
        try transport.open()
        let streamer = FrameStreamer(transport: transport, interval: Self.dormantInterval)

        streamer.start()
        streamer.tick()
        let countBeforeStop = transport.sentReports.count

        streamer.stop()
        streamer.tick()

        #expect(transport.sentReports.count == countBeforeStop)
        #expect(streamer.isRunning == false)
    }

    @Test func realTimerFiresPeriodicallyAndStopsOnStop() async throws {
        let transport = MockHIDTransport()
        try transport.open()
        let streamer = FrameStreamer(transport: transport, interval: .milliseconds(10))

        streamer.start()
        try await Task.sleep(nanoseconds: 120_000_000)
        streamer.stop()
        let countAfterStop = transport.sentReports.count
        #expect(countAfterStop > 0)

        try await Task.sleep(nanoseconds: 60_000_000)
        streamer.tick() // no-op (stopped); forces a sync with the internal queue for a safe read
        #expect(transport.sentReports.count == countAfterStop)
    }
}
