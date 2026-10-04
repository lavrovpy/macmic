// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Foundation
import QuadcastKit

/// Persists `LightingSettings` as one JSON blob under `key`, migrating the
/// per-field keys earlier builds wrote.
enum LightingSettingsStore {
    static let key = "dev.alavreniuk.macmic.lighting"

    /// Written by builds before the blob; read once, then removed.
    static let legacyKeys = [
        LegacyKey.mode, LegacyKey.brightness, LegacyKey.isEnabled,
        LegacyKey.lastSolidColor, LegacyKey.lastPresetSpeed, LegacyKey.lastBlinkColors,
    ]

    private enum LegacyKey {
        static let mode = "dev.alavreniuk.macmic.mode"
        static let brightness = "dev.alavreniuk.macmic.brightness"
        static let isEnabled = "dev.alavreniuk.macmic.isEnabled"
        static let lastSolidColor = "dev.alavreniuk.macmic.lastSolidColor"
        static let lastPresetSpeed = "dev.alavreniuk.macmic.lastPresetSpeed"
        static let lastBlinkColors = "dev.alavreniuk.macmic.lastBlinkColors"
    }

    /// The blob if one exists (a corrupt one gives `.default`), else the
    /// legacy keys migrated into a blob, else `.default` with nothing written.
    /// Legacy keys are removed whenever a blob is in place.
    static func load(from defaults: UserDefaults) -> LightingSettings {
        if let stored = defaults.object(forKey: key) {
            let settings = (stored as? Data).flatMap { try? JSONDecoder().decode(LightingSettings.self, from: $0) }
            removeLegacyKeys(from: defaults)
            return settings ?? .default
        }
        guard legacyKeys.contains(where: { defaults.object(forKey: $0) != nil }) else {
            return .default
        }
        let migrated = readLegacy(from: defaults)
        // Blob first: a crash before the removal leaves both, and the next
        // launch then takes the blob path instead of migrating again.
        save(migrated, to: defaults)
        removeLegacyKeys(from: defaults)
        return migrated
    }

    static func save(_ settings: LightingSettings, to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    private static func removeLegacyKeys(from defaults: UserDefaults) {
        for legacyKey in legacyKeys where defaults.object(forKey: legacyKey) != nil {
            defaults.removeObject(forKey: legacyKey)
        }
    }

    /// The pre-blob readers: an absent or undecodable field gets its old
    /// default, then the sanitizing init reconciles the rest.
    private static func readLegacy(from defaults: UserDefaults) -> LightingSettings {
        func decoded<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
        }
        return LightingSettings(
            mode: decoded(LightMode.self, LegacyKey.mode) ?? .solid(LightingSettings.defaultColor),
            brightness: defaults.object(forKey: LegacyKey.brightness) != nil
                ? defaults.double(forKey: LegacyKey.brightness) : 1,
            isEnabled: defaults.object(forKey: LegacyKey.isEnabled) != nil
                ? defaults.bool(forKey: LegacyKey.isEnabled) : true,
            lastSolidColor: decoded(QuadcastKit.RGBColor.self, LegacyKey.lastSolidColor),
            lastPresetSpeed: defaults.object(forKey: LegacyKey.lastPresetSpeed) != nil
                ? defaults.integer(forKey: LegacyKey.lastPresetSpeed) : nil,
            lastBlinkColors: decoded([QuadcastKit.RGBColor].self, LegacyKey.lastBlinkColors)
        )
    }
}
