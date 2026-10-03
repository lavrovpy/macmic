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

/// Builds the lighting concern (`lighting`) and the Test Microphone model
/// (`microphoneTest`), owns the mic's Core Audio state (`audio`), which has
/// its own hotplug lifecycle, and fans out sleep/wake.
public final class AppState: ObservableObject {
    let lighting: Lighting

    /// Live mute/volume state of the mic's Core Audio devices. Not persisted:
    /// macOS and the mic keep these values themselves, and every other app
    /// (Sound settings, the mic's gain knob) writes the same properties.
    /// Availability is independent of lighting presence — the audio side is
    /// a different USB function.
    @Published public private(set) var audio: AudioDeviceSnapshot = .unavailable

    /// Incoming volume within this distance of the current value is treated
    /// as the HAL echoing our own write (it quantizes the scalar) and doesn't
    /// move the slider; external nudges under 1% are swallowed until a larger
    /// change arrives.
    static let audioEchoTolerance: Float = 0.01

    /// The Audio page's "Test Microphone". Not republished here: only the
    /// view that renders it observes it, so the level meter doesn't
    /// re-render everything bound to `AppState`.
    let microphoneTest: MicrophoneTest

    private let audioControl: AudioDeviceControl
    private let notificationCenter: NotificationCenter
    private var observerTokens: [NSObjectProtocol] = []
    private var audioObservation: AudioDeviceObservation?

    /// - Parameters:
    ///   - transport: the `HIDTransport` `lighting` streams frames over and
    ///     opens.
    ///   - audioControl: the `AudioDeviceControl` for gain/mute; also opened
    ///     here. Required (no default) so a test can never construct a real
    ///     Core Audio control by accident.
    ///   - makeMicrophoneTestSession: builds the session behind "Test
    ///     Microphone" from `audioControl`, so the session can never observe
    ///     a different control; required for the same reason.
    ///   - defaults: where the lighting settings are persisted; injectable
    ///     for tests so they don't touch the real `UserDefaults.standard`.
    ///   - notificationCenter: source of sleep/wake notifications;
    ///     defaults to `NSWorkspace`'s center in production, injectable so
    ///     tests can simulate sleep/wake without a real OS event.
    ///   - scheduler: the clock behind the frame loop and the send retry.
    public init(
        transport: HIDTransport,
        audioControl: AudioDeviceControl,
        makeMicrophoneTestSession: (AudioDeviceControl) -> MicrophoneTestSession,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        scheduler: QuadcastKit.Scheduler = DispatchScheduler()
    ) {
        self.lighting = Lighting(transport: transport, defaults: defaults, scheduler: scheduler)
        self.audioControl = audioControl
        self.microphoneTest = MicrophoneTest(session: makeMicrophoneTestSession(audioControl))
        self.notificationCenter = notificationCenter
        audioObservation = audioControl.observe { [weak self] in self?.handleAudioStateChanged($0) }

        observerTokens.append(notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.handleWillSleep() })
        observerTokens.append(notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.handleDidWake() })

        // Presence arrives through the observers, not from `open()`. Open
        // only after every `observe` (this one and the session's): there is
        // no replay on registration, and a mock control delivers inside
        // `open()`.
        try? audioControl.open()
    }

    deinit {
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
        audioControl.close()
    }

    // MARK: Audio

    /// Sets one direction's volume (`0...1`, clamped). Optimistic: `audio`
    /// moves first so a dragging `Slider` tracks the thumb, then the write
    /// goes out; a failed write reverts to the control's own snapshot.
    /// Ignored while that direction's device is absent.
    public func setAudioVolume(_ scalar: Float, for direction: AudioDirection) {
        guard audio[direction] != nil else { return }
        let clamped = min(max(scalar, 0), 1)
        audio[direction]?.volume = clamped
        do {
            try audioControl.setVolume(clamped, for: direction)
        } catch {
            audio = audioControl.snapshot
        }
    }

    /// Sets one direction's master mute; same optimistic/revert shape as
    /// `setAudioVolume`.
    public func setAudioMuted(_ muted: Bool, for direction: AudioDirection) {
        guard audio[direction] != nil else { return }
        audio[direction]?.isMuted = muted
        do {
            try audioControl.setMuted(muted, for: direction)
        } catch {
            audio = audioControl.snapshot
        }
    }

    private func handleAudioStateChanged(_ incoming: AudioDeviceSnapshot) {
        audio = Self.reconcile(current: audio, incoming: incoming, tolerance: Self.audioEchoTolerance)
    }

    /// Merges a control-reported snapshot into the published one. Per
    /// direction: an availability change, a mute change, or a volume delta
    /// above `tolerance` takes the incoming level; anything closer is the
    /// HAL's quantized echo of our own write, so the current volume is kept
    /// and only the fresh `decibels` is taken (the dB label stays truthful).
    static func reconcile(
        current: AudioDeviceSnapshot,
        incoming: AudioDeviceSnapshot,
        tolerance: Float
    ) -> AudioDeviceSnapshot {
        var result = incoming
        for direction in AudioDirection.allCases {
            guard let currentLevel = current[direction], let incomingLevel = incoming[direction] else { continue }
            if currentLevel.isMuted != incomingLevel.isMuted
                || abs(incomingLevel.volume - currentLevel.volume) > tolerance {
                continue
            }
            result[direction] = AudioLevel(
                volume: currentLevel.volume,
                isMuted: currentLevel.isMuted,
                decibels: incomingLevel.decibels
            )
        }
        return result
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
