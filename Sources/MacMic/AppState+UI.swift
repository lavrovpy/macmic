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
/// (`LightMode`'s associated values). Drives the mode `Picker` in the
/// settings window and the preset buttons in the menu bar popover.
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
/// kept separate so the menu bar view model stays a thin, testable layer on
/// top of Task 7's `AppState`.
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

    /// Whether interactive controls (color picker, preset buttons,
    /// brightness slider) should be enabled. Mirrors `isConnected`; a named,
    /// testable derivation rather than inlining `!isConnected` in the view.
    public var controlsEnabled: Bool {
        isConnected
    }

    /// Human-readable connection status line shown in the popover.
    public var connectionStatusText: String {
        isConnected ? "QuadCast S connected" : "QuadCast S not found"
    }
}
