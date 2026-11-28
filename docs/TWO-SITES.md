# 多现场部署对照：总厂 / 分公司

> 本文用**占位符**写成，可直接公开。真实取值请填在你自己的 `config.env` 里，不要提交进仓库。
>
> 占位符约定：`1.2.3.4` = 云服务器公网 IP，`192.168.1.x` = 厂区内网，`<NVR_PASS>` = NVR 密码，
> `<FRP_TOKEN>` = frp 认证 token，`<WEB_PASS>` = 网页登录密码。

### 适用性（不绑定具体硬件）

| 项 | 说明 |
|---|---|
| 部署设备 | **不挑架构、不挑型号**：arm64 / amd64 都行，任何能跑 Debian 12 或 Ubuntu 22.04+ 的机器（小板子、迷你主机、旧笔记本、虚拟机均可），内存 ≥1 GB。下文统一称「网关设备」 |
| 录像机 | **不挑品牌型号**：任何支持标准 RTSP 的 NVR / IPC 都能接。默认按海康的路径规则生成 RTSP 地址，其它品牌改生成的 yaml 即可 |
| 规模 | **默认多台录像机、每台多路通道**：一台设备可接 1~N 台 NVR，每台可挑任意通道上墙（最多 9 路同屏） |
| 现场数 | 同一台云服务器可同时跑多个现场，靠**端口段**和**隧道名前缀**隔开（见第五节） |

---

## 一、整体结构

```
录像机 NVR ──RTSP──▶ 网关设备（厂区） ──frp隧道──▶ 云服务器 ──HTTP──▶ 浏览器
```

厂区**不需要公网 IP、不需要对外开端口**：网关设备主动往云服务器打洞，云服务器只转发字节流，不存视频。

```
┌──────────────┐  RTSP    ┌─────────────────────────────┐  frp    ┌──────────┐   HTTP   ┌────────┐
│  录像机 NVR  │ ───────▶ │  网关设备（厂区，内网）         │ ──────▶ │ 云服务器 │ ───────▶ │ 浏览器 │
│ 192.168.1.x  │  554     │                             │  隧道    │ frps     │  11985   │        │
└──────────────┘          │  go2rtc   :1984  拉流/转协议 │          │ :7000    │          └────────┘
                          │  nginx    :8080  中文页面   │          │ :11985   │
                          │           :8181  真实 IP    │          │ :11984   │
                          │  cam-authd:9000  登录会话   │          │ :12222   │
                          │  frpc            打洞      │          └──────────┘
                          └─────────────────────────────┘
```

| 组件 | 位置 | 作用 | 为什么需要 |
|---|---|---|---|
| go2rtc | 网关设备 `:1984` | RTSP → MSE / WebRTC | 浏览器不会播 RTSP；只做协议转换（relay），**不转码**，1GB 内存也够用 |
| nginx | 网关设备 `:8080` / `:8181` | 中文监控页 + 反代 go2rtc + 注入认证头 | go2rtc 界面编译在二进制里改不了，只能套一层自己的页面 |
| cam-authd | 网关设备 `:9000` | 表单登录、会话 Cookie、登录审计、失败锁定 | go2rtc 自带 Basic 认证太弱（弹窗、无法登出、不能审计） |
| frpc | 网关设备 | 主动连云服务器，把本机端口映射到公网 | 厂区没有公网 IP，只能由内向外连 |
| frps | 云服务器 `:7000` | 接受隧道，把 `11985` 等端口暴露公网 | 公网的落地点 |
| fail2ban | 网关设备 | SSH 连错 5 次封 60 秒 | 外网 SSH 必被扫 |

### 名词速查

