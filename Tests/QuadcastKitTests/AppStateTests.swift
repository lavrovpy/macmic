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

@Suite @MainActor struct AppStateTests {
    @Test func modeChangeReachesTheMockTransport() throws {
        let fixture = AppStateFixture()
        let transport = fixture.transport
        let state = fixture.state
        let red = RGBColor(r: 0xFF, g: 0, b: 0)

        state.mode = .solid(red)
        state.streamer.tick()

        #expect(transport.sentReports.last == Frame(color: red).dataPacket())
    }

    @Test func disablingStopsStreamingAndReEnablingResumes() throws {
        let fixture = AppStateFixture()
        let transport = fixture.transport
        let state = fixture.state
        state.mode = .solid(RGBColor(r: 1, g: 2, b: 3))

        state.isEnabled = false
        state.streamer.tick() // no-op: stopped
        let countAfterDisable = transport.sentReports.count

        state.isEnabled = true
        state.streamer.tick()

        #expect(transport.sentReports.count > countAfterDisable)
    }

    @Test func persistenceRoundTripsLightMode() throws {
        let fixture = AppStateFixture()
        let blink = LightMode.blink(colors: [RGBColor(r: 10, g: 20, b: 30), RGBColor(r: 40, g: 50, b: 60)], speed: 42)

        fixture.state.mode = blink
        fixture.state.brightness = 0.5
        fixture.state.isEnabled = false

        fixture.relaunch()

        #expect(fixture.state.mode == blink)
        #expect(fixture.state.brightness == 0.5)
        #expect(fixture.state.isEnabled == false)
    }

    /// Regression test: `lastSolidColor` must survive a relaunch even while a
    /// preset (`.cycle`/`.blink`) is the active mode, not just an in-memory
    /// session — otherwise the color picker resets to white on next launch.
    @Test func lastSolidColorSurvivesRelaunchWhilePresetIsActive() throws {
        let fixture = AppStateFixture()
        let color = RGBColor(r: 0xAA, g: 0xBB, b: 0xCC)

        fixture.state.mode = .solid(color)
        fixture.state.mode = .cycle(speed: 50)

        fixture.relaunch()

        #expect(fixture.state.mode == .cycle(speed: 50))
        #expect(fixture.state.lastSolidColor == color)
    }

    /// The settings window's speed slider and blink color list must come back
    /// after a relaunch even when a different mode ended up active, the same
    /// way `lastSolidColor` does.
    @Test func lastPresetSpeedAndBlinkColorsSurviveRelaunchWhileSolidIsActive() throws {
        let fixture = AppStateFixture()
        let colors = [RGBColor(r: 1, g: 2, b: 3), RGBColor(r: 4, g: 5, b: 6)]

        fixture.state.mode = .blink(colors: colors, speed: 88)
        fixture.state.mode = .cycle(speed: 12)
        fixture.state.mode = .solid(RGBColor(r: 0, g: 0, b: 0))

        fixture.relaunch()

        #expect(fixture.state.mode == .solid(RGBColor(r: 0, g: 0, b: 0)))
        #expect(fixture.state.lastPresetSpeed == 12)
        #expect(fixture.state.lastBlinkColors == colors)
    }

    @Test func corruptedPersistedBlinkSettingsFallBackToDefaults() throws {
        let fixture = AppStateFixture()
        fixture.defaults.set(Data([0xFF, 0x00]), forKey: "dev.alavreniuk.macmic.lastBlinkColors")
        fixture.defaults.set(999, forKey: "dev.alavreniuk.macmic.lastPresetSpeed")

        fixture.relaunch()
        let state = fixture.state

        #expect(state.lastBlinkColors == nil)
        #expect(state.lastPresetSpeed == 100)
    }

    @Test func defaultsAreUsedWhenNothingPersistedYet() throws {
        let fixture = AppStateFixture()
        let state = fixture.state

        #expect(state.mode == .solid(RGBColor(r: 0xFF, g: 0xFF, b: 0xFF)))
        #expect(state.brightness == 1)
        #expect(state.isEnabled == true)
    }

    @Test func reconnectReAppliesLastMode() throws {
        let fixture = AppStateFixture()
        let transport = fixture.transport
        let state = fixture.state
        let color = RGBColor(r: 9, g: 9, b: 9)
        state.mode = .solid(color)

        transport.simulateUnplug()
        #expect(state.isConnected == false)

        transport.simulateConnect()
        state.streamer.tick()

        #expect(state.isConnected == true)
        #expect(transport.sentReports.last == Frame(color: color).dataPacket())
    }

    /// One mic is two USB functions; the audio function (`0x171d`) going
    /// away on its own — e.g. re-enumerating — must not take lighting down
    /// while the control function is still matched.
    @Test func removingOnlyTheAudioFunctionKeepsLightingConnected() throws {
        let fixture = AppStateFixture()
        let transport = fixture.transport
        let state = fixture.state
        let color = RGBColor(r: 4, g: 5, b: 6)
        state.mode = .solid(color)

        transport.simulateRemoval(productID: 0x171d)
        state.streamer.tick()

        #expect(state.isConnected == true)
        #expect(transport.sentReports.last == Frame(color: color).dataPacket())
    }

