# VirtualTabletPad: Plan Notes & Baseline Audit (Task 0.1)

Documenting the initial state of the codebase, baseline test and build results, architectural details, packet layouts, security posture, and reconciliation of assumptions in `IMPROVEMENT_PLAN.md` against actual implementation.

---

## 1. Baseline Test & Build Status

The baseline build and test suite were verified on macOS 14+ / Darwin arm64 with Swift 6 strict concurrency:

- **`make test` (Packages/VPadProtocol)**:
  - **Status**: PASSED (0 errors, 0 failures, 0 warnings).
  - **Executed**: 25 unit tests across 3 test suites in 0.005s:
    - `CryptoManagerTests`: 7 tests passed (key derivation, nonce formatting, TCP payload round-trip, UDP envelope round-trip/tamper, replay/gap detection, client/host role directions).
    - `VPadFramesTests`: 9 tests passed (frame round-trip, partial/multiple frames decoder, zero/oversized rejection, file header/chunk/trailer round-trips, filename sanitization, unknown type rejection).
    - `VPadPacketTests`: 9 tests passed (28-byte frozen layout, field offsets and little-endian ordering, invalid length rejection, trackpad click sentinels, stylus factory clamping, roll angle keycode multiplexing, gesture ID multiplexing, proximity/double-tap factories).
- **`make build` (MacHost target)**:
  - **Status**: PASSED (0 errors, 0 warnings).
  - XcodeGen spec `project.yml` successfully generated `VirtualTabletPad.xcodeproj`.
  - Built `MacHost` scheme in `Release` configuration for `generic/platform=macOS`.
  - Code signing verified with `codesign --verify --deep --strict /tmp/VirtualTabletPadBuild/Build/Products/Release/VirtualTabletPad.app`.
  - Product staged to `build/VirtualTabletPad.app`.
- **`make ipad-build` (iPadClient target)**:
  - **Status**: PASSED (0 errors, 0 warnings).
  - Built `iPadClient` scheme in `Debug` configuration for `generic/platform=iOS Simulator`.
  - App bundle verified at `/tmp/VirtualTabletPadiPad/Build/Products/Debug-iphonesimulator/VirtualTabletPad.app`.

---

## 2. Actual Repository Layout vs. Section 0 Assumptions

The initial assumption in Section 0 of `IMPROVEMENT_PLAN.md` listed a simplified set of files. The actual repository contains additional components:

### `Packages/VPadProtocol/`
- `Package.swift`: Swift Package Manager manifest targeting macOS 14.0+ and iOS 17.5+ (Swift 5.10 / Swift 6 mode).
- `Sources/VPadProtocol/`:
  - `VPadConstants.swift`: Protocol version (`protocolVersion = 1`), ports (`udpPort = 8888`, `tcpPort = 8889`), Bonjour service IDs (`_vpad._udp`, `_vpad-tcp._tcp`), packet sizes (`packetSize = 28`, `udpEnvelopeSize = 56`), `EventType`, `Phase`, `ModifierMask`, `CryptoDirection`, `FrameType`, `FileStatus`, `ProtocolErrorCode`, `VPadKeycode`.
  - `VPadPacket.swift`: `@frozen public struct VPadPacket` (28 bytes), raw serializers `toData()` and `fromData()`, typed factories for trackpad move/scroll/click, stylus stroke/hover/proximity/squeeze/double-tap, shortcuts, keyboard press, system action.
  - `CryptoManager.swift`: Stateless crypto utilities (Curve25519, HKDF-SHA256, AES-GCM-256) and thread-safe `SessionCrypto` class for hot-path packet sealing/opening and anti-replay counters.
  - `VPadFrames.swift`: TCP framing protocol (`VPadFrame`, `VPadFrameCodec`, `VPadFrameDecoder`, `FileHeaderPayload`, `FileStatusPayload`).
- `Tests/VPadProtocolTests/`:
  - `VPadPacketTests.swift`, `CryptoManagerTests.swift`, `VPadFramesTests.swift`.

