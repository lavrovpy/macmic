// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
//
// The header packet layout below is ported from QuadcastRGB
// (https://github.com/Ors1mer/QuadcastRGB) modules/devio.c,
// Copyright (C) 2022-2025 Ors1mer, licensed GPLv2-only.
// See LICENSE for the full license text.

/// Raw 64-byte HID feature report layout shared by every packet sent to the
/// QuadCast S display-mode endpoint.
public enum QuadcastPacket {
    /// Every feature report to the QuadCast S is exactly 64 bytes.
    public static let packetSize = 64

    /// The packet that must precede every data packet in the display loop:
    /// `04 F2 00 00 00 00 00 00 01` followed by zero padding.
    public static func headerPacket() -> [UInt8] {
        var packet = [UInt8](repeating: 0, count: packetSize)
        packet[0] = 0x04 // HEADER_CODE
        packet[1] = 0xF2 // DISPLAY_CODE
        packet[8] = 0x01 // PACKET_CNT
        return packet
    }
}
