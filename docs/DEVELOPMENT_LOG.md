# VirtualTabletPad — macOS Host + iPad Client

<img src="docs/app-icon.png" width="128" alt="VirtualTabletPad app icon">

Full implementation of [`AGENT_PLAN.md`](AGENT_PLAN.md): an encrypted Apple Pencil
graphics tablet and virtual trackpad that turns an iPad into an input device for a Mac.

<p>
<img src="docs/ipad-simulator.png" width="58%" alt="iPadOS 27 Simulator (iPad Pro 13-inch M5) running the Liquid Glass workspace">
<img src="docs/settings-merged.png" width="40%" alt="Unified Settings center (Pencil tab)">
</p>

The iPadOS 26+ workspace is a **graphics-tablet slab** under a **Touch Bar-style top
strip**. The strip contains connection, file, keyboard, Function Pad, Settings,
modifiers, undo/redo and brush −/+ in padded groups with 46pt touch targets. The
slab has a visible bezel, a rounded 16:10 active area matching the Mac screen, and
the **same corner radius and width as the strip**. An **Apple Pencil status box**
sits at the strip's right edge; tapping it opens the Pencil feel settings.

When the software keyboard appears, the tablet surface is replaced by a compact
**Keyboard Mode** panel and a two-row F-key/modifier/system strip above the
keyboard. The tiny, unusable canvas and its safe-mode hot zones are not shown while
typing; the tablet slab returns as soon as the keyboard hides. There is no
glass-on-glass, no full-screen fog, and no 1px cyan frame. iPadOS 17.5 still gets
the legacy HStack layout as a fallback.

The user-facing app name is **VirtualTabletPad** on both platforms (`PRODUCT_NAME`,
`CFBundleName` and `CFBundleDisplayName`). The Xcode target names remain `MacHost`
and `iPadClient`, and the app icon in both asset catalogs is generated from
[`virtual_tablet_pad_icon.svg`](virtual_tablet_pad_icon.svg).

## What is included

- **`Packages/VPadProtocol`** — frozen 28-byte packet, X25519 + HKDF + AES-GCM-256,
  56-byte UDP envelopes, TCP framing, file transfer framing, anti-replay counters,
  client/host session roles, and 25 tests.
- **VirtualTabletPad (MacHost target)** — menu-bar agent: Bonjour listener, E2EE
  handshake, UDP decrypt → `CGEvent` injection, PING/STATS, file receiver with
  SHA-256 verification, gesture map editor, and a **Cable / direct IP** address list
  for manual cable connections.
- **VirtualTabletPad (iPadClient target)** — fullscreen landscape workspace: 16:10
  canvas with 240 Hz coalesced Pencil capture, hover/proximity/tilt/roll, Pencil Pro
  squeeze and double-tap haptics, transient ink trail, finger trackpad mode, floating
  modifier island, shortcuts, file sender/drop zone, keyboard pass-through,
  multi-touch gesture engine and radial tool HUD.
- **Liquid Glass workspace (iPadOS 26+)** — Touch Bar-style top strip, graphics-tablet
  slab with bezel and 16:10 active area, Apple Pencil status box, keyboard-triggered
  F-key/modifier accessory, dynamic connection pill and radial HUD.
- **Raw USB-C transport** — usbmuxd tunnel through `USBProxy`; input packets travel
  over TCP, no Wi-Fi, IP, external NIC or system proxy.
- **Function keys** — F1–F12 plus brightness, Mission Control, App Exposé, desktop
  switching, Launchpad, media and volume actions.
- **Unified Settings** — Touchpad, Pencil & Gestures, Function Keys, Connection and
  About in one Settings center.
- **QR pairing** — Mac menu `Pair iPad…` shows a QR with host/ports/name; iPad
  Connection scans it, stores the profile and reconnects to that host.
- **Automatic / cable fallback** — Bonjour for Wi-Fi/AWDL, or link-local/USB-C
  Ethernet/hotspot fallback.
- **Touchpad feel engine** — on-device pointer curve, acceleration, slow precision,
  jitter/smoothing, post-lift stop smoothing, scroll sensitivity/natural direction,
  hold-to-drag with configurable delay, touch indicator and click haptics; presets
  and values persist in `UserDefaults`.
- **Dual-mode gesture engine** — watches `UIAccessibility.isGuidedAccessEnabled`
  and switches live between full 1–5 finger native gestures and a safe mode with
  4/5-finger suppression, Fn/Drag hold zones, inset edge scrubbers and corner
  Show Desktop/Launchpad buttons. The app also exposes an **Auto / Full / Safe**
  manual switch under Settings → Pencil → Gestures for in-app testing.
- **Pencil input controls** — pressure response curves (Natural/Soft/Hard),
  pen-only palm rejection, and a 0–100% stabilization slider that smooths hand
  tremor before packets leave the iPad (local ink uses the same filtered points).
- **Wake-on-tap** — the first trackpad event declares local user activity so a
  sleeping Mac display wakes.

## Status

