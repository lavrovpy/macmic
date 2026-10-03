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

/// `Lighting` through `MockHIDTransport` + `ManualScheduler` + `TestDefaults`:
/// presence, streaming, the send-failure retry policy, and persistence.
@Suite @MainActor struct LightingTests {
    private static let red = RGBColor(r: 0xFF, g: 0, b: 0)
    private static let interval = FrameStreamer.defaultInterval

    private func frame(_ color: RGBColor) -> [UInt8] {
        Frame(color: color).dataPacket()
    }

    /// Advances the clock to `time` seconds after launch.
    private func advance(_ fixture: LightingFixture, to time: TimeInterval) {
        fixture.scheduler.advance(by: time - fixture.scheduler.now)
    }

    // MARK: Presence

    /// Regression test: `open()` succeeding is not a device being matched.
    /// `IOUSBHostTransport.open()` only registers matching notifications and
    /// reports a match through `onDeviceConnected`; launching with no mic
    /// plugged in must leave lighting not found until that callback.
    @Test func deviceAbsentAtLaunchLeavesLightingNotFound() {
        let transport = MockHIDTransport()
        transport.autoConnectOnOpen = false
        let fixture = LightingFixture(transport: transport)
        let lighting = fixture.lighting

        #expect(lighting.isDevicePresent == false)
        #expect(lighting.status == .notFound)
        #expect(lighting.controlsEnabled == false)
        fixture.tick(3)
        #expect(transport.sendAttempts == 0)

        transport.simulateConnect()
        fixture.tick(1)

        #expect(lighting.isDevicePresent == true)
        #expect(lighting.status == .connected)
        #expect(transport.sentReports.last == frame(LightingSettings.defaultColor))
    }

    @Test func openFailureLeavesLightingNotFound() {
        let transport = MockHIDTransport()
        transport.nextOpenError = .openFailed(-1)
        let fixture = LightingFixture(transport: transport)

        #expect(fixture.lighting.isDevicePresent == false)
        #expect(fixture.lighting.status == .notFound)
        #expect(fixture.lighting.controlsEnabled == false)
    }

    /// `onDeviceConnected` fires once per USB function, so twice per mic.
    @Test func bothFunctionsConnectingStreamsOnce() {
        let fixture = LightingFixture()

        fixture.tick(1)
        #expect(fixture.transport.sentReports.count == 2)

        fixture.tick(3)
        #expect(fixture.transport.sentReports.count == 8)
    }

    /// One mic is two USB functions; the audio function (`0x171d`) going
    /// away on its own — e.g. re-enumerating — must not take lighting down
    /// while the control function is still matched.
    @Test func removingOnlyTheAudioFunctionKeepsLightingConnected() {
        let fixture = LightingFixture()
        fixture.lighting.settings.solidColor = Self.red

        fixture.transport.simulateRemoval(productID: 0x171d)
        fixture.tick(1)

        #expect(fixture.lighting.isDevicePresent == true)
        #expect(fixture.lighting.status == .connected)
        #expect(fixture.transport.sentReports.last == frame(Self.red))
    }

    /// The reverse: with only `0x171d` left the transport still reports the
    /// mic present, but `0x171d` rejects control transfers, so sends fail —
    /// lighting stays present (controls enabled) and reports the failure.
    @Test func removingOnlyTheControlFunctionMarksSendFailingButKeepsPresence() {
        let fixture = LightingFixture()

        fixture.transport.simulateRemoval(productID: 0x171f)
        fixture.tick(1)

        #expect(fixture.transport.sentReports.isEmpty)
        #expect(fixture.lighting.isDevicePresent == true)
        #expect(fixture.lighting.isSendFailing == true)
        #expect(fixture.lighting.status == .notResponding)
        #expect(fixture.lighting.controlsEnabled == true)
    }

    @Test func unplugStopsStreamingAndReplugResumesLastSettings() {
        let fixture = LightingFixture()
        let color = RGBColor(r: 9, g: 9, b: 9)
        fixture.lighting.settings.solidColor = color
        fixture.tick(1)

        fixture.transport.simulateUnplug()
        let attemptsAfterUnplug = fixture.transport.sendAttempts
        fixture.tick(3)

        #expect(fixture.lighting.isDevicePresent == false)
        #expect(fixture.transport.sendAttempts == attemptsAfterUnplug)

        fixture.transport.simulateConnect()
        fixture.tick(1)

        #expect(fixture.lighting.isDevicePresent == true)
        #expect(fixture.transport.sentReports.last == frame(color))
    }

