// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

/// An RGB color with 8-bit channels, as sent to the QuadCast S.
public struct RGBColor: Equatable, Sendable {
    public var r: UInt8
    public var g: UInt8
    public var b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Parses a `RRGGBB` or `#RRGGBB` hex string. Returns `nil` for any
    /// other length or non-hex characters.
    public init?(hex: String) {
        var digits = Substring(hex)
        if digits.hasPrefix("#") {
            digits = digits.dropFirst()
        }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            return nil
        }
        self.r = UInt8((value >> 16) & 0xFF)
        self.g = UInt8((value >> 8) & 0xFF)
        self.b = UInt8(value & 0xFF)
    }

    /// Returns this color with each channel multiplied by `brightness`,
    /// which is clamped to `0...1` before scaling.
    public func scaled(brightness: Double) -> RGBColor {
        let clamped = min(max(brightness, 0), 1)
        func scale(_ channel: UInt8) -> UInt8 {
            UInt8((Double(channel) * clamped).rounded())
        }
        return RGBColor(r: scale(r), g: scale(g), b: scale(b))
    }
}