| Item | State |
|---|---|
| Protocol package + 25 tests | ✅ `make test` passes |
| VirtualTabletPad Mac build | ✅ zero Swift compiler warnings |
| VirtualTabletPad iPad build | ✅ zero Swift compiler warnings |
| Liquid Glass workspace (iPadOS 26+) | ✅ aligned Touch Bar strip + tablet slab (16:10), 32pt corners, grouped/padded controls, Pencil status entry, keyboard F-key accessory, real iPad verified |
| Raw USB-C transport | ✅ usbmuxd tunnel, real iPad USB 1.8 ms, trackpad input verified, no Wi-Fi/IP/NIC |
| Function keys | ✅ F1–F12 + brightness/Mission Control/desktop/Launchpad/media pad; packets verified over USB; system-shortcut effects depend on macOS settings |
| Apple Pencil status | ✅ Ready/Connected/Idle activity box (no public Bluetooth state API) |
| Unified Settings center | ✅ Touchpad/Pencil/Function Keys/Connection/About in one sheet |
| QR pairing profile | ✅ Mac QR window + iPad camera scanner + persisted profile |
| Touchpad feel settings | ✅ presets, motion curve, feel, hold-to-drag, scroll, appearance; persisted and live |
| Pencil input controls | ✅ pressure curves + pen-only palm rejection + 0–100% stabilization (default 35%) |
| Dual-mode gesture engine | ✅ Guided Access monitor, Auto/Full/Safe in-app switch, native 1–5 finger paths, safe-mode Fn/Drag zones, 4/5-finger suppression, edge scrubbers; real iPad install + safe/forced-native UI verified, actual Guided Access toggle pass pending |
| Software keyboard Delete / Backspace | ✅ fixed: empty sink no longer swallows ⌫; iOS-side send verified in simulator; control packets get a larger UDP send budget |
| Wake-on-tap | ✅ IOPMAssertionDeclareUserActivity on first trackpad event |
| Dual-client disconnect bug | ✅ fixed: MacHost rejects a second control client instead of evicting the active iPad; real iPad connection stable |
| Mac E2E (handshake, UDP, replay/tamper, files) | ✅ `Tools/vpad_probe.py` |
| iPad/simulator ↔ Mac E2E | ✅ Bonjour discovery, TCP handshake, sub-ms PING, UDP nonce 1, 1 MiB upload success |
| Real iPad Air 11-inch (M2), iPadOS 27.0.1 | ✅ signed, installed, Liquid Glass UI visible, USB Cable connected at ~1.8 ms |
| App name & icon (all platforms) | ✅ `VirtualTabletPad` name on Mac/iPad; icon generated from SVG, device icon fetched (not placeholder), Mac `AppIcon.icns` |
| Real-device trackpad injection | ✅ cursor moved `(734,392) → (986,1082)` from a one-finger swipe |
| Real-device file upload | ✅ 1 MiB smoke + a 91 MB PDF saved on the Mac |
| Real-device Pencil drawing | ✅ 1,174 UDP packets, no crash (fixed `TransientInkLayer.init(layer:)`) |
| Real Apple Pencil Pro squeeze/double-tap | ✅ delegate callbacks, haptics and radial HUD manually verified |
| Bonjour `_vpad._udp` + `_vpad-tcp._tcp` | ✅ observed |
| Pressure/tilt/roll in a Mac drawing app | ⚠️ protocol + injection code complete; visual app-level check pending |
| Hardware/software keyboard, multi-touch gestures | ⚠️ software Delete path verified in simulator; full hardware-keyboard/gesture manual device pass pending |
| Mac Accessibility injection in real apps | ✅ real-device trackpad cursor injection verified; stylus/keyboard app-level checks pending |

## Versions

Marketing versions advance once per feature revision; build numbers count the
cumulative builds for each target.

| App | Version | Build | Basis |
|---|---|---|---|
| VirtualTabletPad (MacHost) | **1.5.0** | **10** | 5 feature revisions; 10 host builds |
| VirtualTabletPad (iPadClient) | **1.5.0** | **28** | 5 feature revisions; 28 simulator/device builds |

The revision waves so far were: 1.0 initial tablet, 1.1 delete key + Touch Bar +
Pencil stabilization, 1.2 dual-mode gesture engine, 1.3 in-app Auto/Full/Safe
switch, 1.4 keyboard-mode layout, 1.5 Mac gesture action routing.

## Requirements

- macOS 14.0+ (tested on macOS 27.0.1)
- iPadOS 17.5+ (tested on an iPad Air 11-inch M2, iPadOS 27.0.1, and the iOS 27 simulator)
- Xcode 27 / Swift 6.4
- XcodeGen 2.46+ (`brew install xcodegen`, or the vendored copy in `.tools/`)
- Python 3.10+ with `cryptography` for the Mac dev probe
- Apple Development team for installing on a physical iPad

## Quick start

### 1. Tests and Mac host

```bash
make test
make build
make run-dev        # Mac host with uploads in build/vpad_uploads
```

Grant Accessibility and Local Network on first launch. In another terminal:

```bash
make probe           # fake iPad: handshake/UDP/files
make probe SIZE_MB=500
```

### 2. iPad simulator

Keep the Mac host running, then:

```bash
make ipad-build

xcrun simctl list devices available | grep iPad
xcrun simctl boot <iPad-UDID>          # or make ipad-install IPAD_SIM=<UDID>
make ipad-install IPAD_SIM=<iPad-UDID>
```

The iPad app automatically discovers the Mac through Bonjour, performs the ECDH
handshake and shows **Mac connected** with a live PING latency.