    @Test func settingsChangeWhileAbsentDoesNotStreamButAppliesOnReconnect() {
        let fixture = LightingFixture()
        fixture.transport.simulateUnplug()
        let attemptsAfterUnplug = fixture.transport.sendAttempts

        fixture.lighting.settings.solidColor = Self.red
        fixture.tick(3)

        #expect(fixture.transport.sendAttempts == attemptsAfterUnplug)

        fixture.transport.simulateConnect()
        fixture.tick(1)

        #expect(fixture.transport.sentReports.last == frame(Self.red))
    }

    // MARK: Streaming

    @Test func settingsChangeReachesTheDevice() {
        let fixture = LightingFixture()

        fixture.lighting.settings.solidColor = Self.red
        fixture.tick(1)

        #expect(fixture.transport.sentReports.last == frame(Self.red))
    }

    @Test func brightnessScalesFrames() {
        let fixture = LightingFixture()
        let color = RGBColor(r: 200, g: 100, b: 50)

        fixture.lighting.settings.solidColor = color
        fixture.lighting.settings.brightness = 0.5
        fixture.tick(1)

        #expect(fixture.transport.sentReports.last == Frame(color: color).scaled(brightness: 0.5).dataPacket())
    }

    @Test func disablingStopsStreamingAndReEnablingResumes() {
        let fixture = LightingFixture()
        fixture.tick(1)

        fixture.lighting.settings.isEnabled = false
        let attemptsAfterDisable = fixture.transport.sendAttempts
        fixture.tick(3)

        #expect(fixture.transport.sendAttempts == attemptsAfterDisable)
        #expect(fixture.lighting.controlsEnabled == true)

        fixture.lighting.settings.isEnabled = true
        fixture.tick(1)

        #expect(fixture.transport.sendAttempts == attemptsAfterDisable + 2)
    }

    @Test func sleepStopsStreamingAndWakeResumes() {
        let fixture = LightingFixture()
        fixture.lighting.settings.solidColor = Self.red
        fixture.tick(1)

        fixture.lighting.systemWillSleep()
        let attemptsAfterSleep = fixture.transport.sendAttempts
        fixture.tick(3)

        #expect(fixture.transport.sendAttempts == attemptsAfterSleep)

        fixture.lighting.systemDidWake()
        fixture.tick(1)

        #expect(fixture.transport.sendAttempts == attemptsAfterSleep + 2)
        #expect(fixture.transport.sentReports.last == frame(Self.red))
    }

    /// Re-selecting the active kind (a `Picker` reporting the same segment)
    /// must not restart a running animation.
    @Test func reselectingSameModeDoesNotRestartAnimation() {
        let fixture = LightingFixture()
        fixture.lighting.settings.modeKind = .cycle
        let frames = PresetSequencer.frames(for: fixture.lighting.settings.mode)
        fixture.tick(1) // frame 0

        fixture.lighting.settings.modeKind = .cycle
        fixture.lighting.settings = fixture.lighting.settings
        fixture.tick(1) // frame 1, not frame 0 again

        let dataPackets = fixture.transport.sentReports.enumerated().compactMap { $0.offset % 2 == 1 ? $0.element : nil }
        #expect(dataPackets == [frames[0].dataPacket(), frames[1].dataPacket()])
    }

    // MARK: Faults

    @Test func sendFailureKeepsDevicePresentAndControlsEnabled() {
        let fixture = LightingFixture()
        fixture.transport.nextSendError = .sendFailed(-1)

        fixture.tick(1)

        #expect(fixture.lighting.isSendFailing == true)
        #expect(fixture.lighting.isDevicePresent == true)
        #expect(fixture.lighting.controlsEnabled == true)
        #expect(fixture.lighting.status == .notResponding)
    }

    @Test func failedSendIsRetriedAfterOneSecond() {
        let fixture = LightingFixture()
        fixture.transport.nextSendError = .sendFailed(-1)
        fixture.tick(1) // fails at 1 interval
        let failedAt = Self.interval

        // The retry restarts the loop, whose first tick is one interval later.
        advance(fixture, to: failedAt + 0.98 + Self.interval)
        #expect(fixture.transport.sendAttempts == 1)
        #expect(fixture.lighting.isSendFailing == true)

        advance(fixture, to: failedAt + 1.02 + Self.interval)
        #expect(fixture.transport.sendAttempts == 3)
        #expect(fixture.transport.sentReports.last == frame(LightingSettings.defaultColor))
        #expect(fixture.lighting.isSendFailing == false)
    }

