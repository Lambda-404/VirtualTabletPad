#!/usr/bin/env python3
"""Development probe for the VirtualTabletPad macOS host.

Acts as a minimal iPad client: performs the E2EE handshake, sends encrypted
PING/UDP packets, and uploads files. This tool is for local verification only
and is not part of the app bundle.

Requires: Python 3.10+ and `cryptography` (tested with cryptography 48).
"""

from __future__ import annotations

import argparse
import hashlib
import os
import socket
import struct
import sys
import time
import uuid
from pathlib import Path

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import x25519
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

PROTOCOL_VERSION = 1
TCP_DIR_CLIENT_TO_HOST = 3
TCP_DIR_HOST_TO_CLIENT = 4
UDP_DIR_CLIENT_TO_HOST = 1

HELLO = 0x01
HELLO_ACK = 0x02
READY = 0x03
PING = 0x04
PONG = 0x05
STATS = 0x06
ERROR = 0x07

FILE_HEADER = 0x30
FILE_CHUNK = 0x31
FILE_TRAILER = 0x32
FILE_STATUS = 0x33
FILE_ABORT = 0x34

CHUNK_SIZE = 65_536
MAX_FRAME = 1 << 20

HKDF_SALT = b"VPadSalt"
HKDF_INFO = b"VPadSessionKey"


def nonce(direction: int, counter: int) -> bytes:
    return struct.pack(">I", direction) + struct.pack(">Q", counter)


def packet(trackpad_move: bool = True) -> bytes:
    """28-byte VPadPacket. Trackpad move with zero delta is inert."""
    packet_type = 0x01 if trackpad_move else 0x11
    phase = 0x01
    modifiers = 0
    return struct.pack("<BBHffffff", packet_type, phase, modifiers, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)