For a one-shot simulator smoke test (DEBUG builds only), keep the host running and:

```bash
make ipad-smoke IPAD_SIM=<iPad-UDID>
```

That launch sets `VPAD_AUTO_SMOKE=1`; on connect the app sends two encrypted UDP
packets and uploads a 1 MiB file. The UI should show `UDP nonce 1`, `dropped 0` and
`Last file: success`; the host saves `vpad-ipad-smoke.bin` under its uploads
directory.

### 3. Physical iPad

Open `VirtualTabletPad.xcodeproj`, select the `iPadClient` scheme and your Apple
Development team, then run on the iPad. `make ipad-device-build` is a compile-only
check (`CODE_SIGNING_ALLOWED=NO`).

Command-line device install (tested with an iPad Air 11-inch M2, iPadOS 27.0.1):

```bash
UDID=<your-iPad-UDID>
TEAM=<your-Apple-Development-team-ID>
xcodebuild -project VirtualTabletPad.xcodeproj -scheme iPadClient -configuration Debug \
  -destination "platform=iOS,id=$UDID" -derivedDataPath /tmp/VirtualTabletPadiPadReal \
  -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic build
xcrun devicectl device install app --device "$UDID" \
  /tmp/VirtualTabletPadiPadReal/Build/Products/Debug-iphoneos/VirtualTabletPad.app
xcrun devicectl device process launch --device "$UDID" --terminate-existing com.vpad.iPadClient
```

On first launch, trust the development certificate on the iPad:
**Settings → General → VPN & Device Management → Developer App → Apple Development →
Trust**. Developer Mode must also be enabled. The iPad needs the local-network prompt
allowed; the Mac host must be running and reachable on the same Wi-Fi/AWDL link.

Real-device smoke test (DEBUG only, Mac host running):

```bash
DEVICECTL_CHILD_VPAD_AUTO_SMOKE=1 xcrun devicectl device process launch \
  --device "$UDID" --terminate-existing com.vpad.iPadClient
```

This sends two encrypted UDP packets and uploads a 1 MiB file; verify
`UDP nonce 1`, `dropped 0`, and `Last file: success` on the iPad.

## Raw USB-C mode (recommended for cable)

Choose **USB Cable** in Settings → Connection. No IP address, Wi-Fi, router or system
proxy is used:

- `USBProxy` connects to usbmuxd on the Mac, opens the iPad app's TCP listener on
  port **8890**, and bridges it to the Mac host's normal control port **8889**.
- The iPad sends input packets as `inputPacket` TCP frames; `EventInjector` injects
  them on the Mac.
- The app and Mac host auto-reconnect if the cable is unplugged/replugged.
- Verified on the real iPad: **1.8 ms**, trackpad cursor injection works, and no
  external network interface is involved.

If you prefer the older link-local/direct mode, it remains available:


A **direct USB-C cable is now plug-and-play**. The iPad USB link exposes a point-to-point
link-local interface on both devices (on this setup `en11` → `169.254.x.x`). MacHost
broadcasts a tiny `VPAD1` discovery beacon on UDP **8899** over every active IPv4
interface; the iPad's `LinkDiscovery` sees the 169.254 source and switches to Cable
mode automatically. No Wi-Fi, no manual IP, and no Internet Sharing are required.

- Verified on the real iPad Air: **1.4–1.5 ms**, cable direct mode.
- The top pill shows **Cable** and the Mac's USB link-local address is used for TCP
  and UDP.
- If auto-detection is unavailable, open the connection pill → **Cable / Direct IP**
  and enter the 169.254 address shown in the Mac menu under **Cable / direct IP**.
- The Mac menu shows every local IPv4 address and a **Copy …** button.
- Automatic/Bonjour remains the fallback when the cable is unplugged; the connection
  returns to Wi-Fi/AWDL.

Other wired options still work through the same screen:

1. **iPad Personal Hotspot over USB** — USB hotspot link, cellular plan required.
2. **USB-C Ethernet adapters** — both devices on the same wired network.

![Cable / direct IP connection settings](docs/connection-sheet.png)

![Direct mode connected without Bonjour](docs/ipad-liquid-direct.png)

DEBUG builds also accept `VPAD_DIRECT_HOST` for headless direct-mode smoke tests:

```bash
DEVICECTL_CHILD_VPAD_DIRECT_HOST=192.168.2.1 \
DEVICECTL_CHILD_VPAD_AUTO_SMOKE=1 \
xcrun devicectl device process launch --device "$UDID" \
  --terminate-existing com.vpad.iPadClient
```

## QR pairing (Wi-Fi)

1. On the Mac menu bar open **Pair iPad…**.
2. Choose the Mac address if several are listed and show the QR.
3. On the iPad open **Settings → Connection → Scan QR** and point the camera at it.
4. The iPad stores the Mac name/address, switches to **Cable-Direct IP**, and
   reconnects to the same host on later launches.

![Pair iPad QR](docs/pairing-qr.png)

The QR carries endpoint metadata only. The session uses the existing X25519 + HKDF +
AES-GCM-256 handshake. Full TLS certificate pinning / a signed pairing identity is
not implemented yet; do not treat QR pairing as an authenticated TLS replacement.

## Liquid Glass workspace

On iPadOS 26+ the workspace is a single full-screen `ZStack`:

