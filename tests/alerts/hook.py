# tests/alerts/hook.py - tiny local webhook receiver for the alert tests.
# Usage: python3 hook.py PORT OUTPREFIX ; each POST body is saved to OUTPREFIX.<path>
import http.server, sys, os
n=[0]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        b=self.rfile.read(int(self.headers['Content-Length'])); n[0]+=1
        open(sys.argv[2]+'.'+self.path.strip('/').replace('/','_'),'wb').write(b)
        self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
    def log_message(self,*a): pass
http.server.HTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()