### `MacHost/`
- `MacHostApp.swift`: Menu-bar app lifecycle (`MenuBarExtra`), settings windows, connection status, IP address picker.
- `UDPServer.swift`: UDP listener on port 8888 (`com.vpad.network` serial queue), datagram receive, decrypt, and dispatch to `EventInjector`.
- `TCPServer.swift`: TCP listener on port 8889, handshake state machine (`awaitingHello` → `ready`), ping/pong, file streaming.
- `EventInjector.swift`: Synthesizes macOS input events via `CGEvent` (trackpad move/scroll/click, stylus tablet mouse, proximity, keyboard, system media keys, dock expose actions).
- `FileReceiver.swift`: Receives chunked file uploads, computes SHA-256 in flight, saves to `~/Downloads` or `$VPAD_UPLOADS_DIR`.
- `SessionState.swift`: Global actor managing active session token, peer description, drop counters.
- `AccessibilityManager.swift`: Checks `AXIsProcessTrustedWithOptions` and polls every 1.5s.
- `GestureMapper.swift` & `GestureMapView.swift`: Maps multi-touch `GestureID`s to custom AppleScript actions or key combinations.
- `PairingView.swift`: Displays pairing QR code encoding local IP and ports.
- `HostBeacon.swift`: Publishes Bonjour services `_vpad._udp` and `_vpad-tcp._tcp`.
- `USBProxy.swift`: usbmuxd tunnel support for raw USB-C wired connections.

### `iPadClient/`
- `iPadClientApp.swift`: SwiftUI application entry point.
- `HybridCanvasView.swift`: 240 Hz touch and stylus engine (UIKit). Captures coalesced touches, hover, altitude/azimuth tilt, Apple Pencil Pro roll angle, normalizes coordinates against `activeRect`.
- `TransientInkLayer.swift`: Fading CAShapeLayer visual feedback trail.
- `LiquidGlassWorkspace.swift`: Modern iPadOS tablet UI with Touch Bar-style top strip, slab bezel, and keyboard accessory mode.
- `WorkspaceView.swift` & `WorkspaceSettingsView.swift`: Workspace views and customization sheets.
- `TouchpadSettingsView.swift` & `TouchpadSettings.swift`: Sensitivity, acceleration curve, natural scrolling, and jitter filter settings.
- `PencilSettings.swift` & `PencilStatusMonitor.swift`: Pressure curve and hover/battery monitor.
- `PencilProManager.swift`: Apple Pencil Pro squeeze gesture and haptic feedback.
- `FunctionKeys.swift`: Top-strip F1–F12, brightness, and media control buttons.
- `GestureEngine.swift`: Multi-finger gesture recognition.
- `ModifierState.swift`: Active modifier bitmask state.
- `UDPClient.swift`: NWConnection UDP datagram sender on `.interactiveVideo` service class.
- `TCPFileClient.swift`: TCP handshake and chunked file uploader.
- `SessionCoordinator.swift` & `SessionState.swift`: Connection lifecycle state coordinators.
- `LinkDiscovery.swift`: NWBrowser Bonjour discovery.
- `PairingProfile.swift`: Storage for paired Mac IP and ports.
- `QRScannerView.swift`: AVFoundation camera view to scan pairing QR code.

### `Tools/`
- `run_all_silent_tests.py`: Python end-to-end multi-stage silent integration test runner.
- `vpad_probe.py`: Command-line diagnostic probe against running MacHost.

---

## 3. `VPadPacket` Binary Layout & Field Offsets

The packet is frozen at **28 bytes** with 4-byte struct alignment (`@frozen public struct VPadPacket`):

| Offset | Size | Field | Type | Encoding / Format | Purpose |
|---|---|---|---|---|---|
| **0** | 1B | `type` | `UInt8` | `EventType` rawValue | Event type (0x01 move, 0x02 scroll, 0x03 click, 0x10 stroke, 0x11 hover, 0x12 proximity, 0x13 squeeze, 0x14 doubleTap, 0x20 shortcut, 0x21 key, 0x22 systemAction, 0x40 gesture) |
| **1** | 1B | `phase` | `UInt8` | `Phase` rawValue | Phase (0x00 began, 0x01 moved, 0x02 ended, 0x03 cancelled) |
| **2..3** | 2B | `modifiers` | `UInt16` | Little-endian bitmask | `ModifierMask` (cmd=1, shift=2, opt=4, ctrl=8, space=16), or `GestureID` when `type == 0x40` |
| **4..7** | 4B | `x` | `Float32` | Little-endian IEEE 754 | Normalized [0.0, 1.0] for stylus; delta dx for trackpad; `SystemAction` enum rawValue for system action |
| **8..11** | 4B | `y` | `Float32` | Little-endian IEEE 754 | Normalized [0.0, 1.0] for stylus; delta dy for trackpad |
| **12..15** | 4B | `pressure` | `Float32` | Little-endian IEEE 754 | Stylus tip pressure [0.0, 1.0]; trackpad click sentinel (1.0 = left, 2.0 = right) |
| **16..19** | 4B | `tiltX` | `Float32` | Little-endian IEEE 754 | Stylus altitude/azimuth projection [-1.0, 1.0] |
| **20..23** | 4B | `tiltY` | `Float32` | Little-endian IEEE 754 | Stylus altitude/azimuth projection [-1.0, 1.0] |
| **24..27** | 4B | `rollAngle` | `Float32` | Little-endian IEEE 754 | Apple Pencil Pro barrel roll angle [-π, π] radians; or virtual `CGKeyCode` for keyboard / shortcut |