- **Width and corners** — the top strip, tablet slab and keyboard accessory share the
  same leading/trailing edges and 32pt continuous corners. Vertical chrome was
  tightened so the 16:10 tablet can consume the full panel width in the normal layout
  instead of being height-limited and centered narrower than the strip.
- **Graphics-tablet slab** — a 12pt bezel surrounds a rounded active area whose aspect
  ratio is locked to the Mac screen (16:10). The slab is centered and sized to use the
  largest possible active area without overlapping the strip.
- **Top Touch Bar strip** — connection status, file, keyboard mode, Function Pad,
  Settings, Command/Shift/Option/Control/Space, Undo/Redo and Brush−/+. Controls are
  grouped into padded clusters at a 56pt strip height with 46pt touch targets; a
  compact fallback moves the edit cluster into an overflow menu on narrow widths.
- **Apple Pencil status box** — shows Ready / Connected / Idle based on recent Pencil
  input and doubles as the entry point to Pencil feel settings. iPadOS does not expose
  the Pencil's Bluetooth connection or battery level to third-party apps, so this is
  an activity indicator, not a Bluetooth report.
- **Keyboard mode** — when the software keyboard appears, the tablet surface is
  replaced by a Keyboard Mode card with Hide Keyboard, Function Pad and Settings
  actions. A fixed two-row accessory above the keyboard shows F1–F12 on row one and
  the Command/Shift/Option/Control/Space plus system keys on row two, so every
  control is visible without horizontal scrolling. The slab and its gesture chrome
  return when the keyboard hides.
- **Gesture-mode chrome** — when Guided Access is off, the canvas shows a dashed
  35pt safety outline, inset edge scrub tracks, and the Fn/Drag and Show
  Desktop/Launchpad hot zones. When Guided Access is on, those aids disappear and
  the canvas becomes a solid black surface for native 1–5 finger gestures.
- The active area uses a subtle dot grid in safe mode; no full-screen MeshGradient fog.
- iPadOS 17.5 falls back to the original HStack layout; `LiquidGlassWorkspace.swift`
  contains the new UI and `WorkspaceView.swift` chooses between the two.

## Function keys and unified settings

The top strip's **fn** button opens the Function Pad:

- **F1–F12** standard macOS function keys.
- **System Keys** row: Brightness −/+, Mission Control (all windows), App Exposé,
  Desktop ←/→, Launchpad (Apps on macOS 27), Play/Pause, Next/Previous,
  Volume −/+.

F1–F12 use macOS virtual keycodes. Brightness/media use system-defined NX events;
Mission Control, App Exposé and desktop switching are now sent as real
Control+arrow CGEvent key combos (with a physical Control key transition), so they
only need Accessibility permission rather than Automation/System Events. The
shortcuts still follow the user's macOS Mission Control/Keyboard settings.

The gear/slider button opens the single **Settings** center, replacing the separate
Touchpad and Tools sheets:

- **Touchpad** — presets and all feel sliders.
- **Pencil** — stabilization, pressure curve, pen-only input, squeeze mode,
  last Pencil interaction, keyboard mode and gestures.
- **Function Keys** — overview and Function Pad entry.
- **Connection** — Automatic / USB Cable / Cable-Direct IP, status, errors.
- **About**.

![F-keys and modifiers drop in above the software keyboard](docs/keyboard-layout.png)

![Function Pad](docs/function-pad.png)

![Unified Settings](docs/settings-merged.png)

## Touchpad feel settings

Open the gear button in the right floating toolbar to tune the finger trackpad:

- **Quick Presets** — Precise, Balanced, Swift.
- **Motion Curve** — Pointer Speed, Acceleration, Slow Precision.
- **Feel** — Jitter Filter, Smoothing, Stop Smoothing (a short post-lift decay).
- **Drag** — Hold to Drag and Drag Delay, adapted from Touchpad/Sofatap.
- **Scroll & Zoom** — Scroll Sensitivity and Natural Scrolling.
- **Appearance** — Show touch indicator and Haptic feedback.

All settings are persisted in `UserDefaults` and applied on the iPad *before* the
encrypted UDP packet is sent, so slider changes are live and do not require a
reconnect. The defaults match the Balanced preset: `1.08×` pointer speed,
`1.25×` acceleration, `0.95×` slow precision, `0.85×` jitter filter, `0.45×`
smoothing, `0.02×` stop smoothing, `80%` scroll sensitivity.

![Touchpad Settings — presets and motion curve](docs/touchpad-settings-top.png)

![Touchpad Settings — feel, scroll and appearance](docs/touchpad-settings.png)

## Pencil feel settings

Tap the Apple Pencil status box in the top strip, or open **Settings → Pencil**, to
tune Pencil input:

- **Stabilization** — a 0–100% slider (default 35%). 0% follows the Pencil tip
  directly; higher values smooth hand tremor and round the trace at the cost of a
  little lag. Presets: Off, Light, Balanced and Strong.
- **Pressure curve** — Natural, Soft/Sensitive or Hard/Controlled.
- **Pen-only input** — ignore direct finger touches for palm rejection.

Stabilization runs on the iPad before the encrypted `stylusStroke` packet is sent,
using a time-constant filter that smooths more at slow speeds and less during fast
strokes. The local cyan ink trail consumes the same filtered points and draws them
with quadratic midpoint curves, so the preview and the Mac stroke stay consistent.
The setting persists in `UserDefaults`; older saved settings are migrated with the
default value.

