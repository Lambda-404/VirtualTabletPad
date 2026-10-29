import XCTest
@testable import VPadProtocol

final class ProfileTests: XCTestCase {

    func testProfileStoreDefaultProfiles() {
        let store = ProfileStore()
        XCTAssertEqual(store.profiles.count, 4)

        let ps = store.profile(for: "com.adobe.Photoshop")
        XCTAssertEqual(ps.name, "Adobe Photoshop")
        XCTAssertEqual(ps.pressureCurve.preset, .soft)
        XCTAssertTrue(ps.areaMapping.lockAspectRatio)

        let blender = store.profile(for: "org.blenderfoundation.blender")
        XCTAssertEqual(blender.name, "Blender")
        XCTAssertEqual(blender.pressureCurve.preset, .hard)

        let fallback = store.profile(for: "com.nonexistent.app")
        XCTAssertEqual(fallback.bundleIdentifier, "*")
        XCTAssertEqual(fallback.name, "Default")
    }

    func testProfileStoreMutation() {
        var store = ProfileStore()
        let fcp = Profile(
            bundleIdentifier: "com.apple.FinalCut",
            name: "Final Cut Pro",
            pressureCurve: PressureCurveConfiguration(preset: .hard),
            areaMapping: AreaMappingConfiguration(lockAspectRatio: false),
            shortcutLayout: [18, 19, 20]
        )
        store.setProfile(fcp)

        let retrieved = store.profile(for: "com.apple.FinalCut")
        XCTAssertEqual(retrieved.name, "Final Cut Pro")
        XCTAssertEqual(retrieved.shortcutLayout, [18, 19, 20])
    }

    func testProfileCodableRoundTrip() throws {
        let original = ProfileStore()
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProfileStore.self, from: encoded)

        XCTAssertEqual(original, decoded)
    }

    func testActiveApplicationFrameCodec() throws {
        let bundleID = "org.krita"
        let frame = VPadFrameCodec.encode(type: .activeApplication, body: Data(bundleID.utf8))

        var decoder = VPadFrameDecoder()
        let payloads = try decoder.append(frame)
        XCTAssertEqual(payloads.count, 1)

        let parsed = try VPadFrameCodec.parse(payload: payloads[0])
        XCTAssertEqual(parsed.type, .activeApplication)
        let receivedID = String(data: parsed.body, encoding: .utf8)
        XCTAssertEqual(receivedID, bundleID)
    }
}
