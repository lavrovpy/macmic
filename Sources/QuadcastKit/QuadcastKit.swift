// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
//
// The protocol layer in this package is ported from QuadcastRGB
// (https://github.com/Ors1mer/QuadcastRGB), Copyright (C) 2022-2025 Ors1mer,
// licensed GPLv2-only. See LICENSE for the full license text.

/// Library entry point for QuadcastKit: the QuadCast S RGB protocol and HID
/// transport layer, kept separate from any UI so it can be reused by both
/// the menu bar app and the `macmic-cli` diagnostic tool.
public enum QuadcastKit {
    public static let version = "0.1.0"
}
