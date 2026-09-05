// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import CoreAudio
import Foundation

/// Why a `MicrophoneMonitor` could not (or can no longer) pass the mic through.
public enum MicrophoneMonitorError: Error, Equatable, Sendable {
    /// macOS microphone privacy permission is denied or restricted for this
    /// process; the user has to change it in System Settings.
    case microphoneAccessDenied
    /// The requested input device reports no channels / no sample rate,
    /// which is how a just-unplugged device looks to `AVAudioEngine`.
    case inputDeviceUnavailable
    /// `AVAudioEngine` failed to prepare, start, or restart; the payload is
    /// the underlying error's description, for display.
    case engineFailed(String)
}

public enum MicrophoneMonitorState: Equatable, Sendable {
    case stopped
    /// `start` was called; permission and engine setup are in flight.
    case starting
    /// Passing audio through. `outputDeviceName` is the system default
    /// output device's name at the time the engine started (`nil` if Core
    /// Audio didn't report one).
    case running(outputDeviceName: String?)
    case failed(MicrophoneMonitorError)
}

/// Live pass-through of a Core Audio input device to the system's current
/// default output, plus an input level meter — so the user can hear the
/// QuadCast S through AirPods/a headset while adjusting its gain, instead
/// of plugging headphones into the mic. `AVAudioEngineMicrophoneMonitor` is
/// the production adapter; `MockMicrophoneMonitor` (test target) is used in
/// unit tests.
public protocol MicrophoneMonitor: AnyObject {
    /// Invoked on the main thread on every state transition, including the
    /// synchronous `.starting` from `start` and `.stopped` from `stop`.
    var onStateChanged: ((MicrophoneMonitorState) -> Void)? { get set }
    /// Normalized input level (`0...1`, see `AudioLevelMeter`), on the main
    /// thread, only while `.running`, at a rate an on-screen meter can draw
    /// (the adapter decimates its per-buffer readings) rather than per buffer.
    var onLevel: ((Float) -> Void)? { get set }
    var state: MicrophoneMonitorState { get }

    /// Begins pass-through from `inputDevice`. The outcome arrives via
    /// `onStateChanged` (`.running` or `.failed`); `.starting` is delivered
    /// before this returns. Calling it while already starting/running stops
    /// the current session and restarts on the new device.
    func start(inputDevice: AudioObjectID)
    /// Synchronous; ends in `.stopped`. Safe to call when already stopped.
    func stop()
}

/// Pure level-meter math, kept separate from the engine so it can be unit
/// tested against known sample buffers.
public enum AudioLevelMeter {
    /// RMS of the buffer; `0` for an empty buffer.
    public static func rootMeanSquare(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    public static func rootMeanSquare(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { rootMeanSquare($0) }
    }

    /// Maps an RMS amplitude to `0...1` linearly in decibels: `floorDecibels`
    /// dBFS and below → `0`, full scale (0 dBFS) and above → `1`. A dB scale
    /// rather than raw amplitude is used because speech at a normal gain sits
    /// around -30…-12 dBFS, which would barely move a linear meter.
    public static func normalizedLevel(rms: Float, floorDecibels: Float = -60) -> Float {
        guard rms > 0, floorDecibels < 0 else { return rms >= 1 ? 1 : 0 }
        let decibels = 20 * log10(rms)
        let level = (decibels - floorDecibels) / -floorDecibels
        return min(max(level, 0), 1)
    }
}