## Dual-mode gesture engine

`GuidedAccessMonitor` observes `UIAccessibility.isGuidedAccessEnabled` and the
`guidedAccessStatusDidChangeNotification`, so the canvas switches modes live without
a restart.

| Gesture | Guided Access ON (native) | Guided Access OFF (safe) |
|---|---|---|
| 1 finger move / tap | Full surface | Full surface; touches starting within 25pt of an edge are ignored |
| 2 finger scroll / right-click / pinch | Enabled | Enabled; pinch sends Cmd+scroll zoom; two-finger long-press sends Quick Look |
| 3 finger | Tap → Look Up; move >4pt → left-button drag | Stationary tap → Look Up; movement is discarded |
| 4 finger | Swipe up/down → Mission Control/App Exposé; left/right → Spaces | Suppressed; hold Fn + two-finger swipe |
| 5 finger | Spread → Show Desktop; pinch → Launchpad | Suppressed; use the lower-right corner buttons |
| Drag | Three-finger drag | Hold Drag (lower-left) + one-finger move |
| Edge scrub | Invisible 0–30pt edge tracks: brightness (left), volume (right), tabs (top/bottom) | Visible inset 40–80pt tracks with the same actions |
| System | — | Fn + two-finger swipe → Mission Control/App Exposé/Spaces |

The safe-mode `Fn` and `Drag` buttons are hold controls; they set local state only and
never become Mac modifier bits. The lower-right buttons send Show Desktop (F11) and
Launchpad. A 4/5-finger touch in safe mode cancels the current gesture and releases a
held mouse button so the Mac cannot get stuck.

Current approximations: Force Touch is mapped to the standard Look Up (⌃⌘D) and
Quick Look (Space) shortcuts; two-finger rotation has no protocol channel; Spaces
and Mission Control are discrete actions rather than a continuous animation. The
double-tap-hold drag and bottom-Dock swipe variants are intentionally left to the
Fn/Drag hot zones and the corner buttons. Safe mode requests `.all` screen-edge
deferral through a transparent child controller; iPadOS can still own some edge
gestures, which is why the 25pt start dead zone remains.

The Mac Gesture Map is kept for legacy custom gesture IDs; the dual-mode engine
sends its standard actions directly and no longer emits IDs 1–4.

### Switching modes inside the app

Open **Settings → Pencil → Gestures** and use the **Gesture engine** segmented
picker: **Auto** follows the system Guided Access switch, **Full** forces the
native 1–5 finger engine, and **Safe** forces the Fn/Drag engine. The choice is
persisted in `UserDefaults`, and the top-bar badge shows `GUIDED`/`SAFE` in Auto
or `FULL`/`SAFE` for a manual override.

Manual switching only changes this app's gesture recognizer. iPadOS Guided Access
is a system security lock and cannot be turned on from inside an app; manual Full
mode can still lose 4/5-finger and edge gestures to iPadOS. For a conflict-free
native test, enable real Guided Access in iPadOS Settings or via the accessibility
shortcut.

`#if DEBUG` builds can force an initial mode for simulator screenshots with
`SIMCTL_CHILD_VPAD_GUIDED_ACCESS=0` (safe) or `1` (native); the setting is not
persisted unless you change the in-app picker.

## Why Mac staging goes through `/tmp`

This workspace lives in a file-provider-managed `Documents` folder. Such folders can
attach `com.apple.FinderInfo` / file-provider xattrs to product bundles, and
`codesign` can refuse to verify a bundle carrying them. `make build` therefore builds
in `/tmp/VirtualTabletPadBuild`, verifies the signature there, copies the signed app
with `ditto --norsrc --noextattr`, and clears residual xattrs. The result is
`build/VirtualTabletPad.app`; `make run`/`make run-dev` clear the workspace copy
before launching.

If a DSH workspace sandbox is active, `xcodebuild` may need `danger-full-access`
because Xcode's SwiftPM resolver starts a nested `sandbox-exec` and writes
`~/Library` caches. A normal Terminal does not need that.

Harmless build notes: `appintentsmetadataprocessor` prints "Metadata extraction
skipped, no AppIntents.framework dependency found" because the apps do not use
AppIntents; ad-hoc Mac signing also prints that hardened runtime is disabled. Select
an Apple Development team for hardened, stably signed Mac builds.

## Permissions

1. **Mac Accessibility** — required for injected trackpad/stylus/keyboard events.
   *System Settings → Privacy & Security → Accessibility*. The menu bar shows a
   red indicator until granted.
2. **Mac Local Network** — allow the prompt so Bonjour discovery works.
3. **Mac Downloads** — the production upload path triggers the Downloads privacy
   prompt on first write. `make run-dev` avoids it by using `build/vpad_uploads`.
4. **iPad Local Network** — allow the prompt; without it Bonjour discovery fails.

Ad-hoc Mac builds change signature on every rebuild and may require re-granting
Accessibility. Select an Apple Development team for a stable grant. The unified
`VirtualTabletPad.app` product path also differs from the earlier `MacHost.app`, so
macOS may treat it as a new Accessibility client; re-grant once if trackpad input
stops working after the rename.

## Architecture

