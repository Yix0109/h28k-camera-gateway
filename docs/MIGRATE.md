# 换服务器 / 迁移指南

三种换法，按你的情况选一种。**都只需要在云服务器和 H28K 上各跑一条命令**，摄像头和 NVR 完全不用动。

---

## 为什么要先看这个

整个系统只有**一个"出口"**是跟服务器绑定的：

```
海康 NVR ──RTSP──▶ H28K（go2rtc + 中文台） ──frpc──▶ 云服务器（frps）──▶ 浏览器
                      ↑ 配置都在这里，不用动          ↑ 只有这里会变
```

H28K 上唯一跟服务器相关的，是 `/etc/frp/frpc.toml` 里的这一行：

```toml
serverAddr = "47.94.251.58"
```

换服务器 = 改这一行 + 重启 frpc。

---

## 方案 A：用域名（**最推荐**，以后换服务器零改动）

### 一次性设置

1. 买个域名（任意注册商），在 DNS 里加一条 A 记录：

   | 类型 | 主机记录 | 值 |
   |---|---|---|
   | A | `frp` | 当前云服务器 IP |

   得到 `frp.example.com`

2. H28K 上改成用域名：

   ```bash
   bash switch-server.sh frp.example.com
   ```

之后 `config.env` 里 `VPS_ADDR` 也可以填域名，`install.sh` 直接支持。

### 以后换服务器

**只改 DNS 的 A 记录**指向新 IP，等 TTL 生效（通常 10 分钟），frpc 会自己重连。
H28K 上**什么都不用做**，浏览器地址还是一样的 `http://frp.example.com:11985`。

> TTL 建议设 300 秒或更短，切换时更快生效。

---

## 方案 B：新服务器一键装 frps（IP 直连）

### 第 1 步：新服务器上（约 2 分钟）

```bash
# 把整个项目目录 scp 上去，或者只拷 server-setup.sh
scp -r h28k-camera-gateway root@新服务器IP:/root/
ssh root@新服务器IP
cd /root/h28k-camera-gateway
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

### 第 3 步：H28K 上切过去（一条命令）

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
# 1) H28K 上 frpc 活着吗
systemctl is-active frpc
journalctl -u frpc -n 30 | grep -E "start proxy|error"

# 2) 新服务器 frps 活着吗（SSH 上去）
systemctl is-active frps
ss -lntp | grep 7000

# 3) token 两边一致吗
grep token /etc/frp/frpc.toml      # H28K
grep token /etc/frp/frps.toml      # 服务器 —— 必须完全相同
```

日志里出现 `token mismatch` 就是 token 不一致。

### SSH 切完就连不上了

十有八九是**新服务器没放行 12222**。补救方式：

1. 到云控制台用「远程连接 / VNC」登录新服务器
2. 或者让 H28K 恢复旧配置（需要内网访问：HDMI 或直连网线到 `192.168.86.x`）

**预防**：切换前先确认 12222 已放行，`switch-server.sh` 会先预检 7000 但管不了 12222。

### 新服务器带宽更小，画面卡

轻量服务器常见 5 Mbps，只能同时看 2–3 路子码流。换之前先算清楚：
一路子码流 ≈ 0.5–1 Mbps。

### 域名换了不生效

```bash
# H28K 上确认解析到新 IP 了
getent hosts frp.example.com
```

没变就是 DNS 缓存，等 TTL 或 `systemctl restart frpc` 强制重连。

### 想两台服务器同时在线（双活）

frpc 只支持一个 `serverAddr`。要双活得跑两个 frpc 实例（不同配置、不同 systemd 服务名），
一般没必要——真要高可用，用域名 + 快速切换就够了。

---

## 一句话版本

```bash
# 新服务器
bash server-setup.sh                                   # 记下 TOKEN

# H28K
bash switch-server.sh 新IP --token TOKEN                # 自动切换+自检+失败回滚

# 有域名的话，这两步都可以省略，只改 DNS 就行
```
