// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Foundation
@testable import MacMic
@testable import QuadcastKit

/// A `Lighting` over a `MockHIDTransport`, a `ManualScheduler` and a
/// `TestDefaults` slot. A transport that must be configured before launch
/// is passed in.
final class LightingFixture {
    private(set) var transport: MockHIDTransport
    let scheduler = ManualScheduler()
    let testDefaults = TestDefaults()
    private var current: Lighting?

    var lighting: Lighting {
        current!
    }

    var defaults: UserDefaults {
        testDefaults.defaults
    }

    /// What this slot holds on disk, as `UserDefaults` would persist it.
    var persisted: [String: Any] {
        defaults.persistentDomain(forName: testDefaults.suiteName) ?? [:]
    }

    init(transport: MockHIDTransport = MockHIDTransport()) {
        self.transport = transport
        current = Lighting(transport: transport, defaults: testDefaults.defaults, scheduler: scheduler)
    }

    /// Quits and relaunches on the same defaults, with a fresh device.
    func relaunch(transport: MockHIDTransport = MockHIDTransport()) {
        current = nil
        self.transport = transport
        current = Lighting(transport: transport, defaults: testDefaults.defaults, scheduler: scheduler)
    }

    /// One frame interval per tick.
    func tick(_ count: Int = 1) {
        for _ in 0..<count {
            scheduler.advance(by: FrameStreamer.defaultInterval)
        }
    }
}
