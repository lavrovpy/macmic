// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

/// The supported USB functions a transport currently has matched, keyed by
/// IORegistry entry id.
///
/// One physical mic can enumerate as several USB functions, each a
/// separately matched service with its own termination notification. Only
/// those whose `QuadcastCatalog` role is `.lighting` accept the lighting
/// control transfer; the Kingston audio function (`0x171d`) rejects it with
/// `kIOReturnError`. So:
/// - `orderedCandidates` tries the last function that accepted a send first,
///   then lighting-role functions, then the rest;
/// - `remove` reports `isEmpty` only once *every* function is gone. Reporting
///   the device as removed on the first termination would disconnect the app
///   while the other function — usually the working `0x171f` — is still
///   present.
///
/// Pure and not thread-safe: the owner serializes access.
struct QuadcastFunctionSet<Handle> {
    struct Function {
        let entryID: UInt64
        let vendorID: Int
        let productID: Int
        let productName: String?
        let handle: Handle
    }

    private var functions: [UInt64: Function] = [:]
    private var activeEntryID: UInt64?

    var isEmpty: Bool { functions.isEmpty }

    /// Adds a matched function. Returns the handle previously stored under
    /// the same entry id, which the caller owns again (e.g. to `destroy()`).
    @discardableResult
    mutating func insert(
        _ handle: Handle, entryID: UInt64, vendorID: Int, productID: Int, productName: String? = nil
    ) -> Handle? {
        let function = Function(
            entryID: entryID, vendorID: vendorID, productID: productID, productName: productName, handle: handle
        )
        return functions.updateValue(function, forKey: entryID)?.handle
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
    /// lighting-role functions, then the rest; ascending entry id within a
    /// group.
    var orderedCandidates: [Function] {
        functions.values.sorted { lhs, rhs in
            let lhsRank = rank(of: lhs)
            let rhsRank = rank(of: rhs)
            return lhsRank != rhsRank ? lhsRank < rhsRank : lhs.entryID < rhs.entryID
        }
    }

    /// The matched mic's name: the reported product string, else the catalog
    /// name, of the first function in lighting-role-then-entry-id order;
    /// `nil` when empty. Ignores the active function, so the name stays put
    /// while sends move between functions.
    var displayName: String? {
        let first = functions.values.min { lhs, rhs in
            let lhsRank = isLighting(lhs) ? 0 : 1
            let rhsRank = isLighting(rhs) ? 0 : 1
            return lhsRank != rhsRank ? lhsRank < rhsRank : lhs.entryID < rhs.entryID
        }
        guard let first else { return nil }
        return QuadcastCatalog.displayName(reported: first.productName, for: catalogEntry(of: first))
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
        return isLighting(function) ? 1 : 2
    }

    private func isLighting(_ function: Function) -> Bool {
        catalogEntry(of: function)?.role == .lighting
    }

    private func catalogEntry(of function: Function) -> QuadcastUSBFunction? {
        QuadcastCatalog.function(vendorID: function.vendorID, productID: function.productID)
    }
}
