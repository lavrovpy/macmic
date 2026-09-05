// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import CoreAudio
@testable import QuadcastKit

/// In-memory `MicrophoneMonitor` for unit tests: records every `start`
/// device and `stop`, and lets a test drive the asynchronous outcome
/// (`simulateRunning` / `simulateFailure`) and the level meter
/// (`simulateLevel`). All callbacks fire synchronously.
final class MockMicrophoneMonitor: MicrophoneMonitor {
    var onStateChanged: ((MicrophoneMonitorState) -> Void)?
    var onLevel: ((Float) -> Void)?
    private(set) var state: MicrophoneMonitorState = .stopped

    private(set) var startedDevices: [AudioObjectID] = []
    private(set) var stopCount = 0

    func start(inputDevice: AudioObjectID) {
        startedDevices.append(inputDevice)
        transition(to: .starting)
    }

    func stop() {
        stopCount += 1
        transition(to: .stopped)
    }

    /// The engine came up; `outputDeviceName` is what the real adapter reads
    /// from the system default output device.
    func simulateRunning(outputDeviceName: String? = "MacBook Pro Speakers") {
        transition(to: .running(outputDeviceName: outputDeviceName))
    }

    func simulateFailure(_ error: MicrophoneMonitorError) {
        transition(to: .failed(error))
    }

    /// Delivers a normalized input level exactly as the real adapter would
    /// (unconditionally — a test that wants the "only while running" rule
    /// enforced asserts on it via `state`).
    func simulateLevel(_ level: Float) {
        onLevel?(level)
    }

    private func transition(to newState: MicrophoneMonitorState) {
        state = newState
        onStateChanged?(newState)
    }
}
