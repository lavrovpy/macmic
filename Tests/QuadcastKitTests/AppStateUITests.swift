// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Dispatch
import Foundation
import SwiftUI
import Testing
@testable import MacMic
@testable import QuadcastKit

/// Tests for the UI-facing derivations layered on top of Task 7's `AppState`
/// (`solidColor`, `modeKind`, `presetSpeed`, `blinkColors`, `controlsEnabled`,
/// `connectionStatusText`), shared by the status menu and the main
/// window. Kept separate from `AppStateTests` (which covers the core
/// persistence/hotplug model those derivations read from).
@Suite struct AppStateUITests {
    private static func freshDefaults(name: String = #function) -> UserDefaults {
        let suiteName = "dev.alavreniuk.macmic.tests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeState(
        transport: HIDTransport = MockHIDTransport(),
        audioControl: AudioDeviceControl = MockAudioDeviceControl()
    ) -> AppState {
        AppState(
            transport: transport,
            audioControl: audioControl,
            microphoneMonitor: MockMicrophoneMonitor(),
            defaults: Self.freshDefaults(),
            notificationCenter: NotificationCenter(),
            streamerInterval: .seconds(3600)
        )
    }

    @Test func controlsEnabledMirrorsConnectionState() throws {
        let transport = MockHIDTransport()
        let state = makeState(transport: transport)
        #expect(state.controlsEnabled == true)

        transport.simulateRemoval()
        #expect(state.controlsEnabled == false)

        transport.simulateConnect()
        #expect(state.controlsEnabled == true)
    }

    @Test func connectionStatusTextReflectsConnectionState() throws {
        let transport = MockHIDTransport()
        let state = makeState(transport: transport)
        #expect(state.connectionStatusText == "QuadCast S connected")

        transport.simulateRemoval()
        #expect(state.connectionStatusText == "QuadCast S not found")
    }

    @Test func solidColorReflectsCurrentSolidMode() throws {
        let state = makeState()
        state.mode = .solid(RGBColor(r: 0x10, g: 0x20, b: 0x30))

        #expect(rgbColor(from: state.solidColor) == RGBColor(r: 0x10, g: 0x20, b: 0x30))
    }

    @Test func solidColorFallsBackToWhiteWhenModeIsNotSolid() throws {
        let state = makeState()
        state.mode = .cycle(speed: 50)

        #expect(rgbColor(from: state.solidColor) == RGBColor(r: 0xFF, g: 0xFF, b: 0xFF))
    }

    @Test func settingSolidColorSwitchesModeToSolid() throws {
        let state = makeState()
        state.mode = .cycle(speed: 50)

        state.solidColor = .init(.sRGB, red: 1, green: 0, blue: 0, opacity: 1)

        #expect(state.mode == .solid(RGBColor(r: 0xFF, g: 0, b: 0)))
    }

    @Test func solidColorSurvivesSwitchingToAndFromAPreset() throws {
        let state = makeState()
        state.mode = .solid(RGBColor(r: 0xAA, g: 0xBB, b: 0xCC))

        state.mode = .cycle(speed: 50)
        #expect(rgbColor(from: state.solidColor) == RGBColor(r: 0xAA, g: 0xBB, b: 0xCC))

        state.mode = .blink(colors: [RGBColor(r: 1, g: 2, b: 3)], speed: 50)
        #expect(rgbColor(from: state.solidColor) == RGBColor(r: 0xAA, g: 0xBB, b: 0xCC))
    }

    // MARK: modeKind

    @Test func modeKindReflectsActiveMode() throws {
        let state = makeState()

        state.mode = .solid(RGBColor(r: 1, g: 2, b: 3))
        #expect(state.modeKind == .solid)
        state.mode = .cycle(speed: 10)
        #expect(state.modeKind == .cycle)
        state.mode = .blink(colors: [RGBColor(r: 1, g: 2, b: 3)], speed: 10)
        #expect(state.modeKind == .blink)
    }

