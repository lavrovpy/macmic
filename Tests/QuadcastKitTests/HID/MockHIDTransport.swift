// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

@testable import QuadcastKit

/// In-memory `HIDTransport` used by QuadcastKit's tests: records every sent
/// report in order and lets a test script the next `open`/`sendFeatureReport`
/// call to fail, without touching real hardware.
final class MockHIDTransport: HIDTransport {
    var onDeviceConnected: (() -> Void)?
    var onDeviceRemoved: (() -> Void)?

    private(set) var sentReports: [[UInt8]] = []
    private(set) var isOpen = false

    /// Consumed (set back to `nil`) the next time `open()` is called.
    var nextOpenError: HIDTransportError?
    /// Consumed (set back to `nil`) the next time `sendFeatureReport` is called.
    var nextSendError: HIDTransportError?
    /// Whether a successful `open()` should simulate a device already being
    /// matched (fires `onDeviceConnected`, like the real transport would for
    /// a mic that's already plugged in). Set `false` to model launching with
    /// no mic connected.
    var autoConnectOnOpen = true

    func open() throws {
        if let error = nextOpenError {
            nextOpenError = nil
            throw error
        }
        isOpen = true
        if autoConnectOnOpen {
            onDeviceConnected?()
        }
    }

    func close() {
        isOpen = false
    }

    func sendFeatureReport(_ bytes: [UInt8]) throws {
        if let error = nextSendError {
            nextSendError = nil
            throw error
        }
        guard isOpen else {
            throw HIDTransportError.deviceNotFound
        }
        sentReports.append(bytes)
    }

    /// Simulates a matching QuadCast HID service appearing.
    func simulateConnect() {
        onDeviceConnected?()
    }

    /// Simulates the active QuadCast HID service disappearing.
    func simulateRemoval() {
        onDeviceRemoved?()
    }
}
