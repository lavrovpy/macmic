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

/// How `AppState` composes its concerns: the audio control's lifecycle,
/// sleep/wake fan-out, teardown, and the independence of the lighting and
/// audio hotplug lifecycles. Each concern's own behaviour is tested against
/// its own fixture.
@Suite @MainActor struct AppStateTests {
    private static let speakers = MicrophoneTestPhase.running(outputDeviceName: "MacBook Pro Speakers")

    @Test func audioControlIsOpenedAfterObserversAreRegistered() {
        let fixture = AppStateFixture()
        let app = fixture.state

        #expect(fixture.audioControl.registrationsAtOpen == 2)
        #expect(app.audio.snapshot == .sample)
        #expect(app.microphoneTest.controlsEnabled)
    }

    @Test func audioOpenFailureLeavesAudioUnavailable() {
        let audioControl = MockAudioDeviceControl()
        audioControl.nextOpenError = .openFailed(-1)
        let fixture = AppStateFixture(audioControl: audioControl)
        let app = fixture.state

        #expect(app.audio.snapshot == .unavailable)
        #expect(app.audio.micControlsEnabled == false)
        #expect(app.audio.monitorControlsEnabled == false)
        #expect(app.microphoneTest.controlsEnabled == false)
        #expect(app.lighting.status == .connected)
    }

    @Test func sleepStopsLightingAndTheMicrophoneTestAndWakeResumesOnlyLighting() {
        let fixture = AppStateFixture()
        let test = fixture.state.microphoneTest
        test.toggleTest()
        fixture.scheduler.advance(by: FrameStreamer.defaultInterval)
        let attemptsBeforeSleep = fixture.transport.sendAttempts
        #expect(attemptsBeforeSleep == 2)
        #expect(test.status.phase == Self.speakers)

        fixture.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(test.status.phase == .stopped)
        #expect(fixture.engine.isRunning == false)
        fixture.scheduler.advance(by: FrameStreamer.defaultInterval * 3)
        #expect(fixture.transport.sendAttempts == attemptsBeforeSleep)

        fixture.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        fixture.scheduler.advance(by: FrameStreamer.defaultInterval)
        #expect(fixture.transport.sendAttempts == attemptsBeforeSleep + 2)
        #expect(test.status.phase == .stopped)
        #expect(fixture.engine.count(of: .start(input: MockAudioDeviceControl.inputDeviceID)) == 1)
    }

    @Test func deinitStopsTheTestAndClosesAudioControlAndTransport() {
        let fixture = AppStateFixture()
        fixture.state.microphoneTest.toggleTest()
        #expect(fixture.engine.isRunning)
        #expect(fixture.audioControl.isOpen)
        #expect(fixture.transport.isOpen)

        fixture.releaseState()

        #expect(fixture.engine.isRunning == false)
        #expect(fixture.engine.calls.suffix(2) == [.stop, .discardClip])
        #expect(fixture.audioControl.isOpen == false)
        #expect(fixture.transport.isOpen == false)
        let attempts = fixture.transport.sendAttempts
        fixture.scheduler.advance(by: FrameStreamer.defaultInterval * 3)
        #expect(fixture.transport.sendAttempts == attempts)
    }

    @Test func lightingAndAudioPresenceAreIndependent() {
        let fixture = AppStateFixture()
        let app = fixture.state
        app.microphoneTest.toggleTest()
        #expect(app.lighting.isDevicePresent)
        #expect(app.audio.micControlsEnabled)

        fixture.transport.simulateUnplug()
        #expect(app.lighting.isDevicePresent == false)
        #expect(app.lighting.controlsEnabled == false)
        #expect(app.audio.micControlsEnabled)
        #expect(app.audio.monitorControlsEnabled)
        #expect(app.microphoneTest.status.phase == Self.speakers)
        #expect(app.microphoneTest.controlsEnabled)
        #expect(fixture.engine.isRunning)

        app.microphoneTest.toggleTest()
        fixture.transport.simulateConnect()
        fixture.audioControl.simulateDeviceRemoved()
        #expect(app.lighting.isDevicePresent)
        #expect(app.lighting.controlsEnabled)
        #expect(app.audio.micControlsEnabled == false)
        #expect(app.audio.monitorControlsEnabled == false)
    }

    @Test func micRemovalFailsTheTestWithoutTouchingLighting() {
        let fixture = AppStateFixture()
        let app = fixture.state
        app.microphoneTest.toggleTest()
        fixture.scheduler.advance(by: FrameStreamer.defaultInterval)
        let attempts = fixture.transport.sendAttempts

        fixture.audioControl.simulateDeviceRemoved()

        #expect(app.microphoneTest.status.phase == .failed(.inputDeviceUnavailable))
        #expect(fixture.engine.isRunning == false)
        #expect(app.audio.isAvailable == false)
        #expect(app.lighting.status == .connected)
        #expect(app.lighting.controlsEnabled)
        fixture.scheduler.advance(by: FrameStreamer.defaultInterval)
        #expect(fixture.transport.sendAttempts == attempts + 2)
    }

    @Test func onlyLightingSettingsArePersisted() {
        let fixture = AppStateFixture()
        let app = fixture.state
        app.audio.micGain = 0.2
        app.audio.isMicMuted = true
        app.audio.monitorVolume = 0.3
        app.audio.isMonitorMuted = true
        app.lighting.settings.brightness = 0.5
        app.microphoneTest.toggleTest()
        fixture.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        fixture.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        #expect(Array(fixture.persisted.keys) == [LightingSettingsStore.key])

        fixture.relaunch()

        #expect(fixture.state.lighting.settings.brightness == 0.5)
        #expect(fixture.state.audio.snapshot == .sample)
        #expect(fixture.audioControl.writes.isEmpty)
    }
}
