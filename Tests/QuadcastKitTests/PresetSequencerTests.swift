// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Testing
@testable import QuadcastKit

@Suite struct PresetSequencerTests {
    @Test func solidReturnsExactlyOneFrame() {
        let color = RGBColor(r: 0x12, g: 0x34, b: 0x56)
        let frames = PresetSequencer.frames(for: .solid(color))
        #expect(frames == [Frame(color: color)])
    }

    @Test func cycleFrameCountMatchesReferenceFormulaAtMinSpeed() {
        let frames = PresetSequencer.frames(for: .cycle(speed: 0))
        let expectedLength = PresetSequencer.maxCycleTransition
        #expect(frames.count == expectedLength * PresetSequencer.rainbowPalette.count)
    }

    @Test func cycleFrameCountMatchesReferenceFormulaAtMaxSpeed() {
        let frames = PresetSequencer.frames(for: .cycle(speed: 100))
        let expectedLength = PresetSequencer.minCycleTransition
        #expect(frames.count == expectedLength * PresetSequencer.rainbowPalette.count)
    }

    @Test func cycleFrameCountMatchesReferenceFormulaAtDefaultSpeed() {
        let frames = PresetSequencer.frames(for: .cycle(speed: 50))
        // Independently derived from get_gradient_length, not by calling
        // transitionLength(speed:) itself: 12 + (128 - 12) * (100 - 50) / 100
        // = 70 frames per transition, times 6 palette colors = 420.
        #expect(frames.count == 420)
    }

    @Test func cycleSequenceStartsAtFirstPaletteColor() {
        let frames = PresetSequencer.frames(for: .cycle(speed: 50))
        #expect(frames.first?.upper == PresetSequencer.rainbowPalette.first)
        #expect(frames.first?.lower == PresetSequencer.rainbowPalette.first)
    }

    @Test func cycleSequenceLoopsSmoothlyBackToStart() {
        // write_gradient's last written frame is exactly the transition's end
        // color, and the final transition wraps back to the first palette
        // color, so the sequence should end exactly where it began.
        let frames = PresetSequencer.frames(for: .cycle(speed: 50))
        #expect(frames.last?.upper == PresetSequencer.rainbowPalette.first)
        #expect(frames.last?.lower == PresetSequencer.rainbowPalette.first)
    }

    @Test func cycleSpeedClampsOutOfRangeInput() {
        let belowRange = PresetSequencer.frames(for: .cycle(speed: -50))
        let atMin = PresetSequencer.frames(for: .cycle(speed: 0))
        #expect(belowRange.count == atMin.count)

        let aboveRange = PresetSequencer.frames(for: .cycle(speed: 500))
        let atMax = PresetSequencer.frames(for: .cycle(speed: 100))
        #expect(aboveRange.count == atMax.count)
    }

    @Test func blinkIncludesOffDelayFrames() {
        let red = RGBColor(r: 0xFF, g: 0, b: 0)
        let black = RGBColor(r: 0, g: 0, b: 0)
        let frames = PresetSequencer.frames(for: .blink(colors: [red], speed: 50))

        let onCount = 101 - 50
        #expect(frames.count == onCount * 2)
        #expect(frames.prefix(onCount).allSatisfy { $0.upper == red })
        #expect(frames.suffix(onCount).allSatisfy { $0.upper == black })
    }

    @Test func blinkFrameCountMatchesReferenceFormulaForMultipleColors() {
        let colors = [
            RGBColor(r: 0xFF, g: 0, b: 0),
            RGBColor(r: 0, g: 0xFF, b: 0),
            RGBColor(r: 0, g: 0, b: 0xFF),
        ]
        let speed = 20
        let frames = PresetSequencer.frames(for: .blink(colors: colors, speed: speed))
        let segmentLength = (101 - speed) * 2
        #expect(frames.count == segmentLength * colors.count)

        // Each color's segment must appear in order, not just contribute to
        // the total count, so reordering/dropping/duplicating a color's
        // segment would fail this test even though the count matches.
        #expect(frames[0].upper == colors[0])
        #expect(frames[segmentLength].upper == colors[1])
        #expect(frames[segmentLength * 2].upper == colors[2])
    }

    @Test func blinkWithEmptyColorListReturnsNoFrames() {
        let frames = PresetSequencer.frames(for: .blink(colors: [], speed: 50))
        #expect(frames.isEmpty)
    }

    @Test func blinkSpeedClampsOutOfRangeInput() {
        let color = RGBColor(r: 1, g: 2, b: 3)
        let belowRange = PresetSequencer.frames(for: .blink(colors: [color], speed: -20))
        let atMin = PresetSequencer.frames(for: .blink(colors: [color], speed: 0))
        #expect(belowRange.count == atMin.count)

        let aboveRange = PresetSequencer.frames(for: .blink(colors: [color], speed: 250))
        let atMax = PresetSequencer.frames(for: .blink(colors: [color], speed: 100))
        #expect(aboveRange.count == atMax.count)
    }
}
