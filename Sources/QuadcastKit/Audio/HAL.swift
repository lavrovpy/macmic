// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import CoreAudio
import Dispatch

/// Constants shared by `SystemHAL`, `CoreAudioDeviceControl` and the
/// microphone-test adapter.
enum HAL {
    static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
}

/// A HAL call refused with `status`.
struct HALStatusError: Error, Equatable {
    let status: OSStatus
}

/// One property-listener registration. `AudioObjectRemovePropertyListenerBlock`
/// only removes the identical block that was added, so the registration
/// carries it.
final class HALListener {
    let object: AudioObjectID
    let address: AudioObjectPropertyAddress
    let queue: DispatchQueue
    let block: AudioObjectPropertyListenerBlock

    init(
        object: AudioObjectID,
        address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        block: @escaping AudioObjectPropertyListenerBlock
    ) {
        self.object = object
        self.address = address
        self.queue = queue
        self.block = block
    }
}

/// The HAL calls `CoreAudioDeviceControl` makes. Synchronous on the caller's
/// queue. A failed read returns `nil` / `0` / `[]` — for a just-unplugged
/// device that is the normal outcome, not an error.
protocol HALPort: AnyObject {
    func deviceIDs() -> [AudioObjectID]
    /// A global-scope `CFString` property (name, UID, model UID).
    func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String?
    /// Total channels across every stream of `device` in `scope`, from
    /// `kAudioDevicePropertyStreamConfiguration`.
    func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int
    func uint32(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32?
    func float32(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Float32?
    func write(_ value: UInt32, _ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> OSStatus
    func write(_ value: Float32, _ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> OSStatus
    /// `handler` runs asynchronously on `queue` after each change. Throws
    /// `HALStatusError` when refused.
    func addListener(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        _ handler: @escaping () -> Void
    ) throws -> HALListener
    /// Harmless for an object the HAL already destroyed.
    func removeListener(_ listener: HALListener)
}

/// `HALPort` over the real Core Audio HAL. Stateless, so any queue may call it.
final class SystemHAL: HALPort {
    init() {}

    func deviceIDs() -> [AudioObjectID] {
        var address = HAL.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(HAL.systemObject, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(HAL.systemObject, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = HAL.address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value?.takeRetainedValue() as String?
    }

    func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = HAL.address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    func uint32(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var address = address
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    func float32(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Float32? {
        var address = address
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value
    }

    func write(_ value: UInt32, _ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> OSStatus {
        var address = address
        var value = value
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    func write(_ value: Float32, _ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> OSStatus {
        var address = address
        var value = value
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    func addListener(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        _ handler: @escaping () -> Void
    ) throws -> HALListener {
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        var address = address
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        guard status == noErr else {
            throw HALStatusError(status: status)
        }
        return HALListener(object: object, address: address, queue: queue, block: block)
    }

    func removeListener(_ listener: HALListener) {
        var address = listener.address
        AudioObjectRemovePropertyListenerBlock(listener.object, &address, listener.queue, listener.block)
    }

    // MARK: - Microphone-test adapter only

    func defaultOutputDevice() -> AudioObjectID? {
        var address = HAL.address(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(HAL.systemObject, &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    /// `DeviceIsAlive` and at least one input channel — the pre-bind
    /// liveness check. Whether the QuadCast is present is the control's
    /// question, not this one.
    func isUsableInput(_ device: AudioObjectID) -> Bool {
        let isAlive = uint32(device, HAL.address(kAudioDevicePropertyDeviceIsAlive)).map { $0 != 0 } ?? false
        return isAlive && channelCount(device, scope: kAudioObjectPropertyScopeInput) > 0
    }

    func nominalSampleRate(_ device: AudioObjectID) -> Double {
        var address = HAL.address(kAudioDevicePropertyNominalSampleRate)
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    func setNominalSampleRate(_ device: AudioObjectID, _ rate: Double) -> Bool {
        var address = HAL.address(kAudioDevicePropertyNominalSampleRate)
        var rate = rate
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &rate) == noErr
    }

    func availableSampleRates(_ device: AudioObjectID) -> [Double] {
        var address = HAL.address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ranges) == noErr else { return [] }
        return ranges.map(\.mMinimum)
    }
}
