import XCTest
import CoreGraphics
@testable import VPadProtocol

final class PressureCurveTests: XCTestCase {

    func testEndpointsFixedAtZeroAndOne() {
        for preset in PressureCurveConfiguration.Preset.allCases {
            let curve = PressureCurveConfiguration(preset: preset)

            XCTAssertEqual(curve.apply(0.0), 0.0)
            XCTAssertEqual(curve.apply(1.0), 1.0)
            XCTAssertEqual(curve.apply(-0.5), 0.0)
            XCTAssertEqual(curve.apply(1.5), 1.0)

            XCTAssertEqual(curve.lookupTable[0], 0.0)
            XCTAssertEqual(curve.lookupTable[255], 1.0)

            XCTAssertEqual(curve.applyInterpolated(0.0), 0.0)
            XCTAssertEqual(curve.applyInterpolated(1.0), 1.0)
            XCTAssertEqual(curve.applyInterpolated(-1.0), 0.0)
            XCTAssertEqual(curve.applyInterpolated(2.0), 1.0)
        }
    }

    func testMonotonicOutputAcrossAllPresets() {
        for preset in PressureCurveConfiguration.Preset.allCases {
            let curve = PressureCurveConfiguration(preset: preset)

            // 1. Check lookup table monotonicity
            for i in 1..<256 {
                XCTAssertGreaterThanOrEqual(
                    curve.lookupTable[i],
                    curve.lookupTable[i - 1],
                    "LUT failure at index \(i) for preset \(preset)"
                )
            }

            // 2. Check continuous interpolated monotonicity across 500 samples
            var previous: Float32 = 0.0
            for step in 0...500 {
                let x = Float32(step) / 500.0
                let y = curve.applyInterpolated(x)
                XCTAssertGreaterThanOrEqual(y, previous, "Monotonic failure at x=\(x) for preset \(preset)")
                XCTAssertGreaterThanOrEqual(y, 0.0)
                XCTAssertLessThanOrEqual(y, 1.0)
                previous = y
            }
        }
    }

    func testNaturalPresetIsLinearIdentity() {
        let curve = PressureCurveConfiguration(preset: .natural)
        for i in 0...10 {
            let x = Float32(i) / 10.0
            let y = curve.apply(x)
            XCTAssertEqual(y, x, accuracy: 0.03)
        }
    }

    func testSoftPresetIsMoreSensitiveThanNatural() {
        let natural = PressureCurveConfiguration(preset: .natural)
        let soft = PressureCurveConfiguration(preset: .soft)

        // At light-to-mid pressure (e.g. 0.25 and 0.5), soft should give higher response
        XCTAssertGreaterThan(soft.apply(0.25), natural.apply(0.25))
        XCTAssertGreaterThan(soft.apply(0.50), natural.apply(0.50))
    }

    func testHardPresetIsMoreControlledThanNatural() {
        let natural = PressureCurveConfiguration(preset: .natural)
        let hard = PressureCurveConfiguration(preset: .hard)

        // At light-to-mid pressure, hard should require more force (lower response)
        XCTAssertLessThan(hard.apply(0.25), natural.apply(0.25))
        XCTAssertLessThan(hard.apply(0.50), natural.apply(0.50))
    }

    func testExtremeControlPointsRemainMonotonicAndBounded() {
        var curve = PressureCurveConfiguration(preset: .custom)
        curve.updateControlPoints(
            p1: CGPoint(x: 0.0, y: 1.0), // High steep rise
            p2: CGPoint(x: 1.0, y: 0.0)
        )

        XCTAssertEqual(curve.apply(0.0), 0.0)
        XCTAssertEqual(curve.apply(1.0), 1.0)

        for i in 1..<256 {
            XCTAssertGreaterThanOrEqual(curve.lookupTable[i], curve.lookupTable[i - 1])
            XCTAssertGreaterThanOrEqual(curve.lookupTable[i], 0.0)
            XCTAssertLessThanOrEqual(curve.lookupTable[i], 1.0)
        }
    }

    func testCodableRoundTrip() throws {
        let original = PressureCurveConfiguration(
            preset: .custom,
            controlPoint1: CGPoint(x: 0.22, y: 0.55),
            controlPoint2: CGPoint(x: 0.44, y: 0.88)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PressureCurveConfiguration.self, from: data)

        XCTAssertEqual(original.preset, decoded.preset)
        XCTAssertEqual(original.controlPoint1.x, decoded.controlPoint1.x, accuracy: 0.001)
        XCTAssertEqual(original.controlPoint1.y, decoded.controlPoint1.y, accuracy: 0.001)
        XCTAssertEqual(original.controlPoint2.x, decoded.controlPoint2.x, accuracy: 0.001)
        XCTAssertEqual(original.controlPoint2.y, decoded.controlPoint2.y, accuracy: 0.001)
        XCTAssertEqual(original.lookupTable, decoded.lookupTable)
    }
}
