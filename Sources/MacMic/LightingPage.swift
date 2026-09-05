// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import QuadcastKit
import SwiftUI

/// Mode picker, the active mode's color/speed controls, and brightness.
/// Color editing is inline (`InlineColorEditor`) rather than `ColorPicker`
/// so no floating Colors panel ever opens next to the window.
struct LightingPage: View {
    @ObservedObject var state: AppState
    /// Which blink color the inline editor is editing. Clamped on read so a
    /// removal never leaves it pointing past the end.
    @State private var selectedBlinkIndex = 0

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: $state.modeKind) {
                    ForEach(LightModeKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            switch state.modeKind {
            case .solid:
                Section("Color") {
                    InlineColorEditor(color: $state.solidRGB)
                }
            case .cycle:
                Section("Speed") {
                    speedSlider
                }
            case .blink:
                Section("Colors") {
                    blinkSwatchStrip
                    InlineColorEditor(color: blinkColorBinding(at: clampedBlinkIndex))
                }
                Section("Speed") {
                    speedSlider
                }
            }

            Section("Brightness") {
                Slider(value: $state.brightness, in: 0...1) {
                    EmptyView()
                } minimumValueLabel: {
                    Image(systemName: "sun.min")
                } maximumValueLabel: {
                    Image(systemName: "sun.max")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!state.controlsEnabled)
    }

    private var speedSlider: some View {
        Slider(value: presetSpeedBinding, in: presetSpeedBounds) {
            EmptyView()
        } minimumValueLabel: {
            Image(systemName: "tortoise")
        } maximumValueLabel: {
            Image(systemName: "hare")
        }
    }

    private var presetSpeedBounds: ClosedRange<Double> {
        Double(AppState.presetSpeedRange.lowerBound)...Double(AppState.presetSpeedRange.upperBound)
    }

    /// `Slider` needs a floating-point binding; the model stores an `Int`.
    private var presetSpeedBinding: Binding<Double> {
        Binding(
            get: { Double(state.presetSpeed) },
            set: { state.presetSpeed = Int($0.rounded()) }
        )
    }

    // MARK: Blink colors

    private var clampedBlinkIndex: Int {
        min(selectedBlinkIndex, max(state.blinkColors.count - 1, 0))
    }

    private var blinkSwatchStrip: some View {
        HStack(spacing: 8) {
            ForEach(Array(state.blinkColors.enumerated()), id: \.offset) { index, rgb in
                ColorSwatch(color: rgb, isSelected: index == clampedBlinkIndex) {
                    selectedBlinkIndex = index
                }
                .accessibilityLabel("Blink color \(index + 1)")
            }
            Spacer()
            Button {
                var colors = state.blinkColors
                colors.remove(at: clampedBlinkIndex)
                state.blinkColors = colors
                selectedBlinkIndex = min(clampedBlinkIndex, colors.count - 1)
            } label: {
                Image(systemName: "minus")
            }
            .disabled(state.blinkColors.count == 1)
            .accessibilityLabel("Remove selected blink color")
            Button {
                var colors = state.blinkColors
                colors.append(colors[clampedBlinkIndex])
                state.blinkColors = colors
                selectedBlinkIndex = colors.count - 1
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add blink color")
        }
    }

    private func blinkColorBinding(at index: Int) -> Binding<QuadcastKit.RGBColor> {
        Binding(
            get: {
                let colors = state.blinkColors
                return index < colors.count ? colors[index] : state.lastSolidColor
            },
            set: { newColor in
                var colors = state.blinkColors
                guard index < colors.count else { return }
                colors[index] = newColor
                state.blinkColors = colors
            }
        )
    }
}
