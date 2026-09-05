#!/usr/bin/env python3
"""Short integrity/half-close test, capped at 1 Mbps in each direction."""
import argparse
import hashlib
import json
import socket
import time

parser = argparse.ArgumentParser()
parser.add_argument("--host", default="127.0.0.1")
parser.add_argument("--port", type=int, default=18080)
parser.add_argument("--chunks", type=int, default=64)
args = parser.parse_args()
if not 1 <= args.chunks <= 128:
    parser.error("chunks must be 1..128 (maximum 1 MiB)")
start = time.monotonic()
digest = hashlib.sha256()
with socket.create_connection((args.host, args.port), timeout=20) as conn:
    for index in range(args.chunks):
        data = hashlib.sha256(str(index).encode()).digest() * 256
        conn.sendall(data)
        received = b""
        while len(received) < len(data):
            part = conn.recv(len(data) - len(received))
            if not part:
                raise RuntimeError("premature EOF")
            received += part
        if received != data:
            raise RuntimeError("data corruption")
        digest.update(received)
        time.sleep(max(0, start + (index + 1) * 8192 / 125000 - time.monotonic()))
    conn.shutdown(socket.SHUT_WR)
    trailer = b""
    while True:
        part = conn.recv(4096)
        if not part:
            break
        trailer += part
    if trailer != b"EOF-OK":
        raise RuntimeError("half-close response lost: " + repr(trailer))
print(json.dumps(dict(ok=True, bytes_each_direction=args.chunks * 8192,
                     elapsed=round(time.monotonic() - start, 3), sha256=digest.hexdigest())))
