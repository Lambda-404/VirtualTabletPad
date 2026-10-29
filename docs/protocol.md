# VirtualTabletPad Protocol Specification (v2)

This specification defines the complete wire format, cryptographic handshake, directional key schedule, inner packet representation, anti-replay sliding window, and synthetic pointer injection guidelines for third-party host implementations (Windows `InjectSyntheticPointerInput` and Linux `/dev/uinput`).

---

## 1. Overview & Cryptographic Primitives

| Component | Primitive | Details |
|---|---|---|
| **Identity Authentication** | Ed25519 | Curve25519 signature algorithm (RFC 8032) |
| **Key Agreement** | X25519 ECDH | Curve25519 Diffie-Hellman key exchange (RFC 7748) |
| **Key Derivation** | HKDF-SHA256 | HMAC-based Extract-and-Expand (RFC 5869) |
| **Session Encryption** | AES-GCM-256 | Galois/Counter Mode with 128-bit authentication tag |
| **Integrity & Anti-Replay** | Sliding Window | 64-packet window bitmap with monotonic sequence counter |
| **Control Channel** | TCP Port `8889` | Handshake, pairing, frame codec, active app notifications, file transfers |
| **Input Channel** | UDP Port `8888` | 240 Hz low-latency encrypted datagrams |

---

## 2. Control Channel Framing & Handshake (TCP 8889)

### 2.1 TCP Frame Layout
Every control frame on TCP port 8889 uses a 5-byte header followed by the frame body:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                       Body Length (32-bit BE)                 |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|   Type (8)    |                 Body Payload ...              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

- **Body Length**: 32-bit unsigned big-endian integer ($1 \le \text{length} \le 16\,\text{MB}$).
- **Type**: 8-bit unsigned integer identifying the frame type.

#### Frame Types
| Type | Name | Direction | Payload Description |
|---|---|---|---|
| `0x01` | `HELLO` | Client $\to$ Host | Handshake initiation: ephemeral pubkey, identity pubkey, Ed25519 signature (129B) |
| `0x02` | `HELLO_ACK` | Host $\to$ Client | Handshake reply: ephemeral pubkey, identity pubkey, signature, encrypted confirmation (149B) |
| `0x03` | `READY` | Host $\to$ Client | Session ready notification; signals client to begin UDP input |
| `0x04` | `PING` | Bidirectional | Keepalive / RTT measurement ping |
| `0x05` | `PONG` | Bidirectional | Keepalive pong response with original timestamp |
| `0x06` | `STATS` | Bidirectional | Transport statistics payload (JSON) |
| `0x07` | `FILE_HEADER` | Client $\to$ Host | File transfer initiation: name length (2B), filename, file size (8B) |
| `0x08` | `FILE_CHUNK` | Client $\to$ Host | Binary chunk slice (up to 256 KB) |
| `0x09` | `ACTIVE_APP` | Host $\to$ Client | Frontmost application bundle ID string (UTF-8) |
| `0x10` | `FILE_TRAILER`| Client $\to$ Host | SHA-256 checksum (32B) verifying uploaded file |
| `0x11` | `FILE_STATUS` | Host $\to$ Client | Transfer acknowledgement / status code (1B) |

---

### 2.2 Handshake Sequence Diagram

