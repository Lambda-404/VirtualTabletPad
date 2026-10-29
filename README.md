<p align="center">
  <img src="docs/app-icon.png" width="120" height="120" alt="VirtualTabletPad Logo" />
</p>

<h1 align="center">VirtualTabletPad</h1>

<p align="center">
  <strong>Transform your iPad into a high-precision Apple Pencil graphics tablet & multi-touch trackpad for Mac</strong>
</p>

<p align="center">
  <a href="#key-features">Features</a> •
  <a href="#screenshots">Screenshots</a> •
  <a href="#quick-start">Quick Start</a> •
  <a href="#connection-modes">Connections</a> •
  <a href="#architecture">Architecture</a> •
  <a href="#requirements">Requirements</a> •
  <a href="README_ZH.md">简体中文</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2014%2B%20%7C%20iPadOS%2017.5%2B-blue?style=flat-square" alt="Platform" />
  <img src="https://img.shields.io/badge/Swift-6.0-orange?style=flat-square&logo=swift" alt="Swift" />
  <img src="https://img.shields.io/badge/RTT-~1.4ms%20(USB)-brightgreen?style=flat-square" alt="RTT" />
  <img src="https://img.shields.io/badge/Security-E2EE%20(AES--GCM--256)-blueviolet?style=flat-square" alt="Security" />
  <img src="https://img.shields.io/badge/License-GPL--3.0-blue?style=flat-square" alt="License" />
</p>

---

**VirtualTabletPad** is an open-source productivity app that turns your iPad into an Apple Pencil graphics tablet and multi-touch trackpad for your Mac.

It features ultra-low round-trip latency **USB-C connectivity** (~1.4 ms RTT, no Wi-Fi or local network needed), automatic **Wi-Fi Bonjour discovery**, full support for **Apple Pencil Pro hardware gestures** (squeeze, barrel roll, hover, haptic feedback), and end-to-end encryption (E2EE). See [docs/latency.md](docs/latency.md) for full latency pipeline details.

<p align="center">
  <img src="docs/ipad-simulator.png" width="58%" alt="iPadOS 27 Simulator (iPad Pro 13-inch M5) running the Liquid Glass Workspace" style="border-radius: 8px;" />
  <img src="docs/settings-merged.png" width="39%" alt="Unified Settings Center · Pencil tab" style="border-radius: 8px;" />
</p>

---

## 🌟 Key Features

### 1. 🎨 Apple Pencil & Professional Tablet Engine
* **240 Hz Coalesced Capture**: Zero perceptible latency drawing powered by `UIEvent.coalescedTouches` and predictive local transient ink rendering.
* **Apple Pencil Pro Hardware Extensions**:
  * **Barrel Roll**: Synchronizes pen barrel orientation (`rollAngle`) in real-time.
  * **Squeeze & Double-Tap**: Triggers the contextual Radial Palette HUD with crisp haptic feedback.
  * **Hover & Tilt**: High-precision cursor hover preview, altitude, and azimuth tilt detection.
* **Hardware-grade Stabilization & Pressure Curves**: 0–100% dynamic tremor filtering; configurable pressure mapping (Natural, Soft, Hard).
* **Stylus-Only Palm Rejection**: Smart rejection of inadvertent palm touches during drawing sessions.

### 2. ⚡ Ultra-Low Latency: Raw USB-C & Seamless Wireless
* **Raw USB-C Cable (Recommended)**:
  * Leverages native `usbmuxd` TCP tunneling with round-trip time (RTT) as low as **1.4 ~ 1.8 ms** (yielding **~9–14 ms** touch-to-cursor latency on 120 Hz ProMotion displays; see [docs/latency.md](docs/latency.md)).
  * True plug-and-play without network configuration, IP routing, or Wi-Fi dependencies.
* **Wi-Fi / AWDL Bonjour Discovery**: Auto-detects Mac hosts on your local network.
* **QR Pairing**: Generate an instant pairing QR code from the Mac menu bar to connect your iPad camera.
* **Smart Reconnect & Session Lock**: Host automatically rejects secondary client collisions to maintain session stability.

### 3. 🖐️ Virtual Trackpad with Dual-Mode Gesture Engine
* **Native 1–5 Finger Gestures**: Point, click, two-finger natural scrolling, right-click, three-finger drag/lookup, and four/five-finger Mission Control.
* **Dual-Mode Gesture Safety**:
  * **Guided Access Mode**: Turns iPad into a dedicated full-screen trackpad with iPadOS edge swipes disabled.
  * **Safe Mode**: Adds safety borders, inset edge scrub tracks, and hot corners to prevent accidental iPadOS app-switching.
