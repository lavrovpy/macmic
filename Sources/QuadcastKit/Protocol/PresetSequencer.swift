// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
//
// The sequence-generation formulas below are ported from QuadcastRGB
// (https://github.com/Ors1mer/QuadcastRGB) modules/rgbmodes.c
// (sequence_cycle, sequence_blink, count_cycle_data, count_blink_data),
// Copyright (C) 2022-2025 Ors1mer, licensed GPLv2-only.
// See LICENSE for the full license text.

/// A lighting mode the QuadCast S display loop can be driven with.
public enum LightMode: Equatable, Sendable {
    case solid(RGBColor)
    case cycle(speed: Int)
    case blink(colors: [RGBColor], speed: Int)
}

/// Manual `Codable` conformance (enums with associated values aren't
/// synthesized) so `AppState` can persist the last-used mode to
/// `UserDefaults`.
extension LightMode: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, color, colors, speed
    }

    private enum Kind: String, Codable {
        case solid, cycle, blink
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .solid:
            self = .solid(try container.decode(RGBColor.self, forKey: .color))
        case .cycle:
            self = .cycle(speed: try container.decode(Int.self, forKey: .speed))
        case .blink:
            self = .blink(
                colors: try container.decode([RGBColor].self, forKey: .colors),
                speed: try container.decode(Int.self, forKey: .speed)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .solid(let color):
            try container.encode(Kind.solid, forKey: .kind)
            try container.encode(color, forKey: .color)
        case .cycle(let speed):
            try container.encode(Kind.cycle, forKey: .kind)
            try container.encode(speed, forKey: .speed)
        case .blink(let colors, let speed):
            try container.encode(Kind.blink, forKey: .kind)
            try container.encode(colors, forKey: .colors)
            try container.encode(speed, forKey: .speed)
        }
    }
}

/// Expands a `LightMode` into the deterministic, host-precomputed `[Frame]`
/// sequence the `FrameStreamer` plays back at ~18 fps (one frame per 55 ms
/// tick). No randomness in v1: QuadcastRGB's blink-random variant is
/// intentionally not ported.
public enum PresetSequencer {
    /// `MIN_CYCL_TR` / `MAX_CYCL_TR` from rgbmodes.h: the gradient transition
    /// length (in frames) between two key colors, at min/max speed.
    static let minCycleTransition = 12
    static let maxCycleTransition = 128

    /// Fixed six-hue rainbow wheel used by the "Rainbow Cycle" preset.
    static let rainbowPalette: [RGBColor] = [
        RGBColor(r: 0xFF, g: 0x00, b: 0x00), // red
        RGBColor(r: 0xFF, g: 0xFF, b: 0x00), // yellow
        RGBColor(r: 0x00, g: 0xFF, b: 0x00), // green
        RGBColor(r: 0x00, g: 0xFF, b: 0xFF), // cyan
        RGBColor(r: 0x00, g: 0x00, b: 0xFF), // blue
        RGBColor(r: 0xFF, g: 0x00, b: 0xFF), // magenta
    ]

    public static func frames(for mode: LightMode) -> [Frame] {
        switch mode {
        case .solid(let color):
            return [Frame(color: color)]
        case .cycle(let speed):
            return cycleFrames(speed: speed)
        case .blink(let colors, let speed):
            return blinkFrames(colors: colors, speed: speed)
        }
    }

    /// `SPEED_RANGE(MIN, MAX, SPD)` from rgbmodes.h, clamped to `0...100`.
    public static func clampSpeed(_ speed: Int) -> Int {
        min(max(speed, 0), 100)
    }

    /// Ports `get_gradient_length`: the frame count of one color-to-color
    /// transition. Lower speed => longer (slower) transitions.
    static func transitionLength(speed: Int) -> Int {
        let clamped = clampSpeed(speed)
        return minCycleTransition + (maxCycleTransition - minCycleTransition) * (100 - clamped) / 100
    }

    /// Ports `sequence_cycle`: chains a gradient from each palette color to
    /// the next, wrapping the last color back to the first so the sequence
    /// loops smoothly.
    private static func cycleFrames(speed: Int) -> [Frame] {
        let colors = rainbowPalette
        guard !colors.isEmpty else { return [] }
        let length = transitionLength(speed: speed)
        guard length >= 2 else { return [] }

        var frames: [Frame] = []
        frames.reserveCapacity(length * colors.count)
        for index in colors.indices {
            let start = colors[index]
            let end = colors[(index + 1) % colors.count]
            frames.append(contentsOf: gradient(from: start, to: end, length: length))
        }
        return frames
    }

    /// Ports `write_gradient`: `length` frames interpolating linearly from
    /// `start` to `end`; the first frame is exactly `start`, the last is
    /// exactly `end`.
    private static func gradient(from start: RGBColor, to end: RGBColor, length: Int) -> [Frame] {
        var frames: [Frame] = []
        frames.reserveCapacity(length)
        for step in 0..<length {
            let t = Double(step) / Double(length - 1)
            let color = RGBColor(
                r: interpolate(start.r, end.r, t),
                g: interpolate(start.g, end.g, t),
                b: interpolate(start.b, end.b, t)
            )
            frames.append(Frame(color: color))
        }
        return frames
    }

    private static func interpolate(_ start: UInt8, _ end: UInt8, _ t: Double) -> UInt8 {
        UInt8(Double(start) + t * (Double(end) - Double(start)))
    }

    /// Ports `sequence_blink`: each color lights for `101 - speed` frames,
    /// then a black delay segment plays. QuadcastRGB exposes the delay as a
    /// separate `dly` parameter (0-100); `LightMode.blink` only exposes
    /// `speed`, so the delay segment reuses the on-segment length for a
    /// symmetric on/off blink.
    private static func blinkFrames(colors: [RGBColor], speed: Int) -> [Frame] {
        guard !colors.isEmpty else { return [] }
        let onCount = 101 - clampSpeed(speed)
        let offCount = onCount
        let off = RGBColor(r: 0, g: 0, b: 0)

        var frames: [Frame] = []
        frames.reserveCapacity((onCount + offCount) * colors.count)
        for color in colors {
            frames.append(contentsOf: Array(repeating: Frame(color: color), count: onCount))
            frames.append(contentsOf: Array(repeating: Frame(color: off), count: offCount))
        }
        return frames
    }
}
