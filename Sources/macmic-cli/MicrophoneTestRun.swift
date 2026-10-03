// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Dispatch
import Foundation
import QuadcastKit

/// Where `MicrophoneTestRun` writes.
protocol TestTerminal: AnyObject {
    /// One line; ends a shown meter line first.
    func line(_ text: String)
    /// Redraws the current line in place.
    func meter(_ text: String)
    /// One line on stderr.
    func error(_ text: String)
}

final class StandardTerminal: TestTerminal {
    private var meterShown = false

    func line(_ text: String) {
        endMeter()
        print(text)
    }

    func meter(_ text: String) {
        // Clear to end of line: the recorder suffix changes width.
        print("\r\(text)\u{1B}[K", terminator: "")
        fflush(stdout)
        meterShown = true
    }

    func error(_ text: String) {
        endMeter()
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }

    private func endMeter() {
        guard meterShown else { return }
        print()
        meterShown = false
    }
}

/// One `audio test` run: waits for the QuadCast input, starts the session,
/// prints every phase change and a meter while running, and in
/// `recordThenPlay` records once running, then plays the clip back. Calls
/// `finish` exactly once, after stopping the session; never calls `exit()`.
/// Main thread only.
final class MicrophoneTestRun {
    enum Mode: Equatable {
        case listen(seconds: Int)
        case recordThenPlay(seconds: Int)
    }

    /// A mic that is still enumerating when the control opens is only
    /// reported by a later HAL notification.
    static let inputWait: TimeInterval = 3
    static let meterInterval: TimeInterval = 0.1

    private enum Step {
        case waitingForInput, listening, waitingToRecord, recording, waitingToPlay, playing
    }

    private let session: MicrophoneTestSession
    private let mode: Mode
    private let scheduler: Scheduler
    private let terminal: TestTerminal
    private let finishHandler: (Int32) -> Void
    private var step = Step.waitingForInput
    private var lastPrintedPhase: MicrophoneTestPhase?
    private var finished = false
    private var inputWaitWork: ScheduledWork?
    private var meterWork: ScheduledWork?
    private var durationWork: ScheduledWork?
    private var recordingWork: ScheduledWork?

    init(
        session: MicrophoneTestSession,
        mode: Mode,
        scheduler: Scheduler,
        terminal: TestTerminal,
        finish: @escaping (Int32) -> Void
    ) {
        self.session = session
        self.mode = mode
        self.scheduler = scheduler
        self.terminal = terminal
        finishHandler = finish
    }

    func begin() {
        dispatchPrecondition(condition: .onQueue(.main))
        lastPrintedPhase = session.status.phase
        session.onStatusChanged = { [weak self] in self?.handle($0) }
        guard session.status.isInputAvailable else {
            inputWaitWork = scheduler.schedule(after: Self.inputWait) { [weak self] in
                guard let self, self.step == .waitingForInput else { return }
                self.terminal.error("audio test: no QuadCast microphone input device found")
                self.finish(1)
            }
            return
        }
        startTest()
    }

    /// Ctrl-C.
    func interrupt() {
        dispatchPrecondition(condition: .onQueue(.main))
        finish(0)
    }

    // Session callbacks re-enter `handle`, so every path below advances
    // `step` before it issues a session command.

    private func startTest() {
        inputWaitWork?.cancel()
        inputWaitWork = nil
        switch mode {
        case .listen(let seconds):
            step = .listening
            terminal.line("testing microphone for \(seconds) s…")
            durationWork = scheduler.schedule(after: TimeInterval(seconds)) { [weak self] in self?.finish(0) }
        case .recordThenPlay(let seconds):
            step = .waitingToRecord
            terminal.line("testing microphone: record \(seconds) s, then play back…")
        }
        meterWork = scheduler.scheduleRepeating(every: Self.meterInterval) { [weak self] in self?.drawMeter() }
        session.start()
    }

    private func handle(_ status: MicrophoneTestStatus) {
        guard !finished else { return }
        if step == .waitingForInput {
            if status.isInputAvailable {
                startTest()
            }
            return
        }
        if status.phase != lastPrintedPhase {
            lastPrintedPhase = status.phase
            terminal.line(formatTestPhase(status.phase))
        }
        if case .failed = status.phase {
            return finish(1)
        }
        guard case .recordThenPlay(let seconds) = mode else { return }
        switch step {
        case .waitingToRecord:
            guard status.canStartRecording else { return }
            step = .recording
            session.startRecording()
            guard session.status.isRecording else {
                terminal.line("could not start recording")
                return finish(1)
            }
            terminal.line("recording for \(seconds) s — say something…")
            recordingWork = scheduler.schedule(after: TimeInterval(seconds)) { [weak self] in
                self?.session.stopRecording()
            }
        case .recording:
            guard !status.isRecording else { return }
            recordingWork?.cancel()
            recordingWork = nil
            guard let clip = status.recorder.clipDuration else {
                terminal.line("recorded nothing")
                return finish(1)
            }
            terminal.line(String(format: "recorded %.1f s", clip))
            step = .waitingToPlay
            playIfPossible(status)
        case .waitingToPlay:
            playIfPossible(status)
        case .playing:
            guard !status.isPlaying else { return }
            if case .running = status.phase {
                terminal.line("playback finished")
                return finish(0)
            }
            // A restart cut the playback; play again once running.
            step = .waitingToPlay
        case .waitingForInput, .listening:
            return
        }
    }

    private func playIfPossible(_ status: MicrophoneTestStatus) {
        guard status.canStartPlayback else { return }
        step = .playing
        session.startPlayback()
        guard session.status.isPlaying else {
            terminal.line("could not start playback")
            return finish(1)
        }
        terminal.line("playing back…")
    }

    private func drawMeter() {
        guard !finished, case .running = session.status.phase else { return }
        terminal.meter(formatLevelMeter(session.level) + "  " + formatRecorderState(session.status.recorder))
    }

    private func finish(_ code: Int32) {
        guard !finished else { return }
        finished = true
        for work in [inputWaitWork, meterWork, durationWork, recordingWork] {
            work?.cancel()
        }
        inputWaitWork = nil
        meterWork = nil
        durationWork = nil
        recordingWork = nil
        session.onStatusChanged = nil
        session.onLevel = nil
        session.stop()
        finishHandler(code)
    }
}
