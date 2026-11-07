# =============================================================
# H28K 摄像头网关 一键部署
#   go2rtc（拉流聚合） + nginx（中文台+反代） + cam-authd（会话认证）
#   + frpc（穿透） + fail2ban（SSH 防护）
#
# 用法：
#   1) cp config.env.example config.env && vi config.env
#   2) sudo bash install.sh
#
# 幂等：改完 config.env 直接重跑即可。
# =============================================================
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -f "$HERE/config.env" ] || { echo "缺少 config.env（可从 config.env.example 复制）"; exit 1; }
# shellcheck disable=SC1091
. "$HERE/config.env"

die(){ echo -e "\n\033[1;31m[失败]\033[0m $*" >&2; exit 1; }
say(){ echo -e "\n\033[1;36m== $*\033[0m"; }
ok(){ echo "  ✔ $*"; }

[ "$(id -u)" -eq 0 ] || die "请用 root 执行：sudo bash install.sh"

# ---------- 默认值 ----------
: "${VPS_ADDR:?config.env 里必须写 VPS_ADDR}"
: "${VPS_TOKEN:?config.env 里必须写 VPS_TOKEN}"
VPS_CTRL_PORT="${VPS_CTRL_PORT:-7000}"
WEB_USER="${WEB_USER:-admin}"
: "${WEB_PASS:?config.env 里必须写 WEB_PASS（至少 8 位）}"
NVR_USER="${NVR_USER:-admin}"
: "${NVR_PASS:?config.env 里必须写 NVR_PASS}"
PORT_GO2RTC="${PORT_GO2RTC:-11984}"
PORT_CAMWEB="${PORT_CAMWEB:-11985}"
PORT_SSH="${PORT_SSH:-12222}"
PORT_WEB_BASE="${PORT_WEB_BASE:-18443}"
PORT_SDK_BASE="${PORT_SDK_BASE:-18000}"
PORT_RTSP_BASE="${PORT_RTSP_BASE:-18554}"
KEEP_NVR_TUNNELS="${KEEP_NVR_TUNNELS:-1}"
PROXY_PROTOCOL="${PROXY_PROTOCOL:-1}"   # 1=用 PROXY Protocol 拿真实 IP（需 frps>=0.53）

[ "${#WEB_PASS}" -ge 8 ] || die "WEB_PASS 至少 8 位"

ARCH=$(uname -m)
case "$ARCH" in
  aarch64|arm64) BIN_ARCH=arm64 ;;
  x86_64|amd64)  BIN_ARCH=amd64 ;;
  *) die "不支持的架构 $ARCH（本包只带 arm64/amd64）" ;;
esac

say "0. 环境"
. /etc/os-release 2>/dev/null || true
echo "  ${PRETTY_NAME:-unknown} / $(uname -r) / $ARCH"
free -h | sed -n '1,2p'

