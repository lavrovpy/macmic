// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import QuadcastKit
import SwiftUI

/// The pages of the main window's sidebar.
enum MainWindowPage: String, CaseIterable, Identifiable {
    case lighting, audio, device

    var id: Self { self }

    var title: String {
        switch self {
        case .lighting: return "Lighting"
        case .audio: return "Audio"
        case .device: return "Device"
        }
    }

    var systemImage: String {
        switch self {
        case .lighting: return "light.max"
        case .audio: return "waveform"
        case .device: return "mic"
        }
    }
}

/// The app's single window: a sidebar of pages on the left and the selected
/// page's settings on the right, System Settings-style. All state lives in
/// `AppState`; the pages only bind to it.
struct MainWindowView: View {
    /// Scene ID of the `Window` that hosts this view, used by
    /// `openWindow(id:)` from the status menu.
    static let windowID = "main"
    static let windowTitle = "MacMic"

    @ObservedObject var state: AppState
    @State private var page: MainWindowPage? = .lighting

    var body: some View {
        NavigationSplitView {
            List(MainWindowPage.allCases, selection: $page) { page in
                Label(page.title, systemImage: page.systemImage)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            switch page ?? .lighting {
            case .lighting:
                LightingPage(state: state)
            case .audio:
                AudioPage(state: state)
            case .device:
                DevicePage(state: state)
            }
        }
        .navigationTitle((page ?? .lighting).title)
        .frame(minWidth: 640, minHeight: 460)
    }
}
