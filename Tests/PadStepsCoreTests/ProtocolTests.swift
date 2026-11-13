import Foundation
import Testing
@testable import PadStepsCore

private func bytes(_ hex: String) -> Data {
    Data(hex.split(separator: " ").map { UInt8($0, radix: 16)! })
}

@Test func queryMatchesPhysicalPad() {
    #expect(SperaxUART.statusQuery == bytes("f5 07 00 19 fa 59 fa"))
}

@Test func decodesCapturedIdlePacket() {
    var parser = UARTFrameDecoder()
    let frames = parser.append(bytes("f5 18 00 19 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 df 28 fa"))
    #expect(frames.count == 1)
    let telemetry = frames.first.flatMap(SperaxUART.telemetry)
    #expect(telemetry?.steps == 0)
    #expect(telemetry?.motion == .idle)
}

@Test func validatesEscapeLengthUsingPhysicalPadCapture() {
    var parser = UARTFrameDecoder()
    let frames = parser.append(bytes("f5 19 00 19 00 00 f0 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 c2 a4 fa"))
    #expect(frames.count == 1)
    #expect(frames.first?.count == 24)
    #expect(frames.first?[6] == 0xf0)
}

@Test func handlesSplitAndCoalescedNotifications() {
    var parser = UARTFrameDecoder()
    let packet = bytes("f5 18 00 19 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 df 28 fa")
    #expect(parser.append(Data([0x12, 0x13, 0x14]) + packet.prefix(9)).isEmpty)
    #expect(parser.append(packet.dropFirst(9) + packet).count == 2)
}

@Test func rejectsCorruptPacketThenRecovers() {
    var parser = UARTFrameDecoder()
    var packet = bytes("f5 18 00 19 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 df 28 fa")
    packet[16] = 40
    #expect(parser.append(packet).isEmpty)
    #expect(parser.rejectedFrames == 1)
    #expect(parser.append(bytes("f5 18 00 19 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 df 28 fa")).count == 1)
}

@Test func impossibleLengthDoesNotBlockTheStream() {
    var parser = UARTFrameDecoder()
    let packet = bytes("f5 18 00 19 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 df 28 fa")
    #expect(parser.append(Data([0xf5, 0xff]) + packet).count == 1)
}
