// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import CoreAudio
import Foundation

/// Which of the QuadCast S's two Core Audio devices a control belongs to:
/// `.input` is the microphone (gain + mic mute), `.output` is the
/// headphone-monitoring output (volume + monitor mute).
public enum AudioDirection: CaseIterable, Sendable {
    case input, output
}

/// The volume/mute state of one direction, read from the device.
/// `volume` is Core Audio's scalar (`0...1`); `decibels` is the same
/// setting as reported by `kAudioDevicePropertyVolumeDecibels`, for display
/// only (`nil` if the device doesn't report it).
public struct AudioLevel: Equatable, Sendable {
    public var volume: Float
    public var isMuted: Bool
    public var decibels: Float?

    public init(volume: Float, isMuted: Bool, decibels: Float? = nil) {
        self.volume = volume
        self.isMuted = isMuted
        self.decibels = decibels
    }
}

/// Everything an `AudioDeviceControl` knows about the mic's audio side at
/// one instant. A `nil` direction means that Core Audio device is absent.
public struct AudioDeviceSnapshot: Equatable, Sendable {
    public var input: AudioLevel?
    public var output: AudioLevel?
    /// The HAL device behind each direction whose level was read in this
    /// snapshot (set by `CoreAudioDeviceControl` and the test mock; empty
    /// when built with the public init). Reassigned on every re-enumeration.
    var deviceIDs: [AudioDirection: AudioObjectID] = [:]

    /// No QuadCast audio device present in either direction.
    public static let unavailable = AudioDeviceSnapshot(input: nil, output: nil)

    public init(input: AudioLevel?, output: AudioLevel?) {
        self.input = input
        self.output = output
    }

    init(input: AudioLevel?, output: AudioLevel?, deviceIDs: [AudioDirection: AudioObjectID]) {
        self.input = input
        self.output = output
        self.deviceIDs = deviceIDs
    }

    /// Levels only — the app's view. QuadcastKit code that must see
    /// re-enumerations uses `isIdentical(to:)`.
    ///
    /// Both this and `isIdentical(to:)` list the stored properties by hand:
    /// a new stored property must be added to both, or deduplication on
    /// either side silently swallows changes to it.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.input == rhs.input && lhs.output == rhs.output
    }

    /// Levels and device ids.
    func isIdentical(to other: Self) -> Bool {
        self == other && deviceIDs == other.deviceIDs
    }

    public var isAvailable: Bool {
        input != nil || output != nil
    }

    public subscript(direction: AudioDirection) -> AudioLevel? {
        get {
            switch direction {
            case .input: return input
            case .output: return output
            }
        }
        set {
            switch direction {
            case .input: input = newValue
            case .output: output = newValue
            }
        }
    }
}

/// Ends one `observe` registration. Idempotent; also on deinit. A delivery
/// in progress skips a cancelled handler.
public final class AudioDeviceObservation {
    private let lock = NSLock()
    private var cancelAction: (() -> Void)?

    init(cancel: @escaping () -> Void) {
        cancelAction = cancel
    }

    deinit {
        cancel()
    }

    public func cancel() {
        lock.lock()
        let action = cancelAction
        cancelAction = nil
        lock.unlock()
        action?()
    }
}

/// Abstraction over the QuadCast S's Core Audio volume/mute controls (the
/// same properties macOS Sound settings drive), so the app and the CLI can
/// be tested without real hardware. `CoreAudioDeviceControl` is the
/// production adapter; `MockAudioDeviceControl` (test target) is used in
/// unit tests.
///
/// Availability is independent of `HIDTransport`'s lighting connection: the
/// audio side is a different USB function with its own hotplug lifecycle,
/// so a caller must track both separately.
public protocol AudioDeviceControl: AnyObject {
    /// Registers `handler` for every delivery, in registration order, on the
    /// main queue. A delivery is the latest snapshot whenever levels, mute,
    /// presence or a tracked device id changed since the previous delivery:
    /// a QuadCast device appearing/disappearing, a re-enumeration under new
    /// ids even with identical levels, an external change, the echo of this
    /// object's own writes. Every successful write is followed by a delivery
    /// even if its value equals the previous one (another process may have
    /// reverted the write first). Bursts may coalesce; a delivery never
    /// predates a `snapshot` read made earlier on main. No replay on
    /// registration. The first delivery after `open()` arrives even when
    /// nothing is present; nothing is delivered after `close()`. Callable
    /// from any thread.
    func observe(_ handler: @escaping (AudioDeviceSnapshot) -> Void) -> AudioDeviceObservation

    /// Current state (may be ahead of the last delivery); `.unavailable`
    /// before `open()` and after `close()`.
    var snapshot: AudioDeviceSnapshot { get }

    /// Starts watching the Core Audio device list and any matched device's
    /// volume/mute properties.
    func open() throws
    /// Stops watching and drops all property listeners.
    func close()

    /// Sets the volume scalar (`0...1`, clamped) of one direction on every
    /// channel of that device.
    func setVolume(_ scalar: Float, for direction: AudioDirection) throws
    /// Sets the master mute of one direction.
    func setMuted(_ muted: Bool, for direction: AudioDirection) throws
}

/// The observer table both implementations share. NSLock-protected;
/// `notify` calls handlers outside the lock.
final class AudioObservers {
    private struct Entry {
        let id: Int
        let handler: (AudioDeviceSnapshot) -> Void
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var nextID = 0

    func add(_ handler: @escaping (AudioDeviceSnapshot) -> Void) -> AudioDeviceObservation {
        lock.lock()
        nextID += 1
        let id = nextID
        entries.append(Entry(id: id, handler: handler))
        lock.unlock()
        return AudioDeviceObservation { [weak self] in self?.remove(id) }
    }

    func notify(_ snapshot: AudioDeviceSnapshot) {
        lock.lock()
        let ids = entries.map(\.id)
        lock.unlock()
        for id in ids {
            lock.lock()
            let handler = entries.first { $0.id == id }?.handler
            lock.unlock()
            handler?(snapshot)
        }
    }

    private func remove(_ id: Int) {
        lock.lock()
        entries.removeAll { $0.id == id }
        lock.unlock()
    }
}

/// Errors surfaced by `AudioDeviceControl` implementations.
public enum AudioDeviceControlError: Error, Equatable {
    /// No QuadCast Core Audio device is present for the requested direction.
    case deviceNotFound(AudioDirection)
    /// Registering the Core Audio device-list listener failed with this status.
    case openFailed(OSStatus)
    /// A property write failed with this status.
    case setFailed(OSStatus)
}
