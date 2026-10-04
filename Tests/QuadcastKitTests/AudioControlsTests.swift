// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Combine
import Foundation
import Testing
@testable import MacMic
@testable import QuadcastKit

/// `AudioControls` over `MockAudioDeviceControl`: availability, optimistic
/// writes and their revert, echo reconciliation, and the UI text.
@Suite @MainActor struct AudioControlsTests {
    /// Builds the controls, then opens the mock, as `AppState` does.
    private func makeControls(
        _ configure: (MockAudioDeviceControl) -> Void = { _ in }
    ) throws -> (mock: MockAudioDeviceControl, controls: AudioControls) {
        let mock = MockAudioDeviceControl()
        configure(mock)
        let controls = AudioControls(control: mock)
        try mock.open()
        return (mock, controls)
    }

    // MARK: Availability

    @Test func absentAtLaunchLeavesControlsDisabled() throws {
        let (_, controls) = try makeControls { $0.stateAtOpen = nil }

        #expect(controls.snapshot == .unavailable)
        #expect(controls.isAvailable == false)
        #expect(controls.micControlsEnabled == false)
        #expect(controls.monitorControlsEnabled == false)
        #expect(controls.micGain == 0)
        #expect(controls.isMicMuted == false)
    }

    /// The control doesn't replay its state to a new observer.
    @Test func seedsFromAnAlreadyOpenControl() throws {
        let mock = MockAudioDeviceControl()
        try mock.open()

        let controls = AudioControls(control: mock)

        #expect(controls.snapshot == .sample)
        #expect(controls.micControlsEnabled == true)
        #expect(controls.monitorControlsEnabled == true)
    }

    @Test func deviceAppearingDeliversValues() throws {
        let (mock, controls) = try makeControls { $0.stateAtOpen = nil }

        mock.simulateDeviceAppeared(.sample)

        #expect(controls.snapshot == .sample)
        #expect(controls.micGain == 0.675)
        #expect(controls.monitorVolume == 0.812)
        #expect(controls.micControlsEnabled == true)
        #expect(controls.monitorControlsEnabled == true)
    }

    @Test func externalChangeUpdatesSnapshot() throws {
        let (mock, controls) = try makeControls()
        let changed = AudioLevel(volume: 0.3, isMuted: true, decibels: -3)

        mock.simulateExternalChange(AudioDeviceSnapshot(input: changed, output: AudioDeviceSnapshot.sample.output))

        #expect(controls.snapshot.input == changed)
        #expect(controls.micGain == 0.3)
        #expect(controls.isMicMuted == true)
    }

    @Test func deviceRemovalClearsValues() throws {
        let (mock, controls) = try makeControls()
        #expect(controls.micControlsEnabled == true)

        mock.simulateDeviceRemoved()

        #expect(controls.snapshot == .unavailable)
        #expect(controls.micGain == 0)
        #expect(controls.isMicMuted == false)
        #expect(controls.monitorVolume == 0)
        #expect(controls.isMonitorMuted == false)
        #expect(controls.micControlsEnabled == false)
        #expect(controls.monitorControlsEnabled == false)
    }

    // MARK: Writes

    @Test func settingGainReachesControlAndUpdatesOptimistically() throws {
        let (mock, controls) = try makeControls { $0.echoesWrites = false }

        controls.micGain = 0.4

        #expect(mock.writes == [.volume(0.4, .input)])
        #expect(controls.micGain == 0.4)
    }

    @Test func settingMutesReachControl() throws {
        let (mock, controls) = try makeControls { $0.echoesWrites = false }

        controls.isMicMuted = true
        controls.isMonitorMuted = true

        #expect(mock.writes == [.muted(true, .input), .muted(true, .output)])
        #expect(controls.isMicMuted == true)
        #expect(controls.isMonitorMuted == true)

        controls.isMicMuted = false
        #expect(mock.writes.last == .muted(false, .input))
        #expect(controls.isMicMuted == false)
    }

    @Test func settingMonitorVolumeReachesControl() throws {
        let (mock, controls) = try makeControls()

        controls.monitorVolume = 0.25

        #expect(mock.writes == [.volume(0.25, .output)])
        #expect(controls.monitorVolume == 0.25)
    }

