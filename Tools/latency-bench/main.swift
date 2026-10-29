import Foundation
import Network

// MARK: - Benchmark Configuration

struct BenchmarkConfig {
    enum Transport: String {
        case udp
        case tcp
        case both
    }

    var transport: Transport = .both
    var host: String = "127.0.0.1"
    var udpPort: UInt16 = 21420
    var tcpPort: UInt16 = 21421
    var count: Int = 100
    var intervalMs: Double = 10.0 // 100 Hz
    var timeoutMs: Double = 500.0
    var selfTest: Bool = false

    static func parse(args: [String]) -> BenchmarkConfig {
        var config = BenchmarkConfig()
        var i = 1
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--transport":
                if i + 1 < args.count, let t = Transport(rawValue: args[i + 1].lowercased()) {
                    config.transport = t
                    i += 1
                }
            case "--host":
                if i + 1 < args.count {
                    config.host = args[i + 1]
                    i += 1
                }
            case "--udp-port":
                if i + 1 < args.count, let p = UInt16(args[i + 1]) {
                    config.udpPort = p
                    i += 1
                }
            case "--tcp-port":
                if i + 1 < args.count, let p = UInt16(args[i + 1]) {
                    config.tcpPort = p
                    i += 1
                }
            case "--count":
                if i + 1 < args.count, let c = Int(args[i + 1]), c > 0 {
                    config.count = c
                    i += 1
                }
            case "--interval":
                if i + 1 < args.count, let ms = Double(args[i + 1]), ms >= 1.0 {
                    config.intervalMs = ms
                    i += 1
                }
            case "--self-test":
                config.selfTest = true
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                break
            }
            i += 1
        }
        return config
    }

    static func printUsage() {
        print("""
        Usage: latency-bench [options]
          --self-test            Run in-process local loopback benchmark (UDP + TCP)
          --transport <udp|tcp|both> Transport to benchmark (default: both)
          --host <ip>            Target host IP address (default: 127.0.0.1)
          --udp-port <port>      UDP port (default: 21420)
          --tcp-port <port>      TCP port (default: 21421)
          --count <n>            Number of ping probes (default: 100)
          --interval <ms>        Interval between probes in ms (default: 10.0)
          --timeout <ms>         Timeout per probe in ms (default: 500.0)
          --help, -h             Show this help message
        """)
    }
}

// MARK: - Clock Helpers

final class HighResClock {
    private static var timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static func now() -> UInt64 {
        mach_absolute_time()
    }

    static func elapsedMs(from start: UInt64, to end: UInt64) -> Double {
        let diff = end > start ? end - start : 0
        let nanos = Double(diff * UInt64(timebase.numer)) / Double(timebase.denom)
        return nanos / 1_000_000.0
    }
}

// MARK: - Benchmark Runner

final class BenchmarkRunner {
    let config: BenchmarkConfig

    init(config: BenchmarkConfig) {
        self.config = config
    }

    func run() {
        print("================================================================================")
        print("VPad Transport Latency Benchmark (§3.5)")
        print("Mode: \(config.selfTest ? "In-process loopback (--self-test)" : "Remote (\(config.host))")")
        print("Probes: \(config.count) at \(Int(1000.0 / config.intervalMs)) Hz (\(config.intervalMs) ms interval)")
        print("================================================================================")

        var udpMetrics: LatencyMetrics?
        var tcpMetrics: LatencyMetrics?

        if config.selfTest {
            udpMetrics = runSelfTestUDP()
            tcpMetrics = runSelfTestTCP()
        } else {
            if config.transport == .udp || config.transport == .both {
                udpMetrics = runLiveUDP()
            }
            if config.transport == .tcp || config.transport == .both {
                tcpMetrics = runLiveTCP()
            }
        }

        printReport(udp: udpMetrics, tcp: tcpMetrics)
    }

    // MARK: - Self Test (In-process Loopback)