    /// The reverse: with only `0x171d` left the transport still reports the
    /// mic present, but `0x171d` rejects control transfers, so the next send
    /// fails.
    @Test func removingOnlyTheControlFunctionFailsTheNextSend() async throws {
        let fixture = AppStateFixture()
        let transport = fixture.transport
        let state = fixture.state
        state.mode = .solid(RGBColor(r: 4, g: 5, b: 6))

        transport.simulateRemoval(productID: 0x171f)
        #expect(state.isConnected == true)
        let countBeforeSend = transport.sentReports.count
        state.streamer.tick()

        // FrameStreamer delivers onError on the main queue.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(transport.sentReports.count == countBeforeSend)
        #expect(state.isConnected == false)
    }

    @Test func wakeReAppliesModeAfterSleepStopped() throws {
        let fixture = AppStateFixture()
        let transport = fixture.transport
        let notificationCenter = fixture.notificationCenter
        let state = fixture.state
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
        let fixture = AppStateFixture()
        let transport = fixture.transport
        let state = fixture.state
        #expect(state.isConnected == true)

        transport.nextSendError = .sendFailed(-1)
        state.streamer.tick()

        // FrameStreamer delivers onError on the main queue, so give it a
        // beat to run before asserting.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(state.isConnected == false)
    }

    @Test func mutatingStateWhileDisconnectedDoesNotResumeStreaming() throws {
        let fixture = AppStateFixture()
        let transport = fixture.transport
        let state = fixture.state
        state.mode = .solid(RGBColor(r: 1, g: 2, b: 3))
        state.streamer.tick()

        transport.simulateUnplug()
        #expect(state.isConnected == false)

        state.mode = .solid(RGBColor(r: 9, g: 9, b: 9))
        let countWhileDisconnected = transport.sentReports.count
        state.streamer.tick()

        #expect(transport.sentReports.count == countWhileDisconnected)
    }

    @Test func openFailureLeavesStateDisconnected() throws {
        let transport = MockHIDTransport()
        transport.nextOpenError = .openFailed(-1)

        let fixture = AppStateFixture(transport: transport)

        let state = fixture.state

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

        let fixture = AppStateFixture(transport: transport)

        let state = fixture.state

        #expect(state.isConnected == false)

        transport.simulateConnect()
        #expect(state.isConnected == true)
    }

    @Test func corruptedPersistedModeFallsBackToDefault() throws {
        let fixture = AppStateFixture()
        fixture.defaults.set(Data([0xFF, 0x00]), forKey: "dev.alavreniuk.macmic.mode")

        fixture.relaunch()
        let state = fixture.state

        #expect(state.mode == .solid(RGBColor(r: 0xFF, g: 0xFF, b: 0xFF)))
    }

    @Test func corruptedPersistedLastSolidColorFallsBackToDefault() throws {
        let fixture = AppStateFixture()
        fixture.defaults.set(Data([0xFF, 0x00]), forKey: "dev.alavreniuk.macmic.lastSolidColor")
        fixture.defaults.set(try! JSONEncoder().encode(LightMode.cycle(speed: 50)), forKey: "dev.alavreniuk.macmic.mode")

        fixture.relaunch()
        let state = fixture.state

        #expect(state.lastSolidColor == RGBColor(r: 0xFF, g: 0xFF, b: 0xFF))
    }

    // MARK: Test Microphone composition

    @Test func sleepStopsTheMicTestAndWakeDoesNotRestartIt() throws {
        let fixture = AppStateFixture()
        let test = fixture.state.microphoneTest
        test.toggleTest()
        #expect(test.status.phase == .running(outputDeviceName: "MacBook Pro Speakers"))

        fixture.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(test.status.phase == .stopped)
        #expect(fixture.engine.isRunning == false)

        fixture.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        fixture.scheduler.runUntilIdle()
        #expect(test.status.phase == .stopped)
        #expect(fixture.engine.count(of: .start(input: MockAudioDeviceControl.inputDeviceID)) == 1)
    }

    @Test func lightingUnplugDoesNotStopTheMicTest() throws {
        let fixture = AppStateFixture()
        let test = fixture.state.microphoneTest
        test.toggleTest()

        fixture.transport.simulateUnplug()

        #expect(fixture.state.isConnected == false)
        #expect(test.status.phase == .running(outputDeviceName: "MacBook Pro Speakers"))
        #expect(test.controlsEnabled == true)
        #expect(fixture.engine.isRunning == true)
    }

    @Test func deinitStopsTheMicTest() throws {
        let fixture = AppStateFixture()
        fixture.state.microphoneTest.toggleTest()
        #expect(fixture.engine.isRunning == true)

        fixture.releaseState()

        #expect(fixture.engine.isRunning == false)
        #expect(fixture.engine.calls.suffix(2) == [.stop, .discardClip])
    }
}