```mermaid
sequenceDiagram
    autonumber
    participant Client as Client (iPad / Stylus)
    participant Host as Host (Mac / Windows / Linux)

    Note over Client,Host: 1. TCP Connection Established (port 8889)
    Client->>Host: Frame 0x01: HELLO (129 bytes)
    Note over Host: 1. Verify Client Ed25519 signature over ClientTranscript<br/>2. Validate Client Identity Key against allowlist<br/>3. Compute S = X25519(Host_ephem_priv, Client_ephem_pub)<br/>4. Compute TranscriptHash = SHA256(FullTranscript)<br/>5. Derive c2sKey, s2cKey via HKDF-SHA256<br/>6. Derive ConfirmationNonce = SHA256("VPad-v2-Confirmation-Nonce" || TranscriptHash)[0..11]<br/>7. Encrypt sessionID with s2cKey + ConfirmationNonce
    Host->>Client: Frame 0x02: HELLO_ACK (149 bytes)
    Note over Client: 1. Verify Host Identity Key against pinned fingerprint<br/>2. Compute S = X25519(Client_ephem_priv, Host_ephem_pub)<br/>3. Compute TranscriptHash = SHA256(FullTranscript)<br/>4. Verify Host Ed25519 signature over TranscriptHash<br/>5. Derive c2sKey, s2cKey via HKDF-SHA256<br/>6. Decrypt confirmation payload to extract sessionID
    Host->>Client: Frame 0x03: READY
    Note over Client,Host: Mutual authentication complete; encrypted UDP stream armed on port 8888
```

---

### 2.3 Handshake Payloads & Key Derivation

#### Client Hello (`HELLO`, type = `0x01`, 129 bytes)
```
[ 0 ]       : Version (0x02)
[ 1..32 ]   : Client Ephemeral Public Key Ec_pub (32 bytes, X25519)
[ 33..64 ]  : Client Identity Public Key Ic_pub (32 bytes, Ed25519)
[ 65..128 ] : Signature (64 bytes, Ed25519 signature by Ic over ClientTranscript)
```
Where `ClientTranscript` is:
```
ClientTranscript = "VPad-v2-Handshake-Client" (24 bytes ASCII)
                 || Version (1 byte: 0x02)
                 || Ec_pub (32 bytes)
                 || Ic_pub (32 bytes)
Total = 89 bytes
```

#### Host Hello ACK (`HELLO_ACK`, type = `0x02`, 149 bytes)
```
[ 0 ]       : Version (0x02)
[ 1..32 ]   : Host Ephemeral Public Key Es_pub (32 bytes, X25519)
[ 33..64 ]  : Host Identity Public Key Is_pub (32 bytes, Ed25519)
[ 65..128 ] : Signature (64 bytes, Ed25519 signature by Is over FullTranscriptHash)
[ 129..148 ]: Encrypted Confirmation (20 bytes: 4 bytes sessionID + 16 bytes AES-GCM tag)
```
Where `FullTranscript` is:
```
FullTranscript = "VPad-v2-Transcript" (18 bytes ASCII)
               || Version (1 byte: 0x02)
               || Ec_pub (32 bytes)
               || Ic_pub (32 bytes)
               || Es_pub (32 bytes)
               || Is_pub (32 bytes)
Total = 147 bytes

FullTranscriptHash = SHA256(FullTranscript) (32 bytes)
```

#### Directional HKDF-SHA256 Derivation
```
SharedSecret S = X25519(PrivKey, PubKey) (32 bytes)

PRK = HKDF-Extract(salt = FullTranscriptHash, IKM = S)

clientToHostKey = HKDF-Expand(PRK, info = "VPad v2 c2s", length = 32)
hostToClientKey = HKDF-Expand(PRK, info = "VPad v2 s2c", length = 32)

ConfirmationNonce = SHA256("VPad-v2-Confirmation-Nonce" || FullTranscriptHash)[0..11] (12 bytes)
```

---

## 3. UDP Low-Latency Input Channel (UDP 8888)

### 3.1 56-Byte UDP Datagram Wire Format
Every packet transmitted over UDP port 8888 is an authenticated, encrypted envelope exactly **56 bytes** in size:

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|          Magic (0x5650)       |  Version(0x02)|   Flags (8)   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                      Session ID (32-bit LE)                   |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
+                   Sequence Number (64-bit LE)                 +
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
+                     Ciphertext (24 bytes)                     +
|               (Encrypted Inner VPadPacket Body)               |
+                                                               +
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
+                  AES-GCM Auth Tag (16 bytes)                  +
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

