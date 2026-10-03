// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import CoreAudio
import Foundation
@testable import QuadcastKit

/// In-memory `HALPort`: an ordered device list with per-scope mute, volume
/// and dB properties laid out like the QuadCast's (mute on element 0 only,
/// volume on elements `1...channels` only, dB on element 1), plus listener
/// bookkeeping. Listeners fire asynchronously on their registered queue,
/// never inside the call that caused them. A write applies the value and
/// fires that property's listeners, which models the HAL echoing a write.
/// Every member is lock-protected.
final class FakeHAL: HALPort {
    struct Device {
        var id: AudioObjectID
        var modelUID: String?
        var name: String?
        var inputChannels: Int
        var outputChannels: Int
        /// Per element (`1...n`).
        var volume: [AudioObjectPropertyScope: [UInt32: Float32]]
        /// Element 0.
        var mute: [AudioObjectPropertyScope: UInt32]
        /// Element 1.
        var decibels: [AudioObjectPropertyScope: Float32]

        static let quadcastModelUID = "HyperX QuadCast S:0951:171D"
        static let quadcastName = "HyperX QuadCast S"

        /// 2 in / 0 out at the probed input level (0.675 / +2.125 dB).
        static func quadcastInput(id: AudioObjectID) -> Device {
            combined(id: id, input: 2, output: 0)
        }

        /// 0 in / 2 out at the probed monitoring level (0.812 / -12.0625 dB).
        static func quadcastOutput(id: AudioObjectID) -> Device {
            combined(id: id, input: 0, output: 2)
        }

        /// One QuadCast device with channels in both scopes, each at the
        /// probed level of that direction.
        static func combined(id: AudioObjectID, input: Int, output: Int) -> Device {
            var device = Device(
                id: id, modelUID: quadcastModelUID, name: quadcastName,
                inputChannels: input, outputChannels: output, volume: [:], mute: [:], decibels: [:]
            )
            if input > 0 {
                device.setLevel(kAudioObjectPropertyScopeInput, channels: input, volume: 0.675, decibels: 2.125)
            }
            if output > 0 {
                device.setLevel(kAudioObjectPropertyScopeOutput, channels: output, volume: 0.812, decibels: -12.0625)
            }
            return device
        }

        /// Built-in speakers: an output with volume and mute, not a QuadCast.
        static func unrelated(id: AudioObjectID) -> Device {
            var device = Device(
                id: id, modelUID: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers",
                inputChannels: 0, outputChannels: 2, volume: [:], mute: [:], decibels: [:]
            )
            device.setLevel(kAudioObjectPropertyScopeOutput, channels: 2, volume: 0.5, decibels: -20)
            return device
        }

        private mutating func setLevel(_ scope: AudioObjectPropertyScope, channels: Int, volume: Float32, decibels: Float32) {
            self.volume[scope] = Dictionary(uniqueKeysWithValues: (1...UInt32(channels)).map { ($0, volume) })
            mute[scope] = 0
            self.decibels[scope] = decibels
        }
    }

    struct Write: Equatable {
        let object: AudioObjectID
        let selector: AudioObjectPropertySelector
        let scope: AudioObjectPropertyScope
        let element: UInt32
        let value: Float32
    }

    struct ListenerSummary: Hashable {
        let object: AudioObjectID
        let selector: AudioObjectPropertySelector
        let scope: AudioObjectPropertyScope
        let element: UInt32
    }

    private struct Registration {
        let listener: HALListener
        let handler: () -> Void
    }

    private struct WriteTarget: Hashable {
        let object: AudioObjectID
        let element: UInt32
    }

    private let lock = NSLock()
    private var devices: [Device] = []
    private var live: [Registration] = []
    private var removed: [Registration] = []
    private var failedWrites: [WriteTarget: OSStatus] = [:]
    private var failingReadIDs: Set<AudioObjectID> = []
    private var refusedSelectors: Set<AudioObjectPropertySelector> = []
    private var appliedWrites: [Write] = []
    private var addedCount = 0
    private var removedCount = 0

