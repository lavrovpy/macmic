// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import CoreAudio
import Dispatch
import Foundation

/// `AudioDeviceControl` backed by the Core Audio HAL: finds the QuadCast S's
/// two audio devices (microphone input, headphone-monitoring output), keeps
/// their mute/volume properties under observation, and writes them.
///
/// Matching uses `kAudioDevicePropertyModelUID`, which carries the USB
/// vendor:product (`...:0951:171D`); the device *name* is only a fallback
/// because it's user-visible text. The audio function is the `0x171d` USB
/// function — the one that rejects lighting control transfers — so audio
/// presence and `HIDTransport` presence are tracked independently.
///
/// Volume lives on elements `1...channelCount` (per channel), not on the
/// main element 0, which this device doesn't expose for volume; mute is on
/// element 0 only. Every write sets all channels to the same value and every
/// read takes channel 1.
public final class CoreAudioDeviceControl: AudioDeviceControl {
    public var onStateChanged: ((AudioDeviceSnapshot) -> Void)?
    public var snapshot: AudioDeviceSnapshot { queue.sync { cached } }

    static let usbVendorID = 0x0951
    static let usbProductID = 0x171d
    static let modelUIDSuffix = ":0951:171d"
    static let fallbackDeviceName = "HyperX QuadCast S"

    /// One HAL device's identity and per-scope channel counts, as read by
    /// `rescanDevices` before `assignDirections` decides whether it's ours.
    struct EnumeratedDevice: Equatable {
        let id: AudioObjectID
        let modelUID: String?
        let name: String?
        let inputChannels: Int
        let outputChannels: Int
    }

    /// The device serving one `AudioDirection`; `channelCount` is that
    /// direction's scope only, since volume is written per channel.
    struct TrackedDevice: Equatable {
        let id: AudioObjectID
        let channelCount: Int
    }

    /// Per-device listeners to drop and to register after a rescan, keyed by
    /// the direction they observe (the mute/volume addresses are scoped).
    struct ListenerDiff: Equatable {
        var remove: [AudioDirection: TrackedDevice]
        var add: [AudioDirection: TrackedDevice]
    }

    /// `AudioObjectRemovePropertyListenerBlock` only removes the identical
    /// block object that was added, so every registration keeps its block.
    /// `direction` is `nil` for the system object's device-list listener.
    private struct ListenerRegistration {
        let objectID: AudioObjectID
        let direction: AudioDirection?
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private let queue = DispatchQueue(label: "dev.alavreniuk.macmic.coreaudio-control")
    private var tracked: [AudioDirection: TrackedDevice] = [:]
    private var registrations: [ListenerRegistration] = []
    private var cached: AudioDeviceSnapshot = .unavailable
    private var isOpen = false

    public init() {}

    /// Registers the device-list listener and scans synchronously, so
    /// `snapshot` is valid when this returns; the initial `onStateChanged`
    /// delivery is still asynchronous (main queue), and happens even when
    /// nothing is present. A second call while open is a no-op.
    public func open() throws {
        try queue.sync {
            guard !isOpen else { return }
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.handleDeviceListChanged()
            }
            var address = HAL.address(kAudioHardwarePropertyDevices)
            let status = AudioObjectAddPropertyListenerBlock(HAL.systemObject, &address, queue, block)
            guard status == noErr else {
                throw AudioDeviceControlError.openFailed(status)
            }
            registrations.append(ListenerRegistration(
                objectID: HAL.systemObject, direction: nil, address: address, block: block
            ))
            isOpen = true
            rescanDevices()
            cached = readSnapshot()
            deliver(cached)
        }
    }

    /// State is cleared under `queue`, but the HAL calls are made outside it
    /// so a listener block that is already queued can't be waited on from
    /// the queue it needs; such a block finds `isOpen == false` and returns.
    public func close() {
        let toRemove: [ListenerRegistration] = queue.sync {
            let registrations = self.registrations
            self.registrations.removeAll()
            tracked.removeAll()
            cached = .unavailable
            isOpen = false
            return registrations
        }
        for registration in toRemove {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(registration.objectID, &address, queue, registration.block)
        }
    }

