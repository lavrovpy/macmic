// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Foundation
import Testing
@testable import macmic_cli
@testable import QuadcastKit

/// Everything a `MicrophoneTestRun` writes, in order.
final class RecordingTerminal: TestTerminal {
    enum Entry: Equatable {
        case line(String)
        case meter(String)
        case error(String)
    }

    private(set) var entries: [Entry] = []

    var lines: [String] {
        entries.compactMap { if case .line(let text) = $0 { return text } else { return nil } }
    }

    var meters: [String] {
        entries.compactMap { if case .meter(let text) = $0 { return text } else { return nil } }
    }

    var errors: [String] {
        entries.compactMap { if case .error(let text) = $0 { return text } else { return nil } }
    }

    func line(_ text: String) {
        entries.append(.line(text))
    }

    func meter(_ text: String) {
        entries.append(.meter(text))
    }

    func error(_ text: String) {
        entries.append(.error(text))
    }
}

/// `macmic-cli audio test` driven over a real session (scripted engine,
/// manual clock) into a `RecordingTerminal`.
@Suite @MainActor struct MicrophoneTestRunTests {
    private final class Harness {
        let fixture: MicrophoneTestFixture
        let terminal = RecordingTerminal()
        let run: MicrophoneTestRun
        private let finishes = Finishes()

        var codes: [Int32] {
            finishes.codes
        }

        init(
            mode: MicrophoneTestRun.Mode,
            stateAtOpen: AudioDeviceSnapshot? = .sample,
            _ configure: (ScriptedMicrophoneEngine) -> Void = { _ in }
        ) {
            fixture = MicrophoneTestFixture(stateAtOpen: stateAtOpen, attachLog: false, configure: configure)
            let finishes = finishes
            run = MicrophoneTestRun(
                session: fixture.session, mode: mode, scheduler: fixture.scheduler, terminal: terminal
            ) { finishes.codes.append($0) }
        }
    }

    private final class Finishes {
        var codes: [Int32] = []
    }

    private static let listenHeader = "testing microphone for 4 s…"
    private static let runningLine = "running: playing through MacBook Pro Speakers"

    @Test func listenPrintsStatesAndExitsZeroAfterTheDuration() {
        let harness = Harness(mode: .listen(seconds: 4))

        harness.run.begin()
        #expect(harness.terminal.lines == [Self.listenHeader, "starting…", Self.runningLine])

        harness.fixture.scheduler.advance(by: 3.9)
        #expect(harness.codes.isEmpty)

        harness.fixture.scheduler.advance(by: 0.2)
        #expect(harness.codes == [0])
        #expect(harness.terminal.lines == [Self.listenHeader, "starting…", Self.runningLine])
        #expect(harness.fixture.session.status.phase == .stopped)
        #expect(harness.fixture.engine.isRunning == false)
    }

    @Test func waitsUpTo3sForTheInputThenFails() {
        let harness = Harness(mode: .listen(seconds: 10), stateAtOpen: nil)

        harness.run.begin()
        harness.fixture.scheduler.advance(by: 2.9)
        #expect(harness.codes.isEmpty)
        #expect(harness.terminal.entries.isEmpty)

        harness.fixture.scheduler.advance(by: 0.2)
        #expect(harness.terminal.errors == ["audio test: no QuadCast microphone input device found"])
        #expect(harness.terminal.lines.isEmpty)
        #expect(harness.codes == [1])
        #expect(harness.fixture.engine.calls.isEmpty)
    }

    @Test func inputAppearingDuringTheWaitStartsTheTest() {
        let harness = Harness(mode: .listen(seconds: 4), stateAtOpen: nil)
        harness.run.begin()
        harness.fixture.scheduler.advance(by: 1)

        harness.fixture.audio.simulateDeviceAppeared(.sample)
        #expect(harness.terminal.lines == [Self.listenHeader, "starting…", Self.runningLine])

        harness.fixture.scheduler.advance(by: 3)
        #expect(harness.codes.isEmpty)
        #expect(harness.terminal.errors.isEmpty)

        harness.fixture.scheduler.advance(by: 1.1)
        #expect(harness.codes == [0])
    }

    @Test func failureExitsOne() {
        let harness = Harness(mode: .listen(seconds: 4)) { $0.startResult = .failure(.engineFailed("boom")) }

        harness.run.begin()

        #expect(harness.terminal.lines == [Self.listenHeader, "starting…", "failed: audio engine error: boom"])
        #expect(harness.codes == [1])
    }

