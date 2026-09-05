// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import AVFoundation
import Foundation
import Testing
@testable import QuadcastKit

@Suite struct ClipRecorderTests {
    private static let stereo = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private static let interleavedStereo = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true
    )!

    /// A buffer of `frames` frames whose channel `c` sample `i` is `base + c * 1000 + i`.
    private static func buffer(_ format: AVAudioFormat, frames: Int, base: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = Int(format.channelCount)
        for channel in 0..<channels {
            for frame in 0..<frames {
                let value = base + Float(channel * 1000 + frame)
                if format.isInterleaved {
                    buffer.floatChannelData![0][frame * channels + channel] = value
                } else {
                    buffer.floatChannelData![channel][frame] = value
                }
            }
        }
        return buffer
    }

    private static func sample(_ buffer: AVAudioPCMBuffer, channel: Int, frame: Int) -> Float {
        let channels = Int(buffer.format.channelCount)
        return buffer.format.isInterleaved
            ? buffer.floatChannelData![0][frame * channels + channel]
            : buffer.floatChannelData![channel][frame]
    }

    @Test func appendCopiesEveryChannelAndAdvancesFrameLength() {
        let clip = AVAudioPCMBuffer(pcmFormat: Self.stereo, frameCapacity: 100)!

        #expect(ClipRecorder.append(Self.buffer(Self.stereo, frames: 30, base: 0), to: clip) == 30)
        #expect(ClipRecorder.append(Self.buffer(Self.stereo, frames: 30, base: 5000), to: clip) == 30)

        #expect(clip.frameLength == 60)
        #expect(Self.sample(clip, channel: 0, frame: 0) == 0)
        #expect(Self.sample(clip, channel: 1, frame: 29) == 1029)
        #expect(Self.sample(clip, channel: 0, frame: 30) == 5000)
        #expect(Self.sample(clip, channel: 1, frame: 59) == 6029)
    }

    @Test func appendStopsAtCapacityInsteadOfRollingOver() {
        let clip = AVAudioPCMBuffer(pcmFormat: Self.stereo, frameCapacity: 100)!

        #expect(ClipRecorder.append(Self.buffer(Self.stereo, frames: 60, base: 0), to: clip) == 60)
        #expect(ClipRecorder.append(Self.buffer(Self.stereo, frames: 60, base: 5000), to: clip) == 40)
        #expect(ClipRecorder.append(Self.buffer(Self.stereo, frames: 60, base: 9000), to: clip) == 0)

        #expect(clip.frameLength == 100)
        #expect(Self.sample(clip, channel: 0, frame: 0) == 0)
        #expect(Self.sample(clip, channel: 1, frame: 99) == 6039)
    }

    @Test func appendHandlesInterleavedBuffers() {
        let clip = AVAudioPCMBuffer(pcmFormat: Self.interleavedStereo, frameCapacity: 10)!

        #expect(ClipRecorder.append(Self.buffer(Self.interleavedStereo, frames: 4, base: 0), to: clip) == 4)
        #expect(ClipRecorder.append(Self.buffer(Self.interleavedStereo, frames: 4, base: 100), to: clip) == 4)

        #expect(clip.frameLength == 8)
        #expect(Self.sample(clip, channel: 1, frame: 3) == 1003)
        #expect(Self.sample(clip, channel: 0, frame: 4) == 100)
        #expect(Self.sample(clip, channel: 1, frame: 7) == 1103)
    }

    @Test func appendRefusesAMismatchedLayout() {
        let clip = AVAudioPCMBuffer(pcmFormat: Self.stereo, frameCapacity: 10)!
        let mono = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

        #expect(ClipRecorder.append(Self.buffer(mono, frames: 4, base: 0), to: clip) == 0)
        #expect(ClipRecorder.append(Self.buffer(Self.interleavedStereo, frames: 4, base: 0), to: clip) == 0)
        #expect(clip.frameLength == 0)
    }

    @Test func recorderLifecycle() {
        let recorder = ClipRecorder()
        #expect(recorder.isRecording == false)
        #expect(recorder.elapsed == 0)
        #expect(recorder.append(Self.buffer(Self.stereo, frames: 10, base: 0)) == false)
        #expect(recorder.stop() == nil)

        #expect(recorder.start(format: Self.stereo, capacity: 48_000) == true)
        #expect(recorder.isRecording == true)
        #expect(recorder.append(Self.buffer(Self.stereo, frames: 24_000, base: 0)) == false)
        #expect(recorder.elapsed == 0.5)
        #expect(recorder.append(Self.buffer(Self.stereo, frames: 24_000, base: 0)) == true)
        #expect(recorder.elapsed == 1)

        let clip = recorder.stop()
        #expect(clip?.frameLength == 48_000)
        #expect(clip.map(ClipRecorder.duration(of:)) == 1)
        #expect(recorder.isRecording == false)
        #expect(recorder.elapsed == 0)
    }

    @Test func stopReturnsNilForAnEmptyRecording() {
        let recorder = ClipRecorder()
        #expect(recorder.start(format: Self.stereo, capacity: 100) == true)
        #expect(recorder.stop() == nil)
    }
}
