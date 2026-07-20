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

/// Converts a SwiftUI `ColorPicker` selection to the `RGBColor` sent to the
/// device, via `NSColor`'s sRGB component space (SwiftUI `Color` has no
/// direct RGB accessor). Pure and hardware-independent so it's testable
/// without a menu bar.
func rgbColor(from color: Color) -> QuadcastKit.RGBColor {
    let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
    func channel(_ value: CGFloat) -> UInt8 {
        UInt8(min(max((value * 255).rounded(), 0), 255))
    }
    return QuadcastKit.RGBColor(r: channel(nsColor.redComponent), g: channel(nsColor.greenComponent), b: channel(nsColor.blueComponent))
}

/// The inverse of `rgbColor(from:)`, used to show the device's current solid
/// color back in the `ColorPicker`.
func color(from rgbColor: QuadcastKit.RGBColor) -> Color {
    Color(.sRGB, red: Double(rgbColor.r) / 255, green: Double(rgbColor.g) / 255, blue: Double(rgbColor.b) / 255, opacity: 1)
}
