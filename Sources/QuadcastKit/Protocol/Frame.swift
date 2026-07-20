// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
//
// The data packet layout below is ported from QuadcastRGB
// (https://github.com/Ors1mer/QuadcastRGB) modules/rgbmodes.c,
// Copyright (C) 2022-2025 Ors1mer, licensed GPLv2-only.
// See LICENSE for the full license text.

/// One display frame: an upper-zone color and a lower-zone color, encoded
/// as a single 64-byte data packet.
public struct Frame: Equatable, Sendable {
    public var upper: RGBColor
    public var lower: RGBColor

    public init(upper: RGBColor, lower: RGBColor) {
        self.upper = upper
        self.lower = lower
    }

    /// Convenience initializer for a frame where both zones show the same color.
    public init(color: RGBColor) {
        self.upper = color
        self.lower = color
    }

    /// The 64-byte data packet: `81 Ru Gu Bu 81 Rl Gl Bl` followed by zero
    /// padding. `0x81` (RGB_CODE) marks each 4-byte zone command.
    public func dataPacket() -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: QuadcastPacket.packetSize)
        packet[0] = 0x81
        packet[1] = upper.r
        packet[2] = upper.g
        packet[3] = upper.b
        packet[4] = 0x81
        packet[5] = lower.r
        packet[6] = lower.g
        packet[7] = lower.b
        return packet
    }

    /// Returns this frame with both zone colors scaled by `brightness`
    /// (clamped to `0...1`).
    public func scaled(brightness: Double) -> Frame {
        Frame(upper: upper.scaled(brightness: brightness), lower: lower.scaled(brightness: brightness))
    }
}
