#!/usr/bin/env bash
# =============================================================
# 自定义站点名称（三处同时改，改完立即生效，不用重装）
#
#   1) 浏览器标签页标题
#   2) 监控页面左上角大标题
#   3) 登录框标题 + 底部小字
#
# 用法：
#   sudo bash set-site-name.sh "长沙分公司监控"
#   sudo bash set-site-name.sh "长沙分公司监控" "某某公司 安防监控系统"
#
# 不带参数运行 = 显示当前名称
# =============================================================
set -euo pipefail

WEB=/opt/cam/www/index.html
AUTHD=/opt/cam-authd/authd.py
ENVF=/etc/cam-authd.env

[ "$(id -u)" -eq 0 ] || { echo "请用 root 运行（sudo bash $0 ...）"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "缺 python3"; exit 1; }
[ -f "$WEB" ]   || { echo "找不到 $WEB（先跑 install.sh）"; exit 1; }
[ -f "$AUTHD" ] || { echo "找不到 $AUTHD（先跑 install.sh）"; exit 1; }

NEW="${1:-}"
FOOT="${2:-}"

if [ -z "$NEW" ]; then
  echo "当前站点名称："
  python3 - "$WEB" "$AUTHD" "$ENVF" <<'PY'
import re, sys, os
web, authd, envf = sys.argv[1:4]
def pick(path, pat):
    m = re.search(pat, open(path, encoding="utf-8").read(), re.S)
    return m.group(1).strip() if m else "(未找到)"print("  页面标题 :", pick(web, r"<h1>(.*?)</h1>"))
print("  标签页   :", pick(web, r"<title>(.*?)</title>"))
print("  登录框   :", pick(authd, r'<h1>(.*?)</h1>'))
print("  登录框底部:", pick(authd, r'<div class="foot">(.*?)</div>'))
if os.path.exists(envf):
    for line in open(envf, encoding="utf-8"):
        if line.startswith(("AUTHD_SITE=", "AUTHD_FOOT=")):
            print("  env      :", line.rstrip())
PY
  exit 0
fi

FOOT="${FOOT:-$NEW}"

echo "把站点名称改成：[$NEW]（底部小字：[$FOOT]）"

# 备份
for f in "$WEB" "$AUTHD" "$ENVF"; do
  [ -f "$f" ] && cp -a "$f" "$f.bak.$(date +%Y%m%d-%H%M%S)"
done

python3 - "$WEB" "$AUTHD" "$ENVF" "$NEW" "$FOOT" <<'PY'
import re, sys, os, html

web, authd, envf, name, foot = sys.argv[1:6]

def sub_once(text, pat, repl):
    new, n = re.subn(pat, repl, text, count=1, flags=re.S)
    return new, n

# ---------- 1. 页面：<title> 与 <h1> ----------
t = open(web, encoding="utf-8").read()
t, n1 = sub_once(t, r"<title>.*?</title>", "<title>%s</title>" % html.escape(name))
t, n2 = sub_once(t, r"<h1[^>]*>.*?</h1>",    "<h1>%s</h1>" % html.escape(name))
open(web, "w", encoding="utf-8").write(t)
print("  页面 %s : title改%d处 h1改%d处" % (os.path.basename(web), n1, n2))

# ---------- 2. 登录页 ----------
s = open(authd, encoding="utf-8").read()

if "__SITE__" in s:
    # 新版 authd.py：名称来自环境变量，只需写 env（下面统一处理）
    print("  登录页 authd.py : 新版本，走环境变量")
else:
    # 旧版 authd.py：直接改死字符串
    s, a = sub_once(s, r"<title>.*?</title>", "<title>登录 · %s</title>" % html.escape(name))
    s, b = sub_once(s, r"<h1>.*?</h1>",    "<h1>%s</h1>" % html.escape(name))
    s, c = sub_once(s, r'<div class="foot">.*?</div>',
                    '<div class="foot">%s</div>' % html.escape(foot))
    open(authd, "w", encoding="utf-8").write(s)
    print("  登录页 authd.py : 旧版本，已改 title%d h1%d foot%d" % (a, b, c))

# ---------- 3. env（新版用得上，旧版也无害） ----------
lines = []
if os.path.exists(envf):
    lines = [l for l in open(envf, encoding="utf-8").read().splitlines()
             if not l.startswith(("AUTHD_SITE=", "AUTHD_FOOT="))]
lines.append('AUTHD_SITE="%s"' % name.replace('"', '\\"'))
lines.append('AUTHD_FOOT="%s"' % foot.replace('"', '\\"'))
with open(envf, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
os.chmod(envf, 0o600)
print("  env %s : 已写入 AUTHD_SITE / AUTHD_FOOT" % os.path.basename(envf))
PY

# 语法自检，改坏了立刻回滚
if ! python3 -c "import ast,sys;ast.parse(open('$AUTHD',encoding='utf-8').read())" 2>/dev/null; then
  echo "!! authd.py 语法出错，回滚"
  cp -a "$(ls -t $AUTHD.bak.* | head -1)" "$AUTHD"
  exit 1
fi

echo "重启 cam-auth ..."
systemctl restart cam-auth
sleep 1
printf '  cam-auth : '; systemctl is-active cam-auth
printf '  nginx    : '; systemctl is-active nginx

echo
echo "验证（本机 8080）："
code=$(curl -s -o /tmp/_login.html -w '%{http_code}' --max-time 6 http://127.0.0.1:8080/login || echo 000)
echo "  /login -> $code"
grep -o '<h1>[^<]*</h1>' /tmp/_login.html 2>/dev/null | head -1 | sed 's/^/  登录框标题: /'
grep -o '<title>[^<]*</title>' /tmp/_login.html 2>/dev/null | head -1 | sed 's/^/  标签页    : /'
grep -o '<div class="foot">[^<]*</div>' /tmp/_login.html 2>/dev/null | head -1 | sed 's/^/  底部小字  : /'
echo
echo "完成。浏览器打开监控台（可能需要 Ctrl+F5 强刷一次）"