| 名词 | 含义 |
|---|---|
| 主码流 / 子码流 | 摄像头同时出两路：主码流高清（如 2560×1440，2~4 Mbps）、子码流标清（640p，0.5~1 Mbps）。**网页用子码流** |
| 通道号规则 | 各家不同，本项目默认按海康的规则生成：`Streaming/Channels/<通道号×100+码流号>`，1 号子码流 `102`、2 号 `202`、10 号 `1002`、16 号 `1602`。别的品牌路径不同，装完改 `/opt/go2rtc/go2rtc.yaml` 里对应那几行即可。**所有通道写成同一个号就会「所有画面都一样」** |
| H.264 / H.265 | 视频编码。Chrome / Edge 的 MSE 与 WebRTC **都不解码 H.265**，子码流也必须是 H.264 |
| PROXY Protocol v2 | frp 选项，把访客真实 IP 传到设备端。不开的话设备看到的全是 `127.0.0.1` |
| 会话级 Cookie | 不带 `Max-Age` / `Expires`，浏览器关闭即失效；配合「刷新即登出」实现严格会话 |
| 隧道名（proxy name） | frp 每条映射的名，**同一台 frps 上必须全局唯一** |

---

## 二、云服务器（装一次，所有现场共用）

| 项 | 值 |
|---|---|
| 公网 IP | `1.2.3.4` |
| frps 版本 | 0.66.0，`/opt/frp/frps` |
| 配置 | `/etc/frp/frps.toml` |
| token | `<FRP_TOKEN>`  **所有现场必须一致** |
| 控制端口 | `7000` |
| 面板 | `http://1.2.3.4:7500/static/` |
| 端口白名单 | `allowPorts = 10000~30000` |

```bash
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/Yix0109/camera-gateway/main/server-setup.sh -o /tmp/s.sh
sudo bash /tmp/s.sh
```

### 云安全组（一条规则一个端口）

| 端口 | 用途 | 归属 |
|---|---|---|
| `7000` | frp 控制通道 | 所有现场 |
| `11985` | 总厂中文监控台 | 总厂 |
| `11984` | 总厂 go2rtc 原版 | 总厂 |
| `12222` | 总厂 SSH | 总厂 |
| `18443~18445` | 总厂 NVR Web 后台 | 总厂（`KEEP_NVR_TUNNELS=1` 时） |
| `12985` | 分公司中文监控台 | 分公司 |
| `12984` | 分公司 go2rtc 原版 | 分公司 |
| `12922` | 分公司 SSH | 分公司 |

> 阿里云防火墙的端口输入框**只接受单个端口**：写 `11984-11985` 或 `11984,11985` 都会报
> 「端口数字为 1~65535 之间」，必须一条规则一个端口。

---

## 三、总厂（多 NVR，全量隧道）

| 项 | 示例值 |
|---|---|
| 网关设备 | `192.168.1.10`（root / `<设备root密码>`） |
| NVR | `192.168.1.64`（1–8）、`192.168.1.35`（1,2,3,4,5,7,8,10,12,13）、`192.168.1.254`（1–16,18–21） |
| NVR 账号 | `admin` / `<NVR_PASS>` |
| 摄像头 | 38 路 |
| 流命名 | `n<IP末段>_c<通道>`，如 `n64_c1` |
| 隧道名前缀 | 空（占默认名） |
| 隧道数 | 12（3 主服务 + 3 台 NVR × 3） |

### config.env

```bash
VPS_ADDR=1.2.3.4
VPS_TOKEN=<FRP_TOKEN>
VPS_CTRL_PORT=7000

WEB_USER=admin
WEB_PASS=<WEB_PASS>

NVR_USER=admin
NVR_PASS=<NVR_PASS>

PORT_GO2RTC=11984
PORT_CAMWEB=11985
PORT_SSH=12222
PORT_WEB_BASE=18443
PORT_SDK_BASE=18000
PORT_RTSP_BASE=18554

KEEP_NVR_TUNNELS=1
PROXY_PROTOCOL=1

NVR1="192.168.1.64|四号机|1,2,3,4,5,6,7,8|二楼针车(后段),四楼成品(后段),五楼裁剪(后段),二楼针车(前段),三楼仓库,三楼质检,四楼成品(前段),五楼裁剪(前段)"
NVR2="192.168.1.35|二号机|1,2,3,4,5,7,8,10,12,13|"
NVR3="192.168.1.254|三号机|1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,18,19,20,21|"
```

### 变量含义