    @Test func retryBackoffDoublesToTenSecondCap() {
        let fixture = LightingFixture()
        fixture.transport.persistentSendError = .sendFailed(-1)
        fixture.tick(1)
        #expect(fixture.transport.sendAttempts == 1)
        var failedAt = Self.interval

        for (attempt, delay) in [1.0, 2, 4, 8, 10, 10, 10].enumerated() {
            let nextAttempt = failedAt + delay + Self.interval
            advance(fixture, to: nextAttempt - 0.02)
            #expect(fixture.transport.sendAttempts == attempt + 1, "retry \(attempt + 1) came before \(delay) s")
            advance(fixture, to: nextAttempt + 0.02)
            #expect(fixture.transport.sendAttempts == attempt + 2, "retry \(attempt + 1) missing after \(delay) s")
            failedAt = nextAttempt
        }
        #expect(fixture.lighting.isSendFailing == true)
        #expect(fixture.lighting.isDevicePresent == true)
    }

    @Test func recoveryClearsFailureAndResetsBackoff() {
        let fixture = LightingFixture()
        fixture.transport.persistentSendError = .sendFailed(-1)
        fixture.tick(1) // failure 1 → retry after 1 s
        advance(fixture, to: Self.interval + 1 + Self.interval + 0.01) // failure 2 → retry after 2 s
        #expect(fixture.transport.sendAttempts == 2)

        fixture.transport.persistentSendError = nil
        advance(fixture, to: Self.interval + 1 + Self.interval + 2 + Self.interval + 0.01)
        #expect(fixture.transport.sendAttempts == 4)
        #expect(fixture.lighting.isSendFailing == false)
        #expect(fixture.lighting.status == .connected)

        // Failing again starts over at 1 s, not 4 s.
        fixture.transport.persistentSendError = .sendFailed(-1)
        fixture.tick(1)
        let failedAt = fixture.scheduler.now
        let attemptsAfterFailure = fixture.transport.sendAttempts
        #expect(fixture.lighting.isSendFailing == true)

        advance(fixture, to: failedAt + 1 + Self.interval + 0.01)
        #expect(fixture.transport.sendAttempts == attemptsAfterFailure + 1)
    }

    @Test func settingsChangeWhileFailingRetriesImmediately() {
        let fixture = LightingFixture()
        fixture.transport.nextSendError = .sendFailed(-1)
        fixture.tick(1)
        #expect(fixture.lighting.isSendFailing == true)

        fixture.lighting.settings.solidColor = Self.red
        fixture.tick(1)

        #expect(fixture.transport.sentReports.last == frame(Self.red))
        #expect(fixture.lighting.isSendFailing == false)
    }

    /// An equal write (a control re-reporting the current value) is not a
    /// change: nothing is saved, and while failing the backoff is kept
    /// rather than restarted.
    @Test func equalSettingsWriteIsIgnoredAndKeepsTheRetrySchedule() {
        let fixture = LightingFixture()
        fixture.lighting.settings.isEnabled = true
        #expect(fixture.persisted.isEmpty)

        fixture.transport.persistentSendError = .sendFailed(-1)
        fixture.tick(1)
        let failedAt = Self.interval
        fixture.lighting.settings.isEnabled = true
        fixture.lighting.settings = fixture.lighting.settings

        advance(fixture, to: failedAt + 1 + Self.interval - 0.02)
        #expect(fixture.transport.sendAttempts == 1)
        #expect(fixture.persisted.isEmpty)

        advance(fixture, to: failedAt + 1 + Self.interval + 0.02)
        #expect(fixture.transport.sendAttempts == 2)
    }

    @Test func wakeWhileFailingRetriesImmediately() {
        let fixture = LightingFixture()
        fixture.transport.persistentSendError = .sendFailed(-1)
        fixture.tick(1)
        #expect(fixture.lighting.isSendFailing == true)

        fixture.lighting.systemWillSleep()
        #expect(fixture.lighting.isSendFailing == false)
        fixture.transport.persistentSendError = nil
        fixture.lighting.systemDidWake()
        fixture.tick(1)

        #expect(fixture.transport.sentReports.last == frame(LightingSettings.defaultColor))
        #expect(fixture.lighting.isSendFailing == false)
    }