```
iPadClient ──TCP 8889──▶ ECDH X25519 → HKDF-SHA256 → AES-GCM-256 key
           ──UDP 8888──▶ 56-byte envelope → decrypt → Mac EventInjector
           ──TCP frames─▶ PING/STATS + FILE_HEADER/CHUNK/TRAILER
```

- **Queues:** iPad UDP sends and Mac UDP receive/decrypt/inject use
  `userInteractive`; TCP/file/script work uses `.utility`. UI updates are pushed to
  the main actor, never per packet.
- **Crypto:** UDP nonce = 4-byte BE direction + 8-byte BE counter. TCP uses
  direction 3/4 with ordered counters; the nonce is not transmitted. `SessionCrypto`
  has `.host` and `.client` roles so both ends seal/open inverse directions.
- **Anti-replay:** the receive counter advances only after successful
  authentication, so forged high counters cannot block legitimate packets.
- **Files:** `[4-byte BE length][payload]` framing, 64 KiB chunks, streaming
  SHA-256 trailer. Names are sanitized to a basename, length-capped, collision-
  suffixed, and constrained inside the uploads directory. `FILE_ABORT (0x34)` and
  disconnect delete partial files.
- **Packet layout:** exactly per `AGENT_PLAN.md` §2; tests assert
  `MemoryLayout<VPadPacket>.size == 28 == stride`.

### Ports

| Transport | Port | Bonjour |
|---|---:|---|
| TCP control/file | **8889** | `_vpad-tcp._tcp` |
| UDP input | **8888** | `_vpad._udp` |

`AGENT_PLAN.md` leaves the UDP port to Bonjour. This implementation fixes it to 8888
for deterministic firewalling and local verification; the iPad resolves it through
Bonjour.

## iPad features

- **Canvas** (`HybridCanvasView`): largest inscribed 16:10 `activeRect`, border
  `#2C2C30` on `#121214`; `UIHoverGestureRecognizer` enters/leaves proximity and sends
  hover tilt/roll; Pencil touches iterate `coalescedTouches` and send 240 Hz stroke
  packets; `TransientInkLayer` draws a 0.8 s fading cyan trail.
- **Pencil Pro** (`PencilProManager`): squeeze haptic +
  `0x13 StylusSqueeze` right-click HUD or local radial palette; double-tap haptic +
  `0x14 StylusDoubleTap`; `UITouch.rollAngle` and `UIHoverGestureRecognizer.rollAngle`
  feed `0x10/0x11` and the Mac converts radians to tablet rotation degrees.
- **Finger trackpad**: one-finger move, tap → left click, two-finger pan → scroll,
  two-finger tap → right click; ≥3 fingers are forwarded to `GestureEngine` and never
  double-handled. Pencil activity suppresses palm/finger input.
- **Modifier sidebar**: momentary Cmd/Shift/Option/Control/Space buttons merge their
  live bitmask into every packet; Space becomes a real Mac Space-key pan.
- **Shortcuts**: Undo, Redo, `[`, `]` sent as `0x20` atomic key macros.
- **Keyboard**: hidden first responder captures hardware keys (`pressesBegan/Changed/
  Ended/Cancelled`) with an explicit HID → macOS virtual-keycode table; a hidden text
  field handles the software keyboard. The field is a pure sink, so backspace is
  captured via `deleteBackward()` plus the delegate fallback and sent as macOS 51;
  both paths send `0x21`, and the Mac keeps a down-key set and releases everything on
  cancel/disconnect.
- **Files**: `Send File` importer and workspace drop zone copy into a temp file and
  stream through `TCPFileClient` over the existing E2EE TCP connection with progress.
- **Gestures**: `GuidedAccessMonitor` selects a native or safe state machine.
  Native mode uses 3-finger left-button drag and 4/5-finger system actions; safe
  mode suppresses 4/5-finger input, keeps a stationary 3-finger tap, and routes
  Fn + two-finger swipes to Mission Control/App Exposé/Spaces. Edge scrubbers send
  brightness/volume/tab actions. The legacy direction-token pattern store is kept
  for compatibility but is not used by the dual-mode recognizer.
- **Radial HUD**: squeeze in local mode opens a pen/eraser/undo palette at the pen
  location.

## Layout

