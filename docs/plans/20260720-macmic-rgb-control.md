# MacMic — Native macOS RGB Control for HyperX QuadCast S

## Overview

- Build **MacMic**, a native macOS menu bar app (Swift + SwiftUI + IOKit HID) that controls the RGB lighting of the HyperX QuadCast S microphone.
- v1 scope (MVP): solid color via color picker, plus animated presets **Rainbow Cycle** and **Blink**, with a brightness control. Per-zone control, wave/lightning/pulse modes, and launch-at-login are explicitly **out of scope** for v1.
- Solves: there is no native macOS software for this mic (HyperX NGENUITY is Windows-only); without host software the mic only shows its default rainbow.
- License: **GPLv2** (the protocol layer is a Swift port of QuadcastRGB by Ors1mer, GPLv2-only, vendored in `reference/QuadcastRGB/`). Credit Ors1mer in README and file headers.

## Context (from discovery)

- **Greenfield repo** at `/Users/alavreniuk/Dev/macmic` — no code yet. Toolchain verified: Swift 6.2.1, Xcode 26.1.1, macOS 15 (arm64). ralphex v0.26.0 installed.
- **Hardware verified present** (diagnostics run 2026-07-20): QuadCast S enumerates as VID `0x0951` with **two simultaneous USB functions**: PID `0x171d` and PID `0x171f`. Each exposes HID services (`hidutil list` shows 4 QuadCast entries). One function carries a vendor usage page `0xFF0B` (65291) HID interface with 64-byte max feature reports (report IDs `0x2A`/`0x2C`, 60-byte payloads declared) plus `0xFF07` and `0xFF99` pages; the other carries consumer-control/keyboard/`0xFF60` interfaces.
- **Protocol reference**: `reference/QuadcastRGB/` contains the vendored GPLv2 C implementation (libusb-based, works on Linux/BSD/macOS). Key files: `modules/devio.c` (transport), `modules/rgbmodes.c` (frame/mode generation), `modules/rgbmodes.h` (constants). See Technical Details below for the extracted protocol spec.
- **Critical behavioral fact**: the mic does **not** persist software-set colors. The host must stream a frame roughly every 55 ms forever; when the stream stops, the mic reverts to its default rainbow. The app is therefore a resident streamer, not a fire-and-forget configurator.

## Development Approach

- **Testing approach**: Regular (code first, then tests in the same task)
- Project format: **SwiftPM package** (no `.xcodeproj`). Everything must build with `swift build` and test with `swift test` from the CLI. The `.app` bundle is assembled by a script in the final tasks.
- Minimum deployment target: macOS 13 (needed for SwiftUI `MenuBarExtra`).
- Complete each task fully before moving to the next
- Make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write unit tests for new functions/methods and modified functions/methods
  - add new test cases for new code paths
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- Run `swift test` after each change
- All IOKit calls live behind a `HIDTransport` protocol so logic is testable with a mock; only the thin `IOKitHIDTransport` adapter is untestable without hardware.
- Hardware-dependent verification is limited to "SetReport returns success" (automatable); visual confirmation of colors is Post-Completion.

## Testing Strategy

- **Unit tests** (Swift Testing framework, `swift test`): required for every task. Pure packet/frame logic is tested against byte-exact reference vectors derived from `reference/QuadcastRGB/`. Device/streamer logic is tested against `MockHIDTransport`.
- **No e2e/UI test framework** in v1 — SwiftUI menu bar surface is thin; all state logic lives in a testable `AppState` model.
- **Hardware smoke test**: `macmic-cli` (Task 5) exercises the real device; success criterion is IOReturn success on report submission, exit code 0.

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix
- Update plan if implementation deviates from original scope
- Keep plan in sync with actual work done

## What Goes Where

- **Implementation Steps** (`[]` checkboxes): tasks achievable within this codebase — code, tests, docs
- **Post-Completion** (no checkboxes): manual visual verification, GitHub publishing, notarization
- Checkboxes appear only in Task sections

## Implementation Steps

### Task 1: Scaffold SwiftPM package and license

- [x] create `Package.swift`: package `MacMic`, platforms `.macOS(.v13)`, targets: `QuadcastKit` (library), `MacMic` (executable, depends on QuadcastKit), `macmic-cli` (executable, depends on QuadcastKit), `QuadcastKitTests` (test target)
- [x] create minimal source stubs so all targets compile (`QuadcastKit/QuadcastKit.swift`, `MacMic/main.swift` printing a placeholder, `macmic-cli/main.swift` printing usage)
- [x] add `LICENSE` (GPLv2 full text) and GPLv2 header comment template noting "protocol layer ported from QuadcastRGB, Copyright (C) 2022-2025 Ors1mer"
- [x] create `.gitignore` for Swift (`.build/`, `.swiftpm/`, `*.xcodeproj`, `.DS_Store`)
- [x] write a smoke test in `QuadcastKitTests` (imports QuadcastKit, trivial assertion)
- [x] run `swift build && swift test` - must pass before task 2

