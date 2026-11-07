#!/usr/bin/env bash
# =============================================================
# 一键修改登录密码（go2rtc / cam-authd / nginx 三处同步）
# 用法：bash set-password.sh '新密码' [用户名，默认 admin]
# =============================================================
set -euo pipefail

NEW="${1:-}"
USER_NAME="${2:-admin}"

[ -n "$NEW" ] || { echo "用法: bash set-password.sh '新密码' [用户名，默认 admin]"; exit 1; }
[ "${#NEW}" -ge 8 ] || { echo "密码至少 8 位"; exit 1; }

YAML=/opt/go2rtc/go2rtc.yaml
CONF=/etc/nginx/conf.d/cam.conf
SNIP=/etc/nginx/snippets/cam-common.conf
ENVF=/etc/cam-authd.env

[ -f "$YAML" ] || { echo "找不到 $YAML"; exit 1; }
[ -f "$SNIP" ] || { echo "找不到 $SNIP"; exit 1; }

STAMP=$(date +%Y%m%d-%H%M%S)

echo "=== 1/4 改 go2rtc 配置 ==="
cp -a "$YAML" "$YAML.bak.$STAMP"
awk -v pw="$NEW" -v u="$USER_NAME" '
    /^  username:/ { print "  username: \"" u "\""; next }
    /^  password:/ { print "  password: \"" pw "\""; next }
    { print }
' "$YAML" > "$YAML.new"
mv "$YAML.new" "$YAML"
chmod 600 "$YAML"
grep -n -E '^  (username|password):' "$YAML" | head -2

echo "=== 2/4 改会话认证凭据 ==="
if [ -f "$ENVF" ]; then
  cp -a "$ENVF" "$ENVF.bak.$STAMP"
  cat > "$ENVF" <<ENVEOF
AUTHD_USER=$USER_NAME
AUTHD_PASS=$NEW
AUTHD_MAX_FAIL=10
AUTHD_FAIL_WINDOW=600
AUTHD_BAN=30
ENVEOF
  chmod 600 "$ENVF"
  systemctl restart cam-auth
  echo "  已更新 $ENVF 并重启 cam-auth"
else
  echo "  (未安装 cam-authd，跳过)"
fi

echo "=== 3/4 改 nginx 转发用的 Basic 头 ==="
B64=$(printf '%s:%s' "$USER_NAME" "$NEW" | base64 | tr -d '\n')
cp -a "$SNIP" "$SNIP.bak.$STAMP"
sed -i "s|proxy_set_header Authorization \"Basic [^\"]*\"|proxy_set_header Authorization \"Basic $B64\"|" "$SNIP"
grep -n 'Authorization' "$SNIP"

echo "=== 4/4 生效并自检 ==="
nginx -t 2>&1 | tail -1
systemctl restart go2rtc
systemctl reload nginx
sleep 2
printf '  未登录访问 : '; curl -s -o /dev/null -w '%{http_code}\n' --max-time 6 http://127.0.0.1:8080/
printf '  登录页     : '; curl -s --max-time 6 http://127.0.0.1:8080/login | grep -o '监控中心' | head -1
printf '  表单登录   : '; curl -s -o /dev/null -w '%{http_code}\n' --max-time 6 -d "username=$USER_NAME&password=$NEW" http://127.0.0.1:8080/login
printf '  原版界面   : '; curl -s -o /dev/null -w '%{http_code}\n' --max-time 6 -u "$USER_NAME:$NEW" http://127.0.0.1:1984/
printf '  服务状态   : '; systemctl is-active go2rtc nginx cam-auth | tr '\n' ' '; echo

cat <<EOF

============================================================
 完成。账号 $USER_NAME / $NEW
   备份： $YAML.bak.$STAMP
          $SNIP.bak.$STAMP
 注意：cam-authd 重启会让所有在线会话失效，其他人需重新登录。
============================================================
EOF
