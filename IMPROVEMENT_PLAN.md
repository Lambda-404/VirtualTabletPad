# VirtualTabletPad: Improvement Plan (for coding agents)

> Put this file in the repo root (or `docs/`) and tell your agent:
> **"Read IMPROVEMENT_PLAN.md. Do Task 0.1 first, then continue in order. Stop at every `HUMAN CHECKPOINT`."**
> The repo already has an `AGENT_PLAN.md`; read it too and reconcile (do not delete it without asking).

## 0. Context

VirtualTabletPad turns an iPad into an Apple Pencil graphics tablet and multi-touch trackpad for a Mac.

- `Packages/VPadProtocol/`: SPM library. `VPadPacket` (frozen 28-byte binary packet), `CryptoManager` (X25519 + HKDF-SHA256 + AES-GCM-256), `VPadConstants`.
- `MacHost/`: menu-bar app. `UDPServer` (port 8888, input), `TCPServer` (port 8889, control + file receive), `USBProxy` (usbmuxd), `EventInjector` (CGEvent), `AccessibilityManager`.
- `iPadClient/`: iPadOS app. `CanvasView` (240 Hz capture), `UDPClient`, `LiquidGlassWorkspace`, `TouchpadSettingsView`.
- Tooling: XcodeGen (`project.yml`), Swift 6 with strict concurrency, `Makefile` targets `test`, `build`, `run-dev`.

This plan was written from the README, not the source. **Task 0.1 verifies the assumptions.** Where a file name or behavior below differs from reality, trust the code and note the difference in `docs/PLAN_NOTES.md`.

## 1. Working agreement (applies to every task)

1. One branch per task: `agent/<task-id>-<slug>`. Small commits, imperative messages (`Add ReplayWindow with sliding bitmap`).
2. Run `make test` before every commit. Never commit with failing tests or new Swift 6 concurrency warnings.
3. Add or update tests with every behavior change. Crypto and parsing code needs tests that include malformed input.
4. Hot input path (packet encode/decode, injection loop): **no heap allocations, no locks on the main actor, no logging per packet.**
5. No new third-party dependencies without asking. Prefer CryptoKit / Foundation / Network.framework.
6. No force unwraps (`!`) or `try!` outside tests.
7. Never change the `VPadPacket` 28-byte payload layout without bumping a protocol version and asking the human first.
8. Update docs (`README.md`, `docs/`) in the same PR as the behavior change.
9. The agent cannot test Pencil hardware, USB tunnelling, or third-party painting apps. Mark those as `HUMAN CHECKPOINT` and write down exact manual test steps.
10. Never commit secrets, signing certificates, team IDs, or UDIDs.

**Stop and ask the human before:** changing wire formats, adding entitlements, touching signing or notarization settings, deleting files, or any task that fails twice.

---

## Phase 0: Hygiene

### Task 0.1: Baseline audit (do this first)
- Run `make test`, `make build`. Record results.
- Read the files listed in section 0. Write `docs/PLAN_NOTES.md` covering: actual file layout, how `VPadPacket` is laid out (field offsets), how pairing and encryption currently work, how `UDPServer` handles unknown senders, what `EventInjector` currently posts.
- List every place this plan's assumptions are wrong.
- **Done when:** `docs/PLAN_NOTES.md` exists and tests/build status is recorded. No source changes.

### Task 0.2: CI
- Add `.github/workflows/ci.yml`: on push and PR, macOS runner, install XcodeGen, run `make test` and `make build`. Cache SwiftPM.
- **Done when:** workflow file is valid and runs the same commands as local.

### Task 0.3: Lint and contribution files
- Add SwiftLint (or swift-format) config with a minimal rule set. Fix only trivial violations; do not reformat the whole repo in this PR.
- Add `CONTRIBUTING.md` (build, test, branch/commit conventions), and `.github/ISSUE_TEMPLATE/bug_report.yml` asking for macOS/iPadOS version, connection mode (USB/Wi-Fi/Direct-IP), app used, and logs.

