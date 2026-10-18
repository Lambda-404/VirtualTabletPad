# AGENT_PLAN.md — VirtualTrackpad & Apple Pencil Pro Graphics Tablet

**macOS Host (14.0+) ↔ iPadOS Client (17.5+) — Merged, dependency-ordered, executable edition**

This single document consolidates the two source plans into one coherent build plan:

- **Core Edition** — Virtual Trackpad, 240 Hz Apple Pencil graphics-tablet engine, Apple Pencil Pro hardware extensions (Barrel Roll, Squeeze, Hover Pose, Haptics).
- **Enhanced Edition** — End-to-End Encryption (E2EE), keyboard pass-through, reliable file transfer, custom multi-touch gestures.

What was reconciled between the two source plans, and why, is logged in [Appendix A](#appendix-a--merge--reconciliation-log). A constants quick-reference is in [Appendix B](#appendix-b--quick-reference).

---

## 0. Agent Directives & Execution Constraints

1. **Autonomous Buildability** — Swift Package Manager (`Package.swift`) for shared protocol logic; XcodeGen (`project.yml`) generates `VirtualTabletPad.xcodeproj`. No GUI intervention anywhere in the build chain.
2. **Strict Concurrency & Latency**
   - Target **Swift 5.10 / Swift 6** language mode; builds must finish with **zero strict-concurrency warnings**.
   - All `Network.framework` UDP socket I/O runs on the dedicated high-priority serial queue `DispatchQueue(label: "com.vpad.network", qos: .userInteractive)`.
   - TCP control/file streaming and the ECDH key exchange run on background serial queues (`qos: .utility`).
   - The 240 Hz touch/stylus/keyboard loop never touches JSON/Codable. Only the fixed **28-byte binary `VPadPacket`** (§2) and the pre-derived AES-GCM session key (§3). The only sanctioned heap allocation in the hot loop is the 56-byte encrypted envelope produced by `AES.GCM.seal` (§3.5).
3. **Target OS Versions**
   - **MacHost:** macOS 14.0+ (Sonoma or newer).
   - **iPadClient:** iPadOS 17.5+ (required for `UITouch.rollAngle`, `UIPencilInteraction.Squeeze`, `UICanvasFeedbackGenerator`).
4. **Security by default** — after the one-time ECDH handshake every packet is AES-GCM-256 encrypted and authenticated (§3). No plaintext transport is shipped in release builds; unauthenticated datagrams are dropped silently.
5. **Protocol freeze** — the 28-byte `VPadPacket` layout is frozen once TASK 1's tests pass. Additive changes require bumping `VPadConstants.protocolVersion` and the HELLO frame version byte (§3.1).

---

## 1. Repository Layout & Project Generation

### 1.1 Directory tree (every file is created by a task below)

```text
VirtualTabletPad/
├── project.yml                       # XcodeGen spec → VirtualTabletPad.xcodeproj (§1.2)
├── Packages/
│   └── VPadProtocol/
│       ├── Package.swift
│       ├── Sources/VPadProtocol/
│       │   ├── VPadConstants.swift   # EventType/Phase/Modifier bitmask, Bonjour ids, port, nonce prefixes
│       │   ├── VPadPacket.swift      # 28-byte packed struct, factories, raw serializer (§2)
│       │   └── CryptoManager.swift   # Curve25519 + HKDF + AES-GCM envelope, nonce counters (§3)
│       └── Tests/VPadProtocolTests/
│           └── VPadPacketTests.swift # layout + round-trip + crypto round-trip/tamper tests
├── MacHost/
│   ├── Info.plist                    # LSUIElement, local-network + AppleEvents usage strings, Bonjour
│   ├── MacHostApp.swift              # MenuBarExtra UI, connection status, gesture-map editor window
│   ├── AccessibilityManager.swift    # AXIsProcessTrustedWithOptions + 1.5 s polling
│   ├── SessionState.swift            # Actor: session key, nonce counters, drop statistics
│   ├── UDPServer.swift               # _vpad._udp listener; decrypt → inject loop on netQueue
│   ├── TCPServer.swift               # _vpad-tcp._tcp :8889 control channel + file streams
│   ├── EventInjector.swift           # CGEvent synthesis: trackpad / tablet / keyboard / gestures
│   └── GestureMapper.swift           # GestureID → key macro / script resolution (UserDefaults)
└── iPadClient/
    ├── Info.plist                    # Local-network usage, Bonjour services, landscape orientation
    ├── iPadClientApp.swift           # Fullscreen landscape app entry
    ├── SessionState.swift            # Client-side session actor + key storage
    ├── UDPClient.swift               # NWBrowser + encrypted 240 Hz sender (.interactiveVideo)
    ├── TCPFileClient.swift           # Control-channel handshake + chunked file uploads (one TCP channel)
    ├── KeyboardHandler.swift         # pressesBegan/Ended capture + software-keyboard path → 0x21
    ├── GestureEngine.swift           # ≥3-finger trajectory recognizer → 0x40
    ├── ModifierState.swift           # Lock-protected active modifier bitmask
    ├── HybridCanvasView.swift        # 240 Hz coalesced touch + hover capture, activeRect mapping
    ├── PencilProManager.swift        # UIPencilInteraction (Squeeze/Tap) + haptics
    ├── TransientInkLayer.swift       # 0.8 s fading CAShapeLayer trail
    └── WorkspaceView.swift           # 16:10 frame, ModifierSidebar, Radial HUD, file drop zone
```

> The Enhanced Edition's tree dropped `HybridCanvasView`, `TransientInkLayer`, `ModifierState`, `PencilProManager`, both `Info.plist` files and the test target; all are restored above. `SessionState.swift` and `GestureMapper.swift` are new homes for state that both plans implied but never filed (see Appendix A).

### 1.2 `project.yml` (XcodeGen) requirements

The agent must generate a spec equivalent to:

```yaml
name: VirtualTabletPad
options:
  bundleIdPrefix: com.vpad
  deploymentTarget:
    macOS: "14.0"
    iOS: "17.5"
packages:
  VPadProtocol:
    path: Packages/VPadProtocol
targets:
  MacHost:
    type: application
    platform: macOS
    sources: [MacHost]
    dependencies:
      - package: VPadProtocol
    info:
      path: MacHost/Info.plist
      properties:
        LSUIElement: true
        NSLocalNetworkUsageDescription: "Connects to your iPad to receive trackpad, stylus, keyboard and file input."
        NSBonjourServices: ["_vpad._udp", "_vpad-tcp._tcp"]
        NSAppleEventsUsageDescription: "Runs user-mapped gesture scripts via AppleScript."
    settings:
      base:
        SWIFT_VERSION: "5.10"            # or 6.0 after TASK 1 passes in both modes
        ENABLE_APP_SANDBOX: NO           # CGEvent posting requires unsandboxed + Accessibility grant
        ENABLE_HARDENED_RUNTIME: YES
        CODE_SIGN_STYLE: Automatic       # local dev may use CODE_SIGN_IDENTITY "-" (ad-hoc)
  iPadClient:
    type: application
    platform: iOS
    sources: [iPadClient]
    dependencies:
      - package: VPadProtocol
    info:
      path: iPadClient/Info.plist
      properties:
        NSLocalNetworkUsageDescription: "Discovers your Mac and sends encrypted trackpad, stylus, keyboard and file input."
        NSBonjourServices: ["_vpad._udp", "_vpad-tcp._tcp"]
        UISupportedInterfaceOrientations: [UIInterfaceOrientationLandscapeLeft, UIInterfaceOrientationLandscapeRight]
        UIRequiresFullScreen: true
    settings:
      base:
        SWIFT_VERSION: "5.10"
        TARGETED_DEVICE_FAMILY: "2"
```

### 1.3 `Info.plist` invariants

- **MacHost:** `LSUIElement = true` (menu-bar agent, no Dock icon); `NSLocalNetworkUsageDescription`; `NSBonjourServices` with both services; `NSAppleEventsUsageDescription` (TASK 10 scripts).
- **iPadClient:** `NSLocalNetworkUsageDescription`; `NSBonjourServices` with both services; landscape-only orientation; fullscreen.

---

## 2. Binary Wire Protocol — 28-Byte Core Packet

### 2.1 Fixed layout (little-endian; Apple silicon is LE, no byte-swapping)

| Offset | Field       | Swift Type | Size | Specification |
|-------:|-------------|------------|-----:|---------------|
| 0      | `type`      | `UInt8`    | 1 B  | `0x01` TrackpadMove · `0x02` TrackpadScroll · `0x03` TrackpadClick · `0x10` StylusStroke · `0x11` StylusHover · `0x12` StylusProximity · `0x13` StylusSqueeze · `0x14` StylusDoubleTap · `0x20` KeyShortcut · `0x21` KeyboardPress · `0x40` CustomGesture |
| 1      | `phase`     | `UInt8`    | 1 B  | `0x00` Began/Down · `0x01` Moved/Changed/Repeat · `0x02` Ended/Up · `0x03` Cancelled |
| 2…3    | `modifiers` | `UInt16`   | 2 B  | Bitmask: `1<<0` Cmd · `1<<1` Shift · `1<<2` Opt · `1<<3` Ctrl · `1<<4` Space (pad-pan) |
| 4…7    | `x`         | `Float32`  | 4 B  | Trackpad: `deltaX` px · Stylus: normalized 0.0…1.0 X in the active 16:10 box |
| 8…11   | `y`         | `Float32`  | 4 B  | Trackpad: `deltaY` px · Stylus: normalized 0.0…1.0 Y in the active 16:10 box |
| 12…15  | `pressure`  | `Float32`  | 4 B  | Stylus: normalized force 0.0…1.0 · Click (`0x03`): 1.0 = Left, 2.0 = Right |
| 16…19  | `tiltX`     | `Float32`  | 4 B  | Stylus: planar X tilt −1.0…1.0 |
| 20…23  | `tiltY`     | `Float32`  | 4 B  | Stylus: planar Y tilt −1.0…1.0 |
| 24…27  | `rollAngle` | `Float32`  | 4 B  | Pencil Pro barrel roll, radians (−π…π) · `0x20`/`0x21`: virtual `CGKeyCode` packed as Float32 |

Total = 28 bytes. All fields are naturally aligned (`size == stride == 28`); this is asserted by TASK 1 tests and is the precondition for the raw `withUnsafeBytes` serializer.

### 2.2 Field multiplexing per packet type

The 28-byte struct is reused for every type; the meaning of each field is fixed by `type`:

| Type  | Name           | `x`          | `y`          | `pressure`          | `tiltX` | `tiltY` | `rollAngle` | `modifiers` |
|------:|----------------|--------------|--------------|---------------------|---------|---------|-------------|-------------|
| 0x01  | TrackpadMove   | deltaX px    | deltaY px    | —                   | —       | —       | —           | active mods |
| 0x02  | TrackpadScroll | wheel2 dx    | wheel1 dy    | —                   | —       | —       | —           | active mods |
| 0x03  | TrackpadClick  | —            | —            | 1.0 Left / 2.0 Right| —       | —       | —           | active mods |
| 0x10  | StylusStroke   | normX        | normY        | force 0…1           | tiltX   | tiltY   | roll (rad)  | active mods |
| 0x11  | StylusHover    | normX        | normY        | —                   | tiltX   | tiltY   | roll (rad)  | active mods |
| 0x12  | StylusProximity| —            | —            | —                   | —       | —       | —           | —           |
| 0x13  | StylusSqueeze  | normX        | normY        | —                   | —       | —       | roll (rad)  | active mods |
| 0x14  | StylusDoubleTap| —            | —            | —                   | —       | —       | —           | active mods |
| 0x20  | KeyShortcut    | —            | —            | —                   | —       | —       | CGKeyCode   | macro mods |
| 0x21  | KeyboardPress  | —            | —            | —                   | —       | —       | CGKeyCode   | key mods   |
| 0x40  | CustomGesture  | —            | —            | —                   | —       | —       | —           | GestureID (UInt16) |

### 2.3 Phase semantics per type

- **0x03 / 0x13:** `0x00` = down/fire, `0x02` = up/release (squeeze sends `0x00` only).
- **0x12:** `0x00` = enter proximity, `0x02` = leave, `0x03` = cancel.
- **0x21:** `0x00` = keyDown, `0x01` = key repeat, `0x02` = keyUp, `0x03` = cancel (Mac synthesizes keyUp for any tracked-down key).
- **0x20 / 0x14:** atomic triggers. One packet (phase `0x00`) causes the Mac to synthesize keyDown + keyUp (40 ms apart) with the given modifiers. This removes the ambiguity in the Core Edition, where 0x20's down/up pairing was unspecified.
- **0x40:** `0x00` = trigger; `0x02`/`0x03` = gesture end/cancel (used to end the cooldown).

### 2.4 Serializer contract (exact code, from Core Edition)

```swift
public func toData() -> Data {
    withUnsafeBytes(of: self) { Data($0) }
}

public static func fromData(_ data: Data) -> VPadPacket? {
    guard data.count == 28 else { return nil }
    return data.withUnsafeBytes { $0.loadUnaligned(as: VPadPacket.self) }
}
```

Plus typed factory methods (`static func stylusStroke(…)`, `static func keyboardPress(…)`, …) so every packet is constructed with its field semantics enforced — no invalid packet can be built by accident.

---

## 3. Transport Security — End-to-End Encryption (E2EE)

All UDP datagrams and TCP frames are encrypted with **AES-GCM-256** (Apple CryptoKit). This protects input streams and file transfers on untrusted Wi-Fi.

### 3.1 Session establishment (TCP control channel, one-time)

1. iPad opens a TCP connection to Mac port **8889** (Bonjour `_vpad-tcp._tcp`).
2. Plaintext frames, in order:
   - iPad → Mac `HELLO`: 1-byte protocol version + 32-byte Curve25519 (X25519) public key.
   - Mac → iPad `HELLO_ACK`: 1-byte version + 32-byte server public key.
3. Both peers compute (CryptoKit):

   ```swift
   let sharedSecret = try myPrivateKey.sharedSecretFromKeyAgreement(with: remotePublicKey)
   let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
       using: SHA256.self,
       salt: Data("VPadSalt".utf8),
       sharedInfo: Data("VPadSessionKey".utf8),
       outputByteCount: 32)
   ```

4. Mac → iPad `READY` (plaintext). From this point **every** TCP frame is encrypted and the iPad may begin encrypted UDP; the Mac UDP listener drops all datagrams until `SessionState` is armed.
5. Handshake timeout: 5 s. Version mismatch → `ERROR` frame, close, and show an upgrade prompt.

### 3.2 UDP envelope — fixed 56-byte datagram

```text
offset  0…12   nonce: 4-byte direction discriminator + 8-byte big-endian counter
offset 12…40   AES-GCM ciphertext of the 28-byte VPadPacket
offset 40…56   16-byte authentication tag
```

Direction discriminators: `0x00000001` iPad→Mac, `0x00000002` Mac→iPad.

### 3.3 TCP framing

Every TCP frame is `[4-byte big-endian payload length][payload]`, payload = `[1-byte frameType][body]`.

| Type | Name        | Direction  | Body |
|-----:|-------------|-----------|------|
| 0x01 | HELLO       | iPad→Mac   | version `UInt8` + 32 B pubkey (plaintext, once) |
| 0x02 | HELLO_ACK   | Mac→iPad   | version `UInt8` + 32 B pubkey (plaintext, once) |
| 0x03 | READY       | Mac→iPad   | empty (plaintext, once) |
| 0x04 | PING        | either     | `UInt64` timestamp (encrypted; answer with PONG) |
| 0x05 | PONG        | either     | echo of PING body |
| 0x06 | STATS       | Mac→iPad   | `UInt64` dropped-packet counter, `UInt64` last nonce (post-stroke diagnostics) |
| 0x07 | ERROR       | either     | `UInt8` code |
| 0x30 | FILE_HEADER | iPad→Mac   | §5 |
| 0x31 | FILE_CHUNK  | iPad→Mac   | §5 |
| 0x32 | FILE_TRAILER| iPad→Mac   | §5 |
| 0x33 | FILE_STATUS | Mac→iPad   | §5 |

**One persistent TCP connection** multiplexes control, stats, and file frames; all sends are serialized on that channel's `.utility` queue, so interleaving is safe and PING latency is not starved by file traffic.

### 3.4 Nonce management & anti-replay

- Nonce = 4-byte direction + 8-byte counter, **starting at 0 per session**, incremented per frame per direction. Keys are ephemeral per session, so nonce reuse is impossible within a session (2⁶⁴ space).
- TCP uses discriminators `0x00000003` iPad→Mac and `0x00000004` Mac→iPad with the same counter scheme.
- Receivers track `lastCounter[peer]` and drop any frame with counter ≤ last (anti-replay). Gaps between counters are counted as dropped packets and surfaced via `STATS`.
- Optional post-MVP: `ROTATE` control frame to rekey long sessions (not a verification gate).

### 3.5 E2EE cost budget (why the 240 Hz loop stays fast)

- 56 B × 240 Hz = **13,440 B/s ≈ 107 kbit/s** — negligible on Wi-Fi 6 or wired USB-C.
- CryptoKit AES-GCM runs in hardware AES on Apple silicon: ≈ sub-microsecond per packet → **< 0.03 % CPU** at 240 Hz.
- Session keys are derived once at handshake; the hot loop only calls `AES.GCM.seal(_:using:nonce:)` with an incrementing counter. The 56-byte envelope is the single sanctioned heap allocation in the hot path.

---

## 4. Mathematical & Conversion Specifications

### 4.1 Spherical altitude/azimuth → planar Wacom tilt (iPadClient)

`UITouch` provides `altitudeAngle` (0 = flat on glass, π/2 = perpendicular) and `azimuthAngle(in:)` (0…2π). Convert to Wacom planar tilt in [−1.0, 1.0]:

```swift
tiltX = Float(cos(azimuth) * cos(altitude))
tiltY = Float(sin(azimuth) * cos(altitude))
```

### 4.2 Barrel roll radians → Wacom rotation degrees (MacHost)

`UITouch.rollAngle` / `UIHoverGestureRecognizer.rollAngle` return radians in [−π, π]. `CGEventField.tabletEventRotation` requires degrees in [0.0, 360.0):

```swift
let degrees = fmod((Double(packet.rollAngle) * 180.0 / .pi) + 360.0, 360.0)
```

### 4.3 Aspect-ratio-locked active mapping box (iPadClient)

An iPad canvas is ~4:3 while a Mac display is typically 16:10 (or 16:9). To prevent geometric distortion (a circle drawn on iPad must not render as an ellipse on Mac):

1. Compute the largest inscribed **16:10** rectangle `activeRect: CGRect`, centered in `CanvasTouchView.bounds`.
2. Normalize every stylus touch/hover point relative to `activeRect`:

```swift
normX = clamp((pt.x - activeRect.minX) / activeRect.width,  0.0, 1.0)
normY = clamp((pt.y - activeRect.minY) / activeRect.height, 0.0, 1.0)
```

The same `activeRect` is drawn as the visible 16:10 border in the workspace UI (§6, TASK 7).

---

## 5. File Transfer Framing (TCP)

File frames multiplex on the TASK 3 control connection (§3.3). Layouts:

```text
FILE_HEADER  (0x30): nameLen UInt16 | fileName UTF-8 | fileSize UInt64
FILE_CHUNK   (0x31): chunkLen UInt32 (≤ 65536) | raw bytes      — 64 KiB buffers
FILE_TRAILER (0x32): sha256 (32 bytes) of the entire file
FILE_STATUS  (0x33): code UInt8 — 0x00 success · 0x01 checksum mismatch · 0x02 disk error · 0x03 cancelled
```

Flow: HEADER → N × CHUNK → TRAILER → Mac verifies SHA-256 and answers FILE_STATUS. The Mac streams chunks to disk (`FileHandle`) and saves to `~/Downloads/VirtualTabletUploads/<sanitized-name>`; sanitization strips path components (no `..`, no absolute paths) and appends a UUID prefix on collision. iPad UI reports progress per chunk (`bytesSent / fileSize`).

---

## 6. Sequential Implementation Tasks

Dependency order: 1 → 2 → 3 → 4 → {5, 6, 7, 8, 9, 10} (5–10 build on 4 but are independent of each other).

---

### TASK 1 — Shared Protocol Package (`Packages/VPadProtocol`)

**Files:** `Package.swift`, `Sources/VPadProtocol/VPadConstants.swift`, `Sources/VPadProtocol/VPadPacket.swift`, `Sources/VPadProtocol/CryptoManager.swift`, `Tests/VPadProtocolTests/VPadPacketTests.swift`

**Requirements:**

1. `Package.swift` — `swift-tools-version:5.10`, platforms `[.macOS(.v14), .iOS(.v17_5)]`, library product `VPadProtocol`, test target.
2. `VPadConstants.swift` — `enum EventType: UInt8` (all §2.1 values), `enum Phase: UInt8`, `struct ModifierMask: OptionSet` over `UInt16`; constants: `protocolVersion = 1`, `udpService = "_vpad._udp"`, `tcpService = "_vpad-tcp._tcp"`, `tcpPort = 8889`, HKDF salt/info, nonce direction prefixes, default gesture IDs (1 = Cmd+Tab, 2 = Dark Mode, 3 = Terminal).
3. `VPadPacket.swift` — `@frozen public struct VPadPacket: Equatable, Sendable` with field order exactly as §2.1; `@inlinable toData()` / `static fromData(_:)` exactly as §2.4; typed factories for every packet type enforcing §2.2 semantics.
4. `CryptoManager.swift` — `final class CryptoManager: @unchecked Sendable` (no Network dependency; unit-testable): Curve25519 keypair generation, `deriveSessionKey(remotePublicKey:)` (§3.1), `sealPacket(_:direction:counter:) -> Data` / `openPacket(_:direction:counter:) -> VPadPacket?` building the 12-byte nonce from direction + counter (§3.2), anti-replay rejection hook.
5. Tests:
   - `MemoryLayout<VPadPacket>.size == 28`, `.stride == 28`.
   - Lossless round-trip serialization; `fromData` rejects non-28-byte input.
   - Factory field-mapping tests (e.g., `keyboardPress` puts keycode in `rollAngle`).
   - AES-GCM round-trip, tamper detection (flip one ciphertext byte → open fails), counter anti-replay, HKDF determinism.

**Verification:** `cd Packages/VPadProtocol && swift test` — 100 % pass.

---

### TASK 2 — macOS Accessibility, Event Injector & Gesture Mapper (`MacHost`)

**Files:** `AccessibilityManager.swift`, `EventInjector.swift`, `GestureMapper.swift`

**Requirements:**

1. **AccessibilityManager.swift**
   - Call `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)`.
   - Poll `AXIsProcessTrusted()` every 1.5 s on a background timer until granted; surface status in the menu-bar UI.
2. **EventInjector.swift**
   - `final class EventInjector: @unchecked Sendable` with `static let shared`; `private let eventSource = CGEventSource(stateID: .hidSystemState)`.
   - `private var isSpacebarHeld = false` — the iPad Space modifier (pan) is synthesized as real key 49 down/up on bit transitions (enter/leave), so panning behaves identically to holding Space on the Mac.
   - Shared helper `func mapModifiers(_ m: UInt16) -> CGEventFlags` (maskCommand / maskShift / maskAlternate / maskControl; Space handled via `isSpacebarHeld`).
3. **Packet routing — `func inject(_ packet: VPadPacket)`** (switch on `packet.type`):
   - **0x01 TrackpadMove** — read current cursor via `CGEvent(source: nil)?.location ?? .zero`; pointer acceleration `let gain = min(max(speed * 0.15, 1.0), 2.8)` where `speed = hypot(packet.x, packet.y)`; clamp new position to `CGDisplayBounds(CGMainDisplayID())`; post `.mouseMoved`, or `.leftMouseDragged` while the left button is down.
   - **0x02 TrackpadScroll** — `CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel, wheelCount: 2, wheel1: Int32(packet.y), wheel2: Int32(packet.x), wheel3: 0)`, post `.cghidEventTap`.
   - **0x03 TrackpadClick** — button from sentinel pressure (`1.0` left, `2.0` right); phase `0x00` → down, `0x02` → up; post at current cursor location.
   - **0x12 StylusProximity (mandatory for Photoshop / Clip Studio Paint / Blender)** —
     ```swift
     guard let event = CGEvent(source: eventSource) else { return }
     event.type = .tabletProximity
     event.setIntegerValueField(.tabletProximityEventEnterProximity, value: packet.phase == 0x00 ? 1 : 0)
     event.setIntegerValueField(.tabletProximityEventPointerType, value: 1)   // pen tip
     event.setIntegerValueField(.tabletProximityEventVendorID, value: 0x056A) // Wacom emulation
     event.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x0FFF)
     event.post(tap: .cghidEventTap)
     ```
   - **0x10 StylusStroke / 0x11 StylusHover** — map `(packet.x, packet.y)` into `CGDisplayBounds(CGMainDisplayID())` pixels. Event type: `0x11` → `.mouseMoved`; `0x10` → `.leftMouseDown` / `.leftMouseDragged` / `.leftMouseUp` by phase. Then inject tablet fields:
     ```swift
     event.setIntegerValueField(.mouseEventSubtype, value: Int64(CGEventMouseSubtype.tabletPoint.rawValue))
     event.setDoubleValueField(.mouseEventPressure, value: Double(packet.pressure))
     event.setDoubleValueField(.tabletEventTiltX, value: Double(packet.tiltX))
     event.setDoubleValueField(.tabletEventTiltY, value: Double(packet.tiltY))
     let degrees = fmod((Double(packet.rollAngle) * 180.0 / .pi) + 360.0, 360.0)   // §4.2
     event.setDoubleValueField(.tabletEventRotation, value: degrees)
     ```
     Apply modifier flags, post `.cghidEventTap`.
   - **0x13 StylusSqueeze** — if `(packet.x, packet.y)` is a valid normalized coordinate (both in 0…1), map it to display pixels and warp the cursor there; on phase `0x00` synthesize a right-click (`rightMouseDown`, then `rightMouseUp` after 10 ms) to summon the context brush HUD directly under the pen hover point.
   - **0x14 StylusDoubleTap** — atomic key press (§2.3): keycode 14 (E, Eraser) + active modifiers, down + up (40 ms).
   - **0x20 KeyShortcut** — atomic key press: `CGKeyCode(UInt8(packet.rollAngle))` + `packet.modifiers`, down + up (40 ms).
   - **0x21 KeyboardPress** — streaming key event (§2.3): `CGEvent(keyboardEventSource: eventSource, virtualKey: CGKeyCode(UInt8(packet.rollAngle)), keyDown: packet.phase == 0x00)`, flags from `mapModifiers(packet.modifiers)`; `0x01` → post keyDown again (repeat); `0x03` → synthesize keyUp. Maintain a down-state dictionary per keycode so a missed keyUp can never leave a stuck key.
   - **0x40 CustomGesture** — read `GestureID = packet.modifiers`; execute via `GestureMapper.shared.action(for: id)`.
4. **GestureMapper.swift** — `[UInt16: GestureAction]` persisted in `UserDefaults` as JSON; `enum GestureAction { case keyMacro([(CGKeyCode, CGEventFlags)]); case runScript(URL, [String]) }`; default map: 1 → Cmd+Tab, 2 → Dark-Mode toggle (`osascript`), 3 → open Terminal. Editable from the menu-bar settings window (TASK 10 wiring).

**Verification:** builds in Gate 2; runtime behaviors in Gate 4.

---

### TASK 3 — TCP Control Channel & E2EE Handshake

**Files:** `MacHost/TCPServer.swift`, `MacHost/SessionState.swift`, `iPadClient/TCPFileClient.swift`, `iPadClient/SessionState.swift`

**Requirements:**

1. **Mac `TCPServer.swift`** — `NWListener` with `NWParameters.tcp` on port **8889**, advertising `NWListener.Service(type: "_vpad-tcp._tcp")`; accepts exactly one active control connection (new connections replace old sessions); all work on a `.utility` serial queue.
2. **Handshake** — implement §3.1 exactly (HELLO → HELLO_ACK → READY, 5 s timeout, version check). On completion, arm the local `SessionState` and notify the UDP server to accept datagrams.
3. **SessionState (both sides)** — an `actor` holding the `SymmetricKey?`, per-direction nonce counters, `lastCounter[peer]` anti-replay state, and drop statistics. The UDP hot path reads the key and counter once per received datagram; handshake/stat mutations happen off the hot path.
4. **`TCPFileClient.swift` (iPad)** — performs the client half of the handshake, exposes the frame codec (§3.3), PING/PONG for latency measurement, and the multiplexed send path used later by TASK 9. One persistent connection carries control + file frames.
5. **Frame codec** — `[4-byte BE length][1-byte type][body]` per §3.3; after READY, every frame except none is encrypted with the session key and the TCP nonce direction discriminators (§3.4).

**Verification:** builds in Gates 2–3; Wireshark check in Gate 4 shows HELLO/HELLO_ACK/READY in clear and ciphertext-only afterward.

---

### TASK 4 — Low-Latency Encrypted UDP Transport

**Files:** `MacHost/UDPServer.swift`, `iPadClient/UDPClient.swift`

**Requirements:**

1. **Both targets** configure transport identically:

   ```swift
   let params = NWParameters.udp
   params.includePeerToPeer = true            // direct wired USB-C / AWDL zero-latency links
   params.serviceClass = .interactiveVideo    // highest-priority DSCP QoS tag
   ```

2. **Mac `UDPServer.swift`** — `NWListener(using: params)` advertising Bonjour `_vpad._udp`; per incoming connection, receive loop on `netQueue`:

   ```swift
   private func receiveNext(on connection: NWConnection) {
       connection.receiveMessage { [weak self] data, _, _, error in
           if let data,
              let packet = CryptoManager.shared.openPacket(data, direction: .clientToHost, session: SessionState.shared) {
               EventInjector.shared.inject(packet)
           }   // decrypt failure / non-armed session / replay → silent drop
           if error == nil { self?.receiveNext(on: connection) }
       }
   }
   ```

3. **iPad `UDPClient.swift`** — `NWBrowser(for: .bonjour(type: "_vpad._udp", domain: nil), using: params)`; auto-connect to the first discovered Mac endpoint; prefer the wired path via `NWPathMonitor` (`nw_interface_type_wired`). Non-blocking sender:

   ```swift
   func send(_ packet: VPadPacket) {
       // drops silently when no session key or when the outbound queue exceeds 2 pending datagrams
       connection?.send(content: CryptoManager.shared.sealPacket(packet, direction: .clientToHost), completion: .idempotent)
   }
   ```

4. UDP is **armed only after** the TASK 3 handshake completes; before that both ends drop everything.

**Verification:** builds in Gates 2–3; E2E latency/drop gate in Gate 4.

---

### TASK 5 — 240 Hz Hybrid Canvas & Gesture Split Engine (`iPadClient`)

**Files:** `HybridCanvasView.swift`, `TransientInkLayer.swift`

**Requirements:**

1. Subclass `UIView` as `CanvasTouchView` (`isMultipleTouchEnabled = true`); owns `activeRect` (§4.3).
2. **Hover & proximity — `UIHoverGestureRecognizer`:**
   - `.began` → send `0x12` phase `0x00` (StylusProximity Enter).
   - `.changed` → normalize `recognizer.location(in: self)` inside `activeRect`; read `azimuthAngle(in:)`, `altitudeAngle`, and (via `#available(iOS 17.5, *)`) `rollAngle`; compute `(tiltX, tiltY)` per §4.1; send `0x11` (StylusHover).
   - `.ended` / `.cancelled` → send `0x12` phase `0x02` (Leave).
3. **240 Hz coalesced stylus capture & palm rejection** (`touchesBegan/Moved/Ended/Cancelled`), separated by `touch.type`:
   - **`.pencil`:** set `isPencilActive = true`. If not already in proximity, send `0x12` enter first. Iterate `event?.coalescedTouches(for: touch) ?? [touch]`:
     - `preciseLocation(in: self)` → normalize to `activeRect` (§4.3).
     - Pressure: `touch.maximumPossibleForce > 0 ? Float(force / maximumPossibleForce) : 0.5`.
     - `(tiltX, tiltY)` via §4.1; `rollAngle` cast to `Float`.
     - Send `0x10` (StylusStroke) immediately (phase from the touch phase).
     - Append each point to `TransientInkLayer` — a glowing cyan vector stroke that fades out over **0.8 s** (`CABasicAnimation` on opacity).
   - **`.direct` (finger trackpad mode):**
     - **Strict palm rejection:** while `isPencilActive`, ignore all single-finger `.direct` touches.
     - 1 finger moving → `deltaX/deltaY` → `0x01` TrackpadMove.
     - 1-finger quick tap (< 180 ms, movement < 6 pt) → `0x03` pressure 1.0 (left).
     - 2-finger quick tap → `0x03` pressure 2.0 (right-click).
     - 2-finger pan → average deltas → `0x02` TrackpadScroll.
   - **≥ 3 fingers** → forward `.direct` touches to `GestureEngine` (TASK 10); do not also handle them as trackpad input (no double-handling).
4. All sends go through `UDPClient.shared.send` with the current `ModifierState` snapshot merged into `packet.modifiers`.

**Verification:** Gates 2–3; Gate 4 pressure/hover/barrel-roll items.

---

### TASK 6 — Apple Pencil Pro Squeeze, Double-Tap & Haptics (`iPadClient`)

**File:** `PencilProManager.swift`

**Requirements:**

1. `final class PencilProManager: NSObject, UIPencilInteractionDelegate`; attach `UIPencilInteraction(delegate: self)`; initialize `UICanvasFeedbackGenerator(view: canvasView)`.
2. **Squeeze** — `pencilInteraction(_:didReceiveSqueeze:)`, on `squeeze.phase == .began`:
   - Physical barrel haptic: `feedbackGenerator?.alignmentOccurred(at: squeeze.hoverPose?.location ?? .zero)`.
   - Extract normalized `(normX, normY)` and `rollAngle` from `squeeze.hoverPose`.
   - User mode **Mac Right-Click HUD** → send `0x13` (StylusSqueeze, phase `0x00`).
   - User mode **Local iPad Radial Palette** → `@Published var radialMenuCenter: CGPoint? = squeeze.hoverPose?.location` so WorkspaceView renders the tool switcher under the hovered pen tip.
3. **Double-tap** — `pencilInteraction(_:didReceiveTap:)`:
   - `feedbackGenerator?.pathCompleted(at: tap.hoverPose?.location ?? .zero)`.
   - Send `0x14` (StylusDoubleTap, phase `0x00`).

**Verification:** Gate 3 (17.5 symbols link); Gate 4 squeeze/haptic item.

---

### TASK 7 — Floating Modifier Sidebar & Workspace UI (`iPadClient`)

**Files:** `ModifierState.swift`, `WorkspaceView.swift`

**Requirements:**

1. **ModifierState.swift** — thread-safe singleton; `final class ModifierState: @unchecked Sendable` with an `NSLock`-protected `var activeFlags: UInt16` (Cmd `1<<0`, Shift `1<<1`, Opt `1<<2`, Ctrl `1<<3`, Space `1<<4`); expose an atomic `snapshot` for the canvas hot path.
2. **WorkspaceView.swift**
   - Dark background `#121214`; visible **16:10 border `#2C2C30`** matching the Mac `activeRect` boundary (§4.3).
   - Dockable left/right **Modifier Sidebar** with momentary press-and-hold buttons via `DragGesture(minimumDistance: 0)`: press sets the bit in `ModifierState.shared.activeFlags` and fires `UICanvasFeedbackGenerator.alignmentOccurred`; release clears the bit.
   - One-tap shortcut buttons sent as `0x20`: Undo (Cmd+Z, keycode 6), Redo (Cmd+Shift+Z, keycode 6), Brush `[` (keycode 33), Brush `]` (keycode 30).
   - **File drop zone** (`DropDelegate`) and transfer progress bar → triggers the TASK 9 flow.
   - **Radial HUD** rendered at `PencilProManager.radialMenuCenter` (TASK 6).
   - **Gesture settings list** — shows GestureID → action description for the TASK 10 map.

**Verification:** Gates 2–3; sidebar/shortcut items in Gate 4.

---

### TASK 8 — Keyboard Pass-Through (`iPadClient` + Mac case)

**Files:** `iPadClient/KeyboardHandler.swift`; Mac side is `EventInjector` case `0x21` (TASK 2)

**Requirements:**

1. **Hardware keyboard path** — a hidden responder view (`canBecomeFirstResponder = true`) activated by a sidebar “⌨” toggle; overrides `pressesBegan(_:with:)`, `pressesChanged`, `pressesEnded`, `pressesCancelled`:
   - Capture `key.keyCode` (HID usage — identical to macOS virtual key codes for standard keys; media/function keys go through an explicit mapping table) and `key.modifierFlags` → VPad bitmask.
   - Send `0x21` with keycode packed into `rollAngle`, modifiers in `modifiers`, phase `0x00/0x01/0x02/0x03`.
   - Auto-resign first responder while any in-app text field is editing (no double-capture); re-focus afterward.
2. **Software keyboard path** — hidden `UITextField` + delegate: on `textField(_:shouldChangeCharactersIn:)`, send `0x21` down/up pairs per character; backspace → keycode 51.
3. **Mac side** — `EventInjector` case `0x21` per TASK 2, including the stuck-key protection (down-state dictionary; `0x03` → forced keyUp).

**Verification:** Gate 4 keyboard items (typing, Cmd+C/V, no stuck keys).

---

### TASK 9 — File Transfer over Reliable TCP

**Files:** extend `MacHost/TCPServer.swift` and `iPadClient/TCPFileClient.swift`; progress UI in `WorkspaceView.swift`

**Requirements:**

1. iPad side: `UIDocumentPickerViewController(forOpeningContentTypes: [.data])` and/or the workspace drop zone selects a file → send frames per §5 (HEADER → 64 KiB CHUNKs → TRAILER) over the existing TASK 3 TCP channel, updating the progress bar per chunk.
2. Mac side: route `0x30…0x33` frames to a file handler that streams chunks to `~/Downloads/VirtualTabletUploads/<sanitized-name>` (path-traversal sanitization; UUID prefix on collision), computes SHA-256, verifies against TRAILER, replies `FILE_STATUS` (0x00 success / 0x01 mismatch / 0x02 disk error), and rejects oversized or malformed framing.
3. `FILE_ABORT`/cancellation from either side stops the transfer and cleans partial files.

**Verification:** Gate 4 file item — 500 MB video transfers with zero corruption (SHA-256 match).

---

### TASK 10 — Custom Multi-Touch Gestures & Macros

**Files:** `iPadClient/GestureEngine.swift`, `MacHost/GestureMapper.swift` (built in TASK 2, wired here), settings list in `WorkspaceView.swift`

**Requirements:**

1. **GestureEngine.swift** — lightweight gesture state machine consuming **≥ 3-finger `.direct` touches** forwarded by the canvas (1–2 finger input stays owned by TASK 5; never double-handled). Features: per-finger delta vectors, centroid path, mean inter-finger distance.
   - Built-in recognizers: 3-finger swipe left/right (centroid translation > 60 pt within 400 ms), 4-finger pinch open/close (inter-finger distance delta threshold).
   - User-defined patterns: sequence of direction tokens loaded from settings JSON.
   - 300 ms end-window debounce; on match send `0x40` (GestureID in `modifiers` field, phase `0x00`); 500 ms cooldown; phase `0x02/0x03` on gesture end/cancel.
2. **Mac side** — `GestureMapper` executes the mapped action: `.keyMacro` → keyDown/keyUp sequence via `EventInjector`; `.runScript` → `Process` (`/usr/bin/osascript` or shell). Defaults: 1 = Cmd+Tab, 2 = toggle Dark Mode, 3 = open Terminal.
3. **Settings UI** — menu-bar window (Mac) and sidebar list (iPad) edit the GestureID → action map.

**Verification:** Gate 4 gesture item (3-finger swipe triggers the mapped macro).

---

## 7. Automated Build & Verification Gates

Run sequentially; each gate must pass before the next:

| Gate | Command / Criterion |
|------|---------------------|
| **0. Protocol** | `cd Packages/VPadProtocol && swift test` — 100 % pass; `MemoryLayout<VPadPacket>.size == 28`; crypto round-trip + tamper tests pass. |
| **1. Generate** | `xcodegen generate` (prerequisite: `brew install xcodegen`) — produces `VirtualTabletPad.xcodeproj`. |
| **2. MacHost** | `xcodebuild -project VirtualTabletPad.xcodeproj -scheme MacHost -destination 'platform=macOS' build` — zero errors, zero strict-concurrency warnings. |
| **3. iPadClient** | `xcodebuild -project VirtualTabletPad.xcodeproj -scheme iPadClient -destination 'generic/platform=iOS' build` — zero errors; `UIPencilInteraction.Squeeze`, `rollAngle`, `UICanvasFeedbackGenerator` link cleanly against the iPadOS 17.5+ SDK. |
| **4. End-to-end** | Runtime checklist below, all boxes checked. |

**Gate 4 — end-to-end functional checklist:**

- [ ] **Accessibility & pairing:** prompt appears on launch; after granting, menu bar shows “Connected”; iPad auto-joins via Bonjour.
- [ ] **Proximity & pressure:** drawing in Photoshop / Clip Studio Paint produces variable stroke thickness from 0.0 to 1.0 force.
- [ ] **Hover barrel roll:** twisting Apple Pencil Pro while hovering ~5 mm above the glass rotates the calligraphy brush cursor on the Mac in real time.
- [ ] **Squeeze & haptics:** squeezing triggers a physical click inside the Pencil barrel and opens the context brush HUD on macOS.
- [ ] **Double-tap:** toggles eraser (E).
- [ ] **Trackpad:** move/click/scroll/right-click gestures behave like a Mac trackpad; Space-pan holds correctly.
- [ ] **E2EE:** Wireshark capture shows only HELLO/HELLO_ACK/READY in clear text; all UDP payloads are ciphertext; injected garbage datagrams are dropped silently.
- [ ] **Keyboard:** typing on the iPad Magic Keyboard instantly populates Mac text fields; Cmd+C/Cmd+V work; no stuck keys after rapid presses.
- [ ] **File transfer:** dragging a 500 MB video into the iPad drop zone streams it over TCP and saves it to `~/Downloads/VirtualTabletUploads/` with a verified SHA-256 (zero corruption); progress UI updates.
- [ ] **Custom gestures:** a 3-finger swipe on the iPad triggers the mapped macro on macOS.
- [ ] **Latency/drop gate:** 10-minute continuous stylus stroke → Mac STATS reports nonce-gap drop rate < 0.1 %; TCP PING RTT < 5 ms over wired USB-C, < 10 ms over Wi-Fi 6.

---

## 8. Known Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Wacom emulation is CGEvent-based; some apps probe for real tablet drivers. | Do not install third-party Wacom drivers on the Mac; validate against the Gate 4 targets (Photoshop / CSP / Blender). |
| `tabletProximityEventCapabilityMask = 0x0FFF` is best-effort emulation on macOS 14. | Treat as compatibility heuristic; keep the exact fields per TASK 2. |
| `UIKey.keyCode` → `CGKeyCode` identity holds only for standard HID keys. | Maintain an explicit mapping table for media/function keys in `KeyboardHandler`. |
| Swift 6 strict concurrency vs `NWConnection` (not Sendable). | Confine connection state to the owning serial queue inside `@unchecked Sendable` wrappers; no `@preconcurrency import`. |
| AES-GCM envelope allocation in the hot loop. | The only permitted heap allocation (§3.5), bounded to one 56-byte buffer per packet. |
| Local-network privacy prompts on iOS 14+/macOS 15 can deny Bonjour discovery. | Handle denial in UI with re-prompt instructions; document in README. |
| Pencil Pro features need real hardware. | Guard with `#available(iOS 17.5, *)` and degrade gracefully (no squeeze/roll without Pencil Pro). |

---

## Appendix A — Merge & Reconciliation Log

### A.1 Task renumbering (traceability)

| Core Edition | Enhanced Edition | Merged plan | Notes |
|--------------|------------------|-------------|-------|
| TASK 1 | — | **TASK 1** | unchanged, plus `CryptoManager` |
| TASK 2 | — | **TASK 2** | unchanged, plus `0x21`/`0x40` cases + `GestureMapper` |
| — | — | **TASK 3** | *new*: TCP control channel + ECDH handshake (both plans referenced it, neither built it) |
| TASK 3 | TASK 7 (crypto) | **TASK 4** | UDP transport built **encrypted from day one** |
| TASK 4 | — | **TASK 5** | unchanged |
| TASK 5 | — | **TASK 6** | unchanged |
| TASK 6 | — | **TASK 7** | plus drop zone / radial HUD / gesture settings |
| — | TASK 8 | **TASK 8** | keyboard pass-through |
| — | TASK 9 | **TASK 9** | file transfer (now formally framed, §5) |
| — | TASK 10 | **TASK 10** | gestures (Mac side now owned by `GestureMapper`) |

### A.2 Reconciliations

1. **Unified file tree** — the Enhanced Edition's tree dropped `HybridCanvasView`, `TransientInkLayer`, `ModifierState`, `PencilProManager`, both `Info.plist`s, and the test target; all restored in §1.1.
2. **Crypto promoted into the package (TASK 1)** — `CryptoManager` is unit-testable via `swift test` instead of being an untestable late addition; it is integrated in TASK 3/4, so no plaintext UDP milestone ever ships.
3. **TCP control channel owns the handshake (new TASK 3)** — both plans said “exchange keys over the initial TCP control socket” but never specified the listener, framing, or READY ordering; §3.1/§3.3 define them.
4. **Field mappings formalized** — `0x21` packs the keycode into `rollAngle` (consistent with `0x20`); `0x40` packs GestureID into `modifiers` (§2.2). The Enhanced Edition never said where these live in the 28-byte struct.
5. **`0x20` vs `0x21` disambiguated** — `0x20` is an atomic macro (down+up synthesized), `0x21` is streaming raw key events with repeat/cancel (§2.3).
6. **File transfer framed** — length-prefixed frames, HEADER/CHUNK/TRAILER/STATUS types, 64 KiB chunks, SHA-256 integrity trailer, filename sanitization (§5). The Enhanced Edition had no framing or integrity check despite a “zero corruption” gate.
7. **Nonce & anti-replay defined** — 4-byte direction + 8-byte counter per session, drop-on-replay, STATS drop reporting (§3.4); the “pre-cached sliding nonce” idea was replaced by this deterministic scheme.
8. **E2EE cost analysis added** (§3.5) to prove the 240 Hz loop remains fast.
9. **`project.yml` and `Info.plist` contents specified** (§1.2/§1.3) — both plans referenced the files without ever defining them.
10. **New files with clear owners** — `SessionState.swift` (both hosts) and `MacHost/GestureMapper.swift`; gesture handling split between TASK 5 (1–2 fingers) and TASK 10 (≥ 3 fingers) to prevent double-handling.
11. **Verification consolidated** into Gates 0–4 with measurable criteria, including a new latency/drop gate backed by the nonce-counter design.
12. **Risk register added** (§8).

---

## Appendix B — Quick Reference

| Item | Value |
|------|-------|
| UDP service | `_vpad._udp` |
| TCP service / port | `_vpad-tcp._tcp` / **8889** |
| Core packet / encrypted UDP datagram | 28 B / 56 B |
| TCP frame | `[4 B BE length][1 B type][body]` |
| HKDF | SHA-256, salt `"VPadSalt"`, info `"VPadSessionKey"`, 32 B |
| Nonce | 12 B = 4 B direction + 8 B counter; prefixes 1 (iPad→Mac UDP), 2 (Mac→iPad UDP), 3/4 (TCP) |
| File chunk | ≤ 64 KiB (65,536 B) |
| Uploads dir | `~/Downloads/VirtualTabletUploads/` |
| Keycodes | Z=6, E=14, `]=30`, `[=33`, Space=49, Delete=51 |
| Haptics | `alignmentOccurred` (press/squeeze), `pathCompleted` (double-tap) |
| Default gesture IDs | 1=Cmd+Tab, 2=Dark Mode, 3=Terminal |
| UI colors | bg `#121214`, 16:10 border `#2C2C30`, cyan ink trail, 0.8 s fade |
| Hot queue | `DispatchQueue(label: "com.vpad.network", qos: .userInteractive)` |