    public func setVolume(_ scalar: Float, for direction: AudioDirection) throws {
        try queue.sync {
            guard let device = tracked[direction] else {
                throw AudioDeviceControlError.deviceNotFound(direction)
            }
            var value = Float32(min(max(scalar, 0), 1))
            // A failure on a later channel leaves earlier ones written, so the
            // snapshot must be re-read even when this throws.
            defer { refreshSnapshot() }
            for element in 1...UInt32(max(device.channelCount, 1)) {
                var address = Self.volumeScalarAddress(for: direction, element: element)
                let status = AudioObjectSetPropertyData(
                    device.id, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value
                )
                guard status == noErr else {
                    throw AudioDeviceControlError.setFailed(status)
                }
            }
        }
    }

    public func setMuted(_ muted: Bool, for direction: AudioDirection) throws {
        try queue.sync {
            guard let device = tracked[direction] else {
                throw AudioDeviceControlError.deviceNotFound(direction)
            }
            var value: UInt32 = muted ? 1 : 0
            var address = Self.muteAddress(for: direction)
            let status = AudioObjectSetPropertyData(
                device.id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value
            )
            guard status == noErr else {
                throw AudioDeviceControlError.setFailed(status)
            }
            refreshSnapshot()
        }
    }

    public func deviceID(for direction: AudioDirection) -> AudioObjectID? {
        queue.sync { tracked[direction]?.id }
    }

    // MARK: - Pure helpers (unit-tested)

    /// `true` for a ModelUID carrying the QuadCast S's USB vendor:product;
    /// the user-visible name is consulted only when no ModelUID is reported.
    static func isQuadcast(modelUID: String?, name: String?) -> Bool {
        if let modelUID {
            return modelUID.lowercased().hasSuffix(modelUIDSuffix)
        }
        return name == fallbackDeviceName
    }

    /// Which directions a device serves, from its per-scope channel counts.
    static func directions(inputChannels: Int, outputChannels: Int) -> [AudioDirection] {
        var result: [AudioDirection] = []
        if inputChannels > 0 { result.append(.input) }
        if outputChannels > 0 { result.append(.output) }
        return result
    }

    /// Picks the device for each direction from an enumeration pass: only
    /// QuadCast devices (`isQuadcast`) are considered, a device serves every
    /// direction it has channels for, and when two devices could serve the
    /// same direction the first enumerated wins (the HAL lists devices in a
    /// stable order, so this stays pinned across rescans).
    static func assignDirections(_ devices: [EnumeratedDevice]) -> [AudioDirection: TrackedDevice] {
        var assigned: [AudioDirection: TrackedDevice] = [:]
        for device in devices where isQuadcast(modelUID: device.modelUID, name: device.name) {
            for direction in directions(inputChannels: device.inputChannels, outputChannels: device.outputChannels)
            where assigned[direction] == nil {
                let channelCount = direction == .input ? device.inputChannels : device.outputChannels
                assigned[direction] = TrackedDevice(id: device.id, channelCount: channelCount)
            }
        }
        return assigned
    }

    /// Which per-device listeners a rescan must drop and register, given
    /// what was tracked before and what `assignDirections` found now. A
    /// listener is identified by (direction, object id): an id that keeps
    /// serving the same direction is left alone, one that moved to another
    /// direction is re-registered under the new scope, and a `channelCount`
    /// change on its own is not a listener change.
    static func listenerDiff(
        previous: [AudioDirection: TrackedDevice],
        current: [AudioDirection: TrackedDevice]
    ) -> ListenerDiff {
        var diff = ListenerDiff(remove: [:], add: [:])
        for (direction, device) in previous where current[direction]?.id != device.id {
            diff.remove[direction] = device
        }
        for (direction, device) in current where previous[direction]?.id != device.id {
            diff.add[direction] = device
        }
        return diff
    }

    static func scope(for direction: AudioDirection) -> AudioObjectPropertyScope {
        switch direction {
        case .input: return kAudioObjectPropertyScopeInput
        case .output: return kAudioObjectPropertyScopeOutput
        }
    }

    // MARK: - Property addresses

    private static func muteAddress(for direction: AudioDirection) -> AudioObjectPropertyAddress {
        HAL.address(kAudioDevicePropertyMute, scope: scope(for: direction))
    }

