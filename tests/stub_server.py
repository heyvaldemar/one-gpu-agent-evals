#!/usr/bin/env python3
"""stub_server.py PORT - an OpenAI-compatible server that answers at once.

For tests/recompute.sh only: the load generator and the recomputation are
tested against it in seconds, without a model. Every answer takes a short,
varying time and reports token counts, and every seventh is an HTTP 500, so
the records hold failed calls as well as answered ones.
"""
import json
import random
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

count = [0]
lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        with lock:
            count[0] += 1
            n = count[0]
        time.sleep(random.Random(body.get("seed", 0)).uniform(0.005, 0.03))
        if n % 7 == 0:
            self.send_response(500)
            self.end_headers()
            return
        out = json.dumps({"choices": [{"message": {"role": "assistant", "content": "ok"}}],
                          "usage": {"prompt_tokens": 500 + n % 11, "completion_tokens": 18 + n % 5}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
