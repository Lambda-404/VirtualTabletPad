import XCTest
@testable import VPadProtocol

final class VPadPacketTests: XCTestCase {
    func testLayoutIsFrozenAt28Bytes() {
        XCTAssertEqual(MemoryLayout<VPadPacket>.size, 28)
        XCTAssertEqual(MemoryLayout<VPadPacket>.stride, 28)
        XCTAssertEqual(MemoryLayout<VPadPacket>.alignment, 4)
    }

    func testFieldOffsetsAreLittleEndian() throws {
        let packet = VPadPacket.stylusStroke(
            x: 0.25,
            y: 0.5,
            pressure: 0.75,
            tiltX: -0.5,
            tiltY: 0.125,
            rollAngle: 1.0,
            phase: .moved,
            modifiers: 0x0003
        )
        let data = packet.toData()
        XCTAssertEqual(data.count, 28)
        XCTAssertEqual(data[0], EventType.stylusStroke.rawValue)
        XCTAssertEqual(data[1], Phase.moved.rawValue)
        XCTAssertEqual(data[2], 0x03)
        XCTAssertEqual(data[3], 0x00)
        XCTAssertEqual(readFloat(data, at: 4), 0.25)
        XCTAssertEqual(readFloat(data, at: 8), 0.5)
        XCTAssertEqual(readFloat(data, at: 12), 0.75)
        XCTAssertEqual(readFloat(data, at: 16), -0.5)
        XCTAssertEqual(readFloat(data, at: 20), 0.125)
        XCTAssertEqual(readFloat(data, at: 24), 1.0)
    }

    func testRoundTrip() {
        let packet = VPadPacket.trackpadScroll(dx: -12.5, dy: 33.25, modifiers: 0x0002)
        let decoded = VPadPacket.fromData(packet.toData())
        XCTAssertEqual(decoded, packet)
    }

    func testFromDataRejectsWrongLength() {
        XCTAssertNil(VPadPacket.fromData(Data()))
        XCTAssertNil(VPadPacket.fromData(Data(repeating: 0, count: 27)))
        XCTAssertNil(VPadPacket.fromData(Data(repeating: 0, count: 29)))
        XCTAssertNotNil(VPadPacket.fromData(Data(repeating: 0, count: 28)))
    }

    func testTrackpadClickUsesPressureSentinel() {
        let left = VPadPacket.trackpadClick(button: .left, phase: .began)
        XCTAssertEqual(left.type, EventType.trackpadClick.rawValue)
        XCTAssertEqual(left.phase, Phase.began.rawValue)
        XCTAssertEqual(left.pressure, 1.0)

        let right = VPadPacket.trackpadClick(button: .right, phase: .ended)
        XCTAssertEqual(right.pressure, 2.0)
        XCTAssertEqual(right.phase, Phase.ended.rawValue)
    }

    func testKeyboardKeycodeLivesInRollAngle() {
        let down = VPadPacket.keyboardPress(keyCode: 14, phase: .began, modifiers: 0x0001)
        XCTAssertEqual(down.type, EventType.keyboardPress.rawValue)
        XCTAssertEqual(down.phase, Phase.began.rawValue)
        XCTAssertEqual(down.rollAngle, 14)
        XCTAssertEqual(down.modifiers, 0x0001)

        let shortcut = VPadPacket.keyShortcut(keyCode: 6, modifiers: 0x0001)
        XCTAssertEqual(shortcut.type, EventType.keyShortcut.rawValue)
        XCTAssertEqual(shortcut.rollAngle, 6)
        XCTAssertEqual(shortcut.phase, Phase.began.rawValue)
    }

    func testGestureIDLivesInModifiers() {
        let gesture = VPadPacket.customGesture(id: 3)
        XCTAssertEqual(gesture.type, EventType.customGesture.rawValue)
        XCTAssertEqual(gesture.modifiers, 3)
        XCTAssertEqual(gesture.phase, Phase.began.rawValue)
    }

    func testStylusFactoryClampsValues() {
        let packet = VPadPacket.stylusStroke(
            x: 2,
            y: -1,
            pressure: 5,
            tiltX: -4,
            tiltY: 9,
            rollAngle: 10,
            phase: .began
        )
        XCTAssertEqual(packet.x, 1)
        XCTAssertEqual(packet.y, 0)
        XCTAssertEqual(packet.pressure, 1)
        XCTAssertEqual(packet.tiltX, -1)
        XCTAssertEqual(packet.tiltY, 1)
        XCTAssertEqual(packet.rollAngle, Float32.pi)
    }

    func testProximityAndDoubleTapFactories() {
        let enter = VPadPacket.stylusProximity(phase: .began)
        XCTAssertEqual(enter.type, EventType.stylusProximity.rawValue)
        XCTAssertEqual(enter.phase, Phase.began.rawValue)

        let leave = VPadPacket.stylusProximity(phase: .ended)
        XCTAssertEqual(leave.phase, Phase.ended.rawValue)

        let tap = VPadPacket.stylusDoubleTap()
        XCTAssertEqual(tap.type, EventType.stylusDoubleTap.rawValue)
        XCTAssertEqual(tap.phase, Phase.began.rawValue)
    }

    // MARK: - Helpers

    private func readFloat(_ data: Data, at offset: Int) -> Float32 {
        let bits = data.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        }
        return Float32(bitPattern: UInt32(littleEndian: bits))
    }
}