    private static func volumeScalarAddress(for direction: AudioDirection, element: UInt32) -> AudioObjectPropertyAddress {
        HAL.address(kAudioDevicePropertyVolumeScalar, scope: scope(for: direction), element: element)
    }

    private static func volumeDecibelsAddress(for direction: AudioDirection) -> AudioObjectPropertyAddress {
        HAL.address(kAudioDevicePropertyVolumeDecibels, scope: scope(for: direction), element: 1)
    }

    // MARK: - Listener handling (all on `queue`)

    private func handleDeviceListChanged() {
        guard isOpen else { return }
        rescanDevices()
        refreshSnapshot()
    }

    private func handleDevicePropertyChanged() {
        guard isOpen else { return }
        refreshSnapshot()
    }

    /// Re-enumerates the HAL's device list and brings the per-device
    /// listeners in line with `assignDirections`' result via `listenerDiff`.
    private func rescanDevices() {
        let enumerated = HAL.allDeviceIDs().map { id in
            EnumeratedDevice(
                id: id,
                modelUID: HAL.readString(id, kAudioDevicePropertyModelUID),
                name: HAL.readString(id, kAudioObjectPropertyName),
                inputChannels: HAL.channelCount(id, scope: kAudioObjectPropertyScopeInput),
                outputChannels: HAL.channelCount(id, scope: kAudioObjectPropertyScopeOutput)
            )
        }
        let assigned = Self.assignDirections(enumerated)
        let diff = Self.listenerDiff(previous: tracked, current: assigned)
        for (direction, device) in diff.remove {
            removeListeners(for: device.id, direction: direction)
        }
        for (direction, device) in diff.add {
            addListener(objectID: device.id, direction: direction, address: Self.muteAddress(for: direction))
            addListener(
                objectID: device.id, direction: direction,
                address: Self.volumeScalarAddress(for: direction, element: 1)
            )
        }
        tracked = assigned
    }

    /// Re-reads every tracked direction and delivers the result only if it
    /// differs from `cached` — which also swallows the HAL's echo of this
    /// object's own writes.
    private func refreshSnapshot() {
        let snapshot = readSnapshot()
        guard snapshot != cached else { return }
        cached = snapshot
        deliver(snapshot)
    }

    private func readSnapshot() -> AudioDeviceSnapshot {
        AudioDeviceSnapshot(input: readLevel(.input), output: readLevel(.output))
    }

    /// A failed mute/volume read is how a just-unplugged device shows up
    /// before the device-list notification lands, so it means "absent"
    /// rather than an error.
    private func readLevel(_ direction: AudioDirection) -> AudioLevel? {
        guard let device = tracked[direction],
              let mute = HAL.readUInt32(device.id, Self.muteAddress(for: direction)),
              let volume = HAL.readFloat32(device.id, Self.volumeScalarAddress(for: direction, element: 1)) else {
            return nil
        }
        let decibels = HAL.readFloat32(device.id, Self.volumeDecibelsAddress(for: direction))
        return AudioLevel(volume: volume, isMuted: mute != 0, decibels: decibels)
    }

    private func addListener(objectID: AudioObjectID, direction: AudioDirection, address: AudioObjectPropertyAddress) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDevicePropertyChanged()
        }
        var address = address
        guard AudioObjectAddPropertyListenerBlock(objectID, &address, queue, block) == noErr else { return }
        registrations.append(ListenerRegistration(
            objectID: objectID, direction: direction, address: address, block: block
        ))
    }

    /// Removing a listener from an object the HAL has already destroyed
    /// fails harmlessly, so an unplugged device's registrations are dropped
    /// the same way as a live one's.
    private func removeListeners(for objectID: AudioObjectID, direction: AudioDirection) {
        let matches: (ListenerRegistration) -> Bool = {
            $0.objectID == objectID && $0.direction == direction
        }
        for registration in registrations where matches(registration) {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(objectID, &address, queue, registration.block)
        }
        registrations.removeAll(where: matches)
    }

    private func deliver(_ snapshot: AudioDeviceSnapshot) {
        DispatchQueue.main.async { self.onStateChanged?(snapshot) }
    }
}