def sha256_file(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


class Probe:
    def __init__(self, host: str, tcp_port: int, udp_port: int) -> None:
        self.host = host
        self.udp_port = udp_port
        self.sock = socket.create_connection((host, tcp_port), timeout=5)
        self.sock.settimeout(5)
        self.udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.private_key = x25519.X25519PrivateKey.generate()
        self.public_key = self.private_key.public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw
        )
        self.key: bytes | None = None
        self.aes: AESGCM | None = None
        self.send_counter = 0
        self.recv_counter = 0
        self.udp_counter = 0
        self.received_types: list[int] = []

    # MARK: - Byte I/O

    def recv_exact(self, count: int) -> bytes:
        buffer = bytearray()
        while len(buffer) < count:
            chunk = self.sock.recv(count - len(buffer))
            if not chunk:
                raise RuntimeError("TCP connection closed by host")
            buffer.extend(chunk)
        return bytes(buffer)

    def send_frame_plain(self, frame_type: int, body: bytes = b"") -> None:
        payload = bytes([frame_type]) + body
        self.sock.sendall(struct.pack(">I", len(payload)) + payload)

    def recv_frame_plain(self) -> tuple[int, bytes]:
        length = struct.unpack(">I", self.recv_exact(4))[0]
        if length == 0 or length > MAX_FRAME:
            raise RuntimeError(f"invalid frame length {length}")
        payload = self.recv_exact(length)
        return payload[0], payload[1:]

    def send_frame_enc(self, frame_type: int, body: bytes = b"") -> None:
        if self.aes is None:
            raise RuntimeError("session key not established")
        plaintext = bytes([frame_type]) + body
        counter = self.send_counter
        encrypted = self.aes.encrypt(nonce(TCP_DIR_CLIENT_TO_HOST, counter), plaintext, None)
        self.send_counter += 1
        self.sock.sendall(struct.pack(">I", len(encrypted)) + encrypted)

    def recv_frame_enc(self) -> tuple[int, bytes]:
        if self.aes is None:
            raise RuntimeError("session key not established")
        length = struct.unpack(">I", self.recv_exact(4))[0]
        if length == 0 or length > MAX_FRAME:
            raise RuntimeError(f"invalid encrypted frame length {length}")
        encrypted = self.recv_exact(length)
        counter = self.recv_counter
        plaintext = self.aes.decrypt(nonce(TCP_DIR_HOST_TO_CLIENT, counter), encrypted, None)
        self.recv_counter += 1
        frame_type = plaintext[0]
        self.received_types.append(frame_type)
        return frame_type, plaintext[1:]

    # MARK: - Handshake

    def handshake(self) -> None:
        self.send_frame_plain(HELLO, bytes([PROTOCOL_VERSION]) + self.public_key)
        got_ack = False
        got_ready = False
        deadline = time.time() + 5
        while time.time() < deadline and not (got_ack and got_ready):
            frame_type, body = self.recv_frame_plain()
            if frame_type == ERROR:
                code = body[0] if body else -1
                raise RuntimeError(f"host rejected handshake with error {code}")
            if frame_type == HELLO_ACK:
                if len(body) != 33:
                    raise RuntimeError(f"bad HELLO_ACK body length {len(body)}")
                if body[0] != PROTOCOL_VERSION:
                    raise RuntimeError(f"protocol version mismatch {body[0]}")
                remote = x25519.X25519PublicKey.from_public_bytes(body[1:])
                shared = self.private_key.exchange(remote)
                self.key = HKDF(
                    algorithm=hashes.SHA256(),
                    length=32,
                    salt=HKDF_SALT,
                    info=HKDF_INFO,
                ).derive(shared)
                self.aes = AESGCM(self.key)
                got_ack = True
            elif frame_type == READY:
                got_ready = True
        if not (got_ack and got_ready):
            raise RuntimeError("handshake did not complete (missing HELLO_ACK/READY)")
        print("PASS handshake (HELLO / HELLO_ACK / READY, HKDF session key)")

    # MARK: - PING / STATS

    def ping(self) -> tuple[int, int]:
        timestamp = time.time_ns() & 0xFFFFFFFFFFFFFFFF
        self.send_frame_enc(PING, struct.pack(">Q", timestamp))
        pong: bytes | None = None
        stats: tuple[int, int] | None = None
        deadline = time.time() + 5
        while time.time() < deadline and (pong is None or stats is None):
            frame_type, body = self.recv_frame_enc()
            if frame_type == PONG:
                if len(body) != 8 or struct.unpack(">Q", body)[0] != timestamp:
                    raise RuntimeError("PONG body mismatch")
                pong = body
            elif frame_type == STATS:
                if len(body) != 16:
                    raise RuntimeError(f"bad STATS body length {len(body)}")
                stats = struct.unpack(">QQ", body)
            elif frame_type == ERROR:
                code = body[0] if body else -1
                raise RuntimeError(f"host error {code} while waiting for PONG/STATS")
        if pong is None or stats is None:
            raise RuntimeError("missing PONG or STATS")
        return stats

    # MARK: - UDP

    def send_udp(self, envelope: bytes) -> None:
        self.udp_sock.sendto(envelope, (self.host, self.udp_port))

    def build_udp(self, counter: int | None = None) -> tuple[bytes, int]:
        if self.aes is None:
            raise RuntimeError("session key not established")
        if counter is None:
            counter = self.udp_counter
            self.udp_counter += 1
        n = nonce(UDP_DIR_CLIENT_TO_HOST, counter)
        return n + self.aes.encrypt(n, packet(), None), counter

    # MARK: - Files

    def upload_file(self, name: str, size: int, bad_checksum: bool = False) -> tuple[int, str, str]:
        name_bytes = name.encode("utf-8")
        header = struct.pack(">H", len(name_bytes)) + name_bytes + struct.pack(">Q", size)
        self.send_frame_enc(FILE_HEADER, header)

        hasher = hashlib.sha256()
        block = bytes((index * 37 + 11) & 0xFF for index in range(CHUNK_SIZE))
        remaining = size
        while remaining > 0:
            length = min(CHUNK_SIZE, remaining)
            data = block[:length]
            hasher.update(data)
            self.send_frame_enc(FILE_CHUNK, struct.pack(">I", length) + data)
            remaining -= length

        digest = bytearray(hasher.digest())
        expected_hex = hasher.hexdigest()
        if bad_checksum:
            digest[0] ^= 0xFF
        self.send_frame_enc(FILE_TRAILER, bytes(digest))

        status: int | None = None
        deadline = time.time() + 30
        while time.time() < deadline and status is None:
            frame_type, body = self.recv_frame_enc()
            if frame_type == FILE_STATUS:
                if len(body) != 1:
                    raise RuntimeError(f"bad FILE_STATUS body length {len(body)}")
                status = body[0]
            elif frame_type == STATS:
                continue
            elif frame_type == ERROR:
                code = body[0] if body else -1
                raise RuntimeError(f"host error {code} during file upload")
            else:
                raise RuntimeError(f"unexpected frame 0x{frame_type:02x} during file upload")
        if status is None:
            raise RuntimeError("missing FILE_STATUS")
        return status, expected_hex, name

    def abort_upload(self, name: str, size: int) -> int:
        name_bytes = name.encode("utf-8")
        header = struct.pack(">H", len(name_bytes)) + name_bytes + struct.pack(">Q", size)
        self.send_frame_enc(FILE_HEADER, header)
        chunk = b"A" * min(CHUNK_SIZE, size)
        self.send_frame_enc(FILE_CHUNK, struct.pack(">I", len(chunk)) + chunk)
        self.send_frame_enc(FILE_ABORT)

        status: int | None = None
        deadline = time.time() + 10
        while time.time() < deadline and status is None:
            frame_type, body = self.recv_frame_enc()
            if frame_type == FILE_STATUS:
                if len(body) != 1:
                    raise RuntimeError(f"bad FILE_STATUS body length {len(body)}")
                status = body[0]
            elif frame_type == STATS:
                continue
            elif frame_type == ERROR:
                code = body[0] if body else -1
                raise RuntimeError(f"host error {code} during file abort")
            else:
                raise RuntimeError(f"unexpected frame 0x{frame_type:02x} during file abort")
        if status is None:
            raise RuntimeError("missing FILE_STATUS after abort")
        return status