```
project.yml                        XcodeGen spec (MacHost + iPadClient)
Packages/VPadProtocol/             shared protocol + crypto + framing + tests
MacHost/
  MacHostApp.swift                 @main, AppDelegate, HostStatus, MenuBarExtra
  AccessibilityManager.swift       AXIsProcessTrusted + 1.5 s polling
  SessionState.swift               host session actor
  TCPServer.swift                  :8889 listener, handshake, frames, files
  UDPServer.swift                  :8888 listener, decrypt → inject
  EventInjector.swift              CGEvent synthesis
  GestureMapper.swift              GestureID → key macro / script
  GestureMapView.swift             menu-bar editor window
  FileReceiver.swift               chunk → disk + SHA-256 + cleanup
  HostBeacon.swift                 UDP 8899 cable discovery beacon
  USBProxy.swift                   usbmuxd raw USB bridge
  PairingView.swift                Mac Pair iPad QR window
  Assets.xcassets/AppIcon.appiconset
  Info.plist                       generated by XcodeGen
iPadClient/
  iPadClientApp.swift              @main SwiftUI app
  WorkspaceView.swift              iOS 26 glass / iPadOS 17 legacy chooser + legacy UI
  LiquidGlassWorkspace.swift       ZStack canvas, glass ornaments, radial palette
  ConnectionSettingsView.swift     automatic vs cable/direct-IP editor
  FunctionKeys.swift               F1–F12 + system-key pad
  WorkspaceSettingsView.swift      unified Settings center
  PairingProfile.swift             saved QR pairing profile
  QRScannerView.swift              AVFoundation QR scanner
  TouchpadSettings.swift           feel model, presets, motion filter
  TouchpadSettingsView.swift       presets + sliders + appearance UI
  LinkDiscovery.swift              UDP 8899 USB link-local discovery
  SessionCoordinator.swift         main-actor UI state + transport mode
  SessionState.swift               client session actor
  UDPClient.swift                  Bonjour/direct UDP + encrypted 240 Hz sender
  TCPFileClient.swift              handshake, PING, file uploads, reconnect
  HybridCanvasView.swift           Pencil/hover/finger canvas + ambient rim
  TransientInkLayer.swift          0.8 s fading trail
  PencilProManager.swift           squeeze/double-tap/haptics/radial state
  GestureEngine.swift              ≥3-finger gestures and patterns
  ModifierState.swift              lock-protected modifier bitmask
  KeyboardHandler.swift            HID mapping + software keyboard
  Assets.xcassets/AppIcon.appiconset
  Info.plist                       generated by XcodeGen
virtual_tablet_pad_icon.svg        source icon
Tools/vpad_probe.py                dev-only fake iPad for Mac E2E
docs/app-icon.png                  rasterized app icon
docs/ipad-liquid-glass.png         Liquid Glass simulator screenshot (iPadOS 27)
docs/ipad-real-device.jpg          legacy filename: iPadOS 27 simulator Liquid Glass screenshot
docs/ipad-liquid-radial.png        Liquid Glass radial palette (simulator)
docs/touchpad-settings.png         touchpad feel settings (iPadOS 27 simulator)
docs/touchpad-settings-top.png     presets and motion curve (simulator)
docs/connection-sheet.png          cable / direct IP settings (simulator)
docs/function-pad.png              F1–F12 and system keys
docs/pairing-qr.png                Mac Pair iPad QR window
docs/keyboard-layout.png           F-key/modifier accessory above keyboard
docs/settings-merged.png           unified Settings center (Pencil tab)
docs/ipad-liquid-direct.png         direct-IP connected screenshot
docs/ipad-simulator.png            current iPadOS 27 simulator screenshot
```

## Verification performed

- `make test`: 25/25 protocol tests, including a client-role/host-role inverse
  direction test.
- `make build` and `make ipad-build` / `make ipad-device-build`: success, zero Swift
  compiler warnings.
- Mac probe: handshake, PING/STATS, UDP replay/tamper drops, 1 MiB and 500 MiB
  SHA-256, bad checksum, `FILE_ABORT`, duplicate-name UUID prefix, path traversal.
- iPad simulator ↔ Mac host: Bonjour discovery, encrypted TCP handshake, sub-ms
  PING/PONG, two encrypted UDP packets accepted (`UDP nonce 1`, `dropped 0`), 1 MiB
  file uploaded with `Last file: success`.
- Host restart: iPad detects the closed TCP connection, shows **Searching for Mac…**,
  reconnects automatically when the host returns.
- Liquid Glass workspace on the iOS 27 simulator and the real iPad Air: full-screen
  `ZStack`, floating modifier island, top connection capsule, paired glass shortcut
  capsules, radial palette, MeshGradient ambient light and coloured canvas rim;
  iPadOS 17 fallback compiles from the same target.
- Direct-IP transport: simulator launched with `VPAD_DIRECT_HOST=127.0.0.1` connected
  over explicit TCP 8889/UDP 8888 without Bonjour; the connection sheet shows the
  mode, host, live latency and server error details.
- Real iPad Air 11-inch M2 (iPadOS 27.0.1): signed with the local Apple Development
  team, installed via `devicectl`, trusted, Liquid Glass UI visible, connected at
  ~14 ms over Wi-Fi; UDP stream (`nonce 1,174`, `dropped 0`) and a 1 MiB smoke upload
  were verified earlier.
- Dual-client bug found during real-device testing: a simulator left running next to
  the real iPad opened a second control connection, and the old MacHost accepted it
  by evicting the active session. Both clients then reconnected every ~2 s. `TCPServer`
  now rejects a second control client while an iPad is active; with the simulator
  stopped the real iPad connection stayed up.
- Touchpad settings: Quick Presets, Motion Curve, Feel, Scroll & Zoom, and Appearance
  are implemented and persisted. The motion filter is applied on-device before the
  encrypted UDP send; the settings sheet was verified on the real iPad (13.7 ms link).
- USB-C cable: `HostBeacon` broadcasts UDP 8899 on every IPv4 interface; the iPad
  receives a 169.254 link-local beacon, switches from automatic to direct mode, and
  connects at **1.4–1.5 ms** with no Wi-Fi. Verified on the real iPad (screenshot).
- Raw USB: `USBProxy` connected over usbmuxd to the iPad listener, the host received
  `inputPacket` frames, and a synthetic trackpad move moved the Mac cursor
  `(0,957) → (759,440)`. Real iPad USB Cable link: **1.8 ms**.
