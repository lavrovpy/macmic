// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Foundation
import QuadcastKit

/// One `probe` line, e.g.
/// `  0951:171f  lighting  HyperX QuadCast S  SET_REPORT(header) -> 0 (OK)`.
/// Shows the device's raw USB product string, not the catalog's fallback
/// name, since the probe is the diagnostic for what the device reports.
func formatProbeResult(_ result: USBProbeResult) -> String {
    let ids = String(format: "%04x:%04x", result.vendorID, result.productID)
    let role: String
    switch QuadcastCatalog.function(vendorID: result.vendorID, productID: result.productID)?.role {
    case .lighting: role = "lighting"
    case .audio: role = "audio"
    case nil: role = "unknown"
    }
    let trimmed = result.productName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let name = trimmed.isEmpty ? "(no product string)" : trimmed
    let status = result.succeeded ? "OK" : "FAILED"
    return "  \(ids)  \(role)  \(name)  SET_REPORT(header) -> \(result.ioReturn) (\(status))"
}