| 变量 | 含义 | 填错会怎样 |
|---|---|---|
| `VPS_ADDR` | 云服务器 IP | 隧道连不上，公网全断 |
| `VPS_TOKEN` | frp 认证 token，必须与 frps 一致 | 日志报 `token in login doesn't match token from configuration` |
| `VPS_CTRL_PORT` | frps 控制端口 | 连不上 |
| `WEB_USER` / `WEB_PASS` | 网页登录账号密码（≥8 位） | 装不下去 |
| `NVR_USER` / `NVR_PASS` | NVR 账号密码 | 页面黑屏、go2rtc 报 401 |
| `PORT_GO2RTC` | 公网访问 go2rtc 原版 | 端口冲突 |
| `PORT_CAMWEB` | 公网访问中文监控台 | **这个才是给别人用的** |
| `PORT_SSH` | 公网 SSH 到网关设备 | 远程维护进不去 |
| `PORT_WEB_BASE` | NVR Web 起始端口（第 1 台 18443、第 2 台 18444…） | — |
| `PORT_SDK_BASE` | NVR SDK 起始端口（厂商手机 App 用） | — |
| `PORT_RTSP_BASE` | NVR RTSP 起始端口（VLC / NVR 互联） | — |
| `KEEP_NVR_TUNNELS` | `1`=同时映射 NVR 后台（每台多 3 条隧道）；`0`=只开监控画面 | 隧道变多，端口与安全组要跟着加 |
| `PROXY_PROTOCOL` | `1`=取真实 IP（frps ≥ 0.53） | 审计日志全是 `127.0.0.1` |
| `PROXY_PREFIX` | 隧道名前缀 | 多现场共用一台 frps 时必须唯一，否则 `proxy already exists` |
| `NVRn` | `IP\|显示名\|通道列表\|通道名列表` | 通道写错 = 黑屏或画面不对 |

### install.sh 内部做了什么

| 步骤 | 做什么 | 含义 |
|---|---|---|
| 0 | 检查 root、架构 | — |
| 1 | 换国内 apt 源，装 `nginx-light` `python3` `fail2ban` | `deb.debian.org` 在国内常 404 |
| 2 | 下载 go2rtc / frpc 静态二进制（走 `ghfast.top`），**校验 SHA256** | GitHub 直连**截断**下载，装上去的 frpc 会段错误 |
| 3 | 生成 `/opt/go2rtc/go2rtc.yaml` + `cameras.json` | 按 `通道×100+02` 规则生成 RTSP 地址 |
| 4 | 部署中文页面到 `/opt/cam/www/` | 左侧列表 + 右侧宫格，最多 9 路 |
| 5 | 装 `cam-authd` + `cam-auth.service` | 登录、会话、审计 `/var/log/cam-auth.log` |
| 6 | 写 nginx 配置：`:8080` 内网 + `:8181` PROXY Protocol | 8181 专供 frp 进来，才能拿真实 IP |
| 7 | 生成 `/etc/frp/frpc.toml` + `frpc.service` | 打洞 |
| 8 | `systemctl enable --now` 四个服务 | 开机自启 |
| 9 | fail2ban：SSH 5 次错封 60 秒 | 防爆破 |
| 10 | 自检：服务状态、内网 8080、公网端口 | **看到「公网 = 200」才算成功** |

### 验收

```bash
systemctl status go2rtc nginx cam-auth frpc
journalctl -u frpc -n 30 --no-pager | grep "start proxy success"
bash tools/fix-codec.sh      # 把 H.265 改成 H.264，必做一次
```

---

## 四、分公司（同服务器，端口与隧道名都要区分）

| 项 | 示例值 | 与总厂差异 |
|---|---|---|
| 网关设备 | `192.168.1.20` | 不同网段 |
| NVR | `192.168.1.64` | — |
| NVR 账号 | `admin` / `<分公司NVR_PASS>` | 各厂独立 |
| 摄像头 | 8 路 | — |
| 隧道名前缀 | `PROXY_PREFIX="ff-"` | ⚠️ **必须加** |
| 隧道数 | 3（`KEEP_NVR_TUNNELS=0`） | 少 9 条 |

