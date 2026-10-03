// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import CoreAudio
import Foundation

enum MicrophoneAccess: Equatable {
    case authorized, notDetermined, denied, restricted
}

enum MicrophoneEnginePreparation: Equatable {
    case ready
    /// A nominal rate was written to the input; poll `isSettled` before `start`.
    case settling
    case failed(MicrophoneTestError)
}

enum MicrophoneEngineEvent: Equatable {
    /// Normalized input level, throttled to at most 25 Hz.
    case inputLevel(Float)
    /// The default output changed, or `AVAudioEngineConfigurationChange`
    /// arrived with the engine stopped.
    case restartNeeded
}

/// AVFoundation / HAL / TCC execution for `MicrophoneTestSession` — no
/// policy, no generations. Main thread only. Every callback (events, the
/// access completion, `onFull`, `onLevel`, `onFinished`) arrives on main,
/// never from inside a call on this protocol, and may still arrive after the
/// `stop()`/`stopRecording()`/`stopPlayback()` that ended its source; the
/// caller discards stale ones.
protocol MicrophoneEngine: AnyObject {
    func microphoneAccess() -> MicrophoneAccess
    func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void)

    /// Requires stopped. Validates `input`, resolves the default output and
    /// watches it (change → `.restartNeeded`), pins the input's nominal rate
    /// to the output's when supported (never restored). `.settling` = a rate
    /// was written; poll `isSettled`. `events` serves this run until `stop()`.
    func prepare(input: AudioObjectID, events: @escaping (MicrophoneEngineEvent) -> Void) -> MicrophoneEnginePreparation
    /// The pinned rate reads back (`true` when nothing was pinned).
    func isSettled(input: AudioObjectID) -> Bool
    /// After `prepare`: private aggregate of `input` + the resolved output,
    /// bound, tapped, started → the output's name.
    func start(input: AudioObjectID) -> Result<String?, MicrophoneTestError>
    /// Releases everything since `prepare` (listener, observer, taps, engine,
    /// aggregate destroyed). Ends playback; a recording in progress becomes
    /// the clip; the clip survives. Idempotent.
    func stop()

    /// Running only. Replaces the clip with a recording capped at
    /// `maxDuration` (no roll-over); `onFull` once if the cap is reached.
    /// `false` (not running / allocation failed) → previous clip kept.
    func startRecording(maxDuration: TimeInterval, onFull: @escaping () -> Void) -> Bool
    /// The clip's duration, or `nil` (and no clip) when nothing was captured.
    func stopRecording() -> TimeInterval?
    var recordedDuration: TimeInterval { get }
    func discardClip()

    /// Running with a clip and not playing. Mutes the live input; `onLevel`
    /// reports the clip; `onFinished` once it has played out.
    func startPlayback(onLevel: @escaping (Float) -> Void, onFinished: @escaping () -> Void) -> Bool
    /// Removes the player tap, stops the player, restores the input volume.
    /// Idempotent.
    func stopPlayback()
    var playbackPosition: TimeInterval { get }
}
