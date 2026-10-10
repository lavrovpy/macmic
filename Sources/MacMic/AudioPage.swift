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
    @ObservedObject var audio: AudioControls
    /// Not observed; see `MicrophoneTestSection`.
    let microphoneTest: MicrophoneTest

    var body: some View {
        Form {
            if !audio.isAvailable {
                Section {
                    Label(audio.statusText, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Microphone") {
                LabeledContent("Gain") {
                    levelRow(
                        value: $audio.micGain,
                        text: audio.micGainText,
                        minimumImage: "mic",
                        maximumImage: "mic.fill"
                    )
                }
                Toggle("Mute microphone", isOn: $audio.isMicMuted)
            }
            .disabled(!audio.micControlsEnabled)

            MicrophoneTestSection(test: microphoneTest)

            Section("Headphone Monitoring") {
                LabeledContent("Volume") {
                    levelRow(
                        value: $audio.monitorVolume,
                        text: audio.monitorVolumeText,
                        minimumImage: "speaker.wave.1",
                        maximumImage: "speaker.wave.3"
                    )
                }
                Toggle("Mute monitoring", isOn: $audio.isMonitorMuted)
            }
            .disabled(!audio.monitorControlsEnabled)
        }
        .formStyle(.grouped)
        // Warning: keep this on the `Form`, not on a `Section`. Grouped-Form
        // sections are lazy rows whose `onDisappear` fires on scroll.
        .onDisappear { microphoneTest.audioPageDidDisappear() }
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

/// The Test Microphone section. The only view that observes
/// `MicrophoneTest`, so the level tick re-renders nothing else.
private struct MicrophoneTestSection: View {
    @ObservedObject var test: MicrophoneTest

    var body: some View {
        Section {
            LabeledContent("Listen") {
                Button(test.isActive ? "Stop Test" : "Start Test") {
                    test.toggleTest()
                }
            }
            LabeledContent("Level") {
                LevelMeter(level: test.level)
            }
            Text(test.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
            LabeledContent("Record") {
                HStack(spacing: 8) {
                    Button {
                        test.toggleRecording()
                    } label: {
                        Label(
                            test.isRecording ? "Stop Recording" : "Record",
                            systemImage: test.isRecording ? "stop.fill" : "record.circle"
                        )
                    }
                    .disabled(!test.recordButtonEnabled)
                    Button {
                        test.togglePlayback()
                    } label: {
                        Label(
                            test.isPlaying ? "Stop" : "Play",
                            systemImage: test.isPlaying ? "stop.fill" : "play.fill"
                        )
                    }
                    .disabled(!test.playButtonEnabled)
                }
            }
            Text(test.recorderStatusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            if test.isMicrophoneAccessDenied {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(Self.microphonePrivacySettingsURL)
                }
            }
        } header: {
            Text("Test Microphone")
        } footer: {
            Text("Use headphones — the live test plays the microphone through your current output.")
        }
        .disabled(!test.controlsEnabled)
    }

    private static let microphonePrivacySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
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
