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

extension Notification.Name {
    /// Posted when something outside the SwiftUI view tree (the app delegate)
    /// wants the main window shown. `openWindow` is only reachable from a
    /// view, so a view that lives as long as the app (`MenuBarLabel`) listens.
    static let macmicShowMainWindow = Notification.Name("dev.alavreniuk.macmic.showMainWindow")
}

/// Runs MacMic as an accessory (menu-bar-only, no Dock icon) app. The main
/// window is opened on demand from the status menu; it doesn't give the app
/// a Dock presence.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Launching the app again while it's running (Finder, Launchpad,
    /// `open MacMic.app`) is the only way to reach a Dock-less app from
    /// outside the menu bar, so treat it as "show me the window".
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .macmicShowMainWindow, object: nil)
        return false
    }
}

/// The status item's label. It is the one view alive for the whole app
/// lifetime (menu and window contents only exist while shown), which is
/// what lets it turn `.macmicShowMainWindow` into an `openWindow` call.
private struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: state.isMicMuted ? "mic.slash.fill" : "mic.fill")
            .onReceive(NotificationCenter.default.publisher(for: .macmicShowMainWindow)) { _ in
                showMainWindow(openWindow)
            }
    }
}

/// Opens (or raises) the main window and brings it to the front.
/// `openWindow` alone leaves it behind the frontmost app: an accessory app
/// isn't activated by opening a window, and on macOS 14+ cooperative
/// activation ignores `ignoringOtherApps`, so the window is ordered front
/// explicitly. The `NSWindow` backing a `Window` scene only exists on the
/// run-loop turn after `openWindow`, hence the hop.
func showMainWindow(_ openWindow: OpenWindowAction) {
    openWindow(id: MainWindowView.windowID)
    DispatchQueue.main.async {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.windows.first(where: isMainWindow) else { return }
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
    }
}

/// SwiftUI derives the `NSWindow` identifier from the scene id (with a
/// suffix), so match on prefix. The title can't be used: the selected
/// page's `navigationTitle` replaces it.
private func isMainWindow(_ window: NSWindow) -> Bool {
    window.identifier?.rawValue.hasPrefix(MainWindowView.windowID) ?? false
}

@main
struct MacMicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState(
        transport: IOUSBHostTransport(),
        audioControl: CoreAudioDeviceControl()
    )

    var body: some Scene {
        // The MenuBarExtra must stay the first scene: SwiftUI auto-opens the
        // first window-type scene at launch, and a menu bar app must not.
        MenuBarExtra {
            MenuBarMenu(state: state)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.menu)

        // `Window` (not `WindowGroup`) so "Open MacMic" always brings up the
        // one existing window instead of opening another copy.
        Window(MainWindowView.windowTitle, id: MainWindowView.windowID) {
            MainWindowView(state: state)
        }
        .windowResizability(.contentMinSize)
        .defaultPosition(.center)
    }
}
