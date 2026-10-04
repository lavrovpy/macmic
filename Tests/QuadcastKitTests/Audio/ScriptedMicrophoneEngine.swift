// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import CoreAudio
import Foundation
import Testing
@testable import QuadcastKit

/// In-memory `MicrophoneEngine`: records every call, answers from scripted
/// values, and invokes callbacks only from the test-facing `answer…`,
/// `emit…`, `fill…` and `finish…` methods — never from inside a port call.
/// Port preconditions the session must honour are checked with
/// `Issue.record`. On `stop()` (and on `stopRecording`/`stopPlayback` for
/// their own callbacks) the current callbacks become the "previous" ones, as
/// does a pending access completion that a new `requestMicrophoneAccess`
/// replaces, so a test can deliver a stale callback the way the real engine
/// may.
final class ScriptedMicrophoneEngine: MicrophoneEngine {
    enum Call: Equatable {
        case microphoneAccess, requestMicrophoneAccess, prepare(input: AudioObjectID), isSettled
        case start(input: AudioObjectID), stop, startRecording(maxDuration: TimeInterval), stopRecording
        case discardClip, startPlayback, stopPlayback
    }

    var access: MicrophoneAccess = .authorized
    var preparation: MicrophoneEnginePreparation = .ready
    /// `isSettled` returns `false` this many times after each `prepare`, then `true`.
    var settlesAfterPolls = 0
    var startResult: Result<String?, MicrophoneTestError> = .success("MacBook Pro Speakers")
    /// Reset to 0 by `startRecording`; set it to model progress.
    var recordedDuration: TimeInterval = 0
    /// Reset to 0 by `startPlayback`; set it to model progress.
    var playbackPosition: TimeInterval = 0
    var canAllocateClip = true

    private(set) var calls: [Call] = []
    private(set) var isPrepared = false
    private(set) var isRunning = false
    private(set) var isRecording = false
    private(set) var isPlaying = false
    private(set) var clipDuration: TimeInterval?

    private var preparedInput: AudioObjectID?
    private var polls = 0
    private var maxDuration: TimeInterval = 0
    private var pendingAccess: ((Bool) -> Void)?
    private var previousAccess: ((Bool) -> Void)?
    private var events: ((MicrophoneEngineEvent) -> Void)?
    private var previousEvents: ((MicrophoneEngineEvent) -> Void)?
    private var onFull: (() -> Void)?
    private var previousOnFull: (() -> Void)?
    private var onLevel: ((Float) -> Void)?
    private var previousOnLevel: ((Float) -> Void)?
    private var onFinished: (() -> Void)?
    private var previousOnFinished: (() -> Void)?

    func count(of call: Call) -> Int {
        calls.filter { $0 == call }.count
    }

    /// The input of every `prepare` call, in order.
    var preparedInputs: [AudioObjectID] {
        calls.compactMap { if case .prepare(let input) = $0 { return input } else { return nil } }
    }

    /// The input of every `start` call, in order.
    var startedInputs: [AudioObjectID] {
        calls.compactMap { if case .start(let input) = $0 { return input } else { return nil } }
    }

    // MARK: MicrophoneEngine

    func microphoneAccess() -> MicrophoneAccess {
        calls.append(.microphoneAccess)
        return access
    }

