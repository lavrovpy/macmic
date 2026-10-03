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

/// `MicrophoneEngine` backed by `AVAudioEngine`, routing a Core Audio input
/// device to the system default output through a private aggregate device.
/// Hardware-only; exercised via `macmic-cli audio test`.
///
/// The aggregate is not optional: on macOS `inputNode` and `outputNode`
/// share one HAL I/O unit, so binding that unit to the mic (an input-only
/// device) with `kAudioOutputUnitProperty_CurrentDevice` also moves the
/// output there and `start()` fails with `kAudioUnitErr_FailedInitialization`
/// (-10875). AVAudioEngine itself runs on a private aggregate of the default
/// input and output for the same reason; this class builds the equivalent
/// for mic + default output, with the output as clock master and drift
/// compensation on the mic, and with each sub-device's other direction
/// left out (see `createAggregateDevice`). The aggregate is destroyed on
/// every `stop()`.
///
/// `prepare` pins the mic's nominal sample rate to the output's when the mic
/// supports that rate, and deliberately leaves it pinned afterwards: with
/// the mic at another rate (Teams parks the QuadCast at 16 kHz) the HAL
/// resamples it inside the aggregate and restarts the aggregate's I/O a few
/// seconds in, which AVAudioEngine turns into a configuration change and a
/// stall — observed on macOS 15.7 with the mic at 16 kHz and the output at
/// 48 kHz; pinned to 48 kHz it ran clean.
///
/// Record/playback reuse the running graph: the input tap appends to a
/// `ClipRecorder` while recording, and an `AVAudioPlayerNode` attached to
/// the same engine plays the clip into the main mixer (so it reaches the
/// same output as the pass-through) with `inputNode.volume` at 0 meanwhile.
final class AVAudioEngineMicrophoneEngine: MicrophoneEngine {
    static let tapBufferSize: AVAudioFrameCount = 1024
    /// The tap fires per buffer (~47 Hz at 48 kHz); levels are decimated to
    /// this so a meter animating at ~80 ms isn't fed faster than it can
    /// draw, and not at all while the level is within `levelEpsilon` (0.5%
    /// of the bar) of what was last delivered.
    static let levelInterval: TimeInterval = 1.0 / 25
    static let levelEpsilon: Float = 0.005
    static let aggregateDeviceName = "MacMic Microphone Test"

    private let hal: SystemHAL
    private var engine: AVAudioEngine?
    private var aggregateDevice: AudioObjectID?
    private var configurationObserver: NSObjectProtocol?
    private var outputListener: HALListener?
    private var output: AudioObjectID?
    private var pinnedRate: Double?
    private var events: ((MicrophoneEngineEvent) -> Void)?

    private let recorder = ClipRecorder()
    /// The format the running engine's input tap delivers; clips are
    /// allocated in it.
    private var inputFormat: AVAudioFormat?
    private var clip: AVAudioPCMBuffer?
    private var player: AVAudioPlayerNode?
    /// The format `player` is currently connected to the mixer with.
    private var playerFormat: AVAudioFormat?
    private var isPlaying = false

    init(hal: SystemHAL = SystemHAL()) {
        self.hal = hal
    }

    deinit {
        stop()
    }

    // MARK: - Permission

    func microphoneAccess() -> MicrophoneAccess {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }

    // MARK: - Run lifecycle

    func prepare(input: AudioObjectID, events: @escaping (MicrophoneEngineEvent) -> Void) -> MicrophoneEnginePreparation {
        guard hal.isUsableInput(input) else { return .failed(.inputDeviceUnavailable) }
        guard let output = hal.defaultOutputDevice() else { return .failed(.engineFailed("no default output device")) }
        self.output = output
        self.events = events
        // The aggregate names a specific output, so the engine can't notice
        // the default output changing by itself.
        outputListener = try? hal.addListener(
            HAL.systemObject, HAL.address(kAudioHardwarePropertyDefaultOutputDevice), queue: .main
        ) { events(.restartNeeded) }
        let outputRate = hal.nominalSampleRate(output)
        guard outputRate > 0, hal.nominalSampleRate(input) != outputRate,
              hal.availableSampleRates(input).contains(outputRate),
              hal.setNominalSampleRate(input, outputRate) else { return .ready }
        pinnedRate = outputRate
        return .settling
    }

