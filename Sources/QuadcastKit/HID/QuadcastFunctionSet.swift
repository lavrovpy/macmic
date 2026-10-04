// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

/// The QuadCast USB functions a transport currently has matched, keyed by
/// IORegistry entry id.
///
/// One physical mic enumerates as two USB functions, each a separately
/// matched service with its own termination notification: PID `0x171f`
/// accepts the lighting control transfer, PID `0x171d` (the audio function)
/// rejects it with `kIOReturnError`. So:
/// - `orderedCandidates` tries the last function that accepted a send first,
///   then `0x171f`, then the rest;
/// - `remove` reports `isEmpty` only once *every* function is gone. Reporting
///   the device as removed on the first termination would disconnect the app
///   while the other function — usually the working `0x171f` — is still
///   present.
///
/// Pure and not thread-safe: the owner serializes access.
struct QuadcastFunctionSet<Handle> {
    struct Function {
        let entryID: UInt64
        let productID: Int
        let handle: Handle
    }

    static var preferredProductID: Int { 0x171f }

    private var functions: [UInt64: Function] = [:]
    private var activeEntryID: UInt64?

    var isEmpty: Bool { functions.isEmpty }

    /// Adds a matched function. Returns the handle previously stored under
    /// the same entry id, which the caller owns again (e.g. to `destroy()`).
    @discardableResult
    mutating func insert(_ handle: Handle, entryID: UInt64, productID: Int) -> Handle? {
        functions.updateValue(Function(entryID: entryID, productID: productID, handle: handle), forKey: entryID)?.handle
    }

    /// Drops a terminated function. `nil` when the entry id was never
    /// matched; otherwise the removed handle and whether no function remains.
    mutating func remove(entryID: UInt64) -> (handle: Handle, isEmpty: Bool)? {
        guard let removed = functions.removeValue(forKey: entryID) else { return nil }
        if activeEntryID == entryID {
            activeEntryID = nil
        }
        return (removed.handle, functions.isEmpty)
    }

    /// Records the function that just accepted a send, so the next send
    /// tries it first. Ignored for an entry id that isn't matched.
    mutating func markActive(_ entryID: UInt64) {
        guard functions[entryID] != nil else { return }
        activeEntryID = entryID
    }

    /// Every matched function in send order: the active one, then
    /// `preferredProductID`, then the rest; ascending entry id within a group.
    var orderedCandidates: [Function] {
        functions.values.sorted { lhs, rhs in
            let lhsRank = rank(of: lhs)
            let rhsRank = rank(of: rhs)
            return lhsRank != rhsRank ? lhsRank < rhsRank : lhs.entryID < rhs.entryID
        }
    }

    /// Empties the set and returns every handle, for the caller to release.
    mutating func removeAll() -> [Handle] {
        let handles = functions.values.sorted { $0.entryID < $1.entryID }.map(\.handle)
        functions.removeAll()
        activeEntryID = nil
        return handles
    }

    private func rank(of function: Function) -> Int {
        if function.entryID == activeEntryID { return 0 }
        if function.productID == Self.preferredProductID { return 1 }
        return 2
    }
}
