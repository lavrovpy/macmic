// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import CoreAudio
import Foundation
import Testing
@testable import QuadcastKit

/// `MicrophoneTestSession` through its interface, over
/// `MockAudioDeviceControl` + `ScriptedMicrophoneEngine` + `ManualScheduler`.
/// Every emission passes through `StatusLog`, which fails the test on an
/// invariant break or a repeated status.
@Suite @MainActor struct MicrophoneTestSessionTests {
    private static let input = MockAudioDeviceControl.inputDeviceID
    private static let speakers = "MacBook Pro Speakers"
    private static let starting = MicrophoneTestStatus.make(.starting)
    private static let running = MicrophoneTestStatus.make(.running(outputDeviceName: speakers))
    private static let inputUnavailable = MicrophoneTestStatus.make(.failed(.inputDeviceUnavailable), input: false)
    private static let outputOnly = AudioDeviceSnapshot(input: nil, output: AudioDeviceSnapshot.sample.output)

    private static func settling(_ engine: ScriptedMicrophoneEngine) {
        engine.preparation = .settling
        engine.settlesAfterPolls = 1000
    }

    /// A fixture whose session has been started and is running.
    private func runningFixture(_ configure: (ScriptedMicrophoneEngine) -> Void = { _ in }) -> MicrophoneTestFixture {
        let fixture = MicrophoneTestFixture(configure: configure)
        fixture.session.start()
        #expect(fixture.session.status.canStartRecording)
        return fixture
    }

    private func recordClip(_ fixture: MicrophoneTestFixture, duration: TimeInterval) {
        fixture.session.startRecording()
        fixture.engine.recordedDuration = duration
        fixture.session.stopRecording()
        #expect(fixture.session.status.recorder == .idle(clipDuration: duration))
    }

    // MARK: Lifecycle

    @Test func startRunsOnTheControlsCurrentInputID() {
        let fixture = MicrophoneTestFixture()
        fixture.audio.simulateReenumeration(inputID: 7000)

        fixture.session.start()

        #expect(fixture.engine.calls == [.discardClip, .microphoneAccess, .prepare(input: 7000), .start(input: 7000)])
        #expect(fixture.log!.statuses == [Self.starting, Self.running])
    }

    @Test func startWithoutInputFailsWithoutPrompting() {
        let fixture = MicrophoneTestFixture(stateAtOpen: Self.outputOnly)
        #expect(fixture.session.status.isInputAvailable == false)

        fixture.session.start()

        #expect(fixture.log!.statuses == [Self.inputUnavailable])
        #expect(fixture.engine.calls.contains(.microphoneAccess) == false)
        #expect(fixture.engine.calls.contains(.requestMicrophoneAccess) == false)
        #expect(fixture.engine.preparedInputs.isEmpty)
    }

    @Test func startWhileActiveIsIgnored() {
        let fixture = MicrophoneTestFixture(configure: Self.settling)
        fixture.session.start()
        let callsWhileStarting = fixture.engine.calls

        fixture.session.start()
        #expect(fixture.engine.calls == callsWhileStarting)

        fixture.scheduler.advance(by: 1.1)
        #expect(fixture.session.status == Self.running)
        let callsWhileRunning = fixture.engine.calls
        fixture.session.start()

        #expect(fixture.engine.calls == callsWhileRunning)
        #expect(fixture.log!.statuses == [Self.starting, Self.running])
    }

    @Test func authorizedStartReachesRunningWithTheOutputName() {
        let fixture = MicrophoneTestFixture { $0.startResult = .success("AirPods Pro") }

        fixture.session.start()

        #expect(fixture.log!.statuses == [Self.starting, .make(.running(outputDeviceName: "AirPods Pro"))])
        #expect(fixture.session.status.isActive)
        #expect(fixture.engine.isRunning)

        let unnamed = MicrophoneTestFixture { $0.startResult = .success(nil) }
        unnamed.session.start()
        #expect(unnamed.session.status == .make(.running(outputDeviceName: nil)))
    }

    @Test(arguments: [MicrophoneAccess.denied, .restricted])
    func deniedOrRestrictedAccessFailsWithoutPreparing(access: MicrophoneAccess) {
        let fixture = MicrophoneTestFixture { $0.access = access }

        fixture.session.start()

        #expect(fixture.log!.statuses == [.make(.failed(.microphoneAccessDenied))])
        #expect(fixture.engine.calls.contains(.requestMicrophoneAccess) == false)
        #expect(fixture.engine.preparedInputs.isEmpty)
    }

