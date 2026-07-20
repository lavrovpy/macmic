// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import QuadcastKit
import SwiftUI

/// UI-facing derivations from `AppState`'s core (persistence/hotplug) model,
/// kept separate so the menu bar view model stays a thin, testable layer on
/// top of Task 7's `AppState`.
extension AppState {
    /// The default speed used when switching to a preset (Rainbow Cycle,
    /// Blink) from the menu bar buttons.
    static let defaultPresetSpeed = 50

    /// The color shown by the `ColorPicker`. Reflects the current mode's
    /// color when it's `.solid`; otherwise falls back to white so switching
    /// back to Solid from a preset starts from a sensible default. Setting
    /// it switches `mode` to `.solid`.
    public var solidColor: Color {
        get {
            if case .solid(let rgb) = mode {
                return color(from: rgb)
            }
            return .white
        }
        set {
            mode = .solid(rgbColor(from: newValue))
        }
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
