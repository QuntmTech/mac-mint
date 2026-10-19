#!/usr/bin/env python3
"""Preview web/dist with the same public/account routing as the Apache deployment."""

import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

ACCOUNT_ROUTES = {
    "/login", "/signup", "/account", "/forgot-password", "/reset-password", "/verify-email"
}


class SiteHandler(SimpleHTTPRequestHandler):
    def send_head(self):
        url = urlsplit(self.path)
        path = url.path[:-1] if url.path.endswith("/") else url.path
        if path == "/home2":
            self.send_response(301)
            self.send_header("Location", "/" + ("?" + url.query if url.query else ""))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return None
        if path in ACCOUNT_ROUTES:
            self.path = "/account-app.html"
        return super().send_head()

    def send_error(self, code, message=None, explain=None):
        page = Path(self.directory) / "404.html"
        if code != 404 or not page.is_file():
            return super().send_error(code, message, explain)
        body = page.read_bytes()
        self.send_response(404)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, default=Path("dist"))
    parser.add_argument("--port", type=int, default=4173)
    args = parser.parse_args()
    for filename in ("index.html", "account-app.html", "404.html"):
        if not (args.directory / filename).is_file():
            parser.error("Build the account app and run scripts/build-homepage.sh first.")
    handler = partial(SiteHandler, directory=str(args.directory.resolve()))
    ThreadingHTTPServer(("127.0.0.1", args.port), handler).serve_forever()
