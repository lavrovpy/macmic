// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import QuadcastKit
import SwiftUI

/// Paints a device color as a SwiftUI swatch, in sRGB (the space the device
/// bytes are authored in).
func color(from rgbColor: QuadcastKit.RGBColor) -> Color {
    Color(.sRGB, red: Double(rgbColor.r) / 255, green: Double(rgbColor.g) / 255, blue: Double(rgbColor.b) / 255, opacity: 1)
}
