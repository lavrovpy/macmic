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

/// The `MenuBarExtra` popover content: enable toggle, solid-color picker,
/// preset buttons, brightness slider, and connection status. Controls are
/// grayed out whenever no QuadCast HID/USB service is matched.
struct ContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(state.isConnected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(state.connectionStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Enabled", isOn: $state.isEnabled)
                .disabled(!state.controlsEnabled)

            ColorPicker("Color", selection: $state.solidColor, supportsOpacity: false)
                .disabled(!state.controlsEnabled)

            HStack {
                Button("Solid") { state.mode = .solid(state.lastSolidColor) }
                Button("Rainbow Cycle") { state.mode = .cycle(speed: AppState.defaultPresetSpeed) }
                Button("Blink") {
                    state.mode = .blink(colors: [rgbColor(from: state.solidColor)], speed: AppState.defaultPresetSpeed)
                }
            }
            .disabled(!state.controlsEnabled)

            VStack(alignment: .leading) {
                Text("Brightness")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $state.brightness, in: 0...1)
            }
            .disabled(!state.controlsEnabled)

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .padding()
        .frame(width: 240)
    }
}