    @Test func recordThenPlayRoundTripExitsZero() {
        let harness = Harness(mode: .recordThenPlay(seconds: 3))
        harness.run.begin()
        harness.fixture.engine.recordedDuration = 3

        harness.fixture.scheduler.advance(by: 3)
        #expect(harness.codes.isEmpty)
        harness.fixture.engine.finishPlayback()

        #expect(harness.terminal.lines == [
            "testing microphone: record 3 s, then play back…",
            "starting…",
            Self.runningLine,
            "recording for 3 s — say something…",
            "recorded 3.0 s",
            "playing back…",
            "playback finished",
        ])
        #expect(harness.codes == [0])
    }

    @Test func restartDuringRecordingStillPlaysBackAndExitsZero() {
        let harness = Harness(mode: .recordThenPlay(seconds: 3))
        harness.run.begin()
        harness.fixture.scheduler.advance(by: 1.2)
        harness.fixture.engine.recordedDuration = 1.2

        harness.fixture.engine.emit(.restartNeeded)
        harness.fixture.scheduler.runUntilIdle()
        harness.fixture.scheduler.advance(by: 2)
        harness.fixture.engine.finishPlayback()

        #expect(harness.terminal.lines == [
            "testing microphone: record 3 s, then play back…",
            "starting…",
            Self.runningLine,
            "recording for 3 s — say something…",
            "starting…",
            "recorded 1.2 s",
            Self.runningLine,
            "playing back…",
            "playback finished",
        ])
        #expect(harness.codes == [0])
    }

    @Test func restartDuringPlaybackReplaysOnceRunning() {
        let harness = Harness(mode: .recordThenPlay(seconds: 2))
        harness.run.begin()
        harness.fixture.engine.recordedDuration = 2
        harness.fixture.scheduler.advance(by: 2)
        #expect(harness.fixture.engine.isPlaying)

        harness.fixture.engine.emit(.restartNeeded)
        harness.fixture.scheduler.runUntilIdle()
        #expect(harness.fixture.engine.isPlaying)
        harness.fixture.engine.finishPlayback()

        #expect(harness.terminal.lines == [
            "testing microphone: record 2 s, then play back…",
            "starting…",
            Self.runningLine,
            "recording for 2 s — say something…",
            "recorded 2.0 s",
            "playing back…",
            "starting…",
            Self.runningLine,
            "playing back…",
            "playback finished",
        ])
        #expect(harness.fixture.engine.count(of: .startPlayback) == 2)
        #expect(harness.codes == [0])
    }

    @Test func emptyRecordingExitsOne() {
        let harness = Harness(mode: .recordThenPlay(seconds: 3))
        harness.run.begin()

        harness.fixture.scheduler.advance(by: 3)

        #expect(harness.terminal.lines.last == "recorded nothing")
        #expect(harness.codes == [1])
    }

    @Test func interruptExitsZeroAndStopsTheSession() {
        let harness = Harness(mode: .listen(seconds: 10))
        harness.run.begin()

        harness.run.interrupt()

        #expect(harness.codes == [0])
        #expect(harness.fixture.session.status.phase == .stopped)
        #expect(harness.fixture.session.onStatusChanged == nil)
        #expect(harness.fixture.engine.isRunning == false)
        #expect(harness.fixture.scheduler.pendingCount == 0)
        #expect(harness.terminal.lines.last == Self.runningLine)
    }

    @Test func meterRedrawsEvery100msOnlyWhileRunning() {
        // Running from 0.24 s: 12 unsettled polls 20 ms apart.
        let harness = Harness(mode: .listen(seconds: 10)) {
            $0.preparation = .settling
            $0.settlesAfterPolls = 12
        }
        harness.run.begin()
        harness.fixture.scheduler.advance(by: 0.2)
        #expect(harness.terminal.meters.isEmpty)

        harness.fixture.scheduler.advance(by: 0.85)
        #expect(harness.terminal.meters.count == 8)
        #expect(harness.terminal.meters.last == "[....................]   0%  ")

        harness.fixture.engine.emit(.inputLevel(0.4))
        harness.fixture.scheduler.advance(by: 0.1)
        #expect(harness.terminal.meters.last == "[########............]  40%  ")

        // A restart that stays in .starting stops the redraws.
        harness.fixture.engine.preparation = .settling
        harness.fixture.engine.settlesAfterPolls = 1000
        harness.fixture.engine.emit(.restartNeeded)
        harness.fixture.scheduler.runUntilIdle()
        let meterCount = harness.terminal.meters.count
        harness.fixture.scheduler.advance(by: 0.5)
        #expect(harness.terminal.meters.count == meterCount)
    }

    @Test func finishIsReportedOnce() {
        let harness = Harness(mode: .listen(seconds: 2))
        harness.run.begin()

        harness.fixture.audio.simulateDeviceRemoved()
        harness.run.interrupt()
        harness.fixture.scheduler.advance(by: 5)

        #expect(harness.terminal.lines.last == "failed: input device unavailable")
        #expect(harness.codes == [1])
    }
}
