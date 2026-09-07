// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Foundation
import Testing
@testable import QuadcastKit

/// The restart safety net of `AVAudioEngineMicrophoneMonitor`: an output
/// device that keeps changing its format (AirPods flipping between 48 and
/// 24 kHz every ~1.5 s) must end in a failure, not an endless restart loop.
@Suite struct RestartLimiterTests {
    @Test func allowsUpToTheLimitWithinTheWindow() {
        var limiter = RestartLimiter(limit: 3, window: 10)
        #expect(limiter.allowRestart(at: 100) == true)
        #expect(limiter.allowRestart(at: 101.5) == true)
        #expect(limiter.allowRestart(at: 103) == true)
        #expect(limiter.allowRestart(at: 104.5) == false)
    }

    @Test func restartsOutsideTheWindowNoLongerCount() {
        var limiter = RestartLimiter(limit: 3, window: 10)
        #expect(limiter.allowRestart(at: 100) == true)
        #expect(limiter.allowRestart(at: 101) == true)
        #expect(limiter.allowRestart(at: 102) == true)
        // 100 and 101 have aged out; only 102 is still in the window.
        #expect(limiter.allowRestart(at: 111.5) == true)
        #expect(limiter.allowRestart(at: 112) == true)
        // Now 102 has aged out too, so this is the third in the window.
        #expect(limiter.allowRestart(at: 112.5) == true)
        #expect(limiter.allowRestart(at: 113) == false)
    }

    @Test func spacedOutRestartsNeverTrip() {
        var limiter = RestartLimiter(limit: 3, window: 10)
        for i in 0..<20 {
            #expect(limiter.allowRestart(at: TimeInterval(i) * 4) == true)
        }
    }

    @Test func resetForgetsEverything() {
        var limiter = RestartLimiter(limit: 3, window: 10)
        for time in [100.0, 101, 102] {
            _ = limiter.allowRestart(at: time)
        }
        #expect(limiter.allowRestart(at: 103) == false)

        limiter.reset()

        #expect(limiter.allowRestart(at: 103.5) == true)
    }
}
