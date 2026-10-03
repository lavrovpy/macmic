// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Foundation
import Testing
@testable import QuadcastKit

/// A `MicrophoneTestSession` over a `MockAudioDeviceControl` (opened with
/// `stateAtOpen` unless `openAudio` is false), a `ScriptedMicrophoneEngine`
/// and a `ManualScheduler`, with a `StatusLog` attached unless the test
/// hands the session's callbacks to something else.
final class MicrophoneTestFixture {
    let audio: MockAudioDeviceControl
    let engine: ScriptedMicrophoneEngine
    let scheduler: ManualScheduler
    let log: StatusLog?
    private var current: MicrophoneTestSession?

    var session: MicrophoneTestSession {
        current!
    }

    init(
        stateAtOpen: AudioDeviceSnapshot? = .sample,
        openAudio: Bool = true,
        attachLog: Bool = true,
        configure: (ScriptedMicrophoneEngine) -> Void = { _ in }
    ) {
        audio = MockAudioDeviceControl()
        audio.stateAtOpen = stateAtOpen
        if openAudio {
            try! audio.open()
        }
        engine = ScriptedMicrophoneEngine()
        configure(engine)
        scheduler = ManualScheduler()
        let session = MicrophoneTestSession(audioControl: audio, engine: engine, scheduler: scheduler)
        current = session
        log = attachLog ? StatusLog(session: session) : nil
    }

    func releaseSession() {
        current = nil
    }
}

/// Every status and level a session emits, in order. Records an issue when
/// an emission breaks the status invariants, repeats the previous status, or
/// carries a non-zero level while not running.
final class StatusLog {
    enum Event: Equatable {
        case status(MicrophoneTestStatus)
        case level(Float)
    }

    private(set) var events: [Event] = []
    /// Runs after each status is recorded; a test may issue session commands
    /// from it, the way the app's and the CLI's callbacks do.
    var onStatus: ((MicrophoneTestStatus) -> Void)?
    private var last: MicrophoneTestStatus?

    var statuses: [MicrophoneTestStatus] {
        events.compactMap { if case .status(let status) = $0 { return status } else { return nil } }
    }

    var phases: [MicrophoneTestPhase] {
        statuses.map(\.phase)
    }

    var levels: [Float] {
        events.compactMap { if case .level(let level) = $0 { return level } else { return nil } }
    }

    init(session: MicrophoneTestSession) {
        last = session.status
        session.onStatusChanged = { [weak self] in self?.record($0) }
        session.onLevel = { [weak self] in self?.record(level: $0) }
    }

    private func record(_ status: MicrophoneTestStatus) {
        if !status.satisfiesInvariants {
            Issue.record("status breaks the invariants: \(status)")
        }
        if status == last {
            Issue.record("status emitted twice in a row: \(status)")
        }
        last = status
        events.append(.status(status))
        onStatus?(status)
    }

    private func record(level: Float) {
        if level != 0 {
            if case .running = last?.phase {} else {
                Issue.record("level \(level) emitted while \(String(describing: last?.phase))")
            }
        }
        events.append(.level(level))
    }
}

extension MicrophoneTestStatus {
    /// Test shorthand: input present, recorder idle without a clip.
    static func make(
        _ phase: MicrophoneTestPhase,
        _ recorder: MicrophoneRecorderState = .idle(clipDuration: nil),
        input: Bool = true
    ) -> MicrophoneTestStatus {
        MicrophoneTestStatus(phase: phase, recorder: recorder, isInputAvailable: input)
    }
}
