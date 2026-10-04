// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Foundation
import Testing
@testable import MacMic
@testable import QuadcastKit

/// `LightingSettings` as a pure value: mode switching with per-mode memory,
/// the blink-list edits, clamping, sanitizing and `Codable`.
@Suite struct LightingSettingsTests {
    private static let colorA = RGBColor(r: 0xAA, g: 0xBB, b: 0xCC)
    private static let colorB = RGBColor(r: 1, g: 2, b: 3)
    private static let colorC = RGBColor(r: 4, g: 5, b: 6)

    @Test func defaultIsWhiteSolidFullBrightnessEnabled() {
        let settings = LightingSettings.default

        #expect(settings.mode == .solid(RGBColor(r: 0xFF, g: 0xFF, b: 0xFF)))
        #expect(settings.brightness == 1)
        #expect(settings.isEnabled == true)
        #expect(settings.lastPresetSpeed == LightingSettings.defaultPresetSpeed)
        #expect(settings.lastBlinkColors == nil)
    }

    @Test func modeKindReflectsActiveMode() {
        #expect(LightingSettings(mode: .solid(Self.colorA)).modeKind == .solid)
        #expect(LightingSettings(mode: .cycle(speed: 10)).modeKind == .cycle)
        #expect(LightingSettings(mode: .blink(colors: [Self.colorA], speed: 10)).modeKind == .blink)
    }

    @Test func switchingModeKindRestoresEachModesRememberedPayload() {
        var settings = LightingSettings(mode: .solid(Self.colorA))
        settings.setBlinkColor(Self.colorB, at: 0)
        settings.duplicateBlinkColor(at: 0)
        settings.setBlinkColor(Self.colorC, at: 1)
        settings.presetSpeed = 77

        settings.modeKind = .cycle
        #expect(settings.mode == .cycle(speed: 77))

        settings.modeKind = .solid
        #expect(settings.mode == .solid(Self.colorA))

        settings.modeKind = .blink
        #expect(settings.mode == .blink(colors: [Self.colorB, Self.colorC], speed: 77))
    }

    /// Before Blink has ever been used it starts from the solid color, not
    /// from a fixed white.
    @Test func firstBlinkSeedsFromSolidColorAtDefaultSpeed() {
        var settings = LightingSettings(mode: .solid(Self.colorA))

        settings.modeKind = .blink

        #expect(settings.mode == .blink(colors: [Self.colorA], speed: LightingSettings.defaultPresetSpeed))
    }

    @Test func reselectingCurrentModeKindLeavesSettingsEqual() {
        var settings = LightingSettings(mode: .cycle(speed: 33))
        let before = settings

        settings.modeKind = .cycle

        #expect(settings == before)
    }

    @Test func solidColorFallsBackToLastSolidColorWhilePresetActive() {
        var settings = LightingSettings(mode: .solid(Self.colorA))

        settings.modeKind = .cycle
        #expect(settings.solidColor == Self.colorA)

        settings.modeKind = .blink
        #expect(settings.solidColor == Self.colorA)
    }

    @Test func settingSolidColorSwitchesToSolid() {
        var settings = LightingSettings(mode: .cycle(speed: 50))

        settings.solidColor = Self.colorB

        #expect(settings.mode == .solid(Self.colorB))
        #expect(settings.lastSolidColor == Self.colorB)
    }

    @Test func presetSpeedUpdatesActivePresetInPlaceAndClamps() {
        var settings = LightingSettings(mode: .blink(colors: [Self.colorA], speed: 50))

        settings.presetSpeed = 80
        #expect(settings.mode == .blink(colors: [Self.colorA], speed: 80))
        #expect(settings.presetSpeed == 80)

        settings.presetSpeed = 500
        #expect(settings.mode == .blink(colors: [Self.colorA], speed: 100))

        settings.modeKind = .cycle
        settings.presetSpeed = -3
        #expect(settings.mode == .cycle(speed: 0))
    }

    @Test func presetSpeedShowsLastPresetSpeedWhileSolidAndIgnoresSets() {
        var settings = LightingSettings(mode: .cycle(speed: 64))
        settings.solidColor = Self.colorB

        #expect(settings.presetSpeed == 64)

        settings.presetSpeed = 10

        #expect(settings.mode == .solid(Self.colorB))
        #expect(settings.presetSpeed == 64)
    }

    @Test func blinkColorsSurviveSwitchingToAnotherModeAndBack() {
        let colors = [Self.colorB, Self.colorC]
        var settings = LightingSettings(mode: .blink(colors: colors, speed: 25))

        settings.modeKind = .solid
        #expect(settings.blinkColors == colors)
        settings.modeKind = .cycle
        #expect(settings.blinkColors == colors)

        settings.modeKind = .blink
        #expect(settings.mode == .blink(colors: colors, speed: 25))
    }

    @Test func duplicateBlinkColorAppendsCopyAndReturnsItsIndex() {
        var settings = LightingSettings(mode: .blink(colors: [Self.colorA, Self.colorB, Self.colorC], speed: 25))

        let index = settings.duplicateBlinkColor(at: 1)

        #expect(index == 3)
        #expect(settings.mode == .blink(colors: [Self.colorA, Self.colorB, Self.colorC, Self.colorB], speed: 25))
    }

