// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import QuadcastKit
import SwiftUI

/// The user-facing choice of lighting mode, without the per-mode payload
/// (`LightMode`'s associated values). Drives the mode `Picker` in the main
/// window's Lighting page and in the status menu.
public enum LightModeKind: String, CaseIterable, Identifiable, Sendable {
    case solid, cycle, blink

    public var id: Self { self }

    public var title: String {
        switch self {
        case .solid: return "Solid"
        case .cycle: return "Rainbow Cycle"
        case .blink: return "Blink"
        }
    }
}

/// UI-facing derivations from `AppState`'s core (persistence/hotplug) model,
/// shared by the status menu and the main window's pages, kept separate so
/// they stay a thin, testable layer on top of Task 7's `AppState`.
extension AppState {
    /// The speed a preset (Rainbow Cycle, Blink) starts at before the user
    /// has ever adjusted it.
    static let defaultPresetSpeed = 50

    /// Inclusive bounds of `presetSpeed`, matching `PresetSequencer`'s
    /// `SPEED_RANGE` clamp.
    static let presetSpeedRange = 0...100

    /// Which kind of mode is active. Setting it switches `mode`, restoring
    /// the remembered payload for the new kind (`lastSolidColor`,
    /// `lastPresetSpeed`, `lastBlinkColors`) so switching between modes
    /// never loses what the user configured for each. Setting the current
    /// kind again is a no-op, so a `Picker` re-selecting the same segment
    /// doesn't restart a running animation.
    public var modeKind: LightModeKind {
        get {
            switch mode {
            case .solid: return .solid
            case .cycle: return .cycle
            case .blink: return .blink
            }
        }
        set {
            guard newValue != modeKind else { return }
            switch newValue {
            case .solid: mode = .solid(lastSolidColor)
            case .cycle: mode = .cycle(speed: lastPresetSpeed)
            case .blink: mode = .blink(colors: blinkColors, speed: lastPresetSpeed)
            }
        }
    }

    /// The active preset's speed (`0...100`, higher is faster), or
    /// `lastPresetSpeed` while `.solid` is active. Setting it updates the
    /// active preset in place (clamped to `presetSpeedRange`); while `.solid`
    /// is active there is nothing to apply it to, so the set is ignored —
    /// the speed control is hidden in that state.
    public var presetSpeed: Int {
        get {
            switch mode {
            case .solid: return lastPresetSpeed
            case .cycle(let speed): return speed
            case .blink(_, let speed): return speed
            }
        }
        set {
            let clamped = PresetSequencer.clampSpeed(newValue)
            switch mode {
            case .solid: break
            case .cycle: mode = .cycle(speed: clamped)
            case .blink(let colors, _): mode = .blink(colors: colors, speed: clamped)
            }
        }
    }

    /// The colors Blink steps through: the active `.blink` list, or
    /// `lastBlinkColors` when another mode is active, or `[lastSolidColor]`
    /// if Blink has never been used. Setting it switches to `.blink` (like
    /// `solidColor` switches to `.solid`), keeping the current `presetSpeed`.
    /// An empty list is rejected because it would play zero frames and leave
    /// the mic dark.
    public var blinkColors: [QuadcastKit.RGBColor] {
        get {
            if case .blink(let colors, _) = mode {
                return colors
            }
            return lastBlinkColors ?? [lastSolidColor]
        }
        set {
            guard !newValue.isEmpty else { return }
            mode = .blink(colors: newValue, speed: presetSpeed)
        }
    }

    /// The solid color the UI edits. Reflects the current mode's color when
    /// it's `.solid`; otherwise falls back to `lastSolidColor` (the last color
    /// picked before switching to a preset) so switching back to Solid
    /// restores what the user had, rather than resetting to white. Setting it
    /// switches `mode` to `.solid`.
    public var solidRGB: QuadcastKit.RGBColor {
        get {
            if case .solid(let rgb) = mode {
                return rgb
            }
            return lastSolidColor
        }
        set {
            mode = .solid(newValue)
        }
    }

    /// `solidRGB` as a SwiftUI `Color`, for views that work in `Color`.
    public var solidColor: Color {
        get { color(from: solidRGB) }
        set { solidRGB = rgbColor(from: newValue) }
    }

    /// Whether the lighting controls (mode picker, color editor, speed and
    /// brightness sliders, enable toggle) should be enabled. Mirrors
    /// `isConnected`; a named, testable derivation rather than inlining
    /// `!isConnected` in the views.
    public var controlsEnabled: Bool {
        isConnected
    }

    /// Human-readable lighting connection status line, shown in the status
    /// menu and on the Device page.
    public var connectionStatusText: String {
        isConnected ? "QuadCast S connected" : "QuadCast S not found"
    }

    // MARK: Audio

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
    /// Independent of `controlsEnabled`, which is lighting only.
    public var micControlsEnabled: Bool {
        audio.input != nil
    }

    /// Whether the monitoring volume slider and mute toggle should be enabled.
    public var monitorControlsEnabled: Bool {
        audio.output != nil
    }

    /// Human-readable audio availability line, the audio counterpart of
    /// `connectionStatusText`.
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

    // MARK: Microphone test

    /// Whether the pass-through is up or coming up — what the Start/Stop
    /// button toggles on.
    public var isMicTestRunning: Bool {
        switch micTestState {
        case .starting, .running: return true
        case .stopped, .failed: return false
        }
    }

    /// Whether the Test Microphone section should be enabled. Same condition
    /// as `micControlsEnabled`; a separate name so the section doesn't
    /// silently inherit gain-control semantics if that ever changes.
    public var micTestControlsEnabled: Bool {
        audio.input != nil
    }

    /// The last start failed on macOS microphone privacy — the one failure
    /// the user fixes in System Settings rather than by retrying.
    public var isMicrophoneAccessDenied: Bool {
        micTestState == .failed(.microphoneAccessDenied)
    }

    public var micTestStatusText: String {
        switch micTestState {
        case .stopped:
            return "Not running"
        case .starting:
            return "Starting…"
        case .running(let outputDeviceName):
            return "Playing through \(outputDeviceName ?? "the default output")"
        case .failed(.microphoneAccessDenied):
            return "Microphone access denied — allow MacMic in System Settings › Privacy & Security › Microphone"
        case .failed(.inputDeviceUnavailable):
            return "Microphone unavailable"
        case .failed(.engineFailed(let detail)):
            return "Failed: \(detail)"
        }
    }
}
