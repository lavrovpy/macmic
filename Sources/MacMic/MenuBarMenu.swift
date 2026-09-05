// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import AppKit
import QuadcastKit
import SwiftUI

/// The status item's pull-down menu: connection status, the enable toggle,
/// a mode submenu, the mic mute toggle, and the entry point to the main
/// window. Deliberately a plain menu rather than a popover so the app has
/// exactly one window.
struct MenuBarMenu: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(state.connectionStatusText)

        Toggle("Lighting Enabled", isOn: $state.isEnabled)
            .disabled(!state.controlsEnabled)

        Picker("Mode", selection: $state.modeKind) {
            ForEach(LightModeKind.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }
        .disabled(!state.controlsEnabled)

        // No keyboard shortcut: MenuBarExtra shortcuts only work while the
        // menu is open, so one would only suggest a global hotkey that
        // doesn't exist.
        Toggle("Mute Microphone", isOn: $state.isMicMuted)
            .disabled(!state.micControlsEnabled)

        Divider()

        Button("Open MacMic…") {
            showMainWindow(openWindow)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit MacMic") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
