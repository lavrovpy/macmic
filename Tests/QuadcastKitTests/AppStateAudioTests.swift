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
@testable import MacMic
@testable import QuadcastKit

/// `AppState`'s audio surface (gain/mute, monitoring volume/mute) driven
/// through `MockAudioDeviceControl`: availability, optimistic writes, echo
/// reconciliation, and independence from the lighting connection.
@Suite @MainActor struct AppStateAudioTests {
    // MARK: Availability

    @Test func audioAbsentAtLaunchLeavesControlsDisabled() throws {
        let audio = MockAudioDeviceControl()
        audio.stateAtOpen = nil
        let fixture = AppStateFixture(audio: audio)
        let state = fixture.state

        #expect(state.audio == .unavailable)
        #expect(state.micControlsEnabled == false)
        #expect(state.monitorControlsEnabled == false)
        #expect(state.audioStatusText == "Audio device not found")
    }

    @Test func openFailureLeavesAudioUnavailable() throws {
        let audio = MockAudioDeviceControl()
        audio.nextOpenError = .openFailed(-1)
        let fixture = AppStateFixture(audio: audio)
        let state = fixture.state

        #expect(state.audio == .unavailable)
        #expect(state.micControlsEnabled == false)
    }

    @Test func deviceAppearingDeliversValuesAndEnablesControls() throws {
        let audio = MockAudioDeviceControl()
        audio.stateAtOpen = nil
        let fixture = AppStateFixture(audio: audio)
        let state = fixture.state

        audio.simulateDeviceAppeared(.sample)

        #expect(state.micGain == 0.675)
        #expect(state.monitorVolume == 0.812)
        #expect(state.micControlsEnabled == true)
        #expect(state.monitorControlsEnabled == true)
        #expect(state.audioStatusText == "Audio device connected")
    }

    @Test func externalChangeUpdatesPublishedState() throws {
        let audio = MockAudioDeviceControl()
        let fixture = AppStateFixture(audio: audio)
        let state = fixture.state

        audio.simulateExternalChange(AudioDeviceSnapshot(
            input: AudioLevel(volume: 0.3, isMuted: true, decibels: -3),
            output: AudioDeviceSnapshot.sample.output
        ))

        #expect(state.micGain == 0.3)
        #expect(state.isMicMuted == true)
    }

    @Test func deviceRemovalClearsValues() throws {
        let audio = MockAudioDeviceControl()
        let fixture = AppStateFixture(audio: audio)
        let state = fixture.state
        #expect(state.micControlsEnabled == true)

        audio.simulateDeviceRemoved()

        #expect(state.audio == .unavailable)
        #expect(state.micGain == 0)
        #expect(state.isMicMuted == false)
        #expect(state.monitorVolume == 0)
        #expect(state.isMonitorMuted == false)
    }

    @Test func audioAvailabilityIsIndependentOfLightingConnection() throws {
        let fixture = AppStateFixture()
        let transport = fixture.transport
        let audio = fixture.audio
        let state = fixture.state
        #expect(state.isConnected == true)
        #expect(state.micControlsEnabled == true)

        transport.simulateUnplug()
        #expect(state.isConnected == false)
        #expect(state.controlsEnabled == false)
        #expect(state.micControlsEnabled == true)
        #expect(state.monitorControlsEnabled == true)

        transport.simulateConnect()
        audio.simulateDeviceRemoved()
        #expect(state.isConnected == true)
        #expect(state.controlsEnabled == true)
        #expect(state.micControlsEnabled == false)
        #expect(state.monitorControlsEnabled == false)
    }

    // MARK: Writes

    @Test func settingGainReachesControlAndUpdatesOptimistically() throws {
        let audio = MockAudioDeviceControl()
        audio.echoesWrites = false
        let fixture = AppStateFixture(audio: audio)
        let state = fixture.state

        state.micGain = 0.4

        #expect(audio.writes.last == .volume(0.4, .input))
        #expect(state.micGain == 0.4)
    }

