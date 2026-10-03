// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import CoreAudio
import Dispatch
import Foundation

/// "Test Microphone": the QuadCast input passed through the system default
/// output, metered, with one clip. Owns lifecycle, permission mapping, input
/// resolution (through `AudioDeviceControl` at start and on every restart),
/// the rate-settle poll, restart coalescing and limiting, recorder phases,
/// level gating and source switching, progress, auto-stop, and invalidation
/// of stale engine callbacks.
///
/// Main thread only. Callbacks fire synchronously inside the command, engine
/// callback, timer or control delivery that caused them, once state is
/// final; a callback may issue commands. Fails with `.inputDeviceUnavailable`
/// when the mic disappears while starting or running; restarts on a changed
/// mic id, a default-output change or a configuration loss; never starts on
/// its own.
///
/// Warning: callbacks may stop or restart the session from inside
/// `publish`, so any work after a `publish` re-checks `generation`/`stage`.
public final class MicrophoneTestSession {
    public static let maxClipDuration: TimeInterval = 30
    static let restartLimit = 3
    static let restartWindow: TimeInterval = 10
    static let settlePollInterval: TimeInterval = 0.02
    static let settlePollLimit = 50
    static let progressInterval: TimeInterval = 0.1

    public var onStatusChanged: ((MicrophoneTestStatus) -> Void)?
    /// ≤25 Hz: the input while `.running`, the clip while playing; one final
    /// `0` after leaving `.running`.
    public var onLevel: ((Float) -> Void)?
    public private(set) var status: MicrophoneTestStatus
    public private(set) var level: Float = 0

    private enum Stage {
        case inactive, awaitingAccess, settling, running
    }

    private let audioControl: AudioDeviceControl
    private let engine: MicrophoneEngine
    private let scheduler: Scheduler
    private var stage = Stage.inactive
    private var generation = 0
    private var recordingGeneration = 0
    private var playbackGeneration = 0
    private var boundInput: AudioObjectID?
    private var clip: TimeInterval?
    private var lastOutputName: String?
    private var limiter = RestartLimiter(limit: restartLimit, window: restartWindow)
    private var restartWork: ScheduledWork?
    private var settleWork: ScheduledWork?
    private var progressWork: ScheduledWork?
    private var observation: AudioDeviceObservation?

    public convenience init(audioControl: AudioDeviceControl) {
        self.init(audioControl: audioControl, engine: AVAudioEngineMicrophoneEngine(), scheduler: DispatchScheduler())
    }

    init(audioControl: AudioDeviceControl, engine: MicrophoneEngine, scheduler: Scheduler) {
        self.audioControl = audioControl
        self.engine = engine
        self.scheduler = scheduler
        status = MicrophoneTestStatus(
            phase: .stopped,
            recorder: .idle(clipDuration: nil),
            isInputAvailable: audioControl.snapshot.deviceIDs[.input] != nil
        )
        observation = audioControl.observe { [weak self] in self?.controlDidChange($0) }
    }

    deinit {
        restartWork?.cancel()
        settleWork?.cancel()
        progressWork?.cancel()
        engine.stop()
        engine.discardClip()
    }

    // MARK: - Commands

