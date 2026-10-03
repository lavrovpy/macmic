// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import CoreAudio
@testable import QuadcastKit

/// In-memory `AudioDeviceControl` for unit tests: records every write in
/// order, lets a test script the next `open`/set to fail, and simulates
/// hotplug, external changes and re-enumeration. Observers are called
/// synchronously on the caller's thread, so tests need no waiting. Not
/// thread-safe.
final class MockAudioDeviceControl: AudioDeviceControl {
    enum Write: Equatable {
        case volume(Float, AudioDirection)
        case muted(Bool, AudioDirection)
    }

    /// The ids attached to present directions until `simulateReenumeration`.
    static let inputDeviceID: AudioObjectID = 4100
    static let outputDeviceID: AudioObjectID = 4101

    private(set) var inputID = MockAudioDeviceControl.inputDeviceID
    private(set) var outputID = MockAudioDeviceControl.outputDeviceID
    private(set) var isOpen = false
    private(set) var writes: [Write] = []

    /// Consumed (set back to `nil`) the next time `open()` is called.
    var nextOpenError: AudioDeviceControlError?
    /// Consumed (set back to `nil`) the next time `setVolume`/`setMuted` is called.
    var nextSetError: AudioDeviceControlError?
    /// What the device reports when `open()` succeeds. `nil` models
    /// launching with no mic plugged in (delivers `.unavailable`).
    var stateAtOpen: AudioDeviceSnapshot? = .sample
    /// Whether a successful write is delivered with the written value, like
    /// the HAL's listener echo. Set `false` to test the optimistic path in
    /// isolation.
    var echoesWrites = true

    private let observers = AudioObservers()
    /// The levels the device holds, open or not; ids are attached on read.
    private var levels: AudioDeviceSnapshot = .unavailable
    private var lastFreshID: AudioObjectID = 5000

    var snapshot: AudioDeviceSnapshot {
        guard isOpen else { return .unavailable }
        var result = AudioDeviceSnapshot(input: levels.input, output: levels.output)
        if result.input != nil { result.deviceIDs[.input] = inputID }
        if result.output != nil { result.deviceIDs[.output] = outputID }
        return result
    }

    func observe(_ handler: @escaping (AudioDeviceSnapshot) -> Void) -> AudioDeviceObservation {
        observers.add(handler)
    }

    func open() throws {
        if let error = nextOpenError {
            nextOpenError = nil
            throw error
        }
        guard !isOpen else { return }
        isOpen = true
        levels = stateAtOpen ?? .unavailable
        observers.notify(snapshot)
    }

    func close() {
        isOpen = false
    }

    /// Records the raw, unclamped value: clamping is the caller's contract
    /// to prove.
    func setVolume(_ scalar: Float, for direction: AudioDirection) throws {
        try checkWritable(direction)
        writes.append(.volume(scalar, direction))
        levels[direction]?.volume = scalar
        if echoesWrites {
            observers.notify(snapshot)
        }
    }

    func setMuted(_ muted: Bool, for direction: AudioDirection) throws {
        try checkWritable(direction)
        writes.append(.muted(muted, direction))
        levels[direction]?.isMuted = muted
        if echoesWrites {
            observers.notify(snapshot)
        }
    }

    /// Simulates a QuadCast audio device appearing with these levels.
    func simulateDeviceAppeared(_ snapshot: AudioDeviceSnapshot) {
        levels = AudioDeviceSnapshot(input: snapshot.input, output: snapshot.output)
        deliverIfOpen()
    }

    /// Simulates every QuadCast audio device disappearing.
    func simulateDeviceRemoved() {
        levels = .unavailable
        deliverIfOpen()
    }

    /// Simulates an external change (the gain knob, Sound settings, another
    /// app); same as `simulateDeviceAppeared`, named for readability.
    func simulateExternalChange(_ snapshot: AudioDeviceSnapshot) {
        simulateDeviceAppeared(snapshot)
    }

    /// A re-enumeration reassigns every id: each direction takes the given
    /// one, or a fresh one. Delivers the same levels under the new ids.
    func simulateReenumeration(inputID: AudioObjectID? = nil, outputID: AudioObjectID? = nil) {
        self.inputID = inputID ?? freshID()
        self.outputID = outputID ?? freshID()
        deliverIfOpen()
    }

    private func freshID() -> AudioObjectID {
        lastFreshID += 1
        return lastFreshID
    }

    private func deliverIfOpen() {
        guard isOpen else { return }
        observers.notify(snapshot)
    }

    private func checkWritable(_ direction: AudioDirection) throws {
        if let error = nextSetError {
            nextSetError = nil
            throw error
        }
        guard snapshot[direction] != nil else {
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