    func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        calls.append(.requestMicrophoneAccess)
        if let pendingAccess {
            previousAccess = pendingAccess
        }
        pendingAccess = completion
    }

    func prepare(input: AudioObjectID, events: @escaping (MicrophoneEngineEvent) -> Void) -> MicrophoneEnginePreparation {
        calls.append(.prepare(input: input))
        if isPrepared {
            Issue.record("prepare while prepared")
        }
        if case .failed = preparation {
            return preparation
        }
        isPrepared = true
        preparedInput = input
        polls = 0
        self.events = events
        return preparation
    }

    func isSettled(input: AudioObjectID) -> Bool {
        calls.append(.isSettled)
        if !isPrepared {
            Issue.record("isSettled before prepare")
        }
        polls += 1
        return polls > settlesAfterPolls
    }

    func start(input: AudioObjectID) -> Result<String?, MicrophoneTestError> {
        calls.append(.start(input: input))
        if !isPrepared || preparedInput != input {
            Issue.record("start(input: \(input)) without prepare(input: \(input))")
        }
        if case .success = startResult {
            isRunning = true
        }
        return startResult
    }

    func stop() {
        calls.append(.stop)
        if isRecording {
            finishRecording()
        }
        if isPlaying {
            endPlayback()
        }
        if let events {
            previousEvents = events
        }
        events = nil
        isPrepared = false
        isRunning = false
        preparedInput = nil
    }

    func startRecording(maxDuration: TimeInterval, onFull: @escaping () -> Void) -> Bool {
        calls.append(.startRecording(maxDuration: maxDuration))
        if !isRunning || isRecording {
            Issue.record("startRecording while \(isRunning ? "recording" : "not running")")
            return false
        }
        guard canAllocateClip else { return false }
        isRecording = true
        clipDuration = nil
        recordedDuration = 0
        self.maxDuration = maxDuration
        self.onFull = onFull
        return true
    }

    func stopRecording() -> TimeInterval? {
        calls.append(.stopRecording)
        finishRecording()
        return clipDuration
    }

    func discardClip() {
        calls.append(.discardClip)
        clipDuration = nil
    }

    func startPlayback(onLevel: @escaping (Float) -> Void, onFinished: @escaping () -> Void) -> Bool {
        calls.append(.startPlayback)
        if !isRunning || clipDuration == nil || isPlaying || isRecording {
            Issue.record("startPlayback refused: running \(isRunning), clip \(String(describing: clipDuration)), playing \(isPlaying), recording \(isRecording)")
            return false
        }
        isPlaying = true
        playbackPosition = 0
        self.onLevel = onLevel
        self.onFinished = onFinished
        return true
    }

    func stopPlayback() {
        calls.append(.stopPlayback)
        endPlayback()
    }

    // MARK: Test-facing triggers

    func answerAccessPrompt(_ granted: Bool) {
        guard let completion = pendingAccess else {
            Issue.record("no access prompt pending")
            return
        }
        pendingAccess = nil
        completion(granted)
    }

    func answerPreviousAccessPrompt(_ granted: Bool) {
        guard let completion = previousAccess else {
            Issue.record("answerPreviousAccessPrompt without a replaced access prompt")
            return
        }
        previousAccess = nil
        completion(granted)
    }

    func emit(_ event: MicrophoneEngineEvent) {
        guard let events else {
            Issue.record("emit(\(event)) without a prepared run")
            return
        }
        events(event)
    }

    func emitFromPreviousRun(_ event: MicrophoneEngineEvent) {
        guard let previousEvents else {
            Issue.record("emitFromPreviousRun(\(event)) without a previous run")
            return
        }
        previousEvents(event)
    }

    /// The recording reaches its cap: `recordedDuration` becomes the
    /// requested `maxDuration` and `onFull` fires once.
    func fillRecording() {
        guard isRecording, let onFull else {
            Issue.record("fillRecording while not recording")
            return
        }
        recordedDuration = maxDuration
        self.onFull = nil
        onFull()
    }

    func fillPreviousRecording() {
        guard let previousOnFull else {
            Issue.record("fillPreviousRecording without a previous recording")
            return
        }
        previousOnFull()
    }

    func emitPlaybackLevel(_ value: Float) {
        guard let onLevel else {
            Issue.record("emitPlaybackLevel while not playing")
            return
        }
        onLevel(value)
    }

    func emitPreviousPlaybackLevel(_ value: Float) {
        guard let previousOnLevel else {
            Issue.record("emitPreviousPlaybackLevel without a previous playback")
            return
        }
        previousOnLevel(value)
    }

    func finishPlayback() {
        guard let onFinished else {
            Issue.record("finishPlayback while not playing")
            return
        }
        onFinished()
    }

    func finishPreviousPlayback() {
        guard let previousOnFinished else {
            Issue.record("finishPreviousPlayback without a previous playback")
            return
        }
        previousOnFinished()
    }

    // MARK: Private

    private func finishRecording() {
        clipDuration = recordedDuration > 0 ? recordedDuration : nil
        isRecording = false
        if let onFull {
            previousOnFull = onFull
        }
        onFull = nil
    }

    private func endPlayback() {
        isPlaying = false
        if let onLevel {
            previousOnLevel = onLevel
        }
        if let onFinished {
            previousOnFinished = onFinished
        }
        onLevel = nil
        onFinished = nil
    }
}