Total: **28 bytes**.
Verified in `Packages/VPadProtocol/Tests/VPadProtocolTests/VPadPacketTests.swift`:
`MemoryLayout<VPadPacket>.size == 28`, `stride == 28`, `alignment == 4`.

---

## 4. Current Pairing & Encryption Mechanics

### Pairing
- MacHost generates a QR code displaying JSON:
  `{"version": 1, "name": "<Mac Name>", "host": "<IP>", "tcpPort": 8889, "udpPort": 8888}`.
- iPadClient scans the QR code with `QRScannerView` and stores `PairedProfile` in `UserDefaults` (`vpad.pairedProfile`).
- **Deficiencies**:
  - No identity keys or persistent asymmetric key pairs.
  - No cryptographic authentication or pinning of host keys.
  - No one-time challenge token.
  - No user approval prompt on MacHost when an unknown client connects.

### Handshake (TCP port 8889)
- Client connects via TCP to port 8889.
- Client generates an ephemeral `Curve25519.KeyAgreement.PrivateKey` and sends plaintext frame:
  `HELLO (0x01) | version (0x01) | clientEphemeralPublicKey (32B)`.
- Server receives `HELLO`, generates its own ephemeral `Curve25519.KeyAgreement.PrivateKey`, and derives a 32-byte `SymmetricKey` using HKDF-SHA256:
  `salt = "VirtualTabletPad-v1-Salt"` (UTF-8)
  `sharedInfo = "VirtualTabletPad-AES-GCM-256"` (UTF-8).
- Server arms `SessionCrypto` on `UDPServer` and sends plaintext frames:
  `HELLO_ACK (0x02) | version (0x01) | hostEphemeralPublicKey (32B)`
  followed by `READY (0x03)`.
- Client receives `HELLO_ACK`, derives the same symmetric key, and arms `SessionCrypto` on `UDPClient`.
- **Deficiencies**:
  - Vulnerable to active Man-In-The-Middle (MITM) attacks on the local network because ephemeral public keys are unauthenticated and unsigned.

### UDP Input Framing (port 8888)
- Datagram format (56 bytes):
  `direction (4B, big-endian) | counter (8B, big-endian) | ciphertext (28B) | tag (16B)`.
- Nonce is 12 bytes: `direction (4B) || counter (8B)`.
  - Direction: `udpClientToHost = 1`, `udpHostToClient = 2`.
- `SessionCrypto.openUDP`:
  - Enforces `metadata.counter > lastUDPCounter`.
  - If a packet arrives out of order (`counter <= lastUDPCounter`), it is **immediately dropped**.
  - **Deficiencies**:
    - No `sessionID` field in the UDP envelope.
    - No sliding replay window (out-of-order packets cause packet loss and gap counting).
    - Sequence counter near overflow is not monitored for rekeying.

---

## 5. Current `UDPServer` Handling of Unknown Senders

- `UDPServer` creates an `NWListener` on UDP port 8888.
- It accepts up to 8 connections (`connections: [NWConnection]`).
- It does **not** validate the sender's IP or endpoint against the authenticated TCP connection.
- In `handleDatagram(_ data: Data)`:
  - If no session is armed (`session == nil`), the datagram is dropped immediately.
  - If a session is armed, it attempts `currentSession.openUDP(data)`.
  - If the packet is from an unknown sender or attacker:
    - The nonce direction or counter check will fail, or
    - AES-GCM tag verification will fail (`dropped += 1`).
- **Deficiencies**:
  - Any machine on the local network can flood UDP port 8888 with 56-byte datagrams, forcing AES-GCM decryption operations on the high-priority `com.vpad.network` queue, creating a CPU denial-of-service vector.

---

## 6. What `EventInjector` Currently Posts

`EventInjector` receives decrypted `VPadPacket` structs from the `com.vpad.network` serial queue and synthesizes macOS input:

1. **Trackpad Move**:
   - Computes target point using `hypot(dx, dy)` and dynamic acceleration gain `[1.0, 2.8]`.
   - Clamps to main display bounds.
   - Synthesizes `CGEvent` with mouse type `.mouseMoved` (or `.leftMouseDragged` if mouse is down).
2. **Trackpad Scroll**:
   - Synthesizes `CGEvent(scrollWheelEvent2Source: ...)` on `.cghidEventTap` with pixel units.