    /// Every read of these objects fails, as for a device unplugged before
    /// the device-list notification lands.
    var failingReads: Set<AudioObjectID> {
        get { locked { failingReadIDs } }
        set { locked { failingReadIDs = newValue } }
    }

    /// `addListener` for these selectors throws
    /// `HALStatusError(kAudioHardwareUnspecifiedError)`.
    var refusedListenerSelectors: Set<AudioObjectPropertySelector> {
        get { locked { refusedSelectors } }
        set { locked { refusedSelectors = newValue } }
    }

    /// Writes the fake accepted, in order; mute values recorded as `Float32`.
    var writes: [Write] {
        locked { appliedWrites }
    }

    var liveListeners: Set<ListenerSummary> {
        locked {
            Set(live.map {
                let address = $0.listener.address
                return ListenerSummary(
                    object: $0.listener.object, selector: address.mSelector,
                    scope: address.mScope, element: address.mElement
                )
            })
        }
    }

    var addedListenerCount: Int {
        locked { addedCount }
    }

    var removedListenerCount: Int {
        locked { removedCount }
    }

    // MARK: - Driving the fake

    /// Appended, so it enumerates after every device already present.
    func plug(_ device: Device) {
        locked { devices.append(device) }
        fireDeviceListChanged()
    }

    func unplug(_ id: AudioObjectID) {
        locked { devices.removeAll { $0.id == id } }
        fireDeviceListChanged()
    }

    /// Every device gone with one device-list change — unlike `unplug` per
    /// device, no listener can observe a partial removal.
    func unplugAll() {
        locked { devices.removeAll() }
        fireDeviceListChanged()
    }

    /// The same devices under new ids, with one device-list change.
    func reenumerate(_ mapping: [AudioObjectID: AudioObjectID]) {
        locked {
            for index in devices.indices {
                if let newID = mapping[devices[index].id] {
                    devices[index].id = newID
                }
            }
        }
        fireDeviceListChanged()
    }

    /// The device with `device.id` re-enumerates as `device`, in the same
    /// list position, with one device-list change — unlike `unplug` + `plug`,
    /// no listener can observe the device missing in between.
    func replace(_ device: Device) {
        locked {
            if let index = devices.firstIndex(where: { $0.id == device.id }) {
                devices[index] = device
            }
        }
        fireDeviceListChanged()
    }

