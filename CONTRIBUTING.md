# Contributing to VirtualTabletPad

Thank you for contributing to VirtualTabletPad! This document outlines development guidelines, conventions, and requirements.

---

## 1. Development Environment

- **macOS**: 14.0 (Sonoma) or newer.
- **Xcode**: 15.4 or 16.0+ (targeting Swift 6 / Swift 5.10 with strict concurrency).
- **XcodeGen**: Project generation is managed by XcodeGen (`project.yml`).
- **Target OS Versions**:
  - MacHost: macOS 14.0+
  - iPadClient: iPadOS 17.5+

---

## 2. Common Build & Test Targets

The root `Makefile` provides standard targets:

```bash
make test             # Run VPadProtocol unit test suite
make build            # Regenerate project and build MacHost Release bundle into build/
make run-dev          # Run MacHost in dev mode (uploads staged in build/vpad_uploads)
make ipad-build       # Build iPadClient for iOS Simulator
make ipad-device-build# Compile-check iPadClient for generic iOS device
make clean            # Clean build artifacts and /tmp caches
```

---

## 3. Working Agreement & Engineering Conventions

1. **Branching**:
   - One branch per task: `agent/<task-id>-<slug>` or `feature/<slug>` / `fix/<slug>`.
   - Keep commits small, focused, and cohesive.
2. **Commit Messages**:
   - Use imperative mood in the subject line (e.g., `Add ReplayWindow with sliding bitmap`).
3. **Testing Discipline**:
   - Run `make test` before every commit.
   - Never commit with failing tests or new Swift 6 concurrency warnings.
   - Add unit tests for every protocol, crypto, and parsing change, including malformed and truncated inputs.
4. **Hot Input Path Requirements**:
   - The 240 Hz stylus and trackpad packet loop must have:
     - **No heap allocations** (the only allowed allocation is the fixed 56-byte encrypted datagram).
     - **No locks on the main actor** (network I/O runs on a dedicated high-priority serial queue).
     - **No per-packet logging**.
5. **Dependencies**:
   - Do not add third-party dependencies without explicit human approval.
   - Prefer Apple standard frameworks (`CryptoKit`, `Network.framework`, `Foundation`).
6. **Code Safety**:
   - No force unwraps (`!`) or `try!` outside unit tests.
7. **Protocol Compatibility**:
   - Never modify the frozen 28-byte `VPadPacket` payload layout without bumping the protocol version and obtaining human alignment first.
8. **Documentation**:
   - Update `README.md` and `docs/` in the same pull request as any behavior or protocol change.
9. **Secrets**:
   - Never commit signing identities, certificates, provisioning profiles, Team IDs, or UDIDs.
10. **Human Checkpoints**:
    - Stylus hardware verification (Apple Pencil Pro haptics, barrel roll, squeeze), physical USB-C usbmuxd links, and manual painting app validations require human verification.
