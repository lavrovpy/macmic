// MacMic - Native macOS RGB control for HyperX QuadCast S
// Copyright (C) 2026 Andrii Lavreniuk
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 2 of the License ONLY.
// See LICENSE for the full license text.

import Testing
@testable import QuadcastKit

@Suite struct IOUSBHostTransportControlRequestTests {
    @Test func matchesQuadcastRGBDevioConstants() {
        let request = IOUSBHostTransport.makeControlRequest(payloadLength: 64)
        #expect(request.bmRequestType == 0x21)
        #expect(request.bRequest == 0x09)
        #expect(request.wValue == 0x0300)
        #expect(request.wIndex == 0x0000)
        #expect(request.wLength == 64)
    }

    @Test func wLengthTracksPayloadLength() {
        #expect(IOUSBHostTransport.makeControlRequest(payloadLength: 0).wLength == 0)
        #expect(IOUSBHostTransport.makeControlRequest(payloadLength: 60).wLength == 60)
        #expect(IOUSBHostTransport.makeControlRequest(payloadLength: 64).wLength == 64)
    }

    @Test func vendorAndProductIDsMatchProtocolSpec() {
        #expect(IOUSBHostTransport.vendorID == 0x0951)
        #expect(IOUSBHostTransport.productIDs == [0x171f, 0x171d])
        #expect(IOUSBHostTransport.preferredProductID == 0x171f)
    }
}