* **Touchpad Feel Tuning**: Configurable pointer curves, precision mode, jitter reduction, and hold-to-drag thresholds.

### 4. 🪟 Liquid Glass Workspace & Touch Bar Strip
* **16:10 Active Canvas**: Proportions matched to your Mac display, framed by a comfortable 12pt bezel.
* **Integrated Touch Bar Top Strip**:
  * **F1–F12 Function Keys**: Controls brightness, Mission Control, App Exposé, Spaces, Launchpad, and media/volume.
  * **Modifier Key Island**: Persistent sticky toggles for `Command`, `Option`, `Control`, `Shift`, and `Space`.
  * **Creative Controls**: Quick Undo/Redo, brush size increments, and software keyboard triggers.
* **Adaptive Keyboard Mode**: Auto-collapses into a dual-row F-key and modifier strip whenever typing is required.

### 5. 🔒 Cryptographic Security & Zero-Allocation Transport
* **Ed25519 + X25519 + HKDF-SHA256 + AES-GCM-256**: Mutual cryptographic identity authentication, ephemeral session key exchange, directional key schedules, and 128-bit AEAD tags ensure all input and control data are tamper-proof and confidential.
* **Frozen 28-Byte Binary Packet (`VPadPacket`)**: Zero heap allocations in the 240 Hz hot input loop; built-in 64-packet sliding window anti-replay verification.

### 6. 📁 Drag & Drop File Transfer
* Send files between iPad and Mac directly with encrypted chunk streaming and SHA-256 verification.

---

## ⚖️ How VirtualTabletPad Compares

VirtualTabletPad focuses exclusively on **input digitization and gesture control** rather than compressed video display streaming.

| Feature / Solution | VirtualTabletPad | Apple Sidecar | Universal Control | Astropad Studio | Duet Display |
|---|:---:|:---:|:---:|:---:|:---:|
| **Primary Goal** | Graphics Tablet & Trackpad | Screen Extension | Cursor Sharing | Graphics Tablet | Second Display |
| **Video Stream Overhead** | **None** (Draw on Mac screen) | High (H.264/HEVC) | None | High (Proprietary video) | High (Virtual display) |
| **Apple Pencil Pro Support** | **Full** (Roll, Squeeze, Haptics) | Basic pressure/tilt | None (iPad apps only) | [TODO(human): verify Pencil Pro roll support] | Basic |
| **Input Protocol & Sampling** | 240 Hz Coalesced UDP (E2EE) | System IPC | System IPC | Proprietary TCP/USB | Proprietary |
| **Round-Trip Latency (USB)** | **~1.4 ms** (see [docs/latency.md](docs/latency.md)) | ~15–30 ms (video RTT) | ~5–12 ms | [TODO(human): benchmark Astropad RTT] | ~20–40 ms |
| **Custom Curves & Area Mapping** | **Yes** (Bézier LUT & Displays) | No | No | Yes | Limited |
| **Multi-Touch Trackpad Mode** | **Yes** (1–5 finger gestures) | No | No | No | Limited |
| **License & Privacy** | **Open Source (GPL-3.0)** | Closed source | Closed source | Proprietary Subscription | Proprietary Subscription |

---

## 📚 Technical Documentation

Deep dive into the underlying protocols, benchmarking, and architectural specifications:

- [Protocol Specification (v2)](docs/protocol.md): Complete wire format, 56-byte UDP datagram envelope, 28-byte `VPadPacket` layout, Windows `InjectSyntheticPointerInput`, and Linux `uinput` implementation notes.
- [Latency Benchmark & Pipeline](docs/latency.md): RTT vs glass-to-glass touch-to-cursor analysis and `Tools/latency-bench` loopback harness.
- [Security Architecture & Threat Model](docs/security.md): Mutual authentication, sliding window replay protection, file transfer sandbox, and parser fuzz testing.
- [Application Compatibility Matrix](docs/compatibility.md): Tested compatibility with Photoshop, Clip Studio Paint, Krita, Blender, Illustrator, and Affinity Designer.
- [DriverKit Virtual HID Feasibility](docs/driverkit_feasibility.md): Architectural analysis of `IOUserHIDEventDriver` vs `CGEvent` synthetic injection.

