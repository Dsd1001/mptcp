#!/usr/bin/env python3
"""Bounded loopback-only echo backend for live tunnel verification."""
import socketserver


class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(30)
        remaining = 2 * 1024 * 1024
        try:
            while remaining:
                data = self.request.recv(min(16384, remaining))
                if not data:
                    self.request.sendall(b"EOF-OK")
                    return
                remaining -= len(data)
                self.request.sendall(data)
        except (TimeoutError, ConnectionError):
            pass


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


with Server(("127.0.0.1", 22001), Echo) as server:
    server.serve_forever()