    @Test func switchingModeKindRestoresEachModesRememberedPayload() throws {
        let state = makeState()
        let solid = RGBColor(r: 0x11, g: 0x22, b: 0x33)
        let blinkColors = [RGBColor(r: 1, g: 1, b: 1), RGBColor(r: 2, g: 2, b: 2)]
        state.mode = .solid(solid)
        state.mode = .blink(colors: blinkColors, speed: 77)

        state.modeKind = .cycle
        #expect(state.mode == .cycle(speed: 77))

        state.modeKind = .solid
        #expect(state.mode == .solid(solid))

        state.modeKind = .blink
        #expect(state.mode == .blink(colors: blinkColors, speed: 77))
    }

    /// Before the user has ever used Blink, it starts from the solid color,
    /// not from a fixed white.
    @Test func firstBlinkSeedsFromSolidColorAtDefaultSpeed() throws {
        let state = makeState()
        let solid = RGBColor(r: 0xAA, g: 0x00, b: 0x55)
        state.mode = .solid(solid)

        state.modeKind = .blink

        #expect(state.mode == .blink(colors: [solid], speed: AppState.defaultPresetSpeed))
    }

    /// Re-selecting the active kind (e.g. a `Picker` reporting the same
    /// segment) must not touch `mode`, or a running animation would restart.
    @Test func reselectingCurrentModeKindIsANoOp() throws {
        let transport = MockHIDTransport()
        let state = makeState(transport: transport)
        let mode = LightMode.cycle(speed: 33)
        let expectedFrames = PresetSequencer.frames(for: mode)
        state.mode = mode
        state.streamer.tick() // sends frame 0

        state.modeKind = .cycle
        state.streamer.tick() // must continue with frame 1, not restart at 0

        #expect(state.mode == mode)
        #expect(transport.sentReports.last == expectedFrames[1].dataPacket())
    }

    // MARK: presetSpeed

    @Test func presetSpeedUpdatesActivePresetInPlaceAndClamps() throws {
        let state = makeState()
        let colors = [RGBColor(r: 5, g: 6, b: 7)]
        state.mode = .blink(colors: colors, speed: 50)

        state.presetSpeed = 80
        #expect(state.mode == .blink(colors: colors, speed: 80))
        #expect(state.presetSpeed == 80)

        state.presetSpeed = 500
        #expect(state.mode == .blink(colors: colors, speed: 100))

        state.mode = .cycle(speed: 50)
        state.presetSpeed = -3
        #expect(state.mode == .cycle(speed: 0))
    }

    @Test func presetSpeedShowsLastPresetSpeedWhileSolidAndIgnoresSets() throws {
        let state = makeState()
        state.mode = .cycle(speed: 64)
        state.mode = .solid(RGBColor(r: 1, g: 1, b: 1))

        #expect(state.presetSpeed == 64)

        state.presetSpeed = 10

        #expect(state.mode == .solid(RGBColor(r: 1, g: 1, b: 1)))
        #expect(state.presetSpeed == 64)
    }

    // MARK: blinkColors

    @Test func settingBlinkColorsSwitchesToBlinkKeepingSpeed() throws {
        let state = makeState()
        state.mode = .cycle(speed: 25)
        let colors = [RGBColor(r: 9, g: 8, b: 7), RGBColor(r: 6, g: 5, b: 4)]

        state.blinkColors = colors

        #expect(state.mode == .blink(colors: colors, speed: 25))
        #expect(state.blinkColors == colors)
    }

    @Test func emptyBlinkColorsAreRejected() throws {
        let state = makeState()
        let colors = [RGBColor(r: 9, g: 8, b: 7)]
        state.mode = .blink(colors: colors, speed: 25)

        state.blinkColors = []

        #expect(state.mode == .blink(colors: colors, speed: 25))
    }

    @Test func blinkColorsSurviveSwitchingToAnotherModeAndBack() throws {
        let state = makeState()
        let colors = [RGBColor(r: 9, g: 8, b: 7), RGBColor(r: 6, g: 5, b: 4)]
        state.mode = .blink(colors: colors, speed: 25)

        state.modeKind = .solid
        #expect(state.blinkColors == colors)
        state.modeKind = .cycle
        #expect(state.blinkColors == colors)

        state.modeKind = .blink
        #expect(state.mode == .blink(colors: colors, speed: 25))
    }
}