---

## 🔧 Troubleshooting & FAQ

#### 1. Mac does not respond to Pencil or touch input
- Ensure Accessibility permissions are granted in **System Settings → Privacy & Security → Accessibility** for `VirtualTabletPad`.
- To completely reset Accessibility permissions:
  ```bash
  tccutil reset Accessibility com.vpad.MacHost
  ```
- Restart the MacHost app after re-granting permission.

#### 2. USB connection shows "Disconnected"
- Check that the USB-C cable supports data transfer (not a charge-only cable).
- Ensure the iPad shows the trust dialog when plugged in and select "Trust this Computer".
- VirtualTabletPad will automatically detect the link-local `169.254.x.x` address or `usbmuxd` tunnel.

#### 3. Wi-Fi connection fails to discover host
- Ensure both Mac and iPad are connected to the same Wi-Fi subnet or VLAN.
- Verify your Mac's firewall is not blocking incoming UDP packets on port `8888` and TCP packets on port `8889`.
- If Bonjour discovery is blocked on managed corporate networks, use **USB-C Cable Mode** or direct QR code pairing.

#### 4. Hand tremors or unexpected palm touches
- Enable **Pen-only input (palm rejection)** in the Pencil tab to reject all capacitive finger touches while using the stylus.
- Adjust the **Stabilization** slider to smooth high-frequency hand tremors.

---

## 📸 Screenshots

All screenshots below were captured on the latest **iPadOS 27 Simulator (iPad Pro 13-inch M5)**; the hero images above show the simulated Liquid Glass Workspace and the Pencil tab of the unified Settings Center.

<table style="width:100%; text-align:center;">
  <tr>
    <td width="50%">
      <img src="docs/ipad-liquid-radial.png" alt="Radial Palette HUD" />
      <br /><b>Pencil Pro Squeeze Radial Tool Palette</b>
    </td>
    <td width="50%">
      <img src="docs/function-pad.png" alt="Function Pad" />
      <br /><b>F1–F12 & Mac System Action Controls</b>
    </td>
  </tr>
  <tr>
    <td width="50%">
      <img src="docs/touchpad-settings-top.png" alt="Touchpad Settings · Presets and Motion Curve" />
      <br /><b>Touchpad Settings · Quick Presets & Motion Curve</b>
    </td>
    <td width="50%">
      <img src="docs/touchpad-settings.png" alt="Touchpad Settings · Feel, Scroll and Appearance" />
      <br /><b>Touchpad Settings · Feel, Scroll & Appearance</b>
    </td>
  </tr>
  <tr>
    <td width="50%">
      <img src="docs/connection-sheet.png" alt="Connection Settings · Transport" />
      <br /><b>Connection Settings · Bonjour / USB / Direct-IP</b>
    </td>
    <td width="50%">
      <img src="docs/ipad-liquid-direct.png" alt="Direct-IP Connection" />
      <br /><b>Direct-IP Link (USB-C / Ethernet)</b>
    </td>
  </tr>
  <tr>
    <td width="50%">
      <img src="docs/keyboard-layout.png" alt="Adaptive Keyboard Mode" />
      <br /><b>Adaptive Dual-Row Function & Modifier Strip</b>
    </td>
    <td width="50%">
      <img src="docs/pairing-qr.png" alt="Mac QR Code Pairing" />
      <br /><b>Instant QR Pairing via Mac Menu Bar</b>
    </td>
  </tr>
</table>

---

## 🛠️ System Requirements

| Component | Minimum | Recommended |
|:---|:---|:---|
| **Mac (Host)** | macOS 14.0 (Sonoma) or later | macOS 15+ / Apple Silicon (M Series) |
| **iPad (Client)** | iPadOS 17.5 or later | iPad Pro / iPad Air (Apple Pencil Pro / 240Hz ProMotion) |
| **Stylus** | Apple Pencil (1st/2nd Gen, USB-C) | Apple Pencil Pro (Hover, Squeeze, Barrel Roll, Haptics) |
| **Connection** | Wi-Fi / AWDL local network | Direct USB-C cable (~1.4 ms latency) |

---

## 🚀 Quick Start

### 1. Build and Run Mac Host

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Swift 6 with strict concurrency.

