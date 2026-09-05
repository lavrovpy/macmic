// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import CoreAudio

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

    /// No QuadCast audio device present in either direction.
    public static let unavailable = AudioDeviceSnapshot(input: nil, output: nil)

    public init(input: AudioLevel?, output: AudioLevel?) {
        self.input = input
        self.output = output
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

/// Abstraction over the QuadCast S's Core Audio volume/mute controls (the
/// same properties macOS Sound settings drive), so `AppState` and the CLI
/// can be tested without real hardware. `CoreAudioDeviceControl` is the
/// production adapter; `MockAudioDeviceControl` (test target) is used in
/// unit tests.
///
/// Availability is independent of `HIDTransport`'s lighting connection: the
/// audio side is a different USB function with its own hotplug lifecycle,
/// so a caller must track both separately.
public protocol AudioDeviceControl: AnyObject {
    /// Invoked on the main thread with the full current state whenever
    /// anything changes: a QuadCast audio device appearing or disappearing,
    /// an external volume/mute change (the mic's gain knob, Sound settings,
    /// another app), and the echo of this object's own `set*` calls. The
    /// first delivery after `open()` reports whatever is already present —
    /// asynchronously, so `open()` returning says nothing about presence.
    var onStateChanged: ((AudioDeviceSnapshot) -> Void)? { get set }

    /// The most recently observed state; `.unavailable` before `open()`.
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

    /// The Core Audio object serving one direction, for handing to a
    /// `MicrophoneMonitor`; `nil` while that device is absent. Ids are
    /// reassigned on every re-enumeration, so callers must not cache one
    /// across a `snapshot` change that drops the direction.
    func deviceID(for direction: AudioDirection) -> AudioObjectID?
}

/// Errors surfaced by `AudioDeviceControl` implementations.
public enum AudioDeviceControlError: Error, Equatable {
    /// No QuadCast Core Audio device is present for the requested direction.
    case deviceNotFound(AudioDirection)
    /// Registering the Core Audio device-list listener failed with this status.
    case openFailed(OSStatus)
    /// A property read failed with this status.
    case readFailed(OSStatus)
    /// A property write failed with this status.
    case setFailed(OSStatus)
}
