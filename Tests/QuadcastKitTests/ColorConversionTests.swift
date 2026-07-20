// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import SwiftUI
import Testing
@testable import MacMic
@testable import QuadcastKit

@Suite struct ColorConversionTests {
    @Test func redConvertsToFullRedChannel() throws {
        // `Color.red` is Apple's semantic systemRed, not pure (255,0,0); use
        // an explicit sRGB literal for a byte-exact vector.
        let red = Color(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)
        #expect(rgbColor(from: red) == RGBColor(r: 0xFF, g: 0, b: 0))
    }

    @Test func whiteConvertsToAllChannelsMax() throws {
        #expect(rgbColor(from: .white) == RGBColor(r: 0xFF, g: 0xFF, b: 0xFF))
    }

    @Test func blackConvertsToAllChannelsZero() throws {
        #expect(rgbColor(from: .black) == RGBColor(r: 0, g: 0, b: 0))
    }

    @Test func roundsToNearestByteRatherThanTruncating() throws {
        // 128/255 ≈ 0.50196, which should round-trip back to exactly 128,
        // not truncate down to 127.
        let color = Color(.sRGB, red: 128.0 / 255, green: 64.0 / 255, blue: 32.0 / 255, opacity: 1)
        #expect(rgbColor(from: color) == RGBColor(r: 128, g: 64, b: 32))
    }

    @Test func colorFromRGBColorRoundTripsThroughRgbColor() throws {
        let original = RGBColor(r: 200, g: 10, b: 90)
        #expect(rgbColor(from: color(from: original)) == original)
    }
}
