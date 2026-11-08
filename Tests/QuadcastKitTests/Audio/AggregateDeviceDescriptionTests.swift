// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import CoreAudio
import Testing
@testable import QuadcastKit

struct AggregateDeviceDescriptionTests {
    private static func subDevices(_ description: [String: Any]) -> [[String: Any]] {
        description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] ?? []
    }

    @Test func separateDevicesEachContributeOneDirection() {
        let description = AVAudioEngineMicrophoneEngine.aggregateDescription(
            inputUID: "mic", outputUID: "headphones", aggregateUID: "agg"
        )
        let subDevices = Self.subDevices(description)

        #expect(subDevices.count == 2)
        #expect(subDevices.first?[kAudioSubDeviceUIDKey] as? String == "mic")
        #expect(subDevices.first?[kAudioSubDeviceOutputChannelsKey] as? Int == 0)
        #expect(subDevices.first?[kAudioSubDeviceDriftCompensationKey] as? Int == 1)
        #expect(subDevices.last?[kAudioSubDeviceUIDKey] as? String == "headphones")
        #expect(subDevices.last?[kAudioSubDeviceInputChannelsKey] as? Int == 0)
        #expect(description[kAudioAggregateDeviceMainSubDeviceKey] as? String == "headphones")
        #expect(description[kAudioAggregateDeviceIsPrivateKey] as? Int == 1)
    }

    @Test func aMicThatIsAlsoTheOutputJoinsOnceWithBothDirections() {
        let description = AVAudioEngineMicrophoneEngine.aggregateDescription(
            inputUID: "quadcast2", outputUID: "quadcast2", aggregateUID: "agg"
        )
        let subDevices = Self.subDevices(description)

        #expect(subDevices.count == 1)
        #expect(subDevices.first?[kAudioSubDeviceUIDKey] as? String == "quadcast2")
        #expect(subDevices.first?[kAudioSubDeviceInputChannelsKey] == nil)
        #expect(subDevices.first?[kAudioSubDeviceOutputChannelsKey] == nil)
        #expect(description[kAudioAggregateDeviceMainSubDeviceKey] as? String == "quadcast2")
    }
}