    @Test func accessPromptGrantedRunsDeniedFails() {
        let granted = MicrophoneTestFixture { $0.access = .notDetermined }
        granted.session.start()
        #expect(granted.log!.statuses == [Self.starting])
        #expect(granted.engine.calls.last == .requestMicrophoneAccess)
        #expect(granted.engine.preparedInputs.isEmpty)

        granted.engine.answerAccessPrompt(true)
        #expect(granted.log!.statuses == [Self.starting, Self.running])

        let denied = MicrophoneTestFixture { $0.access = .notDetermined }
        denied.session.start()
        denied.engine.answerAccessPrompt(false)
        #expect(denied.log!.statuses == [Self.starting, .make(.failed(.microphoneAccessDenied))])
        #expect(denied.engine.preparedInputs.isEmpty)
    }

    @Test func accessAnsweredAfterStopIsIgnored() {
        let fixture = MicrophoneTestFixture { $0.access = .notDetermined }
        fixture.session.start()
        fixture.session.stop()

        fixture.engine.answerAccessPrompt(true)

        #expect(fixture.log!.statuses == [Self.starting, .make(.stopped)])
        #expect(fixture.engine.preparedInputs.isEmpty)
    }

    @Test func accessPromptReadsTheInputIDAfterTheAnswer() {
        let fixture = MicrophoneTestFixture { $0.access = .notDetermined }
        fixture.session.start()
        fixture.audio.simulateReenumeration(inputID: 7100)

        fixture.engine.answerAccessPrompt(true)

        #expect(fixture.engine.preparedInputs == [7100])
        #expect(fixture.engine.startedInputs == [7100])
        #expect(fixture.session.status == Self.running)
    }

    @Test func micRemovalDuringAccessPromptFails() {
        let fixture = MicrophoneTestFixture { $0.access = .notDetermined }
        fixture.session.start()

        fixture.audio.simulateDeviceRemoved()
        #expect(fixture.session.status == Self.inputUnavailable)

        fixture.engine.answerAccessPrompt(true)
        #expect(fixture.engine.preparedInputs.isEmpty)
        #expect(fixture.log!.statuses == [Self.starting, Self.inputUnavailable])
    }

    @Test func settlingPollsEvery20msThenStarts() {
        let fixture = MicrophoneTestFixture {
            $0.preparation = .settling
            $0.settlesAfterPolls = 3
        }
        fixture.session.start()
        #expect(fixture.engine.count(of: .isSettled) == 1)
        #expect(fixture.session.status == Self.starting)

        fixture.scheduler.advance(by: 0.05)
        #expect(fixture.engine.count(of: .isSettled) == 3)
        #expect(fixture.engine.startedInputs.isEmpty)

        fixture.scheduler.advance(by: 0.02)
        #expect(fixture.engine.count(of: .isSettled) == 4)
        #expect(fixture.engine.startedInputs == [Self.input])
        #expect(fixture.log!.statuses == [Self.starting, Self.running])
    }

    @Test func settlingGivesUpAfter50PollsAndStartsAnyway() {
        let fixture = MicrophoneTestFixture(configure: Self.settling)
        fixture.session.start()

        fixture.scheduler.advance(by: 0.98)
        #expect(fixture.engine.startedInputs.isEmpty)
        #expect(fixture.session.status == Self.starting)

        fixture.scheduler.advance(by: 0.04)
        #expect(fixture.engine.startedInputs == [Self.input])
        #expect(fixture.engine.count(of: .isSettled) == 51)
        #expect(fixture.session.status == Self.running)
    }

    @Test func stopDuringSettlingNeverStartsTheEngine() {
        let fixture = MicrophoneTestFixture(configure: Self.settling)
        fixture.session.start()
        fixture.scheduler.advance(by: 0.1)

        fixture.session.stop()
        fixture.scheduler.advance(by: 2)

        #expect(fixture.engine.startedInputs.isEmpty)
        #expect(fixture.engine.isPrepared == false)
        #expect(fixture.scheduler.pendingCount == 0)
        #expect(fixture.log!.statuses == [Self.starting, .make(.stopped)])
    }