    @Test func volumeIsClampedBeforeWriting() throws {
        let (mock, controls) = try makeControls()

        controls.micGain = 1.5
        #expect(mock.writes.last == .volume(1.0, .input))
        #expect(controls.micGain == 1.0)

        controls.monitorVolume = -0.2
        #expect(mock.writes.last == .volume(0.0, .output))
        #expect(controls.monitorVolume == 0.0)
    }

    @Test func writeIsIgnoredWhileDirectionAbsent() throws {
        let (mock, controls) = try makeControls {
            $0.stateAtOpen = AudioDeviceSnapshot(input: AudioDeviceSnapshot.sample.input, output: nil)
        }
        // The slider keeps 0.5 while the control holds 0.505, so a write that
        // reached the control (and failed) would show up as a revert to 0.505.
        controls.micGain = 0.5
        mock.simulateExternalChange(AudioDeviceSnapshot(
            input: AudioLevel(volume: 0.505, isMuted: false, decibels: 1.0),
            output: nil
        ))
        #expect(controls.micGain == 0.5)
        let before = controls.snapshot

        controls.monitorVolume = 0.5
        controls.isMonitorMuted = true

        #expect(controls.snapshot == before)
        #expect(controls.micGain == 0.5)
        #expect(mock.writes == [.volume(0.5, .input)])
    }

    @Test func gainSetFailureRevertsToControlSnapshot() throws {
        let (mock, controls) = try makeControls()
        controls.micGain = 0.5
        // Absorbed as an echo: the slider keeps 0.5 while the control holds 0.505.
        mock.simulateExternalChange(AudioDeviceSnapshot(
            input: AudioLevel(volume: 0.505, isMuted: false, decibels: 1.0),
            output: AudioDeviceSnapshot.sample.output
        ))
        #expect(controls.micGain == 0.5)
        mock.nextSetError = .setFailed(-1)

        controls.micGain = 0.9

        #expect(controls.snapshot.input?.volume == 0.505)
        #expect(controls.snapshot == mock.snapshot)
        #expect(mock.writes == [.volume(0.5, .input)])
    }

    @Test func micMuteSetFailureReverts() throws {
        let (mock, controls) = try makeControls()
        mock.nextSetError = .setFailed(-1)

        controls.isMicMuted = true

        #expect(controls.isMicMuted == false)
        #expect(controls.snapshot == .sample)
        #expect(mock.writes.isEmpty)
    }

    @Test func monitorMuteSetFailureReverts() throws {
        let (mock, controls) = try makeControls()
        mock.nextSetError = .setFailed(-1)

        controls.isMonitorMuted = true

        #expect(controls.isMonitorMuted == false)
        #expect(controls.snapshot == .sample)
        #expect(mock.writes.isEmpty)
    }

    @Test func muteSetFailureRevertsToWhatTheControlHoldsNotTheOldUIValue() throws {
        let (mock, controls) = try makeControls()
        controls.micGain = 0.5
        // Absorbed as an echo: the slider keeps 0.5 while the control holds 0.505.
        let held = AudioLevel(volume: 0.505, isMuted: false, decibels: 1.0)
        mock.simulateExternalChange(AudioDeviceSnapshot(input: held, output: AudioDeviceSnapshot.sample.output))
        #expect(controls.micGain == 0.5)
        mock.nextSetError = .setFailed(-1)

        controls.isMicMuted = true

        #expect(controls.isMicMuted == false)
        #expect(controls.snapshot.input == held)
        #expect(controls.snapshot == mock.snapshot)
        #expect(mock.writes == [.volume(0.5, .input)])
    }

    // MARK: Echo reconciliation

    @Test func echoWithinToleranceKeepsSliderValueButTakesDecibels() throws {
        let (mock, controls) = try makeControls()
        controls.micGain = 0.5

        mock.simulateExternalChange(AudioDeviceSnapshot(
            input: AudioLevel(volume: 0.505, isMuted: false, decibels: 1.0),
            output: AudioDeviceSnapshot.sample.output
        ))

        #expect(controls.micGain == 0.5)
        #expect(controls.snapshot.input?.decibels == 1.0)
    }

