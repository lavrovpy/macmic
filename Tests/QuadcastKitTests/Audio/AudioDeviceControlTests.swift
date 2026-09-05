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
}

@Suite struct CoreAudioDeviceControlMatchingTests {
    @Test func matchesModelUIDWithVendorProductSuffix() {
        #expect(CoreAudioDeviceControl.isQuadcast(modelUID: "HyperX QuadCast S:0951:171D", name: nil))
    }

    @Test func matchesModelUIDCaseInsensitively() {
        #expect(CoreAudioDeviceControl.isQuadcast(modelUID: "HyperX QuadCast S:0951:171d", name: nil))
    }

    @Test func rejectsOtherModelUIDs() {
        #expect(CoreAudioDeviceControl.isQuadcast(modelUID: "MacBook Pro Microphone:1234:5678", name: nil) == false)
        #expect(CoreAudioDeviceControl.isQuadcast(modelUID: "Foo:0951:1234", name: nil) == false)
        #expect(CoreAudioDeviceControl.isQuadcast(modelUID: "", name: nil) == false)
    }

    @Test func fallsBackToNameOnlyWhenModelUIDIsAbsent() {
        #expect(CoreAudioDeviceControl.isQuadcast(modelUID: nil, name: "HyperX QuadCast S"))
        #expect(CoreAudioDeviceControl.isQuadcast(modelUID: nil, name: "MacBook Pro Microphone") == false)
        #expect(CoreAudioDeviceControl.isQuadcast(modelUID: nil, name: nil) == false)
        #expect(CoreAudioDeviceControl.isQuadcast(modelUID: "Foo:0951:1234", name: "HyperX QuadCast S") == false)
    }

    @Test func directionsFollowChannelCounts() {
        #expect(CoreAudioDeviceControl.directions(inputChannels: 2, outputChannels: 0) == [.input])
        #expect(CoreAudioDeviceControl.directions(inputChannels: 0, outputChannels: 2) == [.output])
        #expect(CoreAudioDeviceControl.directions(inputChannels: 2, outputChannels: 2) == [.input, .output])
        #expect(CoreAudioDeviceControl.directions(inputChannels: 0, outputChannels: 0) == [])
    }

    @Test func scopesFollowDirection() {
        #expect(CoreAudioDeviceControl.scope(for: .input) == kAudioObjectPropertyScopeInput)
        #expect(CoreAudioDeviceControl.scope(for: .output) == kAudioObjectPropertyScopeOutput)
    }

    @Test func usbIDsMatchTheLightingTransportsProductList() {
        #expect(IOUSBHostTransport.vendorID == CoreAudioDeviceControl.usbVendorID)
        #expect(IOUSBHostTransport.productIDs.contains(CoreAudioDeviceControl.usbProductID))
        let suffix = String(
            format: ":%04x:%04x", CoreAudioDeviceControl.usbVendorID, CoreAudioDeviceControl.usbProductID
        )
        #expect(CoreAudioDeviceControl.modelUIDSuffix == suffix)
    }
}

@Suite struct MockAudioDeviceControlTests {
    @Test func openDeliversStateAtOpen() throws {
        let control = MockAudioDeviceControl()
        var delivered: [AudioDeviceSnapshot] = []
        control.onStateChanged = { delivered.append($0) }

        try control.open()

        #expect(control.isOpen)
        #expect(control.snapshot == .sample)
        #expect(delivered == [.sample])
    }

    @Test func openWithNoDeviceDeliversUnavailable() throws {
        let control = MockAudioDeviceControl()
        control.stateAtOpen = nil
        var delivered: [AudioDeviceSnapshot] = []
        control.onStateChanged = { delivered.append($0) }

        try control.open()

        #expect(control.snapshot == .unavailable)
        #expect(delivered == [.unavailable])
    }

