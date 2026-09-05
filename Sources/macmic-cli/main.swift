// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Dispatch
import Foundation
import QuadcastKit

let usage = """
    macmic-cli \(QuadcastKitInfo.version)

    Usage:
      macmic-cli solid <hex> [--brightness N]
      macmic-cli cycle [--speed N]
      macmic-cli blink <hex>...
      macmic-cli probe
      macmic-cli audio status
      macmic-cli audio gain <0-100>
      macmic-cli audio mute on|off
      macmic-cli audio monitor <0-100>
      macmic-cli audio monitor-mute on|off
      macmic-cli audio test [--seconds N]
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Opens the transport and gives the async device-matching notification a
/// moment to enumerate already-connected QuadCast USB devices before we act
/// on them.
///
/// Uses `IOUSBHostTransport` (raw USB control transfers), not
/// `IOKitHIDTransport`: per the Task 5 hardware finding, `IOHIDManager`
/// cannot reach the QuadCast S's vendor-page report handler on this system,
/// while a raw control transfer via `IOUSBHostDevice` does.
func openAndWaitForEnumeration() -> IOUSBHostTransport {
    let transport = IOUSBHostTransport()
    do {
        try transport.open()
    } catch {
        fail("failed to open USB host transport: \(error)")
    }
    Thread.sleep(forTimeInterval: 0.3)
    return transport
}

/// Opens the Core Audio control. Unlike `openAndWaitForEnumeration`, no
/// sleep is needed: `CoreAudioDeviceControl.open()` scans the HAL device
/// list synchronously, so `snapshot` is valid as soon as this returns.
func openAudioControl() -> CoreAudioDeviceControl {
    let control = CoreAudioDeviceControl()
    do {
        try control.open()
    } catch {
        fail("failed to open Core Audio control: \(error)")
    }
    return control
}

func parseBrightness(_ arguments: [String]) -> Double {
    guard let index = arguments.firstIndex(of: "--brightness"), index + 1 < arguments.count,
          let value = Double(arguments[index + 1]) else {
        return 1.0
    }
    return value
}

func parseSpeed(_ arguments: [String]) -> Int {
    guard let index = arguments.firstIndex(of: "--speed"), index + 1 < arguments.count,
          let value = Int(arguments[index + 1]) else {
        return 50
    }
    return value
}

/// Strips `--speed`/`--brightness` flags *and* the values that follow them,
/// leaving only the positional `<hex>` color arguments (used by `blink`).
/// Filtering just the `--`-prefixed tokens isn't enough: a flag's numeric
/// value (e.g. `123456` in `--speed 123456`) is itself valid 6-digit hex and
/// would otherwise be silently parsed as an extra color.
func colorArguments(_ arguments: [String]) -> [String] {
    var result: [String] = []
    var skipNext = false
    for argument in arguments {
        if skipNext {
            skipNext = false
            continue
        }
        if argument == "--speed" || argument == "--brightness" {
            skipNext = true
            continue
        }
        if !argument.hasPrefix("--") {
            result.append(argument)
        }
    }
    return result
}

/// Runs the display loop until the process receives SIGINT (Ctrl-C),
/// stopping the streamer (and so releasing the mic back to its default
/// rainbow) before exiting.
func streamUntilInterrupted(mode: LightMode, brightness: Double) -> Never {
    let transport = openAndWaitForEnumeration()
    let streamer = FrameStreamer(transport: transport)
    streamer.onError = { error in
        FileHandle.standardError.write(Data("stream error: \(error)\n".utf8))
        exit(1)
    }
    streamer.setMode(mode, brightness: brightness)
    streamer.start()
    print("streaming (Ctrl-C to stop)…")

    let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signal(SIGINT, SIG_IGN)
    signalSource.setEventHandler {
        streamer.stop()
        transport.close()
        exit(0)
    }
    signalSource.resume()
    dispatchMain()
}

/// Passes the mic through the system default output for `seconds`, printing
/// every monitor state change and a level meter redrawn in place. With
/// `recordSeconds`, instead records that long once the pass-through is up,
/// plays the clip back, and exits when playback ends (exit 1 if the clip
/// came out empty). The device-list scan in `open()` is synchronous, but a
/// mic that is still enumerating is only reported by a later HAL
/// notification, so the input id is polled on the run loop for a few
/// seconds before giving up.
func runMicrophoneTest(control: CoreAudioDeviceControl, seconds: Int, recordSeconds: Int? = nil) -> Never {
    let deadline = Date().addingTimeInterval(3)
    var inputDevice = control.deviceID(for: .input)
    while inputDevice == nil, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        inputDevice = control.deviceID(for: .input)
    }
    guard let inputDevice else {
        control.close()
        fail("audio test: no QuadCast microphone input device found")
    }

    let monitor = AVAudioEngineMicrophoneMonitor()
    var level: Float = 0
    var meterShown = false
    let clearMeter = {
        if meterShown {
            print()
            meterShown = false
        }
    }
    let meterTimer = DispatchSource.makeTimerSource(queue: .main)
    let finish: (Int32) -> Never = { code in
        meterTimer.cancel()
        monitor.onStateChanged = nil
        monitor.onRecorderStateChanged = nil
        monitor.stop()
        control.close()
        exit(code)
    }

    var recordingStarted = false
    monitor.onStateChanged = { state in
        clearMeter()
        print(formatMonitorState(state))
        if case .failed = state {
            finish(1)
        }
        guard let recordSeconds, case .running = state, !recordingStarted else { return }
        recordingStarted = true
        monitor.startRecording()
        guard case .recording = monitor.recorderState else {
            print("could not start recording")
            finish(1)
        }
        print("recording for \(recordSeconds) s — say something…")
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(recordSeconds)) {
            monitor.stopRecording()
        }
    }
    // Only `.idle` matters here: once after the recording (start playback)
    // and once after playback (exit). Progress shows on the meter line.
    var playbackStarted = false
    monitor.onRecorderStateChanged = { recorderState in
        guard case let .idle(duration) = recorderState else { return }
        clearMeter()
        if playbackStarted {
            print("playback finished")
            finish(0)
        }
        guard let duration else {
            print("recorded nothing")
            finish(1)
        }
        print(String(format: "recorded %.1f s", duration))
        monitor.startPlayback()
        guard case .playing = monitor.recorderState else {
            print("could not start playback")
            finish(1)
        }
        playbackStarted = true
        print("playing back…")
    }
    monitor.onLevel = { level = $0 }

    meterTimer.schedule(deadline: .now(), repeating: 0.1)
    meterTimer.setEventHandler {
        guard case .running = monitor.state else { return }
        // Clear to end of line: the recorder suffix changes width.
        print("\r\(formatLevelMeter(level))  \(formatRecorderState(monitor.recorderState))\u{1B}[K", terminator: "")
        fflush(stdout)
        meterShown = true
    }
    meterTimer.resume()

    if recordSeconds == nil {
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) {
            finish(0)
        }
    }

    let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    signal(SIGINT, SIG_IGN)
    signalSource.setEventHandler {
        finish(0)
    }
    signalSource.resume()

    if let recordSeconds {
        print("testing microphone (input device \(inputDevice)): record \(recordSeconds) s, then play back…")
    } else {
        print("testing microphone (input device \(inputDevice)) for \(seconds) s…")
    }
    monitor.start(inputDevice: inputDevice)
    dispatchMain()
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    print(usage)
    exit(0)
}
let rest = Array(arguments.dropFirst())

switch command {
case "solid":
    guard let hex = rest.first, let color = RGBColor(hex: hex) else {
        fail("solid requires a valid <hex> color, e.g. macmic-cli solid FF0000")
    }
    streamUntilInterrupted(mode: .solid(color), brightness: parseBrightness(rest))

case "cycle":
    streamUntilInterrupted(mode: .cycle(speed: parseSpeed(rest)), brightness: parseBrightness(rest))

case "blink":
    let colors = colorArguments(rest).compactMap { RGBColor(hex: $0) }
    guard !colors.isEmpty else {
        fail("blink requires at least one valid <hex> color")
    }
    streamUntilInterrupted(mode: .blink(colors: colors, speed: parseSpeed(rest)), brightness: parseBrightness(rest))

case "probe":
    let transport = openAndWaitForEnumeration()
    do {
        let results = try transport.probe()
        print("matched \(results.count) QuadCast USB device(s) (IOUSBHostTransport, raw control transfer):")
        var anySucceeded = false
        for result in results {
            anySucceeded = anySucceeded || result.succeeded
            let status = result.succeeded ? "OK" : "FAILED"
            let pid = String(format: "0x%04x", result.productID)
            print("  PID \(pid)  SET_REPORT(header) -> \(result.ioReturn) (\(status))")
        }
        transport.close()
        exit(anySucceeded ? 0 : 1)
    } catch {
        fail("probe failed: \(error)")
    }

case "audio":
    guard let audioCommand = parseAudioCommand(rest) else {
        fail(audioUsage)
    }
    let control = openAudioControl()
    do {
        switch audioCommand {
        case .status:
            break
        case let .setVolume(scalar, direction):
            try control.setVolume(scalar, for: direction)
        case let .setMuted(muted, direction):
            try control.setMuted(muted, for: direction)
        case let .test(seconds):
            runMicrophoneTest(control: control, seconds: seconds)
        case let .testRecording(seconds):
            runMicrophoneTest(control: control, seconds: seconds, recordSeconds: seconds)
        }
    } catch {
        fail("audio: \(error)")
    }
    let snapshot = control.snapshot
    print(formatAudioStatus(snapshot))
    control.close()
    exit(snapshot.isAvailable ? 0 : 1)

default:
    print(usage)
    exit(command == "help" || command == "--help" ? 0 : 1)
}
