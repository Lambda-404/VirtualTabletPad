# DriverKit Virtual HID Digitizer Feasibility Analysis

## Architecture Comparison

| Dimension | Current CGEvent Injection | DriverKit Virtual HID Dext |
| :--- | :--- | :--- |
| **Layer** | Window Server (`CGEvent.post`, HID tap) | I/O Kit User-space Driver (`IOUserHIDDevice`) |
| **Device Appearance** | Synthetic Events (Wacom Tablet Subtype) | Hardware Digitizer (`Usage Page 0x0D: Digitizer`) |
| **System Permissions** | Accessibility (`AXIsProcessTrusted`) | System Extension approval in System Settings |
| **Apple Entitlements** | Standard Developer ID | Restricted: `com.apple.developer.driverkit.family.hid.virtualdevice` |
| **Distribution** | Standard `.app` / Notarized `.dmg` | Requires Apple Developer Portal Entitlement Grant |
| **SIP Requirement** | Standard (SIP Enabled) | Standard with grant; SIP Disabled without grant |
| **Implementation Language** | Swift 6.0 | C++ / DriverKit Embedded C++ |

---

## Technical Requirements

### 1. Apple Entitlements
To create a virtual HID device without a physical hardware transport (USB/PCIe), Apple mandates:
- `com.apple.developer.driverkit`
- `com.apple.developer.driverkit.family.hid.virtualdevice` (requires manual justification request to Apple)
- System Extension provisioning profile linked to Developer ID

### 2. Dext Implementation
- Subclass `IOUserHIDDevice` within a `.dext` bundle.
- Compile HID Report Descriptor matching standard graphics tablets:
  - Usage Page `0x0D` (Digitizer)
  - Usage `0x02` (Pen)
  - Fields: Tip Switch, In Range, Pressure (`0x30`), Tilt X/Y (`0x3D`/`0x3E`), Azimuth/Twist (`0x40`), X/Y Coordinates (`0x30`/`0x31`)
- IPC mechanism: `IOUserClient` connection dispatching 240 Hz input reports from `MacHost` to the `.dext`.

---

## Trade-off Evaluation

### Advantages
- Direct kernel-level HID report ingestion; indistinguishable from physical Wacom / Huion hardware.
- No accessibility permission required for cursor motion.
- Robust against sandboxed apps that ignore synthetic `CGEvent` pointer events.

### Drawbacks
- **Deployment Barrier**: Entitlement approval is discretionary and often rejected for non-hardware vendors.
- **Maintenance Cost**: Kernel/DriverKit ABI changes across macOS major releases.
- **User Friction**: Requires reboot / security clearance during System Extension installation.

---

## Recommendation

**Maintain Current CGEvent Architecture.**  
The current `CGEvent` implementation with `.tabletPoint` subtype, 8-bit/16-bit pressure, tilt, rotation, and proximity state machine satisfies the requirements of Krita, Photoshop, Blender, Clip Studio Paint, and Pixelmator without requiring special Apple entitlement waivers or System Extensions.
