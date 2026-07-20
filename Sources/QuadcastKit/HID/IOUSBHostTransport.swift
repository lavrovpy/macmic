// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Foundation
import IOKit
import IOUSBHost

/// One matched QuadCast USB device's response to a header-packet control
/// transfer, as reported by `IOUSBHostTransport.probe()`.
public struct USBProbeResult: Equatable {
    public let productID: Int
    public let ioReturn: IOReturn

    public var succeeded: Bool { ioReturn == kIOReturnSuccess }
}

/// `HIDTransport` backed by `IOUSBHostDevice`, sending the display-loop
/// packets as raw USB control transfers instead of going through the HID
/// class driver stack.
///
/// Per the Task 5 hardware finding, `IOHIDManager`/`IOHIDDeviceSetReport`
/// cannot reach the QuadCast S's vendor-page report handler on this system:
/// `IOHIDManager` only ever surfaces the Consumer Control HID service for
/// each matched PID, never the `0xFF0B` vendor-page service the protocol
/// targets. This transport bypasses the HID layer entirely and issues the
/// equivalent of QuadcastRGB's `devio.c` control transfer directly against
/// the USB device: `bmRequestType 0x21` (host-to-device, class, interface),
/// `bRequest 0x09` (SET_REPORT), `wValue 0x0300` (Feature report, report ID
/// 0), `wIndex 0x0000`, a 64-byte payload, 1 s timeout.
public final class IOUSBHostTransport: HIDTransport {
    public var onDeviceConnected: (() -> Void)?
    public var onDeviceRemoved: (() -> Void)?

    static let vendorID = 0x0951
    static let preferredProductID = 0x171f
    static let productIDs = [0x171f, 0x171d]

    private static let bmRequestType: UInt8 = 0x21
    private static let bRequest: UInt8 = 0x09
    private static let wValue: UInt16 = 0x0300
    private static let wIndex: UInt16 = 0x0000
    private static let completionTimeout: TimeInterval = 1.0

    private let queue = DispatchQueue(label: "dev.alavreniuk.macmic.usbhost-transport")
    private var notificationPort: IONotificationPortRef?
    private var matchIterator: io_iterator_t = 0
    private var removalIterator: io_iterator_t = 0
    private var devicesByEntryID: [UInt64: IOUSBHostDevice] = [:]
    private var activeEntryID: UInt64?

    public init() {}

