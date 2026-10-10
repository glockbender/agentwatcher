"""Plays GitHub for the update test inside the machine, well or badly on request.

    python3 server.py <folder> <port>

The path says how to behave, so one server covers every case:

    /feed/<name>.xml         the feed <folder>/feeds/<name>.xml; feed/broken.xml answers 500
    /zip/ok/<file>           the archive <folder>/<file>, whole
    /zip/drop/<file>         the full length promised, half of it sent, the connection closed
    /zip/stall/<file>        64 KB sent, then silence until the client gives up
    /zip/error/<file>        500
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import time

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parts = self.path.strip("/").split("/")
        if parts[0] == "feed" and len(parts) == 2:
            return self.feed(parts[1])
        if parts[0] == "zip" and len(parts) == 3:
            return self.archive(parts[1], ROOT / parts[2])
        self.send_error(404)

    def feed(self, name: str):
        path = ROOT / "feeds" / name
        if name == "broken.xml" or not path.is_file():
            return self.send_error(500 if name == "broken.xml" else 404)
        self.reply(path.read_bytes(), "application/xml")

    def archive(self, mode: str, path: Path):
        if mode == "error" or not path.is_file():
            return self.send_error(500 if mode == "error" else 404)
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if mode == "ok":
            self.wfile.write(data)
        elif mode == "drop":
            self.wfile.write(data[: len(data) // 2])
            self.wfile.flush()
            self.close_connection = True
        elif mode == "stall":
            self.wfile.write(data[:65536])
            self.wfile.flush()
            time.sleep(600)

    def reply(self, body: bytes, kind: str):
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        sys.stderr.write(f"{time.strftime('%H:%M:%S')} {format % args}\n")


if __name__ == "__main__":
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 8123
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
