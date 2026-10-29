import XCTest
import CoreGraphics
@testable import VPadProtocol

final class AreaMappingTests: XCTestCase {

    func testIdentityMappingOnSingleDisplay() {
        let config = AreaMappingConfiguration()
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let topLeft = config.map(normalizedX: 0.0, normalizedY: 0.0, displayBounds: display)
        XCTAssertEqual(topLeft.x, 0.0, accuracy: 0.5)
        XCTAssertEqual(topLeft.y, 0.0, accuracy: 0.5)

        let bottomRight = config.map(normalizedX: 1.0, normalizedY: 1.0, displayBounds: display)
        XCTAssertEqual(bottomRight.x, 1919.0, accuracy: 0.5)
        XCTAssertEqual(bottomRight.y, 1079.0, accuracy: 0.5)

        let center = config.map(normalizedX: 0.5, normalizedY: 0.5, displayBounds: display)
        XCTAssertEqual(center.x, 959.5, accuracy: 0.5)
        XCTAssertEqual(center.y, 539.5, accuracy: 0.5)
    }

    func testMultipleDisplaysMapping() {
        let config = AreaMappingConfiguration()

        // Display 2 to the right
        let rightDisplay = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let rightPoint = config.map(normalizedX: 0.5, normalizedY: 0.5, displayBounds: rightDisplay)
        XCTAssertEqual(rightPoint.x, 1920.0 + 1279.5, accuracy: 0.5)
        XCTAssertEqual(rightPoint.y, 719.5, accuracy: 0.5)

        // Display 3 to the left (negative coordinates)
        let leftDisplay = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let leftOrigin = config.map(normalizedX: 0.0, normalizedY: 0.0, displayBounds: leftDisplay)
        XCTAssertEqual(leftOrigin.x, -1920.0, accuracy: 0.5)
        XCTAssertEqual(leftOrigin.y, 0.0, accuracy: 0.5)

        let leftMax = config.map(normalizedX: 1.0, normalizedY: 1.0, displayBounds: leftDisplay)
        XCTAssertEqual(leftMax.x, -1.0, accuracy: 0.5)
        XCTAssertEqual(leftMax.y, 1079.0, accuracy: 0.5)
    }

    func testRotationMath() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 1000)

        // 90 degrees clockwise
        let cfg90 = AreaMappingConfiguration(rotation: .rotation90)
        // (0,0) in 90 deg -> rotX = 1 - 0 = 1, rotY = 0 -> maps to (999, 0)
        let p90 = cfg90.map(normalizedX: 0.0, normalizedY: 0.0, displayBounds: display)
        XCTAssertEqual(p90.x, 999.0, accuracy: 0.5)
        XCTAssertEqual(p90.y, 0.0, accuracy: 0.5)

        // 180 degrees
        let cfg180 = AreaMappingConfiguration(rotation: .rotation180)
        // (0,0) -> rotX = 1, rotY = 1 -> maps to (999, 999)
        let p180 = cfg180.map(normalizedX: 0.0, normalizedY: 0.0, displayBounds: display)
        XCTAssertEqual(p180.x, 999.0, accuracy: 0.5)
        XCTAssertEqual(p180.y, 999.0, accuracy: 0.5)

        // 270 degrees
        let cfg270 = AreaMappingConfiguration(rotation: .rotation270)
        // (0,0) -> rotX = 0, rotY = 1 -> maps to (0, 999)
        let p270 = cfg270.map(normalizedX: 0.0, normalizedY: 0.0, displayBounds: display)
        XCTAssertEqual(p270.x, 0.0, accuracy: 0.5)
        XCTAssertEqual(p270.y, 999.0, accuracy: 0.5)
    }

    func testLeftHandedMode() {
        let display = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let cfg = AreaMappingConfiguration(isLeftHanded: true)

        let p = cfg.map(normalizedX: 0.0, normalizedY: 0.0, displayBounds: display)
        XCTAssertEqual(p.x, 999.0, accuracy: 0.5)
        XCTAssertEqual(p.y, 999.0, accuracy: 0.5)
    }

    func testAspectRatioLockLetterboxing() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080) // 16:9 = 1.777
        let cfg = AreaMappingConfiguration(lockAspectRatio: true, tabletAspectRatio: 4.0 / 3.0) // 1.333

        // Expected target width = 1080 * (4/3) = 1440
        // Expected target height = 1080
        // Offset X = (1920 - 1440) / 2 = 240
        let origin = cfg.map(normalizedX: 0.0, normalizedY: 0.0, displayBounds: display)
        XCTAssertEqual(origin.x, 240.0, accuracy: 0.5)
        XCTAssertEqual(origin.y, 0.0, accuracy: 0.5)

        let farRight = cfg.map(normalizedX: 1.0, normalizedY: 1.0, displayBounds: display)
        XCTAssertEqual(farRight.x, 240.0 + 1439.0, accuracy: 0.5)
        XCTAssertEqual(farRight.y, 1079.0, accuracy: 0.5)

        let center = cfg.map(normalizedX: 0.5, normalizedY: 0.5, displayBounds: display)
        XCTAssertEqual(center.x, 959.5, accuracy: 0.5)
        XCTAssertEqual(center.y, 539.5, accuracy: 0.5)
    }

    func testCustomSubregionMapping() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let custom = MappingRegion(x: 100, y: 100, width: 800, height: 600)
        let cfg = AreaMappingConfiguration(customRegion: custom)

        let origin = cfg.map(normalizedX: 0.0, normalizedY: 0.0, displayBounds: display)
        XCTAssertEqual(origin.x, 100.0, accuracy: 0.5)
        XCTAssertEqual(origin.y, 100.0, accuracy: 0.5)

        let end = cfg.map(normalizedX: 1.0, normalizedY: 1.0, displayBounds: display)
        XCTAssertEqual(end.x, 899.0, accuracy: 0.5)
        XCTAssertEqual(end.y, 699.0, accuracy: 0.5)
    }

    func testCodableRoundTrip() throws {
        let original = AreaMappingConfiguration(
            targetDisplayID: 12345,
            customRegion: MappingRegion(x: 50, y: 60, width: 700, height: 800),
            lockAspectRatio: true,
            tabletAspectRatio: 1.43,
            rotation: .rotation90,
            isLeftHanded: true
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AreaMappingConfiguration.self, from: data)
        XCTAssertEqual(original, decoded)
    }
}