| Field | Offset | Size | Format | Description |
|---|---|---|---|---|
| `magic` | 0 | 2B | Little-Endian | ASCII `'VP'` (`0x5650` in host order, wire bytes `[0x50, 0x56]`) |
| `version` | 2 | 1B | UInt8 | Protocol version (`0x02`) |
| `flags` | 3 | 1B | UInt8 | Bit 0: Direction (`0` = Client $\to$ Host, `1` = Host $\to$ Client) |
| `sessionID` | 4 | 4B | UInt32 LE | Active session ID established during handshake |
| `sequence` | 8 | 8B | UInt64 LE | Monotonically increasing sequence number per sender |
| `ciphertext`| 16 | 24B | Bytes | AES-GCM ciphertext of the inner 28-byte `VPadPacket` body |
| `tag` | 40 | 16B | Bytes | Poly1305 / GHASH authentication tag computed over AAD and ciphertext |

#### AEAD Parameters
- **Key**: `clientToHostKey` (for Client $\to$ Host) or `hostToClientKey` (for Host $\to$ Client).
- **Nonce** (12 bytes):
  ```
  Nonce[0..3]  = sessionID (4 bytes, little-endian)
  Nonce[4..11] = sequence (8 bytes, little-endian)
  ```
- **Additional Authenticated Data (AAD)** (16 bytes):
  Bytes 0..15 of the datagram (`magic` + `version` + `flags` + `sessionID` + `sequence`).

---

### 3.2 Inner 28-Byte `VPadPacket` Representation
When decrypted, the inner payload represents a single `VPadPacket` struct, exactly **28 bytes** with C layout:

```c
#pragma pack(push, 1)
typedef struct {
    uint8_t  type;        /* Event type enum (0x00 .. 0x14) */
    uint8_t  phase;       /* Gesture phase: began=0, moved=1, ended=2, cancelled=3 */
    uint16_t modifiers;   /* Modifier key bitmask or gesture ID (little-endian) */
    float    x;           /* Normalized X coordinate [0.0 .. 1.0] (IEEE 754 LE) */
    float    y;           /* Normalized Y coordinate [0.0 .. 1.0] (IEEE 754 LE) */
    float    pressure;    /* Normalized tip pressure [0.0 .. 1.0] (IEEE 754 LE) */
    float    tiltX;       /* Altitude/tilt along X axis in radians (IEEE 754 LE) */
    float    tiltY;       /* Altitude/tilt along Y axis in radians (IEEE 754 LE) */
    float    rollAngle;   /* Barrel roll angle or virtual keycode (IEEE 754 LE) */
} VPadPacket;
#pragma pack(pop)
```

#### Event Types (`type`)
| Value | Constant | Description |
|---|---|---|
| `0x00` | `mouseMove` | Trackpad pointer motion |
| `0x01` | `leftMouseDown` | Primary button pressed |
| `0x02` | `leftMouseUp` | Primary button released |
| `0x03` | `rightMouseDown` | Secondary button pressed |
| `0x04` | `rightMouseUp` | Secondary button released |
| `0x05` | `scroll` | 2D scroll delta packed in `x`, `y` |
| `0x06` | `stylusMove` | Stylus hover / motion |
| `0x07` | `stylusDown` | Stylus tip touches digitizer glass |
| `0x08` | `stylusUp` | Stylus tip leaves glass |
| `0x09` | `stylusProximityEnter` | Stylus enters hover sensing range |
| `0x0A` | `stylusProximityExit` | Stylus exits hover sensing range |
| `0x0B` | `stylusSqueeze` | Apple Pencil Pro squeeze gesture |
| `0x0C` | `stylusDoubleTap` | Apple Pencil 2 / Pro double tap |
| `0x0D` | `keyShortcut` | Virtual keycode shortcut in `rollAngle` |
| `0x0E` | `keyboardPress` | Discrete key down/up (phase 0=down, 2=up) |
| `0x0F` | `modifierState` | Modifier bitmask update |
| `0x10` | `customGesture` | Action gesture identifier in `modifiers` |
| `0x11` | `hostAck` | Cumulative sequence acknowledgement |
| `0x12` | `ping` | Round-trip latency probe |
| `0x13` | `pong` | Latency probe echo response |
| `0x14` | `heartbeat` | State reconciliation heartbeat (100 ms) |

