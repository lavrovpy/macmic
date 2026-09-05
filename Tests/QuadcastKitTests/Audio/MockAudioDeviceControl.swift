// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

@testable import QuadcastKit

/// In-memory `AudioDeviceControl` for unit tests: records every write in
/// order, lets a test script the next `open`/set to fail, and simulates
/// hotplug and external changes — all callbacks fire synchronously so tests
/// need no waiting.
final class MockAudioDeviceControl: AudioDeviceControl {
    enum Write: Equatable {
        case volume(Float, AudioDirection)
        case muted(Bool, AudioDirection)
    }

    var onStateChanged: ((AudioDeviceSnapshot) -> Void)?
    private(set) var snapshot: AudioDeviceSnapshot = .unavailable
    private(set) var isOpen = false
    private(set) var writes: [Write] = []

    /// Consumed (set back to `nil`) the next time `open()` is called.
    var nextOpenError: AudioDeviceControlError?
    /// Consumed (set back to `nil`) the next time `setVolume`/`setMuted` is called.
    var nextSetError: AudioDeviceControlError?
    /// Delivered via `onStateChanged` when `open()` succeeds. `nil` models
    /// launching with no mic plugged in (delivers `.unavailable`).
    var stateAtOpen: AudioDeviceSnapshot? = .sample
    /// Whether a successful write fires `onStateChanged` with the written
    /// value, like the HAL's listener echo. Set `false` to test the
    /// optimistic path in isolation.
    var echoesWrites = true

    func open() throws {
        if let error = nextOpenError {
            nextOpenError = nil
            throw error
        }
        isOpen = true
        snapshot = stateAtOpen ?? .unavailable
        onStateChanged?(snapshot)
    }

    func close() {
        isOpen = false
        snapshot = .unavailable
    }

    /// Records the raw, unclamped value: clamping is the caller's contract
    /// to prove.
    func setVolume(_ scalar: Float, for direction: AudioDirection) throws {
        try checkWritable(direction)
        writes.append(.volume(scalar, direction))
        snapshot[direction]?.volume = scalar
        if echoesWrites {
            onStateChanged?(snapshot)
        }
    }

    func setMuted(_ muted: Bool, for direction: AudioDirection) throws {
        try checkWritable(direction)
        writes.append(.muted(muted, direction))
        snapshot[direction]?.isMuted = muted
        if echoesWrites {
            onStateChanged?(snapshot)
        }
    }

    /// Simulates a QuadCast audio device appearing with these values.
    func simulateDeviceAppeared(_ snapshot: AudioDeviceSnapshot) {
        self.snapshot = snapshot
        onStateChanged?(snapshot)
    }

    /// Simulates every QuadCast audio device disappearing.
    func simulateDeviceRemoved() {
        snapshot = .unavailable
        onStateChanged?(snapshot)
    }

    /// Simulates an external change (the gain knob, Sound settings, another
    /// app); same as `simulateDeviceAppeared`, named for readability.
    func simulateExternalChange(_ snapshot: AudioDeviceSnapshot) {
        simulateDeviceAppeared(snapshot)
    }

    private func checkWritable(_ direction: AudioDirection) throws {
        if let error = nextSetError {
            nextSetError = nil
            throw error
        }
        guard isOpen, snapshot[direction] != nil else {
            throw AudioDeviceControlError.deviceNotFound(direction)
        }
    }
}

extension AudioDeviceSnapshot {
    /// The values probed from the real mic (input 0.675 / +2.125 dB, output
    /// 0.812 / -12.0625 dB).
    static let sample = AudioDeviceSnapshot(
        input: AudioLevel(volume: 0.675, isMuted: false, decibels: 2.125),
        output: AudioLevel(volume: 0.812, isMuted: false, decibels: -12.0625)
    )
}