    func isSettled(input: AudioObjectID) -> Bool {
        pinnedRate.map { hal.nominalSampleRate(input) == $0 } ?? true
    }

    func start(input: AudioObjectID) -> Result<String?, MicrophoneTestError> {
        guard let output, let events else { return .failure(.engineFailed("start called before prepare")) }
        let aggregate: AudioObjectID
        switch createAggregateDevice(input: input, output: output) {
        case let .success(id):
            aggregate = id
        case let .failure(error):
            return .failure(error)
        }
        aggregateDevice = aggregate

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        // The device must be bound before any connection is made or format
        // is read: `inputFormat(forBus:)` describes whichever device the unit
        // is bound to at that moment, and the engine builds the graph from it.
        guard let unit = inputNode.audioUnit else {
            return .failure(.engineFailed("input node has no audio unit"))
        }
        var deviceID = aggregate
        let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)
        )
        guard status == noErr else {
            return .failure(.engineFailed("could not bind aggregate device (\(status))"))
        }
        let format = inputNode.inputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            return .failure(.inputDeviceUnavailable)
        }
        engine.connect(inputNode, to: engine.mainMixerNode, format: format)
        let player = AVAudioPlayerNode()
        engine.attach(player)
        inputNode.installTap(
            onBus: 0, bufferSize: Self.tapBufferSize, format: format,
            block: Self.inputTap(recorder: recorder, events: events)
        )
        self.engine = engine
        self.player = player
        inputFormat = format

        // Honoured only once the engine has really stopped: it also posts one,
        // with the engine still running, right after `start()`.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak engine] _ in
            guard engine?.isRunning == false else { return }
            events(.restartNeeded)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            return .failure(.engineFailed(error.localizedDescription))
        }
        return .success(hal.string(output, kAudioObjectPropertyName))
    }

    func stop() {
        if let outputListener {
            hal.removeListener(outputListener)
            self.outputListener = nil
        }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        stopPlayback()
        if recorder.isRecording {
            clip = recorder.stop()
        }
        player = nil
        playerFormat = nil
        inputFormat = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        if let aggregateDevice {
            AudioHardwareDestroyAggregateDevice(aggregateDevice)
            self.aggregateDevice = nil
        }
        output = nil
        pinnedRate = nil
        events = nil
    }

    // MARK: - Recording and playback

    func startRecording(maxDuration: TimeInterval, onFull: @escaping () -> Void) -> Bool {
        guard engine?.isRunning == true, let inputFormat else { return false }
        let capacity = AVAudioFrameCount(maxDuration * inputFormat.sampleRate)
        guard recorder.start(format: inputFormat, capacity: capacity, onFull: onFull) else { return false }
        clip = nil
        return true
    }

    func stopRecording() -> TimeInterval? {
        clip = recorder.stop()
        return clip.map(ClipRecorder.duration(of:))
    }

    var recordedDuration: TimeInterval {
        recorder.elapsed
    }

    func discardClip() {
        clip = nil
    }

    func startPlayback(onLevel: @escaping (Float) -> Void, onFinished: @escaping () -> Void) -> Bool {
        guard !isPlaying, let engine, engine.isRunning, let player, let clip else { return false }
        if playerFormat != clip.format {
            if playerFormat != nil {
                engine.disconnectNodeOutput(player)
            }
            engine.connect(player, to: engine.mainMixerNode, format: clip.format)
            playerFormat = clip.format
        }
        engine.inputNode.volume = 0
        player.installTap(onBus: 0, bufferSize: Self.tapBufferSize, format: nil, block: Self.playerTap(onLevel: onLevel))
        player.scheduleBuffer(
            clip, at: nil, options: [], completionCallbackType: .dataPlayedBack,
            completionHandler: Self.completion(onFinished)
        )
        player.play()
        isPlaying = true
        return true
    }

    func stopPlayback() {
        guard isPlaying else { return }
        isPlaying = false
        player?.removeTap(onBus: 0)
        player?.stop()
        engine?.inputNode.volume = 1
    }

    /// Seconds of the clip rendered so far, from the player's own clock.
    var playbackPosition: TimeInterval {
        guard let player, let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime), playerTime.sampleRate > 0 else { return 0 }
        return TimeInterval(playerTime.sampleTime) / playerTime.sampleRate
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

    // MARK: - I/O-thread closures
    //
    // Warning: these factories are `static` so the closures capture only
    // their arguments. They run on Core Audio's I/O thread; written as
    // instance code they would capture `self` and touch main-thread state
    // from there. Each hops to main before calling back.

    private static func inputTap(
        recorder: ClipRecorder, events: @escaping (MicrophoneEngineEvent) -> Void
    ) -> AVAudioNodeTapBlock {
        // The tap block is invoked serially, so the throttle needs no lock.
        var throttle = LevelThrottle(interval: levelInterval, epsilon: levelEpsilon)
        return { buffer, _ in
            if let onFull = recorder.append(buffer) {
                DispatchQueue.main.async { onFull() }
            }
            guard let sample = level(of: buffer),
                  let value = throttle.consume(sample, at: ProcessInfo.processInfo.systemUptime) else { return }
            DispatchQueue.main.async { events(.inputLevel(value)) }
        }
    }

    private static func playerTap(onLevel: @escaping (Float) -> Void) -> AVAudioNodeTapBlock {
        var throttle = LevelThrottle(interval: levelInterval, epsilon: levelEpsilon)
        return { buffer, _ in
            guard let sample = level(of: buffer),
                  let value = throttle.consume(sample, at: ProcessInfo.processInfo.systemUptime) else { return }
            DispatchQueue.main.async { onLevel(value) }
        }
    }

    private static func completion(_ onFinished: @escaping () -> Void) -> AVAudioPlayerNodeCompletionHandler {
        { _ in DispatchQueue.main.async { onFinished() } }
    }
}

