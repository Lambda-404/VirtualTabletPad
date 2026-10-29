# TestFlight & App Store Release Notes (VirtualTabletPad iPadClient)

This document contains testing instructions, "What to Test" bullet points for external TestFlight testers, and App Store Review notes for the iPadOS client.

---

## 1. TestFlight "What to Test" Notes (Version 2.0.0)

Welcome to the VirtualTabletPad 2.0.0 beta! This update brings our completely rewritten low-latency input engine, end-to-end encryption, and full Apple Pencil Pro gesture support.

### What to Test:
1. **Apple Pencil Pro Gestures**:
   - **Squeeze**: Squeeze the barrel near the tip. Verify the Radial Palette HUD pops up with crisp haptic feedback.
   - **Barrel Roll**: Rotate the pencil while hovering or drawing in supported apps (e.g. Photoshop or Krita). Confirm the brush cursor rotates smoothly.
   - **Double-Tap**: Double tap the side of the pencil to switch tools (Eraser/Brush) or trigger custom actions.
2. **Pressure Response & Stabilization**:
   - Open **Settings → Pencil Feel** and test the live pressure curve preview with presets (Natural, Soft, Hard).
   - Draw fine lines at 0%, 50%, and 100% stabilization.
3. **USB-C vs. Wi-Fi Connectivity**:
   - Connect via direct USB-C cable. Confirm the status pill switches to `Cable` with ~1.4 ms RTT.
   - Disconnect cable and test wireless Bonjour auto-discovery or QR code pairing.
4. **Multi-Touch Trackpad & Guided Access**:
   - Triple-click the top button to enter Guided Access. Test 1- to 5-finger native gestures (point, scroll, drag, Mission Control).

Please report any input dropped frames, disconnection issues, or latency regressions via TestFlight feedback!

---

## 2. App Store Review Notes

- **Companion macOS App**: VirtualTabletPad for iPad requires the open-source companion host app running on macOS Sonoma (14.0) or later. The host binary can be downloaded or compiled from our GitHub repository: `https://github.com/Lambda-404/VirtualTabletPad`.
- **Local Network Usage**: The app requests Local Network access (`NSLocalNetworkUsageDescription`) solely to discover the companion Mac host via mDNS / Bonjour and establish the encrypted TCP/UDP session.
- **Camera Usage**: The app requests Camera access (`NSCameraUsageDescription`) strictly to scan the one-time pairing QR code displayed on the Mac menu bar. No photos, videos, or facial data are recorded or stored.
- **No Third-Party Tracking**: No telemetry, tracking frameworks, or analytics SDKs are embedded in the app.