```bash
# 1. Clone repository
git clone https://github.com/Lambda-404/VirtualTabletPad.git
cd VirtualTabletPad

# 2. Run test suite (all 25 tests pass)
make test

# 3. Generate Xcode project & build MacHost
make build

# 4. Launch Mac host in development mode
make run-dev
```

> **Permissions on first launch**:
> - **Accessibility**: Required to inject pointer, click, and keyboard `CGEvent`s.
> - **Local Network**: Required for Bonjour host discovery.

### 2. Deploy to iPad

#### Option A: Xcode Deployment (Recommended)
1. Open `VirtualTabletPad.xcodeproj`.
2. Select the `iPadClient` scheme.
3. In `Signing & Capabilities`, choose your Apple Development Team (free personal accounts supported).
4. Connect your iPad, select it as destination, and press **Run**.

#### Option B: Command Line Deployment
```bash
UDID=<your-iPad-UDID>
TEAM=<your-Apple-Development-Team-ID>

# Build and sign
xcodebuild -project VirtualTabletPad.xcodeproj -scheme iPadClient -configuration Debug \
  -destination "platform=iOS,id=$UDID" -derivedDataPath /tmp/VPadBuild \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic build

# Install and launch
xcrun devicectl device install app --device "$UDID" /tmp/VPadBuild/Build/Products/Debug-iphoneos/VirtualTabletPad.app
xcrun devicectl device process launch --device "$UDID" com.vpad.iPadClient
```

> **Note**: For self-signed apps, navigate to **Settings → General → VPN & Device Management** on your iPad and trust your certificate. Ensure **Developer Mode** is turned on in **Settings → Privacy & Security**.

---

## 🔌 Connection Modes

### 1. USB-C Cable Mode (Recommended, ~1.4 ms)
1. Connect Mac and iPad with a USB-C cable.
2. In VirtualTabletPad on iPad, open **Settings → Connection** and select **USB Cable**.
3. The app establishes a point-to-point link via usbmuxd / link-local (169.254.x.x). The status pill displays `Cable` with latency typically around **1.4–1.8 ms**.

### 2. Wi-Fi / AWDL Wireless Mode
1. Ensure both devices are on the same Wi-Fi network.
2. On your Mac, click the menu bar icon and select **Pair iPad…**.
3. On your iPad, tap **Scan QR** in the connection sheet and aim at your Mac screen.

---

## 💡 Pro Tip: Guided Access for Seamless Gestures

To prevent iPadOS system edge gestures (such as swiping up to go home) from interfering with trackpad usage:

1. Go to iPad **Settings → Accessibility → Guided Access**, enable it, and enable the Accessibility Shortcut.
2. Open VirtualTabletPad, then **triple-click the Power / Top button** to start Guided Access.
3. The app automatically transitions to **Full Native Mode**:
   - Safety outlines and corner hot-zones hide automatically.
   - All 1- to 5-finger native gestures work without triggering iPadOS system navigation!

---

## 🏗️ Architecture

```text
VirtualTabletPad/
├── Packages/VPadProtocol/        # Core protocol library (SPM)
│   ├── VPadPacket.swift          # Frozen 28-byte binary packet (Zero heap allocation)
│   ├── CryptoManager.swift       # X25519 + HKDF + AES-GCM-256 encryption engine
│   └── VPadConstants.swift       # Event codes, bitmasks, ports
├── MacHost/                      # macOS menu-bar host
│   ├── UDPServer.swift           # UDP 8888 input decryption loop (QoS: userInteractive)
│   ├── TCPServer.swift           # TCP 8889 control channel & file receiver
│   ├── USBProxy.swift            # Native usbmuxd USB tunnel bridge
│   ├── EventInjector.swift       # CGEvent pointer, stylus, and keyboard injector
│   └── AccessibilityManager.swift# Permission check and polling
└── iPadClient/                   # iPadOS client app
    ├── LiquidGlassWorkspace.swift# Liquid Glass 16:10 canvas & Touch Bar UI
    ├── CanvasView.swift          # 240Hz stylus & touch capture engine
    ├── UDPClient.swift           # Encrypted high-frequency UDP sender
    └── TouchpadSettingsView.swift# Configurable touchpad & pencil sensitivity
```

---

## 📄 License

VirtualTabletPad is released under the [GNU General Public License v3.0 (GPL-3.0)](LICENSE).

You are free to use, modify, and study this project. Any derivative works or distributions containing code from this project must also be open-sourced under the GPL-3.0 license. Issues and Pull Requests are warmly welcome!