---

## Phase 1: Security

Threat model: anyone on the same network (or able to reach the ports) must not be able to inject input, replay captured input, or write files on the Mac.

### Task 1.1: Threat model doc
- Create `docs/security.md`: assets, attackers (LAN attacker, passive sniffer, malicious paired device), what is in/out of scope, current weaknesses found in Task 0.1.

### Task 1.2: Identity keys
- In `VPadProtocol`, add a `KeyStore` protocol (`loadOrCreateIdentity()`, `forget()`), plus `IdentityKey` using `Curve25519.Signing` (Ed25519).
- Implement Keychain-backed stores in `MacHost` and `iPadClient`; an in-memory store for tests.
- **Tests:** create-then-load returns same key; two stores produce different keys.

### Task 1.3: Authenticated handshake
Proposal (the agent may adjust, but must document the final design in `docs/protocol.md`):
- Runs over TCP (port 8889) before any UDP input is accepted.
- Each side sends an ephemeral X25519 public key and its long-term Ed25519 public key. Each signs the handshake transcript hash. Each verifies the peer's signature and that the peer's long-term key is pinned/allowlisted.
- Derive two directional keys with HKDF-SHA256: salt = transcript hash, info = `"VPad v2 c2s"` / `"VPad v2 s2c"`.
- Host assigns a random 4-byte `sessionID` and returns it inside the encrypted handshake confirmation.
- **Alternative:** implement Noise `IK` if the agent judges that safer. Ask the human before choosing it.
- **Tests:** successful handshake; wrong pinned key fails; tampered transcript fails; both sides derive matching keys; known-answer test vectors checked into `Packages/VPadProtocol/Tests/`.

### Task 1.4: Session packet crypto + replay protection
- UDP frame: `sessionID (4B) | seq (8B, big-endian) | ciphertext (28B) | tag (16B)` = 56 bytes.
- AES-GCM nonce = `sessionID (4B) || seq (8B)`; direction is separated by using different keys. Never reuse a (key, nonce) pair; the sequence number must be strictly increasing per direction.
- Implement `ReplayWindow` (sliding bitmap, size 64 or 128). Reject duplicates and too-old packets.
- Rekey (new handshake) on reconnect, and before the sequence counter could wrap.
- **Tests:** in-order, reordered within window, duplicate, too old, tampered tag, wrong session ID, counter near overflow.

### Task 1.5: Pairing flow
- QR payload (versioned, e.g. base64url of a compact encoding): host address/Bonjour name, host Ed25519 public key, 16-byte one-time token, expiry timestamp.
- iPad scans, pins the host key, sends its public key + token. Host validates token (single use, expiry), then shows an approval prompt: "Allow iPad '<name>'?".
- Host stores an allowlist; add "Paired devices" and "Forget device" to the menu bar.
- Unknown or unapproved clients are dropped before any UDP input is processed.
- **Tests:** token reuse rejected; expired token rejected; approval denied leaves allowlist unchanged.

### Task 1.6: Wire it in
- Switch `UDPServer`/`UDPClient`/`TCPServer` to the new session layer. Remove the old unauthenticated path (or gate it behind an explicit `#if DEBUG`).
- In USB mode, bind only to the link-local/USB interface.
- Keep the "reject second client" session lock.
- **HUMAN CHECKPOINT:** pair a real iPad over Wi-Fi and USB; confirm an unpaired device cannot move the cursor.

### Task 1.7: File transfer hardening
- Sanitize incoming filenames (strip path components, reject `..`, absolute paths, control chars), enforce a max size, write into a dedicated folder, require user confirmation, keep SHA-256 verification.
- **Tests:** path traversal names, oversize files, hash mismatch.

### Task 1.8: Parser robustness
- Add malformed-input tests (random bytes, truncated frames, wrong lengths) for the packet decoder and handshake parser. Add a simple fuzz-style loop test (seeded random inputs) that runs in `make test`.

---