    @Test func removeBlinkColorRefusesTheLastColor() {
        var settings = LightingSettings(mode: .blink(colors: [Self.colorA], speed: 25))
        #expect(settings.canRemoveBlinkColor == false)

        let next = settings.removeBlinkColor(at: 0)

        #expect(next == nil)
        #expect(settings.mode == .blink(colors: [Self.colorA], speed: 25))
    }

    @Test func removeBlinkColorReturnsInRangeSelection() {
        var settings = LightingSettings(mode: .blink(colors: [Self.colorA, Self.colorB, Self.colorC], speed: 25))
        #expect(settings.canRemoveBlinkColor == true)

        #expect(settings.removeBlinkColor(at: 1) == 1)
        #expect(settings.blinkColors == [Self.colorA, Self.colorC])

        #expect(settings.removeBlinkColor(at: 1) == 0) // removed the last entry
        #expect(settings.blinkColors == [Self.colorA])
        #expect(settings.lastBlinkColors == [Self.colorA])
    }

    @Test func setBlinkColorReplacesInPlaceAndSwitchesToBlink() {
        var settings = LightingSettings(mode: .blink(colors: [Self.colorA, Self.colorB], speed: 25))
        settings.modeKind = .cycle
        settings.presetSpeed = 60

        settings.setBlinkColor(Self.colorC, at: 1)

        #expect(settings.mode == .blink(colors: [Self.colorA, Self.colorC], speed: 60))

        settings.setBlinkColor(Self.colorB, at: 9) // clamped to the last index
        #expect(settings.blinkColors == [Self.colorA, Self.colorB])
    }

    @Test func blinkIndexClampsPastTheEnd() {
        let settings = LightingSettings(mode: .blink(colors: [Self.colorA, Self.colorB], speed: 25))

        #expect(settings.blinkIndex(clamping: 0) == 0)
        #expect(settings.blinkIndex(clamping: 1) == 1)
        #expect(settings.blinkIndex(clamping: 5) == 1)
        #expect(settings.blinkIndex(clamping: -1) == 0)
    }

    @Test func brightnessIsClampedToUnitRange() {
        var settings = LightingSettings.default

        settings.brightness = 1.5
        #expect(settings.brightness == 1)
        settings.brightness = -0.2
        #expect(settings.brightness == 0)
        settings.brightness = 0.4
        #expect(settings.brightness == 0.4)

        #expect(LightingSettings(brightness: 7).brightness == 1)
    }

    @Test func initSanitizesPayload() {
        let solidWins = LightingSettings(mode: .solid(Self.colorA), lastSolidColor: Self.colorB)
        #expect(solidWins.lastSolidColor == Self.colorA)

        let cycleWins = LightingSettings(mode: .cycle(speed: 500), lastPresetSpeed: 20)
        #expect(cycleWins.mode == .cycle(speed: 100))
        #expect(cycleWins.lastPresetSpeed == 100)

        let blinkWins = LightingSettings(
            mode: .blink(colors: [Self.colorA], speed: -4),
            lastPresetSpeed: 20,
            lastBlinkColors: [Self.colorB]
        )
        #expect(blinkWins.mode == .blink(colors: [Self.colorA], speed: 0))
        #expect(blinkWins.lastBlinkColors == [Self.colorA])

        #expect(LightingSettings(lastPresetSpeed: 900).lastPresetSpeed == 100)
        #expect(LightingSettings(lastBlinkColors: []).lastBlinkColors == nil)

        let emptyBlink = LightingSettings(mode: .blink(colors: [], speed: 30), lastBlinkColors: [Self.colorB])
        #expect(emptyBlink.mode == .blink(colors: [Self.colorB], speed: 30))

        let emptyBlinkNoMemory = LightingSettings(mode: .blink(colors: [], speed: 30), lastSolidColor: Self.colorC)
        #expect(emptyBlinkNoMemory.mode == .blink(colors: [Self.colorC], speed: 30))
        #expect(emptyBlinkNoMemory.lastBlinkColors == [Self.colorC])
    }

    @Test func codableRoundTrip() throws {
        var settings = LightingSettings(mode: .solid(Self.colorA))
        settings.setBlinkColor(Self.colorB, at: 0)
        settings.presetSpeed = 12
        settings.modeKind = .cycle
        settings.brightness = 0.25
        settings.isEnabled = false

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(LightingSettings.self, from: data)

        #expect(decoded == settings)
        #expect(try JSONDecoder().decode(LightingSettings.self, from: JSONEncoder().encode(LightingSettings.default)) == .default)
    }

    /// A blob written by another build: missing and wrongly typed fields
    /// take their defaults, the rest still load.
    @Test func decodingFillsMissingFieldsWithDefaults() throws {
        let json = #"{"brightness": 0.3, "isEnabled": "yes", "lastPresetSpeed": 70, "futureField": 1}"#

        let decoded = try JSONDecoder().decode(LightingSettings.self, from: Data(json.utf8))

        #expect(decoded == LightingSettings(brightness: 0.3, lastPresetSpeed: 70))
        #expect(decoded.mode == .solid(LightingSettings.defaultColor))
        #expect(decoded.isEnabled == true)
        #expect(decoded.lastPresetSpeed == 70)
    }
}
