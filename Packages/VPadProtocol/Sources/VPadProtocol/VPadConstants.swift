import Foundation

// MARK: - Packet enums (§2.1 / §2.3)

public enum EventType: UInt8, Sendable, CaseIterable {
    case trackpadMove = 0x01
    case trackpadScroll = 0x02
    case trackpadClick = 0x03
    case stylusStroke = 0x10
    case stylusHover = 0x11
    case stylusProximity = 0x12
    case stylusSqueeze = 0x13
    case stylusDoubleTap = 0x14
    case keyShortcut = 0x20
    case keyboardPress = 0x21
    case systemAction = 0x22
    case customGesture = 0x40
}

public enum Phase: UInt8, Sendable, CaseIterable {
    case began = 0x00
    case moved = 0x01
    case ended = 0x02
    case cancelled = 0x03
}

public enum SystemAction: UInt8, Sendable, CaseIterable {
    case brightnessDown = 0
    case brightnessUp = 1
    case volumeDown = 2
    case volumeUp = 3
    case mute = 4
    case playPause = 5
    case nextTrack = 6
    case previousTrack = 7
    case missionControl = 8
    case appExpose = 9
    case desktopLeft = 10
    case desktopRight = 11
    case launchpad = 12
}

public struct ModifierMask: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let command = ModifierMask(rawValue: 1 << 0)
    public static let shift = ModifierMask(rawValue: 1 << 1)
    public static let option = ModifierMask(rawValue: 1 << 2)
    public static let control = ModifierMask(rawValue: 1 << 3)
    /// Trackpad pan: synthesized as a real Space key down/up on the Mac.
    public static let space = ModifierMask(rawValue: 1 << 4)

    public static let allKeyboard: ModifierMask = [.command, .shift, .option, .control]
}

// MARK: - Crypto / transport enums

public enum CryptoDirection: UInt32, Sendable, CaseIterable {
    case udpClientToHost = 1
    case udpHostToClient = 2
    case tcpClientToHost = 3
    case tcpHostToClient = 4
}

public enum FrameType: UInt8, Sendable, CaseIterable {
    case hello = 0x01
    case helloAck = 0x02
    case ready = 0x03
    case ping = 0x04
    case pong = 0x05
    case stats = 0x06
    case error = 0x07
    /// USB transport: one raw 28-byte VPadPacket, encrypted by the TCP session.
    case inputPacket = 0x08
    case fileHeader = 0x30
    case fileChunk = 0x31
    case fileTrailer = 0x32
    case fileStatus = 0x33
    /// Additive before the v1 freeze: explicit transfer cancellation.
    case fileAbort = 0x34
}

public enum FileStatus: UInt8, Sendable, CaseIterable {
    case success = 0x00
    case checksumMismatch = 0x01
    case diskError = 0x02
    case cancelled = 0x03
}

public enum ProtocolErrorCode: UInt8, Sendable, CaseIterable {
    case unsupportedVersion = 0x01
    case malformedFrame = 0x02
    case cancelled = 0x03
    case internalError = 0x04
}

// MARK: - Constants

public enum VPadConstants {
    public static let protocolVersion: UInt8 = 1
    public static let protocolVersionV2: UInt8 = 2

    public static let udpService = "_vpad._udp"
    public static let tcpService = "_vpad-tcp._tcp"
    public static let tcpPort: UInt16 = 8889
    /// AGENT_PLAN leaves the UDP port to Bonjour. A fixed port is used for
    /// deterministic firewalling and local end-to-end verification.
    public static let udpPort: UInt16 = 8888

    public static let hkdfSalt = Data("VPadSalt".utf8)
    public static let hkdfInfo = Data("VPadSessionKey".utf8)

    public static let hkdfInfoV2C2S = "VPad v2 c2s"
    public static let hkdfInfoV2S2C = "VPad v2 s2c"

    public static let nonceSize = 12
    public static let ciphertextSize = 28
    public static let tagSize = 16
    public static let udpEnvelopeSize = 56
    public static let publicKeySize = 32

    public static let fileChunkSize = 65_536
    public static let maxFramePayload = 1 << 20
    public static let maxFileNameBytes = 255
    public static let maxFileSize: UInt64 = 8 * 1024 * 1024 * 1024
    public static let uploadsFolderName = "VirtualTabletUploads"

    public static let defaultGestureCommandTab: UInt16 = 1
    public static let defaultGestureDarkMode: UInt16 = 2
    public static let defaultGestureTerminal: UInt16 = 3
}

// MARK: - macOS virtual key codes referenced by the Mac host and defaults

public enum VPadKeycode {
    public static let z: UInt16 = 6
    public static let e: UInt16 = 14
    public static let rightBracket: UInt16 = 30
    public static let leftBracket: UInt16 = 33
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    public static let delete: UInt16 = 51
}
