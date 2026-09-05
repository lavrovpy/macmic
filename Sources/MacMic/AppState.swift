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
        static let lastSolidColor = "dev.alavreniuk.macmic.lastSolidColor"
        static let lastPresetSpeed = "dev.alavreniuk.macmic.lastPresetSpeed"
        static let lastBlinkColors = "dev.alavreniuk.macmic.lastBlinkColors"
    }

    /// Whether a QuadCast HID/USB service is currently matched. Controls
    /// vary their enabled/disabled UI state on this.
    @Published public private(set) var isConnected = false

    @Published public var mode: LightMode {
        didSet {
            switch mode {
            case .solid(let rgb):
                lastSolidColor = rgb
                defaults.set((try? JSONEncoder().encode(rgb)) ?? Data(), forKey: DefaultsKey.lastSolidColor)
            case .cycle(let speed):
                lastPresetSpeed = speed
                defaults.set(speed, forKey: DefaultsKey.lastPresetSpeed)
            case .blink(let colors, let speed):
                lastPresetSpeed = speed
                lastBlinkColors = colors
                defaults.set(speed, forKey: DefaultsKey.lastPresetSpeed)
                defaults.set((try? JSONEncoder().encode(colors)) ?? Data(), forKey: DefaultsKey.lastBlinkColors)
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

    /// The speed of the last active preset (`.cycle`/`.blink`), kept across
    /// mode switches so returning to a preset resumes at the speed the user
    /// set rather than `AppState.defaultPresetSpeed`. Backs
    /// `AppState.presetSpeed` while `.solid` is active.
    @Published public private(set) var lastPresetSpeed: Int

    /// The color list of the last active `.blink` mode, kept while another
    /// mode is active so switching away and back doesn't collapse a
    /// multi-color blink to a single color. `nil` until Blink has ever been
    /// used, so the UI can seed the first blink from the *current*
    /// `lastSolidColor` (`AppState.blinkColors`) instead of a color frozen at
    /// launch. Never empty: an empty list would produce zero frames.
    @Published public private(set) var lastBlinkColors: [QuadcastKit.RGBColor]?

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
        let loadedSolidColor: QuadcastKit.RGBColor
        if case .solid(let rgb) = loadedMode {
            loadedSolidColor = rgb
        } else {
            loadedSolidColor = Self.loadLastSolidColor(from: defaults)
        }
        self.lastSolidColor = loadedSolidColor
        switch loadedMode {
        case .solid:
            self.lastPresetSpeed = Self.loadLastPresetSpeed(from: defaults)
            self.lastBlinkColors = Self.loadLastBlinkColors(from: defaults)
        case .cycle(let speed):
            self.lastPresetSpeed = speed
            self.lastBlinkColors = Self.loadLastBlinkColors(from: defaults)
        case .blink(let colors, let speed):
            self.lastPresetSpeed = speed
            self.lastBlinkColors = colors.isEmpty ? nil : colors
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

        // `open()` succeeding only means the IOKit matching notifications were
        // registered, not that a device is actually present yet: for
        // `IOUSBHostTransport`, any already-matched device is reported
        // asynchronously through `onDeviceConnected` (see its `handleMatched`),
        // so `isConnected` must wait for that callback rather than being set
        // here — otherwise the UI would show "connected" even with no mic
        // plugged in.
        try? transport.open()
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

    private static func loadLastSolidColor(from defaults: UserDefaults) -> QuadcastKit.RGBColor {
        guard let data = defaults.data(forKey: DefaultsKey.lastSolidColor),
              let rgb = try? JSONDecoder().decode(QuadcastKit.RGBColor.self, from: data) else {
            return QuadcastKit.RGBColor(r: 0xFF, g: 0xFF, b: 0xFF)
        }
        return rgb
    }

    private static func loadLastPresetSpeed(from defaults: UserDefaults) -> Int {
        guard defaults.object(forKey: DefaultsKey.lastPresetSpeed) != nil else { return defaultPresetSpeed }
        return PresetSequencer.clampSpeed(defaults.integer(forKey: DefaultsKey.lastPresetSpeed))
    }

    private static func loadLastBlinkColors(from defaults: UserDefaults) -> [QuadcastKit.RGBColor]? {
        guard let data = defaults.data(forKey: DefaultsKey.lastBlinkColors),
              let colors = try? JSONDecoder().decode([QuadcastKit.RGBColor].self, from: data),
              !colors.isEmpty else {
            return nil
        }
        return colors
    }
}