    @Test func echoOutsideToleranceIsAccepted() throws {
        let (mock, controls) = try makeControls()
        controls.micGain = 0.5

        mock.simulateExternalChange(AudioDeviceSnapshot(
            input: AudioLevel(volume: 0.7, isMuted: false, decibels: 3.0),
            output: AudioDeviceSnapshot.sample.output
        ))

        #expect(controls.micGain == 0.7)
        #expect(controls.snapshot.input?.decibels == 3.0)
    }

    @Test func echoToleranceIsOnePercent() throws {
        let (mock, controls) = try makeControls()
        controls.micGain = 0.5
        let output = AudioDeviceSnapshot.sample.output

        mock.simulateExternalChange(AudioDeviceSnapshot(
            input: AudioLevel(volume: 0.509, isMuted: false, decibels: 1.0),
            output: output
        ))
        #expect(controls.micGain == 0.5)

        mock.simulateExternalChange(AudioDeviceSnapshot(
            input: AudioLevel(volume: 0.515, isMuted: false, decibels: 1.25),
            output: output
        ))
        #expect(controls.micGain == 0.515)
        #expect(controls.snapshot.input?.decibels == 1.25)
    }

    @Test func muteChangeIsNeverTreatedAsEcho() throws {
        let (mock, controls) = try makeControls()
        #expect(controls.isMicMuted == false)
        let incoming = AudioLevel(volume: 0.68, isMuted: true, decibels: 2.25)

        mock.simulateExternalChange(AudioDeviceSnapshot(input: incoming, output: AudioDeviceSnapshot.sample.output))

        #expect(controls.isMicMuted == true)
        #expect(controls.snapshot.input == incoming)
    }

    @Test func partialPresenceTakesIncomingSnapshot() throws {
        let (mock, controls) = try makeControls()
        let outputOnly = AudioDeviceSnapshot(input: nil, output: AudioDeviceSnapshot.sample.output)

        mock.simulateDeviceAppeared(outputOnly)
        #expect(controls.snapshot == outputOnly)
        #expect(controls.micControlsEnabled == false)
        #expect(controls.monitorControlsEnabled == true)

        let input = AudioLevel(volume: 0.676, isMuted: false, decibels: 2.2)
        let both = AudioDeviceSnapshot(input: input, output: AudioDeviceSnapshot.sample.output)
        mock.simulateDeviceAppeared(both)
        #expect(controls.snapshot == both)
        #expect(controls.micControlsEnabled == true)
    }

    @Test func idOnlyRedeliveryDoesNotPublish() throws {
        let (mock, controls) = try makeControls()
        var changes = 0
        let subscription = controls.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        mock.simulateReenumeration(inputID: 4200)
        #expect(changes == 0)
        #expect(controls.snapshot == .sample)

        mock.simulateExternalChange(AudioDeviceSnapshot(
            input: AudioLevel(volume: 0.3, isMuted: false, decibels: -3),
            output: AudioDeviceSnapshot.sample.output
        ))
        #expect(changes == 1)
    }

    // MARK: UI text

    @Test func levelTextFormatsPercentAndDecibels() throws {
        let (mock, controls) = try makeControls()
        #expect(controls.micGainText == "68% (+2.1 dB)")
        #expect(controls.monitorVolumeText == "81% (-12.1 dB)")

        mock.simulateExternalChange(AudioDeviceSnapshot(input: AudioLevel(volume: 0.675, isMuted: false), output: nil))
        #expect(controls.micGainText == "68%")
        #expect(controls.monitorVolumeText == "—")
    }

    @Test func statusTextReflectsAvailability() throws {
        let (mock, controls) = try makeControls()
        #expect(controls.statusText == "Audio device connected")

        mock.simulateDeviceRemoved()
        #expect(controls.statusText == "Audio device not found")

        mock.simulateDeviceAppeared(AudioDeviceSnapshot(input: nil, output: AudioDeviceSnapshot.sample.output))
        #expect(controls.statusText == "Audio device connected")
    }
}
