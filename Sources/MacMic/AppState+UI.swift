// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import QuadcastKit

/// UI-facing derivations from `AppState`'s audio state, shared by the status
/// menu and the main window's pages.
extension AppState {
    /// Microphone gain (`0...1`); `0` while the input device is absent.
    public var micGain: Float {
        get { audio.input?.volume ?? 0 }
        set { setAudioVolume(newValue, for: .input) }
    }

    /// The mic's system input mute; `false` while the input device is absent.
    public var isMicMuted: Bool {
        get { audio.input?.isMuted ?? false }
        set { setAudioMuted(newValue, for: .input) }
    }

    /// Headphone-monitoring volume (`0...1`); `0` while the output device is absent.
    public var monitorVolume: Float {
        get { audio.output?.volume ?? 0 }
        set { setAudioVolume(newValue, for: .output) }
    }

    /// Headphone-monitoring mute; `false` while the output device is absent.
    public var isMonitorMuted: Bool {
        get { audio.output?.isMuted ?? false }
        set { setAudioMuted(newValue, for: .output) }
    }

    /// Whether the gain slider and mic mute toggle should be enabled.
    /// Independent of lighting presence.
    public var micControlsEnabled: Bool {
        audio.input != nil
    }

    /// Whether the monitoring volume slider and mute toggle should be enabled.
    public var monitorControlsEnabled: Bool {
        audio.output != nil
    }

    /// Human-readable audio availability line, the audio counterpart of
    /// `Lighting.statusText`.
    public var audioStatusText: String {
        audio.isAvailable ? "Audio device connected" : "Audio device not found"
    }

    public var micGainText: String {
        Self.levelText(audio.input)
    }

    public var monitorVolumeText: String {
        Self.levelText(audio.output)
    }

    /// `"68% (+2.1 dB)"`; `"68%"` when the device reports no dB; `"—"` when
    /// the direction is absent.
    static func levelText(_ level: AudioLevel?) -> String {
        guard let level else { return "—" }
        let percent = "\(Int((level.volume * 100).rounded()))%"
        guard let decibels = level.decibels else { return percent }
        return "\(percent) (\(String(format: "%+.1f", decibels)) dB)"
    }
}