    public func open() throws {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw HIDTransportError.openFailed(kIOReturnNoMemory)
        }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, queue)

        let context = Unmanaged.passUnretained(self).toOpaque()

        let matchResult = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, Self.makeMatchingDictionary(),
            { context, iterator in
                guard let context else { return }
                Unmanaged<IOUSBHostTransport>.fromOpaque(context).takeUnretainedValue().handleMatched(iterator)
            }, context, &matchIterator
        )
        guard matchResult == kIOReturnSuccess else {
            throw HIDTransportError.openFailed(matchResult)
        }
        handleMatched(matchIterator)

        let removalResult = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, Self.makeMatchingDictionary(),
            { context, iterator in
                guard let context else { return }
                Unmanaged<IOUSBHostTransport>.fromOpaque(context).takeUnretainedValue().handleRemoved(iterator)
            }, context, &removalIterator
        )
        guard removalResult == kIOReturnSuccess else {
            throw HIDTransportError.openFailed(removalResult)
        }
        handleRemoved(removalIterator)
    }

    public func close() {
        queue.sync {
            for device in devicesByEntryID.values {
                device.destroy()
            }
            devicesByEntryID.removeAll()
            activeEntryID = nil
        }
        if matchIterator != 0 {
            IOObjectRelease(matchIterator)
            matchIterator = 0
        }
        if removalIterator != 0 {
            IOObjectRelease(removalIterator)
            removalIterator = 0
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
        }
        notificationPort = nil
    }

    public func sendFeatureReport(_ bytes: [UInt8]) throws {
        let candidates = queue.sync { orderedCandidates() }
        guard !candidates.isEmpty else {
            throw HIDTransportError.deviceNotFound
        }

        var lastResult: IOReturn = kIOReturnNotFound
        for (entryID, device) in candidates {
            let result = Self.sendControlTransfer(bytes, to: device)
            if result == kIOReturnSuccess {
                queue.sync { activeEntryID = entryID }
                return
            }
            lastResult = result
        }
        throw HIDTransportError.sendFailed(lastResult)
    }

    /// Sends a header-packet control transfer to every currently matched
    /// QuadCast USB device and reports the raw `IOReturn` for each,
    /// regardless of success. This is the hardware bring-up diagnostic
    /// (`macmic-cli probe`); unlike `sendFeatureReport`, it does not stop at
    /// the first success and is not exercised by unit tests.
    public func probe() throws -> [USBProbeResult] {
        let devices = queue.sync { Array(devicesByEntryID.values) }
        guard !devices.isEmpty else {
            throw HIDTransportError.deviceNotFound
        }
        return devices.map { device in
            let productID = Int(device.deviceDescriptor?.pointee.idProduct ?? 0xFFFF)
            let result = Self.sendControlTransfer(QuadcastPacket.headerPacket(), to: device)
            return USBProbeResult(productID: productID, ioReturn: result)
        }
    }

    /// Try the last-known-good device first (sticky selection), otherwise
    /// prefer the `0x171f` device before falling back to any other match.
    private func orderedCandidates() -> [(UInt64, IOUSBHostDevice)] {
        let entries = Array(devicesByEntryID)
        if let activeEntryID, let device = devicesByEntryID[activeEntryID] {
            return [(activeEntryID, device)] + entries.filter { $0.key != activeEntryID }
        }
        return entries.sorted { lhs, rhs in
            productID(of: lhs.value) == Self.preferredProductID && productID(of: rhs.value) != Self.preferredProductID
        }
    }

    private func productID(of device: IOUSBHostDevice) -> Int {
        Int(device.deviceDescriptor?.pointee.idProduct ?? 0xFFFF)
    }

    /// Builds the SET_REPORT-equivalent control request for a payload of
    /// the given length. Pure and hardware-independent, so it is exercised
    /// directly by unit tests; `sendControlTransfer` is not (it requires a
    /// live `IOUSBHostDevice`).
    static func makeControlRequest(payloadLength: Int) -> IOUSBDeviceRequest {
        IOUSBDeviceRequest(
            bmRequestType: bmRequestType, bRequest: bRequest,
            wValue: wValue, wIndex: wIndex, wLength: UInt16(payloadLength)
        )
    }

    private static func sendControlTransfer(_ bytes: [UInt8], to device: IOUSBHostDevice) -> IOReturn {
        let request = makeControlRequest(payloadLength: bytes.count)
        var payload = bytes
        let data = NSMutableData(bytes: &payload, length: payload.count)
        var bytesTransferred = 0
        do {
            try device.__send(request, data: data, bytesTransferred: &bytesTransferred, completionTimeout: completionTimeout)
            return kIOReturnSuccess
        } catch let error as NSError {
            return IOReturn(error.code)
        } catch {
            return kIOReturnError
        }
    }

    private static func makeMatchingDictionary() -> CFDictionary {
        IOUSBHostDevice.__createMatchingDictionary(
            withVendorID: vendorID as NSNumber, productID: nil, bcdDevice: nil,
            deviceClass: nil, deviceSubclass: nil, deviceProtocol: nil, speed: nil,
            productIDArray: productIDs.map { $0 as NSNumber }
        ).takeRetainedValue()
    }

    private func handleMatched(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            guard let device = try? IOUSBHostDevice(
                __ioService: service, options: [.deviceSeize], queue: nil, interestHandler: nil
            ) else { continue }
            queue.async { [weak self] in
                guard let self else { return }
                self.devicesByEntryID[entryID] = device
                DispatchQueue.main.async { self.onDeviceConnected?() }
            }
        }
    }

    private func handleRemoved(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &entryID)
            queue.async { [weak self] in
                guard let self else { return }
                guard let device = self.devicesByEntryID.removeValue(forKey: entryID) else { return }
                device.destroy()
                if self.activeEntryID == entryID {
                    self.activeEntryID = nil
                }
                DispatchQueue.main.async { self.onDeviceRemoved?() }
            }
        }
    }
}