def main() -> int:
    parser = argparse.ArgumentParser(description="VirtualTabletPad macOS host probe")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--tcp-port", type=int, default=8889)
    parser.add_argument("--udp-port", type=int, default=8888)
    parser.add_argument(
        "--uploads",
        default=str(Path.home() / "Downloads" / "VirtualTabletUploads"),
        help="must match the host's VPAD_UPLOADS_DIR",
    )
    parser.add_argument("--size-mb", type=int, default=1)
    parser.add_argument("--skip-udp", action="store_true")
    parser.add_argument("--skip-files", action="store_true")
    parser.add_argument("--keep-files", action="store_true")
    args = parser.parse_args()

    uploads = Path(args.uploads).expanduser().resolve()
    uploads.mkdir(parents=True, exist_ok=True)
    print(f"uploads directory: {uploads}")

    probe: Probe | None = None
    created: list[Path] = []
    try:
        probe = Probe(args.host, args.tcp_port, args.udp_port)
        probe.handshake()

        dropped, last_nonce = probe.ping()
        if dropped != 0 or last_nonce != 0:
            raise RuntimeError(f"unexpected initial STATS dropped={dropped} last={last_nonce}")
        print("PASS PING/PONG + STATS")

        if not args.skip_udp:
            envelope, _ = probe.build_udp(0)
            probe.send_udp(envelope)
            time.sleep(0.2)
            probe.send_udp(envelope)  # replay counter 0
            tampered, _ = probe.build_udp(1)
            tampered = tampered[:-1] + bytes([tampered[-1] ^ 0x01])
            probe.send_udp(tampered)

            dropped, last_nonce = probe.ping()
            if last_nonce != 0:
                raise RuntimeError(f"replay/tamper advanced last nonce to {last_nonce}")
            if dropped < 2:
                raise RuntimeError(f"expected replay/tamper drops, STATS dropped={dropped}")
            print(f"PASS encrypted UDP accepted; replay/tamper dropped (dropped={dropped}, last={last_nonce})")

        if not args.skip_files:
            size = args.size_mb * 1024 * 1024
            name = f"vpad-probe-{uuid.uuid4().hex}.bin"
            status, expected_hex, _ = probe.upload_file(name, size)
            if status != 0:
                raise RuntimeError(f"file upload status {status} (expected 0)")
            destination = uploads / name
            created.append(destination)
            if not destination.exists():
                raise RuntimeError(f"uploaded file not found at {destination}")
            actual_hex = sha256_file(destination)
            if actual_hex != expected_hex:
                raise RuntimeError("uploaded file SHA-256 mismatch")
            print(f"PASS file upload ({size} bytes, SHA-256 verified)")

            bad_name = f"vpad-bad-{uuid.uuid4().hex}.bin"
            bad_status, _, _ = probe.upload_file(bad_name, 1024 * 1024, bad_checksum=True)
            if bad_status != 1:
                raise RuntimeError(f"bad checksum status {bad_status} (expected 1)")
            if (uploads / bad_name).exists():
                raise RuntimeError("host kept a file with a bad checksum")
            print("PASS bad checksum rejected and partial removed")

            abort_name = f"vpad-abort-{uuid.uuid4().hex}.bin"
            abort_status = probe.abort_upload(abort_name, 4 * 1024 * 1024)
            if abort_status != 3:
                raise RuntimeError(f"abort status {abort_status} (expected 3)")
            if (uploads / abort_name).exists():
                raise RuntimeError("host kept a partial file after FILE_ABORT")
            print("PASS FILE_ABORT cancelled and cleaned partial")

            collision_name = f"vpad-collision-{uuid.uuid4().hex}.bin"
            first_status, _, _ = probe.upload_file(collision_name, 1024)
            second_status, _, _ = probe.upload_file(collision_name, 2048)
            if first_status != 0 or second_status != 0:
                raise RuntimeError(
                    f"collision upload statuses {first_status}/{second_status} (expected 0/0)"
                )
            matches = sorted(uploads.glob(f"*{collision_name}"))
            if len(matches) != 2:
                raise RuntimeError(f"expected 2 collision files, found {len(matches)}")
            created.extend(matches)
            print("PASS name collision preserved both files with UUID prefix")

            traversal = f"../../vpad-evil-{uuid.uuid4().hex}.txt"
            safe_name = Path(traversal).name
            traversal_status, _, _ = probe.upload_file(traversal, 1024)
            if traversal_status != 0:
                raise RuntimeError(f"traversal upload status {traversal_status} (expected 0)")
            safe_path = uploads / safe_name
            created.append(safe_path)
            if not safe_path.exists():
                raise RuntimeError(f"sanitized upload not found at {safe_path}")
            escape_path = uploads.parent.parent / safe_name
            if escape_path.exists():
                raise RuntimeError(f"path traversal escaped uploads directory: {escape_path}")
            print("PASS path traversal sanitized inside uploads")

        print("ALL PROBE CHECKS PASSED")
        return 0
    except Exception as error:  # noqa: BLE001 - CLI tool reports any failure
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    finally:
        if probe is not None:
            try:
                probe.sock.close()
            except OSError:
                pass
            try:
                probe.udp_sock.close()
            except OSError:
                pass
        if not args.keep_files:
            for path in created:
                try:
                    path.unlink(missing_ok=True)
                except OSError:
                    pass


if __name__ == "__main__":
    raise SystemExit(main())