    @Test func settingMutesReachControl() throws {
        let audio = MockAudioDeviceControl()
        let fixture = AppStateFixture(audio: audio)
        let state = fixture.state

        state.isMicMuted = true
        state.isMonitorMuted = true

        #expect(audio.writes == [.muted(true, .input), .muted(true, .output)])
        #expect(state.isMicMuted == true)
        #expect(state.isMonitorMuted == true)

        state.isMicMuted = false
        #expect(audio.writes.last == .muted(false, .input))
        #expect(state.isMicMuted == false)
    }

    @Test func settingMonitorVolumeReachesControl() throws {
        let audio = MockAudioDeviceControl()
        let fixture = AppStateFixture(audio: audio)
        let state = fixture.state

        state.monitorVolume = 0.25

        #expect(audio.writes.last == .volume(0.25, .output))
        #expect(state.monitorVolume == 0.25)
    }

    @Test func volumeIsClampedBeforeWriting() throws {
        let audio = MockAudioDeviceControl()
        let fixture = AppStateFixture(audio: audio)
        let state = fixture.state

        state.micGain = 1.5
        #expect(audio.writes.last == .volume(1.0, .input))
        #expect(state.micGain == 1.0)

        state.micGain = -0.2
        #expect(audio.writes.last == .volume(0.0, .input))
        #expect(state.micGain == 0.0)
    }

    @Test func writeIsIgnoredWhileDirectionAbsent() throws {
        let audio = MockAudioDeviceControl()
        audio.stateAtOpen = AudioDeviceSnapshot(input: AudioDeviceSnapshot.sample.input, output: nil)
        let fixture = AppStateFixture(audio: audio)
        let state = fixture.state
        let before = state.audio

        state.monitorVolume = 0.5
        state.isMonitorMuted = true

        #expect(audio.writes.isEmpty)
        #expect(state.audio == before)
    }

    @Test func setFailureRevertsToControlSnapshot() throws {
        let audio = MockAudioDeviceControl()
        audio.nextSetError = .setFailed(-1)
        let fixture = AppStateFixture(audio: audio)
        let state = fixture.state

        state.micGain = 0.9

        #expect(state.micGain == 0.675)
        #expect(audio.writes.isEmpty)
    }

    @Test func micMuteSetFailureRevertsToControlSnapshot() throws {
        let audio = MockAudioDeviceControl()
        audio.nextSetError = .setFailed(-1)
        let fixture = AppStateFixture(audio: audio)
        let state = fixture.state

        state.isMicMuted = true

        #expect(state.isMicMuted == false)
        #expect(state.audio == .sample)
        #expect(audio.writes.isEmpty)
    }

    @Test func monitorMuteSetFailureRevertsToControlSnapshot() throws {
        let audio = MockAudioDeviceControl()
        audio.nextSetError = .setFailed(-1)
        let fixture = AppStateFixture(audio: audio)
        let state = fixture.state

        state.isMonitorMuted = true

        #expect(state.isMonitorMuted == false)
        #expect(state.audio == .sample)
        #expect(audio.writes.isEmpty)
    }

    @Test func muteSetFailureRevertsToWhatTheControlHoldsNotTheOldUIValue() throws {
        let audio = MockAudioDeviceControl()
        let fixture = AppStateFixture(audio: audio)
        let state = fixture.state
        audio.simulateExternalChange(AudioDeviceSnapshot(
            input: AudioLevel(volume: 0.675, isMuted: true, decibels: 2.125),
            output: AudioDeviceSnapshot.sample.output
        ))
        audio.nextSetError = .setFailed(-1)

        state.isMicMuted = false

        #expect(state.isMicMuted == true)
        #expect(audio.writes.isEmpty)
    }

    // MARK: Echo reconciliation

