// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import QuadcastKit
import SwiftUI

/// Microphone gain/mute and headphone-monitoring volume/mute — the same
/// Core Audio controls as System Settings → Sound, kept in sync with the
/// mic's gain knob and other apps.
struct AudioPage: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            if !state.audio.isAvailable {
                Section {
                    Label(state.audioStatusText, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Microphone") {
                LabeledContent("Gain") {
                    levelRow(
                        value: $state.micGain,
                        text: state.micGainText,
                        minimumImage: "mic",
                        maximumImage: "mic.fill"
                    )
                }
                Toggle("Mute microphone", isOn: $state.isMicMuted)
            }
            .disabled(!state.micControlsEnabled)

            Section("Headphone Monitoring") {
                LabeledContent("Volume") {
                    levelRow(
                        value: $state.monitorVolume,
                        text: state.monitorVolumeText,
                        minimumImage: "speaker.wave.1",
                        maximumImage: "speaker.wave.3"
                    )
                }
                Toggle("Mute monitoring", isOn: $state.isMonitorMuted)
            }
            .disabled(!state.monitorControlsEnabled)

            Section {
                Text("These are the QuadCast S's system audio controls. The gain knob on the mic and other apps change them too; MacMic follows along. The polar pattern is a physical knob and can't be set from software.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func levelRow(
        value: Binding<Float>,
        text: String,
        minimumImage: String,
        maximumImage: String
    ) -> some View {
        HStack(spacing: 12) {
            Slider(value: value, in: 0...1) {
                EmptyView()
            } minimumValueLabel: {
                Image(systemName: minimumImage)
            } maximumValueLabel: {
                Image(systemName: maximumImage)
            }
            Text(text)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
        }
    }
}
