// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import CoreAudio
import Testing
@testable import QuadcastKit

@Suite struct AudioDeviceSnapshotTests {
    @Test func isAvailableWhenEitherDirectionPresent() {
        let level = AudioLevel(volume: 0.5, isMuted: false)
        #expect(AudioDeviceSnapshot.unavailable.isAvailable == false)
        #expect(AudioDeviceSnapshot(input: level, output: nil).isAvailable)
        #expect(AudioDeviceSnapshot(input: nil, output: level).isAvailable)
        #expect(AudioDeviceSnapshot(input: level, output: level).isAvailable)
    }

    @Test func subscriptReadsAndWritesEachDirection() {
        var snapshot = AudioDeviceSnapshot.sample
        #expect(snapshot[.input] == AudioDeviceSnapshot.sample.input)
        #expect(snapshot[.output] == AudioDeviceSnapshot.sample.output)

        snapshot[.input]?.volume = 0.1
        snapshot[.output] = nil
        #expect(snapshot.input?.volume == 0.1)
        #expect(snapshot.output == nil)
        #expect(snapshot[.output] == nil)
    }

    @Test func equalityComparesLevelsNotDeviceIDs() {
        let sample = AudioDeviceSnapshot.sample
        let before = AudioDeviceSnapshot(input: sample.input, output: sample.output, deviceIDs: [.input: 70, .output: 74])
        let reenumerated = AudioDeviceSnapshot(input: sample.input, output: sample.output, deviceIDs: [.input: 110, .output: 102])
        var changed = before
        changed.input?.volume = 0.1

        #expect(before == reenumerated)
        #expect(before == sample)
        #expect(before != changed)
    }

    @Test func isIdenticalAlsoComparesDeviceIDs() {
        let sample = AudioDeviceSnapshot.sample
        let before = AudioDeviceSnapshot(input: sample.input, output: sample.output, deviceIDs: [.input: 70, .output: 74])
        let reenumerated = AudioDeviceSnapshot(input: sample.input, output: sample.output, deviceIDs: [.input: 110, .output: 102])
        var changed = before
        changed.output?.isMuted = true

        #expect(before.isIdentical(to: before))
        #expect(before.isIdentical(to: reenumerated) == false)
        #expect(before.isIdentical(to: sample) == false)
        #expect(before.isIdentical(to: changed) == false)
    }
}

/// Mock-only behaviour; the contract it shares with the production control
/// is in `AudioDeviceControlContractTests`.
@Suite struct MockAudioDeviceControlTests {
    @Test func propagatesScriptedOpenError() {
        let control = MockAudioDeviceControl()
        control.nextOpenError = .openFailed(-2)
        let deliveries = DeliveryRecorder(observing: control)

        #expect(throws: AudioDeviceControlError.openFailed(-2)) {
            try control.open()
        }
        #expect(control.isOpen == false)
        #expect(control.nextOpenError == nil)
        #expect(deliveries.count == 0)
    }

    @Test func recordsWritesInOrder() throws {
        let control = MockAudioDeviceControl()
        try control.open()
        let deliveries = DeliveryRecorder(observing: control)

        try control.setVolume(0.4, for: .input)
        try control.setMuted(true, for: .output)
        try control.setVolume(1.5, for: .output)

        #expect(control.writes == [.volume(0.4, .input), .muted(true, .output), .volume(1.5, .output)])
        #expect(control.snapshot.input?.volume == 0.4)
        #expect(control.snapshot.output?.isMuted == true)
        #expect(control.snapshot.output?.volume == 1.5)
        #expect(deliveries.count == 3)
        #expect(deliveries.last?.isIdentical(to: control.snapshot) == true)
    }

    @Test func writesDoNotEchoWhenDisabled() throws {
        let control = MockAudioDeviceControl()
        control.echoesWrites = false
        try control.open()
        let deliveries = DeliveryRecorder(observing: control)

        try control.setVolume(0.4, for: .input)

        #expect(control.writes == [.volume(0.4, .input)])
        #expect(control.snapshot.input?.volume == 0.4)
        #expect(deliveries.count == 0)
    }

    @Test func propagatesScriptedSetErrorAndConsumesItOnce() throws {
        let control = MockAudioDeviceControl()
        try control.open()
        control.nextSetError = .setFailed(-1)

        #expect(throws: AudioDeviceControlError.setFailed(-1)) {
            try control.setVolume(0.2, for: .input)
        }
        #expect(control.writes.isEmpty)
        #expect(control.snapshot == .sample)

        try control.setVolume(0.2, for: .input)
        #expect(control.writes == [.volume(0.2, .input)])
    }

    @Test func snapshotCarriesFixedIDsForPresentDirections() throws {
        let control = MockAudioDeviceControl()
        control.stateAtOpen = AudioDeviceSnapshot(input: AudioDeviceSnapshot.sample.input, output: nil)
        #expect(control.snapshot.deviceIDs.isEmpty)

        try control.open()
        #expect(control.snapshot.deviceIDs == [.input: MockAudioDeviceControl.inputDeviceID])

        control.simulateDeviceAppeared(.sample)
        #expect(control.snapshot.deviceIDs == [
            .input: MockAudioDeviceControl.inputDeviceID, .output: MockAudioDeviceControl.outputDeviceID,
        ])

        control.simulateDeviceRemoved()
        #expect(control.snapshot.deviceIDs.isEmpty)
    }

    @Test func simulateReenumerationKeepsLevelsAndChangesTheID() throws {
        let control = MockAudioDeviceControl()
        try control.open()
        let deliveries = DeliveryRecorder(observing: control)

        control.simulateReenumeration(inputID: 4200, outputID: 4201)

        #expect(deliveries.count == 1)
        #expect(deliveries.last == .sample)
        #expect(deliveries.last?.deviceIDs == [.input: 4200, .output: 4201])

        control.simulateReenumeration()

        #expect(deliveries.count == 2)
        #expect(deliveries.last == .sample)
        #expect(deliveries.last?.deviceIDs[.input] != 4200)
        #expect(deliveries.last?.deviceIDs[.output] != 4201)
    }

    @Test func closeDropsStateWithoutCallback() throws {
        let control = MockAudioDeviceControl()
        try control.open()
        let deliveries = DeliveryRecorder(observing: control)

        control.close()
        control.simulateDeviceRemoved()

        #expect(control.isOpen == false)
        #expect(control.snapshot.isIdentical(to: .unavailable))
        #expect(deliveries.count == 0)

        try control.open()
        #expect(control.snapshot == .sample)
        #expect(deliveries.snapshots == [.sample])
    }
}
