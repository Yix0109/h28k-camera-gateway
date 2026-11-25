#!/usr/bin/env bash
# =============================================================
# 【傻瓜式部署向导 · 在 H28K 上跑】
#
#   sudo bash deploy.sh
#
# 它会问你几个问题，自动探测 NVR 通道、生成配置、然后调用 install.sh。
# 全程不需要你手写配置文件。
#
# 想跳过提问（自动化）：
#   sudo DEPLOY_AUTO=1 VPS_ADDR=x VPS_TOKEN=y WEB_PASS=z NVR_LIST="ip|密码" bash deploy.sh
# =============================================================
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

say(){ printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
hr(){ printf '%.0s-' {1..60}; echo; }
die(){ printf '\033[1;31m[失败]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 执行（sudo bash deploy.sh）"
[ -f "$HERE/install.sh" ] || die "找不到 install.sh，请确认在项目目录里"

AUTO=${DEPLOY_AUTO:-0}

ask(){   # ask "提示" "默认值"
  local p="$1" d="${2:-}" v
  if [ -n "$d" ]; then read -r -p "$p [$d]: " v; printf '%s' "${v:-$d}"
  else read -r -p "$p: " v; printf '%s' "$v"; fi
}
askpw(){ local p="$1" v; read -r -s -p "$p: " v; echo >&2; printf '%s' "$v"; }

# ---------- 探测 NVR 通道 ----------
probe_channels(){  # probe_channels IP USER PASS  → 输出 "1,2,3,4" 与名称
  local ip="$1" user="$2" pass="$3" xml ids names
  xml=$(curl -s -m 8 --digest -u "$user:$pass" \
        "http://$ip/ISAPI/ContentMgmt/InputProxy/channels" 2>/dev/null || true)
  case "$xml" in *"<id>"*) ;; *) return 1 ;; esac
  ids=$(printf '%s' "$xml" | grep -o '<id>[0-9]\+</id>' | grep -o '[0-9]\+' | tr '\n' ',' | sed 's/,$//')
  names=$(printf '%s' "$xml" | grep -o '<name>[^<]*</name>' | sed 's/<[^>]*>//g' | tr '\n' ',' | sed 's/,$//')
  [ -n "$ids" ] || return 1
  echo "$ids"
  echo "$names"
  return 0
}

echo
hr
echo "   H28K 摄像头网关 · 部署向导"
hr
if [ "$AUTO" != "1" ]; then
  echo "   按提示填写即可，不知道的直接回车用默认值。"
  echo "   想中途退出：Ctrl+C（不会改动任何东西）"
fi

# ---------- 1. 服务器 ----------
say "1/4 云服务器（已装好 frps 的那台）"
if [ -n "${VPS_ADDR:-}" ]; then
  SRV="$VPS_ADDR"; echo "  地址：$SRV"
else
  echo "   支持填域名，例如 frp.example.com"
  echo "   ★ 用域名的话，以后换服务器只改 DNS，设备这边一行都不用动"
  SRV=$(ask "   服务器地址（IP 或域名）")
fi
[ -n "$SRV" ] || die "服务器地址不能为空"

if [ -n "${VPS_TOKEN:-}" ]; then TOK="$VPS_TOKEN"; else
  echo "   在云服务器上执行 server-setup.sh 后会打印 TOKEN"
  TOK=$(askpw "   frp TOKEN")
fi
[ -n "$TOK" ] || die "TOKEN 不能为空"

# ---------- 2. 网页密码 ----------
say "2/4 监控台登录密码"
if [ -n "${WEB_PASS:-}" ]; then WP="$WEB_PASS"; echo "   （已从环境变量读取）"; else
  while :; do
    WP=$(askpw "   设置登录密码（至少 8 位）")
    [ "${#WP}" -ge 8 ] && break
    echo "   太短了，再来一次"
  done
fi
[ "${#WP}" -ge 8 ] || die "密码至少 8 位"

# ---------- 3. 摄像头 ----------
say "3/4 摄像头 / NVR"
echo "   支持多台，逐个添加。没有更多就留空回车。"
NVRCFG=()
NVRUSER_DEFAULT=${NVR_USER:-admin}
if [ -n "${NVR_LIST:-}" ]; then
  for line in $NVR_LIST; do
    ip="${line%%|*}"; rest="${line#*|}"
    user="${rest%%|*}"; pass="${rest#*|}"
    [ "$user" = "$pass" ] && user="$NVRUSER_DEFAULT"
    NVRCFG+=("$ip|$user|$pass")
  done
  echo "   已从环境变量读取 ${#NVRCFG[@]} 台"
fi