// MARK: - Aggregate device

private extension AVAudioEngineMicrophoneEngine {
    /// A private (invisible to other processes) aggregate of `input` and
    /// `output`, clocked by `output` with drift compensation on `input`.
    ///
    /// Each sub-device contributes one direction only (the same composition
    /// AVAudioEngine uses for its own default-device aggregate). Without
    /// `channels-in = 0` the output device's own input streams join the
    /// aggregate and get run too; for AirPods that means their microphone,
    /// which drops the Bluetooth link into the hands-free profile at 24 kHz,
    /// changes the aggregate's format, and restarts the engine — which
    /// rebuilds the aggregate and starts the cycle again every ~1.5 s.
    func createAggregateDevice(input: AudioObjectID, output: AudioObjectID) -> Result<AudioObjectID, MicrophoneTestError> {
        guard let inputUID = hal.string(input, kAudioDevicePropertyDeviceUID) else {
            return .failure(.inputDeviceUnavailable)
        }
        guard let outputUID = hal.string(output, kAudioDevicePropertyDeviceUID) else {
            return .failure(.engineFailed("default output device has no UID"))
        }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.aggregateDeviceName,
            kAudioAggregateDeviceUIDKey: "dev.alavreniuk.macmic.mictest.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: inputUID, kAudioSubDeviceDriftCompensationKey: 1, kAudioSubDeviceOutputChannelsKey: 0],
                [kAudioSubDeviceUIDKey: outputUID, kAudioSubDeviceInputChannelsKey: 0],
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
