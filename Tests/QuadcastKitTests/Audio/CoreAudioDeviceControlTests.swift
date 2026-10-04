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

/// `CoreAudioDeviceControl` through its interface, over `FakeHAL`: matching,
/// direction assignment, listener bookkeeping across hotplug, writes, and
/// delivery.
@Suite struct CoreAudioDeviceControlTests {
    private static let inputScope = kAudioObjectPropertyScopeInput
    private static let outputScope = kAudioObjectPropertyScopeOutput
    private static let inputID = CoreAudioFixture.inputID
    private static let outputID = CoreAudioFixture.outputID

    /// The listeners an open control should hold for these device ids.
    private static func expectedListeners(input: AudioObjectID?, output: AudioObjectID?) -> Set<FakeHAL.ListenerSummary> {
        var expected: Set<FakeHAL.ListenerSummary> = [FakeHAL.ListenerSummary(
            object: HAL.systemObject, selector: kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal, element: kAudioObjectPropertyElementMain
        )]
        for (id, scope) in [(input, inputScope), (output, outputScope)] {
            guard let id else { continue }
            expected.insert(FakeHAL.ListenerSummary(object: id, selector: kAudioDevicePropertyMute, scope: scope, element: 0))
            expected.insert(FakeHAL.ListenerSummary(object: id, selector: kAudioDevicePropertyVolumeScalar, scope: scope, element: 1))
        }
        return expected
    }

    private static func volumeWrite(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope, element: UInt32, _ value: Float32) -> FakeHAL.Write {
        FakeHAL.Write(object: id, selector: kAudioDevicePropertyVolumeScalar, scope: scope, element: element, value: value)
    }

    private static func openedFixture(devices: [FakeHAL.Device]? = nil) throws -> CoreAudioFixture {
        let fixture = devices.map { CoreAudioFixture(devices: $0) } ?? CoreAudioFixture()
        try fixture.control.open()
        fixture.settle()
        return fixture
    }

    // MARK: Matching and assignment

    @Test func openAssignsBothDirectionsByChannelScope() throws {
        let fixture = try Self.openedFixture(devices: [
            .unrelated(id: 50), .quadcastOutput(id: Self.outputID), .quadcastInput(id: Self.inputID),
        ])

        let snapshot = fixture.control.snapshot
        #expect(snapshot == .sample)
        #expect(snapshot.deviceIDs == [.input: Self.inputID, .output: Self.outputID])
        #expect(fixture.deliveries.count == 1)
        #expect(fixture.deliveries.last?.isIdentical(to: snapshot) == true)
    }

    @Test func aCombinedDeviceServesBothDirectionsWithPerScopeChannelCounts() throws {
        let fixture = try Self.openedFixture(devices: [.combined(id: 90, input: 2, output: 4)])
        #expect(fixture.control.snapshot.deviceIDs == [.input: 90, .output: 90])

        try fixture.control.setVolume(0.5, for: .input)
        try fixture.control.setVolume(0.25, for: .output)

        let expected = (1...2).map { Self.volumeWrite(90, Self.inputScope, element: $0, 0.5) }
            + (1...4).map { Self.volumeWrite(90, Self.outputScope, element: $0, 0.25) }
        #expect(fixture.hal.writes == expected)
    }

    @Test func modelUIDMatchesCaseInsensitivelyAndNameIsOnlyAFallback() throws {
        var otherModel = FakeHAL.Device.combined(id: 60, input: 2, output: 2)
        otherModel.modelUID = "Foo:0951:1234"
        var otherName = FakeHAL.Device.combined(id: 61, input: 2, output: 2)
        otherName.modelUID = nil
        otherName.name = "MacBook Pro Microphone"
        var uppercased = FakeHAL.Device.quadcastInput(id: Self.inputID)
        uppercased.modelUID = "HYPERX QUADCAST S:0951:171D"
        var nameOnly = FakeHAL.Device.quadcastOutput(id: Self.outputID)
        nameOnly.modelUID = nil

        let fixture = try Self.openedFixture(devices: [otherModel, otherName, uppercased, nameOnly])

        #expect(fixture.control.snapshot.deviceIDs == [.input: Self.inputID, .output: Self.outputID])
    }

