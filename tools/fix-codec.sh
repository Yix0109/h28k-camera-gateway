#!/bin/bash
# 把 NVR 子码流从 H.265 改成 H.264
# 背景：浏览器（Chrome/Edge）的 MSE 和 WebRTC 都不解码 H.265，
#       页面会报 "mse: streams: codecs not matched: video:H265 => video:H264" 然后黑屏。
#       海康新版固件出厂把子码流也设成 H.265，必须改回 H.264。
#
# 用法：sudo bash tools/fix-codec.sh
#       CHLIST="1 2 3"  只处理指定通道
#       YAML=/opt/go2rtc/go2rtc.yaml 指定配置文件
set -u

YAML="${YAML:-/opt/go2rtc/go2rtc.yaml}"
CHLIST="${CHLIST:-}"

[ -r "$YAML" ] || { echo "读不到 $YAML"; exit 1; }

mapfile -t urls < <(grep -oE 'rtsp://[^"[:space:]]+' "$YAML" | sort -u)
if [ "${#urls[@]}" -eq 0 ]; then
  echo "在 $YAML 里没找到 rtsp:// 地址（是否用了 ffmpeg: 前缀？）"
  exit 1
fi
echo "从配置里读到 ${#urls[@]} 条流"

declare -A seen
changed=0
for u in "${urls[@]}"; do
  cred="${u#rtsp://}"; cred="${cred%%@*}"
  rest="${u#*@}"
  ip="${rest%%:*}"
  path="${rest#*/}"
  chid="${path##*/}"
  case "$chid" in ''|*[!0-9]*) echo "  跳过无法识别的地址：$u"; continue;; esac
  if [ -n "$CHLIST" ]; then
    ch="${chid%??}"
    case " $CHLIST " in *" $ch "*) : ;; *) continue;; esac
  fi
  key="$ip/$chid"
  [ -n "${seen[$key]:-}" ] && continue
  seen[$key]=1

  api="http://$ip/ISAPI/Streaming/channels/$chid"
  f=$(mktemp)
  code=$(curl -s --digest -u "$cred" -o "$f" -w '%{http_code}' -m 8 "$api" 2>/dev/null)
  if [ "$code" != "200" ]; then
    echo "  $ip 通道$chid -> GET $code（密码不对或通道不存在，跳过）"
    rm -f "$f"; continue
  fi
  vc=$(tr -d '\n' < "$f" | grep -o '<videoCodecType>[^<]*' | head -1 | sed 's/.*>//')
  if [ "$vc" = "H.264" ]; then
    echo "  $ip 通道$chid -> 已是 H.264"
    rm -f "$f"; continue
  fi
  sed -i 's#<videoCodecType>H\.265</videoCodecType>#<videoCodecType>H.264</videoCodecType>#' "$f"
  r=$(curl -s --digest -u "$cred" -X PUT -H 'Content-Type: application/xml' \
        --data-binary @"$f" -o /dev/null -w '%{http_code}' -m 12 "$api" 2>/dev/null)
  echo "  $ip 通道$chid -> ${vc:-未知} 改成 H.264：PUT $r"
  case "$r" in 200|201|204) changed=$((changed+1));; esac
  rm -f "$f"
done

echo
echo "本次改动 $changed 个通道"
if [ "$changed" -gt 0 ]; then
  systemctl restart go2rtc && echo "已重启 go2rtc，等 3~5 秒后到页面点「刷新列表」再勾画面"
else
  echo "没有需要改的通道（若仍是黑屏，请看 journalctl -u go2rtc -n 30）"
fi
