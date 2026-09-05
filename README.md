# MacMic

A native macOS menu bar app that controls the RGB lighting on a HyperX QuadCast S microphone. HyperX only ships NGENUITY for Windows, so without host software the mic just displays its default rainbow — MacMic fills that gap on macOS.

![screenshot placeholder](docs/screenshot.png)

## Features (v1)

- Solid color via a native `ColorPicker`
- Animated presets: **Rainbow Cycle** and **Blink**
- Brightness control
- Persists your last color/mode/brightness across launches
- Recovers automatically on device hotplug and sleep/wake
- Menu bar app — no Dock icon; a status menu for quick switches and one window with sidebar navigation (Lighting, Device) for everything else

Out of scope for v1: per-zone color, wave/lightning/pulse modes, launch-at-login. See [Post-Completion](docs/plans/20260720-macmic-rgb-control.md#post-completion) in the plan for the full list of future ideas.

## Install

Requires macOS 13 (Ventura) or later. MacMic is distributed as source; there's no signed release yet (see Known Limitations). Build it yourself:

```sh
git clone <this repo>
cd macmic
./scripts/make-app.sh
open dist/MacMic.app
```

`scripts/make-app.sh` builds the release binary with `swift build -c release`, assembles `dist/MacMic.app` (with an `LSUIElement` `Info.plist` so it never shows a Dock icon), and ad-hoc code-signs it. Since the app isn't notarized, the first launch may need a right-click → Open, or `xattr -dr com.apple.quarantine dist/MacMic.app`, to get past Gatekeeper.

## Usage

Launch `MacMic.app`; a mic icon appears in the menu bar. Its menu has:

- Connection status line
- **Lighting Enabled** — turn streaming on/off without quitting
- **Mode** submenu — Solid / Rainbow Cycle / Blink
- **Open MacMic…** (⌘,) — opens the main window
- **Quit MacMic**

The main window (also opened by launching the app again from Finder or Launchpad) has two sidebar pages:

- **Lighting** — mode picker; for Solid an inline color editor (preset swatches, RGB sliders, hex field); for Blink a list of colors to step through plus speed; for Rainbow Cycle the speed; and brightness. Each mode remembers its own color/speed, so switching modes and back restores what you had.
- **Device** — connection status and the lighting on/off switch

There's also a CLI, `macmic-cli`, useful for scripting or hardware bring-up diagnostics:

```sh
swift run macmic-cli probe                     # lists matched USB services and which accepts control transfers
swift run macmic-cli solid FF0000               # stream solid red until Ctrl-C
swift run macmic-cli solid 00FF00 --brightness 0.5
swift run macmic-cli cycle --speed 50           # rainbow cycle, speed 0-100
swift run macmic-cli blink FF0000 0000FF        # blink through a color list
```

## How it works

The QuadCast S does **not** persist software-set colors — it only remembers a color while a host keeps streaming frames to it. MacMic runs a `DispatchSourceTimer` that sends a header packet plus a data packet (upper-zone + lower-zone RGB) every 55 ms for as long as the app is enabled; stop the stream (quit the app, disable it, sleep the Mac) and the mic reverts to its default rainbow.

Frames are generated ahead of time by `PresetSequencer` — a solid color is a one-frame sequence, Rainbow Cycle and Blink are precomputed frame sequences played back on loop — so the timer's job on every tick is just "send the next byte-exact 64-byte packet," never compute one.

On this machine, `IOHIDManager`/`IOHIDDeviceSetReport` cannot reach the QuadCast S's vendor-page (`0xFF0B`) report handler — only a Consumer Control HID service gets matched, and every report ID it accepted structurally was rejected by the device with `kIOReturnError`. The working transport instead issues a raw USB control transfer (the same `SET_REPORT`-shaped request QuadcastRGB sends over libusb) directly against `IOUSBHostDevice`, bypassing the HID class layer entirely. See `Sources/QuadcastKit/HID/IOUSBHostTransport.swift` and the Task 5/6 hardware findings in [the implementation plan](docs/plans/20260720-macmic-rgb-control.md) for the full investigation.

### Architecture

```
MacMic (SwiftUI MenuBarExtra, .accessory)
  └─ AppState (persistence, hotplug, sleep/wake)
       └─ QuadcastKit
            ├─ FrameStreamer (55 ms DispatchSourceTimer)
            ├─ PresetSequencer (LightMode → [Frame])
            ├─ QuadcastPacket / Frame / RGBColor (pure, byte-exact)
            └─ HIDTransport (protocol)
                 ├─ IOUSBHostTransport (raw USB control transfer — the working path)
                 ├─ IOKitHIDTransport (IOHIDManager — kept for reference/other systems)
                 └─ MockHIDTransport (tests)
macmic-cli (probe / solid / cycle / blink)
```

## Credits

The protocol layer (`Sources/QuadcastKit/Protocol/`, and the report-submission shape in `Sources/QuadcastKit/HID/`) is a Swift port of [QuadcastRGB](https://github.com/Ors1mer/QuadcastRGB) by Ors1mer, vendored for reference at `reference/QuadcastRGB/`. Byte layouts, frame timing, and cycle/blink sequencing formulas come directly from that project's `modules/devio.c` and `modules/rgbmodes.c`.

## License

GPLv2-only, matching the upstream QuadcastRGB license. See [LICENSE](LICENSE).

## Known limitations (v1)

- No per-zone color control (upper/lower zones always match)
- No wave, lightning, or pulse modes
- No launch-at-login
- Not code-signed with a Developer ID or notarized — Gatekeeper will warn on first launch
- Only tested against the QuadCast S (VID `0x0951`, PID `0x171f`/`0x171d`); QuadCast 2/2S and DuoCast are untested
- Unsandboxed: MacMic needs raw USB device access, so it isn't (and can't easily be) distributed via the Mac App Store
