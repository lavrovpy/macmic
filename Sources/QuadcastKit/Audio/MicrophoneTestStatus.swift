// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Foundation

/// Why the Test Microphone could not (or can no longer) pass the mic through.
public enum MicrophoneTestError: Error, Equatable, Sendable {
    /// macOS microphone privacy permission is denied or restricted for this
    /// process; the user has to change it in System Settings.
    case microphoneAccessDenied
    /// The QuadCast input is absent, or reports no channels / no sample rate,
    /// which is how a just-unplugged device looks to `AVAudioEngine`.
    case inputDeviceUnavailable
    /// `AVAudioEngine` failed to prepare, start, or restart; the payload is
    /// the underlying error's description, for display.
    case engineFailed(String)
}

public enum MicrophoneTestPhase: Equatable, Sendable {
    case stopped
    /// `start` was called, or a restart is under way; permission and engine
    /// setup are in flight.
    case starting
    /// Passing audio through. `outputDeviceName` is the system default
    /// output device's name at the time the engine started (`nil` if Core
    /// Audio didn't report one).
    case running(outputDeviceName: String?)
    case failed(MicrophoneTestError)
}

/// The record-and-replay half of the test: a clip can only be recorded or
/// played while `.running`, survives the session's own restarts, and is
/// dropped by stop, failure and the next start.
public enum MicrophoneRecorderState: Equatable, Sendable {
    /// Nothing in progress; `clipDuration` (seconds) is the last recording's
    /// length, `nil` when there is none to play.
    case idle(clipDuration: TimeInterval?)
    case recording(elapsed: TimeInterval)
    case playing(elapsed: TimeInterval, clipDuration: TimeInterval)

    /// The clip that would play, if any — in every phase, not only `.idle`.
    public var clipDuration: TimeInterval? {
        switch self {
        case .idle(let duration): return duration
        case .recording: return nil
        case .playing(_, let duration): return duration
        }
    }
}

/// Both halves of the test, reported together, one value per transition.
/// Invariants (asserted in the session's only publish and by `StatusLog` in
/// every test): `.recording`/`.playing` only while `.running`;
/// `.stopped`/`.failed` carry `.idle(clipDuration: nil)`; `.starting`
/// carries `.idle` with any clip kept across a restart.
public struct MicrophoneTestStatus: Equatable, Sendable {
    public internal(set) var phase: MicrophoneTestPhase
    public internal(set) var recorder: MicrophoneRecorderState
    /// The QuadCast input is present, from the latest `AudioDeviceControl`
    /// delivery, in every phase.
    public internal(set) var isInputAvailable: Bool

    init(phase: MicrophoneTestPhase, recorder: MicrophoneRecorderState, isInputAvailable: Bool) {
        self.phase = phase
        self.recorder = recorder
        self.isInputAvailable = isInputAvailable
    }

    /// `.starting` or `.running`.
    public var isActive: Bool {
        switch phase {
        case .starting, .running: return true
        case .stopped, .failed: return false
        }
    }

    public var isRecording: Bool {
        if case .recording = recorder { return true }
        return false
    }

    public var isPlaying: Bool {
        if case .playing = recorder { return true }
        return false
    }

    /// The session's own gates; UI and CLI enable controls from these and
    /// never re-derive them.
    public var canStartRecording: Bool {
        guard case .running = phase, case .idle = recorder else { return false }
        return true
    }

    public var canStartPlayback: Bool {
        guard case .running = phase, case .idle(let clip) = recorder else { return false }
        return clip != nil
    }

    var satisfiesInvariants: Bool {
        switch phase {
        case .running:
            return true
        case .starting:
            if case .idle = recorder { return true }
            return false
        case .stopped, .failed:
            return recorder == .idle(clipDuration: nil)
        }
    }
}