while :; do
  n=$((${#NVRCFG[@]}+1))
  [ "$AUTO" = "1" ] && break
  [ "$n" -gt 8 ] && { echo "   最多 8 台"; break; }
  echo
  echo "   --- 第 $n 台 ---"
  NIP=$(ask "   NVR 的 IP（留空结束）")
  [ -n "$NIP" ] || break

  if ! ping -c1 -W2 "$NIP" >/dev/null 2>&1; then
    echo "   ! ping 不通，仍然可以继续（有些 NVR 禁 ping）"
  fi

  NU=$(ask "   账号" "$NVRUSER_DEFAULT")
  NP=$(askpw "   密码")

  echo -n "   正在探测通道…… "
  if RES=$(probe_channels "$NIP" "$NU" "$NP"); then
    chans=$(printf '%s' "$RES" | sed -n '1p')
    names=$(printf '%s' "$RES" | sed -n '2p')
    cnt=$(echo "$chans" | tr ',' '\n' | wc -l)
    echo "成功，找到 $cnt 个通道"
    echo "     通道：$chans"
    echo "     名称：$(echo "$names" | cut -c1-80)..."
    echo "   直接回车用探测结果，或手输要保留的通道（例如 1,2,3）"
    CH=$(ask "   通道" "$chans")
    NM=$(ask "   通道名（可留空，会自动用「通道N」）" "$names")
  else
    echo "探测失败（密码错 / 没开 ISAPI / 网络不通）"
    echo "   不知道就先填 1,2,3,4，登录 NVR 网页能看到实际通道号"
    CH=$(ask "   通道列表" "1,2,3,4")
    NM=$(ask "   通道名（可留空）" "")
  fi

  LABEL=$(ask "   显示名（浏览器顶部按钮上显示）" "NVR$n")
  NVRCFG+=("$NIP|$NU|$NP|$LABEL|$CH|$NM")
done

[ "${#NVRCFG[@]}" -gt 0 ] || die "至少需要一台 NVR"

# ---------- 4. 生成 config.env ----------
say "4/4 生成配置"
CFG="$HERE/config.env"
[ -f "$CFG" ] && cp -a "$CFG" "$CFG.bak.$(date +%H%M%S)" && echo "   已备份旧 config.env"

{
  echo "# 由 deploy.sh 于 $(date '+%Y-%m-%d %H:%M:%S') 生成"
  echo "VPS_ADDR=$SRV"
  echo "VPS_TOKEN=$TOK"
  echo "VPS_CTRL_PORT=7000"
  echo ""
  echo "WEB_USER=admin"
  echo "WEB_PASS=$WP"
  echo ""
  echo "NVR_USER=$NVRUSER_DEFAULT"
  echo ""
  echo "# 各 NVR 的密码写在下面对应的 NVRn 行里"
  echo ""
  echo "PORT_GO2RTC=11984"
  echo "PORT_CAMWEB=11985"
  echo "PORT_SSH=12222"
  echo "PORT_WEB_BASE=18443"
  echo "PORT_SDK_BASE=18000"
  echo "PORT_RTSP_BASE=18554"
  echo "KEEP_NVR_TUNNELS=1"
  echo "PROXY_PROTOCOL=1"
  echo ""
  i=1
  for row in "${NVRCFG[@]}"; do
    IFS='|' read -r ip user pass label ch nm <<< "$row"
    [ -n "${label:-}" ] || label="NVR$i"
    if [ -n "${nm:-}" ]; then
      echo "NVR$i=\"$ip|$label|$ch|$nm\""
    else
      echo "NVR$i=\"$ip|$label|$ch|\""
    fi
    echo "#NVR${i}_PASS=$pass"
    i=$((i+1))
  done
} > "$CFG"
chmod 600 "$CFG"

echo "   已写入 $CFG"
echo
echo "   -------- 摘要 --------"
echo "   服务器   : $SRV"
echo "   监控台   : http://$SRV:11985"
echo "   摄像头   : ${#NVRCFG[@]} 台"
echo "   登录密码 : $WP"
hr

# 第一台的账号密码作为全局默认（install.sh 生成 yaml 时用）
FIRSTUSER=$(echo "${NVRCFG[0]}" | cut -d'|' -f2)
FIRSTPASS=$(echo "${NVRCFG[0]}" | cut -d'|' -f3)
sed -i "s|^NVR_USER=.*|NVR_USER=$FIRSTUSER|" "$CFG"
grep -q '^NVR_PASS=' "$CFG" || echo "NVR_PASS=$FIRSTPASS" >> "$CFG"

# 记录每台的真实密码，install 完成后按 IP 精确写回（多台密码不同也能对）
: > /root/nvr-passwords.txt
for row in "${NVRCFG[@]}"; do
  IFS='|' read -r ip user pass label ch nm <<< "$row"
  printf '%s\t%s\n' "$ip" "$pass" >> /root/nvr-passwords.txt
done
chmod 600 /root/nvr-passwords.txt

if [ "$AUTO" != "1" ]; then
  echo
  printf '现在开始部署？(Y/n) '
  read -r go
  case "${go:-Y}" in [Yy]*) ;; *) echo "配置已保存，之后可运行： sudo bash install.sh"; exit 0 ;; esac
fi

# ---------- 执行 ----------
echo
say "开始安装（约 1-3 分钟）"
bash "$HERE/install.sh"
RC=$?

if [ "$RC" -eq 0 ]; then
  say "按 IP 校正各台 NVR 的密码（特殊字符自动 URL 编码）"
  bash "$HERE/tools/fix-nvr-passwords.sh" /root/nvr-passwords.txt || true
fi

if [ "$RC" -eq 0 ]; then
  cat <<EOF

============================================================
 全部完成
   中文监控台 : http://$SRV:11985
   登录       : admin / $WP
   外网 SSH   : ssh root@$SRV -p 12222
============================================================
EOF
fi
exit "$RC"

