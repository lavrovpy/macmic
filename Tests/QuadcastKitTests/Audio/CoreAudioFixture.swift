// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import CoreAudio
import Foundation
@testable import QuadcastKit

/// A `CoreAudioDeviceControl` over a `FakeHAL`, delivering on a private
/// serial queue into `deliveries`. The control is not opened.
final class CoreAudioFixture {
    static let inputID: AudioObjectID = 70
    static let outputID: AudioObjectID = 74

    let hal: FakeHAL
    let callbackQueue: DispatchQueue
    let control: CoreAudioDeviceControl
    let deliveries: DeliveryRecorder

    /// `devices` are plugged, in order, before the control is built.
    init(devices: [FakeHAL.Device] = [
        .quadcastInput(id: CoreAudioFixture.inputID), .quadcastOutput(id: CoreAudioFixture.outputID),
    ]) {
        let hal = FakeHAL()
        devices.forEach(hal.plug)
        let callbackQueue = DispatchQueue(label: "dev.alavreniuk.macmic.tests.coreaudio-callbacks")
        let control = CoreAudioDeviceControl(hal: hal, callbackQueue: callbackQueue)
        self.hal = hal
        self.callbackQueue = callbackQueue
        self.control = control
        deliveries = DeliveryRecorder(observing: control)
    }

    /// Lets everything already set in motion land: the control's queue runs
    /// the listener blocks the fake has fired, then the callback queue runs
    /// the deliveries those scheduled.
    func settle() {
        _ = control.snapshot
        callbackQueue.sync {}
    }
}

/// Every snapshot delivered to one observer, from any thread.
final class DeliveryRecorder {
    private let lock = NSLock()
    private var recorded: [AudioDeviceSnapshot] = []
    private var observation: AudioDeviceObservation?

    /// Records `control`'s deliveries for as long as this recorder lives.
    init(observing control: AudioDeviceControl) {
        observation = control.observe { [weak self] in self?.append($0) }
    }

    var snapshots: [AudioDeviceSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var count: Int {
        snapshots.count
    }

    var last: AudioDeviceSnapshot? {
        snapshots.last
    }

    func cancelObservation() {
        observation?.cancel()
    }

    private func append(_ snapshot: AudioDeviceSnapshot) {
        lock.lock()
        recorded.append(snapshot)
        lock.unlock()
    }
}
