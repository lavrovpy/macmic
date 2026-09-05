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
}

let audioUsage = """
    Usage:
      macmic-cli audio status
      macmic-cli audio gain <0-100>
      macmic-cli audio mute on|off
      macmic-cli audio monitor <0-100>
      macmic-cli audio monitor-mute on|off
    """

/// `nil` on any malformed form (unknown verb, missing/extra argument, value
/// out of range).
func parseAudioCommand(_ arguments: [String]) -> AudioCommand? {
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
