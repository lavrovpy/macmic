// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import AppKit
import QuadcastKit
import SwiftUI

/// Runs MacMic as an accessory (menu-bar-only, no Dock icon) app, matching
/// v1 scope: no separate windowed UI.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct MacMicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState(transport: IOUSBHostTransport())

    var body: some Scene {
        MenuBarExtra("MacMic", systemImage: "mic.fill") {
            ContentView(state: state)
        }
        .menuBarExtraStyle(.window)
    }
}
