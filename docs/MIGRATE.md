# 换服务器 / 迁移指南

三种换法，按你的情况选一种。**都只需要在云服务器和 设备 上各跑一条命令**，摄像头和 NVR 完全不用动。

---

## 为什么要先看这个

整个系统只有**一个"出口"**是跟服务器绑定的：

```
海康 NVR ──RTSP──▶ 设备（go2rtc + 中文台） ──frpc──▶ 云服务器（frps）──▶ 浏览器
                      ↑ 配置都在这里，不用动          ↑ 只有这里会变
```

设备 上唯一跟服务器相关的，是 `/etc/frp/frpc.toml` 里的这一行：

```toml
serverAddr = "1.2.3.4"
```

换服务器 = 改这一行 + 重启 frpc。

---

## 方案 A：用域名（**最推荐**，以后换服务器零改动）

用域名之后，`serverAddr` 永远是 `frp.你的域名.com`，换服务器只是**改一条 DNS 记录**——
设备不用登、不用改、不用重启，手机 App 里存的地址也不用改。

### A1. 准备一个域名（三种来源，任选）

| 来源 | 说明 | 成本 |
|---|---|---|
| 已有域名 | 直接在 DNS 服务商加记录 | 0 |
| 新买 | 阿里云/腾讯云/Namesilo 等，`.top`/`.xyz` 一年十几块 | ~15 元/年 |
| 免费二级域名 | DuckDNS（`xxx.duckdns.org`）等 | 0 |

> **建议把 DNS 解析放在国内服务商**（阿里云 DNS / 腾讯 DNSPod）。国外 NS 在国内解析慢，
> 偶尔被污染，会影响 frpc 启动时解析域名的速度。

### A2. 加一条 A 记录

| 类型 | 主机记录 | 记录值 | TTL |
|---|---|---|---|
| A | `frp` | 当前云服务器 IP（如 `1.2.3.4`） | **300 秒** |

得到 `frp.example.com`。

- **TTL 一定要改短**：默认常是 600/3600 秒，换服务器那天会等到崩溃。300 秒足够。
- 服务器 IP 会变（按量实例）的话，可以用 DDNS 脚本随服务器启动更新 A 记录。

验证解析（在设备或自己电脑上）：

```bash
getent hosts frp.example.com        # Linux
nslookup frp.example.com            # Windows
```

### A3. 把设备从 IP 切到域名（一次性，一条命令）

```bash
# 设备 上
bash switch-server.sh frp.example.com
```

脚本会先打印「域名解析 → x.x.x.x」，确认解析对了再动手；之后备份、改 `serverAddr`、
延迟重启、等 `start proxy success`，失败自动回滚。

也可以一开始就用域名装：`deploy.sh` 向导里「服务器地址」直接填域名。

### A4. 以后换服务器（三步，设备基本不用管）

1. 新服务器执行 `bash server-setup.sh`（token 沿用旧的，或两边一起改）
2. DNS 里把 `frp` 的 A 记录改成新 IP，等 TTL（≤5 分钟）
3. 设备上让 frpc 重新解析域名：

   ```bash
   bash switch-server.sh --restart-only
   ```

   这个模式**不改配置**，只做「确认解析 → 延迟重启 → 等隧道 → 失败回滚」。

> 为什么还要重启一次？frpc 只在启动时解析域名，长期运行不会跟着 DNS 变。
> 想彻底免手动，可以在设备上加定时任务：`0 4 * * * systemctl restart frpc`
> （凌晨低峰自动重连，代价是断几秒）。

### A5. 用域名的三个额外好处

1. **以后能上 HTTPS**：Let's Encrypt 不给纯 IP 签证书，有域名才能给 `11984/11985` 配证书
2. **手机 App 里存的地址不用改**：换服务器后 App 照旧能用
3. **不用记 IP**：`frp.example.com:11985` 比一串数字好记，也不怕 IP 变更

### A6. 两个注意点

- **备案**：服务器在中国大陆时，用域名对外提供 HTTP 服务按规定需要 ICP 备案。
  用高端口（11985）通常不会被拦，但云厂商可能弹提醒；要长期稳定就备案，或把 frps 放境外。
- **别把真实域名写进公开仓库**：本项目文档一律用 `frp.example.com` 占位，
  你的真实域名只写在私下的《账号密码清单》里。

---
## 方案 B：新服务器一键装 frps（IP 直连）

### 第 1 步：新服务器上（约 2 分钟）

