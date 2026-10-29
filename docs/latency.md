# Latency Measurement & Benchmark (§3.5)

This document specifies how VirtualTabletPad measures network and input latency, the exact definitions used across documentation, and how to run `Tools/latency-bench`.

---

## 1. Latency Terminology & Definitions

In remote input devices, "latency" often conflates transport transmission time with full display pipeline delay. VirtualTabletPad strictly distinguishes between these two concepts:

```
[Stylus Tip on Glass]
        │
        ▼  iPad Digitizer Scan (120Hz: ~8.3ms, 240Hz: ~4.2ms)
[UIKit Touch Callback]
        │
        ▼  Zero-copy VPadPacket serialization + ChaCha20-Poly1305 seal (<0.1ms)
[UDP / USB Socket Out]
        │
        ▼  Transport One-Way Delay (RTT / 2) (~0.2ms - 1.5ms)
[MacHost UDPServer]
        │
        ▼  ChaCha20-Poly1305 open + CGEventPost injection (<0.1ms)
[macOS WindowServer / Target App]
        │
        ▼  Compositor Frame & Display Scanout (60Hz: ~16.6ms, 120Hz: ~8.3ms)
[Cursor / Canvas Ink Moves on Screen]
```

### A. Round-Trip Time (RTT)
The elapsed time between when the client generates a timestamped probe (`ping`) and when it receives the echoed response (`pong`) back from the host:
$$\text{RTT} = t_{\text{pong received}} - t_{\text{ping sent}}$$
`Tools/latency-bench` directly measures RTT.

### B. One-Way Transport Latency
The network delay from client socket to host socket. On symmetric, non-congested local networks:
$$\text{Latency}_{\text{transport}} \approx \frac{\text{RTT}}{2}$$
Typical values:
* **USB Cable (USBMux / CoreTelephony/Direct)**: RTT $\approx 0.2 - 0.5\text{ ms} \implies \text{one-way} < 0.25\text{ ms}$
* **Local 5GHz / 6GHz Wi-Fi (Quiet)**: RTT $\approx 1.0 - 3.0\text{ ms} \implies \text{one-way} \approx 0.5 - 1.5\text{ ms}$
* **Crowded 2.4GHz Wi-Fi**: RTT $\approx 4.0 - 15.0\text{ ms} \implies \text{one-way} \approx 2.0 - 7.5\text{ ms}$

### C. Touch-to-Cursor Latency (End-to-End Glass-to-Glass)
The total time from the physical Apple Pencil contacting the iPad digitizer to the rendered pixel moving on the macOS display:
$$\text{Latency}_{\text{touch-to-cursor}} = T_{\text{digitizer}} + T_{\text{client}} + \text{Latency}_{\text{transport}} + T_{\text{host}} + T_{\text{display}}$$

| Pipeline Stage | 60 Hz Mac Display | 120 Hz ProMotion Mac Display |
|---|---|---|
| iPad Pencil Scan (240 Hz digitizer) | ~4.2 ms | ~4.2 ms |
| Client Serialization & Crypto | < 0.1 ms | < 0.1 ms |
| Transport One-Way (5GHz Wi-Fi) | ~1.0 ms | ~1.0 ms |
| Host Decryption & CGEventPost | < 0.1 ms | < 0.1 ms |
| Mac Display Refresh & Composition | ~8.3 – 16.6 ms | ~4.1 – 8.3 ms |
| **Total Glass-to-Glass Latency** | **~14 – 22 ms** | **~9 – 14 ms** |

> **IMPORTANT**: Marketing materials or descriptions must never advertise transport RTT (~1ms) as glass-to-glass touch latency (~12-18ms). VirtualTabletPad explicitly reports transport RTT as transport metrics and clearly explains display scanout contributions.

---

## 2. Statistical Metrics & Jitter Calculation

`LatencyMetrics` computes robust statistics over sample collections:

1. **Percentiles ($p_{50}, p_{95}, p_{99}$)**:
   Calculated using linear interpolation over ordered sample ranks:
   $$\text{Rank} = p \times (N - 1)$$
   $p_{50}$ represents typical operational latency, while $p_{99}$ captures tail buffering delays or radio channel retries.
2. **RFC 3550 Interarrival Jitter ($J$)**:
   $$\Delta_i = |\text{RTT}_i - \text{RTT}_{i-1}|$$
   $$J_i = J_{i-1} + \frac{\Delta_i - J_{i-1}}{16}$$
   Provides a smoothed 16-sample running average of network variance, filtering single-probe outliers while exposing periodic radio scheduling jitter.

---

## 3. Wire Protocol Probes

Probes are supported on both UDP and TCP transports without changing frozen packet layouts:

### UDP Probe (`VPadPacket`)
* **Ping (`type: 0x51`)**:
  * `x`, `y` (Float32 bit patterns): 64-bit client high-resolution timestamp (`mach_absolute_time`)
  * `modifiers`: 16-bit sequence/probe identifier
* **Pong (`type: 0x52`)**:
  * `x`, `y`: Echoes original client timestamp
  * `pressure`, `tiltX`: Host timestamp at receipt (`mach_absolute_time`)
  * `modifiers`: Echoes probe identifier

### TCP Probe (`VPadFrame`)
* **Ping (`type: 0x04`)**: 8-byte big-endian timestamp payload.
* **Pong (`type: 0x05`)**: Echoes the 8-byte big-endian timestamp.

---

## 4. Running the Benchmark Tool

Run the automated in-process loopback benchmark:
```bash
make latency-bench
```

Or invoke the binary directly with custom parameters:
```bash
./build/latency-bench --self-test --count 200 --interval 5.0
```

To run against a remote MacHost instance:
```bash
./build/latency-bench --host 192.168.1.50 --udp-port 21420 --count 500
```
