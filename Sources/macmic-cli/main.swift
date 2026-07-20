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
    macmic-cli \(QuadcastKit.version)

    Usage:
      macmic-cli solid <hex> [--brightness N]
      macmic-cli cycle [--speed N]
      macmic-cli blink <hex>...
      macmic-cli probe
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Opens the transport and gives `IOHIDManager`'s async device-matching
/// callbacks a moment to enumerate already-connected QuadCast HID services
/// before we act on `matchedDevices`.
func openAndWaitForEnumeration() -> IOKitHIDTransport {
    let transport = IOKitHIDTransport()
    do {
        try transport.open()
    } catch {
        fail("failed to open HID manager: \(error)")
    }
    Thread.sleep(forTimeInterval: 0.3)
    return transport
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
    let colors = rest.filter { !$0.hasPrefix("--") }.compactMap { RGBColor(hex: $0) }
    guard !colors.isEmpty else {
        fail("blink requires at least one valid <hex> color")
    }
    streamUntilInterrupted(mode: .blink(colors: colors, speed: parseSpeed(rest)), brightness: parseBrightness(rest))

case "probe":
    let transport = openAndWaitForEnumeration()
    do {
        let results = try transport.probe()
        print("matched \(results.count) QuadCast HID service(s):")
        var anySucceeded = false
        for result in results {
            anySucceeded = anySucceeded || result.succeeded
            let status = result.succeeded ? "OK" : "FAILED"
            let pid = String(format: "0x%04x", result.productID)
            let page = String(format: "0x%04x", result.usagePage)
            print("  PID \(pid)  usagePage \(page)  SetReport(header) -> \(result.ioReturn) (\(status))")
        }
        transport.close()
        exit(anySucceeded ? 0 : 1)
    } catch {
        fail("probe failed: \(error)")
    }

default:
    print(usage)
    exit(command == "help" || command == "--help" ? 0 : 1)
}
