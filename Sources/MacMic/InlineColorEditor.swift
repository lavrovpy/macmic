// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import QuadcastKit
import SwiftUI

/// A color editor that lives entirely inside the window: a row of preset
/// swatches, R/G/B sliders, and a hex field. Replaces `ColorPicker`, whose
/// system Colors panel is a separate floating window.
struct InlineColorEditor: View {
    @Binding var color: QuadcastKit.RGBColor
    /// Text of the hex field, kept separate from `color` so a half-typed
    /// value isn't rewritten under the user; applied as soon as it parses.
    @State private var hexText = ""

    static let swatches: [QuadcastKit.RGBColor] = [
        "FFFFFF", "FF0000", "FF6A00", "FFD500", "00FF00", "00FFAA",
        "00FFFF", "0080FF", "0000FF", "8000FF", "FF00FF", "FF0080",
    ].compactMap { QuadcastKit.RGBColor(hex: $0) }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(Self.swatches.enumerated()), id: \.offset) { _, swatch in
                ColorSwatch(color: swatch, isSelected: swatch == color) {
                    color = swatch
                }
                .accessibilityLabel("Preset color \(swatch.hexString)")
            }
        }

        channelSlider("Red", \.r, tint: .red)
        channelSlider("Green", \.g, tint: .green)
        channelSlider("Blue", \.b, tint: .blue)

        LabeledContent("Hex") {
            HStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(MacMic.color(from: color))
                    .frame(width: 28, height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                TextField("Hex", text: $hexText, prompt: Text("RRGGBB"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(commitHex)
            }
        }
        .onAppear { hexText = color.hexString }
        .onChange(of: color) { newColor in
            if QuadcastKit.RGBColor(hex: hexText) != newColor {
                hexText = newColor.hexString
            }
        }
        .onChange(of: hexText) { text in
            if let parsed = QuadcastKit.RGBColor(hex: text), parsed != color {
                color = parsed
            }
        }
    }

    private func commitHex() {
        hexText = (QuadcastKit.RGBColor(hex: hexText) ?? color).hexString
    }

    private func channelSlider(_ title: String, _ channel: WritableKeyPath<QuadcastKit.RGBColor, UInt8>, tint: Color) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: channelBinding(channel), in: 0...255)
                    .tint(tint)
                Text("\(color[keyPath: channel])")
                    .font(.body.monospacedDigit())
                    .frame(width: 32, alignment: .trailing)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func channelBinding(_ channel: WritableKeyPath<QuadcastKit.RGBColor, UInt8>) -> Binding<Double> {
        Binding(
            get: { Double(color[keyPath: channel]) },
            set: { color[keyPath: channel] = UInt8(min(max($0.rounded(), 0), 255)) }
        )
    }
}

/// A clickable color square; the selected one gets an accent ring.
struct ColorSwatch: View {
    let color: QuadcastKit.RGBColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 5)
                .fill(MacMic.color(from: color))
                .frame(width: 22, height: 22)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.accentColor, lineWidth: 2)
                            .padding(-2)
                    }
                }
        }
        .buttonStyle(.plain)
    }
}
