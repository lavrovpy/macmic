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

enum LightingStatus: Equatable {
    case notFound, connected, notResponding
}

/// The lighting concern: settings (persisted as one blob), presence, send
/// health and the retry policy over `HIDTransport` + `FrameStreamer`. Main
/// thread only. Presence moves only with the transport's callbacks; a failed
/// send never disables the controls — it is retried after 1, 2, 4, 8, then
/// every 10 s for as long as lighting is wanted.
final class Lighting: ObservableObject {
    static let maxRetryDelay: TimeInterval = 10

    /// An equal write is ignored; any other is saved, then applied (which
    /// retries at once while sends are failing).
    @Published var settings: LightingSettings {
        didSet {
            dispatchPrecondition(condition: .onQueue(.main))
            guard settings != oldValue else { return }
            LightingSettingsStore.save(settings, to: defaults)
            apply()
        }
    }

    /// A QuadCast USB function is matched. Set only from the transport's
    /// callbacks, never assumed from `open()` succeeding.
    @Published private(set) var isDevicePresent = false

    /// The latest run failed while lighting should be on; cleared by the
    /// next first frame sent, unplug, disable or sleep.
    @Published private(set) var isSendFailing = false

    var status: LightingStatus {
        if !isDevicePresent { return .notFound }
        return isSendFailing ? .notResponding : .connected
    }

    var statusText: String {
        switch status {
        case .notFound: return "QuadCast S not found"
        case .connected: return "QuadCast S connected"
        case .notResponding: return "QuadCast S not responding — retrying"
        }
    }

    var controlsEnabled: Bool {
        isDevicePresent
    }

    private let transport: HIDTransport
    private let streamer: FrameStreamer
    private let defaults: UserDefaults
    private let scheduler: QuadcastKit.Scheduler
    private var isAsleep = false
    private var consecutiveFailures = 0
    private var retry: ScheduledWork?

    /// Gating on presence too: a settings change racing a removal must not
    /// resume streaming against a device that just disappeared.
    private var wantsStreaming: Bool {
        isDevicePresent && settings.isEnabled && !isAsleep
    }

    /// Loads (and migrates) the settings, wires the callbacks, then opens
    /// the transport — a mock connects inside that call.
    init(transport: HIDTransport, defaults: UserDefaults, scheduler: QuadcastKit.Scheduler = DispatchScheduler()) {
        self.transport = transport
        self.defaults = defaults
        self.scheduler = scheduler
        streamer = FrameStreamer(transport: transport, scheduler: scheduler)
        settings = LightingSettingsStore.load(from: defaults)

        streamer.onError = { [weak self] _ in self?.streamerDidFail() }
        streamer.onFirstFrameSent = { [weak self] in self?.streamerDidSendFirstFrame() }
        transport.onDeviceConnected = { [weak self] in self?.deviceDidConnect() }
        transport.onDeviceRemoved = { [weak self] in self?.deviceWasRemoved() }
        try? transport.open()
    }

    deinit {
        retry?.cancel()
        streamer.stop()
        transport.close()
    }

    func systemWillSleep() {
        dispatchPrecondition(condition: .onQueue(.main))
        isAsleep = true
        apply()
    }

    func systemDidWake() {
        dispatchPrecondition(condition: .onQueue(.main))
        isAsleep = false
        apply()
    }

    private func apply() {
        retry?.cancel()
        retry = nil
        guard wantsStreaming else {
            consecutiveFailures = 0
            if isSendFailing {
                isSendFailing = false
            }
            streamer.stop()
            return
        }
        streamer.setMode(settings.mode, brightness: settings.brightness)
        streamer.start()
    }

    private func deviceDidConnect() {
        dispatchPrecondition(condition: .onQueue(.main))
        if !isDevicePresent {
            isDevicePresent = true
        }
        apply()
    }

    private func deviceWasRemoved() {
        dispatchPrecondition(condition: .onQueue(.main))
        isDevicePresent = false
        apply()
    }

    private func streamerDidFail() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard wantsStreaming else { return }
        consecutiveFailures += 1
        if !isSendFailing {
            isSendFailing = true
        }
        let delay = min(pow(2, Double(consecutiveFailures - 1)), Self.maxRetryDelay)
        retry?.cancel()
        retry = scheduler.schedule(after: delay) { [weak self] in self?.apply() }
    }

    private func streamerDidSendFirstFrame() {
        dispatchPrecondition(condition: .onQueue(.main))
        consecutiveFailures = 0
        if isSendFailing {
            isSendFailing = false
        }
    }
}
