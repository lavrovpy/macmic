// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import QuadcastKit
import SwiftUI

/// Connection status and the master lighting switch.
struct DevicePage: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section("Microphone") {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(state.isConnected ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        Text(state.connectionStatusText)
                    }
                }
                Toggle("Lighting enabled", isOn: $state.isEnabled)
                    .disabled(!state.controlsEnabled)
            }

            Section {
                Text("The QuadCast S does not remember its colors. MacMic keeps sending frames while it runs, so the lighting returns to the mic's default when MacMic quits or the toggle above is off.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