    @Test func reconnectWhileFailingRetriesImmediately() {
        let fixture = LightingFixture()
        fixture.transport.simulateRemoval(productID: 0x171f)
        fixture.tick(1)
        #expect(fixture.lighting.isSendFailing == true)

        fixture.transport.simulateConnect(productID: 0x171f)
        fixture.tick(1)

        #expect(fixture.transport.sentReports.last == frame(LightingSettings.defaultColor))
        #expect(fixture.lighting.isSendFailing == false)
    }

    @Test func unplugWhileFailingClearsFailureAndCancelsRetry() {
        let fixture = LightingFixture()
        fixture.transport.nextSendError = .sendFailed(-1)
        fixture.tick(1)
        #expect(fixture.lighting.isSendFailing == true)

        fixture.transport.simulateUnplug()
        fixture.tick(1) // the loop's leftover tick drains

        #expect(fixture.lighting.isSendFailing == false)
        #expect(fixture.lighting.status == .notFound)
        #expect(fixture.scheduler.pendingCount == 0)

        fixture.scheduler.advance(by: Lighting.maxRetryDelay * 2)
        #expect(fixture.transport.sendAttempts == 1)
    }

    @Test func disablingWhileFailingClearsFailure() {
        let fixture = LightingFixture()
        fixture.transport.nextSendError = .sendFailed(-1)
        fixture.tick(1)
        #expect(fixture.lighting.isSendFailing == true)

        fixture.lighting.settings.isEnabled = false
        fixture.tick(1)

        #expect(fixture.lighting.isSendFailing == false)
        #expect(fixture.lighting.status == .connected)
        #expect(fixture.scheduler.pendingCount == 0)
    }

    @Test func statusTextPerState() {
        let fixture = LightingFixture()
        #expect(fixture.lighting.statusText == "QuadCast S connected")

        fixture.transport.nextSendError = .sendFailed(-1)
        fixture.tick(1)
        #expect(fixture.lighting.statusText == "QuadCast S not responding — retrying")

        fixture.transport.simulateUnplug()
        #expect(fixture.lighting.statusText == "QuadCast S not found")
    }

    // MARK: Persistence

    @Test func settingsPersistAcrossRelaunch() {
        let fixture = LightingFixture()
        let colors = [RGBColor(r: 10, g: 20, b: 30), RGBColor(r: 40, g: 50, b: 60)]
        fixture.lighting.settings.solidColor = RGBColor(r: 0xAA, g: 0xBB, b: 0xCC)
        fixture.lighting.settings.setBlinkColor(colors[0], at: 0)
        fixture.lighting.settings.duplicateBlinkColor(at: 0)
        fixture.lighting.settings.setBlinkColor(colors[1], at: 1)
        fixture.lighting.settings.presetSpeed = 42
        fixture.lighting.settings.modeKind = .cycle
        fixture.lighting.settings.brightness = 0.5
        fixture.lighting.settings.isEnabled = false
        let saved = fixture.lighting.settings

        fixture.relaunch()

        #expect(fixture.lighting.settings == saved)
        #expect(fixture.lighting.settings.mode == .cycle(speed: 42))
        #expect(fixture.lighting.settings.solidColor == RGBColor(r: 0xAA, g: 0xBB, b: 0xCC))
        #expect(fixture.lighting.settings.blinkColors == colors)
    }

    @Test func migratesLegacyKeysOnceAndRemovesThem() throws {
        let fixture = LightingFixture()
        let blink = LightMode.blink(colors: [RGBColor(r: 1, g: 2, b: 3), RGBColor(r: 4, g: 5, b: 6)], speed: 42)
        fixture.defaults.set(try JSONEncoder().encode(blink), forKey: "dev.alavreniuk.macmic.mode")
        fixture.defaults.set(0.25, forKey: "dev.alavreniuk.macmic.brightness")
        fixture.defaults.set(false, forKey: "dev.alavreniuk.macmic.isEnabled")

        fixture.relaunch()

        let expected = LightingSettings(mode: blink, brightness: 0.25, isEnabled: false)
        #expect(fixture.lighting.settings == expected)
        #expect(Array(fixture.persisted.keys) == [LightingSettingsStore.key])

        // The next launch reads the blob, not the (now absent) legacy keys.
        fixture.relaunch()
        #expect(fixture.lighting.settings == expected)
        #expect(Array(fixture.persisted.keys) == [LightingSettingsStore.key])
    }