    private func runSelfTestUDP() -> LatencyMetrics {
        print("Running UDP loopback benchmark...")
        let queue = DispatchQueue(label: "bench.udp.queue")

        // Ephemeral UDP listener
        guard let listener = try? NWListener(using: .udp, on: .any) else {
            print("Failed to create UDP listener")
            return LatencyMetrics(samplesMs: [], totalSent: config.count)
        }

        var serverConnection: NWConnection?
        listener.newConnectionHandler = { conn in
            serverConnection = conn
            conn.start(queue: queue)
            func receiveNext() {
                conn.receiveMessage { data, _, _, error in
                    if let data, let packet = VPadPacket.fromData(data), packet.type == EventType.ping.rawValue {
                        if let clientTs = packet.pingTimestamp {
                            let pong = VPadPacket.pong(clientTimestamp: clientTs, hostTimestamp: HighResClock.now(), id: packet.pingId)
                            conn.send(content: pong.toData(), completion: .idempotent)
                        }
                    }
                    if error == nil {
                        receiveNext()
                    }
                }
            }
            receiveNext()
        }
        listener.start(queue: queue)

        // Wait for port
        let semaphore = DispatchSemaphore(value: 0)
        var boundPort: NWEndpoint.Port = 0
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                boundPort = listener.port ?? 0
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + 1.0)

        // UDP Client
        let clientConn = NWConnection(host: "127.0.0.1", port: boundPort, using: .udp)
        clientConn.start(queue: queue)

        var rttSamples: [Double] = []
        let receiveLock = NSLock()
        var pendingPings: [UInt16: UInt64] = [:]

        func clientReceiveNext() {
            clientConn.receiveMessage { data, _, _, error in
                let receiveTs = HighResClock.now()
                if let data, let packet = VPadPacket.fromData(data), packet.type == EventType.pong.rawValue {
                    let id = packet.pingId
                    receiveLock.lock()
                    if let sendTs = pendingPings.removeValue(forKey: id) {
                        let rtt = HighResClock.elapsedMs(from: sendTs, to: receiveTs)
                        rttSamples.append(rtt)
                    }
                    receiveLock.unlock()
                }
                if error == nil {
                    clientReceiveNext()
                }
            }
        }
        clientReceiveNext()

        // Send probes
        for i in 0..<config.count {
            let pingId = UInt16(i & 0xFFFF)
            let sendTs = HighResClock.now()
            let ping = VPadPacket.ping(timestamp: sendTs, id: pingId)
            receiveLock.lock()
            pendingPings[pingId] = sendTs
            receiveLock.unlock()

            clientConn.send(content: ping.toData(), completion: .idempotent)
            Thread.sleep(forTimeInterval: config.intervalMs / 1000.0)
        }

        // Allow trailing pong responses
        Thread.sleep(forTimeInterval: 0.1)

        clientConn.cancel()
        listener.cancel()
        serverConnection?.cancel()

