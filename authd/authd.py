#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cam-authd 鈥斺€?涓枃鐩戞帶鍙扮殑涓ユ牸浼氳瘽璁よ瘉鏈嶅姟锛堝惈鐧诲綍瀹¤锛?鐩戝惉 127.0.0.1:9000锛岀敱 nginx 鐨?auth_request 璋冪敤銆?
浼氳瘽瑙勫垯锛?  路 浼氳瘽绾?Cookie锛堜笉甯?Max-Age / Expires锛?  路 浼氳瘽鍙瓨鏈嶅姟绔唴瀛?  路 鍚?IP 杩炵画 10 娆″瘑鐮侀敊 鈫?閿?30 绉?  路 鐧诲綍鎴愬姛/澶辫触/琚攣/鐧诲嚭 鍏ㄩ儴鍐欏叆 /var/log/cam-auth.log
"""
import os
import sys
import time
import hmac
import html
import fcntl
import secrets
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN_HOST = os.environ.get("AUTHD_HOST", "127.0.0.1")
LISTEN_PORT = int(os.environ.get("AUTHD_PORT", "9000"))
USERNAME    = os.environ.get("AUTHD_USER", "admin")
PASSWORD    = os.environ.get("AUTHD_PASS", "")
SESSION_TTL = int(os.environ.get("AUTHD_TTL", "28800"))
MAX_FAIL    = int(os.environ.get("AUTHD_MAX_FAIL", "10"))
FAIL_WINDOW = int(os.environ.get("AUTHD_FAIL_WINDOW", "600"))
BAN_SECONDS = int(os.environ.get("AUTHD_BAN", "30"))
AUDIT_LOG   = os.environ.get("AUTHD_LOG", "/var/log/cam-auth.log")

sessions = {}
fails = {}
bans = {}

def now():
    return time.time()

def client_ip(handler):
    xr = handler.headers.get("X-Real-IP") or ""
    if xr:
        return xr.split(",")[0].strip()
    xff = handler.headers.get("X-Forwarded-For") or ""
    if xff:
        return xff.split(",")[0].strip()
    return handler.client_address[0]

def audit(ip, user, result, handler=None):
    """涓€琛屼竴鏉★細鏃堕棿\tIP\t鐢ㄦ埛鍚峔t缁撴灉\tUA"""
    ua = ""
    if handler is not None:
        ua = (handler.headers.get("User-Agent") or "")[:120].replace("\t", " ")
    user = (user or "-").replace("\t", " ")[:40]
    line = "%s\t%s\t%s\t%s\t%s\n" % (
        time.strftime("%Y-%m-%d %H:%M:%S"), ip, user, result, ua)
    try:
        with open(AUDIT_LOG, "a", encoding="utf-8") as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            f.write(line)
            fcntl.flock(f, fcntl.LOCK_UN)
    except Exception as e:
        sys.stderr.write("audit write failed: %s\n" % e)

def prune():
    t = now()
    for k in [k for k, v in sessions.items() if v <= t]:
        sessions.pop(k, None)
    for k in [k for k, v in bans.items() if v <= t]:
        bans.pop(k, None)

def get_sid(handler):
    for part in (handler.headers.get("Cookie") or "").split(";"):
        part = part.strip()
        if part.startswith("sid="):
            return part[4:]
    return ""

def session_ok(handler):
    sid = get_sid(handler)
    if not sid:
        return False
    exp = sessions.get(sid)
    if exp and exp > now():
        return True
    sessions.pop(sid, None)
    return False

LOGIN_HTML = """<!DOCTYPE html>
<html lang="zh-CN"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>鐧诲綍 路 鐩戞帶涓績</title>
<style>
  *{{box-sizing:border-box}}
  body{{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
       background:#0f1115;color:#e6e6e6;font:14px/1.6 "Microsoft YaHei","PingFang SC",sans-serif}}
  .card{{width:330px;background:#171a21;border:1px solid #242a33;border-radius:10px;padding:26px 24px}}
  h1{{margin:0 0 4px;font-size:17px;color:#38d9c0}}
  p.sub{{margin:0 0 18px;font-size:12px;color:#6f7b8c}}
  label{{display:block;font-size:12px;color:#8b97a8;margin:12px 0 5px}}
  input{{width:100%;padding:9px 10px;border-radius:6px;border:1px solid #2e3644;
        background:#0f1319;color:#e6e6e6;font-size:14px;outline:none}}
  input:focus{{border-color:#1f9e8c}}
  button{{width:100%;margin-top:18px;padding:10px;border:0;border-radius:6px;
         background:#16796b;color:#fff;font-size:14px;cursor:pointer}}
  button:hover{{background:#1a8b7b}}
  .err{{margin-top:14px;padding:8px 10px;border-radius:6px;background:#3a1d1d;
       border:1px solid #6b2b2b;color:#f0a5a5;font-size:12px}}
  .foot{{margin-top:16px;font-size:11px;color:#4d5968;text-align:center}}
</style></head>
<body>
<form class="card" method="post" action="/login" autocomplete="off">
  <h1>鐩戞帶涓績</h1>
  <p class="sub">璇风櫥褰曞悗鏌ョ湅锛堝埛鏂伴〉闈㈤渶閲嶆柊鐧诲綍锛?/p>
  <label>鐢ㄦ埛鍚?/label>
  <input name="username" value="{user}" autofocus required>
  <label>瀵嗙爜</label>
  <input name="password" type="password" required>
  {err}
  <button type="submit">鐧?褰?/button>
  <div class="foot">H28K 鐩戞帶绯荤粺</div>
</form>
</body></html>"""

class Handler(BaseHTTPRequestHandler):
    server_version = "cam-authd"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        # 涓嶈褰?/auth 瀛愯姹傦紙姣忎釜闈欐€佽祫婧愰兘浼氳Е鍙戯紝鍣煶澶ぇ锛?        if self.path.startswith("/auth"):
            return
        sys.stderr.write("%s - %s\n" % (client_ip(self), fmt % args))

    def send_html(self, code, body, extra_headers=None):
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra_headers or []):
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, location, extra_headers=None):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", "0")
        for k, v in (extra_headers or []):
            self.send_header(k, v)
        self.end_headers()

    def login_page(self, code=200, err="", user=USERNAME):
        body = LOGIN_HTML.format(
            user=html.escape(user),
            err=('<div class="err">%s</div>' % html.escape(err)) if err else "")
        self.send_html(code, body)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        prune()
        if path == "/login":
            self.login_page()
        elif path == "/logout":
            sid = get_sid(self)
            if sid and sessions.pop(sid, None):
                audit(client_ip(self), "-", "LOGOUT", self)
            self.redirect("/login", [("Set-Cookie", "sid=; Path=/; HttpOnly; SameSite=Lax")])
        elif path == "/auth":
            if session_ok(self):
                self.send_response(204)
                self.send_header("Content-Length", "0")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
            else:
                self.send_response(401)
                self.send_header("Content-Length", "0")
                self.end_headers()
        elif path == "/health":
            self.send_html(200, "ok")
        else:
            self.send_html(404, "not found")

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        prune()
        if path != "/login":
            self.send_html(404, "not found")
            return

        ip = client_ip(self)
        until = bans.get(ip, 0)
        if until > now():
            left = int(until - now()) + 1
            audit(ip, "-", "LOCKED", self)
            self.login_page(429, "瀵嗙爜閿欒娆℃暟杩囧锛岃 %d 绉掑悗鍐嶈瘯" % left)
            return

        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(min(length, 8192)).decode("utf-8", "replace")
        form = urllib.parse.parse_qs(raw)
        user = (form.get("username") or [""])[0]
        pwd  = (form.get("password") or [""])[0]

        if hmac.compare_digest(user, USERNAME) and hmac.compare_digest(pwd, PASSWORD):
            fails.pop(ip, None)
            sid = secrets.token_urlsafe(32)
            sessions[sid] = now() + SESSION_TTL
            audit(ip, user, "OK", self)
            self.redirect("/", [("Set-Cookie",
                "sid=%s; Path=/; HttpOnly; SameSite=Lax" % sid)])
            return

        arr = [t for t in fails.get(ip, []) if t > now() - FAIL_WINDOW]
        arr.append(now())
        fails[ip] = arr
        left = MAX_FAIL - len(arr)
        if left <= 0:
            bans[ip] = now() + BAN_SECONDS
            fails.pop(ip, None)
            audit(ip, user, "BAD_PWD->LOCKED", self)
            self.login_page(429, "瀵嗙爜閿欒娆℃暟杩囧锛岃 %d 绉掑悗鍐嶈瘯" % BAN_SECONDS)
            return
        audit(ip, user, "BAD_PWD", self)
        self.login_page(401, "鐢ㄦ埛鍚嶆垨瀵嗙爜閿欒锛岃繕鍙皾璇?%d 娆? % left)

def main():
    if not PASSWORD:
        sys.exit("AUTHD_PASS 鏈缃?)
    open(AUDIT_LOG, "a").close()
    try:
        os.chmod(AUDIT_LOG, 0o600)
    except Exception:
        pass
    srv = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    srv.daemon_threads = True
    sys.stderr.write("cam-authd on %s:%d user=%s log=%s\n"
                     % (LISTEN_HOST, LISTEN_PORT, USERNAME, AUDIT_LOG))
    srv.serve_forever()

if __name__ == "__main__":
    main()