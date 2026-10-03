// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Testing
@testable import QuadcastKit

@Suite struct QuadcastFunctionSetTests {
    private static let control = 0x171f
    private static let audio = 0x171d

    /// Both functions of one plugged-in mic, with the audio function matched
    /// first and at the lower entry id so the preference rule, not insertion
    /// or id order, decides the candidate order.
    private func pluggedInMic() -> QuadcastFunctionSet<String> {
        var set = QuadcastFunctionSet<String>()
        set.insert("audio", entryID: 1, productID: Self.audio)
        set.insert("control", entryID: 2, productID: Self.control)
        return set
    }

    @Test func removingTheAudioFunctionAloneDoesNotEmptyTheSet() throws {
        var set = pluggedInMic()

        let removed = set.remove(entryID: 1)

        let removal = try #require(removed)
        #expect(removal.handle == "audio")
        #expect(removal.isEmpty == false)
        #expect(set.isEmpty == false)
        #expect(set.orderedCandidates.map(\.handle) == ["control"])
    }

    @Test func removingTheLastFunctionEmptiesTheSet() throws {
        var set = pluggedInMic()
        _ = set.remove(entryID: 2)

        let removed = set.remove(entryID: 1)

        let removal = try #require(removed)
        #expect(removal.isEmpty)
        #expect(set.isEmpty)
        #expect(set.orderedCandidates.isEmpty)
    }

    @Test func removingAnUnknownEntryIsIgnored() {
        var set = pluggedInMic()

        let removed = set.remove(entryID: 99)

        #expect(removed == nil)
        #expect(set.orderedCandidates.count == 2)
    }

    @Test func preferredProductComesFirst() {
        let set = pluggedInMic()

        #expect(set.orderedCandidates.map(\.productID) == [Self.control, Self.audio])
    }

    @Test func remainingCandidatesAreOrderedByEntryID() {
        var set = QuadcastFunctionSet<String>()
        set.insert("c", entryID: 30, productID: Self.audio)
        set.insert("a", entryID: 10, productID: Self.audio)
        set.insert("b", entryID: 20, productID: Self.audio)

        #expect(set.orderedCandidates.map(\.handle) == ["a", "b", "c"])
    }

    @Test func activeEntryComesFirst() {
        var set = pluggedInMic()

        set.markActive(1)

        #expect(set.orderedCandidates.map(\.handle) == ["audio", "control"])
    }

    @Test func markingAnUnknownEntryActiveIsIgnored() {
        var set = pluggedInMic()

        set.markActive(99)
        set.insert("late", entryID: 99, productID: Self.audio)

        #expect(set.orderedCandidates.map(\.handle) == ["control", "audio", "late"])
    }

    @Test func removingTheActiveEntryClearsStickiness() {
        var set = pluggedInMic()
        set.markActive(1)

        _ = set.remove(entryID: 1)
        set.insert("audio again", entryID: 1, productID: Self.audio)

        #expect(set.orderedCandidates.map(\.handle) == ["control", "audio again"])
    }

    @Test func rematchOfTheSameEntryReturnsTheReplacedHandle() {
        var set = pluggedInMic()

        let replaced = set.insert("control v2", entryID: 2, productID: Self.control)

        #expect(replaced == "control")
        #expect(set.orderedCandidates.map(\.handle) == ["control v2", "audio"])
    }

    @Test func firstMatchReplacesNothing() {
        var set = QuadcastFunctionSet<String>()

        #expect(set.insert("control", entryID: 2, productID: Self.control) == nil)
    }

    @Test func removeAllReturnsEveryHandleAndClearsStickiness() {
        var set = pluggedInMic()
        set.markActive(1)

        let handles = set.removeAll()

        #expect(handles == ["audio", "control"])
        #expect(set.isEmpty)
        set.insert("audio again", entryID: 1, productID: Self.audio)
        set.insert("control again", entryID: 2, productID: Self.control)
        #expect(set.orderedCandidates.map(\.handle) == ["control again", "audio again"])
    }
}
