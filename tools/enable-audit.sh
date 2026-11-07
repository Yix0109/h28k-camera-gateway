#!/usr/bin/env bash
# =============================================================
# H28K 监控系统：启用真实 IP + 登录审计日志
#
# 做三件事：
#   1) frp 隧道开 PROXY Protocol v2，让 nginx 拿到访客真实 IP
#      （新增 8181 端口走代理协议，8080 保留给内网直连，不影响原有访问）
#   2) cam-authd 增加登录审计：/var/log/cam-auth.log
#      格式：时间  IP  用户名  结果  客户端
#   3) logrotate 保留 30 天
#
# 用法：sudo bash h28k-enable-audit.sh
# 失败会自动回滚 frp 配置并重启服务。
# =============================================================
set -u
STAMP=$(date +%Y%m%d-%H%M%S)
LOG=/root/enable-audit.log
exec > >(tee -a "$LOG") 2>&1
echo "=== $(date -Is) 开始 ==="

[ "$(id -u)" -eq 0 ] || { echo "请用 root 执行"; exit 1; }
NGINX_CONF=/etc/nginx/conf.d/cam.conf
FRPC_TOML=/etc/frp/frpc.toml
AUTHD=/opt/cam-authd/authd.py

for f in "$NGINX_CONF" "$FRPC_TOML" "$AUTHD"; do
  [ -f "$f" ] || { echo "找不到 $f，这台机器可能没按之前的方案部署过"; exit 1; }
done

echo "--- 0. 备份 ---"
cp -a "$NGINX_CONF" "$NGINX_CONF.bak.$STAMP"
cp -a "$FRPC_TOML" "$FRPC_TOML.bak.$STAMP"
cp -a "$AUTHD" "$AUTHD.bak.$STAMP"
echo "  $NGINX_CONF.bak.$STAMP"
echo "  $FRPC_TOML.bak.$STAMP"
echo "  $AUTHD.bak.$STAMP"

# ---------- 1. 新 authd：带审计日志 ----------
echo "--- 1. 更新 cam-authd（登录审计） ---"
[ -f /etc/cam-authd.env ] || { echo "缺 /etc/cam-authd.env"; exit 1; }
U=$(grep -m1 '^AUTHD_USER=' /etc/cam-authd.env | cut -d= -f2-)
[ -n "$U" ] || { echo "cam-authd.env 里没有 AUTHD_USER"; exit 1; }

cat > "$AUTHD" <<'PYEOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cam-authd —— 中文监控台的严格会话认证服务（含登录审计）
监听 127.0.0.1:9000，由 nginx 的 auth_request 调用。

会话规则：
  · 会话级 Cookie（不带 Max-Age / Expires）
  · 会话只存服务端内存
  · 同 IP 连续 10 次密码错 → 锁 30 秒
  · 登录成功/失败/被锁/登出 全部写入 /var/log/cam-auth.log
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
    """一行一条：时间\tIP\t用户名\t结果\tUA"""
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
<title>登录 · 监控中心</title>
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
  <h1>监控中心</h1>
  <p class="sub">请登录后查看（刷新页面需重新登录）</p>
  <label>用户名</label>
  <input name="username" value="{user}" autofocus required>
  <label>密码</label>
  <input name="password" type="password" required>
  {err}
  <button type="submit">登 录</button>
  <div class="foot">H28K 监控系统</div>
