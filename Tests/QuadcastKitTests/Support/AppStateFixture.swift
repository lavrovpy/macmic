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

/// The whole `AppState` graph over mocks: a `ScriptedMicrophoneEngine`
/// behind the real `MicrophoneTestSession`, one `ManualScheduler` for the
/// session and the lighting, a private `NotificationCenter` and a
/// `TestDefaults` slot. Mocks that must be configured before launch are
/// passed in. Only `AppStateTests` build it; each concern is tested
/// without the rest of the graph.
final class AppStateFixture {
    private(set) var transport: MockHIDTransport
    private(set) var audioControl: MockAudioDeviceControl
    private(set) var engine: ScriptedMicrophoneEngine
    let scheduler = ManualScheduler()
    let notificationCenter = NotificationCenter()
    let testDefaults = TestDefaults()
    private var current: AppState?

    var state: AppState {
        current!
    }

    /// What this slot holds on disk, as `UserDefaults` would persist it.
    var persisted: [String: Any] {
        testDefaults.defaults.persistentDomain(forName: testDefaults.suiteName) ?? [:]
    }

    init(
        transport: MockHIDTransport = MockHIDTransport(),
        audioControl: MockAudioDeviceControl = MockAudioDeviceControl(),
        engine: ScriptedMicrophoneEngine = ScriptedMicrophoneEngine()
    ) {
        self.transport = transport
        self.audioControl = audioControl
        self.engine = engine
        current = launch()
    }

    /// Quits and relaunches on the same defaults, with fresh devices.
    func relaunch(
        transport: MockHIDTransport = MockHIDTransport(),
        audioControl: MockAudioDeviceControl = MockAudioDeviceControl()
    ) {
        current = nil
        self.transport = transport
        self.audioControl = audioControl
        engine = ScriptedMicrophoneEngine()
        current = launch()
    }

    func releaseState() {
        current = nil
    }

    private func launch() -> AppState {
        let engine = engine
        let scheduler = scheduler
        return AppState(
            transport: transport,
            audioControl: audioControl,
            makeMicrophoneTestSession: { MicrophoneTestSession(audioControl: $0, engine: engine, scheduler: scheduler) },
            defaults: testDefaults.defaults,
            notificationCenter: notificationCenter,
            scheduler: scheduler
        )
    }
}
