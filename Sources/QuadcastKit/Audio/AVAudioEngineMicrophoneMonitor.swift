// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import AVFoundation
import CoreAudio
import Foundation

/// `MicrophoneMonitor` backed by `AVAudioEngine`, routing the requested
/// Core Audio input device to the system default output through a private
/// aggregate device.
///
/// The aggregate is not optional: on macOS `inputNode` and `outputNode`
/// share one HAL I/O unit, so binding that unit to the mic (an input-only
/// device) with `kAudioOutputUnitProperty_CurrentDevice` also moves the
/// output there and `start()` fails with `kAudioUnitErr_FailedInitialization`
/// (-10875). AVAudioEngine itself runs on a private aggregate of the default
/// input and output for the same reason; this class builds the equivalent
/// for mic + default output, with the output as clock master and drift
/// compensation on the mic. The aggregate is destroyed on every stop.
///
/// Before building it, the mic's nominal sample rate is pinned to the
/// output's when the mic supports that rate (and left pinned afterwards):
/// with the mic at another rate (Teams parks the QuadCast at 16 kHz) the HAL
/// resamples it inside the aggregate and restarts the aggregate's I/O a few
/// seconds in, which AVAudioEngine turns into a configuration change and a
/// stall — observed on macOS 15.7 with the mic at 16 kHz and the output at
/// 48 kHz; pinned to 48 kHz it ran clean.
///
/// Three events restart the pass-through on the same input device:
/// `AVAudioEngineConfigurationChange` (only once the engine has really
/// stopped — it also posts one, with the engine still running, right after
/// `start()`), the default output device changing (the aggregate names a
/// specific output, so the engine can't notice this itself), and the HAL
/// device list changing (a vanished mic fails the restart's validation with
/// `.inputDeviceUnavailable`).
///
/// Not thread-safe: `start`/`stop` are main-thread calls and all state lives
/// on the main thread. The only off-main code is the input tap, which hops
/// to main at most every `levelInterval` (see `LevelThrottle`). `generation`
/// invalidates anything still in flight — a permission prompt, a
/// rate-pinning wait, a tap buffer, a restart — from a session that has
/// since been stopped or restarted.
public final class AVAudioEngineMicrophoneMonitor: MicrophoneMonitor {
    public var onStateChanged: ((MicrophoneMonitorState) -> Void)?
    public var onLevel: ((Float) -> Void)?
    public private(set) var state: MicrophoneMonitorState = .stopped

    static let tapBufferSize: AVAudioFrameCount = 1024
    /// The tap fires per buffer (~47 Hz at 48 kHz); `onLevel` is decimated
    /// to this so a meter animating at ~80 ms isn't fed faster than it can
    /// draw, and not at all while the level is within `levelEpsilon` (0.5%
    /// of the bar) of what was last delivered.
    static let levelInterval: TimeInterval = 1.0 / 25
    static let levelEpsilon: Float = 0.005
    static let aggregateDeviceName = "MacMic Microphone Test"
    /// Polling interval and cap for the mic's nominal rate to read back
    /// after pinning; the HAL applies the change asynchronously.
    static let ratePollInterval: TimeInterval = 0.02
    static let ratePollAttempts = 50

    private struct Listener {
        let objectID: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var engine: AVAudioEngine?
    private var aggregateDevice: AudioObjectID?
    private var configurationObserver: NSObjectProtocol?
    private var listeners: [Listener] = []
    private var inputDevice: AudioObjectID?
    private var generation = 0
    private var restartScheduled = false

    public init() {}

    deinit {
        tearDown()
    }

