#!/usr/bin/env python3
"""One-time Google Calendar OAuth bootstrap for CallDrop.

Prereq (one-time, ~5 min):
  1. https://console.cloud.google.com → create a project (any name)
  2. APIs & Services → Library → enable "Google Calendar API"
  3. APIs & Services → OAuth consent screen → External → fill app name/email →
     Publish app (status "In production"; the unverified warning is fine for
     personal use — this keeps the refresh token from expiring after 7 days)
  4. APIs & Services → Credentials → Create credentials → OAuth client ID →
     Desktop app → copy the Client ID and Client Secret

Then run:  python3 google_calendar_auth.py CLIENT_ID CLIENT_SECRET
A browser opens; approve read-only calendar access. Credentials land in
~/.config/calldrop/google.json where the CallDrop app picks them up within a minute.
"""

import http.server
import json
import sys
import threading
import urllib.parse
import urllib.request
import webbrowser
from pathlib import Path

PORT = 8765
REDIRECT = f"http://localhost:{PORT}"
SCOPE = "https://www.googleapis.com/auth/calendar.readonly"

code_holder = {}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        code_holder["code"] = qs.get("code", [None])[0]
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(b"<h2>CallDrop connected to Google Calendar. You can close this tab.</h2>")

    def log_message(self, *a):
        pass


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)
    client_id, client_secret = sys.argv[1], sys.argv[2]

    auth_url = (
        "https://accounts.google.com/o/oauth2/v2/auth?"
        + urllib.parse.urlencode({
            "client_id": client_id,
            "redirect_uri": REDIRECT,
            "response_type": "code",
            "scope": SCOPE,
            "access_type": "offline",
            "prompt": "consent",
        })
    )

    server = http.server.HTTPServer(("localhost", PORT), Handler)
    threading.Thread(target=server.handle_request, daemon=True).start()
    print("Opening browser for Google consent…")
    webbrowser.open(auth_url)

    import time
    for _ in range(300):
        if code_holder.get("code"):
            break
        time.sleep(1)
    else:
        sys.exit("Timed out waiting for Google consent.")

    body = urllib.parse.urlencode({
        "code": code_holder["code"],
        "client_id": client_id,
        "client_secret": client_secret,
        "redirect_uri": REDIRECT,
        "grant_type": "authorization_code",
    }).encode()
    req = urllib.request.Request("https://oauth2.googleapis.com/token", data=body)
    with urllib.request.urlopen(req, timeout=30) as resp:
        tokens = json.loads(resp.read())

    refresh = tokens.get("refresh_token")
    if not refresh:
        sys.exit(f"No refresh token returned: {tokens}")

    out = Path.home() / ".config" / "calldrop" / "google.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({
        "client_id": client_id,
        "client_secret": client_secret,
        "refresh_token": refresh,
    }, indent=1))
    out.chmod(0o600)
    print(f"Saved {out} — CallDrop will start watching your calendar within a minute.")


if __name__ == "__main__":
    main()
