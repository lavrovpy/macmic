// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Foundation
import Testing
@testable import MacMic
@testable import QuadcastKit

/// The Audio page's `MicrophoneTest` model over a real `MicrophoneTestSession`
/// (scripted engine, manual clock): mirroring, the toggles, the
/// page/sleep lifetime rule, and the UI text.
@Suite @MainActor struct MicrophoneTestTests {
    private func makeTest(
        stateAtOpen: AudioDeviceSnapshot? = .sample,
        _ configure: (ScriptedMicrophoneEngine) -> Void = { _ in }
    ) -> (fixture: MicrophoneTestFixture, test: MicrophoneTest) {
        let fixture = MicrophoneTestFixture(stateAtOpen: stateAtOpen, attachLog: false, configure: configure)
        return (fixture, MicrophoneTest(session: fixture.session))
    }

    @Test func mirrorsStatusAndLevel() {
        let (fixture, test) = makeTest()
        #expect(test.status == fixture.session.status)
        #expect(test.level == 0)

        test.toggleTest()
        #expect(test.status == fixture.session.status)
        #expect(test.status.phase == .running(outputDeviceName: "MacBook Pro Speakers"))

        fixture.engine.emit(.inputLevel(0.4))
        #expect(test.level == 0.4)

        test.toggleTest()
        #expect(test.status.phase == .stopped)
        #expect(test.level == 0)
    }

    @Test func toggleTestStartsAndStops() {
        let (fixture, test) = makeTest {
            $0.preparation = .settling
            $0.settlesAfterPolls = 1000
        }
        #expect(test.isActive == false)

        test.toggleTest()
        #expect(test.status.phase == .starting)
        #expect(test.isActive)

        test.toggleTest()
        #expect(test.status.phase == .stopped)
        #expect(test.isActive == false)
        #expect(fixture.engine.startedInputs.isEmpty)
    }

    @Test func statusTextPerPhase() {
        let (fixture, test) = makeTest {
            $0.preparation = .settling
            $0.settlesAfterPolls = 1
        }
        #expect(test.statusText == "Not running")

        test.toggleTest()
        #expect(test.statusText == "Starting…")

        fixture.scheduler.advance(by: 0.03)
        #expect(test.statusText == "Playing through MacBook Pro Speakers")

        fixture.engine.preparation = .ready
        fixture.engine.startResult = .success(nil)
        fixture.engine.emit(.restartNeeded)
        fixture.scheduler.runUntilIdle()
        #expect(test.statusText == "Playing through the default output")

        let denied = makeTest { $0.access = .denied }
        denied.test.toggleTest()
        #expect(denied.test.statusText
            == "Microphone access denied — allow MacMic in System Settings › Privacy & Security › Microphone")

        let noInput = makeTest(stateAtOpen: AudioDeviceSnapshot(input: nil, output: AudioDeviceSnapshot.sample.output))
        noInput.test.toggleTest()
        #expect(noInput.test.statusText == "Microphone unavailable")

        let engineFailure = makeTest { $0.startResult = .failure(.engineFailed("error -10875")) }
        engineFailure.test.toggleTest()
        #expect(engineFailure.test.statusText == "Failed: error -10875")
        #expect(engineFailure.test.isActive == false)
    }

    @Test func recorderStatusTextPerPhase() {
        let (fixture, test) = makeTest()
        #expect(test.recorderStatusText == "Nothing recorded")

        test.toggleTest()
        test.toggleRecording()
        #expect(test.recorderStatusText == "Recording… 0.0 s")
        fixture.engine.recordedDuration = 1.26
        fixture.scheduler.advance(by: 0.1)
        #expect(test.recorderStatusText == "Recording… 1.3 s")

        test.toggleRecording()
        #expect(test.recorderStatusText == "Recorded 1.3 s")

        test.togglePlayback()
        fixture.engine.playbackPosition = 0.5
        fixture.scheduler.advance(by: 0.1)
        #expect(test.recorderStatusText == "Playing 0.5 s of 1.3 s")

        test.togglePlayback()
        #expect(test.recorderStatusText == "Recorded 1.3 s")
        #expect(test.maxClipDuration == 30)
    }

    @Test func accessDeniedHintOnlyForThatFailure() {
        let denied = makeTest { $0.access = .denied }
        #expect(denied.test.isMicrophoneAccessDenied == false)

        denied.test.toggleTest()
        #expect(denied.test.isMicrophoneAccessDenied)

        denied.test.audioPageDidDisappear()
        #expect(denied.test.isMicrophoneAccessDenied == false)

        let engineFailure = makeTest { $0.startResult = .failure(.engineFailed("boom")) }
        engineFailure.test.toggleTest()
        #expect(engineFailure.test.isMicrophoneAccessDenied == false)
    }

    @Test func controlsEnabledFollowsInputPresence() {
        let (fixture, test) = makeTest()
        #expect(test.controlsEnabled)

        fixture.audio.simulateDeviceRemoved()
        #expect(test.controlsEnabled == false)

        fixture.audio.simulateDeviceAppeared(AudioDeviceSnapshot(input: nil, output: AudioDeviceSnapshot.sample.output))
        #expect(test.controlsEnabled == false)

        fixture.audio.simulateDeviceAppeared(.sample)
        #expect(test.controlsEnabled)
    }

    @Test func buttonEnablementFollowsTheSessionGates() {
        let (fixture, test) = makeTest()
        #expect(test.recordButtonEnabled == false)
        #expect(test.playButtonEnabled == false)

        test.toggleTest()
        #expect(test.recordButtonEnabled)
        #expect(test.playButtonEnabled == false)

        test.toggleRecording()
        #expect(test.isRecording)
        #expect(test.recordButtonEnabled)
        #expect(test.playButtonEnabled == false)

        fixture.engine.recordedDuration = 1
        test.toggleRecording()
        #expect(test.recordButtonEnabled)
        #expect(test.playButtonEnabled)

        test.togglePlayback()
        #expect(test.isPlaying)
        #expect(test.recordButtonEnabled == false)
        #expect(test.playButtonEnabled)

        test.toggleTest()
        #expect(test.recordButtonEnabled == false)
        #expect(test.playButtonEnabled == false)
    }

    @Test func pageDisappearingStopsTheTest() {
        let (fixture, test) = makeTest()
        test.toggleTest()

        test.audioPageDidDisappear()
        fixture.scheduler.advance(by: 5)

        #expect(test.status.phase == .stopped)
        #expect(fixture.engine.isRunning == false)
        #expect(fixture.engine.startedInputs.count == 1)
    }

    @Test func sleepStopsTheTest() {
        let (fixture, test) = makeTest()
        test.toggleTest()

        test.systemWillSleep()
        fixture.scheduler.advance(by: 5)

        #expect(test.status.phase == .stopped)
        #expect(fixture.engine.isRunning == false)
        #expect(fixture.engine.startedInputs.count == 1)
    }

    @Test func inputRemovalShowsMicrophoneUnavailable() {
        let (fixture, test) = makeTest()
        test.toggleTest()

        fixture.audio.simulateDeviceRemoved()

        #expect(test.status.phase == .failed(.inputDeviceUnavailable))
        #expect(test.statusText == "Microphone unavailable")
        #expect(test.controlsEnabled == false)
        #expect(test.isActive == false)
    }
}
