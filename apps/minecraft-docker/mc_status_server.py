#!/usr/bin/env python3
import socket
import json
import struct
from http.server import HTTPServer, BaseHTTPRequestHandler

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        data = {"online": False, "version": "", "players": 0, "max_players": 0}
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(3)
            s.connect(("minecraft", 25565))
            s.send(b"\xfe\x01")
            raw = s.recv(4096)
            if raw and raw[0] == 0xff:
                raw = raw[3:].decode("utf-16be", errors="ignore")
                parts = raw.split("\x00")
                data = {
                    "online": True,
                    "version": parts[2] if len(parts) > 2 else "",
                    "players": int(parts[4]) if len(parts) > 4 else 0,
                    "max_players": int(parts[5]) if len(parts) > 5 else 0
                }
            s.close()
        except Exception:
            pass

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(json.dumps(data).encode("utf-8"))

    def log_message(self, format, *args):
        # Suppress noisy HTTP access logs
        pass

if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", 8082), Handler)
    server.serve_forever()