```bash
# 把整个项目目录 scp 上去，或者只拷 server-setup.sh
scp -r camera-gateway root@新服务器IP:/root/
ssh root@新服务器IP
cd /root/camera-gateway
bash server-setup.sh
```

脚本会：
- 装 frps（优先用 `bin/` 里的，没有则走 `ghfast.top` 下载）
- **自动生成一个随机 token** 并写入 `/etc/frp/frps.toml`
- 注册 systemd、开机自启、启动
- 检测 ufw/firewalld 并自动放行
- 打印 token 和需要到云控制台放行的端口

**记下打印出来的 TOKEN**，下一步要用。

### 第 2 步：云控制台放行端口

| 协议 | 端口 | 不放行的后果 |
|---|---|---|
| TCP | 7000 | 隧道连不上，全站黑屏 |
| TCP | 11985 | 中文监控台打不开 |
| TCP | 11984 | go2rtc 原版打不开 |
| TCP | 12222 | 外网 SSH 失联（只能走内网或 VNC） |

### 第 3 步：设备 上切过去（一条命令）

```bash
bash switch-server.sh 新服务器IP --token 刚才的TOKEN
```

脚本会：
1. 备份 `frpc.toml`
2. **预检**新服务器 7000 端口通不通（不通会警告，可中止）
3. 改 `serverAddr`（和 token）
4. **延迟 3 秒**重启 frpc —— 避免切断你正在用的这条 SSH
5. 等待最多 25 秒，检查日志里有没有 `start proxy success`
6. **失败自动回滚**到旧服务器

> SSH 会闪断几秒，重连后就能看到结果。

### 第 4 步：验证

```bash
# 新服务器
systemctl status frps --no-pager | head -3

# 浏览器
http://新IP:11985     → 登录 → 有画面
```

### 第 5 步：收尾

- 旧服务器**保留 1–2 天**再释放（出问题能秒回滚）
- 更新你保存的《账号密码清单》里的地址

---

## 方案 C：回滚（切错了/新服务器不行）

```bash
bash switch-server.sh 旧服务器IP --token 旧TOKEN
```

`switch-server.sh` 失败时会自动回滚，并打印回滚命令。手动回滚也行：

```bash
cp -a /etc/frp/frpc.toml.bak.<时间戳> /etc/frp/frpc.toml
nohup sh -c 'sleep 3; systemctl restart frpc' >/dev/null 2>&1 &
```

---

## 常见问题

### 切完监控打不开

按顺序查：

```bash
# 1) 设备 上 frpc 活着吗
systemctl is-active frpc
journalctl -u frpc -n 30 | grep -E "start proxy|error"

# 2) 新服务器 frps 活着吗（SSH 上去）
systemctl is-active frps
ss -lntp | grep 7000

# 3) token 两边一致吗
grep token /etc/frp/frpc.toml      # 设备
grep token /etc/frp/frps.toml      # 服务器 —— 必须完全相同
```

日志里出现 `token mismatch` 就是 token 不一致。

### SSH 切完就连不上了

十有八九是**新服务器没放行 12222**。补救方式：

1. 到云控制台用「远程连接 / VNC」登录新服务器
2. 或者让 设备 恢复旧配置（需要内网访问：HDMI 或直连网线到 `192.168.1.x`）

**预防**：切换前先确认 12222 已放行，`switch-server.sh` 会先预检 7000 但管不了 12222。

### 新服务器带宽更小，画面卡

轻量服务器常见 5 Mbps，只能同时看 2–3 路子码流。换之前先算清楚：
一路子码流 ≈ 0.5–1 Mbps。

### 域名换了不生效

```bash
# 1) 设备上确认解析到新 IP 了
getent hosts frp.example.com

# 2) 解析对了但隧道还连着旧服务器 → 重启 frpc 重新解析
bash switch-server.sh --restart-only
```

解析结果还是旧 IP，就是 DNS 缓存没到期（等 TTL），或本地 `resolv.conf` 缓存。

### 想两台服务器同时在线（双活）

frpc 只支持一个 `serverAddr`。要双活得跑两个 frpc 实例（不同配置、不同 systemd 服务名），
一般没必要——真要高可用，用域名 + 快速切换就够了。

---

## 一句话版本

```bash
# 新服务器
bash server-setup.sh                                   # 记下 TOKEN

# 设备
bash switch-server.sh 新IP --token TOKEN                # 自动切换+自检+失败回滚

# 有域名的话：只改 DNS 的 A 记录，然后
bash switch-server.sh --restart-only     # 设备上重新解析域名（不改配置）
```
