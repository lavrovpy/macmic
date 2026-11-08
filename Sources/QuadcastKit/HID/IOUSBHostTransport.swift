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

/// One matched USB function's response to a header-packet control
/// transfer, as reported by `IOUSBHostTransport.probe()`.
public struct USBProbeResult: Equatable {
    public let vendorID: Int
    public let productID: Int
    /// The device's own USB product string, if it reports one.
    public let productName: String?
    public let ioReturn: IOReturn

    public init(vendorID: Int, productID: Int, productName: String?, ioReturn: IOReturn) {
        self.vendorID = vendorID
        self.productID = productID
        self.productName = productName
        self.ioReturn = ioReturn
    }

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
///
/// It matches every `QuadcastCatalog` function with
/// `isMatchedByLightingTransport`, and sends all of them the same control
/// request: upstream uses identical code for every model in the catalog.
/// `QuadcastFunctionSet` decides which function takes the transfer and when
/// removal is reported.
public final class IOUSBHostTransport: HIDTransport {
    public var onDeviceConnected: ((_ deviceName: String) -> Void)?
    public var onDeviceNameChanged: ((_ deviceName: String) -> Void)?
    public var onDeviceRemoved: (() -> Void)?

    private static let bmRequestType: UInt8 = 0x21
    private static let bRequest: UInt8 = 0x09
    private static let wValue: UInt16 = 0x0300
    private static let wIndex: UInt16 = 0x0000
    private static let completionTimeout: TimeInterval = 1.0

    private let queue = DispatchQueue(label: "dev.alavreniuk.macmic.usbhost-transport")
    private var notificationPort: IONotificationPortRef?
    private var matchIterators: [io_iterator_t] = []
    private var removalIterators: [io_iterator_t] = []
    private var functions = QuadcastFunctionSet<IOUSBHostDevice>()

    public init() {}

    public func open() throws {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            throw HIDTransportError.openFailed(kIOReturnNoMemory)
        }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, queue)

        let context = Unmanaged.passUnretained(self).toOpaque()
        // IOKit matching takes a single idVendor per dictionary, so this
        // registers one notification of each kind per vendor.
        let vendors = QuadcastCatalog.lightingTransportProductIDs.sorted { $0.key < $1.key }

        for (vendorID, productIDs) in vendors {
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(
                port, kIOFirstMatchNotification,
                Self.makeMatchingDictionary(vendorID: vendorID, productIDs: productIDs),
                { context, iterator in
                    guard let context else { return }
                    Unmanaged<IOUSBHostTransport>.fromOpaque(context).takeUnretainedValue().handleMatched(iterator)
                }, context, &iterator
            )
            guard result == kIOReturnSuccess else {
                throw HIDTransportError.openFailed(result)
            }
            matchIterators.append(iterator)
            handleMatched(iterator)
        }

        for (vendorID, productIDs) in vendors {
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(
                port, kIOTerminatedNotification,
                Self.makeMatchingDictionary(vendorID: vendorID, productIDs: productIDs),
                { context, iterator in
                    guard let context else { return }
                    Unmanaged<IOUSBHostTransport>.fromOpaque(context).takeUnretainedValue().handleRemoved(iterator)
                }, context, &iterator
            )
            guard result == kIOReturnSuccess else {
                throw HIDTransportError.openFailed(result)
            }
            removalIterators.append(iterator)
            handleRemoved(iterator)
        }
    }

    /// Tears down the iterators, the port and the devices in one
    /// `queue.sync`. `handleMatched` seizes a device before its insert hops
    /// onto `queue`, so an insert that lands after this finds the port gone
    /// and destroys its device instead of adding it.
    public func close() {
        queue.sync {
            for iterator in matchIterators + removalIterators {
                IOObjectRelease(iterator)
            }
            matchIterators = []
            removalIterators = []
            if let notificationPort {
                IONotificationPortDestroy(notificationPort)
            }
            notificationPort = nil
            for device in functions.removeAll() {
                device.destroy()
            }
        }
    }

    /// Runs on `queue` for its whole duration (not just the candidate
    /// snapshot) so a concurrent hotplug removal can't `destroy()` the
    /// `IOUSBHostDevice` this is actively sending a control transfer to;
    /// `handleMatched`/`handleRemoved` mutate `functions` via `queue.async`,
    /// so this serializes against them instead of racing.
    public func sendFeatureReport(_ bytes: [UInt8]) throws {
        try queue.sync {
            let candidates = functions.orderedCandidates
            guard !candidates.isEmpty else {
                throw HIDTransportError.deviceNotFound
            }

            var lastResult: IOReturn = kIOReturnNotFound
            for candidate in candidates {
                let result = Self.sendControlTransfer(bytes, to: candidate.handle)
                if result == kIOReturnSuccess {
                    functions.markActive(candidate.entryID)
                    return
                }
                lastResult = result
            }
            throw HIDTransportError.sendFailed(lastResult)
        }
    }

    /// Sends a header-packet control transfer to every currently matched
    /// USB function and reports the raw `IOReturn` for each,
    /// regardless of success. This is the hardware bring-up diagnostic
    /// (`macmic-cli probe`); unlike `sendFeatureReport`, it does not stop at
    /// the first success and is not exercised by unit tests.
    ///
    /// Runs on `queue` for its whole duration, same as `sendFeatureReport`,
    /// so a concurrent hotplug removal or `close()` can't `destroy()` a
    /// device this is still sending to.
    public func probe() throws -> [USBProbeResult] {
        try queue.sync {
            let candidates = functions.orderedCandidates
            guard !candidates.isEmpty else {
                throw HIDTransportError.deviceNotFound
            }
            return candidates.map { candidate in
                let result = Self.sendControlTransfer(QuadcastPacket.headerPacket(), to: candidate.handle)
                return USBProbeResult(
                    vendorID: candidate.vendorID, productID: candidate.productID,
                    productName: candidate.productName, ioReturn: result
                )
            }
        }
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

    /// A fresh dictionary per call: `IOServiceAddMatchingNotification`
    /// consumes the one it is given.
    private static func makeMatchingDictionary(vendorID: Int, productIDs: [Int]) -> CFDictionary {
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
            let vendorID = Int(device.deviceDescriptor?.pointee.idVendor ?? 0xFFFF)
            let productID = Int(device.deviceDescriptor?.pointee.idProduct ?? 0xFFFF)
            let productName = IORegistryEntryCreateCFProperty(
                service, kUSBHostDevicePropertyProductString as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String
            queue.async { [weak self] in
                guard let self, self.notificationPort != nil else {
                    device.destroy()
                    return
                }
                self.functions.insert(
                    device, entryID: entryID, vendorID: vendorID, productID: productID, productName: productName
                )?.destroy()
                let name = self.functions.displayName ?? QuadcastCatalog.genericName
                DispatchQueue.main.async { self.onDeviceConnected?(name) }
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
                let previousName = self.functions.displayName
                guard let removal = self.functions.remove(entryID: entryID) else { return }
                removal.handle.destroy()
                if removal.isEmpty {
                    DispatchQueue.main.async { self.onDeviceRemoved?() }
                } else if let name = self.functions.displayName, name != previousName {
                    DispatchQueue.main.async { self.onDeviceNameChanged?(name) }
                }
            }
        }
    }
}