    /// Regression test: each mode's remembered payload must survive
    /// migration even while another mode is active, or switching back after
    /// the upgrade resets the picker.
    @Test func legacyMigrationKeepsRememberedPayloadsWhilePresetActive() throws {
        let fixture = LightingFixture()
        let solid = RGBColor(r: 0xAA, g: 0xBB, b: 0xCC)
        let blinkColors = [RGBColor(r: 1, g: 2, b: 3), RGBColor(r: 4, g: 5, b: 6)]
        fixture.defaults.set(try JSONEncoder().encode(LightMode.cycle(speed: 30)), forKey: "dev.alavreniuk.macmic.mode")
        fixture.defaults.set(try JSONEncoder().encode(solid), forKey: "dev.alavreniuk.macmic.lastSolidColor")
        fixture.defaults.set(try JSONEncoder().encode(blinkColors), forKey: "dev.alavreniuk.macmic.lastBlinkColors")
        fixture.defaults.set(12, forKey: "dev.alavreniuk.macmic.lastPresetSpeed")

        fixture.relaunch()
        let settings = fixture.lighting.settings

        #expect(settings.mode == .cycle(speed: 30))
        #expect(settings.solidColor == solid)
        #expect(settings.blinkColors == blinkColors)
        #expect(settings.lastPresetSpeed == 30)
    }

    @Test func corruptLegacyValuesFallBackToDefaults() throws {
        let fixture = LightingFixture()
        fixture.defaults.set(Data([0xFF, 0x00]), forKey: "dev.alavreniuk.macmic.mode")
        fixture.defaults.set(Data([0xFF, 0x00]), forKey: "dev.alavreniuk.macmic.lastSolidColor")
        fixture.defaults.set(Data([0xFF, 0x00]), forKey: "dev.alavreniuk.macmic.lastBlinkColors")
        fixture.defaults.set(999, forKey: "dev.alavreniuk.macmic.lastPresetSpeed")

        fixture.relaunch()
        let settings = fixture.lighting.settings

        #expect(settings.mode == .solid(LightingSettings.defaultColor))
        #expect(settings.lastBlinkColors == nil)
        #expect(settings.lastPresetSpeed == 100)
        #expect(settings.brightness == 1)
        #expect(settings.isEnabled == true)

        fixture.defaults.removePersistentDomain(forName: fixture.testDefaults.suiteName)
        fixture.defaults.set(try JSONEncoder().encode(LightMode.cycle(speed: 50)), forKey: "dev.alavreniuk.macmic.mode")
        fixture.defaults.set(Data([0xFF, 0x00]), forKey: "dev.alavreniuk.macmic.lastSolidColor")

        fixture.relaunch()

        #expect(fixture.lighting.settings.mode == .cycle(speed: 50))
        #expect(fixture.lighting.settings.solidColor == LightingSettings.defaultColor)
    }

    @Test func corruptBlobFallsBackToDefaults() {
        let fixture = LightingFixture()
        fixture.defaults.set(Data([0xFF, 0x00]), forKey: LightingSettingsStore.key)

        fixture.relaunch()

        #expect(fixture.lighting.settings == .default)
    }

    @Test func blobWinsOverStaleLegacyKeysAndRemovesThem() throws {
        let fixture = LightingFixture()
        fixture.lighting.settings.solidColor = Self.red
        fixture.defaults.set(try JSONEncoder().encode(LightMode.cycle(speed: 10)), forKey: "dev.alavreniuk.macmic.mode")
        fixture.defaults.set(0.1, forKey: "dev.alavreniuk.macmic.brightness")

        fixture.relaunch()

        #expect(fixture.lighting.settings == LightingSettings(mode: .solid(Self.red)))
        #expect(Array(fixture.persisted.keys) == [LightingSettingsStore.key])
    }

    @Test func defaultsUsedWhenNothingPersisted() {
        let fixture = LightingFixture()

        #expect(fixture.lighting.settings == .default)
        #expect(fixture.persisted.isEmpty)
    }

    @Test func onlyTheLightingKeyIsWritten() {
        let fixture = LightingFixture()

        fixture.lighting.settings.solidColor = Self.red
        fixture.lighting.settings.modeKind = .blink
        fixture.lighting.settings.presetSpeed = 70
        fixture.lighting.settings.brightness = 0.3
        fixture.lighting.settings.isEnabled = false
        fixture.lighting.systemWillSleep()
        fixture.lighting.systemDidWake()

        #expect(Array(fixture.persisted.keys) == [LightingSettingsStore.key])
    }
}