## Phase 2: Tablet event fidelity on macOS

### Task 2.1: Make injection testable
- Introduce `protocol EventPosting { func post(_ event: CGEvent) }` so `EventInjector` can be unit-tested with a recording fake.

### Task 2.2: Tablet fields and proximity state machine
- For pen input, post mouse `CGEvent`s with the tablet subtype and set pressure, tilt X/Y, (and rotation if available) fields.
- Implement a proximity state machine: **enter proximity** on first hover/touch, **leave proximity** when the pen goes out of range or the client disconnects. Hover posts `mouseMoved` (tablet subtype, zero pressure).
- Verify exact `CGEventField` names against the installed SDK before use; do not guess.
- If `VPadPacket` lacks tilt or pressure fields the injector needs, **stop and ask** (see rule 7).
- **Tests (with fake poster):** event sequence for a stroke = enter proximity, down, drags, up; disconnect mid-stroke emits up + leave; pressure is clamped to 0...1.

### Task 2.3: Event inspector tool
- Add `Tools/TabletEventInspector`: a tiny macOS app (or script) with a view that logs `NSEvent.pressure`, tilt, subtype, and proximity events. Used to verify Task 2.2.
- **HUMAN CHECKPOINT:** run the inspector while drawing from the iPad.

### Task 2.4: Compatibility matrix
- Create `docs/compatibility.md` with a table: app, version, pressure works, tilt works, hover works, notes. The agent fills in the structure; the human fills in the results for Krita, Photoshop, Affinity, Clip Studio Paint, Blender, and anything else they use.

### Task 2.5 (optional, ask first): DriverKit virtual HID digitizer
- Write a feasibility note in `docs/` (entitlement requirements, effort, trade-offs). Do not implement without approval.

---

## Phase 3: Reliability and latency

### Task 3.1: Reliable state changes
- Classify events: **continuous** (position/pressure samples; loss is fine) vs **state** (pen down/up, buttons, modifiers, proximity).
- Resend state events in the next N packets until the host acknowledges (cumulative ack in a host-to-client packet).
- **Tests:** simulated loss of a pen-up packet still results in pen-up on the host.

### Task 3.2: Heartbeat and reconciliation
- Client sends a heartbeat (~100 ms) with full current state (pen down, button mask, modifier mask). Host reconciles differences by injecting the missing up/down events.

### Task 3.3: Host watchdog
- If no valid packet arrives for ~500 ms while a button, pen contact, or modifier is considered held, release everything (mouse up, key up for all held modifiers).
- **Tests:** held Command key is released after timeout; connection loss mid-stroke ends the stroke.

### Task 3.4: Connection state machine
- Explicit states: `disconnected → connecting → handshaking → active → reconnecting`. Replace ad-hoc flags. Surface the state in both UIs.
- **HUMAN CHECKPOINT:** unplug the cable mid-stroke, sleep/wake the Mac, toggle Wi-Fi. Nothing should stay stuck.

### Task 3.5: Latency benchmark
- Add ping/echo packets (client timestamp echoed by host). Add `Tools/latency-bench` that reports p50/p95/p99 round-trip time and jitter, per transport.
- Document in `docs/latency.md` exactly what is measured. The README must say "round-trip" or "touch-to-cursor" correctly.

### Task 3.6: Batch coalesced samples (optional)
- If the iPad produces multiple coalesced samples per frame, send them in one datagram. Only do this if Task 3.5 shows a benefit, and only with a protocol version bump (ask first).

---

## Phase 4: Features

Each feature gets its own branch and settings UI, with settings stored in a `Codable` struct.

### Task 4.1: Area mapping
- `MappingRegion` (rect in global display coordinates), display picker (`NSScreen`), aspect-ratio lock, rotation, left-handed mode. Assume the iPad sends normalized 0...1 coordinates (verify in Task 0.1).
- **Tests:** mapping math for multiple displays, rotation, ratio lock.

