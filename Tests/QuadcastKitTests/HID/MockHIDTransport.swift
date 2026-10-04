// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Foundation
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
/// synchronously on the caller. `sentReports` and `sendAttempts` may be read
/// while a real-timer streamer sends from its own queue.
final class MockHIDTransport: HIDTransport {
    var onDeviceConnected: (() -> Void)?
    var onDeviceRemoved: (() -> Void)?

    var sentReports: [[UInt8]] {
        lock.lock()
        defer { lock.unlock() }
        return reports
    }

    /// Every `sendFeatureReport` call, failed ones included.
    var sendAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    private(set) var isOpen = false

    /// Consumed (set back to `nil`) the next time `open()` is called.
    var nextOpenError: HIDTransportError?
    /// Consumed (set back to `nil`) the next time `sendFeatureReport` is called.
    var nextSendError: HIDTransportError?
    /// Thrown by every `sendFeatureReport` until set back to `nil`.
    var persistentSendError: HIDTransportError?
    /// Whether a successful `open()` matches both functions of an
    /// already-plugged-in mic (`0x171f`, then `0x171d`: two
    /// `onDeviceConnected` calls, like the real transport). Set `false` to
    /// model launching with no mic connected.
    var autoConnectOnOpen = true

    private var functions = QuadcastFunctionSet<Int>()
    private let lock = NSLock()
    private var reports: [[UInt8]] = []
    private var attempts = 0

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
        lock.lock()
        attempts += 1
        lock.unlock()
        if let error = nextSendError {
            nextSendError = nil
            throw error
        }
        if let error = persistentSendError {
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
        lock.lock()
        reports.append(bytes)
        lock.unlock()
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
