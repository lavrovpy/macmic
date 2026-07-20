# CLAUDE.md

Guidance for Claude Code (or any agent) working in this repo.

## What this is

MacMic: a native macOS menu bar app (Swift + SwiftUI + IOKit/IOUSBHost) that drives the RGB lighting on a HyperX QuadCast S microphone, which has no native macOS host software. Full background and protocol details: [README.md](README.md) and the implementation plan at `docs/plans/20260720-macmic-rgb-control.md`.

## Build & test commands

Pure SwiftPM package — no `.xcodeproj`. Run everything from the repo root.

```sh
swift build                       # debug build, all targets
swift build -c release            # release build (needed for the app bundle and CLI hardware use)
swift test                        # run the full QuadcastKitTests suite
swift test --filter FrameTests    # run one test suite
./scripts/make-app.sh             # release build + assemble dist/MacMic.app (ad-hoc signed)
./scripts/test-make-app.sh        # shellchecks make-app.sh, runs it, asserts the built bundle looks right
swift run macmic-cli probe        # hardware diagnostic: lists matched USB services + which accepts control transfers
```

There is no separate lint step; `swift build` must be warning-free (checked in Task 10 of the plan).

## Architecture

```
MacMic (SwiftUI MenuBarExtra, .accessory — no Dock icon)
  └─ AppState (persistence, hotplug, sleep/wake)
       └─ QuadcastKit
            ├─ FrameStreamer (55 ms DispatchSourceTimer display loop)
            ├─ PresetSequencer (LightMode → [Frame])
            ├─ QuadcastPacket / Frame / RGBColor (pure, byte-exact protocol types)
            └─ HIDTransport (protocol)
                 ├─ IOUSBHostTransport (raw USB control transfer — the transport that actually works, see below)
                 ├─ IOKitHIDTransport (IOHIDManager path — doesn't reach the device on this hardware, kept for reference)
                 └─ MockHIDTransport (test target only)
macmic-cli (probe / solid / cycle / blink — thin executable over QuadcastKit)
```

### Targets (`Package.swift`)

