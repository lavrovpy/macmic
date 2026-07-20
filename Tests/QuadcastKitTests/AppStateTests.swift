// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import AppKit
import Dispatch
import Foundation
import Testing
@testable import MacMic
@testable import QuadcastKit

@Suite struct AppStateTests {
    /// A very long interval so the real `DispatchSourceTimer` never fires
    /// during these tests; `state.streamer.tick()` drives ticks
    /// deterministically instead (same pattern as `FrameStreamerTests`).
    private static let dormantInterval: DispatchTimeInterval = .seconds(3600)

    /// A `UserDefaults` suite unique to each test so runs never see another
    /// test's persisted state.
    private static func freshDefaults(name: String = #function) -> UserDefaults {
        let suiteName = "dev.alavreniuk.macmic.tests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeState(
        transport: HIDTransport,
        defaults: UserDefaults? = nil,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> AppState {
        AppState(
            transport: transport,
            defaults: defaults ?? Self.freshDefaults(),
            notificationCenter: notificationCenter,
            streamerInterval: Self.dormantInterval
        )
    }

    @Test func modeChangeReachesTheMockTransport() throws {
        let transport = MockHIDTransport()
        let state = makeState(transport: transport)
        let red = RGBColor(r: 0xFF, g: 0, b: 0)

        state.mode = .solid(red)
        state.streamer.tick()

        #expect(transport.sentReports.last == Frame(color: red).dataPacket())
    }

    @Test func disablingStopsStreamingAndReEnablingResumes() throws {
        let transport = MockHIDTransport()
        let state = makeState(transport: transport)
        state.mode = .solid(RGBColor(r: 1, g: 2, b: 3))

        state.isEnabled = false
        state.streamer.tick() // no-op: stopped
        let countAfterDisable = transport.sentReports.count

        state.isEnabled = true
        state.streamer.tick()

        #expect(transport.sentReports.count > countAfterDisable)
    }

    @Test func persistenceRoundTripsLightMode() throws {
        let defaults = Self.freshDefaults()
        let blink = LightMode.blink(colors: [RGBColor(r: 10, g: 20, b: 30), RGBColor(r: 40, g: 50, b: 60)], speed: 42)

        let first = makeState(transport: MockHIDTransport(), defaults: defaults)
        first.mode = blink
        first.brightness = 0.5
        first.isEnabled = false

        let second = makeState(transport: MockHIDTransport(), defaults: defaults)

        #expect(second.mode == blink)
        #expect(second.brightness == 0.5)
        #expect(second.isEnabled == false)
    }

    @Test func defaultsAreUsedWhenNothingPersistedYet() throws {
        let state = makeState(transport: MockHIDTransport())

        #expect(state.mode == .solid(RGBColor(r: 0xFF, g: 0xFF, b: 0xFF)))
        #expect(state.brightness == 1)
        #expect(state.isEnabled == true)
    }

    @Test func reconnectReAppliesLastMode() throws {
        let transport = MockHIDTransport()
        let state = makeState(transport: transport)
        let color = RGBColor(r: 9, g: 9, b: 9)
        state.mode = .solid(color)

        transport.simulateRemoval()
        #expect(state.isConnected == false)

        transport.simulateConnect()
        state.streamer.tick()

        #expect(state.isConnected == true)
        #expect(transport.sentReports.last == Frame(color: color).dataPacket())
    }

    @Test func wakeReAppliesModeAfterSleepStopped() throws {
        let transport = MockHIDTransport()
        let notificationCenter = NotificationCenter()
        let state = makeState(transport: transport, notificationCenter: notificationCenter)
        let color = RGBColor(r: 5, g: 6, b: 7)
        state.mode = .solid(color)

        notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        state.streamer.tick() // no-op: stopped by sleep
        let countAfterSleep = transport.sentReports.count

        notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        state.streamer.tick()

        #expect(transport.sentReports.count > countAfterSleep)
        #expect(transport.sentReports.last == Frame(color: color).dataPacket())
    }

    @Test func transportErrorMarksDisconnected() async throws {
        let transport = MockHIDTransport()
        let state = makeState(transport: transport)
        #expect(state.isConnected == true)

        transport.nextSendError = .sendFailed(-1)
        state.streamer.tick()

        // FrameStreamer delivers onError on the main queue, so give it a
        // beat to run before asserting.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(state.isConnected == false)
    }

    @Test func mutatingStateWhileDisconnectedDoesNotResumeStreaming() throws {
        let transport = MockHIDTransport()
        let state = makeState(transport: transport)
        state.mode = .solid(RGBColor(r: 1, g: 2, b: 3))
        state.streamer.tick()

        transport.simulateRemoval()
        #expect(state.isConnected == false)

        state.mode = .solid(RGBColor(r: 9, g: 9, b: 9))
        let countWhileDisconnected = transport.sentReports.count
        state.streamer.tick()

        #expect(transport.sentReports.count == countWhileDisconnected)
    }

    @Test func openFailureLeavesStateDisconnected() throws {
        let transport = MockHIDTransport()
        transport.nextOpenError = .openFailed(-1)

        let state = makeState(transport: transport)

        #expect(state.isConnected == false)
    }

    /// Regression test: `open()` succeeding must not be conflated with a
    /// device actually being matched. `IOUSBHostTransport.open()` only
    /// registers IOKit matching notifications; a real device match (or lack
    /// thereof) is reported asynchronously via `onDeviceConnected`. Launching
    /// with no mic plugged in must leave `isConnected == false` until a real
    /// match notification arrives.
    @Test func deviceAbsentAtLaunchLeavesStateDisconnected() throws {
        let transport = MockHIDTransport()
        transport.autoConnectOnOpen = false

        let state = makeState(transport: transport)

        #expect(state.isConnected == false)

        transport.simulateConnect()
        #expect(state.isConnected == true)
    }

    @Test func corruptedPersistedModeFallsBackToDefault() throws {
        let defaults = Self.freshDefaults()
        defaults.set(Data([0xFF, 0x00]), forKey: "dev.alavreniuk.macmic.mode")

        let state = makeState(transport: MockHIDTransport(), defaults: defaults)

        #expect(state.mode == .solid(RGBColor(r: 0xFF, g: 0xFF, b: 0xFF)))
    }
}
