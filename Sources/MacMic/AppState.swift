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

/// UI-facing model that translates user intent (mode/brightness/enabled)
/// into `FrameStreamer` calls, persists the last-used settings, and keeps
/// lighting in sync with device hotplug and sleep/wake, so the menu bar UI
/// (Task 8) only has to bind to `@Published` properties.
public final class AppState: ObservableObject {
    private enum DefaultsKey {
        static let mode = "dev.alavreniuk.macmic.mode"
        static let brightness = "dev.alavreniuk.macmic.brightness"
        static let isEnabled = "dev.alavreniuk.macmic.isEnabled"
    }

    /// Whether a QuadCast HID/USB service is currently matched. Controls
    /// vary their enabled/disabled UI state on this.
    @Published public private(set) var isConnected = false

    @Published public var mode: LightMode {
        didSet {
            if case .solid(let rgb) = mode {
                lastSolidColor = rgb
            }
            defaults.set((try? JSONEncoder().encode(mode)) ?? Data(), forKey: DefaultsKey.mode)
            applyEnabledState()
        }
    }

    /// The last color picked while in `.solid` mode, kept even while a
    /// preset (`Cycle`/`Blink`) is active so switching presets and back
    /// doesn't reset the picker to white. Backs `AppState.solidColor`'s
    /// non-solid fallback (Task 8).
    @Published public private(set) var lastSolidColor: QuadcastKit.RGBColor

    @Published public var brightness: Double {
        didSet {
            defaults.set(brightness, forKey: DefaultsKey.brightness)
            applyEnabledState()
        }
    }

    @Published public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: DefaultsKey.isEnabled)
            applyEnabledState()
        }
    }

    private let transport: HIDTransport
    /// Internal (not private) so tests can call `tick()` for a deterministic
    /// synchronous send, the same pattern `FrameStreamerTests` uses.
    let streamer: FrameStreamer
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private var observerTokens: [NSObjectProtocol] = []

    /// - Parameters:
    ///   - transport: the `HIDTransport` to stream frames over; `open()` is
    ///     called as part of initialization.
    ///   - defaults: where mode/brightness/enabled are persisted; injectable
    ///     for tests so they don't touch the real `UserDefaults.standard`.
    ///   - notificationCenter: source of sleep/wake notifications;
    ///     defaults to `NSWorkspace`'s center in production, injectable so
    ///     tests can simulate sleep/wake without a real OS event.
    ///   - streamerInterval: the underlying `FrameStreamer`'s tick interval;
    ///     tests pass a long dormant interval and drive `streamer.tick()`
    ///     manually instead of waiting on the real timer.
    public init(
        transport: HIDTransport,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        streamerInterval: DispatchTimeInterval = .milliseconds(55)
    ) {
        self.transport = transport
        self.streamer = FrameStreamer(transport: transport, interval: streamerInterval)
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        let loadedMode = Self.loadMode(from: defaults)
        self.mode = loadedMode
        self.brightness = Self.loadBrightness(from: defaults)
        self.isEnabled = Self.loadIsEnabled(from: defaults)
        if case .solid(let rgb) = loadedMode {
            self.lastSolidColor = rgb
        } else {
            self.lastSolidColor = QuadcastKit.RGBColor(r: 0xFF, g: 0xFF, b: 0xFF)
        }

        transport.onDeviceConnected = { [weak self] in self?.handleDeviceConnected() }
        transport.onDeviceRemoved = { [weak self] in self?.handleDeviceRemoved() }
        streamer.onError = { [weak self] _ in self?.handleTransportError() }

        observerTokens.append(notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.handleWillSleep() })
        observerTokens.append(notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.handleDidWake() })

        do {
            try transport.open()
            isConnected = true
            applyEnabledState()
        } catch {
            isConnected = false
        }
    }

    deinit {
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
        streamer.stop()
        transport.close()
    }

    /// Starts (or restarts, picking up the current `mode`/`brightness`) or
    /// stops the streamer to match `isEnabled`/`isConnected`. Called whenever
    /// `mode`, `brightness`, or `isEnabled` changes, and after (re)connecting.
    /// Also gated on `isConnected` so a state mutation that races a hotplug
    /// removal can't resume streaming against a device that's already gone.
    private func applyEnabledState() {
        guard isConnected, isEnabled else {
            streamer.stop()
            return
        }
        streamer.setMode(mode, brightness: brightness)
        streamer.start()
    }

    private func handleDeviceConnected() {
        isConnected = true
        applyEnabledState()
    }

    private func handleDeviceRemoved() {
        isConnected = false
        streamer.stop()
    }

    private func handleTransportError() {
        isConnected = false
    }

    private func handleWillSleep() {
        streamer.stop()
    }

    private func handleDidWake() {
        applyEnabledState()
    }

    private static func loadMode(from defaults: UserDefaults) -> LightMode {
        guard let data = defaults.data(forKey: DefaultsKey.mode),
              let mode = try? JSONDecoder().decode(LightMode.self, from: data) else {
            return .solid(RGBColor(r: 0xFF, g: 0xFF, b: 0xFF))
        }
        return mode
    }

    private static func loadBrightness(from defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: DefaultsKey.brightness) != nil else { return 1 }
        return defaults.double(forKey: DefaultsKey.brightness)
    }

    private static func loadIsEnabled(from defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: DefaultsKey.isEnabled) != nil else { return true }
        return defaults.bool(forKey: DefaultsKey.isEnabled)
    }
}