# ---------- 1. apt 源 + 依赖 ----------
say "1. 依赖（nginx / python3 / fail2ban）"
shopt -s nullglob
for f in /etc/apt/sources.list.d/*.sources; do
  case "$f" in
    *armbian*) [ -f "$f.disabled" ] || mv "$f" "$f.disabled" 2>/dev/null || true ;;
    *)
      sed -i 's|https\?://deb.debian.org|http://mirrors.tuna.tsinghua.edu.cn|g' "$f" 2>/dev/null || true
      sed -i 's|https\?://security.debian.org|http://mirrors.tuna.tsinghua.edu.cn|g' "$f" 2>/dev/null || true
      ;;
  esac
done
shopt -u nullglob

apt-get update -qq || true
command -v nginx >/dev/null 2>&1 || {
  apt-get install -y --fix-missing nginx-light 2>/dev/null || apt-get install -y nginx || die "nginx 安装失败"
}
command -v python3 >/dev/null 2>&1 || apt-get install -y python3 || die "python3 安装失败"
command -v fail2ban-client >/dev/null 2>&1 || apt-get install -y fail2ban >/dev/null 2>&1 || true
ok "$(nginx -v 2>&1 | head -1) / $(python3 -V 2>&1)"

# ---------- 2. 二进制 ----------
say "2. go2rtc / frpc"
mkdir -p /opt/go2rtc /opt/frp /opt/cam/www /etc/frp /opt/cam-authd

if [ -f "$HERE/bin/go2rtc_linux_$BIN_ARCH" ]; then
  install -m 0755 "$HERE/bin/go2rtc_linux_$BIN_ARCH" /usr/local/bin/go2rtc
  ok "go2rtc ← bin/"
else
  echo "  本地没有，尝试下载"
  curl -fsSL --connect-timeout 20 -o /usr/local/bin/go2rtc \
    "https://ghfast.top/https://github.com/AlexxIT/go2rtc/releases/download/v1.9.15/go2rtc_linux_$BIN_ARCH" \
    || die "go2rtc 下载失败，请放到 bin/go2rtc_linux_$BIN_ARCH"
  chmod 0755 /usr/local/bin/go2rtc
fi

if [ -f "$HERE/bin/frpc_linux_$BIN_ARCH" ]; then
  install -m 0755 "$HERE/bin/frpc_linux_$BIN_ARCH" /opt/frp/frpc
  ok "frpc ← bin/"
elif [ ! -x /opt/frp/frpc ]; then
  echo "  本地没有，尝试下载"
  tmp=$(mktemp -d)
  for base in "https://ghfast.top/" "https://gh-proxy.com/" ""; do
    if curl -fsSL --connect-timeout 20 -o "$tmp/frp.tgz" \
        "${base}https://github.com/fatedier/frp/releases/download/v0.66.0/frp_0.66.0_linux_${BIN_ARCH}.tar.gz"; then
      tar -xzf "$tmp/frp.tgz" -C "$tmp" && break
    fi
  done
  find "$tmp" -name frpc -type f -exec install -m 0755 {} /opt/frp/frpc \;
  rm -rf "$tmp"
  [ -x /opt/frp/frpc ] || die "frpc 获取失败，请放到 bin/frpc_linux_$BIN_ARCH"
fi

# ---------- 3. go2rtc 配置 + 页面数据 ----------
say "3. 生成 go2rtc 配置与摄像头清单"
YAML=/opt/go2rtc/go2rtc.yaml
JSON=/opt/cam/www/cameras.json

{
  echo "api:"
  echo "  listen: \":1984\""
  echo "  username: \"$WEB_USER\""
  echo "  password: \"$WEB_PASS\""
  echo "  local_auth: true"
  echo ""
  echo "rtsp:"
  echo "  listen: \":8554\""
  echo ""
  echo "webrtc:"
  echo "  listen: \":8555\""
  echo ""
  echo "# 通道规则：<通道>02 = 子码流(网页用)，<通道>01 = 主码流"
  echo "streams:"
} > "$YAML"

echo "[" > "$JSON"
first_nvr=1
for i in 1 2 3 4 5 6 7 8; do
  var="NVR$i"
  [ -n "${!var:-}" ] || continue
  IFS='|' read -r ip label chans names <<< "${!var}"
  [ -n "$ip" ] || continue
  prefix="n$(echo "$ip" | awk -F. '{print $4}')"
  label="${label:-$ip}"

  echo "" >> "$YAML"
  echo "  # ===== $label ($ip) =====" >> "$YAML"

  [ $first_nvr -eq 1 ] || echo "," >> "$JSON"
  first_nvr=0
  printf '  {"id": "%s", "name": "%s", "channels": [' "$ip" "$label" >> "$JSON"

  IFS=',' read -ra CHARR <<< "$chans"
  IFS=',' read -ra NAMEARR <<< "${names:-}"
  first_ch=1
  for idx in "${!CHARR[@]}"; do
    ch=$(echo "${CHARR[$idx]}" | tr -d ' ')
    [ -n "$ch" ] || continue
    path=$(printf '%d02' "$ch")
    cname="${NAMEARR[$idx]:-通道 $ch}"
    key="${prefix}_c${ch}"
    printf '  %-10s rtsp://%s:%s@%s:554/Streaming/Channels/%s   # %s\n' \
      "$key:" "$NVR_USER" "$NVR_PASS" "$ip" "$path" "$cname" >> "$YAML"
    [ $first_ch -eq 1 ] || printf ',' >> "$JSON"
    first_ch=0
    printf '{"key": "%s", "name": "%s"}' "$key" "$(printf '%s' "$cname" | sed 's/"/\\"/g')" >> "$JSON"
  done
  printf ']}' >> "$JSON"
done
echo "" >> "$JSON"
echo "]" >> "$JSON"
chmod 600 "$YAML"
ok "流数量：$(grep -c 'rtsp://' "$YAML")"
python3 -c "import json;json.load(open('$JSON'))" && ok "cameras.json 校验通过" || echo "  (json 校验跳过)"

# ---------- 4. 中文页面 ----------
say "4. 中文监控台页面"
install -m 0644 "$HERE/web/index.html" /opt/cam/www/index.html
ok "/opt/cam/www/index.html"

# ---------- 5. 会话认证服务 ----------
say "5. cam-authd（会话认证 + 登录审计）"
[ -f "$HERE/authd/authd.py" ] || die "缺少 authd/authd.py"
install -m 0755 "$HERE/authd/authd.py" /opt/cam-authd/authd.py
python3 -c "import ast;ast.parse(open('/opt/cam-authd/authd.py',encoding='utf-8').read())" || die "authd.py 语法错误"

umask 077
cat > /etc/cam-authd.env <<EOF
AUTHD_USER=$WEB_USER
AUTHD_PASS=$WEB_PASS
AUTHD_MAX_FAIL=10
AUTHD_FAIL_WINDOW=600
AUTHD_BAN=30
EOF
chmod 600 /etc/cam-authd.env
umask 022

cat > /etc/systemd/system/cam-auth.service <<'EOF'
[Unit]
Description=cam-authd strict session authentication
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/cam-authd.env
ExecStart=/usr/bin/python3 /opt/cam-authd/authd.py
Restart=always
RestartSec=3
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now cam-auth >/dev/null 2>&1 || true
systemctl restart cam-auth
sleep 2
ok "cam-auth: $(systemctl is-active cam-auth)"

# ---------- 6. nginx ----------
say "6. nginx（8080 内网 + 8181 真实 IP）"
B64=$(printf '%s:%s' "$WEB_USER" "$WEB_PASS" | base64 | tr -d '\n')
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

cat > /etc/nginx/conf.d/cam.conf <<'NGEOF'
# 8080：内网直连（不带 PROXY 头），方便本地排查
server {
    listen 8080 default_server;
    include /etc/nginx/snippets/cam-common.conf;
}

# 8181：给 frp 用，带 PROXY Protocol v2 → 能拿到访客真实 IP
server {
    listen 8181 proxy_protocol default_server;
    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;
    real_ip_recursive on;

    include /etc/nginx/snippets/cam-common.conf;

    access_log /var/log/nginx/cam-access.log;
}
NGEOF

rm -f /etc/nginx/sites-enabled/default
nginx -t || die "nginx 配置校验失败"
systemctl enable --now nginx >/dev/null 2>&1 || true
systemctl reload nginx 2>/dev/null || systemctl restart nginx
ok "nginx: $(systemctl is-active nginx)"

# ---------- 7. frpc ----------
say "7. frp 隧道"
CAM_LOCAL=8080
CAM_TRANSPORT=""
if [ "$PROXY_PROTOCOL" = "1" ]; then
  CAM_LOCAL=8181
  CAM_TRANSPORT='transport.proxyProtocolVersion = "v2"'
fi

{
  echo "serverAddr = \"$VPS_ADDR\""
  echo "serverPort = $VPS_CTRL_PORT"
  echo "loginFailExit = false"
  echo ""
  echo "auth.method = \"token\""
  echo "auth.token = \"$VPS_TOKEN\""
  echo ""
  echo "[[proxies]]"
  echo 'name = "go2rtc"'
  echo 'type = "tcp"'
  echo 'localIP = "127.0.0.1"'
  echo "localPort = 1984"
  echo "remotePort = $PORT_GO2RTC"
  echo ""
  echo "[[proxies]]"
  echo 'name = "camweb"'
  echo 'type = "tcp"'
  echo 'localIP = "127.0.0.1"'
  echo "localPort = $CAM_LOCAL"
  echo "remotePort = $PORT_CAMWEB"
  [ -n "$CAM_TRANSPORT" ] && echo "$CAM_TRANSPORT"
  echo ""
  echo "[[proxies]]"
  echo 'name = "ssh"'
  echo 'type = "tcp"'
  echo 'localIP = "127.0.0.1"'
  echo "localPort = 22"
  echo "remotePort = $PORT_SSH"

  if [ "$KEEP_NVR_TUNNELS" = "1" ]; then
    idx=0
    for i in 1 2 3 4 5 6 7 8; do
      var="NVR$i"; [ -n "${!var:-}" ] || continue
      ip=$(echo "${!var}" | cut -d'|' -f1)
      idx=$((idx+1))
      wp=$((PORT_WEB_BASE + idx - 1)); sp=$((PORT_SDK_BASE + idx - 1)); rp=$((PORT_RTSP_BASE + idx - 1))
      printf '\n[[proxies]]\nname = "nvr%dweb"\ntype = "tcp"\nlocalIP = "%s"\nlocalPort = 80\nremotePort = %d\n' "$idx" "$ip" "$wp"
      printf '\n[[proxies]]\nname = "nvr%dsdk"\ntype = "tcp"\nlocalIP = "%s"\nlocalPort = 8000\nremotePort = %d\n' "$idx" "$ip" "$sp"
      printf '\n[[proxies]]\nname = "nvr%drtsp"\ntype = "tcp"\nlocalIP = "%s"\nlocalPort = 554\nremotePort = %d\n' "$idx" "$ip" "$rp"
    done
  fi
} > /etc/frp/frpc.toml
chmod 600 /etc/frp/frpc.toml
ok "隧道数：$(grep -c 'name = ' /etc/frp/frpc.toml)"

# ---------- 8. systemd ----------
say "8. 服务"
cat > /etc/systemd/system/go2rtc.service <<'EOF'
[Unit]
Description=go2rtc streaming server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/go2rtc -config /opt/go2rtc/go2rtc.yaml
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/frpc.service <<'EOF'
[Unit]
Description=frp client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/opt/frp/frpc -c /etc/frp/frpc.toml
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

install -m 0755 "$HERE/tools/set-password.sh" /root/set-password.sh 2>/dev/null || true
systemctl daemon-reload
systemctl enable go2rtc frpc >/dev/null 2>&1 || true
systemctl restart go2rtc
systemctl restart frpc
sleep 3

# ---------- 9. fail2ban（SSH） ----------
say "9. fail2ban"
if command -v fail2ban-client >/dev/null 2>&1; then
  cat > /etc/fail2ban/jail.d/cam.local <<'EOF'
[DEFAULT]
bantime  = 30
findtime = 600
maxretry = 10

# 网页登录的 10 次锁定由 cam-authd 内存计数，这里只管 SSH
[sshd]
enabled  = true
maxretry = 5
bantime  = 60
findtime = 600
EOF
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
  sleep 2
  ok "fail2ban: $(systemctl is-active fail2ban)"
else
  echo "  (未安装，跳过)"
fi

# ---------- 10. 日志轮转 ----------
cat > /etc/logrotate.d/cam-auth <<'EOF'
/var/log/cam-auth.log /var/log/nginx/cam-access.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
touch /var/log/cam-auth.log
chmod 600 /var/log/cam-auth.log
ok "logrotate 已配置（30 天）"

# ---------- 11. 自检 ----------
say "10. 自检"
printf '  go2rtc      : '; systemctl is-active go2rtc
printf '  nginx       : '; systemctl is-active nginx
printf '  cam-auth    : '; systemctl is-active cam-auth
printf '  frpc        : '; systemctl is-active frpc
printf '  内网 8080   : '; curl -s -o /dev/null -w '%{http_code}\n' --max-time 6 http://127.0.0.1:8080/login || true
printf '  公网 %s : ' "$PORT_CAMWEB"
EXT=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://$VPS_ADDR:$PORT_CAMWEB/login" || echo 000)
echo "$EXT"

if [ "$EXT" != "200" ] && [ "$PROXY_PROTOCOL" = "1" ]; then
  echo "  ! 公网不通，可能是 frps 不支持 PROXY Protocol，回退到 8080"
  sed -i "s/localPort = 8181/localPort = 8080/; /proxyProtocolVersion/d" /etc/frp/frpc.toml
  systemctl restart frpc
  sleep 4
  printf '  回退后公网 : '
  curl -s -o /dev/null -w '%{http_code}\n' --max-time 15 "http://$VPS_ADDR:$PORT_CAMWEB/login" || true
fi

cat <<EOF

============================================================
 部署完成
   中文监控台 : http://$VPS_ADDR:$PORT_CAMWEB/login
                ($WEB_USER / $WEB_PASS)
   go2rtc 原版: http://$VPS_ADDR:$PORT_GO2RTC
   内网调试   : http://<本机IP>:8080
   外网 SSH   : ssh root@$VPS_ADDR -p $PORT_SSH

 安全组需放行：TCP $PORT_CAMWEB、TCP $PORT_GO2RTC、TCP $PORT_SSH
 改密码： bash /root/set-password.sh '新密码'
 看日志： tail -f /var/log/cam-auth.log
============================================================
EOF
