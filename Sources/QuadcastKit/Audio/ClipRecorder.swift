// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import AVFoundation
import Foundation

/// The clip `AVAudioEngineMicrophoneMonitor` captures: a fixed-capacity PCM
/// buffer the input tap appends to on Core Audio's I/O thread while
/// `start`/`stop`/`elapsed` are called on main. The lock is held for the
/// whole append (one tap buffer's memcpy), which is short enough for a
/// test-microphone feature; a lock-free ring would be the next step if
/// playback ever glitched under it.
///
/// Recording stops when the buffer is full rather than rolling over: the
/// user asked for "a part of me speaking", and a clip whose start silently
/// moves would make the level meter and the played-back audio disagree.
final class ClipRecorder {
    private let lock = NSLock()
    private var clip: AVAudioPCMBuffer?

    var isRecording: Bool {
        lock.withLock { clip != nil }
    }

    /// Seconds captured so far; `0` when not recording.
    var elapsed: TimeInterval {
        lock.withLock { clip.map(Self.duration(of:)) ?? 0 }
    }

    /// Begins a new clip in `format` holding up to `capacity` frames; `false`
    /// when the buffer cannot be allocated.
    func start(format: AVAudioFormat, capacity: AVAudioFrameCount) -> Bool {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return false }
        lock.withLock { clip = buffer }
        return true
    }

    /// Ends the recording and returns the clip, or `nil` when nothing was
    /// recorded (or no recording was in progress).
    func stop() -> AVAudioPCMBuffer? {
        lock.withLock {
            defer { clip = nil }
            guard let clip, clip.frameLength > 0 else { return nil }
            return clip
        }
    }

    /// I/O-thread entry: appends what fits. Returns `true` when the clip is
    /// full after this append, which is the caller's cue to stop recording.
    func append(_ buffer: AVAudioPCMBuffer) -> Bool {
        lock.withLock {
            guard let clip else { return false }
            _ = Self.append(buffer, to: clip)
            return clip.frameLength >= clip.frameCapacity
        }
    }

    /// Copies as many frames of `source` as fit in `destination`'s remaining
    /// capacity, advancing its `frameLength`; returns the number copied.
    /// Copies nothing when the layouts differ (channel count, interleaving,
    /// sample type), since a byte copy would then scramble the audio.
    @discardableResult
    static func append(_ source: AVAudioPCMBuffer, to destination: AVAudioPCMBuffer) -> AVAudioFrameCount {
        guard sameLayout(source.format, destination.format),
              let from = source.floatChannelData, let to = destination.floatChannelData else { return 0 }
        let frames = min(source.frameLength, destination.frameCapacity - destination.frameLength)
        guard frames > 0 else { return 0 }
        let channels = Int(source.format.channelCount)
        if source.format.isInterleaved {
            let offset = Int(destination.frameLength) * channels
            (to[0] + offset).update(from: from[0], count: Int(frames) * channels)
        } else {
            for channel in 0..<channels {
                (to[channel] + Int(destination.frameLength)).update(from: from[channel], count: Int(frames))
            }
        }
        destination.frameLength += frames
        return frames
    }

    /// Whether a frame of `a` and a frame of `b` have the same byte layout.
    /// `AVAudioFormat ==` also compares channel layouts, which a tap buffer
    /// may carry differently from the format the tap was installed with.
    static func sameLayout(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.channelCount == b.channelCount && a.isInterleaved == b.isInterleaved && a.commonFormat == b.commonFormat
    }

    static func duration(of clip: AVAudioPCMBuffer) -> TimeInterval {
        TimeInterval(clip.frameLength) / clip.format.sampleRate
    }
}
