// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import QuadcastKit

/// The user-facing choice of lighting mode, without the per-mode payload
/// (`LightMode`'s associated values). Drives the mode `Picker` in the main
/// window's Lighting page and in the status menu.
enum LightModeKind: String, CaseIterable, Identifiable {
    case solid, cycle, blink

    var id: Self { self }

    var title: String {
        switch self {
        case .solid: return "Solid"
        case .cycle: return "Rainbow Cycle"
        case .blink: return "Blink"
        }
    }
}

/// Every lighting setting the user makes, with every lighting invariant:
/// speeds 0...100, brightness 0...1, the blink list never empty, the active
/// mode's payload mirrored into its `last*` memory — so switching modes and
/// back restores what the user had for each.
struct LightingSettings: Codable, Equatable {
    static let defaultColor = QuadcastKit.RGBColor(r: 0xFF, g: 0xFF, b: 0xFF)
    /// The speed a preset (Rainbow Cycle, Blink) starts at before the user
    /// has ever adjusted it.
    static let defaultPresetSpeed = 50
    /// `PresetSequencer.clampSpeed`'s bounds.
    static let presetSpeedRange = 0...100
    static let `default` = LightingSettings()

    private(set) var mode: LightMode
    var brightness: Double {
        didSet { brightness = min(max(brightness, 0), 1) }
    }
    var isEnabled: Bool
    private(set) var lastSolidColor: QuadcastKit.RGBColor
    /// The speed of the last active preset.
    private(set) var lastPresetSpeed: Int
    /// `nil` until Blink has been used, so the first blink is seeded from
    /// the solid color the user has *then*, not one frozen earlier.
    private(set) var lastBlinkColors: [QuadcastKit.RGBColor]?

    private enum CodingKeys: String, CodingKey {
        case mode, brightness, isEnabled, lastSolidColor, lastPresetSpeed, lastBlinkColors
    }

    /// Sanitizing init (decoding, migration, tests): the active mode's
    /// payload wins over the matching `last*`; speeds and brightness are
    /// clamped; an empty `lastBlinkColors` becomes `nil`; `.blink([])`
    /// becomes `lastBlinkColors ?? [lastSolidColor]`.
    init(
        mode: LightMode = .solid(defaultColor),
        brightness: Double = 1,
        isEnabled: Bool = true,
        lastSolidColor: QuadcastKit.RGBColor? = nil,
        lastPresetSpeed: Int? = nil,
        lastBlinkColors: [QuadcastKit.RGBColor]? = nil
    ) {
        var solid = lastSolidColor ?? Self.defaultColor
        var speed = PresetSequencer.clampSpeed(lastPresetSpeed ?? Self.defaultPresetSpeed)
        var blink = lastBlinkColors?.isEmpty == false ? lastBlinkColors : nil
        let resolved: LightMode
        switch mode {
        case .solid(let color):
            solid = color
            resolved = mode
        case .cycle(let modeSpeed):
            speed = PresetSequencer.clampSpeed(modeSpeed)
            resolved = .cycle(speed: speed)
        case .blink(let colors, let modeSpeed):
            speed = PresetSequencer.clampSpeed(modeSpeed)
            let list = colors.isEmpty ? (blink ?? [solid]) : colors
            blink = list
            resolved = .blink(colors: list, speed: speed)
        }
        self.mode = resolved
        self.brightness = min(max(brightness, 0), 1)
        self.isEnabled = isEnabled
        self.lastSolidColor = solid
        self.lastPresetSpeed = speed
        self.lastBlinkColors = blink
    }