### Task 2: Packet builder — header and solid-color frames

Port packet construction from `reference/QuadcastRGB/modules/devio.c` and `rgbmodes.c` (see Technical Details for the byte layout).

- [x] create `QuadcastKit/Protocol/QuadcastPacket.swift`: `static func headerPacket() -> [UInt8]` returning the 64-byte header `04 F2 00 00 00 00 00 00 01` + zero padding
- [x] create `RGBColor` struct (r, g, b as UInt8) with `init?(hex: String)` parsing `RRGGBB` / `#RRGGBB`
- [x] implement `Frame` type: one display frame = upper-zone color + lower-zone color; `func dataPacket() -> [UInt8]` returning 64 bytes: `[0x81, r, g, b]` (upper) at offset 0, `[0x81, r, g, b]` (lower) at offset 4, zero padding
- [x] implement brightness scaling: `Frame.scaled(brightness: Double)` multiplying each channel, clamped 0...1
- [x] write tests: header packet byte-exact vector; solid red frame == `81 FF 00 00 81 FF 00 00` + 56 zeros; hex parsing success + failure cases; brightness 0/0.5/1 vectors
- [x] run `swift test` - must pass before task 3

### Task 3: Preset frame sequencers — Rainbow Cycle and Blink

Port sequence generation from `reference/QuadcastRGB/modules/rgbmodes.c` (`sequence_cycle`, `sequence_blink`, `count_cycle_data`, `count_blink_data`; constants in `rgbmodes.h`: `MIN_CYCL_TR=12`, `MAX_CYCL_TR=128`, speed mapping `SPEED_RANGE`).

