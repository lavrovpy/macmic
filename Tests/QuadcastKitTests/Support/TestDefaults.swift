// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Foundation

/// A `UserDefaults` suite checked out for one test and returned on deinit.
/// Slots are reused: every unique suite name leaves an empty plist in
/// ~/Library/Preferences (cfprefsd recreates it even after deletion), so
/// unique per-test names leaked a file per test. The number of files is
/// bounded by peak test parallelism.
final class TestDefaults {
    let defaults: UserDefaults
    let suiteName: String
    private let slot: Int

    /// Takes the lowest free slot and clears it, so a slot a crashed run
    /// left dirty starts empty too.
    init() {
        slot = SlotPool.shared.checkOut()
        suiteName = "dev.alavreniuk.macmic.tests.slot\(slot)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
        SlotPool.shared.checkIn(slot)
    }
}

private final class SlotPool {
    static let shared = SlotPool()

    private let lock = NSLock()
    private var free: Set<Int> = []
    private var count = 0

    func checkOut() -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let slot = free.min() {
            free.remove(slot)
            return slot
        }
        count += 1
        return count - 1
    }

    func checkIn(_ slot: Int) {
        lock.lock()
        free.insert(slot)
        lock.unlock()
    }
}