    /// A change made outside the control (the gain knob, Sound settings):
    /// `volume` goes to every channel of `scope`.
    func changeExternally(_ id: AudioObjectID, scope: AudioObjectPropertyScope, volume: Float32? = nil, muted: Bool? = nil) {
        let changed: [AudioObjectPropertyAddress] = locked {
            guard let index = devices.firstIndex(where: { $0.id == id }) else { return [] }
            var changed: [AudioObjectPropertyAddress] = []
            if let volume, let elements = devices[index].volume[scope]?.keys {
                for element in elements {
                    devices[index].volume[scope]?[element] = volume
                    changed.append(HAL.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: element))
                }
            }
            if let muted {
                devices[index].mute[scope] = muted ? 1 : 0
                changed.append(HAL.address(kAudioDevicePropertyMute, scope: scope))
            }
            return changed
        }
        fire(id, changed)
    }

    /// Every later write to `element` of `id` returns `status` and changes nothing.
    func failWrites(to id: AudioObjectID, element: UInt32, status: OSStatus) {
        locked { failedWrites[WriteTarget(object: id, element: element)] = status }
    }

    /// Calls the handlers of listeners already removed — a block the HAL
    /// had queued when `close()` removed it.
    func fireRemovedListeners() {
        let due = locked { removed }
        for registration in due {
            registration.listener.queue.async(execute: registration.handler)
        }
    }

    // MARK: - HALPort

    func deviceIDs() -> [AudioObjectID] {
        locked { devices.map(\.id) }
    }

    func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        locked {
            guard let device = readableDevice(object) else { return nil }
            switch selector {
            case kAudioDevicePropertyModelUID: return device.modelUID
            case kAudioObjectPropertyName: return device.name
            default: return nil
            }
        }
    }

    func channelCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        locked {
            guard let device = readableDevice(device) else { return 0 }
            switch scope {
            case kAudioObjectPropertyScopeInput: return device.inputChannels
            case kAudioObjectPropertyScopeOutput: return device.outputChannels
            default: return 0
            }
        }
    }

    func uint32(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        locked {
            guard address.mSelector == kAudioDevicePropertyMute,
                  address.mElement == kAudioObjectPropertyElementMain else { return nil }
            return readableDevice(object)?.mute[address.mScope]
        }
    }

    func float32(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Float32? {
        locked {
            guard let device = readableDevice(object) else { return nil }
            switch address.mSelector {
            case kAudioDevicePropertyVolumeScalar:
                return device.volume[address.mScope]?[address.mElement]
            case kAudioDevicePropertyVolumeDecibels:
                return address.mElement == 1 ? device.decibels[address.mScope] : nil
            default:
                return nil
            }
        }
    }

    func write(_ value: UInt32, _ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> OSStatus {
        apply(object, address, recordedAs: Float32(value)) { device in
            guard address.mSelector == kAudioDevicePropertyMute,
                  address.mElement == kAudioObjectPropertyElementMain,
                  device.mute[address.mScope] != nil else { return false }
            device.mute[address.mScope] = value
            return true
        }
    }

    func write(_ value: Float32, _ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> OSStatus {
        apply(object, address, recordedAs: value) { device in
            guard address.mSelector == kAudioDevicePropertyVolumeScalar,
                  device.volume[address.mScope]?[address.mElement] != nil else { return false }
            device.volume[address.mScope]?[address.mElement] = value
            return true
        }
    }

    func addListener(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        queue: DispatchQueue,
        _ handler: @escaping () -> Void
    ) throws -> HALListener {
        try locked {
            guard !refusedSelectors.contains(address.mSelector) else {
                throw HALStatusError(status: kAudioHardwareUnspecifiedError)
            }
            let listener = HALListener(object: object, address: address, queue: queue) { _, _ in handler() }
            live.append(Registration(listener: listener, handler: handler))
            addedCount += 1
            return listener
        }
    }

    func removeListener(_ listener: HALListener) {
        locked {
            guard let index = live.firstIndex(where: { $0.listener === listener }) else { return }
            removed.append(live.remove(at: index))
            removedCount += 1
        }
    }

    // MARK: - Private

    /// Call with the lock held.
    private func readableDevice(_ id: AudioObjectID) -> Device? {
        guard !failingReadIDs.contains(id) else { return nil }
        return devices.first { $0.id == id }
    }

    private func apply(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        recordedAs value: Float32,
        _ change: (inout Device) -> Bool
    ) -> OSStatus {
        let status: OSStatus = locked {
            if let status = failedWrites[WriteTarget(object: object, element: address.mElement)] {
                return status
            }
            guard let index = devices.firstIndex(where: { $0.id == object }) else {
                return kAudioHardwareBadObjectError
            }
            guard change(&devices[index]) else {
                return kAudioHardwareUnknownPropertyError
            }
            appliedWrites.append(Write(
                object: object, selector: address.mSelector, scope: address.mScope,
                element: address.mElement, value: value
            ))
            return noErr
        }
        if status == noErr {
            fire(object, [address])
        }
        return status
    }

    private func fireDeviceListChanged() {
        fire(HAL.systemObject, [HAL.address(kAudioHardwarePropertyDevices)])
    }

    private func fire(_ object: AudioObjectID, _ addresses: [AudioObjectPropertyAddress]) {
        let due: [Registration] = locked {
            live.filter { registration in
                let listened = registration.listener.address
                return registration.listener.object == object && addresses.contains {
                    $0.mSelector == listened.mSelector && $0.mScope == listened.mScope && $0.mElement == listened.mElement
                }
            }
        }
        for registration in due {
            registration.listener.queue.async(execute: registration.handler)
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