    @Test func firstEnumeratedWinsADuplicateDirection() throws {
        let fixture = try Self.openedFixture(devices: [
            .quadcastInput(id: Self.inputID), .quadcastInput(id: 80), .quadcastOutput(id: Self.outputID),
        ])
        #expect(fixture.control.snapshot.deviceIDs == [.input: Self.inputID, .output: Self.outputID])

        fixture.hal.unplug(Self.inputID)
        fixture.settle()

        #expect(fixture.control.snapshot.deviceIDs == [.input: 80, .output: Self.outputID])
    }

    // MARK: Listeners across rescans

    @Test func unrelatedDeviceChangesDeliverNothingAndKeepListeners() throws {
        let fixture = try Self.openedFixture()
        let added = fixture.hal.addedListenerCount
        let removed = fixture.hal.removedListenerCount

        fixture.hal.plug(.unrelated(id: 50))
        fixture.settle()
        fixture.hal.changeExternally(50, scope: Self.outputScope, volume: 0.1)
        fixture.settle()
        fixture.hal.unplug(50)
        fixture.settle()

        #expect(fixture.deliveries.count == 1)
        #expect(fixture.hal.addedListenerCount == added)
        #expect(fixture.hal.removedListenerCount == removed)
        #expect(fixture.hal.liveListeners == Self.expectedListeners(input: Self.inputID, output: Self.outputID))
    }

    @Test func idServingAnotherDirectionAfterRescanIsReRegisteredUnderThatScope() throws {
        let fixture = try Self.openedFixture()

        fixture.hal.reenumerate([Self.inputID: Self.outputID, Self.outputID: Self.inputID])
        fixture.settle()

        #expect(fixture.hal.liveListeners == Self.expectedListeners(input: Self.outputID, output: Self.inputID))
        #expect(fixture.control.snapshot.deviceIDs == [.input: Self.outputID, .output: Self.inputID])

        fixture.hal.changeExternally(Self.inputID, scope: Self.outputScope, volume: 0.3)
        fixture.settle()

        #expect(fixture.deliveries.last?.output?.volume == 0.3)
    }

    @Test func channelCountChangeUnderTheSameIDKeepsListenersAndWritesTheNewCount() throws {
        let fixture = try Self.openedFixture()
        let added = fixture.hal.addedListenerCount
        let removed = fixture.hal.removedListenerCount

        fixture.hal.replace(.combined(id: Self.inputID, input: 1, output: 0))
        fixture.settle()

        #expect(fixture.hal.addedListenerCount == added)
        #expect(fixture.hal.removedListenerCount == removed)
        #expect(fixture.deliveries.count == 1)

        try fixture.control.setVolume(0.5, for: .input)

        #expect(fixture.hal.writes == [Self.volumeWrite(Self.inputID, Self.inputScope, element: 1, 0.5)])
    }

    @Test func registersMuteOnElement0AndVolumeOnElement1PerScope() throws {
        let fixture = try Self.openedFixture()

        #expect(fixture.hal.liveListeners == Self.expectedListeners(input: Self.inputID, output: Self.outputID))
        #expect(fixture.hal.addedListenerCount == 5)
    }

    @Test func hotplugWithNewIDsMovesTheListeners() throws {
        let fixture = try Self.openedFixture()

        fixture.hal.unplug(Self.inputID)
        fixture.hal.unplug(Self.outputID)
        fixture.hal.plug(.quadcastInput(id: 102))
        fixture.hal.plug(.quadcastOutput(id: 106))
        fixture.settle()

        #expect(fixture.hal.liveListeners == Self.expectedListeners(input: 102, output: 106))
        #expect(fixture.hal.removedListenerCount == 4)
        #expect(fixture.deliveries.last?.deviceIDs == [.input: 102, .output: 106])

        fixture.hal.changeExternally(102, scope: Self.inputScope, muted: true)
        fixture.settle()

        #expect(fixture.deliveries.last?.input?.isMuted == true)
    }

    @Test func reEnumerationWithIdenticalLevelsIsDelivered() throws {
        let fixture = try Self.openedFixture()

        fixture.hal.reenumerate([Self.inputID: 110, Self.outputID: 102])
        fixture.settle()

        let deliveries = fixture.deliveries.snapshots
        #expect(deliveries.count == 2)
        #expect(deliveries.last == deliveries.first)
        #expect(deliveries.last?.isIdentical(to: deliveries[0]) == false)
        #expect(deliveries.last?.deviceIDs == [.input: 110, .output: 102])
    }