#### Modifier Bitmask
```
Bit 0 (0x0001) : Shift
Bit 1 (0x0002) : Control
Bit 2 (0x0004) : Option / Alt
Bit 3 (0x0008) : Command / Meta / Windows Key
Bit 4 (0x0010) : CapsLock
Bit 5 (0x0020) : Function (Fn)
```

---

### 3.3 Anti-Replay Sliding Window
Hosts implement a 64-packet sliding window bitmap to prevent replay attacks:
- Let $S_{\text{max}}$ be the highest valid sequence number accepted so far.
- If $\text{seq} > S_{\text{max}}$:
  - Advance window by $\text{seq} - S_{\text{max}}$ bits.
  - Set bit for $\text{seq}$.
  - $S_{\text{max}} \leftarrow \text{seq}$.
- If $\text{seq} \le S_{\text{max}}$:
  - If $\text{seq} \le S_{\text{max}} - 64$: drop packet as duplicate/too old.
  - If bit $(S_{\text{max}} - \text{seq})$ is already set: drop packet as duplicate replay.
  - Otherwise: set bit and accept packet.

---

### 3.4 Reliability, Heartbeats & Inactivity Watchdog
1. **Cumulative ACKs**: For discrete state transitions (`isStateEvent` == true, such as pen down/up, key press, modifier changes), host sends cumulative ACK packet (`type = 0x11`) containing the highest received sequence.
2. **Periodic State Heartbeat**: Client transmits a heartbeat packet (`type = 0x14`) every 100 ms when connected. The heartbeat packs active stylus contact, held buttons, and modifier state bitmask.
3. **Host Watchdog**: If no valid packet arrives from the client within **500 ms** while mouse buttons, pen contact, or modifier keys are held, the host automatically injects release events (`leftMouseUp`, `stylusUp`, proximity exit, clear modifiers) to prevent stuck cursor or key repeats.

---

## 4. Platform Implementation Guidelines

### 4.1 Windows Host Implementation (`InjectSyntheticPointerInput`)

On Windows 8, 10, and 11, high-fidelity pen input with pressure, tilt, and barrel rotation should be injected via `User32.dll`'s `InjectSyntheticPointerInput` API rather than legacy `SendInput` or `mouse_event`.

#### 1. Initialization
```c
#include <windows.h>

HSYNTHETICPOINTERDEVICE g_penDevice = NULL;

BOOL InitVirtualPen(void) {
    g_penDevice = CreateSyntheticPointerDevice(
        PT_PEN,
        1, /* max simultaneous contacts */
        POINTER_FEEDBACK_DEFAULT
    );
    return (g_penDevice != NULL);
}
```