    @Test func prepareFailureFailsAndStopsTheEngine() {
        let fixture = MicrophoneTestFixture { $0.preparation = .failed(.engineFailed("no default output device")) }

        fixture.session.start()

        #expect(fixture.log!.statuses == [Self.starting, .make(.failed(.engineFailed("no default output device")))])
        #expect(fixture.engine.calls.suffix(3) == [.prepare(input: Self.input), .stop, .discardClip])
        #expect(fixture.engine.startedInputs.isEmpty)
    }

    @Test func startFailureFailsAndStopsTheEngine() {
        let fixture = MicrophoneTestFixture {
            $0.startResult = .failure(.engineFailed("could not bind aggregate device (-50)"))
        }

        fixture.session.start()

        #expect(fixture.log!.statuses == [
            Self.starting, .make(.failed(.engineFailed("could not bind aggregate device (-50)"))),
        ])
        #expect(fixture.engine.calls.suffix(3) == [.start(input: Self.input), .stop, .discardClip])
        #expect(fixture.engine.isPrepared == false)
    }

    @Test func stopEmitsOnlyOnARealChange() {
        let fixture = MicrophoneTestFixture()
        fixture.session.stop()
        #expect(fixture.log!.events.isEmpty)
        #expect(fixture.engine.calls.isEmpty)

        fixture.session.start()
        fixture.session.stop()
        fixture.session.stop()

        #expect(fixture.log!.statuses == [Self.starting, Self.running, .make(.stopped)])
        #expect(fixture.engine.count(of: .stop) == 1)
    }

    @Test func stopAfterFailureEmitsStopped() {
        let fixture = MicrophoneTestFixture { $0.startResult = .failure(.engineFailed("boom")) }
        fixture.session.start()

        fixture.session.stop()

        #expect(fixture.log!.phases == [.starting, .failed(.engineFailed("boom")), .stopped])
    }

    @Test func stopInsideTheStartingCallbackPreventsPrepare() {
        let fixture = MicrophoneTestFixture()
        let session = fixture.session
        fixture.log!.onStatus = { [weak session] status in
            if status.phase == .starting {
                session?.stop()
            }
        }

        fixture.session.start()

        #expect(fixture.log!.phases == [.starting, .stopped])
        #expect(fixture.engine.preparedInputs.isEmpty)
        #expect(fixture.engine.isRunning == false)
    }

    @Test func deinitStopsTheEngineWithoutCallbacks() {
        let fixture = MicrophoneTestFixture()
        fixture.session.start()
        fixture.session.startRecording()
        fixture.engine.emit(.inputLevel(0.5))
        let eventCount = fixture.log!.events.count
        weak var released = fixture.session

        fixture.releaseSession()

        #expect(released == nil)
        #expect(fixture.engine.calls.suffix(2) == [.stop, .discardClip])
        #expect(fixture.engine.isRunning == false)
        fixture.scheduler.advance(by: 1)
        #expect(fixture.log!.events.count == eventCount)
    }

    // MARK: Restarts

    @Test func restartTriggersInOneTurnRestartOnce() {
        let fixture = runningFixture()
        fixture.engine.emit(.restartNeeded)
        fixture.engine.emit(.restartNeeded)
        fixture.audio.simulateReenumeration(inputID: 7200)
        #expect(fixture.engine.preparedInputs == [Self.input])

        fixture.scheduler.runUntilIdle()

        #expect(fixture.engine.preparedInputs == [Self.input, 7200])
        #expect(fixture.log!.statuses == [Self.starting, Self.running, Self.starting, Self.running])
    }

    @Test func restartPassesThroughStartingWithTheNewOutputName() {
        let fixture = runningFixture()
        fixture.engine.startResult = .success("AirPods Pro")

        fixture.engine.emit(.restartNeeded)
        fixture.scheduler.runUntilIdle()

        #expect(fixture.log!.phases == [
            .starting, .running(outputDeviceName: Self.speakers), .starting, .running(outputDeviceName: "AirPods Pro"),
        ])
        #expect(fixture.engine.calls.suffix(3) == [.stop, .prepare(input: Self.input), .start(input: Self.input)])
    }

    @Test func restartReadsTheInputIDAgain() {
        let fixture = runningFixture()
        let audio = fixture.audio
        // The id changes after the restart has torn the run down, so only a
        // fresh read at begin() can see it.
        fixture.log!.onStatus = { status in
            if status.phase == .starting {
                audio.simulateReenumeration(inputID: 7300)
            }
        }

        fixture.engine.emit(.restartNeeded)
        fixture.scheduler.runUntilIdle()

        #expect(fixture.engine.preparedInputs == [Self.input, 7300])
        #expect(fixture.engine.startedInputs == [Self.input, 7300])
        #expect(fixture.session.status == Self.running)
    }

    @Test func changedInputIDWhileRunningRestartsOnTheNewID() {
        let fixture = runningFixture()

        fixture.audio.simulateReenumeration(inputID: 7400)
        #expect(fixture.session.status == Self.running)
        fixture.scheduler.runUntilIdle()

        #expect(fixture.engine.preparedInputs == [Self.input, 7400])
        #expect(fixture.log!.statuses == [Self.starting, Self.running, Self.starting, Self.running])
    }

    @Test func levelOnlyOrOutputOnlyChangesDoNotRestart() {
        let fixture = runningFixture()

        fixture.audio.simulateExternalChange(AudioDeviceSnapshot(
            input: AudioLevel(volume: 0.2, isMuted: true, decibels: -5),
            output: AudioDeviceSnapshot.sample.output
        ))
        fixture.audio.simulateReenumeration(inputID: Self.input, outputID: 9000)
        fixture.audio.simulateExternalChange(AudioDeviceSnapshot(input: AudioDeviceSnapshot.sample.input, output: nil))
        fixture.scheduler.runUntilIdle()

        #expect(fixture.engine.preparedInputs == [Self.input])
        #expect(fixture.log!.statuses == [Self.starting, Self.running])
    }

    @Test func restartTriggerDuringSettlingRestartsTheStart() {
        let fixture = MicrophoneTestFixture(configure: Self.settling)
        fixture.session.start()
        fixture.scheduler.advance(by: 0.1)

        fixture.engine.emit(.restartNeeded)
        fixture.scheduler.runUntilIdle()

        #expect(fixture.engine.preparedInputs == [Self.input, Self.input])
        #expect(fixture.engine.calls.contains(.stop))
        #expect(fixture.engine.startedInputs.isEmpty)
        #expect(fixture.log!.statuses == [Self.starting])

        fixture.engine.settlesAfterPolls = 0
        fixture.scheduler.advance(by: 0.03)
        #expect(fixture.session.status == Self.running)
    }

    @Test func fourthRestartWithin10sFailsNamingTheOutputAndDropsTheClip() {
        let fixture = runningFixture { $0.startResult = .success("AirPods Pro") }
        recordClip(fixture, duration: 2)
        for _ in 1...3 {
            fixture.scheduler.advance(by: 1)
            fixture.engine.emit(.restartNeeded)
            fixture.scheduler.runUntilIdle()
            #expect(fixture.session.status == .make(.running(outputDeviceName: "AirPods Pro"), .idle(clipDuration: 2)))
        }

        fixture.scheduler.advance(by: 1)
        fixture.engine.emit(.restartNeeded)
        fixture.scheduler.runUntilIdle()

        #expect(fixture.session.status
            == .make(.failed(.engineFailed("output device AirPods Pro keeps changing its audio format"))))
        #expect(fixture.engine.clipDuration == nil)
        #expect(fixture.engine.preparedInputs.count == 4)
        #expect(fixture.engine.isPrepared == false)
    }

    @Test func restartLimitWhileSettlingNamesNoEarlierSessionsOutput() {
        let fixture = runningFixture { $0.startResult = .success("AirPods Pro") }
        fixture.session.stop()
        Self.settling(fixture.engine)
        fixture.session.start()

        for _ in 1...4 {
            fixture.engine.emit(.restartNeeded)
            fixture.scheduler.runUntilIdle()
        }

        #expect(fixture.session.status
            == .make(.failed(.engineFailed("the output device keeps changing its audio format"))))
        #expect(fixture.engine.startedInputs == [Self.input])
    }

    @Test func restartsSpacedBeyondTheWindowKeepRunning() {
        let fixture = runningFixture()

        // Every 4 s: at most 3 restarts in any 10 s window, exactly the limit.
        for _ in 1...10 {
            fixture.scheduler.advance(by: 4)
            fixture.engine.emit(.restartNeeded)
            fixture.scheduler.runUntilIdle()
        }

        #expect(fixture.session.status == Self.running)
        #expect(fixture.engine.preparedInputs.count == 11)
    }

    @Test func startResetsTheRestartBudget() {
        let fixture = runningFixture()
        for _ in 1...3 {
            fixture.engine.emit(.restartNeeded)
            fixture.scheduler.runUntilIdle()
        }
        fixture.session.stop()
        fixture.session.start()

        for _ in 1...3 {
            fixture.engine.emit(.restartNeeded)
            fixture.scheduler.runUntilIdle()
        }

        #expect(fixture.session.status == Self.running)
    }

    @Test func stopInsideTheRestartsStartingCallbackLeavesTheEngineStopped() {
        let fixture = runningFixture()
        let session = fixture.session
        fixture.log!.onStatus = { [weak session] status in
            if status.phase == .starting {
                session?.stop()
            }
        }

        fixture.engine.emit(.restartNeeded)
        fixture.scheduler.runUntilIdle()

        #expect(fixture.log!.phases.suffix(2) == [.starting, .stopped])
        #expect(fixture.engine.preparedInputs == [Self.input])
        #expect(fixture.engine.isPrepared == false)
        #expect(fixture.engine.isRunning == false)
    }

    @Test func stopCancelsAPendingRestart() {
        let fixture = runningFixture()
        fixture.engine.emit(.restartNeeded)

        fixture.session.stop()
        #expect(fixture.scheduler.pendingCount == 0)

        // A restart left pending would land on this fresh run in the same turn.
        fixture.session.start()
        fixture.scheduler.runUntilIdle()

        #expect(fixture.engine.preparedInputs == [Self.input, Self.input])
        #expect(fixture.log!.statuses == [Self.starting, Self.running, .make(.stopped), Self.starting, Self.running])
        #expect(fixture.scheduler.pendingCount == 0)
    }

    @Test func eventsFromAStoppedRunAreIgnored() {
        let fixture = runningFixture()
        fixture.engine.emit(.restartNeeded)
        fixture.scheduler.runUntilIdle()

        fixture.engine.emitFromPreviousRun(.inputLevel(0.7))
        fixture.engine.emitFromPreviousRun(.restartNeeded)
        fixture.scheduler.runUntilIdle()
        #expect(fixture.log!.levels.isEmpty)
        #expect(fixture.engine.preparedInputs.count == 2)

        fixture.session.stop()
        fixture.engine.emitFromPreviousRun(.inputLevel(0.4))
        fixture.engine.emitFromPreviousRun(.restartNeeded)
        fixture.scheduler.runUntilIdle()
        #expect(fixture.log!.levels.isEmpty)
        #expect(fixture.engine.preparedInputs.count == 2)
        #expect(fixture.session.status == .make(.stopped))
    }

    // MARK: Availability

    @Test func micRemovalWhileRunningFailsAsOneValueWithInputUnavailable() {
        let fixture = runningFixture()
        fixture.session.startRecording()
        fixture.engine.recordedDuration = 1
        let before = fixture.log!.statuses.count

        fixture.audio.simulateDeviceRemoved()

        #expect(Array(fixture.log!.statuses.dropFirst(before)) == [Self.inputUnavailable])
        #expect(fixture.engine.isRunning == false)
        #expect(fixture.engine.clipDuration == nil)
    }

    @Test func micRemovalWhileSettlingFails() {
        let fixture = MicrophoneTestFixture(configure: Self.settling)
        fixture.session.start()

        fixture.audio.simulateDeviceRemoved()
        fixture.scheduler.advance(by: 2)

        #expect(fixture.log!.statuses == [Self.starting, Self.inputUnavailable])
        #expect(fixture.engine.startedInputs.isEmpty)
        #expect(fixture.engine.isPrepared == false)
    }

    @Test func availabilityIsTrackedWhileStopped() {
        let fixture = MicrophoneTestFixture()

        fixture.audio.simulateDeviceRemoved()
        fixture.audio.simulateDeviceAppeared(Self.outputOnly)
        fixture.audio.simulateDeviceAppeared(.sample)

        #expect(fixture.log!.statuses == [.make(.stopped, input: false), .make(.stopped)])
        #expect(fixture.engine.calls.isEmpty)
    }

    @Test func availabilityIsSeededFromTheSnapshotAtInit() {
        let present = MicrophoneTestFixture()
        let absent = MicrophoneTestFixture(stateAtOpen: nil)
        let outputOnly = MicrophoneTestFixture(stateAtOpen: Self.outputOnly)
        let unopened = MicrophoneTestFixture(openAudio: false)

        #expect(present.session.status == .make(.stopped))
        #expect(absent.session.status == .make(.stopped, input: false))
        #expect(outputOnly.session.status == .make(.stopped, input: false))
        #expect(unopened.session.status == .make(.stopped, input: false))
    }

    // MARK: Recorder

    @Test func recorderCommandsOutsideTheirPhaseAreIgnored() {
        let fixture = MicrophoneTestFixture {
            $0.preparation = .settling
            $0.settlesAfterPolls = 1
        }
        let session = fixture.session
        func pokeEveryRecorderCommand() {
            session.startRecording()
            session.stopRecording()
            session.startPlayback()
            session.stopPlayback()
        }

        pokeEveryRecorderCommand()
        #expect(fixture.engine.calls.isEmpty)

        session.start()
        let callsWhileStarting = fixture.engine.calls
        pokeEveryRecorderCommand()
        #expect(fixture.engine.calls == callsWhileStarting)

        fixture.scheduler.advance(by: 0.03)
        #expect(session.status == Self.running)
        let callsWhileRunning = fixture.engine.calls
        session.stopRecording()
        session.startPlayback()
        session.stopPlayback()
        #expect(fixture.engine.calls == callsWhileRunning)

        session.startRecording()
        session.startRecording()
        session.startPlayback()
        session.stopPlayback()
        #expect(fixture.engine.count(of: .startRecording(maxDuration: 30)) == 1)
        #expect(fixture.engine.count(of: .startPlayback) == 0)
        #expect(fixture.engine.count(of: .stopPlayback) == 0)
        #expect(fixture.log!.statuses == [
            Self.starting, Self.running, .make(.running(outputDeviceName: Self.speakers), .recording(elapsed: 0)),
        ])
    }

    @Test func recordStopPlayRoundTripWithProgressEvery100ms() {
        let fixture = runningFixture()
        let session = fixture.session
        let running = MicrophoneTestPhase.running(outputDeviceName: Self.speakers)

        session.startRecording()
        #expect(session.status == .make(running, .recording(elapsed: 0)))
        fixture.engine.recordedDuration = 0.1
        fixture.scheduler.advance(by: 0.09)
        #expect(session.status.recorder == .recording(elapsed: 0))
        fixture.scheduler.advance(by: 0.02)
        #expect(session.status.recorder == .recording(elapsed: 0.1))
        fixture.engine.recordedDuration = 0.25
        fixture.scheduler.advance(by: 0.1)
        #expect(session.status.recorder == .recording(elapsed: 0.25))

        session.stopRecording()
        #expect(session.status == .make(running, .idle(clipDuration: 0.25)))
        fixture.scheduler.advance(by: 0.5)

        session.startPlayback()
        #expect(session.status.recorder == .playing(elapsed: 0, clipDuration: 0.25))
        fixture.engine.playbackPosition = 0.1
        fixture.scheduler.advance(by: 0.1)
        #expect(session.status.recorder == .playing(elapsed: 0.1, clipDuration: 0.25))

        fixture.engine.finishPlayback()
        #expect(session.status == .make(running, .idle(clipDuration: 0.25)))
        #expect(fixture.log!.statuses.map(\.recorder) == [
            .idle(clipDuration: nil), .idle(clipDuration: nil),
            .recording(elapsed: 0), .recording(elapsed: 0.1), .recording(elapsed: 0.25),
            .idle(clipDuration: 0.25),
            .playing(elapsed: 0, clipDuration: 0.25), .playing(elapsed: 0.1, clipDuration: 0.25),
            .idle(clipDuration: 0.25),
        ])
    }

    @Test func endingTheRecorderPhaseInsideItsCallbackLeavesNoProgressTimer() {
        let fixture = runningFixture()
        let session = fixture.session
        let engine = fixture.engine
        fixture.log!.onStatus = { [weak session] status in
            switch status.recorder {
            case .recording:
                engine.recordedDuration = 1
                session?.stopRecording()
            case .playing: session?.stopPlayback()
            case .idle: break
            }
        }

        session.startRecording()
        #expect(session.status.recorder == .idle(clipDuration: 1))
        #expect(fixture.scheduler.pendingCount == 0)

        session.startPlayback()
        #expect(session.status.recorder == .idle(clipDuration: 1))
        #expect(fixture.scheduler.pendingCount == 0)
    }

    @Test func emptyRecordingLeavesNoClip() {
        let fixture = runningFixture()

        fixture.session.startRecording()
        fixture.session.stopRecording()

        #expect(fixture.session.status.recorder == .idle(clipDuration: nil))
        #expect(fixture.session.status.canStartPlayback == false)
        #expect(fixture.engine.clipDuration == nil)
    }

    @Test func recordingAutoStopsWhenTheClipIsFull() {
        let fixture = runningFixture()
        fixture.session.startRecording()
        #expect(fixture.engine.calls.last == .startRecording(maxDuration: 30))

        fixture.engine.fillRecording()

        #expect(fixture.session.status.recorder == .idle(clipDuration: 30))
        #expect(fixture.engine.isRecording == false)
        #expect(fixture.session.status.canStartPlayback)
    }

    @Test func lateFullFromAPreviousRecordingDoesNotStopANewOne() {
        let fixture = runningFixture()
        recordClip(fixture, duration: 1)
        fixture.session.startRecording()

        fixture.engine.fillPreviousRecording()

        #expect(fixture.session.status.isRecording)
        #expect(fixture.engine.isRecording)
    }

    @Test func recordingStartFailureKeepsThePreviousClip() {
        let fixture = runningFixture()
        recordClip(fixture, duration: 2)
        fixture.engine.canAllocateClip = false
        let statusCount = fixture.log!.statuses.count

        fixture.session.startRecording()
        fixture.scheduler.advance(by: 1)

        #expect(fixture.log!.statuses.count == statusCount)
        #expect(fixture.session.status.recorder == .idle(clipDuration: 2))
        #expect(fixture.engine.clipDuration == 2)
        #expect(fixture.session.status.canStartPlayback)
    }

    @Test func playbackRefusedWithoutClipOrWhileRecording() {
        let fixture = runningFixture()
        fixture.session.startPlayback()

        fixture.session.startRecording()
        fixture.engine.recordedDuration = 1
        fixture.session.startPlayback()

        #expect(fixture.engine.count(of: .startPlayback) == 0)
        #expect(fixture.session.status.isRecording)
    }

    @Test func playbackFinishingReturnsToIdleWithTheClipAndRestoresInput() {
        let fixture = runningFixture()
        recordClip(fixture, duration: 1.5)
        fixture.session.startPlayback()
        #expect(fixture.session.status.recorder == .playing(elapsed: 0, clipDuration: 1.5))

        fixture.engine.finishPlayback()

        #expect(fixture.session.status.recorder == .idle(clipDuration: 1.5))
        #expect(fixture.engine.calls.suffix(2) == [.startPlayback, .stopPlayback])
        #expect(fixture.engine.isPlaying == false)
        fixture.engine.emit(.inputLevel(0.4))
        #expect(fixture.log!.levels == [0.4])
    }

    @Test func staleCompletionDoesNotEndANewPlayback() {
        let fixture = runningFixture()
        recordClip(fixture, duration: 1)
        fixture.session.startPlayback()
        fixture.session.stopPlayback()
        fixture.session.startPlayback()

        fixture.engine.finishPreviousPlayback()

        #expect(fixture.session.status.isPlaying)
        #expect(fixture.engine.isPlaying)
    }

    @Test func playbackElapsedIsClampedToTheClip() {
        let fixture = runningFixture()
        recordClip(fixture, duration: 1)
        fixture.session.startPlayback()

        fixture.engine.playbackPosition = 1.4
        fixture.scheduler.advance(by: 0.1)

        #expect(fixture.session.status.recorder == .playing(elapsed: 1, clipDuration: 1))
    }

    @Test func restartDuringRecordingEmitsOneCombinedTransition() {
        let fixture = runningFixture()
        fixture.session.startRecording()
        fixture.engine.recordedDuration = 2
        let before = fixture.log!.statuses.count

        fixture.engine.emit(.restartNeeded)
        fixture.scheduler.runUntilIdle()

        #expect(Array(fixture.log!.statuses.dropFirst(before)) == [
            .make(.starting, .idle(clipDuration: 2)),
            .make(.running(outputDeviceName: Self.speakers), .idle(clipDuration: 2)),
        ])
        #expect(fixture.engine.clipDuration == 2)
        #expect(fixture.session.status.canStartPlayback)
    }

    @Test func restartDuringPlaybackCutsItAndKeepsTheClip() {
        let fixture = runningFixture()
        recordClip(fixture, duration: 2)
        fixture.session.startPlayback()
        let before = fixture.log!.statuses.count

        fixture.engine.emit(.restartNeeded)
        fixture.scheduler.runUntilIdle()

        #expect(Array(fixture.log!.statuses.dropFirst(before)) == [
            .make(.starting, .idle(clipDuration: 2)),
            .make(.running(outputDeviceName: Self.speakers), .idle(clipDuration: 2)),
        ])
        #expect(fixture.engine.isPlaying == false)
        #expect(fixture.engine.clipDuration == 2)

        fixture.session.startPlayback()
        fixture.engine.finishPreviousPlayback()
        #expect(fixture.session.status.isPlaying)
    }

    @Test func stopFailureAndStartEachDropTheClip() {
        let fixture = runningFixture()
        recordClip(fixture, duration: 2)
        fixture.session.stop()
        #expect(fixture.session.status == .make(.stopped))
        #expect(fixture.engine.clipDuration == nil)

        fixture.session.start()
        recordClip(fixture, duration: 3)
        fixture.audio.simulateDeviceRemoved()
        #expect(fixture.session.status == Self.inputUnavailable)
        #expect(fixture.engine.clipDuration == nil)

        fixture.audio.simulateDeviceAppeared(.sample)
        let callCount = fixture.engine.calls.count
        fixture.session.start()
        #expect(fixture.engine.calls[callCount] == .discardClip)
        #expect(fixture.session.status == Self.running)
    }

    // MARK: Level

    @Test func levelOnlyWhileRunning() {
        let fixture = MicrophoneTestFixture {
            $0.preparation = .settling
            $0.settlesAfterPolls = 1
        }
        fixture.session.start()
        fixture.engine.emit(.inputLevel(0.5))
        #expect(fixture.log!.levels.isEmpty)
        #expect(fixture.session.level == 0)

        fixture.scheduler.advance(by: 0.03)
        fixture.engine.emit(.inputLevel(0.5))
        #expect(fixture.log!.levels == [0.5])
        #expect(fixture.session.level == 0.5)

        fixture.session.stop()
        fixture.engine.emitFromPreviousRun(.inputLevel(0.6))
        #expect(fixture.log!.levels == [0.5, 0])
        #expect(fixture.session.level == 0)
    }

    @Test func levelFollowsTheClipDuringPlaybackThenTheInputAgain() {
        let fixture = runningFixture()
        recordClip(fixture, duration: 1)
        fixture.session.startPlayback()

        fixture.engine.emit(.inputLevel(0.3))
        fixture.engine.emitPlaybackLevel(0.6)
        #expect(fixture.session.level == 0.6)

        fixture.engine.finishPlayback()
        fixture.engine.emit(.inputLevel(0.2))

        #expect(fixture.log!.levels == [0.6, 0.2])
    }

    @Test func leavingRunningResetsLevelAfterTheStatus() {
        let stopped = runningFixture()
        stopped.engine.emit(.inputLevel(0.5))
        stopped.session.stop()
        #expect(stopped.log!.events.suffix(2) == [.status(.make(.stopped)), .level(0)])

        let restarted = runningFixture()
        restarted.engine.emit(.inputLevel(0.5))
        restarted.engine.emit(.restartNeeded)
        restarted.scheduler.runUntilIdle()
        #expect(restarted.log!.events.suffix(3) == [.status(Self.starting), .level(0), .status(Self.running)])

        let failed = runningFixture()
        failed.engine.emit(.inputLevel(0.5))
        failed.audio.simulateDeviceRemoved()
        #expect(failed.log!.events.suffix(2) == [.status(Self.inputUnavailable), .level(0)])
    }

    @Test func lateLevelFromAPreviousPlaybackIsDropped() {
        let fixture = runningFixture()
        recordClip(fixture, duration: 1)
        fixture.session.startPlayback()
        fixture.session.stopPlayback()

        fixture.engine.emitPreviousPlaybackLevel(0.9)
        #expect(fixture.log!.levels.isEmpty)

        fixture.session.startPlayback()
        fixture.engine.emitPreviousPlaybackLevel(0.8)
        fixture.engine.emitPlaybackLevel(0.3)
        #expect(fixture.log!.levels == [0.3])
    }
}