    /// Ignored while active.
    public func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard stage == .inactive else { return }
        limiter.reset()
        lastOutputName = nil
        engine.discardClip()
        clip = nil
        guard audioControl.snapshot.deviceIDs[.input] != nil else {
            return fail(.inputDeviceUnavailable, inputAvailable: false)
        }
        switch engine.microphoneAccess() {
        case .denied, .restricted: return fail(.microphoneAccessDenied)
        case .authorized: stage = .settling
        case .notDetermined: stage = .awaitingAccess
        }
        generation += 1
        let g = generation
        publish(MicrophoneTestStatus(phase: .starting, recorder: .idle(clipDuration: nil), isInputAvailable: true))
        guard generation == g else { return }
        if stage == .awaitingAccess {
            engine.requestMicrophoneAccess { [weak self] granted in
                guard let self, self.generation == g, self.stage == .awaitingAccess else { return }
                if granted {
                    self.begin()
                } else {
                    self.fail(.microphoneAccessDenied)
                }
            }
        } else {
            begin()
        }
    }

    /// → `.stopped`, emitted only on a real change; drops the clip.
    public func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard stage != .inactive || status.phase != .stopped else { return }
        endRun(keepingClip: false)
        stage = .inactive
        publish(MicrophoneTestStatus(
            phase: .stopped, recorder: .idle(clipDuration: nil), isInputAvailable: status.isInputAvailable
        ))
        resetLevel()
    }

    /// No-op unless `status.canStartRecording`.
    public func startRecording() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard status.canStartRecording else { return }
        recordingGeneration += 1
        let g = generation, r = recordingGeneration
        guard engine.startRecording(maxDuration: Self.maxClipDuration, onFull: { [weak self] in
            guard let self, self.generation == g, self.recordingGeneration == r else { return }
            self.stopRecording()
        }) else { return }
        clip = nil
        startProgress()
        var next = status
        next.recorder = .recording(elapsed: 0)
        publish(next)
    }

    /// No-op unless recording.
    public func stopRecording() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard status.isRecording else { return }
        progressWork?.cancel()
        progressWork = nil
        recordingGeneration += 1
        clip = engine.stopRecording()
        var next = status
        next.recorder = .idle(clipDuration: clip)
        publish(next)
    }

    /// No-op unless `status.canStartPlayback`.
    public func startPlayback() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard status.canStartPlayback, let clip else { return }
        playbackGeneration += 1
        let g = generation, p = playbackGeneration
        guard engine.startPlayback(
            onLevel: { [weak self] value in
                guard let self, self.generation == g, self.playbackGeneration == p else { return }
                self.setLevel(value)
            },
            onFinished: { [weak self] in
                guard let self, self.generation == g, self.playbackGeneration == p else { return }
                self.endPlayback()
            }
        ) else { return }
        startProgress()
        var next = status
        next.recorder = .playing(elapsed: 0, clipDuration: clip)
        publish(next)
    }

    /// No-op unless playing; keeps the clip.
    public func stopPlayback() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard status.isPlaying else { return }
        endPlayback()
    }

    // MARK: - Starting

    /// After access is granted; also on every restart. Reads the input id
    /// afresh: the HAL reassigns it whenever the audio function re-enumerates.
    private func begin() {
        stage = .settling
        guard let input = audioControl.snapshot.deviceIDs[.input] else {
            return fail(.inputDeviceUnavailable, inputAvailable: false)
        }
        boundInput = input
        let g = generation
        let preparation = engine.prepare(input: input) { [weak self] event in
            guard let self, self.generation == g else { return }
            switch event {
            case .inputLevel(let value):
                if self.stage == .running, !self.status.isPlaying {
                    self.setLevel(value)
                }
            case .restartNeeded:
                self.requestRestart()
            }
        }
        switch preparation {
        case .ready: launch()
        case .settling: awaitSettled(input: input, waitsLeft: Self.settlePollLimit)
        case .failed(let error): fail(error)
        }
    }

    /// Checks now, then every `settlePollInterval`; launches anyway after
    /// `settlePollLimit` waits (1.0 s).
    private func awaitSettled(input: AudioObjectID, waitsLeft: Int) {
        guard !engine.isSettled(input: input), waitsLeft > 0 else { return launch() }
        let g = generation
        settleWork = scheduler.schedule(after: Self.settlePollInterval) { [weak self] in
            guard let self, self.generation == g, self.stage == .settling else { return }
            self.awaitSettled(input: input, waitsLeft: waitsLeft - 1)
        }
    }

    private func launch() {
        settleWork = nil
        guard let input = boundInput else { return }
        switch engine.start(input: input) {
        case .success(let name):
            stage = .running
            lastOutputName = name
            publish(MicrophoneTestStatus(
                phase: .running(outputDeviceName: name), recorder: .idle(clipDuration: clip), isInputAvailable: true
            ))
        case .failure(let error):
            fail(error)
        }
    }

    // MARK: - Control deliveries and restarts

    private func controlDidChange(_ snapshot: AudioDeviceSnapshot) {
        dispatchPrecondition(condition: .onQueue(.main))
        let input = snapshot.deviceIDs[.input]
        if stage != .inactive, input == nil {
            return fail(.inputDeviceUnavailable, inputAvailable: false)
        }
        var next = status
        next.isInputAvailable = input != nil
        publish(next)
        if stage == .settling || stage == .running, let bound = boundInput, input != bound {
            requestRestart()
        }
    }

    /// Coalesced per main-queue turn: triggers tend to arrive together.
    private func requestRestart() {
        guard stage == .settling || stage == .running, restartWork == nil else { return }
        restartWork = scheduler.schedule(after: 0) { [weak self] in self?.performRestart() }
    }

    private func performRestart() {
        restartWork = nil
        guard stage == .settling || stage == .running else { return }
        guard limiter.allowRestart(at: scheduler.now) else {
            let device = lastOutputName.map { "output device \($0)" } ?? "the output device"
            return fail(.engineFailed("\(device) keeps changing its audio format"))
        }
        endRun(keepingClip: true)
        stage = .settling
        let g = generation
        // One value: a recording cut by the restart reports its clip together
        // with `.starting`, never as an idle-while-running in between.
        publish(MicrophoneTestStatus(
            phase: .starting, recorder: .idle(clipDuration: clip), isInputAvailable: status.isInputAvailable
        ))
        resetLevel()
        guard generation == g, stage == .settling else { return }
        begin()
    }

    // MARK: - Ending

    /// Cancels timers, keeps a partial recording as the clip, cuts playback,
    /// stops the engine, invalidates callbacks.
    private func endRun(keepingClip: Bool) {
        restartWork?.cancel()
        restartWork = nil
        settleWork?.cancel()
        settleWork = nil
        progressWork?.cancel()
        progressWork = nil
        if status.isRecording {
            clip = engine.stopRecording()
        }
        recordingGeneration += 1
        playbackGeneration += 1
        if status.isPlaying {
            engine.stopPlayback()
        }
        engine.stop()
        if !keepingClip {
            engine.discardClip()
            clip = nil
        }
        generation += 1
        boundInput = nil
    }

    private func fail(_ error: MicrophoneTestError, inputAvailable: Bool? = nil) {
        endRun(keepingClip: false)
        stage = .inactive
        publish(MicrophoneTestStatus(
            phase: .failed(error),
            recorder: .idle(clipDuration: nil),
            isInputAvailable: inputAvailable ?? status.isInputAvailable
        ))
        resetLevel()
    }

    private func endPlayback() {
        progressWork?.cancel()
        progressWork = nil
        playbackGeneration += 1
        engine.stopPlayback()
        var next = status
        next.recorder = .idle(clipDuration: clip)
        publish(next)
    }

    // MARK: - Publishing

    /// The only place `status` changes.
    private func publish(_ new: MicrophoneTestStatus) {
        assert(new.satisfiesInvariants, "invalid microphone test status \(new)")
        guard new != status else { return }
        status = new
        onStatusChanged?(new)
    }

    private func setLevel(_ value: Float) {
        guard stage == .running else { return }
        level = value
        onLevel?(value)
    }

    private func resetLevel() {
        guard level != 0 else { return }
        level = 0
        onLevel?(0)
    }

    /// Call before the publish that enters recording or playing: a callback
    /// may end that phase at once, and only a timer already armed gets
    /// cancelled by it.
    private func startProgress() {
        progressWork?.cancel()
        progressWork = scheduler.scheduleRepeating(every: Self.progressInterval) { [weak self] in
            guard let self else { return }
            var next = self.status
            switch next.recorder {
            case .recording:
                next.recorder = .recording(elapsed: self.engine.recordedDuration)
            case .playing(_, let duration):
                next.recorder = .playing(elapsed: min(self.engine.playbackPosition, duration), clipDuration: duration)
            case .idle:
                return
            }
            self.publish(next)
        }
    }
}

/// Sliding-window count of engine restarts: the first `limit` restarts in
/// any `window` are allowed, the next one is refused, so an output that
/// keeps changing its format (AirPods flipping between 48 and 24 kHz) ends
/// the test instead of cycling it forever.
private struct RestartLimiter {
    let limit: Int
    let window: TimeInterval
    private var restartTimes: [TimeInterval] = []

    init(limit: Int, window: TimeInterval) {
        self.limit = limit
        self.window = window
    }

    /// Records a restart at `time` and reports whether it may go ahead.
    mutating func allowRestart(at time: TimeInterval) -> Bool {
        restartTimes.removeAll { time - $0 > window }
        restartTimes.append(time)
        return restartTimes.count <= limit
    }

    mutating func reset() {
        restartTimes.removeAll()
    }
}