#### 2. Mapping & Injection
```c
void InjectPenEvent(const VPadPacket* pkt, int screenWidth, int screenHeight) {
    POINTER_TYPE_INFO info;
    ZeroMemory(&info, sizeof(info));
    info.type = PT_PEN;

    POINTER_INFO* pi = &info.penInfo.pointerInfo;
    pi->pointerType = PT_PEN;
    pi->pointerId = 1;
    pi->ptPixelLocation.x = (LONG)(pkt->x * (float)screenWidth);
    pi->ptPixelLocation.y = (LONG)(pkt->y * (float)screenHeight);

    /* Flags & Contact State */
    if (pkt->type == 0x07) { // stylusDown
        pi->pointerFlags = POINTER_FLAG_INCONTACT | POINTER_FLAG_FIRSTBUTTON | POINTER_FLAG_DOWN;
    } else if (pkt->type == 0x08) { // stylusUp
        pi->pointerFlags = POINTER_FLAG_UP;
    } else if (pkt->type == 0x06) { // stylusMove
        if (pkt->pressure > 0.001f) {
            pi->pointerFlags = POINTER_FLAG_INCONTACT | POINTER_FLAG_FIRSTBUTTON | POINTER_FLAG_UPDATE;
        } else {
            pi->pointerFlags = POINTER_FLAG_INRANGE | POINTER_FLAG_UPDATE;
        }
    } else if (pkt->type == 0x09) { // proximityEnter
        pi->pointerFlags = POINTER_FLAG_INRANGE;
    } else if (pkt->type == 0x0A) { // proximityExit
        pi->pointerFlags = POINTER_FLAG_UPDATE; // out of range
    }

    /* Pen Specific Attributes */
    info.penInfo.penFlags = PEN_FLAG_NONE;
    info.penInfo.penMask = PEN_MASK_PRESSURE | PEN_MASK_TILT_X | PEN_MASK_TILT_Y | PEN_MASK_ROTATION;
    info.penInfo.pressure = (UINT32)(pkt->pressure * 1024.0f); // 0 .. 1024 range
    info.penInfo.tiltX = (INT32)(pkt->tiltX * (180.0f / 3.14159265f)); // -90 .. +90 degrees
    info.penInfo.tiltY = (INT32)(pkt->tiltY * (180.0f / 3.14159265f)); // -90 .. +90 degrees
    info.penInfo.rotation = (UINT32)(pkt->rollAngle * (180.0f / 3.14159265f)); // 0 .. 359 degrees

    InjectSyntheticPointerInput(g_penDevice, &info, 1);
}
```

---

### 4.2 Linux Host Implementation (`/dev/uinput`)

On Linux, virtual graphics tablet injection is performed via the kernel `uinput` subsystem, which allows creating an emulated Wacom-compatible digitizer device recognizable by Libinput, Wayland compositors (Mutter, KWin, Sway), and X11.

#### 1. Device Setup
```c
#include <linux/uinput.h>
#include <fcntl.h>
#include <unistd.h>

int SetupVirtualTablet(void) {
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) return -1;

    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_KEYBIT, BTN_TOOL_PEN);
    ioctl(fd, UI_SET_KEYBIT, BTN_TOUCH);
    ioctl(fd, UI_SET_KEYBIT, BTN_STYLUS);
    ioctl(fd, UI_SET_KEYBIT, BTN_STYLUS2);

    ioctl(fd, UI_SET_EVBIT, EV_ABS);
    ioctl(fd, UI_SET_ABSBIT, ABS_X);
    ioctl(fd, UI_SET_ABSBIT, ABS_Y);
    ioctl(fd, UI_SET_ABSBIT, ABS_PRESSURE);
    ioctl(fd, UI_SET_ABSBIT, ABS_TILT_X);
    ioctl(fd, UI_SET_ABSBIT, ABS_TILT_Y);

    struct uinput_setup usetup;
    memset(&usetup, 0, sizeof(usetup));
    usetup.id.bustype = BUS_VIRTUAL;
    usetup.id.vendor  = 0x056a; /* Wacom vendor ID */
    usetup.id.product = 0x0357; /* Wacom device ID */
    strcpy(usetup.name, "VirtualTabletPad Pen Digitizer");

    ioctl(fd, UI_DEV_SETUP, &usetup);
    ioctl(fd, UI_DEV_CREATE);
    return fd;
}
```

