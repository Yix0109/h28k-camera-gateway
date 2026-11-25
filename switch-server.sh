#!/usr/bin/env bash
# =============================================================
# 【换服务器专用 · 在 H28K 上跑】一条命令把隧道切到新服务器
#
# 用法：
#   bash switch-server.sh 新IP或域名
#   bash switch-server.sh frp.example.com --token 新token
#   bash switch-server.sh 1.2.3.4 --token xx --port 7000 --yes
#   bash switch-server.sh --restart-only        # 域名没变、只改了 DNS 时用它
#
# 做的事：
#   1) 备份 frpc.toml
#   2) 改 serverAddr（可选 token / 端口）
#   3) 延迟重启 frpc —— 避免切断正在用的 SSH
#   4) 等隧道建立并自检，失败自动回滚
# =============================================================
set -euo pipefail

NEW_HOST=""
if [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; then
  NEW_HOST="$1"; shift
fi

NEW_TOKEN=""
NEW_PORT=""
ASSUME_YES=0
RESTART_ONLY=0
TOML=/etc/frp/frpc.toml
WAIT=${WAIT:-25}

while [ $# -gt 0 ]; do
  case "$1" in
    --token) NEW_TOKEN="$2"; shift 2 ;;
    --port)  NEW_PORT="$2"; shift 2 ;;
    --restart-only|--dns-changed) RESTART_ONLY=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    -h|--help) sed -n '1,16p' "$0"; exit 0 ;;
    *) echo "未知参数：$1"; exit 1 ;;
  esac
done

if [ "$RESTART_ONLY" != "1" ] && [ -z "$NEW_HOST" ]; then
  sed -n '1,16p' "$0"; exit 1
fi

say(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
ok(){ echo "  ✔ $*"; }
warn(){ echo "  ! $*"; }
die(){ printf '\033[1;31m[失败]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 执行"
[ -f "$TOML" ] || die "找不到 $TOML，这台机器没装过 frpc"

STAMP=$(date +%Y%m%d-%H%M%S)
OLD_HOST=$(grep -m1 '^serverAddr' "$TOML" | sed 's/.*"\(.*\)".*/\1/')
OLD_TOKEN=$(grep -m1 '^auth.token' "$TOML" | sed 's/.*"\(.*\)".*/\1/')
[ "$RESTART_ONLY" = "1" ] && NEW_HOST="$OLD_HOST"

say "0. 当前 → 目标"
echo "  旧服务器：$OLD_HOST"
echo "  新服务器：$NEW_HOST"
if [ "$RESTART_ONLY" = "1" ]; then
  echo "  模式：仅重启（DNS 已改，让 frpc 重新解析域名）"
fi

# 域名先看一眼解析结果，避免“改完 DNS 还没生效”白折腾
case "$NEW_HOST" in
  *[a-zA-Z]*)
    RESOLVED=$(getent hosts "$NEW_HOST" 2>/dev/null | awk '{print $1}' | head -1 || true)
    if [ -n "$RESOLVED" ]; then
      echo "  域名解析：$NEW_HOST → $RESOLVED"
    else
      echo "  域名解析：$NEW_HOST 解析失败（DNS 还没生效？稍等 TTL 再试）"
    fi
    ;;
esac

if [ "$ASSUME_YES" != "1" ]; then
  printf '\n确认切换？(yes/N) '
  read -r ans
  [ "$ans" = "yes" ] || { echo "已取消"; exit 0; }
fi

say "1. 备份"
cp -a "$TOML" "$TOML.bak.$STAMP"
ok "$TOML.bak.$STAMP"

say "2. 连通性预检（新服务器 $NEW_PORT 是否可达）"
P=${NEW_PORT:-$(grep -m1 '^serverPort' "$TOML" | grep -o '[0-9]*')}
if timeout 5 bash -c "cat < /dev/null > /dev/tcp/$NEW_HOST/$P" 2>/dev/null; then
  ok "$NEW_HOST:$P 可连通"
else
  warn "$NEW_HOST:$P 连不通"
  echo "     常见原因：frps 没启动 / 云安全组没放行 / 地址写错"
  if [ "$ASSUME_YES" != "1" ]; then
    printf '     仍然继续？(yes/N) '; read -r ans2
    [ "$ans2" = "yes" ] || { echo "已取消"; exit 0; }
  fi
fi

say "3. 写入新配置"
if [ "$RESTART_ONLY" = "1" ]; then
  echo "  （仅重启模式，配置不变）"
else
  sed -i "s|^serverAddr = .*|serverAddr = \"$NEW_HOST\"|" "$TOML"
  [ -n "$NEW_PORT" ]  && sed -i "s|^serverPort = .*|serverPort = $NEW_PORT|" "$TOML"
  [ -n "$NEW_TOKEN" ] && sed -i "s|^auth.token = .*|auth.token = \"$NEW_TOKEN\"|" "$TOML"
fi
grep -E '^serverAddr|^serverPort|^auth.token' "$TOML" | sed 's/\(auth.token = "\).*/\1***"/'

say "4. 延迟 3 秒重启 frpc（不切断当前 SSH）"
TS=$(date '+%Y-%m-%d %H:%M:%S')
nohup bash -c "sleep 3; systemctl restart frpc" >/dev/null 2>&1 &
echo "  SSH 可能会断几秒，重连后继续看结果"
sleep 6

say "5. 等待隧道建立（最多 ${WAIT}s）"
i=0
SUCCESS=0
while [ $i -lt "$WAIT" ]; do
  if journalctl -u frpc --since "$TS" --no-pager 2>/dev/null | grep -q "start proxy success"; then
    SUCCESS=1; break
  fi
  sleep 2; i=$((i+2))
done

if [ "$SUCCESS" = "1" ]; then
  ok "隧道已建立"
  journalctl -u frpc --since "$TS" --no-pager 2>/dev/null | grep -c "start proxy success" | xargs echo "  成功建立的隧道数："
else
  warn "未检测到 start proxy success"
  journalctl -u frpc -n 15 --no-pager 2>/dev/null | tail -15
fi

say "6. 结果"
if [ "$SUCCESS" = "1" ]; then
  LANIP=$(hostname -I 2>/dev/null | awk '{print $1}')
  printf '  本地登录页：'; curl -s -o /dev/null -w '%{http_code}\n' --max-time 6 http://127.0.0.1:8080/login || true
  cat <<EOF

============================================================
 切换完成：$OLD_HOST → $NEW_HOST
   中文监控台 : http://$NEW_HOST:11985
   go2rtc原版 : http://$NEW_HOST:11984
   外网 SSH   : ssh root@$NEW_HOST -p 12222
   内网调试   : http://$LANIP:8080

 备份：$TOML.bak.$STAMP
 回滚：bash switch-server.sh $OLD_HOST$([ -n "$OLD_TOKEN" ] && echo " --token $OLD_TOKEN")
============================================================
EOF
else
  echo "  隧道没起来，自动回滚到 $OLD_HOST"
  cp -a "$TOML.bak.$STAMP" "$TOML"
  systemctl restart frpc
  sleep 4
  printf '  回滚后状态：'; systemctl is-active frpc
  cat <<EOF

  回滚完成。排查方向：
    · 新服务器上 frps 是否在跑： systemctl status frps
    · TOKEN 是否一致：          两边 auth.token 必须完全相同
    · 云安全组是否放行 TCP ${NEW_PORT:-$P}
    · 手动看日志：              journalctl -u frpc -f
EOF
  exit 1
fi
