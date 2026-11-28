# 摄像头网关 · go2rtc + frp + 中文监控台

把厂区/门店的**录像机（NVR / IPC，任何支持标准 RTSP 的品牌）**变成**外网可看的低延迟网页监控**，跑在一台便宜的常开小机器上——**arm64 / amd64 都行，不挑型号**（本仓库在 HINLINK H28K / RK3528 上验证过）。默认支持**多台录像机、每台多路通道**。

```
┌─────────┐   RTSP    ┌──────────────────────────┐   frp    ┌──────────┐   浏览器
│ 录像机   │ ────────▶ │  网关设备 (Debian/Ubuntu) │ ───────▶ │ 云服务器  │ ───────▶ 中文监控台
│  ×N 台   │  554      │  go2rtc :1984            │  token   │  frps    │   http(s)
└─────────┘           │  nginx  :8080 (中文页面)  │          │  :7000   │
                      │  cam-authd :9000 (会话)   │          └──────────┘
                      │  frpc                    │
                      └──────────────────────────┘
```

延迟约 **0.5–1.5 秒**（MSE），不需要厂商 App、不需要公网 IP、不做转码。

---

## 特性

| 能力 | 说明 |
|---|---|
| 多 NVR 聚合 | 一个页面看多台 NVR 的全部通道，按前缀分组，最多 9 路同屏 |
| 低延迟 | 走 go2rtc 的 MSE/WebRTC，不用 HLS，延迟 1 秒级 |
| 不转码 | 只做 RTSP 转发（relay），低配小主机也能扛，CPU 占用个位数 |
| 中文界面 | 自带中文监控台，摄像头名来自配置，不是 go2rtc 的英文原版 |
| 严格会话 | 表单登录 + 会话级 Cookie + 刷新即登出 + 前端零存储 |
| 防爆破 | 同 IP 连续 10 次密码错 → 锁 30 秒；SSH 由 fail2ban 兜底 |
| 真实 IP | frp 开 PROXY Protocol v2，nginx/审计日志记录访客真实 IP |
| 登录审计 | `/var/log/cam-auth.log`：时间 / IP / 用户名 / 结果 / 客户端 |
| 一键部署 | `install.sh` 幂等，改完配置重跑即可；自带校验与自检 |
| 不用公网 IP | 全部走 frp 反向隧道，家宽/4G 后面也能用 |

---

## 前置条件

| 项 | 要求 |
|---|---|
| 设备 | **不挑型号**：任何能跑 Debian 12 / Ubuntu 22.04+ 的机器都行——arm64（如 RK3528、RK3568、树莓派、电视盒子）或 amd64（迷你主机、旧笔记本、虚拟机）。内存 ≥1 GB，能长期开机即可 |
| 系统 | 已装好系统、能 SSH 登录 root |
| 网络 | 设备能与录像机互通；能访问外网（装依赖用） |
| 云服务器 | 已装 **frps**（本项目只含客户端），有公网 IP |
| 录像机 | **不挑品牌型号**：任何支持标准 RTSP 的 NVR / IPC 都行（海康、大华、宇视、TP-Link、雄迈…）。默认按海康的路径规则 `Streaming/Channels/<通道>02` 生成，其它品牌改生成的 yaml 即可 |
| 账号 | root |