</form>
</body></html>"""

class Handler(BaseHTTPRequestHandler):
    server_version = "cam-authd"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        # 不记录 /auth 子请求（每个静态资源都会触发，噪音太大）
        if self.path.startswith("/auth"):
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
            self.login_page(429, "密码错误次数过多，请 %d 秒后再试" % left)
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
            self.login_page(429, "密码错误次数过多，请 %d 秒后再试" % BAN_SECONDS)
            return
        audit(ip, user, "BAD_PWD", self)
        self.login_page(401, "用户名或密码错误，还可尝试 %d 次" % left)

def main():
    if not PASSWORD:
        sys.exit("AUTHD_PASS 未设置")
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
PYEOF
chmod 0755 "$AUTHD"
python3 -c "import ast;ast.parse(open('$AUTHD',encoding='utf-8').read())" || { echo "authd.py 语法错误，回滚"; cp -a "$AUTHD.bak.$STAMP" "$AUTHD"; exit 1; }
echo "  语法 OK"

# ---------- 2. nginx：8080 内网直连 + 8181 代理协议 ----------
echo "--- 2. nginx 配置（新增 8181 走 PROXY Protocol） ---"
B64=$(grep -m1 'Authorization "Basic' "$NGINX_CONF" | sed 's/.*"Basic \([^"]*\)".*/\1/')
[ -n "$B64" ] || { echo "读不到 nginx 里的 Basic 头"; exit 1; }

mkdir -p /etc/nginx/snippets
cat > /etc/nginx/snippets/cam-common.conf <<'NGEOF'
    charset utf-8;
    root /opt/cam/www;
    index index.html;

    location = /login {
        proxy_pass http://127.0.0.1:9000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
    location = /logout {
        proxy_pass http://127.0.0.1:9000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
    location = /auth {
        internal;
        proxy_pass http://127.0.0.1:9000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
    }

    location = / {
        auth_request /auth;
        error_page 401 = @need_login;
        try_files /index.html =404;
    }
    location / {
        auth_request /auth;
        error_page 401 = @need_login;
        try_files $uri @g2r;
    }
    location @need_login {
        return 302 $scheme://$http_host/login;
    }
    location @g2r {
        proxy_pass http://127.0.0.1:1984;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header Authorization "Basic __B64__";
        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
NGEOF
sed -i "s|__B64__|$B64|" /etc/nginx/snippets/cam-common.conf

cat > "$NGINX_CONF" <<'NGEOF'
# 8080：内网直连（不带 PROXY 头），方便本地排查
server {
    listen 8080 default_server;
    include /etc/nginx/snippets/cam-common.conf;
}

# 8181：给 frp 用，带 PROXY Protocol v2，可拿到访客真实 IP
server {
    listen 8181 proxy_protocol default_server;
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
    real_ip_recursive on;

    include /etc/nginx/snippets/cam-common.conf;

    # 访问日志里就是真实 IP
    access_log /var/log/nginx/cam-access.log;
}
NGEOF
nginx -t || { echo "nginx 配置错误，回滚"; cp -a "$NGINX_CONF.bak.$STAMP" "$NGINX_CONF"; exit 1; }
echo "  nginx 配置 OK"

# ---------- 3. frp：camweb 隧道改到 8181 并开 PROXY v2 ----------
echo "--- 3. frp 隧道（camweb → 8181 + proxyProtocolVersion v2） ---"
python3 - "$FRPC_TOML" <<'PYEOF'
import sys, re
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
blocks = re.split(r'(?m)^(?=\[\[proxies\]\])', src)
out = []
hit = False
for b in blocks:
    if 'name = "camweb"' in b:
        hit = True
        b = re.sub(r'localPort = \d+', 'localPort = 8181', b)
        if 'proxyProtocolVersion' not in b:
            b = b.rstrip("\n") + '\ntransport.proxyProtocolVersion = "v2"\n\n'
    out.append(b)
open(p, "w", encoding="utf-8").write("".join(out))
print("  camweb 已改为 8181 + proxy v2" if hit else "  警告：没找到 camweb 隧道")
PYEOF
grep -A6 'name = "camweb"' "$FRPC_TOML"

echo "--- 4. 重启服务 ---"
systemctl restart cam-auth
nginx -t && systemctl reload nginx
systemctl restart frpc
sleep 5
printf '  cam-auth: '; systemctl is-active cam-auth
printf '  nginx   : '; systemctl is-active nginx
printf '  frpc    : '; systemctl is-active frpc

# ---------- 5. 自检（失败自动回滚 frp） ----------
echo "--- 5. 自检 ---"
printf '  内网 8080 登录页 : '
curl -s -o /dev/null -w '%{http_code}\n' --max-time 8 http://127.0.0.1:8080/login
printf '  公网 11985 登录页: '
EXT=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://$VPS_ADDR:$PORT_CAMWEB/login)
echo "$EXT"

if [ "$EXT" != "200" ]; then
  echo "!! 公网访问异常（返回 $EXT），回滚 frp 配置"
  cp -a "$FRPC_TOML.bak.$STAMP" "$FRPC_TOML"
  systemctl restart frpc
  sleep 4
  printf '  回滚后公网: '
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 15 http://$VPS_ADDR:$PORT_CAMWEB/login
  echo "  已回滚，nginx/authd 的改动保留（不影响现有访问）"
else
  echo "  ✔ 公网链路正常"
fi

echo "--- 6. 审计日志 ---"
cat > /etc/logrotate.d/cam-auth <<'LGEOF'
/var/log/cam-auth.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
LGEOF
touch /var/log/cam-auth.log
chmod 600 /var/log/cam-auth.log
echo "  已配置 logrotate（保留 30 天）"
echo "  当前内容（可能为空，等你登录一次就会有）："
tail -5 /var/log/cam-auth.log 2>/dev/null || echo "  (空)"

cat <<EOF

============================================================
 完成
   登录审计： tail -f /var/log/cam-auth.log
   访问日志： tail -f /var/log/nginx/cam-access.log   （8181 端口，含真实 IP）
   字段：     时间   IP   用户名   结果   UA
   结果值：   OK / BAD_PWD / BAD_PWD->LOCKED / LOCKED / LOGOUT

 如果公网访问变成 400/502，说明 frps 不支持 PROXY Protocol，
 脚本已自动回滚；手动回滚：
   cp -a $FRPC_TOML.bak.$STAMP $FRPC_TOML && systemctl restart frpc
============================================================
EOF
echo "=== done $(date -Is) ==="
