// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Foundation
import IOKit
import IOKit.hid

/// One matched QuadCast HID service's response to a header-packet feature
/// report, as reported by `IOKitHIDTransport.probe()`.
public struct ProbeResult: Equatable {
    public let productID: Int
    public let usagePage: Int
    public let ioReturn: IOReturn

    public var succeeded: Bool { ioReturn == kIOReturnSuccess }
}

/// `HIDTransport` backed by `IOHIDManager`.
///
/// The QuadCast S enumerates as VID `0x0951` with two simultaneous USB
/// functions, PID `0x171f` and PID `0x171d`; both are matched. Per the
/// "Report submission risk" note in the plan, the HID service that actually
/// accepts a report ID 0 feature report is not known ahead of time, so
/// `sendFeatureReport` tries the last-known-good service first, then the
/// `0x171f` service, then any other matched service, remembering whichever
/// one succeeds.
public final class IOKitHIDTransport: HIDTransport {
    public var onDeviceConnected: (() -> Void)?
    public var onDeviceRemoved: (() -> Void)?

    static let vendorID = 0x0951
    static let preferredProductID = 0x171f
    static let productIDs = [0x171f, 0x171d]

    private let manager: IOHIDManager
    private let queue = DispatchQueue(label: "dev.alavreniuk.macmic.hid-transport")
    private var matchedDevices: [IOHIDDevice] = []
    private var activeDevice: IOHIDDevice?

    public init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matchers: [[String: Any]] = Self.productIDs.map {
            [kIOHIDVendorIDKey: Self.vendorID, kIOHIDProductIDKey: $0]
        }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matchers as CFArray)
        IOHIDManagerSetDispatchQueue(manager, queue)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<IOKitHIDTransport>.fromOpaque(context).takeUnretainedValue().handleDeviceMatched(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<IOKitHIDTransport>.fromOpaque(context).takeUnretainedValue().handleDeviceRemoved(device)
        }, context)
    }

    public func open() throws {
        IOHIDManagerActivate(manager)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            throw HIDTransportError.openFailed(result)
        }
    }

    public func close() {
        queue.sync {
            matchedDevices.removeAll()
            activeDevice = nil
        }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerCancel(manager)
    }

    public func sendFeatureReport(_ bytes: [UInt8]) throws {
        let candidates = queue.sync { orderedCandidates() }
        guard !candidates.isEmpty else {
            throw HIDTransportError.deviceNotFound
        }

        var lastResult: IOReturn = kIOReturnNotFound
        for device in candidates {
            var reportBytes = bytes
            let result = reportBytes.withUnsafeMutableBytes { buffer -> IOReturn in
                guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else {
                    return kIOReturnError
                }
                return IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(0), base, buffer.count)
            }
            if result == kIOReturnSuccess {
                queue.sync { activeDevice = device }
                return
            }
            lastResult = result
        }
        throw HIDTransportError.sendFailed(lastResult)
    }

    /// Try the last-known-good device first (sticky selection), otherwise
    /// prefer the `0x171f` service before falling back to any other match.
    private func orderedCandidates() -> [IOHIDDevice] {
        if let activeDevice, matchedDevices.contains(activeDevice) {
            return [activeDevice] + matchedDevices.filter { $0 != activeDevice }
        }
        return matchedDevices.sorted { lhs, rhs in
            productID(of: lhs) == Self.preferredProductID && productID(of: rhs) != Self.preferredProductID
        }
    }

    private func productID(of device: IOHIDDevice) -> Int {
        (IOHIDDeviceGetProperty(device, kIOHIDProductIDKey as CFString) as? Int) ?? -1
    }

    private func usagePage(of device: IOHIDDevice) -> Int {
        (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? -1
    }

    /// Sends a header-packet feature report to every currently matched
    /// QuadCast HID service and reports the raw `IOReturn` for each,
    /// regardless of success. This is the hardware bring-up diagnostic
    /// (`macmic-cli probe`); unlike `sendFeatureReport`, it does not stop at
    /// the first success and is not exercised by unit tests.
    public func probe() throws -> [ProbeResult] {
        let devices = queue.sync { matchedDevices }
        guard !devices.isEmpty else {
            throw HIDTransportError.deviceNotFound
        }
        return devices.map { device in
            var packet = QuadcastPacket.headerPacket()
            let result = packet.withUnsafeMutableBytes { buffer -> IOReturn in
                guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else {
                    return kIOReturnError
                }
                return IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, CFIndex(0), base, buffer.count)
            }
            return ProbeResult(productID: productID(of: device), usagePage: usagePage(of: device), ioReturn: result)
        }
    }

    private func handleDeviceMatched(_ device: IOHIDDevice) {
        queue.async { [weak self] in
            guard let self else { return }
            if !self.matchedDevices.contains(device) {
                self.matchedDevices.append(device)
            }
            DispatchQueue.main.async { self.onDeviceConnected?() }
        }
    }

    private func handleDeviceRemoved(_ device: IOHIDDevice) {
        queue.async { [weak self] in
            guard let self else { return }
            self.matchedDevices.removeAll { $0 == device }
            if self.activeDevice == device {
                self.activeDevice = nil
            }
            DispatchQueue.main.async { self.onDeviceRemoved?() }
        }
    }
}