    @Test func partialRemovalTouchesOnlyTheMissingDirection() throws {
        let fixture = try Self.openedFixture()
        let added = fixture.hal.addedListenerCount

        fixture.hal.unplug(Self.outputID)
        fixture.settle()

        #expect(fixture.hal.liveListeners == Self.expectedListeners(input: Self.inputID, output: nil))
        #expect(fixture.hal.addedListenerCount == added)
        #expect(fixture.hal.removedListenerCount == 2)
        #expect(fixture.deliveries.last == AudioDeviceSnapshot(input: AudioDeviceSnapshot.sample.input, output: nil))
        #expect(fixture.deliveries.last?.deviceIDs == [.input: Self.inputID])
    }

    // MARK: Changes and writes

    @Test func externalChangeIsDelivered() throws {
        let fixture = try Self.openedFixture()

        fixture.hal.changeExternally(Self.inputID, scope: Self.inputScope, volume: 0.3, muted: true)
        fixture.settle()

        #expect(fixture.deliveries.count == 2)
        #expect(fixture.deliveries.last?.input == AudioLevel(volume: 0.3, isMuted: true, decibels: 2.125))
        #expect(fixture.control.snapshot.input?.volume == 0.3)
    }

    @Test func ownWriteIsDeliveredOnceDespiteTheEcho() throws {
        let fixture = try Self.openedFixture()

        try fixture.control.setVolume(0.5, for: .input)
        fixture.settle()

        #expect(fixture.deliveries.count == 2)
        #expect(fixture.deliveries.last?.input?.volume == 0.5)

        try fixture.control.setMuted(true, for: .output)
        fixture.settle()

        #expect(fixture.deliveries.count == 3)
        #expect(fixture.deliveries.last?.output?.isMuted == true)
    }

    @Test func ownWriteRevertedBeforeItsDeliveryIsStillDelivered() throws {
        let fixture = try Self.openedFixture()

        fixture.callbackQueue.suspend()
        try fixture.control.setMuted(true, for: .input)
        fixture.hal.changeExternally(Self.inputID, scope: Self.inputScope, muted: false)
        _ = fixture.control.snapshot  // both listeners have run; the deliveries wait on the suspended queue
        fixture.callbackQueue.resume()
        fixture.settle()

        #expect(fixture.deliveries.count == 2)
        #expect(fixture.deliveries.last?.input?.isMuted == false)
    }

    @Test func ownVolumeWriteRevertedBeforeItsDeliveryIsStillDelivered() throws {
        let fixture = try Self.openedFixture()

        fixture.callbackQueue.suspend()
        try fixture.control.setVolume(0.5, for: .input)
        fixture.hal.changeExternally(Self.inputID, scope: Self.inputScope, volume: 0.675)
        _ = fixture.control.snapshot  // both listeners have run; the deliveries wait on the suspended queue
        fixture.callbackQueue.resume()
        fixture.settle()

        #expect(fixture.deliveries.count == 2)
        #expect(fixture.deliveries.last?.input?.volume == 0.675)
    }

