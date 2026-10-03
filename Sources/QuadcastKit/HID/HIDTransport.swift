// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import IOKit

/// Abstraction over the HID feature-report channel used to drive the
/// QuadCast S display loop, so the streaming/mode logic in QuadcastKit can
/// be tested without real hardware. `IOUSBHostTransport` is the production
/// adapter (its doc says why it bypasses `IOHIDManager`); `MockHIDTransport`
/// (test target) is used in unit tests.
///
/// Both callbacks are delivered on the main thread.
public protocol HIDTransport: AnyObject {
    /// Invoked once per matched QuadCast USB function — twice for one mic,
    /// including for a mic that is already plugged in when `open()` runs.
    var onDeviceConnected: (() -> Void)? { get set }
    /// Invoked once every matched QuadCast USB function is gone, not when
    /// the first of them terminates.
    var onDeviceRemoved: (() -> Void)? { get set }

    /// Starts watching for matching USB functions. Success does not mean a
    /// device is present; presence arrives through `onDeviceConnected`.
    func open() throws
    /// Stops watching and releases every matched function without firing
    /// `onDeviceRemoved`.
    func close()
    /// Sends one 64-byte feature report (report ID 0), trying each matched
    /// function until one accepts it. Each attempt is a synchronous USB
    /// control transfer with a 1 s timeout, so this can block for about 1 s
    /// per function: never call it on the main thread.
    func sendFeatureReport(_ bytes: [UInt8]) throws
}

/// Errors surfaced by `HIDTransport` implementations.
public enum HIDTransportError: Error, Equatable {
    /// No QuadCast USB function is currently matched.
    case deviceNotFound
    /// Registering the matching notifications failed with this `IOReturn`.
    case openFailed(IOReturn)
    /// Every matched function rejected the feature report; this is the last
    /// `IOReturn` code seen.
    case sendFailed(IOReturn)
}
