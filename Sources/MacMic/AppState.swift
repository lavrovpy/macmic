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
/// (Task 8) only has to bind to `@Published` properties. Also owns the
/// mic's Core Audio state (`audio`), which has its own hotplug lifecycle.
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

    /// Live mute/volume state of the mic's Core Audio devices. Not persisted:
    /// macOS and the mic keep these values themselves, and every other app
    /// (Sound settings, the mic's gain knob) writes the same properties.
    /// Availability is independent of `isConnected` (lighting) — the audio
    /// side is a different USB function.
    @Published public private(set) var audio: AudioDeviceSnapshot = .unavailable

    /// Incoming volume within this distance of the current value is treated
    /// as the HAL echoing our own write (it quantizes the scalar) and doesn't
    /// move the slider; external nudges under 1% are swallowed until a larger
    /// change arrives.
    static let audioEchoTolerance: Float = 0.01

    /// The "Test Microphone" pass-through (mic → system default output).
    /// Transient and never persisted: it stops when the input device
    /// disappears, on sleep, when the Audio page goes away, and in `deinit`,
    /// and is never resumed on its own.
    @Published public private(set) var micTestState: MicrophoneMonitorState = .stopped

    /// Normalized input level (`0...1`) while `micTestState` is `.running`;
    /// `0` otherwise. Reports the clip instead of the live input while one
    /// is playing back.
    @Published public private(set) var micTestLevel: Float = 0

    /// The record/playback half of the test; only ever leaves `.idle` while
    /// `micTestState` is `.running`, and loses its clip when the test stops.
    @Published public private(set) var micRecorderState: MicrophoneRecorderState = .idle(clipDuration: nil)

    private let transport: HIDTransport
    private let audioControl: AudioDeviceControl
    private let microphoneMonitor: MicrophoneMonitor
    /// Internal (not private) so tests can call `tick()` for a deterministic
    /// synchronous send, the same pattern `FrameStreamerTests` uses.
    let streamer: FrameStreamer
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private var observerTokens: [NSObjectProtocol] = []

    /// - Parameters:
    ///   - transport: the `HIDTransport` to stream frames over; `open()` is
    ///     called as part of initialization.
    ///   - audioControl: the `AudioDeviceControl` for gain/mute; also opened
    ///     here. Required (no default) so a test can never construct a real
    ///     Core Audio control by accident.
    ///   - microphoneMonitor: the pass-through behind "Test Microphone";
    ///     required for the same reason.
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
        audioControl: AudioDeviceControl,
        microphoneMonitor: MicrophoneMonitor,
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        streamerInterval: DispatchTimeInterval = .milliseconds(55)
    ) {
        self.transport = transport
        self.audioControl = audioControl
        self.microphoneMonitor = microphoneMonitor
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
        audioControl.onStateChanged = { [weak self] in self?.handleAudioStateChanged($0) }
        microphoneMonitor.onStateChanged = { [weak self] in self?.handleMicTestStateChanged($0) }
        microphoneMonitor.onLevel = { [weak self] in self?.handleMicTestLevel($0) }
        microphoneMonitor.onRecorderStateChanged = { [weak self] in self?.micRecorderState = $0 }

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
        // Same contract: presence arrives via `onStateChanged`, not here.
        try? audioControl.open()
    }

    deinit {
        for token in observerTokens {
            notificationCenter.removeObserver(token)
        }
        streamer.stop()
        microphoneMonitor.stop()
        transport.close()
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
        if audio.input == nil {
            stopMicTest()
        }
    }

    // MARK: Microphone test

    /// Starts passing the mic through the system default output. Ignored
    /// while the input device is absent. The device id is read at call time:
    /// the HAL reassigns it on every re-enumeration of the audio function.
    public func startMicTest() {
        guard audio.input != nil, let device = audioControl.deviceID(for: .input) else { return }
        microphoneMonitor.start(inputDevice: device)
    }

    public func stopMicTest() {
        microphoneMonitor.stop()
    }

    /// Records the live input into a clip (up to `micMaxClipDuration`),
    /// replacing the previous one. Ignored unless the test is running.
    public func startMicRecording() {
        guard case .running = micTestState else { return }
        microphoneMonitor.startRecording()
    }

    public func stopMicRecording() {
        microphoneMonitor.stopRecording()
    }

    /// Plays the recorded clip through the test's output, muting the live
    /// pass-through meanwhile. Ignored unless the test is running.
    public func playMicRecording() {
        guard case .running = micTestState else { return }
        microphoneMonitor.startPlayback()
    }

    public func stopMicPlayback() {
        microphoneMonitor.stopPlayback()
    }

    public var micMaxClipDuration: TimeInterval {
        microphoneMonitor.maxClipDuration
    }

    private func handleMicTestStateChanged(_ newState: MicrophoneMonitorState) {
        micTestState = newState
        if case .running = newState {} else {
            micTestLevel = 0
        }
    }

    private func handleMicTestLevel(_ level: Float) {
        guard case .running = micTestState else { return }
        micTestLevel = level
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
        stopMicTest()
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
