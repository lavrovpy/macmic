// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Foundation

/// One separately enumerated USB device of a supported HyperX mic.
public struct QuadcastUSBFunction: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        /// Accepts the 2-zone lighting control transfer.
        case lighting
        /// Carries the mic's Core Audio devices; rejects lighting transfers.
        case audio
    }

    public let vendorID: Int
    public let productID: Int
    public let role: Role
    /// Shown only when the device reports no name of its own.
    public let fallbackName: String
    /// `IOUSBHostTransport` matches, and so seizes, this function.
    public let isMatchedByLightingTransport: Bool
}

/// Every USB function MacMic supports: the single source for the lighting
/// transport's matching, the function set's send order, the Core Audio
/// matcher and `macmic-cli probe`. Only the Kingston QuadCast S has been
/// tested on hardware; the HP entries come from the sources noted on each.
public enum QuadcastCatalog {
    public static let kingstonVendorID = 0x0951
    public static let hpVendorID = 0x03f0
    public static let genericName = "HyperX microphone"

    // One flat list with a per-entry matching flag rather than a per-vendor
    // rule: Kingston 0x171D and HP 0x0294 share a role but are matched
    // differently.
    public static let functions: [QuadcastUSBFunction] = [
        // QuadcastRGB devio.c product_ids_kingston. Hardware-verified.
        lighting(kingstonVendorID, 0x171f, "HyperX QuadCast S"),
        // Hardware-verified (CLAUDE.md Hardware notes): matched by the
        // transport so that removal is reported only once both functions
        // are gone.
        QuadcastUSBFunction(
            vendorID: kingstonVendorID, productID: 0x171d, role: .audio,
            fallbackName: "HyperX QuadCast S", isMatchedByLightingTransport: true
        ),
        // QuadcastRGB devio.c product_ids_hp: QuadCast S revisions.
        lighting(hpVendorID, 0x0f8b, "HyperX QuadCast S"),
        lighting(hpVendorID, 0x028c, "HyperX QuadCast S"),
        lighting(hpVendorID, 0x048c, "HyperX QuadCast S"),
        lighting(hpVendorID, 0x068c, "HyperX QuadCast S"),
        // devio.c labels this the DuoCast; CastGlow's README lists it as a
        // QuadCast S revision. The label is uncertain and only shows when the
        // device reports no USB product string.
        lighting(hpVendorID, 0x098c, "HyperX DuoCast"),
        // devio.c.
        lighting(hpVendorID, 0x09af, "HyperX QuadCast 2"),
        // CastGlow README (third-party, unverified): the audio function of a
        // 0x028C unit. Not matched by the transport, which seizes what it
        // matches; nothing shows that seizing an HP audio function is harmless.
        QuadcastUSBFunction(
            vendorID: hpVendorID, productID: 0x0294, role: .audio,
            fallbackName: "HyperX QuadCast S", isMatchedByLightingTransport: false
        ),
        // Never add the QuadCast 2S (03F0:02B5): it uses a different 108-LED
        // protocol, so the 2-zone packets are wrong for it.
    ]

    public static func function(vendorID: Int, productID: Int) -> QuadcastUSBFunction? {
        functions.first { $0.vendorID == vendorID && $0.productID == productID }
    }

    /// Resolves a Core Audio `kAudioDevicePropertyModelUID`
    /// (`"<name>:<vid>:<pid>"`) by its last two `:` components, each exactly
    /// four hex digits in any case. Returns a function of any role, or `nil`.
    public static func function(modelUID: String) -> QuadcastUSBFunction? {
        let components = modelUID.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count >= 2,
              let vendorID = fourDigitHex(components[components.count - 2]),
              let productID = fourDigitHex(components[components.count - 1])
        else { return nil }
        return function(vendorID: vendorID, productID: productID)
    }

    /// `reported` trimmed of whitespace if it is not blank; else the
    /// function's fallback name; else `genericName`.
    public static func displayName(reported: String?, for function: QuadcastUSBFunction?) -> String {
        if let trimmed = reported?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return trimmed
        }
        return function?.fallbackName ?? genericName
    }

    /// Vendor → the product ids the lighting transport matches, in catalog
    /// order within each vendor.
    static var lightingTransportProductIDs: [Int: [Int]] {
        functions
            .filter(\.isMatchedByLightingTransport)
            .reduce(into: [:]) { $0[$1.vendorID, default: []].append($1.productID) }
    }

    private static func lighting(_ vendorID: Int, _ productID: Int, _ name: String) -> QuadcastUSBFunction {
        QuadcastUSBFunction(
            vendorID: vendorID, productID: productID, role: .lighting,
            fallbackName: name, isMatchedByLightingTransport: true
        )
    }

    private static func fourDigitHex(_ text: Substring) -> Int? {
        guard text.count == 4, text.allSatisfy(\.isHexDigit) else { return nil }
        return Int(text, radix: 16)
    }
}
