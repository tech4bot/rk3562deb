#!/usr/bin/env python3
"""Tiny server for the C20e video playback bench: serves the clip + page and
records the <video> element's own frame statistics, which is the only honest
measure of "is it stuttering" -- dropped frames come straight from Chrome."""
import http.server, socketserver, os, sys, urllib.parse, datetime

ROOT = os.path.dirname(os.path.abspath(__file__))
LOG = open(os.path.join(ROOT, "bench.log"), "a", buffering=1)

class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw): super().__init__(*a, directory=ROOT, **kw)
    def do_GET(self):
        if self.path.startswith("/log?"):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            f = lambda k, d="": q.get(k, [d])[0]
            LOG.write("%s t=%-7s total=%-6s dropped=%-5s corrupted=%-4s fps=%-6s mem=%s\n" % (
                datetime.datetime.now().strftime("%H:%M:%S"), f("t"), f("total"),
                f("dropped"), f("corrupted"), f("fps"), f("mem")))
            self.send_response(204); self.end_headers(); return
        return super().do_GET()
    def log_message(self, *a): pass

socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", int(sys.argv[1] if len(sys.argv) > 1 else 8099)), H) as s:
    s.serve_forever()
