# 排错手册

按「现象 → 原因 → 处理」查。命令都在设备（H28K）上执行，除非特别说明。

---

## 一、部署阶段

### `apt` 报 404 / 长时间卡住

**原因**：国内访问 `deb.debian.org` 不稳定；Armbian 源的 `github.armbian.com` 常超时。

```bash
# 换成清华源
sed -i 's|https\?://deb.debian.org|http://mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/*.sources
sed -i 's|https\?://security.debian.org|http://mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/*.sources
# 停用 armbian 源
mv /etc/apt/sources.list.d/armbian.sources /etc/apt/sources.list.d/armbian.sources.disabled 2>/dev/null
apt-get update
```

### GitHub 下载超时

`install.sh` 已走 `ghfast.top` 代理。仍失败就手动下好放进 `bin/`：

| 文件 | 来源 |
|---|---|
| `bin/go2rtc_linux_arm64` | https://github.com/AlexxIT/go2rtc/releases |
| `bin/frpc_linux_arm64` | https://github.com/fatedier/frp/releases |

> 注意：**解压出来的 frpc 要校验大小**（Linux arm64 约 14.7 MB）。曾经遇到压缩包被截断，
> 解压出的二进制大小对但内容坏，跑起来直接 `SEGV`。用 `sha256sum` 对比官方值。

---

## 二、页面打不开

### 公网 11985 超时，内网 8080 正常

1. 云安全组没放行 `11985` → 控制台加规则
2. `frpc` 没起来 → `systemctl status frpc`，`journalctl -u frpc -n 30`
3. frps 没起来 / token 不对 → 云服务器 `systemctl status frps`

### 公网返回 400 / 502

若启用了 `PROXY_PROTOCOL=1` 而 frps 版本 < 0.53，nginx 会因读不到 PROXY 头而返回 400。

```bash
# 回退
sed -i 's/localPort = 8181/localPort = 8080/; /proxyProtocolVersion/d' /etc/frp/frpc.toml
nohup sh -c 'sleep 2; systemctl restart frpc' >/dev/null 2>&1 &
```

### 打开是 go2rtc 的英文界面而不是中文台

nginx 的 `location = /` 没生效（`try_files` 把 `/` 兜底给了 go2rtc）。

```bash
grep -n 'location = /' /etc/nginx/conf.d/cam.conf   # 应该能看到
nginx -t && systemctl reload nginx
```

---

## 三、登录相关

### 提示「密码错误次数过多，请 N 秒后再试」

同一 IP 连错 10 次会锁 30 秒（`/etc/cam-authd.env` 里的 `AUTHD_MAX_FAIL` / `AUTHD_BAN`）。
等 30 秒，或：

```bash
systemctl restart cam-auth      # 会清空所有在线会话
```

### 能登录，但画面区域空白 / 401

nginx 转发给 go2rtc 的 Basic 头与 go2rtc 密码不一致（多见于手工改过密码）。

```bash
bash /root/set-password.sh '当前密码'    # 三处一起重算
```

### 按 F5 后被踢回登录页

**这是设计行为**（严格会话：刷新=强制登出）。不是 bug。

### 浏览器一直弹旧密码框

浏览器缓存了 Basic 凭据（11984 端口）。清站点数据或换无痕窗口。
中文台（11985）用的是表单登录 + Cookie，不受影响。

---

## 四、画面相关

### 所有通道显示同一个画面

RTSP 路径里的通道号没变——早期版本曾把所有流都写成 `102`。

```bash
grep 'rtsp://' /opt/go2rtc/go2rtc.yaml | head
# 正确的应该是 102 / 202 / 302 / ... / 1002 ...
```

重新生成：改 `config.env` 后 `bash install.sh`。

### 画面全黑 / 一直转圈

按顺序排查：

```bash
# 1) NVR 密码对不对
curl -s -m 5 --digest -u admin:密码 http://<NVR_IP>/ISAPI/System/deviceInfo | head -3

# 2) 通道号存不存在
curl -s -m 5 --digest -u admin:密码 http://<NVR_IP>/ISAPI/Streaming/channels | grep '<id>'

# 3) go2rtc 能不能拉到
journalctl -u go2rtc -n 30 --no-pager | tail -20
```

常见报错：

| 报错 | 含义 |
|---|---|
| `401 Unauthorized` | 密码错 |
| `404 Not Found` | 通道号不存在 |
| `connection reset by peer` | 密码错或该通道未启用 |
| `exec: "ffmpeg": executable file not found` | 只影响「抓图/截图」接口，不影响网页播放，可忽略；要用就 `apt install ffmpeg` |

### 只有主码流清晰，网页却模糊

网页默认用 `…02` 子码流（640p）。要高清就把该行改 `…01`，但带宽会涨到约 4 Mbps/路。

### H.265 通道黑屏

浏览器 MSE/WebRTC **不支持 H.265**。在 NVR 里把该通道编码改成 **H.264**，或只用子码流。

---

## 五、性能与带宽

| 现象 | 原因 | 处理 |
|---|---|---|
| 同时看 3 路以上开始卡 | 云服务器带宽不足（轻量常见 5 Mbps） | 升带宽，或减少同屏路数 |
| 画面延迟 3–5 秒 | 走了 HLS | 播放器右上角切到 MSE |
| go2rtc 进程 CPU 100% | 配了转码 / ffmpeg | 配置里不要写转码，只做 relay |
| 设备内存吃紧 | 同屏路数过多 | 每屏 ≤9 路，看的人越多越吃 |

---

## 六、外网 SSH

### 连不上

```bash
# 设备上
systemctl status frpc
ss -lntp | grep ':22'
```

- 端口 `12222` 没在安全组 → 加规则
- frpc 挂了 → 重启
- 连上了但密码不对 → 用户密码问题

### 改 frp 配置后 SSH 立刻断

`systemctl restart frpc` 会重启承载 SSH 的那条隧道（自己把自己踢下线）。
用延迟重启：

```bash
nohup sh -c 'sleep 3; systemctl restart frpc' >/dev/null 2>&1 &
```

---

## 七、日志与审计

```bash
tail -f /var/log/cam-auth.log            # 登录：时间 IP 用户 结果 UA
tail -f /var/log/nginx/cam-access.log    # 带真实 IP 的请求
fail2ban-client status sshd              # SSH 封禁情况
```

若 `cam-auth.log` 里 IP 全是 `127.0.0.1`：说明 PROXY Protocol 没生效
（`PROXY_PROTOCOL=0` 或 frps 太旧），只能拿到局域网直连的真实 IP。

---

## 八、彻底重来

```bash
systemctl disable --now go2rtc frpc cam-auth
rm -rf /opt/go2rtc /opt/cam /opt/cam-authd /etc/frp /etc/nginx/conf.d/cam.conf
rm -f /etc/systemd/system/{go2rtc,frpc,cam-auth}.service
systemctl daemon-reload
# 然后重新 bash install.sh
```

NVR 和摄像头侧不需要动。