- [x] create `QuadcastKit/Protocol/PresetSequencer.swift` with `enum LightMode { case solid(RGBColor), cycle(speed: Int), blink(colors: [RGBColor], speed: Int) }`
- [x] implement `func frames(for mode: LightMode) -> [Frame]` — solid returns 1 frame; cycle generates the hue-rotation sequence with speed-dependent transition count; blink generates color-segment + off-delay segments
- [x] keep generation deterministic (no randomness in v1 — skip QuadcastRGB's blink-random variant)
- [x] write tests: frame counts match the reference formulas for min/max/default speed; cycle sequence starts and ends adjacent (loops smoothly); blink includes off (000000) delay frames; solid returns exactly one frame
- [x] write tests for invalid input (empty blink color list, out-of-range speed clamps)
- [x] run `swift test` - must pass before task 4

⚠️ Scope note: QuadcastRGB's `sequence_blink` takes independent `spd` (on-time) and `dly` (off-time) parameters. `LightMode.blink` only exposes `speed` per this plan's signature, so the off-delay segment reuses the on-segment length (`101 - speed` frames each way) for a symmetric blink. Rainbow Cycle uses a fixed built-in 6-hue palette (red/yellow/green/cyan/blue/magenta) rather than a user-supplied color list, since `LightMode.cycle` only takes `speed`.

### Task 4: HID transport layer

- [ ] create `QuadcastKit/HID/HIDTransport.swift`: protocol with `func sendFeatureReport(_ bytes: [UInt8]) throws`, `var onDeviceConnected/onDeviceRemoved` callbacks, `func open() / close()`
- [ ] create `QuadcastKit/HID/IOKitHIDTransport.swift` using `IOHIDManager`: match VID `0x0951` with PIDs `0x171f` and `0x171d` (array matching dictionaries); register matching/removal callbacks on a dedicated dispatch queue; open device; implement `sendFeatureReport` via `IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, reportID 0, ...)`
- [ ] device selection strategy (see Technical Details "Report submission risk"): prefer the PID `0x171f` HID service; on `kIOReturnError`/unsupported, fall back to the other QuadCast HID services; remember which service accepted reports
- [ ] create `QuadcastKit/HID/MockHIDTransport.swift` (records sent reports, scriptable failures) in the test target
- [ ] write tests using the mock: transport-consumer behavior — reports recorded in order, error propagation, reconnect callback flow (IOKit adapter itself is exercised by Task 5's CLI, not unit tests)
- [ ] run `swift test` - must pass before task 5

### Task 5: FrameStreamer and hardware smoke-test CLI

- [ ] create `QuadcastKit/FrameStreamer.swift`: owns a `DispatchSourceTimer` at 55 ms; each tick sends header packet then the next data packet from the current frame sequence (looping); `func setMode(_ mode: LightMode, brightness: Double)` swaps sequences atomically; `start() / stop()`; on transport error, stop and surface via callback
- [ ] implement `macmic-cli`: `macmic-cli solid <hex> [--brightness N]`, `macmic-cli cycle [--speed N]`, `macmic-cli blink <hex>...`, `macmic-cli probe` (lists matched QuadCast HID services and reports which accepts feature reports); runs the streamer until Ctrl-C
- [ ] `probe` must print per-service results (PID, usage page, IOReturn of a header-packet SetReport) — this is the hardware bring-up diagnostic
- [ ] write tests with MockHIDTransport: streamer sends header+data pairs in order, loops the sequence, `setMode` swaps cleanly mid-stream, stops on error, `stop()` ceases sends
- [ ] run `swift test` - must pass; run `swift build -c release` to confirm CLI links against IOKit
- [ ] run `.build/release/macmic-cli probe` — record output in the plan file; at least one service must accept SetReport with `kIOReturnSuccess` (⚠️ if all fail, investigate report ID `0x2A` / interface fallback per Technical Details before proceeding)

### Task 6: AppState and persistence

- [ ] create `MacMic/AppState.swift`: `@Observable` (or `ObservableObject`) model holding `isConnected`, `mode`, `brightness`, `isEnabled`; translates UI intent into `FrameStreamer` calls
- [ ] persist last mode/brightness/enabled to `UserDefaults` (encode `LightMode` as `Codable`); restore and re-apply on launch
- [ ] handle device hotplug: on `onDeviceConnected` re-apply current mode; on removal set `isConnected = false` and stop streamer
- [ ] handle sleep/wake: subscribe to `NSWorkspace.willSleepNotification` / `didWakeNotification`; stop streaming on sleep, re-apply mode on wake (USB state refresh)
- [ ] write tests: mode changes reach the mock transport; persistence round-trip (encode/decode `LightMode`); reconnect re-applies last mode; wake re-applies mode
- [ ] run `swift test` - must pass before task 7

### Task 7: Menu bar UI

- [ ] convert `MacMic` executable to a SwiftUI app: `@main` App with `MenuBarExtra("MacMic", systemImage: "mic.fill")` and `.menuBarExtraStyle(.window)`; set `NSApplication` activation policy `.accessory` (no Dock icon) in an app delegate
- [ ] popover content: enable/disable toggle, `ColorPicker` bound to solid color, preset buttons (Solid / Rainbow Cycle / Blink), brightness `Slider`, connection status line ("QuadCast S connected" / "not found"), Quit button
- [ ] gray out controls when `isConnected == false`
- [ ] wire `ColorPicker`'s `Color` → `RGBColor` conversion (via `NSColor` sRGB components) as a testable pure function
- [ ] write tests: `Color`/`RGBColor` conversion vectors (red/white/black, rounding), AppState → UI state derivations (disabled when disconnected)
- [ ] run `swift test` - must pass before task 8

### Task 8: App bundle assembly script

- [ ] create `scripts/make-app.sh`: `swift build -c release`, assemble `dist/MacMic.app` (`Contents/MacOS/MacMic`, generated `Info.plist` with `LSUIElement = true`, bundle id `dev.alavreniuk.macmic`, version), `codesign --force --sign -` (ad-hoc)
- [ ] make script idempotent and fail-fast (`set -euo pipefail`); verify with `codesign --verify` and a launch check that the process starts and stays alive for 3 seconds (then kill it)
- [ ] add `dist/` to `.gitignore`
- [ ] write test/check: shellcheck-clean if shellcheck available; run the script in CI-style (`bash scripts/make-app.sh`) and assert `dist/MacMic.app/Contents/MacOS/MacMic` exists and Info.plist contains `LSUIElement`
- [ ] run `swift test` and the script - must pass before task 9

### Task 9: Verify acceptance criteria

- [ ] verify all Overview requirements implemented: menu bar app, solid color picker, cycle + blink presets, brightness, hotplug + sleep/wake handling, persistence
- [ ] verify edge cases: mic unplugged at launch, unplugged mid-stream, invalid hex input in CLI, brightness extremes
- [ ] run full test suite `swift test` — all pass
- [ ] run `.build/release/macmic-cli probe` once more; confirm success path unchanged
- [ ] build release + bundle script cleanly from a fresh clone state (`git clean -ndx` review, then build)
- [ ] fix any compiler warnings; run `swift build 2>&1` warning-free

### Task 10: [Final] Update documentation

- [ ] write `README.md`: what it is, screenshot placeholder, install (build from source, `make-app.sh`), usage, how the protocol works (frame streaming, no persistence), credits to QuadcastRGB/Ors1mer, GPLv2 notice, known limitations (v1 scope)
- [ ] add `CLAUDE.md` with build/test commands and architecture map for future sessions
- [ ] ensure every source file carries the GPLv2 header

## Technical Details

### Protocol spec (extracted from QuadcastRGB `devio.c` / `rgbmodes.c`, GPLv2, Ors1mer)

**Device**: VID `0x0951` (Kingston), PID `0x171f` is the function QuadcastRGB opens. This specific mic also enumerates PID `0x171d` simultaneously.

**Transport**: USB control transfer = standard HID SET_REPORT:
- `bmRequestType 0x21`, `bRequest 0x09` (SET_REPORT), `wValue 0x0300` (Feature report, report ID 0), `wIndex 0x0000`, 64-byte payload, 1 s timeout.
- macOS equivalent: `IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, reportID: 0, buffer, 64)`.

**Display loop** (runs forever; stopping it reverts the mic to default rainbow):
```
repeat every 55 ms:
  send header packet (64 B): 04 F2 00 00 00 00 00 00 01 00...00
  send data packet   (64 B): 81 Ru Gu Bu 81 Rl Gl Bl 00...00
                             ^upper zone   ^lower zone
  advance to next frame in sequence (loop at end)
```
- `0x04` = header code, `0xF2` = display code, byte 8 = packet count `0x01`.
- `0x81` = RGB command code; each frame is one 8-byte pair (upper at offset 0, lower at offset 4); `BYTE_STEP = 4`.
- Solid color = a 1-frame sequence. Animations = host-precomputed frame sequences played at ~18 fps (55 ms).

**Mode generation** (rgbmodes.c): cycle = hue rotation with `SPEED_RANGE(12, 128, speed)` transition steps between key colors; blink = per-color lit segments followed by black delay segments; speed/delay params 0–100. Port formulas directly from the vendored source.

### Report submission risk (resolve in Task 5 `probe`)

The observed HID report descriptor (vendor page `0xFF0B`) declares feature reports with IDs `0x2A`/`0x2C` (60 B), not report ID 0. QuadcastRGB bypasses descriptors via raw control transfer with `wValue 0x0300` (report ID 0), which libusb sends regardless. On macOS, `IOHIDDeviceSetReport` with reportID 0 may be rejected by the HID stack if the service's descriptor declares no report 0. Mitigations, in order:
1. Try reportID 0 SetReport(Feature) on each matched QuadCast HID service (both PIDs) — likely one accepts.
2. If all reject: try prefixing/report ID `0x2A` on the `0xFF0B` service (60-byte payload window).
3. Last resort: drop to `IOUSBHostDevice`/libusb-style control transfer (would add a dependency — flag as ⚠️ scope change in this plan first).

macOS caveat: match narrowly (VID/PID; select service by usage page where possible) to avoid opening the keyboard-class interface, which can trigger an Input Monitoring TCC prompt.

### Architecture

```
MacMic (SwiftUI MenuBarExtra, .accessory)
  └─ AppState (persistence, hotplug, sleep/wake)
       └─ QuadcastKit
            ├─ FrameStreamer (55 ms DispatchSourceTimer)
            ├─ PresetSequencer (LightMode → [Frame])
            ├─ QuadcastPacket / Frame / RGBColor (pure, byte-exact)
            └─ HIDTransport (protocol)
                 ├─ IOKitHIDTransport (IOHIDManager)
                 └─ MockHIDTransport (tests)
macmic-cli (probe / solid / cycle / blink)
```

- Streaming stays on a dedicated dispatch queue; UI on main. `setMode` hands the streamer a new immutable `[Frame]` array (no locking on frame data).
- App is unsandboxed (raw HID vendor-page access; GitHub distribution, not App Store).

## Post-Completion

**Manual verification** (requires eyes on the mic):
- Visually confirm solid colors match picker selection (red/green/blue/white), cycle animates smoothly, blink timing feels right
- Confirm mic reverts to default rainbow when app quits, and MacMic re-takes control on relaunch
- Sleep the Mac, wake it, confirm lighting resumes without replugging
- Unplug/replug mic while app runs; confirm status line and lighting recovery
- Confirm no Input Monitoring permission prompt appears; if it does, tighten device matching

**External/publishing**:
- Create GitHub repo, push, add screenshot to README
- Optional later: Developer ID signing + notarization for distribution, Sparkle updates, launch-at-login (SMAppService), per-zone colors, remaining QuadcastRGB modes (wave, lightning, pulse), HP-VID QuadCast 2/2S support
