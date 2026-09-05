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
swift run macmic-cli audio status # hardware diagnostic: Core Audio gain/mute + monitoring volume/mute of the mic
```

There is no separate lint step; `swift build` must be warning-free (checked in Task 10 of the plan).

## Architecture

```
MacMic (SwiftUI MenuBarExtra menu + one sidebar-navigation Window (Lighting, Audio, Device), .accessory — no Dock icon)
  └─ AppState (persistence, hotplug, sleep/wake, audio state)
       └─ QuadcastKit
            ├─ FrameStreamer (55 ms DispatchSourceTimer display loop)
            ├─ PresetSequencer (LightMode → [Frame])
            ├─ QuadcastPacket / Frame / RGBColor (pure, byte-exact protocol types)
            ├─ HIDTransport (protocol) — lighting
            │    ├─ IOUSBHostTransport (raw USB control transfer — the transport that actually works, see below)
            │    ├─ IOKitHIDTransport (IOHIDManager path — doesn't reach the device on this hardware, kept for reference)
            │    └─ MockHIDTransport (test target only)
            └─ AudioDeviceControl (protocol) — mic gain/mute, headphone-monitoring volume/mute
                 ├─ CoreAudioDeviceControl (Core Audio HAL properties, observed live)
                 └─ MockAudioDeviceControl (test target only)
macmic-cli (probe / solid / cycle / blink / audio — thin executable over QuadcastKit)
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
- `Sources/QuadcastKit/Audio/AudioDeviceControl.swift` — `AudioDirection` (`.input` = mic, `.output` = headphone monitoring), `AudioLevel` (volume scalar `0...1`, mute, read-only dB), `AudioDeviceSnapshot` (both directions; `nil` = that Core Audio device is absent), the `AudioDeviceControl` protocol (one `onStateChanged` full-snapshot callback on the main thread, `setVolume(_:for:)`, `setMuted(_:for:)`) and its errors
- `Sources/QuadcastKit/Audio/CoreAudioDeviceControl.swift` — the production adapter: matches the mic's two HAL devices by `kAudioDevicePropertyModelUID`, listens for device-list and per-device mute/volume changes on a private serial queue, delivers snapshots on main
- `Sources/QuadcastKit/FrameStreamer.swift` — owns the 55 ms timer, sends header+data packets in a loop, swaps `LightMode` atomically
- `Sources/MacMic/AppState.swift` — `@Observable`/`ObservableObject` model: persistence (`UserDefaults`), hotplug, sleep/wake, translates UI intent into `FrameStreamer` calls; also owns the live `audio: AudioDeviceSnapshot` (not persisted — the device and macOS are the source of truth) and translates `setAudioVolume`/`setAudioMuted` into `AudioDeviceControl` calls, reconciling the HAL's echo of its own writes in `reconcile` (see Hardware notes)
- `Sources/MacMic/AppState+UI.swift` — UI-facing derivations on top of `AppState`, shared by the popover and the settings window: `LightModeKind` + `modeKind` (switching restores each mode's remembered payload), `solidColor` (falls back to `lastSolidColor`, not white, when a preset is active), `presetSpeed`, `blinkColors` (falls back to `lastBlinkColors`, then `[lastSolidColor]` if Blink was never used), `controlsEnabled` (lighting only), `connectionStatusText`; audio: `micGain`, `isMicMuted`, `monitorVolume`, `isMonitorMuted`, `micControlsEnabled`/`monitorControlsEnabled`, `audioStatusText`, `levelText`
- `Sources/MacMic/ColorConversion.swift` — pure `Color` ↔ `QuadcastKit.RGBColor` conversion via `NSColor`'s sRGB space; testable without a menu bar
- `Sources/MacMic/MenuBarMenu.swift` — the `MenuBarExtra` pull-down menu (`.menu` style, not a popover): status, enable toggle, mode submenu, "Mute Microphone" toggle, "Open MacMic…", Quit
- `Sources/MacMic/MainWindowView.swift` — the app's single window: `NavigationSplitView` with a sidebar of `MainWindowPage`s (Lighting, Audio, Device)
- `Sources/MacMic/LightingPage.swift`, `AudioPage.swift`, `DevicePage.swift` — the pages' grouped `Form`s: mode picker, per-mode color/speed, brightness; mic gain/mute + monitoring volume/mute; lighting + audio status and the enable toggle
- `Sources/MacMic/InlineColorEditor.swift` — swatches + RGB sliders + hex field bound to `RGBColor`; used instead of `ColorPicker` because that opens the system Colors panel as a second floating window
- `Sources/MacMic/MacMicApp.swift` — scenes: the `MenuBarExtra` first (so nothing auto-opens at launch) and a single `Window(id: MainWindowView.windowID)`; the app stays `.accessory`, so `showMainWindow` orders the window front explicitly (`openWindow` alone leaves it behind the frontmost app on macOS 14+), and re-launching the app (`applicationShouldHandleReopen`) opens the window
- `Sources/macmic-cli/main.swift` — `probe` / `solid` / `cycle` / `blink` / `audio` subcommands
- `Sources/macmic-cli/AudioCommand.swift` — pure parsing (`parseAudioCommand`, `parsePercent`, `parseOnOff`) and formatting (`formatAudioStatus`) for `macmic-cli audio`

### Testing approach

- Unit tests only (Swift Testing framework via `swift test`); no e2e/UI framework — all state logic lives in testable `AppState`, so the thin SwiftUI views don't need their own tests.
- Pure protocol/frame logic (`QuadcastPacket`, `Frame`, `PresetSequencer`) is tested against byte-exact reference vectors derived from `reference/QuadcastRGB/`.
- Device/streamer logic is tested against `MockHIDTransport` — never the real IOKit/IOUSBHost adapters, which are hardware-only and exercised manually via `macmic-cli probe`.
- Audio logic is tested against `MockAudioDeviceControl`; `CoreAudioDeviceControl` is hardware-only, exercised via `macmic-cli audio`. Its pure helpers (`isQuadcast`, `directions`, `scope(for:)`, and the rescan halves `assignDirections` / `listenerDiff` that decide which HAL device serves which direction and which per-device listeners to drop/register on hotplug) are unit-tested directly; `rescanDevices` itself only does the HAL reads and applies the diff.

## Hardware notes

This is important context for any future protocol/transport work — see the plan's Task 5/6 for the full investigation:

- `IOHIDManager`/`IOHIDDeviceSetReport` **cannot** reach the QuadCast S's vendor-page (`0xFF0B`) report handler on this class of Mac. Only a Consumer Control HID service (`usagePage 0x000c`) gets matched, and every report ID tried (`0`, `0x2A`, `0x2C`) at both 64- and 60-byte payload sizes was rejected with `kIOReturnError` (`0xE0005000`).
- The working path is a raw USB control transfer via `IOUSBHostDevice` (`Sources/QuadcastKit/HID/IOUSBHostTransport.swift`), matching what QuadcastRGB does over libusb. `IOUSBHostObjectInitOptionsDeviceSeize` on device init is what lets it take over from the kernel-resident HID driver — no separate `IOUSBHostInterface` claim needed.
- Two USB functions enumerate for one physical mic: PID `0x171f` (accepts control transfers, `kIOReturnSuccess`) and PID `0x171d` (rejects, `kIOReturnError`). Always prefer `0x171f`. Because both are matched/removed independently, `IOUSBHostTransport.handleRemoved` (and `IOKitHIDTransport.handleDeviceRemoved`) only fire `onDeviceRemoved` once *every* matched function is gone — firing on the first termination would spuriously disconnect the app while the other function (usually the working `0x171f`) is still present.
- The device does not persist color — streaming must never stop while lighting should stay on. `FrameStreamer` is a resident 55 ms loop, not a fire-and-forget configurator.
- `HIDTransport.open()` succeeding only means matching notifications were registered, not that a device is present: `IOUSBHostTransport` reports an already-matched device asynchronously via `onDeviceConnected` (`handleMatched` hops queue → main). `AppState.isConnected` must be set from that callback, never assumed true right after `open()` returns — see the `deviceAbsentAtLaunchLeavesStateDisconnected` regression test.
- `AppState.applyEnabledState()` must gate on `isConnected` as well as `isEnabled`: a `mode`/`brightness` change racing a hotplug-removal notification must not resume the streamer against a device that just disappeared.
- **Audio (Core Audio HAL, not the vendor USB protocol).** The mic enumerates as *two* Core Audio devices, both named `HyperX QuadCast S` / manufacturer `Kingston` / transport USB, with `kAudioDevicePropertyModelUID` = `HyperX QuadCast S:0951:171D` on both. `CoreAudioDeviceControl` matches on that ModelUID suffix (`:0951:171d`, compared case-insensitively) and falls back to the name only when no ModelUID is reported. The two devices are told apart by `kAudioDevicePropertyStreamConfiguration` channel counts per scope (2 in / 0 out = microphone, 0 in / 2 out = headphone monitoring), not by the `DeviceUID` suffix (`…:4100:1` / `:2` are just enumeration order).
- Audio is the `0x171d` USB function — the one that *rejects* lighting control transfers — so audio presence and lighting (`HIDTransport`) presence are independent hotplug lifecycles; `AppState.audio` availability is never derived from `isConnected` or vice versa.
- Per scope (input for the mic, output for monitoring): `kAudioDevicePropertyMute` is on element 0 (main) only; `kAudioDevicePropertyVolumeScalar` / `VolumeDecibels` are on elements 1 and 2 (per channel) and **not** on element 0. `CoreAudioDeviceControl` writes every channel with the same value and reads channel 1. Do not add an element-0 volume fallback without a probe result for a device that needs it. Observed dB ranges: input -8…+7 dB, output -40…-9 dB. `kAudioDevicePropertyDataSource` is absent on both devices.
- The HAL quantizes a written volume scalar (USB audio volume is in 1/256 dB steps; e.g. writing 0.812 reads back 0.81217885) and its listener echoes the quantized value. `AppState.reconcile` treats an incoming volume within `audioEchoTolerance` (1%) of the current one, with the mute bit unchanged, as that echo and keeps the slider value (taking only the fresh dB); everything else — availability, mute, larger deltas — takes the incoming value. `CoreAudioDeviceControl.refreshSnapshot` separately dedups byte-identical re-reads.
- Verified 2026-09-05 via `macmic-cli audio`: gain/mute/monitor/monitor-mute writes all took effect and read back; an external write from an independent Core Audio process was delivered through `onStateChanged` on the main queue within ~1 s; `close()` removed every listener with `noErr`.
- Audio hotplug verified 2026-09-05 by re-enumerating the audio function in software (`IOUSBHostDevice.reset()` on PID `0x171d` — only possible while MacMic is *not* running, since its transport holds that function exclusively): `CoreAudioDeviceControl` delivered `.unavailable` ~30 ms after the reset, the devices came back ~2 s later under new AudioObjectIDs (`110/102` → `196/188`), listeners were re-registered on the new ids (proven by the control then reporting macOS restoring the saved gain: the mic re-enumerates at gain 0.80 and coreaudiod writes the remembered 0.68 back ~0.7 s later — the mic does not persist gain across re-enumeration), and a write/readback/`close()` afterwards were clean. A physical unplug/replug takes the same `kAudioHardwarePropertyDevices` path. **Whether host-side mute lights the mic's red mute LED has not been observed** (the CLI check was run without eyes on the mic) — treat it as unknown until someone records the observation here.
- Polar pattern is a physical knob on the QuadCast S with no software interface; nothing in the code attempts it.
- `FrameStreamer.setMode()` only resets `frameIndex` to 0 when `LightMode` itself changes, not on brightness-only calls: `AppState.applyEnabledState()` calls `setMode` on every brightness change too (e.g. once per `Slider` drag tick), so without this a `.cycle`/`.blink` animation would restart from frame 0 on every tick of the brightness slider instead of just dimming in place — see the `brightnessOnlyChangeDoesNotResetPlaybackPosition` regression test.

## Conventions

- Every source file (Swift and shell) carries a GPLv2 header. Files under `Sources/QuadcastKit/Protocol/`, `Sources/QuadcastKit/HID/`, and `Sources/QuadcastKit/FrameStreamer.swift` additionally credit Ors1mer/QuadcastRGB, since that logic is a direct port. `Sources/QuadcastKit/Audio/` and `Sources/macmic-cli/` are not ports (plain GPLv2 header, no credit line). See any existing file for the exact header text.
- License is GPLv2-only (not "or later") — matches the upstream QuadcastRGB license this project's protocol layer is ported from.
- `QuadcastKit`'s version-info enum is named `QuadcastKitInfo`, not `QuadcastKit` — a same-named type would shadow the module when a file also imports AppKit (which transitively defines an unrelated global `RGBColor` via Quickdraw, so `QuadcastKit.RGBColor` needs the module name to resolve unambiguously).
- App is unsandboxed by necessity (raw HID/USB vendor-page access); distributed via GitHub releases, not the Mac App Store.