### Task 4.2: Pressure curve editor
- Cubic Bézier with two control points; precompute a 256-entry lookup table; apply it in the hot path with a table lookup only. Keep Natural/Soft/Hard as presets.
- **Tests:** monotonic output, endpoints fixed at (0,0) and (1,1).

### Task 4.3: Per-app profiles
- `Profile` (curve, mapping, shortcut layout) stored as JSON. Mac sends the frontmost app's bundle ID over the control channel (`NSWorkspace.didActivateApplicationNotification`); iPad switches profile.

### Task 4.4: Custom actions
- `enum Action { key(combo), systemAction, macro([Step]), toggleTool }`; assignable to Pencil squeeze, double-tap, and F-strip keys.

### Task 4.5: Protocol spec for other platforms
- Write `docs/protocol.md`: packet layouts, handshake, key schedule, and test vectors, complete enough for a third party to write a Windows (`InjectSyntheticPointerInput`) or Linux (`uinput`) host. Do not implement other hosts in this repo without approval.

---

## Phase 5: Release and presentation

### Task 5.1: README rewrite
- Replace "military-grade" with the actual algorithms. Add a "How this differs from Sidecar / Universal Control / Astropad / Duet" section (leave claims the agent cannot verify as `TODO(human)`), a troubleshooting section, and links to `docs/`.
- Keep `README_ZH.md` in sync (translate the changes).

### Task 5.2: Release workflow
- `.github/workflows/release.yml`: on tag `v*`, build, archive, package a `.dmg`, attach to a GitHub Release. Signing and notarization steps read secrets from GitHub Actions secrets and are skipped with a clear message when secrets are absent.
- **HUMAN CHECKPOINT:** the human supplies Developer ID certificates and `notarytool` credentials.

### Task 5.3: Distribution extras (optional)
- Homebrew cask file, Sparkle update feed, TestFlight notes. Draft only; ask before enabling.

---

## Suggested order

`0.1 → 0.2 → 0.3 → 1.1 → 1.2 → 1.3 → 1.4 → 1.5 → 1.6 → 1.7 → 1.8 → 2.1 → 2.2 → 2.3 → 3.1 → 3.2 → 3.3 → 3.4 → 3.5 → 4.x → 5.x`

## Progress log (agent updates this section)

| Task | Status | PR/Branch | Notes |
|------|--------|-----------|-------|
| 0.1  | done   | agent/0.1-baseline-audit | Baseline audit complete; docs/PLAN_NOTES.md created |
| 0.2  | done   | agent/0.2-ci | GitHub Actions CI workflow added (.github/workflows/ci.yml) |
| 0.3  | done   | agent/0.3-lint-and-contrib | Added .swiftlint.yml, CONTRIBUTING.md, and bug_report.yml |
| 1.1  | done   | agent/1.1-threat-model | Threat model documented in docs/security.md |
| 1.2  | done   | agent/1.2-identity-keys | Added IdentityKey, KeyStore protocols, InMemory/Keychain stores, unit tests |
| 1.3  | done   | agent/1.3-authenticated-handshake | Mutual authenticated handshake, docs/protocol.md, directional HKDF keys |
| 1.4  | done   | agent/1.4-session-crypto-replay | 56B V2 UDP datagram, ReplayWindow sliding bitmap, anti-replay tests |
| 1.5  | done   | agent/1.5-pairing-flow | PairingPayloadV2, PairingTokenManager single-use tokens, DeviceAllowlist |
| 1.6  | done   | agent/1.6-wire-in | Wired V2 session crypto, allowlist, single-use tokens, UI paired list |
| 1.7  | done   | agent/1.7-file-hardening | FileReceiver hardened, path traversal blocked, user confirmation dialog |
| 1.8  | done   | agent/1.8-parser-robustness | Parser robustness tests & 2000-iteration seeded PRNG fuzz loop |
| 2.1  | done   | agent/2.1-testable-injection | EventPosting protocol, MockEventPoster, deterministic EventInjector, MacHostTests |
