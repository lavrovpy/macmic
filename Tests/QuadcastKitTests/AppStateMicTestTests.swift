// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import AppKit
import Dispatch
import Foundation
import Testing
@testable import MacMic
@testable import QuadcastKit

/// `AppState`'s "Test Microphone" surface driven through
/// `MockMicrophoneMonitor` + `MockAudioDeviceControl`: start/stop plumbing,
/// state and level mirroring, the transient-lifetime rules (input device
/// gone, sleep, deinit), independence from lighting, and the UI text.
@Suite struct AppStateMicTestTests {
    private static func freshDefaults(name: String = #function) -> UserDefaults {
        let suiteName = "dev.alavreniuk.macmic.tests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeState(
        transport: HIDTransport = MockHIDTransport(),
        audio: MockAudioDeviceControl = MockAudioDeviceControl(),
        monitor: MockMicrophoneMonitor = MockMicrophoneMonitor(),
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> AppState {
        AppState(
            transport: transport,
            audioControl: audio,
            microphoneMonitor: monitor,
            defaults: Self.freshDefaults(),
            notificationCenter: notificationCenter,
            streamerInterval: .seconds(3600)
        )
    }

    // MARK: Start / stop

    @Test func initialStateIsStopped() throws {
        let state = makeState()

        #expect(state.micTestState == .stopped)
        #expect(state.micTestLevel == 0)
        #expect(state.isMicTestRunning == false)
        #expect(state.micTestControlsEnabled == true)
    }

    @Test func startUsesTheControlsCurrentInputDeviceID() throws {
        let monitor = MockMicrophoneMonitor()
        let state = makeState(monitor: monitor)

        state.startMicTest()

        #expect(monitor.startedDevices == [MockAudioDeviceControl.inputDeviceID])
        #expect(state.micTestState == .starting)
        #expect(state.isMicTestRunning == true)
    }

    @Test func startIsIgnoredWhileInputDeviceAbsent() throws {
        let audio = MockAudioDeviceControl()
        audio.stateAtOpen = AudioDeviceSnapshot(input: nil, output: AudioDeviceSnapshot.sample.output)
        let monitor = MockMicrophoneMonitor()
        let state = makeState(audio: audio, monitor: monitor)
        #expect(state.micTestControlsEnabled == false)

        state.startMicTest()

        #expect(monitor.startedDevices.isEmpty)
        #expect(state.micTestState == .stopped)
    }

    @Test func stopReachesTheMonitorAndResetsState() throws {
        let monitor = MockMicrophoneMonitor()
        let state = makeState(monitor: monitor)
        state.startMicTest()
        monitor.simulateRunning(outputDeviceName: "AirPods Pro")
        monitor.simulateLevel(0.5)

        state.stopMicTest()

        #expect(monitor.stopCount == 1)
        #expect(state.micTestState == .stopped)
        #expect(state.micTestLevel == 0)
        #expect(state.isMicTestRunning == false)
    }

    // MARK: Mirroring

    @Test func stateMirrorsMonitorTransitions() throws {
        let monitor = MockMicrophoneMonitor()
        let state = makeState(monitor: monitor)

        state.startMicTest()
        #expect(state.micTestState == .starting)

        monitor.simulateRunning(outputDeviceName: "AirPods Pro")
        #expect(state.micTestState == .running(outputDeviceName: "AirPods Pro"))
        #expect(state.isMicTestRunning == true)

        monitor.simulateFailure(.engineFailed("boom"))
        #expect(state.micTestState == .failed(.engineFailed("boom")))
        #expect(state.isMicTestRunning == false)
    }

    @Test func levelMirrorsOnlyWhileRunning() throws {
        let monitor = MockMicrophoneMonitor()
        let state = makeState(monitor: monitor)

        state.startMicTest()
        monitor.simulateLevel(0.4)
        #expect(state.micTestLevel == 0)

        monitor.simulateRunning()
        monitor.simulateLevel(0.4)
        #expect(state.micTestLevel == 0.4)
        monitor.simulateLevel(0.9)
        #expect(state.micTestLevel == 0.9)
    }

    @Test func levelResetsWhenStateLeavesRunning() throws {
        let monitor = MockMicrophoneMonitor()
        let state = makeState(monitor: monitor)
        state.startMicTest()
        monitor.simulateRunning()
        monitor.simulateLevel(0.7)
        #expect(state.micTestLevel == 0.7)

        monitor.simulateFailure(.inputDeviceUnavailable)

        #expect(state.micTestLevel == 0)
        monitor.simulateLevel(0.7)
        #expect(state.micTestLevel == 0)
    }

    // MARK: Transient lifetime

    @Test func inputDeviceDisappearingStopsTheTest() throws {
        let audio = MockAudioDeviceControl()
        let monitor = MockMicrophoneMonitor()
        let state = makeState(audio: audio, monitor: monitor)
        state.startMicTest()
        monitor.simulateRunning()

        audio.simulateExternalChange(AudioDeviceSnapshot(input: nil, output: AudioDeviceSnapshot.sample.output))

        #expect(monitor.stopCount == 1)
        #expect(state.micTestState == .stopped)
        #expect(state.micTestControlsEnabled == false)
    }

    @Test func audioChangesThatKeepTheInputDoNotStopTheTest() throws {
        let audio = MockAudioDeviceControl()
        let monitor = MockMicrophoneMonitor()
        let state = makeState(audio: audio, monitor: monitor)
        state.startMicTest()
        monitor.simulateRunning()

        state.micGain = 0.3
        audio.simulateExternalChange(AudioDeviceSnapshot(
            input: AudioLevel(volume: 0.9, isMuted: true, decibels: 5),
            output: nil
        ))

        #expect(monitor.stopCount == 0)
        #expect(state.micTestState == .running(outputDeviceName: "MacBook Pro Speakers"))
    }

    @Test func sleepStopsTheTestAndWakeDoesNotRestartIt() throws {
        let monitor = MockMicrophoneMonitor()
        let notificationCenter = NotificationCenter()
        let state = makeState(monitor: monitor, notificationCenter: notificationCenter)
        state.startMicTest()
        monitor.simulateRunning()

        notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(monitor.stopCount == 1)
        #expect(state.micTestState == .stopped)

        notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(monitor.startedDevices.count == 1)
        #expect(state.micTestState == .stopped)
    }

    @Test func deinitStopsTheTest() throws {
        let monitor = MockMicrophoneMonitor()
        var state: AppState? = makeState(monitor: monitor)
        state?.startMicTest()
        monitor.simulateRunning()
        #expect(monitor.stopCount == 0)

        state = nil

        #expect(monitor.stopCount == 1)
        #expect(monitor.state == .stopped)
    }

    // MARK: Independence from lighting

    @Test func startingTheTestDoesNotTouchLighting() throws {
        let transport = MockHIDTransport()
        let monitor = MockMicrophoneMonitor()
        let state = makeState(transport: transport, monitor: monitor)
        state.isEnabled = false
        state.streamer.tick() // no-op: stopped (and a barrier for the async stop)
        let reportsBefore = transport.sentReports.count

        state.startMicTest()
        monitor.simulateRunning()
        monitor.simulateLevel(0.5)
        state.stopMicTest()
        state.streamer.tick()

        #expect(state.streamer.isRunning == false)
        #expect(state.isConnected == true)
        #expect(state.isEnabled == false)
        #expect(transport.sentReports.count == reportsBefore)
    }

    @Test func lightingHotplugRemovalDoesNotStopTheTest() throws {
        let transport = MockHIDTransport()
        let monitor = MockMicrophoneMonitor()
        let state = makeState(transport: transport, monitor: monitor)
        state.startMicTest()
        monitor.simulateRunning(outputDeviceName: "AirPods Pro")

        transport.simulateRemoval()

        #expect(state.isConnected == false)
        #expect(monitor.stopCount == 0)
        #expect(state.micTestState == .running(outputDeviceName: "AirPods Pro"))
        #expect(state.micTestControlsEnabled == true)
    }

    // MARK: UI derivations

    @Test func statusTextPerState() throws {
        let monitor = MockMicrophoneMonitor()
        let state = makeState(monitor: monitor)
        #expect(state.micTestStatusText == "Not running")

        state.startMicTest()
        #expect(state.micTestStatusText == "Starting…")

        monitor.simulateRunning(outputDeviceName: "AirPods Pro")
        #expect(state.micTestStatusText == "Playing through AirPods Pro")

        monitor.simulateRunning(outputDeviceName: nil)
        #expect(state.micTestStatusText == "Playing through the default output")

        monitor.simulateFailure(.microphoneAccessDenied)
        #expect(state.micTestStatusText
            == "Microphone access denied — allow MacMic in System Settings › Privacy & Security › Microphone")

        monitor.simulateFailure(.inputDeviceUnavailable)
        #expect(state.micTestStatusText == "Microphone unavailable")

        monitor.simulateFailure(.engineFailed("error -10875"))
        #expect(state.micTestStatusText == "Failed: error -10875")
    }

    @Test func isMicrophoneAccessDeniedOnlyForThatFailure() throws {
        let monitor = MockMicrophoneMonitor()
        let state = makeState(monitor: monitor)
        #expect(state.isMicrophoneAccessDenied == false)

        state.startMicTest()
        monitor.simulateFailure(.microphoneAccessDenied)
        #expect(state.isMicrophoneAccessDenied == true)
        #expect(state.isMicTestRunning == false)

        monitor.simulateFailure(.inputDeviceUnavailable)
        #expect(state.isMicrophoneAccessDenied == false)

        state.stopMicTest()
        #expect(state.isMicrophoneAccessDenied == false)
    }

    @Test func micTestControlsEnabledFollowsInputPresence() throws {
        let audio = MockAudioDeviceControl()
        let state = makeState(audio: audio)
        #expect(state.micTestControlsEnabled == true)

        audio.simulateDeviceRemoved()
        #expect(state.micTestControlsEnabled == false)

        audio.simulateDeviceAppeared(AudioDeviceSnapshot(input: nil, output: AudioDeviceSnapshot.sample.output))
        #expect(state.micTestControlsEnabled == false)

        audio.simulateDeviceAppeared(.sample)
        #expect(state.micTestControlsEnabled == true)
    }
}
