import CryptoKit
import XCTest
@testable import VPadProtocol

final class LatencyBenchmarkTests: XCTestCase {

    func testPingPongPacketRoundTripAndFieldExtraction() {
        let originalTs: UInt64 = 0xA1B2_C3D4_E5F6_0718
        let pingId: UInt16 = 31415

        let ping = VPadPacket.ping(timestamp: originalTs, id: pingId)
        XCTAssertEqual(ping.type, EventType.ping.rawValue)
        XCTAssertEqual(ping.pingTimestamp, originalTs)
        XCTAssertEqual(ping.pingId, pingId)
        XCTAssertFalse(ping.isStateEvent)

        let pingData = ping.toData()
        let decodedPing = VPadPacket.fromData(pingData)
        XCTAssertNotNil(decodedPing)
        XCTAssertEqual(decodedPing?.pingTimestamp, originalTs)
        XCTAssertEqual(decodedPing?.pingId, pingId)

        let hostTs: UInt64 = 0x9988_7766_5544_3322
        let pong = VPadPacket.pong(clientTimestamp: originalTs, hostTimestamp: hostTs, id: pingId)
        XCTAssertEqual(pong.type, EventType.pong.rawValue)
        XCTAssertEqual(pong.pingTimestamp, originalTs)
        XCTAssertEqual(pong.pongHostTimestamp, hostTs)
        XCTAssertEqual(pong.pingId, pingId)
        XCTAssertFalse(pong.isStateEvent)

        let pongData = pong.toData()
        let decodedPong = VPadPacket.fromData(pongData)
        XCTAssertNotNil(decodedPong)
        XCTAssertEqual(decodedPong?.pingTimestamp, originalTs)
        XCTAssertEqual(decodedPong?.pongHostTimestamp, hostTs)
        XCTAssertEqual(decodedPong?.pingId, pingId)
    }

    func testLatencyMetricsEmptyAndSingle() {
        let emptyMetrics = LatencyMetrics(samplesMs: [], totalSent: 10)
        XCTAssertEqual(emptyMetrics.count, 0)
        XCTAssertEqual(emptyMetrics.lostCount, 10)
        XCTAssertEqual(emptyMetrics.lossRate, 1.0)
        XCTAssertEqual(emptyMetrics.minMs, 0.0)
        XCTAssertEqual(emptyMetrics.maxMs, 0.0)
        XCTAssertEqual(emptyMetrics.p50Ms, 0.0)
        XCTAssertEqual(emptyMetrics.jitterMs, 0.0)

        let single = LatencyMetrics(samplesMs: [4.2], totalSent: 1)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single.lostCount, 0)
        XCTAssertEqual(single.lossRate, 0.0)
        XCTAssertEqual(single.minMs, 4.2)
        XCTAssertEqual(single.maxMs, 4.2)
        XCTAssertEqual(single.meanMs, 4.2)
        XCTAssertEqual(single.p50Ms, 4.2)
        XCTAssertEqual(single.p95Ms, 4.2)
        XCTAssertEqual(single.p99Ms, 4.2)
        XCTAssertEqual(single.stdDevMs, 0.0)
        XCTAssertEqual(single.jitterMs, 0.0)
    }

    func testLatencyMetricsPercentilesKnownDistribution() {
        // 101 samples: 0.0 to 100.0 with step 1.0
        let samples = (0...100).map { Double($0) }
        let metrics = LatencyMetrics(samplesMs: samples, totalSent: 101)

        XCTAssertEqual(metrics.count, 101)
        XCTAssertEqual(metrics.minMs, 0.0)
        XCTAssertEqual(metrics.maxMs, 100.0)
        XCTAssertEqual(metrics.meanMs, 50.0)
        XCTAssertEqual(metrics.p50Ms, 50.0)
        XCTAssertEqual(metrics.p95Ms, 95.0)
        XCTAssertEqual(metrics.p99Ms, 99.0)
    }

    func testRFC3550JitterCalculation() {
        // Samples with constant step: deltas are always equal -> jitter converges
        let samples: [Double] = [10.0, 12.0, 14.0, 16.0, 18.0] // differences are all 2.0
        let metrics = LatencyMetrics(samplesMs: samples, totalSent: 5)

        // After 4 iterations of j += (2 - j) / 16:
        // i=1: j = 2/16 = 0.125
        // i=2: j = 0.125 + (2 - 0.125)/16 = 0.2421875
        // i=3: j = 0.2421875 + (2 - 0.2421875)/16 = 0.35205078125
        // i=4: j = 0.35205078125 + (2 - 0.35205078125)/16 = 0.455047607421875
        XCTAssertEqual(metrics.jitterMs, 0.4550476, accuracy: 0.0001)
    }

    func testSimulatedUDPPingPongLoopback() throws {
        let key = SymmetricKey(size: .bits256)
        let hostSession = SessionCrypto(key: key)
        let clientSession = SessionCrypto(key: key, role: .client)

        // Client prepares ping
        let clientTs: UInt64 = 1_000_000
        let pingPacket = VPadPacket.ping(timestamp: clientTs, id: 1)
        guard let pingEnvelope = clientSession.sealUDP(pingPacket) else {
            XCTFail("Failed to seal ping")
            return
        }

        // Host receives and opens ping
        guard let hostReceivedPacket = hostSession.openUDP(pingEnvelope) else {
            XCTFail("Failed to open ping on host")
            return
        }
        XCTAssertEqual(hostReceivedPacket.type, EventType.ping.rawValue)
        XCTAssertEqual(hostReceivedPacket.pingTimestamp, clientTs)

        // Host creates pong and replies
        let hostTs: UInt64 = 1_000_500
        let pongPacket = VPadPacket.pong(clientTimestamp: clientTs, hostTimestamp: hostTs, id: hostReceivedPacket.pingId)
        guard let pongEnvelope = hostSession.sealUDP(pongPacket) else {
            XCTFail("Failed to seal pong")
            return
        }

        // Client receives and opens pong
        guard let clientReceivedPacket = clientSession.openUDP(pongEnvelope) else {
            XCTFail("Failed to open pong on client")
            return
        }
        XCTAssertEqual(clientReceivedPacket.type, EventType.pong.rawValue)
        XCTAssertEqual(clientReceivedPacket.pingTimestamp, clientTs)
        XCTAssertEqual(clientReceivedPacket.pongHostTimestamp, hostTs)
        XCTAssertEqual(clientReceivedPacket.pingId, 1)
    }
}
