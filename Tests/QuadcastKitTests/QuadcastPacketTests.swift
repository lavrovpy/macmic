// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Testing
@testable import QuadcastKit

@Suite struct QuadcastPacketTests {
    @Test func headerPacketByteExact() {
        var expected = [UInt8](repeating: 0, count: 64)
        expected[0] = 0x04
        expected[1] = 0xF2
        expected[8] = 0x01
        #expect(QuadcastPacket.headerPacket() == expected)
    }

    @Test func headerPacketIsSixtyFourBytes() {
        #expect(QuadcastPacket.headerPacket().count == 64)
    }
}

@Suite struct RGBColorTests {
    @Test func hexStringRoundTripsThroughHexInit() throws {
        let color = RGBColor(r: 0x0A, g: 0xBC, b: 0xFF)
        #expect(color.hexString == "0ABCFF")
        #expect(RGBColor(hex: color.hexString) == color)
    }

    @Test func hexParsingSucceedsWithoutHash() {
        #expect(RGBColor(hex: "FF0000") == RGBColor(r: 0xFF, g: 0, b: 0))
    }

    @Test func hexParsingSucceedsWithHash() {
        #expect(RGBColor(hex: "#00FF00") == RGBColor(r: 0, g: 0xFF, b: 0))
    }

    @Test func hexParsingIsCaseInsensitive() {
        #expect(RGBColor(hex: "0000ff") == RGBColor(r: 0, g: 0, b: 0xFF))
    }

    @Test func hexParsingFailsOnWrongLength() {
        #expect(RGBColor(hex: "FFF") == nil)
        #expect(RGBColor(hex: "FFFFFFF") == nil)
        #expect(RGBColor(hex: "") == nil)
    }

    @Test func hexParsingFailsOnNonHexCharacters() {
        #expect(RGBColor(hex: "GGGGGG") == nil)
    }

    @Test func brightnessScalingVectors() {
        let white = RGBColor(r: 255, g: 255, b: 255)
        #expect(white.scaled(brightness: 0) == RGBColor(r: 0, g: 0, b: 0))
        #expect(white.scaled(brightness: 0.5) == RGBColor(r: 128, g: 128, b: 128))
        #expect(white.scaled(brightness: 1) == RGBColor(r: 255, g: 255, b: 255))
    }

    @Test func brightnessScalingClampsOutOfRangeInput() {
        let white = RGBColor(r: 255, g: 255, b: 255)
        #expect(white.scaled(brightness: -1) == RGBColor(r: 0, g: 0, b: 0))
        #expect(white.scaled(brightness: 2) == RGBColor(r: 255, g: 255, b: 255))
    }
}

@Suite struct FrameTests {
    @Test func solidRedFrameDataPacketByteExact() {
        let red = RGBColor(r: 0xFF, g: 0, b: 0)
        let frame = Frame(color: red)
        var expected: [UInt8] = [0x81, 0xFF, 0x00, 0x00, 0x81, 0xFF, 0x00, 0x00]
        expected.append(contentsOf: [UInt8](repeating: 0, count: 56))
        #expect(frame.dataPacket() == expected)
    }

    @Test func dataPacketIsSixtyFourBytes() {
        #expect(Frame(color: RGBColor(r: 1, g: 2, b: 3)).dataPacket().count == 64)
    }

    @Test func twoZoneFrameEncodesEachZoneIndependently() {
        let frame = Frame(upper: RGBColor(r: 10, g: 20, b: 30), lower: RGBColor(r: 40, g: 50, b: 60))
        var expected: [UInt8] = [0x81, 10, 20, 30, 0x81, 40, 50, 60]
        expected.append(contentsOf: [UInt8](repeating: 0, count: 56))
        #expect(frame.dataPacket() == expected)
    }

    @Test func scaledFrameHalvesBothZones() {
        let frame = Frame(color: RGBColor(r: 255, g: 255, b: 255))
        let scaled = frame.scaled(brightness: 0.5)
        #expect(scaled.upper == RGBColor(r: 128, g: 128, b: 128))
        #expect(scaled.lower == RGBColor(r: 128, g: 128, b: 128))
    }
}