    public func start(inputDevice: AudioObjectID) {
        tearDown()
        generation += 1
        let session = generation
        self.inputDevice = inputDevice
        transition(to: .starting)

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            prepareInputDevice(session: session)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, self.generation == session else { return }
                    if granted {
                        self.prepareInputDevice(session: session)
                    } else {
                        self.transition(to: .failed(.microphoneAccessDenied))
                    }
                }
            }
        case .denied, .restricted:
            transition(to: .failed(.microphoneAccessDenied))
        @unknown default:
            transition(to: .failed(.microphoneAccessDenied))
        }
    }

    public func stop() {
        generation += 1
        tearDown()
        inputDevice = nil
        if state != .stopped {
            transition(to: .stopped)
        }
    }

    // MARK: - Session setup (main thread)

    /// Validates the mic, pins its rate to the output's, then builds the
    /// engine once the rate has read back (or the wait has timed out).
    private func prepareInputDevice(session: Int) {
        guard let inputDevice, HAL.isAlive(inputDevice), HAL.channelCount(inputDevice, scope: kAudioObjectPropertyScopeInput) > 0 else {
            transition(to: .failed(.inputDeviceUnavailable))
            return
        }
        guard let output = HAL.defaultOutputDevice() else {
            transition(to: .failed(.engineFailed("no default output device")))
            return
        }
        let outputRate = HAL.nominalSampleRate(output)
        guard outputRate > 0, HAL.nominalSampleRate(inputDevice) != outputRate,
              HAL.availableSampleRates(inputDevice).contains(outputRate),
              HAL.setNominalSampleRate(inputDevice, outputRate) else {
            startEngine(session: session, output: output)
            return
        }
        awaitNominalSampleRate(inputDevice, outputRate, attemptsLeft: Self.ratePollAttempts, session: session) {
            self.startEngine(session: session, output: output)
        }
    }

    private func awaitNominalSampleRate(
        _ device: AudioObjectID, _ rate: Double, attemptsLeft: Int, session: Int, then continuation: @escaping () -> Void
    ) {
        guard HAL.nominalSampleRate(device) != rate, attemptsLeft > 0 else {
            continuation()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.ratePollInterval) { [weak self] in
            guard let self, self.generation == session else { return }
            self.awaitNominalSampleRate(device, rate, attemptsLeft: attemptsLeft - 1, session: session, then: continuation)
        }
    }

    private func startEngine(session: Int, output: AudioObjectID) {
        guard let inputDevice else { return }
        let aggregate: AudioObjectID
        switch Self.createAggregateDevice(input: inputDevice, output: output) {
        case let .success(id):
            aggregate = id
        case let .failure(error):
            transition(to: .failed(error))
            return
        }
        aggregateDevice = aggregate

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // The device must be bound before any connection is made or format
        // is read: `inputFormat(forBus:)` describes whichever device the unit
        // is bound to at that moment, and the engine builds the graph from it.
        guard let unit = input.audioUnit else {
            tearDown()
            transition(to: .failed(.engineFailed("input node has no audio unit")))
            return
        }
        var deviceID = aggregate
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else {
            tearDown()
            transition(to: .failed(.engineFailed("could not bind aggregate device (\(status))")))
            return
        }
        let format = input.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            tearDown()
            transition(to: .failed(.inputDeviceUnavailable))
            return
        }
        engine.connect(input, to: engine.mainMixerNode, format: format)
        // The tap block is invoked serially, so the throttle needs no lock.
        var throttle = LevelThrottle(interval: Self.levelInterval, epsilon: Self.levelEpsilon)
        input.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: nil) { [weak self] buffer, _ in
            guard let self, let sample = Self.level(of: buffer),
                  let level = throttle.consume(sample, at: ProcessInfo.processInfo.systemUptime) else { return }
            DispatchQueue.main.async {
                guard self.generation == session, case .running = self.state else { return }
                self.onLevel?(level)
            }
        }
        self.engine = engine

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.generation == session, self.engine?.isRunning == false else { return }
            self.scheduleRestart(session: session)
        }
        addListener(HAL.systemObject, HAL.address(kAudioHardwarePropertyDefaultOutputDevice), session: session)
        addListener(HAL.systemObject, HAL.address(kAudioHardwarePropertyDevices), session: session)

        engine.prepare()
        do {
            try engine.start()
        } catch {
            tearDown()
            transition(to: .failed(.engineFailed(error.localizedDescription)))
            return
        }
        transition(to: .running(outputDeviceName: HAL.readString(output, kAudioObjectPropertyName)))
    }

    private func addListener(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress, session: Int) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.generation == session else { return }
            self.scheduleRestart(session: session)
        }
        var address = address
        guard AudioObjectAddPropertyListenerBlock(objectID, &address, DispatchQueue.main, block) == noErr else { return }
        listeners.append(Listener(objectID: objectID, address: address, block: block))
    }

    /// Coalesces the restart triggers (they tend to arrive together) into
    /// one restart per main-queue turn.
    private func scheduleRestart(session: Int) {
        guard !restartScheduled else { return }
        restartScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restartScheduled = false
            guard self.generation == session, case .running = self.state else { return }
            self.tearDown()
            self.generation += 1
            self.transition(to: .starting)
            self.prepareInputDevice(session: self.generation)
        }
    }

    private func tearDown() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.objectID, &address, DispatchQueue.main, listener.block)
        }
        listeners.removeAll()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        if let aggregateDevice {
            AudioHardwareDestroyAggregateDevice(aggregateDevice)
            self.aggregateDevice = nil
        }
    }

    private func transition(to newState: MicrophoneMonitorState) {
        state = newState
        onStateChanged?(newState)
    }

    /// Normalized level of channel 0; for an interleaved buffer the RMS is
    /// taken over all channels together, which is close enough for a meter.
    static func level(of buffer: AVAudioPCMBuffer) -> Float? {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let count = buffer.format.isInterleaved
            ? Int(buffer.frameLength) * Int(buffer.format.channelCount)
            : Int(buffer.frameLength)
        let samples = UnsafeBufferPointer(start: channels[0], count: count)
        return AudioLevelMeter.normalizedLevel(rms: AudioLevelMeter.rootMeanSquare(samples))
    }
}

