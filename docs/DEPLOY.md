# 详细部署流程

从一台空白设备到「外网能看画面」，按顺序做完这 6 步。

> 全程假设：设备在内网 `192.168.1.0/24`，NVR 同网段；云服务器公网 `1.2.3.4`。
> 实际地址请替换。

---

## 一、准备设备系统

### 1.1 装系统

H28K（RK3528A）推荐用官方 **Armbian Bookworm** 镜像，通过 Maskrom（RKDevTool）刷入 eMMC：

1. 断电，卡针按住机身 Reset 孔
2. 插 USB-C **数据线**到电脑，松开卡针
3. 设备管理器出现 `Rockchip USB Device`（没出现先装 DriverAssistant）
4. RKDevTool → 高级功能 → 擦除所有 → 下载镜像 → 选 `.img` → 执行
5. 完成后断电重启

> 其他 ARM64/x86_64 设备只要装 **Debian 12 / Ubuntu 22.04+**，本项目同样可用。

### 1.2 首次登录

- HDMI 接显示器看启动，或网线接 LAN 口后扫描局域网找到 IP
- 默认 root / `1234`（Armbian），首次登录强制改密码
- 改完密码建议立刻记到密码管理器

### 1.3 基础配置

```bash
# 换国内源（Debian 12 是 deb822 格式）
sed -i 's|http://deb.debian.org|http://mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/*.sources
sed -i 's|http://security.debian.org|http://mirrors.tuna.tsinghua.edu.cn|g' /etc/apt/sources.list.d/*.sources
# armbian 源在国内经常超时，改名停用
mv /etc/apt/sources.list.d/armbian.sources /etc/apt/sources.list.d/armbian.sources.disabled
apt-get update

# 时区
timedatectl set-timezone Asia/Shanghai
```

> `install.sh` 会自动做换源这一步，但手动做一遍能避免第一次 apt 卡住。

---

## 二、云服务器：安装 frps

本项目**只包含客户端（frpc）**，服务端要在云服务器上装一次。

```bash
# 云服务器上（root）
cd /tmp
curl -LO https://ghfast.top/https://github.com/fatedier/frp/releases/download/v0.66.0/frp_0.66.0_linux_amd64.tar.gz
tar -xzf frp_0.66.0_linux_amd64.tar.gz
install -m 0755 frp_0.66.0_linux_amd64/frps /usr/local/bin/frps

mkdir -p /etc/frp
cat > /etc/frp/frps.toml <<'EOF'
bindPort = 7000
auth.method = "token"
auth.token = "换成你自己的长随机串"
# 管理面板（可选）
webServer.addr = "0.0.0.0"
webServer.port = 7500
webServer.user = "admin"
webServer.password = "换成强密码"
EOF

cat > /etc/systemd/system/frps.service <<'EOF'
[Unit]
Description=frp server
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frps -c /etc/frp/frps.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload && systemctl enable --now frps
systemctl status frps --no-pager | head -5
```

**安全组放行**：`7000/tcp`（frp 控制端口）。之后还要加 `11985`、`11984`、`12222`。

> 生成 token：`head -c 24 /dev/urandom | base64 | tr -d '/+='`

---

## 三、确认设备能访问 NVR

```bash
# 在设备上
ping -c 2 192.168.1.64
curl -s -m 5 --digest -u admin:你的NVR密码 \
  http://192.168.1.64/ISAPI/System/deviceInfo | head -5
```

返回 XML（含 `<model>DS-XXXX</model>`）说明**账号密码和网络都对**。

再确认 RTSP：

```bash
curl -s -m 8 --digest -u admin:你的NVR密码 \
  -o /dev/null -w '%{http_code}\n' \
  rtsp://192.168.1.64:554/Streaming/Channels/102
```

- `200` → 正常
- `404` → 通道号不存在，换个通道试（见下方通道规则）
- 连不上 → NVR 关了 RTSP 服务，在 NVR 网页「配置 → 网络 → 高级 → RTSP」里打开

**通道规则**：`<通道号>02` 为子码流、`<通道号>01` 为主码流。
通道 1 → `102`，通道 2 → `202`，通道 10 → `1002`。

