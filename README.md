# H28K 摄像头网关 · go2rtc + frp + 中文监控台

把厂区/门店的 **海康 NVR**（或多台摄像头）变成**外网可看的低延迟网页监控**，跑在一台便宜的 ARM 小主机（HINLINK H28K，RK3528）上。

```
┌─────────┐   RTSP    ┌──────────────────────────┐   frp    ┌──────────┐   浏览器
│ 海康 NVR │ ────────▶ │  H28K (Debian/Armbian)   │ ───────▶ │ 云服务器  │ ───────▶ 中文监控台
│  ×N 台   │  554      │  go2rtc :1984            │  token   │  frps    │   http(s)
└─────────┘           │  nginx  :8080 (中文页面)  │          │  :7000   │
                      │  cam-authd :9000 (会话)   │          └──────────┘
                      │  frpc                    │
                      └──────────────────────────┘
```

延迟约 **0.5–1.5 秒**（MSE），不需要海康的 App、不需要公网 IP、不做转码。

---

## 特性

| 能力 | 说明 |
|---|---|
| 多 NVR 聚合 | 一个页面看多台 NVR 的全部通道，按前缀分组，最多 9 路同屏 |
| 低延迟 | 走 go2rtc 的 MSE/WebRTC，不用 HLS，延迟 1 秒级 |
| 不转码 | 只做 RTSP 转发（relay），ARM 小主机也能扛，CPU 占用个位数 |
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
| 设备 | 能跑 Debian 12 / Armbian bookworm 的 ARM64 或 x86_64（实测 H28K / RK3528A / 2G RAM） |
| 系统 | 已装好系统、能 SSH 登录 root |
| 网络 | 设备能与 NVR 互通；能访问外网（装依赖用） |
| 云服务器 | 已装 **frps**（本项目只含客户端），有公网 IP |
| 摄像头 | 海康（或兼容 ISAPI/RTSP）的 NVR / IPC，知道账号密码 |
| 账号 | root |

> frps 的安装不在本项目范围，见 [docs/DEPLOY.md#二云服务器-安装-frps](docs/DEPLOY.md)。

---

## 快速开始

```bash
# 1) 传到设备
scp -r h28k-camera-gateway root@<设备IP>:/root/

# 2) 改配置（至少 6 个值）
ssh root@<设备IP>
cd /root/h28k-camera-gateway
cp config.env.example config.env
vi config.env        # VPS_ADDR / VPS_TOKEN / WEB_PASS / NVR_PASS / NVR1..N

# 3) 部署
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
3. **主码流多为 H.265，浏览器放不出**：网页统一用 `…02` 子码流（H.264）。要清晰度就把该行改 `…01`，但带宽 ×5。
4. **带宽**：一路子码流约 0.5–1 Mbps，云服务器 5 Mbps 只能同时看 2–3 路。
5. **远程改 frp 会断自己的 SSH**：`systemctl restart frpc` 会重启承载 SSH 的隧道。请用延迟重启：
   `nohup sh -c 'sleep 3; systemctl restart frpc' >/dev/null 2>&1 &`
6. **刷新即登出**是有意设计（严格会话），不是 bug。
7. **`cam-authd` 重启 = 全员掉线**（会话在内存里），改密码后需要重新登录。
8. **同一台 VPS 跑多套**：`PORT_*` 和 frp 的 `name` 都必须唯一，否则 frps 会踢掉同名隧道。

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

---

## 目录结构

```
h28k-camera-gateway/
├── install.sh              # 一键部署（幂等）
├── config.env.example      # 配置模板
├── authd/authd.py          # 会话认证 + 登录审计（Python3 标准库）
├── web/index.html          # 中文监控台
├── tools/set-password.sh   # 一键改密码（三处同步）
├── tools/enable-audit.sh   # 启用真实 IP + 审计日志（PROXY Protocol）
├── bin/                    # 放 go2rtc / frpc 二进制（不入库）
└── docs/
    ├── DEPLOY.md           # 详细部署流程（含 frps 搭建）
    └── TROUBLESHOOTING.md  # 排错手册
```

---

## 许可

MIT。go2rtc（MIT）与 frp（Apache-2.0）的版权归各自作者。