    /// Each field falls back to its default on its own, so a blob written by
    /// another build (a field missing, renamed or retyped) still loads.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: (try? container.decode(LightMode.self, forKey: .mode)) ?? .solid(Self.defaultColor),
            brightness: (try? container.decode(Double.self, forKey: .brightness)) ?? 1,
            isEnabled: (try? container.decode(Bool.self, forKey: .isEnabled)) ?? true,
            lastSolidColor: try? container.decode(QuadcastKit.RGBColor.self, forKey: .lastSolidColor),
            lastPresetSpeed: try? container.decode(Int.self, forKey: .lastPresetSpeed),
            lastBlinkColors: try? container.decode([QuadcastKit.RGBColor].self, forKey: .lastBlinkColors)
        )
    }

    /// Setting a kind restores that mode's remembered payload. Setting the
    /// current kind is a no-op, so a `Picker` re-selecting the same segment
    /// doesn't restart a running animation.
    var modeKind: LightModeKind {
        get {
            switch mode {
            case .solid: return .solid
            case .cycle: return .cycle
            case .blink: return .blink
            }
        }
        set {
            guard newValue != modeKind else { return }
            switch newValue {
            case .solid: setMode(.solid(lastSolidColor))
            case .cycle: setMode(.cycle(speed: lastPresetSpeed))
            case .blink: setMode(.blink(colors: blinkColors, speed: lastPresetSpeed))
            }
        }
    }

    /// The active solid color, or `lastSolidColor` while a preset is active.
    /// Setting it switches to Solid.
    var solidColor: QuadcastKit.RGBColor {
        get {
            if case .solid(let color) = mode {
                return color
            }
            return lastSolidColor
        }
        set { setMode(.solid(newValue)) }
    }

    /// The active preset's speed, or `lastPresetSpeed` while Solid is active.
    /// Setting it clamps and updates the active preset in place; ignored
    /// while Solid is active (the speed control is hidden then).
    var presetSpeed: Int {
        get {
            switch mode {
            case .solid: return lastPresetSpeed
            case .cycle(let speed): return speed
            case .blink(_, let speed): return speed
            }
        }
        set {
            let clamped = PresetSequencer.clampSpeed(newValue)
            switch mode {
            case .solid: break
            case .cycle: setMode(.cycle(speed: clamped))
            case .blink(let colors, _): setMode(.blink(colors: colors, speed: clamped))
            }
        }
    }

    /// The colors Blink steps through: the active list, else
    /// `lastBlinkColors`, else `[lastSolidColor]`. Never empty.
    var blinkColors: [QuadcastKit.RGBColor] {
        if case .blink(let colors, _) = mode {
            return colors
        }
        return lastBlinkColors ?? [lastSolidColor]
    }

    var canRemoveBlinkColor: Bool {
        blinkColors.count > 1
    }

    func blinkIndex(clamping index: Int) -> Int {
        min(max(index, 0), blinkColors.count - 1)
    }

    /// Replaces the color at `index` (clamped) and switches to Blink at
    /// `presetSpeed`.
    mutating func setBlinkColor(_ color: QuadcastKit.RGBColor, at index: Int) {
        var colors = blinkColors
        colors[blinkIndex(clamping: index)] = color
        setMode(.blink(colors: colors, speed: presetSpeed))
    }

    /// Appends a copy of the color at `index` (clamped); returns the copy's
    /// index.
    @discardableResult
    mutating func duplicateBlinkColor(at index: Int) -> Int {
        var colors = blinkColors
        colors.append(colors[blinkIndex(clamping: index)])
        setMode(.blink(colors: colors, speed: presetSpeed))
        return colors.count - 1
    }

    /// Removes the color at `index` (clamped) and returns the index to select
    /// next, or `nil` (nothing removed) for the last remaining color — an
    /// empty list would play zero frames and leave the mic dark.
    @discardableResult
    mutating func removeBlinkColor(at index: Int) -> Int? {
        guard canRemoveBlinkColor else { return nil }
        var colors = blinkColors
        let removed = blinkIndex(clamping: index)
        colors.remove(at: removed)
        setMode(.blink(colors: colors, speed: presetSpeed))
        return min(removed, colors.count - 1)
    }

    private mutating func setMode(_ newMode: LightMode) {
        switch newMode {
        case .solid(let color):
            lastSolidColor = color
        case .cycle(let speed):
            lastPresetSpeed = speed
        case .blink(let colors, let speed):
            lastPresetSpeed = speed
            lastBlinkColors = colors
        }
        mode = newMode
    }
}
