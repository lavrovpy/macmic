// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Foundation
@testable import MacMic
@testable import QuadcastKit

/// An `AppState` over mocks, a `ScriptedMicrophoneEngine` behind the real
/// `MicrophoneTestSession`, a private `NotificationCenter` and a
/// `TestDefaults` slot. Mocks that must be configured before launch are
/// passed in.
final class AppStateFixture {
    /// Long enough that the real streamer timer never fires during a test;
    /// tests drive `state.streamer.tick()` instead.
    static let dormantStreamerInterval: DispatchTimeInterval = .seconds(3600)

    private(set) var transport: MockHIDTransport
    private(set) var audio: MockAudioDeviceControl
    private(set) var engine: ScriptedMicrophoneEngine
    let scheduler = ManualScheduler()
    let notificationCenter = NotificationCenter()
    let testDefaults = TestDefaults()
    private var current: AppState?

    var state: AppState {
        current!
    }

    var defaults: UserDefaults {
        testDefaults.defaults
    }

    init(
        transport: MockHIDTransport = MockHIDTransport(),
        audio: MockAudioDeviceControl = MockAudioDeviceControl(),
        engine: ScriptedMicrophoneEngine = ScriptedMicrophoneEngine()
    ) {
        self.transport = transport
        self.audio = audio
        self.engine = engine
        current = makeState()
    }

    /// Quits and relaunches on the same defaults, with fresh devices.
    func relaunch(
        transport: MockHIDTransport = MockHIDTransport(),
        audio: MockAudioDeviceControl = MockAudioDeviceControl()
    ) {
        current = nil
        self.transport = transport
        self.audio = audio
        engine = ScriptedMicrophoneEngine()
        current = makeState()
    }

    func releaseState() {
        current = nil
    }

    private func makeState() -> AppState {
        let engine = engine
        let scheduler = scheduler
        return AppState(
            transport: transport,
            audioControl: audio,
            makeMicrophoneTestSession: { MicrophoneTestSession(audioControl: $0, engine: engine, scheduler: scheduler) },
            defaults: testDefaults.defaults,
            notificationCenter: notificationCenter,
            streamerInterval: Self.dormantStreamerInterval
        )
    }
}
