// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import AppKit
import SwiftUI
import Testing
@testable import MacMic
@testable import QuadcastKit

@Suite struct ColorConversionTests {
    @Test func colorFromRGBColorUsesSRGBComponents() throws {
        let rgb = RGBColor(r: 200, g: 10, b: 128)

        let components = try #require(NSColor(color(from: rgb)).usingColorSpace(.sRGB))

        #expect(abs(components.redComponent - 200.0 / 255) < 0.0001)
        #expect(abs(components.greenComponent - 10.0 / 255) < 0.0001)
        #expect(abs(components.blueComponent - 128.0 / 255) < 0.0001)
        #expect(components.alphaComponent == 1)
    }
}
