#!/usr/bin/env bash
# =============================================================
# 【第一步 · 在云服务器上跑】一键安装 frps（内网穿透服务端）
#
# 用法（root 执行）：
#   bash server-setup.sh                          # 自动生成 token
#   bash server-setup.sh --token 你的token        # 用指定 token
#   bash server-setup.sh --token xx --port 7000 --panel-pass xx
#
# 装完会打印：token、需要放行的端口、以及下一步该做什么。
# =============================================================
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

TOKEN=""
PORT=7000
PANEL_PORT=7500
PANEL_PASS=""
FRP_VER=0.66.0

while [ $# -gt 0 ]; do
  case "$1" in
    --token)      TOKEN="$2"; shift 2 ;;
    --port)       PORT="$2"; shift 2 ;;
    --panel-pass) PANEL_PASS="$2"; shift 2 ;;
    --panel-port) PANEL_PORT="$2"; shift 2 ;;
    -h|--help)    sed -n '1,16p' "$0"; exit 0 ;;
    *) echo "未知参数：$1"; exit 1 ;;
  esac
done

say(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
die(){ printf '\033[1;31m[失败]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 执行（sudo bash server-setup.sh）"

ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) FRP_ARCH=amd64 ;;
  aarch64|arm64) FRP_ARCH=arm64 ;;
  *) die "不支持的架构：$ARCH" ;;
esac

[ -n "$TOKEN" ] || TOKEN=$(head -c 24 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-28)
[ -n "$PANEL_PASS" ] || PANEL_PASS=$(head -c 18 /dev/urandom | base64 | tr -d '/+=\n' | cut -c1-16)

say "1. 安装 frps $FRP_VER（$FRP_ARCH）"
if [ -f "$HERE/bin/frps_linux_$FRP_ARCH" ]; then
  install -m 0755 "$HERE/bin/frps_linux_$FRP_ARCH" /usr/local/bin/frps
  echo "  用本地 bin/ 里的 frps"
elif [ -x /usr/local/bin/frps ]; then
  echo "  已存在 $(/usr/local/bin/frps -v 2>&1 | head -1)，跳过下载"
else
  tmp=$(mktemp -d)
  ok=0
  for base in "https://ghfast.top/" "https://gh-proxy.com/" ""; do
    url="${base}https://github.com/fatedier/frp/releases/download/v${FRP_VER}/frp_${FRP_VER}_linux_${FRP_ARCH}.tar.gz"
    echo "  下载：$url"
    if curl -fsSL --connect-timeout 20 -o "$tmp/frp.tgz" "$url"; then
      tar -xzf "$tmp/frp.tgz" -C "$tmp" 2>/dev/null && ok=1 && break
    fi
  done
  [ "$ok" = 1 ] || die "下载失败，请把 frps 二进制放到 bin/frps_linux_$FRP_ARCH 后重试"
  find "$tmp" -name frps -type f -exec install -m 0755 {} /usr/local/bin/frps \;
  rm -rf "$tmp"
fi
/usr/local/bin/frps -v 2>&1 | head -1

say "2. 写配置 /etc/frp/frps.toml"
mkdir -p /etc/frp
cat > /etc/frp/frps.toml <<EOF
# frp 服务端配置（由 server-setup.sh 生成）
bindPort = $PORT

auth.method = "token"
auth.token = "$TOKEN"

# 管理面板：http://服务器IP:$PANEL_PORT/static/
webServer.addr = "0.0.0.0"
webServer.port = $PANEL_PORT
webServer.user = "admin"
webServer.password = "$PANEL_PASS"

log.to = "console"
log.level = "info"
EOF
chmod 600 /etc/frp/frps.toml
echo "  已写入"

say "3. 注册 systemd 服务"
cat > /etc/systemd/system/frps.service <<'EOF'
[Unit]
Description=frp server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c /etc/frp/frps.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable frps >/dev/null 2>&1
systemctl restart frps
sleep 2
printf '  服务状态：'; systemctl is-active frps

say "4. 自检"
if ss -lntp 2>/dev/null | grep -q ":$PORT "; then echo "  ✔ 已监听 $PORT"; else echo "  ✘ 未监听 $PORT，请查看 journalctl -u frps -n 30"; fi
if ss -lntp 2>/dev/null | grep -q ":$PANEL_PORT "; then echo "  ✔ 已监听 $PANEL_PORT"; else echo "  ! 面板未监听（不影响隧道）"; fi

# 本机防火墙提示（云厂商安全组不在这里，需到控制台加）
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  echo "  检测到 ufw 已启用，已自动放行 $PORT / $PANEL_PORT"
  ufw allow "$PORT"/tcp >/dev/null 2>&1 || true
  ufw allow "$PANEL_PORT"/tcp >/dev/null 2>&1 || true
elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  echo "  检测到 firewalld，已自动放行 $PORT / $PANEL_PORT"
  firewall-cmd --permanent --add-port="$PORT"/tcp >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port="$PANEL_PORT"/tcp >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
fi

PUBIP=$(curl -s -m 5 https://api.ipify.org 2>/dev/null || curl -s -m 5 http://ifconfig.me 2>/dev/null || echo "服务器公网IP")

cat <<EOF

============================================================
 frps 已就绪
------------------------------------------------------------
 服务器地址 : $PUBIP
 控制端口   : $PORT
 TOKEN      : $TOKEN
 管理面板   : http://$PUBIP:$PANEL_PORT/static/
              账号 admin / $PANEL_PASS
------------------------------------------------------------
 必须在【云厂商控制台 → 防火墙/安全组】放行：
   TCP  $PORT        frp 控制端口（必须）
   TCP  11985        中文监控台
   TCP  11984        go2rtc 原版界面
   TCP  12222        外网 SSH
   TCP  7500         frp 面板（可选，建议只对你的IP开放）
------------------------------------------------------------
 下一步（在 H28K 设备上执行）：
   bash switch-server.sh $PUBIP --token $TOKEN
============================================================
EOF
