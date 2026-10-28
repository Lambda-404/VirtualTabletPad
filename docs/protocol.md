# VirtualTabletPad Protocol Specification (v2)

This specification defines the cryptographic handshake, session establishment, and directional key schedule for VirtualTabletPad Protocol v2 (Task 1.3).

---

## 1. Overview & Primitives

- **Long-term Identity**: Curve25519 Ed25519 signatures (`Curve25519.Signing`).
- **Ephemeral Key Agreement**: Curve25519 X25519 ECDH (`Curve25519.KeyAgreement`).
- **Key Derivation Function**: HKDF-SHA256 (`salt: transcriptHash`, `info: "VPad v2 c2s"` / `"VPad v2 s2c"`).
- **Session Encryption**: AES-GCM-256 with 128-bit authentication tag.
- **Port Assignment**:
  - Control & Handshake Channel: TCP port 8889.
  - Low-Latency Input Channel: UDP port 8888.

---

## 2. Handshake Message Flow

```mermaid
sequenceDiagram
    autonumber
    participant iPad as iPad Client (Ic, Ec)
    participant Mac as Mac Host (Is, Es)

    Note over iPad,Mac: 1. TCP Connection Established on port 8889
    iPad->>Mac: Frame 0x01 (HELLO) [129 bytes]<br/>version (0x02) | Ec_pub (32B) | Ic_pub (32B) | sig_Ic(ClientTranscript) (64B)
    Note over Mac: Verify client signature<br/>Verify Ic_pub against allowlist<br/>Compute shared secret S = X25519(Es_priv, Ec_pub)<br/>Compute transcriptHash<br/>Derive (c2sKey, s2cKey) via HKDF-SHA256<br/>Encrypt sessionID with s2cKey
    Mac->>iPad: Frame 0x02 (HELLO_ACK) [149 bytes]<br/>version (0x02) | Es_pub (32B) | Is_pub (32B) | sig_Is(transcriptHash) (64B) | enc_s2c(sessionID) (20B)
    Note over iPad: Verify Is_pub matches pinned host key<br/>Compute S = X25519(Ec_priv, Es_pub)<br/>Compute transcriptHash<br/>Verify server signature<br/>Derive (c2sKey, s2cKey)<br/>Decrypt sessionID
    Mac->>iPad: Frame 0x03 (READY)
    Note over iPad,Mac: Mutual authentication complete; UDP datagram input armed
```

---

## 3. Message Formats

### 3.1 Client Hello (`HELLO`, type = `0x01`)
Total payload size: **129 bytes**.

| Offset | Size | Field | Description |
|---|---|---|---|
| `0` | 1B | `version` | Protocol version (`0x02`) |
| `1..32` | 32B | `clientEphemeralPublicKey` | Raw representation of client X25519 ephemeral public key ($E_{c}$) |
| `33..64` | 32B | `clientIdentityPublicKey` | Raw representation of client Ed25519 long-term identity public key ($I_{c}$) |
| `65..128` | 64B | `signature` | Ed25519 signature by $I_{c}$ over `ClientTranscript` |

#### Client Transcript:
```
ClientTranscript = "VPad-v2-Handshake-Client" (24B) || version (1B) || clientEphemeralPublicKey (32B) || clientIdentityPublicKey (32B)
```

### 3.2 Server Hello ACK (`HELLO_ACK`, type = `0x02`)
Total payload size: **149 bytes**.

| Offset | Size | Field | Description |
|---|---|---|---|
| `0` | 1B | `version` | Protocol version (`0x02`) |
| `1..32` | 32B | `serverEphemeralPublicKey` | Raw representation of server X25519 ephemeral public key ($E_{s}$) |
| `33..64` | 32B | `serverIdentityPublicKey` | Raw representation of server Ed25519 long-term identity public key ($I_{s}$) |
| `65..128` | 64B | `signature` | Ed25519 signature by $I_{s}$ over `FullTranscriptHash` |
| `129..148` | 20B | `encryptedConfirmation` | AES-GCM ciphertext (4B `sessionID` big-endian) + 16B authentication tag |

#### Full Transcript Hash:
```
FullTranscript = "VPad-v2-Transcript" (18B)
               || version (1B)
               || clientEphemeralPublicKey (32B)
               || clientIdentityPublicKey (32B)
               || serverEphemeralPublicKey (32B)
               || serverIdentityPublicKey (32B)

FullTranscriptHash = SHA256(FullTranscript) (32 bytes)
```

---

## 4. Key Schedule

Shared secret $S$ is computed using standard Curve25519 Diffie-Hellman key agreement:
$$S = \text{X25519}(E_{s, \text{priv}}, E_{c, \text{pub}}) = \text{X25519}(E_{c, \text{priv}}, E_{s, \text{pub}})$$

Directional session keys are extracted and expanded using HKDF-SHA256:
- $\text{PRK} = \text{HKDF-Extract}(\text{salt} = \text{FullTranscriptHash}, \text{IKM} = S)$
- $\text{clientToHostKey} = \text{HKDF-Expand}(\text{PRK}, \text{info} = \text{"VPad v2 c2s"}, \text{length} = 32)$
- $\text{hostToClientKey} = \text{HKDF-Expand}(\text{PRK}, \text{info} = \text{"VPad v2 s2c"}, \text{length} = 32)$

### Confirmation Nonce:
The nonce used for `encryptedConfirmation` is 12 bytes derived as:
$$\text{ConfirmationNonce} = \text{SHA256}(\text{"VPad-v2-Confirmation-Nonce"} \mathbin{\Vert} \text{FullTranscriptHash})[0\dots 11]$$
