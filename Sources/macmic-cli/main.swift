// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import QuadcastKit

print("""
    macmic-cli \(QuadcastKit.version)

    Usage:
      macmic-cli solid <hex> [--brightness N]
      macmic-cli cycle [--speed N]
      macmic-cli blink <hex>...
      macmic-cli probe
    """)
