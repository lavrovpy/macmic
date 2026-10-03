// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import IOKit
@testable import QuadcastKit

/// In-memory `HIDTransport` used by QuadcastKit's tests: records every sent
/// report in order and lets a test script the next `open`/`sendFeatureReport`
/// call to fail, without touching real hardware. Tracks matched functions in
/// the same `QuadcastFunctionSet` as `IOUSBHostTransport`, so the
/// one-mic-two-functions rules are the production ones: removal is reported
/// once every function is gone, and a send succeeds only while `0x171f` is
/// matched (with `0x171d` alone it fails with `kIOReturnError`, as on
/// hardware). Each product id is its own entry id here; callbacks fire
/// synchronously on the caller.
final class MockHIDTransport: HIDTransport {
    var onDeviceConnected: (() -> Void)?
    var onDeviceRemoved: (() -> Void)?

    private(set) var sentReports: [[UInt8]] = []
    private(set) var isOpen = false

    /// Consumed (set back to `nil`) the next time `open()` is called.
    var nextOpenError: HIDTransportError?
    /// Consumed (set back to `nil`) the next time `sendFeatureReport` is called.
    var nextSendError: HIDTransportError?
    /// Whether a successful `open()` matches both functions of an
    /// already-plugged-in mic (`0x171f`, then `0x171d`: two
    /// `onDeviceConnected` calls, like the real transport). Set `false` to
    /// model launching with no mic connected.
    var autoConnectOnOpen = true

    private var functions = QuadcastFunctionSet<Int>()

    func open() throws {
        if let error = nextOpenError {
            nextOpenError = nil
            throw error
        }
        isOpen = true
        if autoConnectOnOpen {
            simulateConnect(productID: 0x171f)
            simulateConnect(productID: 0x171d)
        }
    }

    func close() {
        isOpen = false
        _ = functions.removeAll()
    }

    func sendFeatureReport(_ bytes: [UInt8]) throws {
        if let error = nextSendError {
            nextSendError = nil
            throw error
        }
        let candidates = functions.orderedCandidates
        guard !candidates.isEmpty else {
            throw HIDTransportError.deviceNotFound
        }
        guard let accepting = candidates.first(where: {
            $0.productID == QuadcastFunctionSet<Int>.preferredProductID
        }) else {
            throw HIDTransportError.sendFailed(kIOReturnError)
        }
        functions.markActive(accepting.entryID)
        sentReports.append(bytes)
    }

    /// Simulates one QuadCast USB function being matched.
    func simulateConnect(productID: Int = 0x171f) {
        functions.insert(productID, entryID: UInt64(productID), productID: productID)
        onDeviceConnected?()
    }

    /// Simulates one USB function terminating; `onDeviceRemoved` fires only
    /// if it was the last one.
    func simulateRemoval(productID: Int) {
        guard let removal = functions.remove(entryID: UInt64(productID)) else { return }
        if removal.isEmpty {
            onDeviceRemoved?()
        }
    }

    /// Simulates the whole mic being unplugged: every function terminates.
    func simulateUnplug() {
        guard !functions.isEmpty else { return }
        _ = functions.removeAll()
        onDeviceRemoved?()
    }
}
