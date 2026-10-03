// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Foundation

/// Pure level-meter math, kept separate from the engine so it can be unit
/// tested against known sample buffers.
public enum AudioLevelMeter {
    /// RMS of the buffer; `0` for an empty buffer.
    public static func rootMeanSquare(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        return (sum / Float(samples.count)).squareRoot()
    }

    public static func rootMeanSquare(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { rootMeanSquare($0) }
    }

    /// Maps an RMS amplitude to `0...1` linearly in decibels: `floorDecibels`
    /// dBFS and below → `0`, full scale (0 dBFS) and above → `1`. A dB scale
    /// rather than raw amplitude is used because speech at a normal gain sits
    /// around -30…-12 dBFS, which would barely move a linear meter.
    public static func normalizedLevel(rms: Float, floorDecibels: Float = -60) -> Float {
        guard rms > 0, floorDecibels < 0 else { return rms >= 1 ? 1 : 0 }
        let decibels = 20 * log10(rms)
        let level = (decibels - floorDecibels) / -floorDecibels
        return min(max(level, 0), 1)
    }
}

/// Decimates per-buffer levels to a delivery rate: at most one value per
/// `interval`, carrying the peak of the buffers since the last delivery
/// (so a short burst between deliveries still shows), and nothing while
/// that peak is within `epsilon` of the last delivered value. Pure, so the
/// rate policy is unit-testable without an engine.
struct LevelThrottle {
    let interval: TimeInterval
    let epsilon: Float
    private var peak: Float = 0
    private var lastDelivered: Float?
    private var lastDeliveryTime: TimeInterval = -.infinity

    init(interval: TimeInterval, epsilon: Float) {
        self.interval = interval
        self.epsilon = epsilon
    }

    /// Feeds one buffer's level; returns the value to deliver, or `nil`.
    mutating func consume(_ level: Float, at time: TimeInterval) -> Float? {
        peak = max(peak, level)
        guard time - lastDeliveryTime >= interval else { return nil }
        let value = peak
        peak = 0
        if let lastDelivered, abs(value - lastDelivered) < epsilon { return nil }
        lastDelivered = value
        lastDeliveryTime = time
        return value
    }
}
