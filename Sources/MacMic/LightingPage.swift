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
    @ObservedObject var lighting: Lighting
    /// Which blink color the inline editor is editing; read through
    /// `blinkIndex(clamping:)`, so it may point past the end.
    @State private var selectedBlinkIndex = 0

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: $lighting.settings.modeKind) {
                    ForEach(LightModeKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            switch lighting.settings.modeKind {
            case .solid:
                Section("Color") {
                    InlineColorEditor(color: $lighting.settings.solidColor)
                }
            case .cycle:
                Section("Speed") {
                    speedSlider
                }
            case .blink:
                Section("Colors") {
                    blinkSwatchStrip
                    InlineColorEditor(color: blinkColorBinding(at: selectedIndex))
                }
                Section("Speed") {
                    speedSlider
                }
            }

            Section("Brightness") {
                Slider(value: $lighting.settings.brightness, in: 0...1) {
                    EmptyView()
                } minimumValueLabel: {
                    Image(systemName: "sun.min")
                } maximumValueLabel: {
                    Image(systemName: "sun.max")
                }
                .accessibilityLabel("Brightness")
                .accessibilityValue("\(Int((lighting.settings.brightness * 100).rounded())) percent")
            }
        }
        .formStyle(.grouped)
        .disabled(!lighting.controlsEnabled)
    }

    private var speedSlider: some View {
        Slider(value: presetSpeedBinding, in: presetSpeedBounds) {
            EmptyView()
        } minimumValueLabel: {
            Image(systemName: "tortoise")
        } maximumValueLabel: {
            Image(systemName: "hare")
        }
        .accessibilityLabel("Speed")
        .accessibilityValue("\(lighting.settings.presetSpeed) of \(LightingSettings.presetSpeedRange.upperBound)")
    }

    private var presetSpeedBounds: ClosedRange<Double> {
        Double(LightingSettings.presetSpeedRange.lowerBound)...Double(LightingSettings.presetSpeedRange.upperBound)
    }

    /// `Slider` needs a floating-point binding; the model stores an `Int`.
    private var presetSpeedBinding: Binding<Double> {
        Binding(
            get: { Double(lighting.settings.presetSpeed) },
            set: { lighting.settings.presetSpeed = Int($0.rounded()) }
        )
    }

    // MARK: Blink colors

    private var selectedIndex: Int {
        lighting.settings.blinkIndex(clamping: selectedBlinkIndex)
    }

    private var blinkSwatchStrip: some View {
        HStack(spacing: 8) {
            ForEach(Array(lighting.settings.blinkColors.enumerated()), id: \.offset) { index, rgb in
                ColorSwatch(color: rgb, isSelected: index == selectedIndex) {
                    selectedBlinkIndex = index
                }
                .accessibilityLabel("Blink color \(index + 1)")
                .accessibilityValue(rgb.hexString)
            }
            Spacer()
            Button {
                if let next = lighting.settings.removeBlinkColor(at: selectedIndex) {
                    selectedBlinkIndex = next
                }
            } label: {
                Image(systemName: "minus")
            }
            .disabled(!lighting.settings.canRemoveBlinkColor)
            .accessibilityLabel("Remove selected blink color")
            Button {
                selectedBlinkIndex = lighting.settings.duplicateBlinkColor(at: selectedIndex)
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add blink color")
        }
    }

    private func blinkColorBinding(at index: Int) -> Binding<QuadcastKit.RGBColor> {
        Binding(
            get: { lighting.settings.blinkColors[lighting.settings.blinkIndex(clamping: index)] },
            set: { lighting.settings.setBlinkColor($0, at: index) }
        )
    }
}