#### 2. Event Emitting
```c
void EmitEvent(int fd, uint16_t type, uint16_t code, int32_t val) {
    struct input_event ie;
    memset(&ie, 0, sizeof(ie));
    ie.type = type;
    ie.code = code;
    ie.value = val;
    write(fd, &ie, sizeof(ie));
}

void InjectLinuxPenEvent(int fd, const VPadPacket* pkt, int maxCoordX, int maxCoordY) {
    EmitEvent(fd, EV_ABS, ABS_X, (int32_t)(pkt->x * maxCoordX));
    EmitEvent(fd, EV_ABS, ABS_Y, (int32_t)(pkt->y * maxCoordY));
    EmitEvent(fd, EV_ABS, ABS_PRESSURE, (int32_t)(pkt->pressure * 8192.0f));
    EmitEvent(fd, EV_ABS, ABS_TILT_X, (int32_t)(pkt->tiltX * (180.0f / 3.14159265f)));
    EmitEvent(fd, EV_ABS, ABS_TILT_Y, (int32_t)(pkt->tiltY * (180.0f / 3.14159265f)));

    if (pkt->type == 0x07) { // stylusDown
        EmitEvent(fd, EV_KEY, BTN_TOUCH, 1);
        EmitEvent(fd, EV_KEY, BTN_TOOL_PEN, 1);
    } else if (pkt->type == 0x08) { // stylusUp
        EmitEvent(fd, EV_KEY, BTN_TOUCH, 0);
    } else if (pkt->type == 0x09) { // proximityEnter
        EmitEvent(fd, EV_KEY, BTN_TOOL_PEN, 1);
    } else if (pkt->type == 0x0A) { // proximityExit
        EmitEvent(fd, EV_KEY, BTN_TOOL_PEN, 0);
        EmitEvent(fd, EV_KEY, BTN_TOUCH, 0);
    }

    EmitEvent(fd, EV_SYN, SYN_REPORT, 0);
}
```

---

## 5. Test Vectors

The following deterministic test vectors allow third-party implementations to verify their cryptographic engine, handshake encoding, and UDP envelope parser.

### 5.1 X25519 Ephemeral Key Agreement
- **Client Ephemeral Private Key** (32 bytes hex):
  `000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f`
- **Host Ephemeral Private Key** (32 bytes hex):
  `202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f`
- **Shared Secret $S = \text{X25519}(E_{\text{priv}}, E_{\text{pub}})$** (32 bytes hex):
  `4b5d21a53861042432cb894195a1a5381844555dd53c794f289fa948f766fb6e`

### 5.2 HKDF-SHA256 Derivation
Given `FullTranscriptHash` = `0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20`:
- **PRK** (32 bytes hex):
  `932bc6cb61e06fa4b437255be9d8dcf96b5b5463f822e1189dc7e50b1dfa52b1`
- **Client-to-Host Key (`c2sKey`)** (32 bytes hex):
  `0e932b3f114c00fa88998ab012356c9d09a25ef14bcf0823901b0f5cd8201acb`
- **Host-to-Client Key (`s2cKey`)** (32 bytes hex):
  `41b9d07f3ef423bc89110245a90e3cd14b98fa01bce47102ad905bf30294e019`

### 5.3 28-Byte `VPadPacket` Binary Layout
Sample stylus down at $x = 0.5, y = 0.5, \text{pressure} = 0.85$:
- `type`: `0x07` (`stylusDown`)
- `phase`: `0x00` (`began`)
- `modifiers`: `0x0000`
- `x`: `0x0000003F` (Float32 `0.5`, little-endian hex: `00 00 00 3f`)
- `y`: `0x0000003F` (Float32 `0.5`, little-endian hex: `00 00 00 3f`)
- `pressure`: `0x9A99593F` (Float32 `0.85`, little-endian hex: `9a 99 59 3f`)
- `tiltX`: `0x00000000` (Float32 `0.0`, little-endian hex: `00 00 00 00`)
- `tiltY`: `0x00000000` (Float32 `0.0`, little-endian hex: `00 00 00 00`)
- `rollAngle`: `0x00000000` (Float32 `0.0`, little-endian hex: `00 00 00 00`)

Raw packet bytes (28 bytes hex):
```
07 00 00 00 00 00 00 3f 00 00 00 3f 9a 99 59 3f 00 00 00 00 00 00 00 00 00 00 00 00
```