// MARK: - Aggregate device

private extension AVAudioEngineMicrophoneMonitor {
    /// A private (invisible to other processes) aggregate of `input` and
    /// `output`, clocked by `output` with drift compensation on `input`.
    static func createAggregateDevice(input: AudioObjectID, output: AudioObjectID) -> Result<AudioObjectID, MicrophoneMonitorError> {
        guard let inputUID = HAL.readString(input, kAudioDevicePropertyDeviceUID) else {
            return .failure(.inputDeviceUnavailable)
        }
        guard let outputUID = HAL.readString(output, kAudioDevicePropertyDeviceUID) else {
            return .failure(.engineFailed("default output device has no UID"))
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: aggregateDeviceName,
            kAudioAggregateDeviceUIDKey: "dev.alavreniuk.macmic.mictest.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: inputUID, kAudioSubDeviceDriftCompensationKey: 1],
                [kAudioSubDeviceUIDKey: outputUID],
            ],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr, aggregate != kAudioObjectUnknown else {
            return .failure(.engineFailed("could not create aggregate device (\(status))"))
        }
        return .success(aggregate)
    }
}

// MARK: - Level throttle

/// Decimates per-buffer levels to a delivery rate: at most one value per
/// `interval`, carrying the peak of the buffers since the last delivery
/// (so a short burst between deliveries still shows), and nothing while
/// that peak is within `epsilon` of the last delivered value. Pure, so the
/// rate policy is unit-testable without an engine.
struct LevelThrottle {
    let interval: TimeInterval
    let epsilon: Float
    private var peak: Float = 0
    private var lastDelivered: Float?
    private var lastDeliveryTime: TimeInterval = -.infinity

    init(interval: TimeInterval, epsilon: Float) {
        self.interval = interval
        self.epsilon = epsilon
    }

    /// Feeds one buffer's level; returns the value to deliver, or `nil`.
    mutating func consume(_ level: Float, at time: TimeInterval) -> Float? {
        peak = max(peak, level)
        guard time - lastDeliveryTime >= interval else { return nil }
        let value = peak
        peak = 0
        if let lastDelivered, abs(value - lastDelivered) < epsilon { return nil }
        lastDelivered = value
        lastDeliveryTime = time
        return value
    }
}
