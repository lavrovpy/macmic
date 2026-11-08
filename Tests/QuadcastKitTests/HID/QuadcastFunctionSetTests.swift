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
    private static let kingston = 0x0951
    private static let control = 0x171f
    private static let audio = 0x171d

    /// Both functions of one plugged-in mic, with the audio function matched
    /// first and at the lower entry id so the preference rule, not insertion
    /// or id order, decides the candidate order.
    private func pluggedInMic() -> QuadcastFunctionSet<String> {
        var set = QuadcastFunctionSet<String>()
        set.insert("audio", entryID: 1, vendorID: Self.kingston, productID: Self.audio)
        set.insert("control", entryID: 2, vendorID: Self.kingston, productID: Self.control)
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
        set.insert("c", entryID: 30, vendorID: Self.kingston, productID: Self.audio)
        set.insert("a", entryID: 10, vendorID: Self.kingston, productID: Self.audio)
        set.insert("b", entryID: 20, vendorID: Self.kingston, productID: Self.audio)

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
        set.insert("late", entryID: 99, vendorID: Self.kingston, productID: Self.audio)

        #expect(set.orderedCandidates.map(\.handle) == ["control", "audio", "late"])
    }

    @Test func removingTheActiveEntryClearsStickiness() {
        var set = pluggedInMic()
        set.markActive(1)

        _ = set.remove(entryID: 1)
        set.insert("audio again", entryID: 1, vendorID: Self.kingston, productID: Self.audio)

        #expect(set.orderedCandidates.map(\.handle) == ["control", "audio again"])
    }

    @Test func rematchOfTheSameEntryReturnsTheReplacedHandle() {
        var set = pluggedInMic()

        let replaced = set.insert("control v2", entryID: 2, vendorID: Self.kingston, productID: Self.control)

        #expect(replaced == "control")
        #expect(set.orderedCandidates.map(\.handle) == ["control v2", "audio"])
    }

    @Test func firstMatchReplacesNothing() {
        var set = QuadcastFunctionSet<String>()

        #expect(set.insert("control", entryID: 2, vendorID: Self.kingston, productID: Self.control) == nil)
    }

    @Test func removeAllReturnsEveryHandleAndClearsStickiness() {
        var set = pluggedInMic()
        set.markActive(1)

        let handles = set.removeAll()

        #expect(handles == ["audio", "control"])
        #expect(set.isEmpty)
        set.insert("audio again", entryID: 1, vendorID: Self.kingston, productID: Self.audio)
        set.insert("control again", entryID: 2, vendorID: Self.kingston, productID: Self.control)
        #expect(set.orderedCandidates.map(\.handle) == ["control again", "audio again"])
    }

    @Test(arguments: QuadcastCatalog.functions.filter { $0.role == .lighting })
    func everyCatalogLightingFunctionIsTriedBeforeTheAudioFunction(_ function: QuadcastUSBFunction) {
        var set = QuadcastFunctionSet<String>()
        set.insert("audio", entryID: 1, vendorID: Self.kingston, productID: Self.audio)
        set.insert("lighting", entryID: 2, vendorID: function.vendorID, productID: function.productID)

        #expect(set.orderedCandidates.map(\.productID) == [function.productID, Self.audio])
    }

    @Test func displayNameIsTheLightingFunctionsProductName() {
        var set = QuadcastFunctionSet<String>()
        set.insert("audio", entryID: 1, vendorID: Self.kingston, productID: Self.audio, productName: "Audio")
        set.insert(
            "control", entryID: 2, vendorID: Self.kingston, productID: Self.control, productName: "HyperX QuadCast S"
        )

        #expect(set.displayName == "HyperX QuadCast S")
        set.markActive(1)
        #expect(set.displayName == "HyperX QuadCast S")
    }

    @Test func displayNameFallsBackToTheCatalogName() {
        var quadcast2 = QuadcastFunctionSet<String>()
        quadcast2.insert("q2", entryID: 1, vendorID: 0x03f0, productID: 0x09af, productName: nil)
        var unnamed = QuadcastFunctionSet<String>()
        unnamed.insert("098c", entryID: 1, vendorID: 0x03f0, productID: 0x098c, productName: "  ")

        #expect(quadcast2.displayName == "HyperX QuadCast 2")
        #expect(unnamed.displayName == "HyperX DuoCast")
    }

    @Test func displayNameIsNilWhenEmpty() {
        var set = QuadcastFunctionSet<String>()
        #expect(set.displayName == nil)

        set.insert("control", entryID: 2, vendorID: Self.kingston, productID: Self.control)
        _ = set.removeAll()

        #expect(set.displayName == nil)
    }
}