    @Test func volumeWritesEveryChannelElementNeverElementZero() throws {
        let fixture = try Self.openedFixture()

        try fixture.control.setVolume(0.5, for: .input)
        try fixture.control.setVolume(1.5, for: .output)

        #expect(fixture.hal.writes == [
            Self.volumeWrite(Self.inputID, Self.inputScope, element: 1, 0.5),
            Self.volumeWrite(Self.inputID, Self.inputScope, element: 2, 0.5),
            Self.volumeWrite(Self.outputID, Self.outputScope, element: 1, 1),
            Self.volumeWrite(Self.outputID, Self.outputScope, element: 2, 1),
        ])
    }

    @Test func muteWritesElementZero() throws {
        let fixture = try Self.openedFixture()

        try fixture.control.setMuted(true, for: .output)

        #expect(fixture.hal.writes == [FakeHAL.Write(
            object: Self.outputID, selector: kAudioDevicePropertyMute, scope: Self.outputScope, element: 0, value: 1
        )])
        #expect(fixture.control.snapshot.output?.isMuted == true)
    }

    @Test func partialVolumeWriteFailureThrowsAndStillDeliversTheWrittenChannel() throws {
        // No volume listener, so no echo: the delivery can only come from the
        // control re-reading after the failed write.
        let fixture = CoreAudioFixture()
        fixture.hal.refusedListenerSelectors = [kAudioDevicePropertyVolumeScalar]
        try fixture.control.open()
        fixture.settle()
        fixture.hal.failWrites(to: Self.inputID, element: 2, status: kAudioHardwareIllegalOperationError)

        #expect(throws: AudioDeviceControlError.setFailed(kAudioHardwareIllegalOperationError)) {
            try fixture.control.setVolume(0.4, for: .input)
        }
        fixture.settle()

        #expect(fixture.hal.writes == [Self.volumeWrite(Self.inputID, Self.inputScope, element: 1, 0.4)])
        #expect(fixture.deliveries.last?.input?.volume == 0.4)
    }

    @Test func failedReadMeansAbsent() throws {
        let fixture = try Self.openedFixture()

        fixture.hal.failingReads = [Self.inputID]
        fixture.hal.changeExternally(Self.inputID, scope: Self.inputScope, volume: 0.2)
        fixture.settle()

        #expect(fixture.deliveries.last == AudioDeviceSnapshot(input: nil, output: AudioDeviceSnapshot.sample.output))
        #expect(fixture.deliveries.last?.deviceIDs == [.output: Self.outputID])
    }

    // MARK: Lifecycle

    @Test func openFailureThrowsOpenFailedWithTheHALStatus() throws {
        let fixture = CoreAudioFixture()
        fixture.hal.refusedListenerSelectors = [kAudioHardwarePropertyDevices]

        #expect(throws: AudioDeviceControlError.openFailed(kAudioHardwareUnspecifiedError)) {
            try fixture.control.open()
        }
        fixture.settle()

        #expect(fixture.control.snapshot.isIdentical(to: .unavailable))
        #expect(fixture.deliveries.count == 0)
        #expect(fixture.hal.liveListeners.isEmpty)
    }

    @Test func openTwiceIsANoOp() throws {
        let fixture = try Self.openedFixture()

        try fixture.control.open()
        fixture.settle()

        #expect(fixture.deliveries.count == 1)
        #expect(fixture.hal.addedListenerCount == 5)
    }

    @Test func closeRemovesEveryListener() throws {
        let fixture = try Self.openedFixture()

        fixture.control.close()

        #expect(fixture.hal.liveListeners.isEmpty)
        #expect(fixture.hal.removedListenerCount == fixture.hal.addedListenerCount)
        #expect(fixture.control.snapshot.isIdentical(to: .unavailable))
        #expect(throws: AudioDeviceControlError.deviceNotFound(.input)) {
            try fixture.control.setVolume(0.5, for: .input)
        }
    }

    @Test func nothingIsDeliveredAfterCloseEvenIfAlreadyQueued() throws {
        let fixture = try Self.openedFixture()

        fixture.callbackQueue.suspend()
        fixture.hal.changeExternally(Self.inputID, scope: Self.inputScope, volume: 0.2)
        _ = fixture.control.snapshot  // the listener has run; its delivery waits on the suspended queue
        fixture.control.close()
        fixture.hal.fireRemovedListeners()
        fixture.callbackQueue.resume()
        fixture.settle()

        #expect(fixture.deliveries.count == 1)
        #expect(fixture.hal.liveListeners.isEmpty)
        #expect(fixture.control.snapshot.isIdentical(to: .unavailable))
    }

    @Test func burstsCoalesceToTheLatestValue() throws {
        let fixture = try Self.openedFixture()

        fixture.callbackQueue.suspend()
        for volume: Float32 in [0.1, 0.2, 0.3] {
            fixture.hal.changeExternally(Self.inputID, scope: Self.inputScope, volume: volume)
            _ = fixture.control.snapshot
        }
        fixture.callbackQueue.resume()
        fixture.settle()

        #expect(fixture.deliveries.count == 2)
        #expect(fixture.deliveries.last?.input?.volume == 0.3)
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
