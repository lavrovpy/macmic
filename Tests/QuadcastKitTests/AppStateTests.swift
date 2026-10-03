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

/// How `AppState` composes its concerns: sleep/wake fan-out, and the Test
/// Microphone's lifetime against lighting hotplug and `AppState` itself.
@Suite @MainActor struct AppStateTests {
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

    @Test func sleepStopsLightingAndTheMicrophoneTestAndWakeResumesOnlyLighting() throws {
        let fixture = AppStateFixture()
        let test = fixture.state.microphoneTest
        test.toggleTest()
        fixture.scheduler.advance(by: FrameStreamer.defaultInterval)
        let attemptsBeforeSleep = fixture.transport.sendAttempts
        #expect(attemptsBeforeSleep == 2)

        fixture.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        fixture.scheduler.advance(by: FrameStreamer.defaultInterval * 3)
        #expect(fixture.transport.sendAttempts == attemptsBeforeSleep)
        #expect(test.status.phase == .stopped)

        fixture.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        fixture.scheduler.advance(by: FrameStreamer.defaultInterval)
        #expect(fixture.transport.sendAttempts == attemptsBeforeSleep + 2)
        #expect(test.status.phase == .stopped)
    }

    @Test func lightingUnplugDoesNotStopTheMicTest() throws {
        let fixture = AppStateFixture()
        let test = fixture.state.microphoneTest
        test.toggleTest()

        fixture.transport.simulateUnplug()

        #expect(fixture.state.lighting.isDevicePresent == false)
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
