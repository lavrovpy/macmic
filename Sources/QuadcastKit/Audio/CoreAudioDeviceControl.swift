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
///
/// Internal state is confined to a private serial queue, where the HAL
/// listeners also run. Observers run on `callbackQueue` (`.main` in
/// production).
public final class CoreAudioDeviceControl: AudioDeviceControl {
    static let usbVendorID = 0x0951
    static let usbProductID = 0x171d
    static let modelUIDSuffix = ":0951:171d"
    static let fallbackDeviceName = "HyperX QuadCast S"

    /// One HAL device's identity and per-scope channel counts, as read by
    /// `rescanDevices` before `assignDirections` decides whether it's ours.
    private struct EnumeratedDevice {
        let id: AudioObjectID
        let modelUID: String?
        let name: String?
        let inputChannels: Int
        let outputChannels: Int
    }

    /// The device serving one `AudioDirection`; `channelCount` is that
    /// direction's scope only, since volume is written per channel.
    private struct TrackedDevice {
        let id: AudioObjectID
        let channelCount: Int
    }

    /// Per-device listeners to drop and to register after a rescan, keyed by
    /// the direction they observe (the mute/volume addresses are scoped).
    private struct ListenerDiff {
        var remove: [AudioDirection: TrackedDevice]
        var add: [AudioDirection: TrackedDevice]
    }

    private let hal: HALPort
    private let callbackQueue: DispatchQueue
    private let queue = DispatchQueue(label: "dev.alavreniuk.macmic.coreaudio-control")
    private let observers = AudioObservers()

    // Confined to `queue`.
    private var tracked: [AudioDirection: TrackedDevice] = [:]
    private var listeners: [AudioDirection: [HALListener]] = [:]
    private var deviceListListener: HALListener?
    private var cached: AudioDeviceSnapshot = .unavailable
    private var lastDelivered: AudioDeviceSnapshot?
    private var isOpen = false

    public convenience init() {
        self.init(hal: SystemHAL(), callbackQueue: .main)
    }

    /// `callbackQueue` must be serial. Tests pass a private one.
    init(hal: HALPort, callbackQueue: DispatchQueue) {
        self.hal = hal
        self.callbackQueue = callbackQueue
    }

    public func observe(_ handler: @escaping (AudioDeviceSnapshot) -> Void) -> AudioDeviceObservation {
        observers.add(handler)
    }

    public var snapshot: AudioDeviceSnapshot {
        queue.sync { cached }
    }

    /// Registers the device-list listener and scans synchronously, so
    /// `snapshot` is valid when this returns; the first delivery is still
    /// asynchronous. A second call while open is a no-op.
    public func open() throws {
        try queue.sync {
            guard !isOpen else { return }
            do {
                deviceListListener = try hal.addListener(
                    HAL.systemObject, HAL.address(kAudioHardwarePropertyDevices), queue: queue
                ) { [weak self] in
                    self?.handleDeviceListChanged()
                }
            } catch let error as HALStatusError {
                throw AudioDeviceControlError.openFailed(error.status)
            }
            isOpen = true
            lastDelivered = nil
            rescanDevices()
            cached = readSnapshot()
            scheduleDelivery()
        }
    }

    /// State is cleared under `queue`, but the HAL calls are made outside it
    /// so a listener block that is already queued can't be waited on from
    /// the queue it needs; such a block finds `isOpen == false` and returns.
    public func close() {
        let toRemove: [HALListener] = queue.sync {
            let removed = [deviceListListener].compactMap { $0 } + listeners.values.flatMap { $0 }
            deviceListListener = nil
            listeners.removeAll()
            tracked.removeAll()
            cached = .unavailable
            lastDelivered = nil
            isOpen = false
            return removed
        }
        toRemove.forEach(hal.removeListener)
    }

    public func setVolume(_ scalar: Float, for direction: AudioDirection) throws {
        try queue.sync {
            guard let device = tracked[direction] else {
                throw AudioDeviceControlError.deviceNotFound(direction)
            }
            let value = Float32(min(max(scalar, 0), 1))
            var wroteAnyChannel = false
            // A failure on a later channel leaves earlier ones written, so the
            // snapshot must be re-read even when this throws.
            defer {
                if wroteAnyChannel { refreshAfterOwnWrite() }
            }
            for element in 1...UInt32(max(device.channelCount, 1)) {
                let status = hal.write(value, device.id, Self.volumeScalarAddress(for: direction, element: element))
                guard status == noErr else {
                    throw AudioDeviceControlError.setFailed(status)
                }
                wroteAnyChannel = true
            }
        }
    }

