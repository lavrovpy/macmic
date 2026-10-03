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

enum ControlKind: CaseIterable, Sendable {
    case coreAudio, mock
}

/// Drives the device side of one `AudioDeviceControl` implementation, so the
/// same contract runs against `CoreAudioDeviceControl` + `FakeHAL` and
/// against `MockAudioDeviceControl`, which every app test relies on. Starts
/// with nothing plugged in and the control not opened.
protocol ControlHarness {
    var control: AudioDeviceControl { get }
    func plugBoth()
    func unplugAll()
    /// The input re-enumerates under `newInputID` with identical levels.
    func replug(newInputID: AudioObjectID)
    /// Returns once every delivery caused so far has landed.
    func settle()
}

func makeHarness(_ kind: ControlKind) -> ControlHarness {
    switch kind {
    case .coreAudio: return CoreAudioHarness()
    case .mock: return MockHarness()
    }
}

private final class CoreAudioHarness: ControlHarness {
    private let fixture = CoreAudioFixture(devices: [])

    var control: AudioDeviceControl {
        fixture.control
    }

    func plugBoth() {
        fixture.hal.plug(.quadcastInput(id: CoreAudioFixture.inputID))
        fixture.hal.plug(.quadcastOutput(id: CoreAudioFixture.outputID))
    }

    func unplugAll() {
        fixture.hal.deviceIDs().forEach(fixture.hal.unplug)
    }

    func replug(newInputID: AudioObjectID) {
        guard let current = fixture.control.snapshot.deviceIDs[.input] else { return }
        fixture.hal.reenumerate([current: newInputID])
    }

    func settle() {
        fixture.settle()
    }
}

private final class MockHarness: ControlHarness {
    private let mock = MockAudioDeviceControl()

    init() {
        mock.stateAtOpen = nil
    }

    var control: AudioDeviceControl {
        mock
    }

    func plugBoth() {
        mock.stateAtOpen = .sample
        mock.simulateDeviceAppeared(.sample)
    }

    func unplugAll() {
        mock.stateAtOpen = nil
        mock.simulateDeviceRemoved()
    }

    func replug(newInputID: AudioObjectID) {
        mock.simulateReenumeration(inputID: newInputID, outputID: mock.outputID)
    }

    func settle() {}
}

/// The `AudioDeviceControl` contract every caller relies on, held by both
/// the production control and the test mock.
@Suite struct AudioDeviceControlContractTests {
    @Test(arguments: ControlKind.allCases)
    func openDeliversToEveryObserver(_ kind: ControlKind) throws {
        let harness = makeHarness(kind)
        harness.plugBoth()
        let first = DeliveryRecorder(observing: harness.control)
        let second = DeliveryRecorder(observing: harness.control)

        try harness.control.open()
        harness.settle()

        for recorder in [first, second] {
            #expect(recorder.count == 1)
            #expect(recorder.last == .sample)
            #expect(recorder.last?.deviceIDs[.input] != nil)
            #expect(recorder.last?.deviceIDs[.output] != nil)
        }
    }

    @Test(arguments: ControlKind.allCases)
    func openWithNothingPresentDeliversUnavailable(_ kind: ControlKind) throws {
        let harness = makeHarness(kind)
        let recorder = DeliveryRecorder(observing: harness.control)

        try harness.control.open()
        harness.settle()

        #expect(recorder.count == 1)
        #expect(recorder.last?.isIdentical(to: .unavailable) == true)
    }

    @Test(arguments: ControlKind.allCases)
    func writeBeforeOpenThrowsDeviceNotFound(_ kind: ControlKind) throws {
        let harness = makeHarness(kind)
        harness.plugBoth()
        let recorder = DeliveryRecorder(observing: harness.control)

        #expect(throws: AudioDeviceControlError.deviceNotFound(.input)) {
            try harness.control.setVolume(0.5, for: .input)
        }
        #expect(throws: AudioDeviceControlError.deviceNotFound(.output)) {
            try harness.control.setMuted(true, for: .output)
        }
        harness.settle()

        #expect(recorder.count == 0)
    }

    @Test(arguments: ControlKind.allCases)
    func writeIsEchoedToObservers(_ kind: ControlKind) throws {
        let harness = makeHarness(kind)
        harness.plugBoth()
        let recorder = DeliveryRecorder(observing: harness.control)
        try harness.control.open()
        harness.settle()

        try harness.control.setVolume(0.5, for: .input)
        harness.settle()

        #expect(recorder.count == 2)
        #expect(recorder.last?.input?.volume == 0.5)
        #expect(harness.control.snapshot.input?.volume == 0.5)
    }

    @Test(arguments: ControlKind.allCases)
    func writeToAbsentDirectionThrowsDeviceNotFound(_ kind: ControlKind) throws {
        let harness = makeHarness(kind)
        try harness.control.open()
        harness.settle()

        #expect(throws: AudioDeviceControlError.deviceNotFound(.input)) {
            try harness.control.setVolume(0.5, for: .input)
        }
        #expect(throws: AudioDeviceControlError.deviceNotFound(.output)) {
            try harness.control.setMuted(true, for: .output)
        }
    }

    @Test(arguments: ControlKind.allCases)
    func removalDeliversAbsentDirectionWithoutID(_ kind: ControlKind) throws {
        let harness = makeHarness(kind)
        harness.plugBoth()
        let recorder = DeliveryRecorder(observing: harness.control)
        try harness.control.open()
        harness.settle()

        harness.unplugAll()
        harness.settle()

        #expect(recorder.count == 2)
        #expect(recorder.last?.isIdentical(to: .unavailable) == true)
        #expect(harness.control.snapshot.isIdentical(to: .unavailable))
    }

    @Test(arguments: ControlKind.allCases)
    func reEnumerationWithIdenticalLevelsDeliversTheNewID(_ kind: ControlKind) throws {
        let harness = makeHarness(kind)
        harness.plugBoth()
        let recorder = DeliveryRecorder(observing: harness.control)
        try harness.control.open()
        harness.settle()

        harness.replug(newInputID: 4242)
        harness.settle()

        #expect(recorder.count == 2)
        #expect(recorder.last == .sample)
        #expect(recorder.last?.deviceIDs[.input] == 4242)
        #expect(harness.control.snapshot.deviceIDs[.input] == 4242)
    }

    @Test(arguments: ControlKind.allCases)
    func cancelledObservationReceivesNothing(_ kind: ControlKind) throws {
        let harness = makeHarness(kind)
        harness.plugBoth()
        let cancelled = DeliveryRecorder(observing: harness.control)
        let kept = DeliveryRecorder(observing: harness.control)
        cancelled.cancelObservation()

        try harness.control.open()
        harness.settle()
        try harness.control.setMuted(true, for: .input)
        harness.settle()

        #expect(cancelled.count == 0)
        #expect(kept.count == 2)
    }

    @Test(arguments: ControlKind.allCases)
    func nothingIsDeliveredAfterClose(_ kind: ControlKind) throws {
        let harness = makeHarness(kind)
        harness.plugBoth()
        let recorder = DeliveryRecorder(observing: harness.control)
        try harness.control.open()
        harness.settle()

        harness.control.close()
        harness.unplugAll()
        harness.plugBoth()
        harness.settle()

        #expect(recorder.count == 1)
        #expect(harness.control.snapshot.isIdentical(to: .unavailable))
    }
}