    @Test func propagatesScriptedOpenError() {
        let control = MockAudioDeviceControl()
        control.nextOpenError = .openFailed(-2)
        var delivered: [AudioDeviceSnapshot] = []
        control.onStateChanged = { delivered.append($0) }

        var caught: AudioDeviceControlError?
        do {
            try control.open()
            Issue.record("expected open() to throw")
        } catch let error as AudioDeviceControlError {
            caught = error
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(caught == .openFailed(-2))
        #expect(control.isOpen == false)
        #expect(control.nextOpenError == nil)
        #expect(delivered.isEmpty)
    }

    @Test func recordsWritesInOrderAndEchoes() throws {
        let control = MockAudioDeviceControl()
        try control.open()
        var delivered: [AudioDeviceSnapshot] = []
        control.onStateChanged = { delivered.append($0) }

        try control.setVolume(0.4, for: .input)
        try control.setMuted(true, for: .output)
        try control.setVolume(1.5, for: .output)

        #expect(control.writes == [.volume(0.4, .input), .muted(true, .output), .volume(1.5, .output)])
        #expect(control.snapshot.input?.volume == 0.4)
        #expect(control.snapshot.output?.isMuted == true)
        #expect(control.snapshot.output?.volume == 1.5)
        #expect(delivered.count == 3)
        #expect(delivered.last == control.snapshot)
    }

    @Test func writesDoNotEchoWhenDisabled() throws {
        let control = MockAudioDeviceControl()
        control.echoesWrites = false
        try control.open()
        var delivered: [AudioDeviceSnapshot] = []
        control.onStateChanged = { delivered.append($0) }

        try control.setVolume(0.4, for: .input)

        #expect(control.writes == [.volume(0.4, .input)])
        #expect(control.snapshot.input?.volume == 0.4)
        #expect(delivered.isEmpty)
    }

    @Test func writeThrowsDeviceNotFoundForAbsentDirection() throws {
        let control = MockAudioDeviceControl()
        control.stateAtOpen = AudioDeviceSnapshot(input: AudioDeviceSnapshot.sample.input, output: nil)
        try control.open()

        var caught: AudioDeviceControlError?
        do {
            try control.setVolume(0.5, for: .output)
            Issue.record("expected setVolume to throw for an absent direction")
        } catch let error as AudioDeviceControlError {
            caught = error
        }
        #expect(caught == .deviceNotFound(.output))
        #expect(control.writes.isEmpty)
    }

    @Test func writeThrowsDeviceNotFoundBeforeOpen() {
        let control = MockAudioDeviceControl()
        var caught: AudioDeviceControlError?
        do {
            try control.setMuted(true, for: .input)
            Issue.record("expected setMuted to throw before open()")
        } catch let error as AudioDeviceControlError {
            caught = error
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(caught == .deviceNotFound(.input))
    }

    @Test func propagatesScriptedSetErrorAndConsumesItOnce() throws {
        let control = MockAudioDeviceControl()
        try control.open()
        control.nextSetError = .setFailed(-1)

        var caught: AudioDeviceControlError?
        do {
            try control.setVolume(0.2, for: .input)
            Issue.record("expected setVolume to throw")
        } catch let error as AudioDeviceControlError {
            caught = error
        }
        #expect(caught == .setFailed(-1))
        #expect(control.writes.isEmpty)
        #expect(control.snapshot == .sample)

        try control.setVolume(0.2, for: .input)
        #expect(control.writes == [.volume(0.2, .input)])
    }

    @Test func simulateRemovedAndAppearedFireCallbacksInOrder() throws {
        let control = MockAudioDeviceControl()
        try control.open()
        var delivered: [AudioDeviceSnapshot] = []
        control.onStateChanged = { delivered.append($0) }

        let changed = AudioDeviceSnapshot(
            input: AudioLevel(volume: 0.3, isMuted: true, decibels: -1),
            output: AudioDeviceSnapshot.sample.output
        )
        control.simulateDeviceRemoved()
        control.simulateDeviceAppeared(.sample)
        control.simulateExternalChange(changed)

        #expect(delivered == [.unavailable, .sample, changed])
        #expect(control.snapshot == changed)
    }

    @Test func closeDropsStateWithoutCallback() throws {
        let control = MockAudioDeviceControl()
        try control.open()
        var delivered: [AudioDeviceSnapshot] = []
        control.onStateChanged = { delivered.append($0) }

        control.close()

        #expect(control.isOpen == false)
        #expect(control.snapshot == .unavailable)
        #expect(delivered.isEmpty)

        try control.open()
        #expect(control.snapshot == .sample)
        #expect(delivered == [.sample])
    }
}

/// The pure half of `CoreAudioDeviceControl.rescanDevices`: which HAL device
/// serves which direction, and which per-device listeners a rescan has to
/// drop or register. The HAL reads themselves are hardware-only.
@Suite struct CoreAudioDeviceControlRescanTests {
    private typealias Enumerated = CoreAudioDeviceControl.EnumeratedDevice
    private typealias Tracked = CoreAudioDeviceControl.TrackedDevice
    private typealias Diff = CoreAudioDeviceControl.ListenerDiff

    private static let modelUID = "HyperX QuadCast S:0951:171D"
    private static let mic = Enumerated(id: 70, modelUID: modelUID, name: "HyperX QuadCast S", inputChannels: 2, outputChannels: 0)
    private static let monitor = Enumerated(id: 74, modelUID: modelUID, name: "HyperX QuadCast S", inputChannels: 0, outputChannels: 2)
    private static let builtIn = Enumerated(id: 50, modelUID: "MacBook Pro Microphone:1234:5678", name: "MacBook Pro Microphone", inputChannels: 1, outputChannels: 0)

    @Test func assignsTheTwoQuadcastDevicesByChannelScope() {
        let assigned = CoreAudioDeviceControl.assignDirections([Self.builtIn, Self.mic, Self.monitor])
        #expect(assigned == [.input: Tracked(id: 70, channelCount: 2), .output: Tracked(id: 74, channelCount: 2)])
    }

    @Test func ignoresNonQuadcastDevicesEvenWhenTheyAreTheOnlyOnes() {
        let other = Enumerated(id: 51, modelUID: "Speakers:1234:5678", name: "Speakers", inputChannels: 0, outputChannels: 2)
        #expect(CoreAudioDeviceControl.assignDirections([Self.builtIn, other]).isEmpty)
        #expect(CoreAudioDeviceControl.assignDirections([]).isEmpty)
    }

    @Test func firstEnumeratedWinsADuplicateDirection() {
        let secondMic = Enumerated(id: 80, modelUID: Self.modelUID, name: nil, inputChannels: 2, outputChannels: 0)
        let assigned = CoreAudioDeviceControl.assignDirections([Self.mic, secondMic, Self.monitor])
        #expect(assigned[.input] == Tracked(id: 70, channelCount: 2))
        #expect(assigned[.output] == Tracked(id: 74, channelCount: 2))
    }

    @Test func aCombinedDeviceServesBothDirectionsWithPerScopeChannelCounts() {
        let combined = Enumerated(id: 90, modelUID: Self.modelUID, name: nil, inputChannels: 1, outputChannels: 2)
        let assigned = CoreAudioDeviceControl.assignDirections([combined])
        #expect(assigned == [.input: Tracked(id: 90, channelCount: 1), .output: Tracked(id: 90, channelCount: 2)])
    }

    @Test func nameFallbackAppliesInsideAssignment() {
        let unnamedUID = Enumerated(id: 70, modelUID: nil, name: "HyperX QuadCast S", inputChannels: 2, outputChannels: 0)
        #expect(CoreAudioDeviceControl.assignDirections([unnamedUID])[.input] == Tracked(id: 70, channelCount: 2))
    }

    @Test func firstScanAddsEverythingAndRemovesNothing() {
        let current: [AudioDirection: Tracked] = [.input: Tracked(id: 70, channelCount: 2), .output: Tracked(id: 74, channelCount: 2)]
        #expect(CoreAudioDeviceControl.listenerDiff(previous: [:], current: current) == Diff(remove: [:], add: current))
    }

    @Test func unchangedScanIsANoOp() {
        let tracked: [AudioDirection: Tracked] = [.input: Tracked(id: 70, channelCount: 2), .output: Tracked(id: 74, channelCount: 2)]
        #expect(CoreAudioDeviceControl.listenerDiff(previous: tracked, current: tracked) == Diff(remove: [:], add: [:]))
    }

    @Test func unplugRemovesEveryTrackedListener() {
        let tracked: [AudioDirection: Tracked] = [.input: Tracked(id: 70, channelCount: 2), .output: Tracked(id: 74, channelCount: 2)]
        #expect(CoreAudioDeviceControl.listenerDiff(previous: tracked, current: [:]) == Diff(remove: tracked, add: [:]))
    }

    @Test func replugWithNewIDsSwapsListeners() {
        let before: [AudioDirection: Tracked] = [.input: Tracked(id: 70, channelCount: 2), .output: Tracked(id: 74, channelCount: 2)]
        let after: [AudioDirection: Tracked] = [.input: Tracked(id: 102, channelCount: 2), .output: Tracked(id: 106, channelCount: 2)]
        #expect(CoreAudioDeviceControl.listenerDiff(previous: before, current: after) == Diff(remove: before, add: after))
    }

    @Test func partialRemovalOnlyTouchesTheMissingDirection() {
        let before: [AudioDirection: Tracked] = [.input: Tracked(id: 70, channelCount: 2), .output: Tracked(id: 74, channelCount: 2)]
        let after: [AudioDirection: Tracked] = [.input: Tracked(id: 70, channelCount: 2)]
        #expect(CoreAudioDeviceControl.listenerDiff(previous: before, current: after)
            == Diff(remove: [.output: Tracked(id: 74, channelCount: 2)], add: [:]))
    }

    @Test func idReusedForTheSameDirectionKeepsItsListeners() {
        let before: [AudioDirection: Tracked] = [.input: Tracked(id: 70, channelCount: 2)]
        let after: [AudioDirection: Tracked] = [.input: Tracked(id: 70, channelCount: 1)]
        #expect(CoreAudioDeviceControl.listenerDiff(previous: before, current: after) == Diff(remove: [:], add: [:]))
    }

    @Test func idMovingToAnotherDirectionIsReRegisteredUnderTheNewScope() {
        let before: [AudioDirection: Tracked] = [.input: Tracked(id: 70, channelCount: 2)]
        let after: [AudioDirection: Tracked] = [.output: Tracked(id: 70, channelCount: 2)]
        #expect(CoreAudioDeviceControl.listenerDiff(previous: before, current: after) == Diff(remove: before, add: after))
    }
}
