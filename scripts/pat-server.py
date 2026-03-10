#!/usr/bin/env python3
"""
Simple local PAT server for pre-filling Forgejo migration "access token" field.
Usage:
  python3 scripts/pat-server.py          # reads GITHUB_PAT from .env or env

Security:
- Serves token only on localhost and prints a helpful startup message.
- Adds CORS header so a bookmarklet on the Forgejo UI can fetch it.
"""

from http.server import HTTPServer, BaseHTTPRequestHandler
import os
import pathlib

PORT = 8765


def load_pat_from_envfile(env_path: pathlib.Path):
    if not env_path.exists():
        return None
    with env_path.open() as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            k, v = line.split('=', 1)
            k = k.strip()
            v = v.strip().strip('"').strip("'")
            if k == 'GITHUB_PAT' and v:
                return v
    return None


class PATHandler(BaseHTTPRequestHandler):
    def _set_headers(self, code=200, content_type='text/plain'):
        self.send_response(code)
        self.send_header('Content-type', content_type)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def do_OPTIONS(self):
        self._set_headers()

    def do_GET(self):
        if self.path == '/pat':
            pat = os.getenv('GITHUB_PAT') or load_pat_from_envfile(pathlib.Path(__file__).resolve().parents[1] / '.env')
            if not pat:
                self._set_headers(404)
                self.wfile.write(b'')
                return
            self._set_headers(200)
            self.wfile.write(pat.encode('utf-8'))
            return

        if self.path == '/health':
            self._set_headers(200, 'text/plain')
            self.wfile.write(b'OK')
            return

        self._set_headers(404)
        self.wfile.write(b'')

    def log_message(self, format, *args):
        # Reduce noise: print minimal logs.
        print("[pat-server] " + (format % args))


if __name__ == '__main__':
    print(f"Starting PAT server on http://localhost:{PORT}/pat")
    print("Reads GITHUB_PAT from environment or .env at repo root.")
    print("Use Ctrl+C to stop. Only bind to localhost for safety.")
    server_address = ('127.0.0.1', PORT)
    httpd = HTTPServer(server_address, PATHandler)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print('\nShutting down')
        httpd.server_close()