> frps 的安装不在本项目范围，见 [docs/DEPLOY.md#二云服务器-安装-frps](docs/DEPLOY.md)。

---

## 快速开始（傻瓜式，两条命令）

### 第 1 步：云服务器装 frps

```bash
scp -r h28k-camera-gateway root@<云服务器IP>:/root/
ssh root@<云服务器IP>
cd /root/h28k-camera-gateway
bash server-setup.sh
```

跑完会打印 **TOKEN** 和要放行的端口。记下 TOKEN。
（也会提示你去云控制台加安全组：`7000`、`11985`、`11984`、`12222`）

### 第 2 步：设备上跑向导

```bash
scp -r h28k-camera-gateway root@<设备IP>:/root/
ssh root@<设备IP>
cd /root/h28k-camera-gateway
sudo bash deploy.sh
```

向导只问 4 类问题：

| 会问什么 | 说明 |
|---|---|
| 服务器地址 | IP 或域名。**填域名的话，以后换服务器只需改 DNS** |
| frp TOKEN | 上一步打印的那串 |
| 登录密码 | 中文台密码，至少 8 位 |
| NVR 的 IP / 账号 / 密码 | 逐台添加，留空回车结束 |

**它会自动做这些事**：
- 探测每台 NVR 的通道数量和通道名（调 ISAPI，成功就自动填好）
- 生成 `config.env`（不用手写）
- 直接调用 `install.sh` 完成部署
- 多台 NVR 密码不同也能各自对上（按 IP 精确写回）

---

## 换服务器（一条命令）

**方案一：直接用域名（推荐）**

安装时「服务器地址」填 `frp.example.com`，以后换服务器只改 DNS 的 A 记录：

```bash
# 1) 新服务器
bash server-setup.sh                        # 记下 TOKEN

# 2) DNS 里把 frp 的 A 记录改成新 IP，等 TTL（建议设 300 秒）

# 3) 设备上让 frpc 重新解析（不改任何配置）
bash switch-server.sh --restart-only
```

**方案二：IP 直连**

```bash
# 新服务器
bash server-setup.sh          # 记下新 TOKEN

# 设备上
bash switch-server.sh 新IP --token 新TOKEN
```

两种都由脚本自动完成：备份 → 预检端口 → 改配置 → **延迟重启（不断 SSH）** → 等隧道建立 → **失败自动回滚**。

> 域名方案的细节（TTL、备案、HTTPS）见 [docs/MIGRATE.md](docs/MIGRATE.md) 方案 A。

---

## 快速开始（手动版）

不想用向导、想自己控制每一个值时：

```bash
scp -r h28k-camera-gateway root@<设备IP>:/root/
ssh root@<设备IP>
cd /root/h28k-camera-gateway
cp config.env.example config.env
vi config.env        # VPS_ADDR / VPS_TOKEN / WEB_PASS / SITE_NAME / NVR_PASS / NVR1..N
sudo bash install.sh
```

跑完会打印访问地址。**别忘了在云服务器安全组放行**：`11985`（中文台）、`11984`（go2rtc 原版）、`12222`（外网 SSH）。

---

## config.env 怎么填

```bash
VPS_ADDR=1.2.3.4                 # 云服务器公网 IP
VPS_TOKEN=xxxxxxxx               # 必须和 frps 的 auth.token 一致
VPS_CTRL_PORT=7000

WEB_USER=admin
WEB_PASS=改成强密码               # 中文台登录密码（至少 8 位）
SITE_NAME=监控中心                # 可自定义：浏览器标签 + 页面标题 + 登录框标题
# SITE_FOOT=某某公司 安防监控系统   # 登录框底部小字，留空则与 SITE_NAME 相同
NVR_USER=admin
NVR_PASS=摄像头密码

# 端口（同一台 VPS 跑多套时一定要错开）
PORT_GO2RTC=11984
PORT_CAMWEB=11985
PORT_SSH=12222
PORT_WEB_BASE=18443              # NVR 网页映射起始端口，依次 +1
PORT_SDK_BASE=18000              # NVR 手机 App(SDK) 起始端口
PORT_RTSP_BASE=18554             # NVR RTSP 起始端口
KEEP_NVR_TUNNELS=1               # 1=同时保留 NVR 的 web/sdk/rtsp 映射

# 每台 NVR 一行：IP|显示名|通道列表|通道名(一一对应，可留空)
NVR1="192.168.1.64|四号机 车间|1,2,3,4,5,6,7,8|二楼针车,四楼车间,..."
NVR2="192.168.1.35|二号机|1,2,3,4,5,7,8,10|一路,二路,三路,四路,五路,七路,八路,流水线"
NVR3="192.168.1.254|三号机|1,2,3,4|通道1,通道2,通道3,通道4"
```

**通道号规则**（最常踩的坑）：

| NVR 里的通道 | RTSP 路径（子码流） | 主码流 |
|---|---|---|
| 1 | `Streaming/Channels/102` | `101` |
| 2 | `202` | `201` |
| 10 | `1002` | `1001` |
| 21 | `2102` | `2101` |

即 **通道号 × 100 + 码流号**。`install.sh` 会自动拼，你只填通道号。

---

## 部署后

| 用途 | 地址 | 凭据 |
|---|---|---|
| 中文监控台 | `http://<VPS_IP>:11985` | `WEB_USER` / `WEB_PASS` |
| go2rtc 原版 | `http://<VPS_IP>:11984` | 同上（Basic） |
| 内网调试 | `http://<设备IP>:8080` | 同上 |
| 外网 SSH | `ssh root@<VPS_IP> -p 12222` | 设备 root 密码 |

---

## 注意事项（务必读）

1. **国内装依赖会失败**：`deb.debian.org` 常 404/超时，`install.sh` 会自动换清华源并停用 `armbian.sources`。若仍失败，手动改 `/etc/apt/sources.list.d/*.sources`。
2. **GitHub 直连下不动**：脚本走 `ghfast.top` 代理；还不行就在电脑上下好 `go2rtc_linux_arm64`、`frpc_linux_arm64` 放进 `bin/`。
3. **子码流也常是 H.265，浏览器放不出**：海康新固件出厂把子码流也设成 H.265，页面会报
   `mse: streams: codecs not matched: video:H265 => video:H264`。用 `bash tools/fix-codec.sh`
   一键改成 H.264（或到 NVR 后台 → 配置 → 视频 → 子码流 → 视频编码 改 H.264）。详见
   [docs/TROUBLESHOOTING.md#h265-通道黑屏最常见](docs/TROUBLESHOOTING.md)。
4. **带宽**：一路子码流约 0.5–1 Mbps，云服务器 5 Mbps 只能同时看 2–3 路。
5. **远程改 frp 会断自己的 SSH**：`systemctl restart frpc` 会重启承载 SSH 的隧道。请用延迟重启：
   `nohup sh -c 'sleep 3; systemctl restart frpc' >/dev/null 2>&1 &`
6. **刷新即登出**是有意设计（严格会话），不是 bug。
7. **`cam-authd` 重启 = 全员掉线**（会话在内存里），改密码后需要重新登录。
8. **同一台 VPS 跑多套**：`PORT_*` 和 frp 的 `name` 都必须唯一（用 `PROXY_PREFIX` 区分），
   否则 frps 会报 `proxy [xxx] already exists` 并踢掉同名隧道。

更多见 [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)。

---

## 日常运维

```bash
bash /root/set-password.sh '新密码'          # 同步改 go2rtc / cam-authd / nginx 三处
tail -f /var/log/cam-auth.log                # 看谁在登录
tail -f /var/log/nginx/cam-access.log        # 带真实 IP 的访问日志
systemctl status go2rtc nginx cam-auth frpc  # 四个服务都该是 active
```

加/删摄像头：改 `config.env` 的 `NVR*` → `bash install.sh`（幂等）。

改站点名称（浏览器标签 + 页面大标题 + 登录框，三处一起变，**不用重装**）：

```bash
sudo bash tools/set-site-name.sh "长沙分公司监控"
sudo bash tools/set-site-name.sh "长沙分公司监控" "某某公司 安防监控系统"   # 第二个参数是登录框底部小字
sudo bash tools/set-site-name.sh                                          # 不带参数=看当前名称
```

### 多个现场共用一台云服务器

端口和 frp 隧道名都要区分，完整对照见 [docs/TWO-SITES.md](docs/TWO-SITES.md)。要点：

| 差异 | 现场 A | 现场 B |
|---|---|---|
| 公网端口 | 11984 / 11985 / 12222 | 12984 / 12985 / 12922 |
| `PROXY_PREFIX` | 空 | `"ff-"` |

不加 `PROXY_PREFIX` 的话，frps 会报 `proxy [camweb] already exists`，后装的现场公网全部不通。

---

## 目录结构

```
h28k-camera-gateway/
├── deploy.sh               # ★ 傻瓜式部署向导（问几个问题就装完）
├── server-setup.sh         # ★ 云服务器一键装 frps
├── switch-server.sh        # ★ 换服务器（自动回滚）
├── install.sh              # 底层安装脚本（幂等，被 deploy.sh 调用）
├── config.env.example      # 配置模板
├── authd/authd.py          # 会话认证 + 登录审计（Python3 标准库）
├── web/index.html          # 中文监控台
├── tools/
│   ├── set-password.sh     # 一键改密码（三处同步）
│   ├── enable-audit.sh     # 启用真实 IP + 审计日志（PROXY Protocol）
│   └── fix-nvr-passwords.sh# 多台 NVR 不同密码时按 IP 校正
├── bin/                    # 放 go2rtc / frpc / frps 二进制（不入库）
└── docs/
    ├── DEPLOY.md           # 详细部署流程（含 frps 搭建）
    ├── MIGRATE.md          # 换服务器 / 迁移指南
    └── TROUBLESHOOTING.md  # 排错手册
```

---

## 许可

MIT。go2rtc（MIT）与 frp（Apache-2.0）的版权归各自作者。
