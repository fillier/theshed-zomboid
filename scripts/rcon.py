#!/usr/bin/env python3
"""Minimal Source RCON client for Project Zomboid.

Usage: rcon.py --host HOST --port PORT --password PASS <command>
"""
import argparse
import socket
import struct
import sys

SERVERDATA_AUTH = 3
SERVERDATA_AUTH_RESPONSE = 2
SERVERDATA_EXECCOMMAND = 2


def _pack(req_id, pkt_type, body):
    body_bytes = body.encode("utf-8") + b"\x00\x00"
    size = 4 + 4 + len(body_bytes)
    return struct.pack("<iii", size, req_id, pkt_type) + body_bytes


def _recv(sock):
    def read_exactly(n):
        buf = b""
        while len(buf) < n:
            chunk = sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("Connection closed by server")
            buf += chunk
        return buf

    size = struct.unpack("<i", read_exactly(4))[0]
    data = read_exactly(size)
    req_id, pkt_type = struct.unpack("<ii", data[:8])
    body = data[8:-2].decode("utf-8", errors="replace")
    return req_id, pkt_type, body


def rcon(host, port, password, command):
    with socket.create_connection((host, port), timeout=10) as sock:
        # Authenticate
        sock.sendall(_pack(1, SERVERDATA_AUTH, password))
        req_id, pkt_type, _ = _recv(sock)
        # Some servers send an extra empty packet before the auth response
        if pkt_type != SERVERDATA_AUTH_RESPONSE:
            req_id, pkt_type, _ = _recv(sock)
        if req_id == -1:
            raise PermissionError("RCON authentication failed — check RCON_PASSWORD")

        # Execute command
        sock.sendall(_pack(2, SERVERDATA_EXECCOMMAND, command))
        _, _, body = _recv(sock)
        return body


def main():
    parser = argparse.ArgumentParser(description="Send an RCON command to a PZ server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=27015)
    parser.add_argument("--password", required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    cmd = " ".join(args.command)
    if not cmd:
        parser.error("No command specified")

    try:
        result = rcon(args.host, args.port, args.password, cmd)
        if result:
            print(result)
        return 0
    except Exception as exc:
        print(f"rcon error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
