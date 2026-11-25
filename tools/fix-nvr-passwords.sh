#!/usr/bin/env bash
# =============================================================
# 按 IP 精确修正 go2rtc.yaml 里每台 NVR 的密码
# （多台 NVR 密码不同时使用；install.sh 只支持一个全局密码）
#
# 用法： bash fix-nvr-passwords.sh [/root/nvr-passwords.txt]
# 文件格式： 每行  <IP><TAB><密码>
# =============================================================
set -euo pipefail

MAP="${1:-/root/nvr-passwords.txt}"
YAML=/opt/go2rtc/go2rtc.yaml

[ -f "$MAP" ] || { echo "没有 $MAP，跳过"; exit 0; }
[ -f "$YAML" ] || { echo "找不到 $YAML"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "缺 python3"; exit 1; }

cp -a "$YAML" "$YAML.bak.$(date +%H%M%S)"

python3 - "$MAP" "$YAML" <<'PY'
import re, sys
from urllib.parse import quote

mapf, yamlf = sys.argv[1], sys.argv[2]
pairs = []
for line in open(mapf, encoding="utf-8"):
    parts = line.rstrip("\n").split("\t")
    if len(parts) == 2 and parts[0].strip():
        # 密码里的 @ : / # 等必须百分号编码，否则 RTSP URL 会被截断
        pairs.append((parts[0].strip(), quote(parts[1], safe="")))

src = open(yamlf, encoding="utf-8").read()
changed = 0
for ip, pw in pairs:
    pat = re.compile(r"(rtsp://[^:/\s@]+:)[^@\s]*@(" + re.escape(ip) + r":)")
    new, n = pat.subn(lambda m: m.group(1) + pw + "@" + m.group(2), src)
    if n:
        src = new
        changed += n
open(yamlf, "w", encoding="utf-8").write(src)
print("  已修正 %d 条流的密码（含特殊字符的已自动 URL 编码）" % changed)
PY

chmod 600 "$YAML"
if command -v systemctl >/dev/null 2>&1 && systemctl is-active go2rtc >/dev/null 2>&1; then
  systemctl restart go2rtc
  sleep 2
  echo "  go2rtc: $(systemctl is-active go2rtc)"
fi
