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

    /// A supported USB function is matched. Set only from the transport's
    /// callbacks, never assumed from `open()` succeeding.
    @Published private(set) var isDevicePresent = false

    /// The connected mic's name from the transport's latest connect or
    /// rename; `nil` while not present.
    @Published private(set) var deviceName: String?

    /// The latest run failed while lighting should be on; cleared by the
    /// next first frame sent, unplug, disable or sleep.
    @Published private(set) var isSendFailing = false

    var status: LightingStatus {
        if !isDevicePresent { return .notFound }
        return isSendFailing ? .notResponding : .connected
    }

    var statusText: String {
        let name = deviceName ?? QuadcastCatalog.genericName
        switch status {
        case .notFound: return "No HyperX microphone found for lighting"
        case .connected: return "\(name) connected"
        case .notResponding: return "\(name) not responding — retrying"
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
        transport.onDeviceConnected = { [weak self] name in self?.deviceDidConnect(name: name) }
        transport.onDeviceNameChanged = { [weak self] name in self?.deviceWasRenamed(name) }
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

    private func deviceDidConnect(name: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        if deviceName != name {
            deviceName = name
        }
        if !isDevicePresent {
            isDevicePresent = true
        }
        apply()
    }

    private func deviceWasRenamed(_ name: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard isDevicePresent, deviceName != name else { return }
        deviceName = name
    }

    private func deviceWasRemoved() {
        dispatchPrecondition(condition: .onQueue(.main))
        isDevicePresent = false
        deviceName = nil
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
