// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Combine
import Dispatch
import Foundation
import QuadcastKit

/// Mic gain/mute and headphone-monitoring volume/mute over
/// `AudioDeviceControl`. Main thread only. Observes the control but does not
/// open or close it (`AppState` owns that lifecycle).
///
/// The four setters are optimistic: the value moves first so a dragging
/// `Slider` tracks the thumb, then the write goes out (volume clamped to
/// `0...1`); a failed write reverts to the control's own snapshot. A setter
/// is ignored while its direction's device is absent.
///
/// Not persisted: macOS and the mic keep these values themselves, and every
/// other app (Sound settings, the mic's gain knob) writes the same
/// properties.
final class AudioControls: ObservableObject {
    /// Incoming volume within this distance of the current value is treated
    /// as the HAL echoing our own write (it quantizes the scalar) and doesn't
    /// move the slider; external nudges under 1% are swallowed until a larger
    /// change arrives.
    static let echoTolerance: Float = 0.01

    /// Reconciled; a delivery whose levels equal the current ones (e.g. an
    /// id-only re-enumeration) doesn't publish.
    @Published private(set) var snapshot: AudioDeviceSnapshot

    private let control: AudioDeviceControl
    private var observation: AudioDeviceObservation?

    init(control: AudioDeviceControl) {
        self.control = control
        snapshot = control.snapshot
        observation = control.observe { [weak self] in self?.controlDidDeliver($0) }
    }

    // MARK: Values

    /// Microphone gain (`0...1`); `0` while the input device is absent.
    var micGain: Float {
        get { snapshot.input?.volume ?? 0 }
        set { setVolume(newValue, for: .input) }
    }

    /// The mic's system input mute; `false` while the input device is absent.
    var isMicMuted: Bool {
        get { snapshot.input?.isMuted ?? false }
        set { setMuted(newValue, for: .input) }
    }

    /// Headphone-monitoring volume (`0...1`); `0` while the output device is absent.
    var monitorVolume: Float {
        get { snapshot.output?.volume ?? 0 }
        set { setVolume(newValue, for: .output) }
    }

    /// Headphone-monitoring mute; `false` while the output device is absent.
    var isMonitorMuted: Bool {
        get { snapshot.output?.isMuted ?? false }
        set { setMuted(newValue, for: .output) }
    }

    // MARK: Derivations

    var micControlsEnabled: Bool {
        snapshot.input != nil
    }

    var monitorControlsEnabled: Bool {
        snapshot.output != nil
    }

    var isAvailable: Bool {
        snapshot.isAvailable
    }

    /// The audio counterpart of `Lighting.statusText`.
    var statusText: String {
        isAvailable ? "Audio device connected" : "Audio device not found"
    }

    var micGainText: String {
        Self.levelText(snapshot.input)
    }

    var monitorVolumeText: String {
        Self.levelText(snapshot.output)
    }

    // MARK: Private

    private func setVolume(_ scalar: Float, for direction: AudioDirection) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard snapshot[direction] != nil else { return }
        let clamped = min(max(scalar, 0), 1)
        var optimistic = snapshot
        optimistic[direction]?.volume = clamped
        update(optimistic)
        do {
            try control.setVolume(clamped, for: direction)
        } catch {
            update(control.snapshot)
        }
    }

    private func setMuted(_ muted: Bool, for direction: AudioDirection) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard snapshot[direction] != nil else { return }
        var optimistic = snapshot
        optimistic[direction]?.isMuted = muted
        update(optimistic)
        do {
            try control.setMuted(muted, for: direction)
        } catch {
            update(control.snapshot)
        }
    }

    private func controlDidDeliver(_ incoming: AudioDeviceSnapshot) {
        dispatchPrecondition(condition: .onQueue(.main))
        update(Self.reconcile(current: snapshot, incoming: incoming, tolerance: Self.echoTolerance))
    }

    /// Every write goes through here: `@Published` publishes equal
    /// assignments too, so a direct `snapshot =` re-renders every observer
    /// on an id-only re-enumeration.
    private func update(_ next: AudioDeviceSnapshot) {
        guard next != snapshot else { return }
        snapshot = next
    }

    /// Merges a control-reported snapshot into the published one. Per
    /// direction: an availability change, a mute change, or a volume delta
    /// above `tolerance` takes the incoming level; anything closer is the
    /// HAL's quantized echo of our own write, so the current volume is kept
    /// and only the fresh `decibels` is taken (the dB label stays truthful).
    private static func reconcile(
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

    /// `"68% (+2.1 dB)"`; `"68%"` when the device reports no dB; `"—"` when
    /// the direction is absent.
    private static func levelText(_ level: AudioLevel?) -> String {
        guard let level else { return "—" }
        let percent = "\(Int((level.volume * 100).rounded()))%"
        guard let decibels = level.decibels else { return percent }
        return "\(percent) (\(String(format: "%+.1f", decibels)) dB)"
    }
}