    public func setMuted(_ muted: Bool, for direction: AudioDirection) throws {
        try queue.sync {
            guard let device = tracked[direction] else {
                throw AudioDeviceControlError.deviceNotFound(direction)
            }
            let status = hal.write(UInt32(muted ? 1 : 0), device.id, Self.muteAddress(for: direction))
            guard status == noErr else {
                throw AudioDeviceControlError.setFailed(status)
            }
            refreshAfterOwnWrite()
        }
    }

    // MARK: - Direction assignment

    /// `true` for a ModelUID carrying the QuadCast S's USB vendor:product;
    /// the user-visible name is consulted only when no ModelUID is reported.
    private static func isQuadcast(modelUID: String?, name: String?) -> Bool {
        if let modelUID {
            return modelUID.lowercased().hasSuffix(modelUIDSuffix)
        }
        return name == fallbackDeviceName
    }

    /// Which directions a device serves, from its per-scope channel counts.
    private static func directions(inputChannels: Int, outputChannels: Int) -> [AudioDirection] {
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
    private static func assignDirections(_ devices: [EnumeratedDevice]) -> [AudioDirection: TrackedDevice] {
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
    private static func listenerDiff(
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

    private static func scope(for direction: AudioDirection) -> AudioObjectPropertyScope {
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
        let enumerated = hal.deviceIDs().map { id in
            EnumeratedDevice(
                id: id,
                modelUID: hal.string(id, kAudioDevicePropertyModelUID),
                name: hal.string(id, kAudioObjectPropertyName),
                inputChannels: hal.channelCount(id, scope: kAudioObjectPropertyScopeInput),
                outputChannels: hal.channelCount(id, scope: kAudioObjectPropertyScopeOutput)
            )
        }
        let assigned = Self.assignDirections(enumerated)
        let diff = Self.listenerDiff(previous: tracked, current: assigned)
        for direction in diff.remove.keys {
            listeners.removeValue(forKey: direction)?.forEach(hal.removeListener)
        }
        for (direction, device) in diff.add {
            let addresses = [Self.muteAddress(for: direction), Self.volumeScalarAddress(for: direction, element: 1)]
            listeners[direction] = addresses.compactMap { address in
                try? hal.addListener(device.id, address, queue: queue) { [weak self] in
                    self?.handleDevicePropertyChanged()
                }
            }
        }
        tracked = assigned
    }

    /// Re-reads every tracked direction and schedules a delivery only if
    /// levels or device ids changed — which also swallows the HAL's echo of
    /// this object's own writes.
    private func refreshSnapshot() {
        let current = readSnapshot()
        guard !current.isIdentical(to: cached) else { return }
        cached = current
        scheduleDelivery()
    }

    /// Re-reads after this object's own write and forces the next delivery
    /// even if it equals the last one (the `observe` contract for writes).
    /// Without the force, the dedup swallows a write another process reverted
    /// before the delivery ran (A → B → A), leaving a caller that applied B
    /// optimistically on B.
    private func refreshAfterOwnWrite() {
        cached = readSnapshot()
        lastDelivered = nil
        scheduleDelivery()
    }

    /// A direction gets a device id only when its mute and volume reads
    /// succeeded.
    private func readSnapshot() -> AudioDeviceSnapshot {
        var snapshot = AudioDeviceSnapshot.unavailable
        for direction in AudioDirection.allCases {
            guard let device = tracked[direction], let level = readLevel(device, direction) else { continue }
            snapshot[direction] = level
            snapshot.deviceIDs[direction] = device.id
        }
        return snapshot
    }

    /// A failed mute/volume read is how a just-unplugged device shows up
    /// before the device-list notification lands, so it means "absent"
    /// rather than an error.
    private func readLevel(_ device: TrackedDevice, _ direction: AudioDirection) -> AudioLevel? {
        guard let mute = hal.uint32(device.id, Self.muteAddress(for: direction)),
              let volume = hal.float32(device.id, Self.volumeScalarAddress(for: direction, element: 1)) else {
            return nil
        }
        let decibels = hal.float32(device.id, Self.volumeDecibelsAddress(for: direction))
        return AudioLevel(volume: volume, isMuted: mute != 0, decibels: decibels)
    }

    private func scheduleDelivery() {
        callbackQueue.async { [weak self] in self?.deliverLatest() }
    }

    // MARK: - Delivery (on `callbackQueue`)

    /// Delivers whatever `cached` holds now, not a value captured when the
    /// delivery was scheduled: that is what keeps a delivery from predating
    /// a `snapshot` read made on main in between. Capturing the value at
    /// schedule time would break it.
    private func deliverLatest() {
        let latest: AudioDeviceSnapshot? = queue.sync {
            guard isOpen, !(lastDelivered.map { cached.isIdentical(to: $0) } ?? false) else { return nil }
            lastDelivered = cached
            return cached
        }
        if let latest {
            observers.notify(latest)
        }
    }
}
