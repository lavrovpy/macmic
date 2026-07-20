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

/// Tests for the menu bar's UI-facing derivations layered on top of Task 7's
/// `AppState` (`solidColor`, `controlsEnabled`, `connectionStatusText`), kept
/// separate from `AppStateTests` (which covers the core persistence/hotplug
/// model those derivations read from).
@Suite struct AppStateUITests {
    private static func freshDefaults(name: String = #function) -> UserDefaults {
        let suiteName = "dev.alavreniuk.macmic.tests.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeState(transport: HIDTransport = MockHIDTransport()) -> AppState {
        AppState(
            transport: transport,
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
}
