#!/usr/bin/env python3
"""
sync_api.py — API per esporre rustunes sul Raspberry Pi.

L'app mobile (o qualsiasi client) può:
  POST /api/sync/files/<name>   -> carica un file audio in /music/inbox
  POST /api/sync/run            -> esegue `rustunes sync /music/inbox`
  GET  /api/sync/status         -> output dell'ultimo run
  GET  /api/sync/health         -> ok

Auth: header `Authorization: Bearer <SYNC_TOKEN>`

Variabili d'ambiente:
  SYNC_TOKEN        (obbligatoria) token condiviso con l'app
  MUSIC_DIR         (default: /home/pi/music/inbox)
  IPHONE_ADDR       (default: 10.66.0.2) IP WireGuard dell'iPhone
  RUSTUNES_BIN      (default: /usr/local/bin/rustunes)
  LISTEN_PORT       (default: 8787)
  LISTEN_HOST       (default: 0.0.0.0 — metti 127.0.0.1 dietro Caddy/Nginx)
"""

import json
import os
import re
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

TOKEN = os.environ.get("SYNC_TOKEN", "RXzDPp5ucM7VQhM0NK4mUycBDgWlq9l7")
MUSIC_DIR = Path(os.environ.get("MUSIC_DIR", "/home/pi/music/inbox"))
IPHONE_ADDR = os.environ.get("IPHONE_ADDR", "10.66.0.2")
RUSTUNES = os.environ.get("RUSTUNES_BIN", "/usr/local/bin/rustunes")
HOST = os.environ.get("LISTEN_HOST", "0.0.0.0")
PORT = int(os.environ.get("LISTEN_PORT", "8787"))

MUSIC_DIR.mkdir(parents=True, exist_ok=True)

_lock = threading.Lock()
_last_run = {"status": "idle", "output": "", "rc": None}

SAFE_NAME = re.compile(r"[^A-Za-z0-9._\- ()\[\]]+")


def check_auth(handler):
    auth = handler.headers.get("Authorization", "")
    return auth == f"Bearer {TOKEN}"


def json_response(handler, code, obj):
    body = json.dumps(obj).encode()
    handler.send_response(code)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print(f"[sync-api] {self.client_address[0]} {fmt % args}")

    # ---------- GET ----------
    def do_GET(self):
        path = urlparse(self.path).path

        if path == "/api/sync/health":
            if not check_auth(self):
                return json_response(self, 401, {"error": "auth"})
            return json_response(self, 200, {"ok": True})

        if path == "/api/sync/status":
            if not check_auth(self):
                return json_response(self, 401, {"error": "auth"})
            with _lock:
                return json_response(self, 200, dict(_last_run))

        if path == "/api/sync/files":
            if not check_auth(self):
                return json_response(self, 401, {"error": "auth"})
            files = []
            for f in sorted(MUSIC_DIR.iterdir()):
                if f.is_file():
                    files.append({"name": f.name, "size": f.stat().st_size})
            return json_response(self, 200, {"files": files})

        json_response(self, 404, {"error": "not found"})

    # ---------- POST ----------
    def do_POST(self):
        path = urlparse(self.path).path

        if not check_auth(self):
            return json_response(self, 401, {"error": "auth"})

        # Upload file: POST /api/sync/files/<name>  (body = bytes)
        if path.startswith("/api/sync/files/"):
            name = unquote(path[len("/api/sync/files/"):])
            name = SAFE_NAME.sub("_", Path(name).name) or "track.bin"
            length = int(self.headers.get("Content-Length", "0"))
            dest = MUSIC_DIR / name
            tmp = MUSIC_DIR / (name + ".part")
            remaining = length
            try:
                with open(tmp, "wb") as out:
                    while remaining > 0:
                        chunk = self.rfile.read(min(1 << 20, remaining))
                        if not chunk:
                            break
                        out.write(chunk)
                        remaining -= len(chunk)
                tmp.replace(dest)
            except Exception as e:
                tmp.unlink(missing_ok=True)
                return json_response(self, 500, {"error": str(e)})
            return json_response(self, 200, {"ok": True, "name": name, "size": dest.stat().st_size})

        # Lancia sync: POST /api/sync/run  {"action":"sync"|"push"|"pull"}
        if path == "/api/sync/run":
            try:
                length = int(self.headers.get("Content-Length", "0"))
                body = json.loads(self.rfile.read(length) or b"{}")
            except Exception:
                body = {}
            action = body.get("action", "sync")
            if action not in ("sync", "push", "pull"):
                return json_response(self, 400, {"error": "action must be sync|push|pull"})

            cmd = [RUSTUNES]
            if action == "push":
                cmd += ["push", str(MUSIC_DIR)]
            elif action == "pull":
                cmd += ["pull"]
            else:
                cmd += ["--wifi-address", IPHONE_ADDR, "sync", str(MUSIC_DIR)]

            # sync/push vogliono --wifi-address solo se passano da Wi-Fi
            if action in ("push",) :
                cmd = [RUSTUNES, "--wifi-address", IPHONE_ADDR] + cmd[1:]

            def run():
                try:
                    proc = subprocess.run(
                        cmd, capture_output=True, text=True, timeout=3600
                    )
                    out = (proc.stdout or "") + (proc.stderr or "")
                    with _lock:
                        _last_run.update(
                            status="done" if proc.returncode == 0 else "error",
                            output=out[-8000:],
                            rc=proc.returncode,
                        )
                except Exception as e:
                    with _lock:
                        _last_run.update(status="error", output=str(e), rc=-1)

            threading.Thread(target=run, daemon=True).start()
            return json_response(self, 202, {"ok": True, "action": action})

        json_response(self, 404, {"error": "not found"})


if __name__ == "__main__":
    if not TOKEN:
        raise SystemExit("SYNC_TOKEN non impostato: esportalo prima di avviare.")
    print(f"sync-api in ascolto su {HOST}:{PORT} — music dir: {MUSIC_DIR}")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
