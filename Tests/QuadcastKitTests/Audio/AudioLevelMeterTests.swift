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

@Suite struct AudioLevelMeterTests {
    @Test func rootMeanSquareOfEmptyBufferIsZero() {
        #expect(AudioLevelMeter.rootMeanSquare([]) == 0)
    }

    @Test func rootMeanSquareOfSilenceIsZero() {
        #expect(AudioLevelMeter.rootMeanSquare([Float](repeating: 0, count: 1024)) == 0)
    }

    @Test func rootMeanSquareOfFullScaleSquareWaveIsOne() {
        let samples: [Float] = (0..<1024).map { $0 % 2 == 0 ? 1 : -1 }
        #expect(AudioLevelMeter.rootMeanSquare(samples) == 1)
    }

    @Test func rootMeanSquareOfSineIsAmplitudeOverRootTwo() {
        let samples: [Float] = (0..<4800).map { index in
            let phase = Double(index) / 4800 * 2 * Double.pi * 10
            return Float(0.5 * sin(phase))
        }
        let rms = AudioLevelMeter.rootMeanSquare(samples)
        #expect(abs(rms - 0.5 / Float(2).squareRoot()) < 0.001)
    }

    @Test func rootMeanSquareAcceptsAnUnsafeBufferPointer() {
        let samples: [Float] = [0.5, -0.5, 0.5, -0.5]
        let rms = samples.withUnsafeBufferPointer { AudioLevelMeter.rootMeanSquare($0) }
        #expect(rms == 0.5)
    }

    @Test func normalizedLevelMapsSilenceToZeroAndFullScaleToOne() {
        #expect(AudioLevelMeter.normalizedLevel(rms: 0) == 0)
        #expect(AudioLevelMeter.normalizedLevel(rms: 1) == 1)
    }

    @Test func normalizedLevelIsLinearInDecibels() {
        // -30 dBFS is exactly halfway between the -60 dB floor and 0 dBFS.
        let minus30dB = Float(pow(10.0, -30.0 / 20.0))
        #expect(abs(AudioLevelMeter.normalizedLevel(rms: minus30dB) - 0.5) < 0.001)
        // -6 dBFS (0.5 amplitude) → 0.9 with a -60 dB floor.
        #expect(abs(AudioLevelMeter.normalizedLevel(rms: 0.5) - 0.8998) < 0.001)
    }

    @Test func normalizedLevelClampsBelowFloorAndAboveFullScale() {
        #expect(AudioLevelMeter.normalizedLevel(rms: 1e-6) == 0)
        #expect(AudioLevelMeter.normalizedLevel(rms: 2) == 1)
    }

    @Test func normalizedLevelHonoursCustomFloor() {
        // With a -20 dB floor, -10 dBFS is the midpoint.
        let minus10dB = Float(pow(10.0, -10.0 / 20.0))
        #expect(abs(AudioLevelMeter.normalizedLevel(rms: minus10dB, floorDecibels: -20) - 0.5) < 0.001)
        #expect(AudioLevelMeter.normalizedLevel(rms: 0.05, floorDecibels: -20) == 0)
    }
}

@Suite struct LevelThrottleTests {
    @Test func deliversTheFirstLevelImmediately() {
        var throttle = LevelThrottle(interval: 0.04, epsilon: 0.005)
        #expect(throttle.consume(0.3, at: 10) == 0.3)
    }

    @Test func holdsBackWithinTheIntervalAndCarriesThePeak() {
        var throttle = LevelThrottle(interval: 0.04, epsilon: 0.005)
        #expect(throttle.consume(0.3, at: 10) == 0.3)
        #expect(throttle.consume(0.9, at: 10.02) == nil)
        #expect(throttle.consume(0.5, at: 10.03) == nil)
        // The burst to 0.9 between deliveries is what gets delivered, not
        // the 0.5 the interval happened to expire on.
        #expect(throttle.consume(0.5, at: 10.05) == 0.9)
    }

    @Test func skipsAValueWithinEpsilonOfTheLastDelivered() {
        var throttle = LevelThrottle(interval: 0.04, epsilon: 0.005)
        #expect(throttle.consume(0.3, at: 10) == 0.3)
        #expect(throttle.consume(0.303, at: 10.05) == nil)
        #expect(throttle.consume(0.297, at: 10.10) == nil)
        #expect(throttle.consume(0.31, at: 10.15) == 0.31)
    }

    @Test func skippedValueDoesNotExtendTheHold() {
        var throttle = LevelThrottle(interval: 0.04, epsilon: 0.005)
        #expect(throttle.consume(0.3, at: 10) == 0.3)
        #expect(throttle.consume(0.301, at: 10.05) == nil)
        // Nothing was delivered at 10.05, so the next buffer is eligible.
        #expect(throttle.consume(0.6, at: 10.06) == 0.6)
    }

    @Test func silenceIsDeliveredOnceThenSuppressed() {
        var throttle = LevelThrottle(interval: 0.04, epsilon: 0.005)
        #expect(throttle.consume(0, at: 10) == 0)
        #expect(throttle.consume(0, at: 10.1) == nil)
        #expect(throttle.consume(0, at: 10.2) == nil)
    }
}

@Suite struct MicrophoneMonitorStateTests {
    @Test func runningStatesCompareByOutputDeviceName() {
        #expect(MicrophoneMonitorState.running(outputDeviceName: "AirPods Pro")
            == .running(outputDeviceName: "AirPods Pro"))
        #expect(MicrophoneMonitorState.running(outputDeviceName: "AirPods Pro")
            != .running(outputDeviceName: nil))
        #expect(MicrophoneMonitorState.failed(.engineFailed("x")) != .failed(.engineFailed("y")))
    }

    @Test func mockMonitorRecordsLifecycleAndFiresCallbacks() {
        let monitor = MockMicrophoneMonitor()
        var states: [MicrophoneMonitorState] = []
        var levels: [Float] = []
        monitor.onStateChanged = { states.append($0) }
        monitor.onLevel = { levels.append($0) }

        monitor.start(inputDevice: 4100)
        #expect(monitor.state == .starting)
        monitor.simulateRunning(outputDeviceName: "AirPods Pro")
        monitor.simulateLevel(0.4)
        monitor.start(inputDevice: 4200)
        monitor.simulateFailure(.inputDeviceUnavailable)
        monitor.stop()
        monitor.stop()

        #expect(monitor.startedDevices == [4100, 4200])
        #expect(monitor.stopCount == 2)
        #expect(levels == [0.4])
        #expect(states == [
            .starting, .running(outputDeviceName: "AirPods Pro"),
            .starting, .failed(.inputDeviceUnavailable),
            .stopped, .stopped,
        ])
    }
}
