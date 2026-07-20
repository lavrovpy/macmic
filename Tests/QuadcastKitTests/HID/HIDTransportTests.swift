// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Testing
@testable import QuadcastKit

@Suite struct MockHIDTransportTests {
    @Test func recordsReportsInOrder() throws {
        let transport = MockHIDTransport()
        try transport.open()
        try transport.sendFeatureReport([0x01, 0x02])
        try transport.sendFeatureReport([0x03, 0x04])
        #expect(transport.sentReports == [[0x01, 0x02], [0x03, 0x04]])
    }

    @Test func sendFeatureReportThrowsWhenNotOpen() {
        let transport = MockHIDTransport()
        var caught: HIDTransportError?
        do {
            try transport.sendFeatureReport([0x00])
            Issue.record("expected sendFeatureReport to throw before open()")
        } catch let error as HIDTransportError {
            caught = error
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(caught == .deviceNotFound)
    }

    @Test func propagatesScriptedSendErrorAndConsumesItOnce() throws {
        let transport = MockHIDTransport()
        try transport.open()
        transport.nextSendError = .sendFailed(-1)

        var caught: HIDTransportError?
        do {
            try transport.sendFeatureReport([0x00])
            Issue.record("expected sendFeatureReport to throw")
        } catch let error as HIDTransportError {
            caught = error
        }
        #expect(caught == .sendFailed(-1))
        #expect(transport.sentReports.isEmpty)

        try transport.sendFeatureReport([0x01])
        #expect(transport.sentReports == [[0x01]])
    }

    @Test func propagatesScriptedOpenError() {
        let transport = MockHIDTransport()
        transport.nextOpenError = .openFailed(-2)

        var caught: HIDTransportError?
        do {
            try transport.open()
            Issue.record("expected open() to throw")
        } catch let error as HIDTransportError {
            caught = error
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(caught == .openFailed(-2))
        #expect(transport.isOpen == false)
    }

    @Test func firesConnectAndRemovalCallbacksInOrder() {
        let transport = MockHIDTransport()
        var events: [String] = []
        transport.onDeviceConnected = { events.append("connected") }
        transport.onDeviceRemoved = { events.append("removed") }

        transport.simulateConnect()
        transport.simulateRemoval()
        transport.simulateConnect()

        #expect(events == ["connected", "removed", "connected"])
    }

    @Test func closeStopsAcceptingReportsUntilReopened() throws {
        let transport = MockHIDTransport()
        try transport.open()
        transport.close()

        var caught: HIDTransportError?
        do {
            try transport.sendFeatureReport([0x00])
            Issue.record("expected sendFeatureReport to throw after close()")
        } catch let error as HIDTransportError {
            caught = error
        }
        #expect(caught == .deviceNotFound)

        try transport.open()
        try transport.sendFeatureReport([0x00])
        #expect(transport.sentReports == [[0x00]])
    }
}
