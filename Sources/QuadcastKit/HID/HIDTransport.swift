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
/// be tested without real hardware. `IOUSBHostTransport` is the adapter that
/// actually reaches the device on this hardware; `IOKitHIDTransport` is kept
/// for reference only (its `IOHIDManager` path cannot reach the vendor-page
/// report handler — see `CLAUDE.md`'s Hardware notes). `MockHIDTransport`
/// (test target) is used in unit tests.
public protocol HIDTransport: AnyObject {
    /// Invoked when a matching QuadCast HID service becomes available.
    var onDeviceConnected: (() -> Void)? { get set }
    /// Invoked when the previously active QuadCast HID service disappears.
    var onDeviceRemoved: (() -> Void)? { get set }

    /// Starts watching for matching HID services and opens the manager.
    func open() throws
    /// Stops watching and releases any open HID services.
    func close()
    /// Sends one 64-byte feature report (report ID 0) to the active device.
    func sendFeatureReport(_ bytes: [UInt8]) throws
}

/// Errors surfaced by `HIDTransport` implementations.
public enum HIDTransportError: Error, Equatable {
    /// No matching QuadCast HID service is currently available.
    case deviceNotFound
    /// Opening the HID manager failed with this `IOReturn` code.
    case openFailed(IOReturn)
    /// Every candidate HID service rejected the feature report; this is the
    /// last `IOReturn` code seen.
    case sendFailed(IOReturn)
}
