// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Foundation
import QuadcastKit

/// One parsed `macmic-cli audio …` invocation.
enum AudioCommand: Equatable {
    case status
    /// `gain` / `monitor`; the value is already converted to `0...1`.
    case setVolume(Float, AudioDirection)
    /// `mute` / `monitor-mute`.
    case setMuted(Bool, AudioDirection)
    /// `test [--seconds N]`: pass the mic through the default output for
    /// this many seconds.
    case test(seconds: Int)
}

let defaultTestSeconds = 10

let audioUsage = """
    Usage:
      macmic-cli audio status
      macmic-cli audio gain <0-100>
      macmic-cli audio mute on|off
      macmic-cli audio monitor <0-100>
      macmic-cli audio monitor-mute on|off
      macmic-cli audio test [--seconds N]
    """

/// `nil` on any malformed form (unknown verb, missing/extra argument, value
/// out of range).
func parseAudioCommand(_ arguments: [String]) -> AudioCommand? {
    if arguments.first == "test" {
        return parseTestSeconds(Array(arguments.dropFirst())).map { .test(seconds: $0) }
    }
    switch arguments.count {
    case 1 where arguments[0] == "status":
        return .status
    case 2:
        switch arguments[0] {
        case "gain":
            return parsePercent(arguments[1]).map { .setVolume($0, .input) }
        case "monitor":
            return parsePercent(arguments[1]).map { .setVolume($0, .output) }
        case "mute":
            return parseOnOff(arguments[1]).map { .setMuted($0, .input) }
        case "monitor-mute":
            return parseOnOff(arguments[1]).map { .setMuted($0, .output) }
        default:
            return nil
        }
    default:
        return nil
    }
}

/// The `--seconds N` option of `audio test`: no arguments →
/// `defaultTestSeconds`; `N` must be a positive integer; any other token
/// (or a bare `--seconds`) → `nil`.
func parseTestSeconds(_ arguments: [String]) -> Int? {
    switch arguments.count {
    case 0:
        return defaultTestSeconds
    case 2 where arguments[0] == "--seconds":
        guard let seconds = Int(arguments[1]), seconds > 0 else { return nil }
        return seconds
    default:
        return nil
    }
}

/// `"0"..."100"` → `0...1`; anything else (non-integer, out of range) → `nil`.
func parsePercent(_ text: String) -> Float? {
    guard let percent = Int(text), (0...100).contains(percent) else {
        return nil
    }
    return Float(percent) / 100
}

/// Exactly `"on"`/`"off"` (case-insensitive) → `true`/`false`; else `nil`.
func parseOnOff(_ text: String) -> Bool? {
    switch text.lowercased() {
    case "on": return true
    case "off": return false
    default: return nil
    }
}

/// Two lines, e.g.
///
///     input  (microphone): gain 68% (+2.1 dB), mute off
///     output (monitoring): volume 81% (-12.1 dB), mute off
///
/// An absent direction prints `not found`.
func formatAudioStatus(_ snapshot: AudioDeviceSnapshot) -> String {
    let input = formatLevel(snapshot.input, valueName: "gain")
    let output = formatLevel(snapshot.output, valueName: "volume")
    return "input  (microphone): \(input)\noutput (monitoring): \(output)"
}

private func formatLevel(_ level: AudioLevel?, valueName: String) -> String {
    guard let level else { return "not found" }
    let percent = Int((level.volume * 100).rounded())
    var text = "\(valueName) \(percent)%"
    if let decibels = level.decibels {
        text += String(format: " (%+.1f dB)", decibels)
    }
    text += ", mute \(level.isMuted ? "on" : "off")"
    return text
}

/// One line describing a `MicrophoneMonitor` transition, e.g.
/// `running: playing through AirPods Pro`.
func formatMonitorState(_ state: MicrophoneMonitorState) -> String {
    switch state {
    case .stopped:
        return "stopped"
    case .starting:
        return "starting…"
    case let .running(outputDeviceName):
        return "running: playing through \(outputDeviceName ?? "default output")"
    case .failed(.microphoneAccessDenied):
        return "failed: microphone access denied (System Settings > Privacy & Security > Microphone)"
    case .failed(.inputDeviceUnavailable):
        return "failed: input device unavailable"
    case let .failed(.engineFailed(reason)):
        return "failed: audio engine error: \(reason)"
    }
}

/// A fixed-width text meter for a normalized `0...1` level, e.g.
/// `[########............]  40%`; the width never changes so it can be
/// redrawn in place with `\r`.
func formatLevelMeter(_ level: Float, cells: Int = 20) -> String {
    let clamped = min(max(level, 0), 1)
    let filled = Int((clamped * Float(cells)).rounded())
    let bar = String(repeating: "#", count: filled) + String(repeating: ".", count: cells - filled)
    return String(format: "[%@] %3d%%", bar, Int((clamped * 100).rounded()))
}
