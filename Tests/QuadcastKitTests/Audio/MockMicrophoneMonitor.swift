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
/// (`simulateRunning` / `simulateFailure`), the level meter
/// (`simulateLevel`), and the recorder's progress and completion
/// (`simulateRecordingProgress` / `simulatePlaybackProgress` /
/// `simulatePlaybackFinished`). All callbacks fire synchronously. The
/// recorder calls do not check `state` — that guard is `AppState`'s.
final class MockMicrophoneMonitor: MicrophoneMonitor {
    var onStateChanged: ((MicrophoneMonitorState) -> Void)?
    var onLevel: ((Float) -> Void)?
    private(set) var state: MicrophoneMonitorState = .stopped
    var onRecorderStateChanged: ((MicrophoneRecorderState) -> Void)?
    private(set) var recorderState: MicrophoneRecorderState = .idle(clipDuration: nil)
    let maxClipDuration: TimeInterval = 30

    private(set) var startedDevices: [AudioObjectID] = []
    private(set) var stopCount = 0
    private(set) var recordingStartCount = 0
    private(set) var playbackStartCount = 0

    func start(inputDevice: AudioObjectID) {
        startedDevices.append(inputDevice)
        transitionRecorder(to: .idle(clipDuration: nil))
        transition(to: .starting)
    }

    func stop() {
        stopCount += 1
        transitionRecorder(to: .idle(clipDuration: nil))
        transition(to: .stopped)
    }

    func startRecording() {
        recordingStartCount += 1
        transitionRecorder(to: .recording(elapsed: 0))
    }

    func stopRecording() {
        guard case .recording(let elapsed) = recorderState else { return }
        transitionRecorder(to: .idle(clipDuration: elapsed))
    }

    func startPlayback() {
        guard case .idle(let duration?) = recorderState else { return }
        playbackStartCount += 1
        transitionRecorder(to: .playing(elapsed: 0, clipDuration: duration))
    }

    func stopPlayback() {
        guard case .playing(_, let duration) = recorderState else { return }
        transitionRecorder(to: .idle(clipDuration: duration))
    }

    func simulateRecordingProgress(_ elapsed: TimeInterval) {
        guard case .recording = recorderState else { return }
        transitionRecorder(to: .recording(elapsed: elapsed))
    }

    func simulatePlaybackProgress(_ elapsed: TimeInterval) {
        guard case .playing(_, let duration) = recorderState else { return }
        transitionRecorder(to: .playing(elapsed: elapsed, clipDuration: duration))
    }

    /// The clip played to its end.
    func simulatePlaybackFinished() {
        stopPlayback()
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

    private func transitionRecorder(to newState: MicrophoneRecorderState) {
        guard newState != recorderState else { return }
        recorderState = newState
        onRecorderStateChanged?(newState)
    }
}