- UI: Touch Bar top strip, separate rounded canvas, and keyboard-triggered F-key
  accessory verified on the real iPad; the Settings, Function Pad and keyboard
  screenshots are in `docs/`.
- Function/system action packets are delivered to `EventInjector`; Launchpad uses the
  macOS 27 Apps app. Mission Control/App Exposé/Spaces use real Control+arrow CGEvents,
  so they depend on the user's macOS shortcut configuration and Accessibility permission
  but not Automation/System Events.
- Real-device file transfer: a 91 MB PDF was uploaded through the app and saved to
  `build/vpad_uploads/Abstract Backgrounds + Shapes.pdf` after the host's SHA-256
  trailer check.
- Real-device trackpad: one-finger swipe moved the Mac cursor from `(734,392)` to
  `(986,1082)`, proving actual `CGEvent` injection.
- Real-device Pencil: drawing produced 1,174 encrypted packets with no crash. The
  first real-device stroke exposed and fixed a CoreAnimation crash in
  `TransientInkLayer` (`init(layer:)` was not implemented).
- Real Apple Pencil Pro: squeeze phases (`began/changed/ended`), double-tap, haptics
  and the Local Radial Palette HUD were manually verified; console logs show
  `VPAD_PENCIL squeeze` / `VPAD_PENCIL tap` callbacks.
- Unified identity: both products report `CFBundleName`/`CFBundleDisplayName`
  `VirtualTabletPad`; `devicectl device info apps` shows that name, and
  `devicectl device info appIcon` returned a 1024×1024 non-placeholder icon generated
  from `virtual_tablet_pad_icon.svg`. The Mac bundle contains `AppIcon.icns`.

## Manual hardware verification still required

- Pencil pressure/tilt/hover/barrel-roll appearance inside a Mac drawing app.
- Hardware keyboard passthrough (including Cmd+C/V and no stuck keys) and the
  software keyboard path.
- One/two-finger trackpad behavior across more apps and 3/4-finger gestures.
- Mac right-click HUD on squeeze and eraser-on-double-tap inside a Mac app.
- Confirm the Mac Downloads privacy prompt with the production upload directory.

## Reference projects studied

- [chekusu/sofatap](https://github.com/chekusu/sofatap) — gesture-driven touch
  surface, hold-to-drag, haptics, dot-grid feedback, unified settings and device UI.
  The drag model and settings organization were adapted into SwiftUI; the network
  pairing/dictation stack was not copied.
- [TheAndreyZakharov/Touchpad](https://github.com/TheAndreyZakharov/Touchpad) —
  four core gestures, pointer/scroll sensitivity and natural scrolling. The hold-to-
  drag and sensitivity model were adopted.
- [gabrieldonadel/entangle](https://github.com/gabrieldonadel/entangle) — NAT/Bonjour
  discovery, keyboard relay and trackpad-first UI. Our Bonjour discovery, keyboard
  mode and device status follow the same approach.
- **EasyCanvas, Astropad Studio, Duet Display** — pressure/tilt, shortcut bars,
  radial tools, low-latency direct connections. Our Pencil pipeline, radial HUD,
  Function Pad and raw-USB mode follow the same product expectations.

All adapted behavior is implemented in SwiftUI/Swift; no third-party source files were
copied into the project.

### Scope note

The list also includes features that are separate subsystems rather than UI ports:
live Accessibility text synchronization, on-device dictation, authenticated TLS
certificate pinning, virtual extended display drivers, hardware H.264/HEVC screen
streaming and adaptive video quality. Basic QR endpoint pairing is now in place, but
the larger pieces require ScreenCaptureKit/VideoToolbox/DriverKit and Accessibility
pipelines and should be planned as separate phases.

## Notes vs. `AGENT_PLAN.md`

- The iPad target is now included in `project.yml` with iOS 17.5 deployment; the
  shared package keeps `.iOS(.v17)` because `PackageDescription` has no `.v17_5`.
- Liquid Glass requires iOS 26; the iPad target keeps 17.5 deployment and selects the
  glass workspace with `if #available(iOS 26.0, *)`, falling back to the original
  HStack layout on older iPadOS.
- Cable mode uses the USB link-local interface plus a UDP 8899 discovery beacon, so
  a plain USB-C cable auto-connects; manual IP, Personal Hotspot over USB and USB-C
  Ethernet remain available as fallbacks.
- The Mac host is intentionally single-tablet: an additional TCP control client is
  rejected while an iPad is active. This prevents a simulator left running beside the
  physical iPad from evicting the active session and causing a reconnect war.
- Xcode does not accept `SWIFT_VERSION = 5.10`; both apps use Swift 6 mode with strict
  concurrency and build without compiler warnings.
- `kAXTrustedCheckOptionPrompt` is an imported mutable global rejected by Swift 6;
  the identical documented string key is used.
- `UIKey.keyCode` is HID usage, **not** a macOS virtual keycode for standard keys;
  `KeyboardHandler` contains an explicit HID → macOS table (the plan's risk note only
  mentioned media/function keys).
- `FILE_ABORT (0x34)` was added before the v1 freeze; it cancels a transfer without
  changing the 28-byte packet.
- UDP is fixed at 8888 for deterministic local testing; Bonjour still carries
  discovery.