- `QuadcastKit` — library target, all protocol/HID logic, zero UI dependencies
- `MacMic` — executable, SwiftUI menu bar app, depends on `QuadcastKit`
- `macmic-cli` — executable, hardware diagnostic + scriptable CLI, depends on `QuadcastKit`
- `QuadcastKitTests` — test target, depends on `QuadcastKit`, `MacMic`, and `macmic-cli` (so UI-adjacent pure functions like color conversion and the CLI's pure argument-parsing helpers are covered too)

### Key files

- `Sources/QuadcastKit/Protocol/QuadcastPacket.swift` — 64-byte header packet
- `Sources/QuadcastKit/Protocol/Frame.swift` — one display frame (upper/lower zone color) → 64-byte data packet, brightness scaling
- `Sources/QuadcastKit/Protocol/RGBColor.swift` — hex-parsed RGB color
- `Sources/QuadcastKit/Protocol/PresetSequencer.swift` — `LightMode` (solid/cycle/blink) → `[Frame]`, ported cycle/blink formulas
- `Sources/QuadcastKit/HID/HIDTransport.swift` — transport protocol (`sendFeatureReport`, connect/remove callbacks)
- `Sources/QuadcastKit/HID/IOUSBHostTransport.swift` — the working transport (raw USB control transfer via `IOUSBHostDevice`)
- `Sources/QuadcastKit/HID/IOKitHIDTransport.swift` — `IOHIDManager`-based transport (non-functional on this hardware; see below)
- `Sources/QuadcastKit/FrameStreamer.swift` — owns the 55 ms timer, sends header+data packets in a loop, swaps `LightMode` atomically
- `Sources/MacMic/AppState.swift` — `@Observable`/`ObservableObject` model: persistence (`UserDefaults`), hotplug, sleep/wake, translates UI intent into `FrameStreamer` calls
- `Sources/MacMic/AppState+UI.swift` — UI-facing derivations on top of `AppState`: `solidColor` (falls back to `lastSolidColor`, not white, when a preset is active), `controlsEnabled`, `connectionStatusText`
- `Sources/MacMic/ColorConversion.swift` — pure `Color` ↔ `QuadcastKit.RGBColor` conversion via `NSColor`'s sRGB space; testable without a menu bar
- `Sources/MacMic/ContentView.swift`, `MacMicApp.swift` — SwiftUI menu bar surface
- `Sources/macmic-cli/main.swift` — `probe` / `solid` / `cycle` / `blink` subcommands

### Testing approach

- Unit tests only (Swift Testing framework via `swift test`); no e2e/UI framework — all state logic lives in testable `AppState`, so the thin SwiftUI views don't need their own tests.
- Pure protocol/frame logic (`QuadcastPacket`, `Frame`, `PresetSequencer`) is tested against byte-exact reference vectors derived from `reference/QuadcastRGB/`.
- Device/streamer logic is tested against `MockHIDTransport` — never the real IOKit/IOUSBHost adapters, which are hardware-only and exercised manually via `macmic-cli probe`.

## Hardware notes

This is important context for any future protocol/transport work — see the plan's Task 5/6 for the full investigation:

- `IOHIDManager`/`IOHIDDeviceSetReport` **cannot** reach the QuadCast S's vendor-page (`0xFF0B`) report handler on this class of Mac. Only a Consumer Control HID service (`usagePage 0x000c`) gets matched, and every report ID tried (`0`, `0x2A`, `0x2C`) at both 64- and 60-byte payload sizes was rejected with `kIOReturnError` (`0xE0005000`).
- The working path is a raw USB control transfer via `IOUSBHostDevice` (`Sources/QuadcastKit/HID/IOUSBHostTransport.swift`), matching what QuadcastRGB does over libusb. `IOUSBHostObjectInitOptionsDeviceSeize` on device init is what lets it take over from the kernel-resident HID driver — no separate `IOUSBHostInterface` claim needed.
- Two USB functions enumerate for one physical mic: PID `0x171f` (accepts control transfers, `kIOReturnSuccess`) and PID `0x171d` (rejects, `kIOReturnError`). Always prefer `0x171f`.
- The device does not persist color — streaming must never stop while lighting should stay on. `FrameStreamer` is a resident 55 ms loop, not a fire-and-forget configurator.
- `HIDTransport.open()` succeeding only means matching notifications were registered, not that a device is present: `IOUSBHostTransport` reports an already-matched device asynchronously via `onDeviceConnected` (`handleMatched` hops queue → main). `AppState.isConnected` must be set from that callback, never assumed true right after `open()` returns — see the `deviceAbsentAtLaunchLeavesStateDisconnected` regression test.
- `AppState.applyEnabledState()` must gate on `isConnected` as well as `isEnabled`: a `mode`/`brightness` change racing a hotplug-removal notification must not resume the streamer against a device that just disappeared.
- `FrameStreamer.setMode()` only resets `frameIndex` to 0 when `LightMode` itself changes, not on brightness-only calls: `AppState.applyEnabledState()` calls `setMode` on every brightness change too (e.g. once per `Slider` drag tick), so without this a `.cycle`/`.blink` animation would restart from frame 0 on every tick of the brightness slider instead of just dimming in place — see the `brightnessOnlyChangeDoesNotResetPlaybackPosition` regression test.

## Conventions

- Every source file (Swift and shell) carries a GPLv2 header. Files under `Sources/QuadcastKit/Protocol/`, `Sources/QuadcastKit/HID/`, `Sources/QuadcastKit/FrameStreamer.swift`, and `Sources/macmic-cli/` additionally credit Ors1mer/QuadcastRGB, since that logic is a direct port. See any existing file for the exact header text.
- License is GPLv2-only (not "or later") — matches the upstream QuadcastRGB license this project's protocol layer is ported from.
- `QuadcastKit`'s version-info enum is named `QuadcastKitInfo`, not `QuadcastKit` — a same-named type would shadow the module when a file also imports AppKit (which transitively defines an unrelated global `RGBColor` via Quickdraw, so `QuadcastKit.RGBColor` needs the module name to resolve unambiguously).
- App is unsandboxed by necessity (raw HID/USB vendor-page access); distributed via GitHub releases, not the Mac App Store.