    @Test func echoWithinToleranceKeepsSliderValueButTakesDecibels() throws {
        let audio = MockAudioDeviceControl()
        let fixture = AppStateFixture(audio: audio)
        let state = fixture.state
        state.micGain = 0.5

        audio.simulateExternalChange(AudioDeviceSnapshot(
            input: AudioLevel(volume: 0.505, isMuted: false, decibels: 1.0),
            output: audio.snapshot.output
        ))

        #expect(state.micGain == 0.5)
        #expect(state.audio.input?.decibels == 1.0)
    }

    @Test func echoOutsideToleranceIsAccepted() throws {
        let audio = MockAudioDeviceControl()
        let fixture = AppStateFixture(audio: audio)
        let state = fixture.state
        state.micGain = 0.5

        audio.simulateExternalChange(AudioDeviceSnapshot(
            input: AudioLevel(volume: 0.7, isMuted: false, decibels: 3.0),
            output: audio.snapshot.output
        ))

        #expect(state.micGain == 0.7)
    }

    @Test func muteChangeIsNeverTreatedAsEcho() throws {
        let audio = MockAudioDeviceControl()
        let fixture = AppStateFixture(audio: audio)
        let state = fixture.state
        #expect(state.isMicMuted == false)

        audio.simulateExternalChange(AudioDeviceSnapshot(
            input: AudioLevel(volume: 0.675, isMuted: true, decibels: 2.125),
            output: audio.snapshot.output
        ))

        #expect(state.isMicMuted == true)
    }

    @Test func reconcileHandlesNilOnEitherSide() throws {
        let level = AudioLevel(volume: 0.5, isMuted: false, decibels: 0)
        let present = AudioDeviceSnapshot(input: level, output: level)

        let appeared = AppState.reconcile(current: .unavailable, incoming: present, tolerance: 0.01)
        #expect(appeared == present)

        let removed = AppState.reconcile(current: present, incoming: .unavailable, tolerance: 0.01)
        #expect(removed == .unavailable)

        let outputOnly = AudioDeviceSnapshot(input: nil, output: level)
        let partial = AppState.reconcile(current: present, incoming: outputOnly, tolerance: 0.01)
        #expect(partial == outputOnly)
    }

    // MARK: Lifecycle

    @Test func audioStateIsNotPersisted() throws {
        let fixture = AppStateFixture()
        fixture.state.micGain = 0.2
        fixture.state.isMicMuted = true

        let audioKeys = fixture.defaults.dictionaryRepresentation().keys.filter { $0.lowercased().contains("audio") }
        #expect(audioKeys.isEmpty)

        let audio = MockAudioDeviceControl()
        audio.stateAtOpen = nil
        fixture.relaunch(audio: audio)
        #expect(fixture.state.audio == .unavailable)
    }

    @Test func deinitClosesAudioControl() throws {
        let fixture = AppStateFixture()
        #expect(fixture.audio.isOpen == true)

        fixture.releaseState()

        #expect(fixture.audio.isOpen == false)
    }

    // MARK: UI text

    @Test func levelTextFormatsPercentAndDecibels() throws {
        #expect(AppState.levelText(AudioLevel(volume: 0.675, isMuted: false, decibels: 2.125)) == "68% (+2.1 dB)")
        #expect(AppState.levelText(AudioLevel(volume: 0.812, isMuted: false, decibels: -12.0625)) == "81% (-12.1 dB)")
        #expect(AppState.levelText(AudioLevel(volume: 0.675, isMuted: false)) == "68%")
        #expect(AppState.levelText(nil) == "—")
    }

    @Test func audioStatusTextReflectsAvailability() throws {
        let audio = MockAudioDeviceControl()
        let fixture = AppStateFixture(audio: audio)
        let state = fixture.state
        #expect(state.audioStatusText == "Audio device connected")

        audio.simulateDeviceRemoved()
        #expect(state.audioStatusText == "Audio device not found")

        audio.simulateDeviceAppeared(AudioDeviceSnapshot(input: nil, output: AudioDeviceSnapshot.sample.output))
        #expect(state.audioStatusText == "Audio device connected")
        #expect(state.micControlsEnabled == false)
        #expect(state.monitorControlsEnabled == true)
    }
}