---

## 四、部署本项目

```bash
# 电脑上
scp -r h28k-camera-gateway root@192.168.1.50:/root/

# 设备上
cd /root/h28k-camera-gateway
cp config.env.example config.env
vi config.env          # 至少改 VPS_ADDR / VPS_TOKEN / WEB_PASS / NVR_PASS / NVR1
sudo bash install.sh
```

`install.sh` 会依次做：

| 步骤 | 内容 |
|---|---|
| 1 | 换 apt 源，装 nginx / python3 / fail2ban |
| 2 | 装 go2rtc、frpc（优先用 `bin/` 里的，没有再下载） |
| 3 | 按 `config.env` 生成 `go2rtc.yaml`（每路一条 RTSP）+ `cameras.json` |
| 4 | 部署中文页面 `/opt/cam/www/index.html` |
| 5 | 装 `cam-authd`（会话认证 + 登录审计），监听 127.0.0.1:9000 |
| 6 | 写 nginx 配置：8080（内网）+ 8181（PROXY Protocol，给 frp 用） |
| 7 | 生成 `frpc.toml`：监控台 / go2rtc / SSH / 每台 NVR 的 web+sdk+rtsp |
| 8 | 建 systemd 服务并启动 |
| 9 | 配 fail2ban（SSH 防爆破） |
| 10 | 配日志轮转（30 天） |
| 11 | 自检：四个服务状态 + 内网/公网 HTTP 状态码 |

**如果公网返回不是 200**（通常是 frps 版本太低不支持 PROXY Protocol），脚本会自动把 camweb 隧道回退到 8080 并重启，站点不会挂，只是拿不到真实 IP。

---

## 五、云安全组

在云厂商控制台 → 防火墙/安全组，放行：

| 协议 | 端口 | 用途 |
|---|---|---|
| TCP | 11985 | 中文监控台 |
| TCP | 11984 | go2rtc 原版界面 |
| TCP | 12222 | 外网 SSH（可关掉，改用内网） |
| TCP | 7000 | frp 控制（已有） |
| TCP | 18443+ | NVR 网页映射（可选） |
| TCP | 18000+ | NVR 手机 App 映射（可选） |
| TCP | 18554+ | NVR RTSP 映射（可选） |

> 只做网页监控的话，只放 `11985` 就够了。

---

## 六、验证

### 6.1 服务端

```bash
systemctl status go2rtc nginx cam-auth frpc     # 四个都是 active
curl -s -o /dev/null -w '%{http_code}\n' -u admin:密码 http://127.0.0.1:1984/api/streams
```

### 6.2 公网

浏览器打开 `http://1.2.3.4:11985`

1. 应看到登录页
2. 输入 `WEB_USER` / `WEB_PASS`
3. 进入后左侧勾选摄像头 → 右侧出画面

### 6.3 隧道是否通

云服务器面板 `http://1.2.3.4:7500/static/` 能看到在线的 proxy 列表；
或设备上 `journalctl -u frpc -n 30 | grep "start proxy success"`。

---

## 七、多现场 / 多设备

同一台 frps 可以接多个现场，但要保证两点：

1. **frp 的 `name` 唯一**：本项目用 `camweb`、`go2rtc`、`ssh`、`nvr1web`… 第二套会撞车，
   可以在 `install.sh` 里给名字加前缀（如 `site2_camweb`），或每套单独跑一台 frps。
2. **远端端口错开**：改 `PORT_*`（11985→11986 等），别重复。

更省事的做法：**每个现场一台独立的轻量云服务器**（最低配即可），互不干扰。

---

## 八、之后要改什么

| 需求 | 做法 |
|---|---|
| 加/删摄像头 | 改 `config.env` 的 `NVR*` → `bash install.sh` |
| 改登录密码 | `bash /root/set-password.sh '新密码'` |
| 切主码流 | 改 `/opt/go2rtc/go2rtc.yaml` 里该行 `…02` → `…01`，`systemctl restart go2rtc` |
| 网页看不到新加的流 | 页面点「刷新列表」（60 秒也会自动同步） |
| 换设备 | 复制整个目录 + 改 `config.env` 的端口段 |
