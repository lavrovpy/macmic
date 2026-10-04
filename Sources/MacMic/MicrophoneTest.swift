// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Combine
import Dispatch
import Foundation
import QuadcastKit

/// The Audio page's Test Microphone model. Owns the rule that the test never
/// outlives the Audio page or a system sleep and never resumes by itself
/// (mic removal is the session's: it fails). Main thread only.
final class MicrophoneTest: ObservableObject {
    @Published private(set) var status: MicrophoneTestStatus
    @Published private(set) var level: Float

    private let session: MicrophoneTestSession

    /// Takes over `session.onStatusChanged` and `session.onLevel`.
    init(session: MicrophoneTestSession) {
        self.session = session
        status = session.status
        level = session.level
        session.onStatusChanged = { [weak self] status in
            dispatchPrecondition(condition: .onQueue(.main))
            self?.status = status
        }
        session.onLevel = { [weak self] level in
            dispatchPrecondition(condition: .onQueue(.main))
            self?.level = level
        }
    }

    // MARK: Commands

    func toggleTest() {
        dispatchPrecondition(condition: .onQueue(.main))
        if isActive {
            session.stop()
        } else {
            session.start()
        }
    }

    func toggleRecording() {
        dispatchPrecondition(condition: .onQueue(.main))
        if isRecording {
            session.stopRecording()
        } else {
            session.startRecording()
        }
    }

    func togglePlayback() {
        dispatchPrecondition(condition: .onQueue(.main))
        if isPlaying {
            session.stopPlayback()
        } else {
            session.startPlayback()
        }
    }

    /// The pass-through is only meaningful while the user is looking at the
    /// gain slider; leaving the page (or closing the window) ends it.
    func audioPageDidDisappear() {
        dispatchPrecondition(condition: .onQueue(.main))
        session.stop()
    }

    func systemWillSleep() {
        dispatchPrecondition(condition: .onQueue(.main))
        session.stop()
    }

    // MARK: Derivations

    /// The pass-through is up or coming up — what the Start/Stop button
    /// toggles on.
    var isActive: Bool {
        status.isActive
    }

    /// Whether the Test Microphone section is enabled.
    var controlsEnabled: Bool {
        status.isInputAvailable
    }

    /// The last start failed on macOS microphone privacy — the one failure
    /// the user fixes in System Settings rather than by retrying.
    var isMicrophoneAccessDenied: Bool {
        status.phase == .failed(.microphoneAccessDenied)
    }

    var statusText: String {
        switch status.phase {
        case .stopped:
            return "Not running"
        case .starting:
            return "Starting…"
        case .running(let outputDeviceName):
            return "Playing through \(outputDeviceName ?? "the default output")"
        case .failed(.microphoneAccessDenied):
            return "Microphone access denied — allow MacMic in System Settings › Privacy & Security › Microphone"
        case .failed(.inputDeviceUnavailable):
            return "Microphone unavailable"
        case .failed(.engineFailed(let detail)):
            return "Failed: \(detail)"
        }
    }

    var isRecording: Bool {
        status.isRecording
    }

    var isPlaying: Bool {
        status.isPlaying
    }

    /// Record / Stop Recording.
    var recordButtonEnabled: Bool {
        status.canStartRecording || isRecording
    }

    /// Play / Stop.
    var playButtonEnabled: Bool {
        status.canStartPlayback || isPlaying
    }

    var recorderStatusText: String {
        switch status.recorder {
        case .idle(nil):
            return "Nothing recorded"
        case .idle(let duration?):
            return "Recorded \(Self.formatSeconds(duration))"
        case .recording(let elapsed):
            return "Recording… \(Self.formatSeconds(elapsed))"
        case .playing(let elapsed, let duration):
            return "Playing \(Self.formatSeconds(elapsed)) of \(Self.formatSeconds(duration))"
        }
    }

    var maxClipDuration: TimeInterval {
        MicrophoneTestSession.maxClipDuration
    }

    static func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.1f s", seconds)
    }
}