```bash
VPS_ADDR=1.2.3.4
VPS_TOKEN=<FRP_TOKEN>
VPS_CTRL_PORT=7000

WEB_USER=admin
WEB_PASS=<WEB_PASS>

NVR_USER=admin
NVR_PASS=<分公司NVR_PASS>

PORT_GO2RTC=12984
PORT_CAMWEB=12985
PORT_SSH=12922

KEEP_NVR_TUNNELS=0
PROXY_PROTOCOL=1

PROXY_PREFIX="ff-"

NVR1="192.168.1.64|仓库|1,2,3,4,5,6,7,8|"
```

### 三处必须不同，少一处都不行

| 差异 | 总厂 | 分公司 | 不改的后果 |
|---|---|---|---|
| ① 公网端口 | 11984/11985/12222 | 12984/12985/12922 | 端口被占，frps 报 `port already used` |
| ② `PROXY_PREFIX` | 空 | `ff-` | frps 报 `proxy [camweb] already exists`，**分公司所有隧道注册失败，公网 000** |
| ③ `KEEP_NVR_TUNNELS` | `1` | `0`（可选） | 多 9 条隧道，安全组要跟着开 |

> ② 很容易被误判。安装脚本自检公网为 `000` 时，曾把原因写成「frps 不支持 PROXY Protocol」，
> 实际上服务器日志里是：
>
> ```
> new proxy [camweb] type [tcp] error: proxy [camweb] already exists   ← 每 30 秒刷一次
> ```
>
> frp 的隧道名是**全局唯一**的，不按设备隔离；`PROXY_PREFIX` 就是为此加的（commit `9a7f002`）。

---

## 五、两台对照总表

| 项目 | 总厂 | 分公司 |
|---|---|---|
| 网关设备内网 IP | `192.168.1.10` | `192.168.1.20` |
| NVR | 3 台，38 通道 | 1 台，8 通道 |
| 中文监控台 | `http://1.2.3.4:11985` | `http://1.2.3.4:12985` |
| go2rtc 原版 | `:11984` | `:12984` |
| 外网 SSH | `-p 12222` | `-p 12922` |
| NVR Web 后台 | `:18443~18445` | 未开 |
| 隧道名前缀 | （空） | `ff-` |
| 隧道数 | 12 | 3 |

---

## 六、域名为什么还要带端口

`<你的域名>` 的 A 记录指向服务器后，直接访问 80 端口会拿到：

```
HTTP 403 Forbidden
Server: Beaver
<title>Non-compliance ICP Filing</title>
```

原因是**域名未备案**，云厂商按 Host 头拦截 80/443；而 TCP 隧道走高端口不经过这个拦截。
所以现阶段只能 `http://<你的域名>:11985`。

想让网址干净（不带端口、走 443），只有两条路：

1. 给域名做 **ICP 备案**（约 7~20 个工作日，要营业执照）；
2. 把服务放到**境外服务器**（不受备案约束，国内访问会慢一些）。

**记忆口诀：同一台服务器——端口分段；同一台 frps——隧道名加前缀。**

---

## 七、运维速查

```bash
systemctl status go2rtc nginx cam-auth frpc       # 服务状态
journalctl -u go2rtc -f                           # 拉流日志
journalctl -u frpc -n 30 --no-pager | grep -E 'start proxy|error'
tail -f /var/log/cam-auth.log                     # 登录审计
bash /root/set-password.sh '新密码'                # 三处同步改网页密码
bash tools/fix-codec.sh                           # 画面黑屏先查编码
```

---

## 八、再加第三个现场

照分公司这份做，只改四样：

1. 端口整体再加 1000：`13985 / 13984 / 13922`，云安全组放行；
2. `PROXY_PREFIX="gz-"`（换个前缀）；
3. `NVRn` 换成该现场的 NVR；
4. 其余不变，多台设备互不影响。

容量参考：frps 只转发字节流，几十路同时看 CPU 占用仍很低，**瓶颈在带宽**——
一路子码流约 0.5~1 Mbps，云服务器出网 5 Mbps 时同时看 5~8 路就会开始卡。
