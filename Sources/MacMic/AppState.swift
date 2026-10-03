// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import AppKit
import Combine
import Dispatch
import Foundation
import QuadcastKit

/// Composition root: builds one object per concern, opens the shared audio
/// control, fans out sleep/wake. Publishes nothing; views observe the
/// concern they render. Main thread only.
final class AppState: ObservableObject {
    let lighting: Lighting
    let audio: AudioControls
    let microphoneTest: MicrophoneTest

    private let audioControl: AudioDeviceControl
    private let notificationCenter: NotificationCenter
    private var observerTokens: [NSObjectProtocol] = []

    /// Ports are required so a test can't build real hardware adapters by
    /// accident. The session factory receives this `AppState`'s own
    /// control, so the session can never observe a different one.
    /// `notificationCenter` is the source of sleep/wake notifications.
    init(
        transport: HIDTransport,
        audioControl: AudioDeviceControl,
        makeMicrophoneTestSession: (AudioDeviceControl) -> MicrophoneTestSession,
        defaults: UserDefaults,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        scheduler: QuadcastKit.Scheduler = DispatchScheduler()
    ) {
        lighting = Lighting(transport: transport, defaults: defaults, scheduler: scheduler)
        audio = AudioControls(control: audioControl)
        microphoneTest = MicrophoneTest(session: makeMicrophoneTestSession(audioControl))
        self.audioControl = audioControl
        self.notificationCenter = notificationCenter

        observerTokens.append(notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.handleWillSleep() })
        observerTokens.append(notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.handleDidWake() })

        // Warning: open last. There is no replay on registration and a mock
        // delivers inside open(), so an observer added here that doesn't seed
        // from snapshot (as audio and the session do) would miss the opening
        // state in tests.
        try? audioControl.open()
    }

    /// The only place the hardware adapters and the production session are
    /// built.
    static func live() -> AppState {
        AppState(
            transport: IOUSBHostTransport(),
            audioControl: CoreAudioDeviceControl(),
            makeMicrophoneTestSession: MicrophoneTestSession.init(audioControl:),
            defaults: .standard
        )
    }

    deinit {
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
        audioControl.close()
    }

    private func handleWillSleep() {
        dispatchPrecondition(condition: .onQueue(.main))
        lighting.systemWillSleep()
        microphoneTest.systemWillSleep()
    }

    private func handleDidWake() {
        dispatchPrecondition(condition: .onQueue(.main))
        lighting.systemDidWake()
    }
}