3. **Trackpad Click**:
   - Distinguishes left vs. right click based on `packet.pressure >= 1.5` sentinel.
   - Synthesizes `.leftMouseDown`/`.leftMouseUp` or `.rightMouseDown`/`.rightMouseUp` on `.cghidEventTap`.
4. **Stylus Stroke & Hover**:
   - Translates normalized `(x, y)` to main screen display coordinates.
   - Synthesizes `CGEvent` mouse events (`.mouseMoved`, `.leftMouseDown`, `.leftMouseDragged`, `.leftMouseUp`).
   - Sets event fields:
     - `.mouseEventSubtype` = `Int64(CGEventMouseSubtype.tabletPoint.rawValue)` (1)
     - `.mouseEventPressure` = `Double(safeUnit(packet.pressure))` (0.0 to 1.0)
     - `.tabletEventTiltX` = `Double(safeBipolar(packet.tiltX))` (-1.0 to 1.0)
     - `.tabletEventTiltY` = `Double(safeBipolar(packet.tiltY))` (-1.0 to 1.0)
     - `.tabletEventRotation` = `degrees` (0.0 to 360.0 from `packet.rollAngle`)
   - Posts to `.cghidEventTap`.
5. **Stylus Proximity**:
   - Synthesizes `CGEvent` of type `.tabletProximity`.
   - Sets `.tabletProximityEventEnterProximity` = 1 (began) or 0 (ended/cancelled).
   - Sets `.tabletProximityEventPointerType` = 1 (pen tip).
   - Sets `.tabletProximityEventVendorID` = 0x056A (Wacom).
   - Sets `.tabletProximityEventCapabilityMask` = 0x0FFF.
   - Posts to `.cghidEventTap`.
6. **Stylus Squeeze**:
   - Calls `CGWarpMouseCursorPosition(point)` and simulates a right-click down/up (10ms hold).
7. **Stylus Double Tap**:
   - Posts atomic keycode `VPadKeycode.e` (eraser shortcut).
8. **Keyboard & Shortcuts**:
   - Posts key down/up with autorepeat for `keyboardPress`.
   - Posts atomic key combos for `keyShortcut`.
9. **System Actions**:
   - Dispatches media/volume/brightness via `NSEvent.otherEvent(with: .systemDefined, subtype: 8, ...)` or Dock Exposé via Accessibility API.
10. **Spacebar Panning**:
    - Synthesizes real Spacebar down/up when `ModifierMask.space` changes state.

---

## 7. Assumptions in `IMPROVEMENT_PLAN.md` vs. Reality

| Topic | Plan Assumption | Codebase Reality | Action in Subsequent Tasks |
|---|---|---|---|
| **iPad Canvas View** | `iPadClient/CanvasView.swift` | Implemented as `iPadClient/HybridCanvasView.swift` | Use `HybridCanvasView.swift` across all tasks. |
| **Protocol Library** | 3 files (`VPadPacket`, `CryptoManager`, `VPadConstants`) | 4 files, including `VPadFrames.swift` (framing, chunking, file codecs) | Preserve and extend `VPadFrames.swift`. |
| **UDP Datagram Layout** | `sessionID (4B) \| seq (8B) \| ciphertext (28B) \| tag (16B)` | Current v1 is `direction (4B) \| counter (8B) \| ciphertext (28B) \| tag (16B)` | Update to `sessionID \| seq \| ciphertext \| tag` in Task 1.4 with protocol v2. |
| **Replay Protection** | Sliding bitmap `ReplayWindow` | Current v1 is strictly monotonic check (`counter > lastUDPCounter`), which drops out-of-order packets | Implement sliding bitmap `ReplayWindow` in Task 1.4. |
| **Identity Keys & Auth** | Assumed identity keys exist | Only ephemeral X25519 keys exist in v1; no Ed25519 keys or pinning | Implement `IdentityKey` and Keychain stores in Task 1.2, signed handshake in Task 1.3. |
| **Event Injection Testing** | Assumed `EventPosting` abstraction exists | Direct calls to `CGEvent.post()` and `CGWarpMouseCursorPosition()` | Implement `protocol EventPosting` in Task 2.1. |
| **Proximity State Machine** | Assumed existing state machine | Stateless pass-through driven only by client packets; no timeout or automatic proximity enter/leave on contact | Implement formal `ProximityStateMachine` in Task 2.2. |
| **File Transfer Path Traversal** | Assumed unhardened path | `VPadFrames.swift` already has `testFileNameSanitization` testing simple names, but `FileReceiver.swift` needs full traversal prevention (`..`, absolute paths, control characters) | Harden `FileReceiver.swift` in Task 1.7. |
