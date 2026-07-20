// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Testing
@testable import macmic_cli

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
}
