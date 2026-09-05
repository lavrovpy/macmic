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

            Section {
                LabeledContent("Listen") {
                    Button(state.isMicTestRunning ? "Stop Test" : "Start Test") {
                        if state.isMicTestRunning {
                            state.stopMicTest()
                        } else {
                            state.startMicTest()
                        }
                    }
                }
                LabeledContent("Level") {
                    LevelMeter(level: state.micTestLevel)
                }
                Text(state.micTestStatusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                LabeledContent("Record") {
                    HStack(spacing: 8) {
                        Button {
                            if state.isMicRecording {
                                state.stopMicRecording()
                            } else {
                                state.startMicRecording()
                            }
                        } label: {
                            Label(
                                state.isMicRecording ? "Stop Recording" : "Record",
                                systemImage: state.isMicRecording ? "stop.fill" : "record.circle"
                            )
                        }
                        .disabled(!state.micRecordControlsEnabled)
                        Button {
                            if state.isMicPlaying {
                                state.stopMicPlayback()
                            } else {
                                state.playMicRecording()
                            }
                        } label: {
                            Label(
                                state.isMicPlaying ? "Stop" : "Play",
                                systemImage: state.isMicPlaying ? "stop.fill" : "play.fill"
                            )
                        }
                        .disabled(!state.micPlayControlsEnabled)
                    }
                }
                Text(state.micRecorderStatusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if state.isMicrophoneAccessDenied {
                    Button("Open System Settings") {
                        NSWorkspace.shared.open(Self.microphonePrivacySettingsURL)
                    }
                }
            } header: {
                Text("Test Microphone")
            } footer: {
                Text("Plays the microphone through your current output device so you can hear gain changes, or record up to \(Int(state.micMaxClipDuration)) seconds and play it back. Use headphones to avoid feedback while listening live.")
            }
            .disabled(!state.micTestControlsEnabled)

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
        // The pass-through is only meaningful while the user is looking at
        // the gain slider; leaving the page (or closing the window) ends it.
        .onDisappear { state.stopMicTest() }
    }

    private static let microphonePrivacySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

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

/// Horizontal input level bar: green up to -18 dBFS-ish (0.7), yellow to
/// 0.9, red above — the conventional "you're clipping" bands.
private struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * CGFloat(min(max(level, 0), 1)))
            }
        }
        .frame(height: 8)
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int((level * 100).rounded())) percent")
    }

    private var color: Color {
        switch level {
        case ..<0.7: return .green
        case ..<0.9: return .yellow
        default: return .red
        }
    }
}
