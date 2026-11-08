// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Testing
@testable import QuadcastKit

@Suite struct QuadcastCatalogTests {
    private static let kingston = QuadcastCatalog.kingstonVendorID
    private static let hp = QuadcastCatalog.hpVendorID

    @Test func kingstonFunctionsKeepTodaysRolesAndMatching() throws {
        let lighting = try #require(QuadcastCatalog.function(vendorID: Self.kingston, productID: 0x171f))
        let audio = try #require(QuadcastCatalog.function(vendorID: Self.kingston, productID: 0x171d))

        #expect(lighting.role == .lighting)
        #expect(lighting.isMatchedByLightingTransport)
        #expect(audio.role == .audio)
        #expect(audio.isMatchedByLightingTransport)
    }

    @Test func hpLightingFunctionsAreUpstreamDevioIDs() {
        let hpLighting = QuadcastCatalog.functions
            .filter { $0.vendorID == Self.hp && $0.role == .lighting }
            .map(\.productID)

        #expect(Set(hpLighting) == [0x0f8b, 0x028c, 0x048c, 0x068c, 0x098c, 0x09af])
    }

    @Test func lightingTransportMatchesKingstonBothFunctionsAndHPLightingOnly() {
        #expect(QuadcastCatalog.lightingTransportProductIDs == [
            0x0951: [0x171f, 0x171d],
            0x03f0: [0x0f8b, 0x028c, 0x048c, 0x068c, 0x098c, 0x09af],
        ])
    }

    @Test func hpAudioFunctionIsNotSeizedByTheLightingTransport() throws {
        let audio = try #require(QuadcastCatalog.function(vendorID: Self.hp, productID: 0x0294))

        #expect(audio.role == .audio)
        #expect(audio.isMatchedByLightingTransport == false)
    }

    @Test func quadcast2SIsNotSupported() {
        #expect(QuadcastCatalog.function(vendorID: Self.hp, productID: 0x02b5) == nil)
        #expect(QuadcastCatalog.function(modelUID: "HyperX QuadCast 2S:03F0:02B5") == nil)
    }

    @Test func modelUIDResolvesTheTrailingVendorAndProduct() {
        let kingstonAudio = QuadcastCatalog.function(vendorID: Self.kingston, productID: 0x171d)
        let hpAudio = QuadcastCatalog.function(vendorID: Self.hp, productID: 0x0294)

        #expect(QuadcastCatalog.function(modelUID: "HyperX QuadCast S:0951:171D") == kingstonAudio)
        #expect(QuadcastCatalog.function(modelUID: "hyperx quadcast s:0951:171d") == kingstonAudio)
        #expect(QuadcastCatalog.function(modelUID: "A:B:03f0:0294") == hpAudio)
        for unmatched in ["HyperX QuadCast S", "x:951:171d", "x:0951:171dz", "x:0951:", "Foo:0951:1234"] {
            #expect(QuadcastCatalog.function(modelUID: unmatched) == nil, "\(unmatched)")
        }
    }

    @Test func kingstonAudioModelUIDResolvesToTheAudioFunction() {
        #expect(
            QuadcastCatalog.function(modelUID: FakeHAL.Device.quadcastModelUID)
                == QuadcastCatalog.function(vendorID: 0x0951, productID: 0x171d)
        )
    }

    @Test func entriesAreUniqueByVendorAndProduct() {
        let keys = QuadcastCatalog.functions.map { "\($0.vendorID):\($0.productID)" }

        #expect(Set(keys).count == keys.count)
    }

    @Test func displayNamePrefersTheReportedName() {
        let function = QuadcastCatalog.function(vendorID: Self.hp, productID: 0x09af)

        #expect(QuadcastCatalog.displayName(reported: " HyperX QuadCast S ", for: function) == "HyperX QuadCast S")
        for blank: String? in [nil, "", "  "] {
            #expect(QuadcastCatalog.displayName(reported: blank, for: function) == "HyperX QuadCast 2")
        }
        #expect(QuadcastCatalog.displayName(reported: nil, for: nil) == "HyperX microphone")
    }
}