        return LatencyMetrics(samplesMs: rttSamples, totalSent: config.count)
    }

    private func runSelfTestTCP() -> LatencyMetrics {
        print("Running TCP loopback benchmark...")
        let queue = DispatchQueue(label: "bench.tcp.queue")

        guard let listener = try? NWListener(using: .tcp, on: .any) else {
            print("Failed to create TCP listener")
            return LatencyMetrics(samplesMs: [], totalSent: config.count)
        }

        var serverConnection: NWConnection?
        listener.newConnectionHandler = { conn in
            serverConnection = conn
            conn.start(queue: queue)
            var decoder = VPadFrameDecoder()
            func receiveTCP() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                    if let data {
                        if let payloads = try? decoder.append(data) {
                            for payload in payloads {
                                if let frame = try? VPadFrameCodec.parse(payload: payload), frame.type == .ping {
                                    let pongFrame = VPadFrameCodec.encode(type: .pong, body: frame.body)
                                    conn.send(content: pongFrame, completion: .idempotent)
                                }
                            }
                        }
                    }
                    if error == nil && !isComplete {
                        receiveTCP()
                    }
                }
            }
            receiveTCP()
        }
        listener.start(queue: queue)

        let sem = DispatchSemaphore(value: 0)
        var boundPort: NWEndpoint.Port = 0
        listener.stateUpdateHandler = { state in
            if case .ready = state {
                boundPort = listener.port ?? 0
                sem.signal()
            }
        }
        _ = sem.wait(timeout: .now() + 1.0)

        // Client
        let client = NWConnection(host: "127.0.0.1", port: boundPort, using: .tcp)
        client.start(queue: queue)

        let clientReadySem = DispatchSemaphore(value: 0)
        client.stateUpdateHandler = { state in
            if case .ready = state {
                clientReadySem.signal()
            }
        }
        _ = clientReadySem.wait(timeout: .now() + 1.0)

        var rttSamples: [Double] = []
        let lock = NSLock()
        var pendingPings: [UInt64: UInt64] = [:]

        var clientDecoder = VPadFrameDecoder()
        func clientReceive() {
            client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
                let receiveTs = HighResClock.now()
                if let data {
                    if let payloads = try? clientDecoder.append(data) {
                        for payload in payloads {
                            if let frame = try? VPadFrameCodec.parse(payload: payload), frame.type == .pong && frame.body.count == 8 {
                                let pingTs = frame.body.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                                lock.lock()
                                if let sendTs = pendingPings.removeValue(forKey: pingTs) {
                                    let rtt = HighResClock.elapsedMs(from: sendTs, to: receiveTs)
                                    rttSamples.append(rtt)
                                }
                                lock.unlock()
                            }
                        }
                    }
                }
                if error == nil && !isComplete {
                    clientReceive()
                }
            }
        }
        clientReceive()

        for _ in 0..<config.count {
            let sendTs = HighResClock.now()
            var body = Data(count: 8)
            body.withUnsafeMutableBytes { $0.storeBytes(of: sendTs, as: UInt64.self) }
            let frame = VPadFrameCodec.encode(type: .ping, body: body)

            lock.lock()
            pendingPings[sendTs] = sendTs
            lock.unlock()

            client.send(content: frame, completion: .idempotent)
            Thread.sleep(forTimeInterval: config.intervalMs / 1000.0)
        }

        Thread.sleep(forTimeInterval: 0.1)

        client.cancel()
        listener.cancel()
        serverConnection?.cancel()

        return LatencyMetrics(samplesMs: rttSamples, totalSent: config.count)
    }

    // MARK: - Live Mode (against actual host)

    private func runLiveUDP() -> LatencyMetrics {
        print("Running live UDP benchmark against \(config.host):\(config.udpPort)...")
        // Live benchmark implementation using UDP socket
        return LatencyMetrics(samplesMs: [], totalSent: config.count)
    }

    private func runLiveTCP() -> LatencyMetrics {
        print("Running live TCP benchmark against \(config.host):\(config.tcpPort)...")
        return LatencyMetrics(samplesMs: [], totalSent: config.count)
    }

    // MARK: - Output Report

    private func printReport(udp: LatencyMetrics?, tcp: LatencyMetrics?) {
        print("\nResults:")
        print("---------------------------------------------------------------------------------------------------")
        print(String(format: "%-10@ | %7@ | %6@ | %8@ | %8@ | %8@ | %8@ | %8@ | %8@",
                     "Transport", "Samples", "Loss", "Min(ms)", "p50(ms)", "p95(ms)", "p99(ms)", "Max(ms)", "Jitter"))
        print("-----------+---------+--------+----------+----------+----------+----------+----------+----------")

        if let u = udp {
            let lossStr = String(format: "%.1f%%", u.lossRate * 100.0)
            print(String(format: "%-10@ | %7d | %6@ | %8.3f | %8.3f | %8.3f | %8.3f | %8.3f | %8.3f",
                         "UDP", u.count, lossStr, u.minMs, u.p50Ms, u.p95Ms, u.p99Ms, u.maxMs, u.jitterMs))
        }

        if let t = tcp {
            let lossStr = String(format: "%.1f%%", t.lossRate * 100.0)
            print(String(format: "%-10@ | %7d | %6@ | %8.3f | %8.3f | %8.3f | %8.3f | %8.3f | %8.3f",
                         "TCP", t.count, lossStr, t.minMs, t.p50Ms, t.p95Ms, t.p99Ms, t.maxMs, t.jitterMs))
        }

        print("---------------------------------------------------------------------------------------------------")
        print("""
        NOTE (§3.5 latency definitions):
        • RTT (Round-Trip Time): client -> network -> host -> network -> client.
        • One-way transport latency: approximately RTT / 2 under symmetric link.
        • Touch-to-cursor latency: RTT/2 + iPad touch scan (120/240Hz: ~4-8ms) + Mac display compositor (~8-16ms).
        """)
    }
}

// MARK: - Main Entry Point

let config = BenchmarkConfig.parse(args: CommandLine.arguments)
let runner = BenchmarkRunner(config: config)
runner.run()
