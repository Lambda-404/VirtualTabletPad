# VirtualTabletPad Threat Model & Security Specification

This document defines the security architecture, threat model, trust boundaries, attack vectors, and mitigation strategy for VirtualTabletPad (Phase 1, Task 1.1).

---

## 1. Protected Assets

VirtualTabletPad controls macOS input devices and facilitates local file transfers from an iPad. Compromising these channels gives an attacker substantial access to the host machine:

1. **System Pointer & Keystroke Injection**:
   - `EventInjector` synthesizes low-level macOS `CGEvent`s (mouse movements, clicks, trackpad scrolls, stylus strokes with pressure/tilt, keyboard presses, system hotkeys).
   - Arbitrary event injection enables full system control, terminal command execution, or sensitive data access.
2. **AppleScript & Macro Execution**:
   - Custom gesture packets (`0x40`) trigger user-configured AppleScript scripts and macro sequences via `GestureMapper`.
3. **Local File System Integrity**:
   - `FileReceiver` receives chunked files over TCP port 8889 and writes them to disk (`~/Downloads` or `$VPAD_UPLOADS_DIR`).
   - Path traversal or unchecked file writing could overwrite system files or install malicious payloads.
4. **User Privacy & Telemetry Confidentiality**:
   - Real-time Apple Pencil strokes, pressure dynamics, handwritten notes, drawings, and virtual keyboard keystrokes transmitted over the network must remain confidential.

---

## 2. Threat Actors & Attack Vectors

### 2.1 Passive LAN Eavesdropper
- **Capabilities**: Captures raw 802.11 Wi-Fi frames or Ethernet traffic on the local subnet.
- **Goal**: Reconstruct user drawings, trackpad interactions, keystrokes, or transferred files.
- **Threat Mitigation**: End-to-end authenticated encryption (E2EE) with AES-GCM-256 for all TCP frames and UDP datagrams.

### 2.2 Active LAN Attacker (Man-In-The-Middle)
- **Capabilities**: Capable of ARP spoofing, DNS poisoning, packet injection, dropping, and modifying TCP/UDP streams on the local network.
- **Goal**: Intercept ephemeral key agreement to inject malicious input or intercept sensitive data.
- **Threat Mitigation**: Mutual cryptographic authentication. Each device maintains a long-term Ed25519 identity key. Handshake transcript hashes are signed and verified against pinned/approved keys.

### 2.3 Replay Attacker
- **Capabilities**: Records valid encrypted UDP datagrams or TCP frames transmitted over the network and resends them at a later time.
- **Goal**: Re-inject previous clicks, mouse movements, or keystroke shortcuts.
- **Threat Mitigation**: Directional nonces combined with an anti-replay sliding bitmap window (`ReplayWindow`). Packets with duplicate or stale sequence numbers are dropped before cryptographic processing.

### 2.4 Rogue or Unpaired Device
- **Capabilities**: Any computer or mobile device on the same local subnet capable of reaching TCP port 8889 or UDP port 8888.
- **Goal**: Connect to MacHost without authorization and send spurious input commands.
- **Threat Mitigation**:
  - Pairing QR flow requiring a short-lived one-time pairing token and out-of-band Ed25519 public key pinning.
  - Interactive approval prompt on MacHost before any new client is added to the persistent Keychain allowlist.
  - Strict rejection of all unapproved connections.

### 2.5 Denial of Service (DoS) / Flooding Attacker
- **Capabilities**: Floods UDP port 8888 with forged 56-byte datagrams.
- **Goal**: Exhaust CPU cycles on MacHost by forcing repeated AES-GCM tag verification on the high-priority `com.vpad.network` queue.
- **Threat Mitigation**:
  - Incorporate a 4-byte random `sessionID` prefix in the UDP datagram envelope.
  - Validate `sessionID` in constant-time before performing AES-GCM decryption; drop non-matching datagrams with zero cryptographic overhead.
  - Restrict UDP processing strictly to link-local / USB interfaces when operating in wired USB mode.

---

## 3. Trust Boundaries & Scope

### In Scope
- Local Wi-Fi network communication (Bonjour / multicast UDP / TCP).
- Direct-IP and link-local cable connections.
- Raw USB tunneling via `usbmuxd` (`USBProxy`).
- Cryptographic identity generation and persistent storage in the Apple Keychain.
- Handshake protocol, session key derivation, and envelope layout.
- Path sanitization and size enforcement for received files.

### Out of Scope
- Physical compromise of the Mac or iPad hardware.
- Malware already running with `root` or `TCC` Accessibility privileges on macOS.
- Compromise of the iOS application sandbox or operating system kernel.

---

## 4. Current Vulnerabilities & Weaknesses (Task 0.1 Audit)

1. **Unauthenticated Handshake**:
   - The current Protocol v1 handshake relies on unauthenticated ephemeral X25519 key exchange without digital signatures. An active attacker on the LAN can execute a Man-In-The-Middle (MITM) attack, establishing independent sessions with both the iPad and Mac.
2. **Missing Pairing Authorization & Pinning**:
   - The current pairing QR code displays only the Mac's IP and ports. It contains no cryptographic token, no public key fingerprint, and no expiration timestamp.
   - Any client that discovers the Mac over Bonjour or scans the subnet can connect and receive a session key without the Mac user being prompted or approving the device.
3. **Absence of Host Allowlist**:
   - MacHost does not maintain a trusted device allowlist in the Keychain; it accepts any incoming client that completes the ephemeral X25519 exchange.
4. **UDP Envelope Lacks Session Identifier**:
   - In Protocol v1, the 56-byte datagram format is `direction (4B) | counter (8B) | ciphertext (28B) | tag (16B)`.
   - Lacking a `sessionID`, any incoming 56-byte packet causes an AES-GCM tag verification attempt against the current session key on the `com.vpad.network` queue, leaving MacHost vulnerable to CPU exhaustion from packet floods.
5. **Rigid Replay Check Lacks Sliding Window**:
   - Protocol v1 enforces `metadata.counter > lastUDPCounter`. Any legitimate packet that arrives out of order due to Wi-Fi jitter is discarded permanently.
6. **File Transfer Traversal Hardening**:
   - Incoming file paths must be strictly checked against directory traversal (`..`), absolute root paths, null bytes, and dangerous extensions before saving.

---

## 5. Security Architecture Roadmap (Phase 1 Tasks)

1. **Task 1.2 (Identity Keys)**: Generate and store long-term Ed25519 (`Curve25519.Signing`) identity keys in the macOS and iOS Keychains.
2. **Task 1.3 (Authenticated Handshake)**: Implement mutual authentication using Ed25519 signatures over the ephemeral X25519 handshake transcript hash.
3. **Task 1.4 (Envelope & ReplayWindow)**: Transition UDP datagram to `sessionID (4B) | seq (8B) | ciphertext (28B) | tag (16B)` with a 128-bit sliding bitmap `ReplayWindow`.
4. **Task 1.5 (Pairing Flow)**: Deploy versioned QR code with host Ed25519 key, 16-byte one-time token, and expiration timestamp, coupled with an interactive approval prompt on the Mac and Keychain allowlist storage.
5. **Task 1.6 (Wire It In)**: Connect servers to the new security layer and gate/remove unauthenticated paths.
6. **Task 1.7 (File Hardening)**: Enforce strict filename sanitization, traversal prevention, and maximum transfer limits.
7. **Task 1.8 (Parser Robustness)**: Add comprehensive fuzzing and malformed-input test suites to `make test`.
