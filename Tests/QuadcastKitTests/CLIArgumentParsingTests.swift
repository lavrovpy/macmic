// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Testing
@testable import macmic_cli
@testable import QuadcastKit

@Suite struct CLIArgumentParsingTests {
    @Test func parseBrightnessReadsFlagValue() {
        #expect(parseBrightness(["FF0000", "--brightness", "0.5"]) == 0.5)
    }

    @Test func parseBrightnessDefaultsToOneWhenFlagMissing() {
        #expect(parseBrightness(["FF0000"]) == 1.0)
    }

    @Test func parseBrightnessDefaultsToOneWhenValueIsNotANumber() {
        #expect(parseBrightness(["FF0000", "--brightness", "bright"]) == 1.0)
    }

    @Test func parseSpeedReadsFlagValue() {
        #expect(parseSpeed(["--speed", "80"]) == 80)
    }

    @Test func parseSpeedDefaultsToFiftyWhenFlagMissing() {
        #expect(parseSpeed([]) == 50)
    }

    @Test func parseSpeedDefaultsToFiftyWhenValueIsNotANumber() {
        #expect(parseSpeed(["--speed", "fast"]) == 50)
    }

    @Test func colorArgumentsStripsFlagsAndTheirValues() {
        #expect(colorArguments(["FF0000", "--speed", "40", "00FF00"]) == ["FF0000", "00FF00"])
    }

    /// Regression test for the bug fixed in 3f6dc65: a flag's numeric value
    /// (e.g. `123456` in `--speed 123456`) is itself valid 6-digit hex and
    /// must not be misparsed as an extra color.
    @Test func colorArgumentsDoesNotTreatAFlagsHexLikeValueAsAColor() {
        #expect(colorArguments(["FF0000", "--speed", "123456", "--brightness", "1"]) == ["FF0000"])
    }

    @Test func colorArgumentsReturnsEmptyForNoPositionalArguments() {
        #expect(colorArguments(["--speed", "50", "--brightness", "1"]).isEmpty)
    }

    @Test func parseAudioCommandStatus() {
        #expect(parseAudioCommand(["status"]) == .status)
    }

    @Test func parseAudioCommandGainConvertsPercentToScalar() {
        #expect(parseAudioCommand(["gain", "40"]) == .setVolume(0.4, .input))
        #expect(parseAudioCommand(["gain", "0"]) == .setVolume(0, .input))
        #expect(parseAudioCommand(["gain", "100"]) == .setVolume(1, .input))
    }

    @Test func parseAudioCommandMonitorAndMonitorMute() {
        #expect(parseAudioCommand(["monitor", "25"]) == .setVolume(0.25, .output))
        #expect(parseAudioCommand(["monitor-mute", "on"]) == .setMuted(true, .output))
        #expect(parseAudioCommand(["monitor-mute", "off"]) == .setMuted(false, .output))
    }

    @Test func parseAudioCommandMuteOnOff() {
        #expect(parseAudioCommand(["mute", "on"]) == .setMuted(true, .input))
        #expect(parseAudioCommand(["mute", "off"]) == .setMuted(false, .input))
        #expect(parseAudioCommand(["mute", "ON"]) == .setMuted(true, .input))
    }

    @Test func parseAudioCommandRejectsUnknownVerbMissingValueAndExtraArguments() {
        #expect(parseAudioCommand([]) == nil)
        #expect(parseAudioCommand(["volume", "40"]) == nil)
        #expect(parseAudioCommand(["gain"]) == nil)
        #expect(parseAudioCommand(["mute"]) == nil)
        #expect(parseAudioCommand(["status", "now"]) == nil)
        #expect(parseAudioCommand(["gain", "40", "extra"]) == nil)
        #expect(parseAudioCommand(["gain", "101"]) == nil)
        #expect(parseAudioCommand(["mute", "yes"]) == nil)
    }

    @Test func parsePercentBounds() {
        #expect(parsePercent("0") == 0)
        #expect(parsePercent("100") == 1)
        #expect(parsePercent("50") == 0.5)
        #expect(parsePercent("101") == nil)
        #expect(parsePercent("-1") == nil)
        #expect(parsePercent("abc") == nil)
        #expect(parsePercent("50.5") == nil)
        #expect(parsePercent("") == nil)
    }

    @Test func parseOnOffIsStrict() {
        #expect(parseOnOff("on") == true)
        #expect(parseOnOff("off") == false)
        #expect(parseOnOff("Off") == false)
        #expect(parseOnOff("1") == nil)
        #expect(parseOnOff("yes") == nil)
        #expect(parseOnOff("") == nil)
    }

    @Test func formatAudioStatusListsBothDirections() {
        let text = formatAudioStatus(.sample)
        #expect(text == """
            input  (microphone): gain 68% (+2.1 dB), mute off
            output (monitoring): volume 81% (-12.1 dB), mute off
            """)
    }

    @Test func formatAudioStatusShowsNotFoundForAbsentDirection() {
        let snapshot = AudioDeviceSnapshot(
            input: AudioLevel(volume: 0.5, isMuted: true, decibels: nil),
            output: nil
        )
        #expect(formatAudioStatus(snapshot) == """
            input  (microphone): gain 50%, mute on
            output (monitoring): not found
            """)
        #expect(formatAudioStatus(.unavailable) == """
            input  (microphone): not found
            output (monitoring): not found
            """)
    }
}
