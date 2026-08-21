---
name: vpn-deploy-kit
description: "Deploy a dual-protocol VPN (Reality + Hysteria2) on a fresh Ubuntu VPS using the vpn-deploy-kit repo, incl. 3x-ui v2.9.4 compatibility fixes."
description_zh: "用 vpn-deploy-kit 在全新 Ubuntu VPS 上部署双协议 VPN(Reality + Hysteria2), 含 3x-ui v2.9.4 兼容修复"
description_en: "Deploy a dual-protocol VPN (Reality + Hysteria2) on a fresh Ubuntu VPS using the vpn-deploy-kit repo, including 3x-ui v2.9.4 compatibility fixes and client config delivery."
version: 1.0.0
---

# VPN 部署(Reality + Hysteria2 双协议)

在用户提供的全新 Ubuntu VPS 上按 `https://github.com/chieven-sys/vpn-deploy-kit` 方案部署双协议 VPN，并交付 Clash Verge 客户端配置。

## 触发场景
- 用户给一台新 VPS + 凭据，要求"按之前方式搭建 VPN / 部署 VPN"
- 本地仓库在 `E:\workspace\vpn`（= vpn-deploy-kit）

## 环境约束(Windows Git Bash)
- 本机 `sleep/chmod/which/timeout` 不可用 → 用 **Python(paramiko)** 做 SSH/SFTP/密钥
- venv: `C:/Users/Admin/.workbuddy/binaries/python/envs/default/Scripts/python.exe` (已装 paramiko)
- 远程命令用 `exec_command`, 别用交互 shell; 无交互命令加 `timeout <n> cmd || true`
- **部署脚本在本地实际是 CRLF(0d0a)**, SFTP 忠实上传 → 必须在 VPS 端 `sed -i 's/\r$//'`(见踩坑表#1)

## 方案
- x-ray 核心 + 3x-ui 面板, Reality(VLESS/tcp 443) + Hysteria2(udp 8443)
- 脚本链: bootstrap.sh → 00-precheck → 01-harden-ssh → 02-port-probe → 03-install-3xui → 04-add-reality → 05-install-hysteria → 06-deploy-hysteria-cfg → 07-end-to-end-test → 08-gen-client-yaml
- 幂等, state 存 `output/state.json`(嵌套 `step.03.completed`), `.step-*` 标记文件

## 部署步骤

### 1. 收集凭据(向用户要)
IP / SSH端口 / 用户名 / 密码 / 系统版本 / 商家(VNC控制台备用)。常见: root + Ubuntu 22.04。

### 2. 打通 SSH 并探测
凭据用环境变量传入(脚本已模板化, 无硬编码; 防止密码泄露到技能库):
```bash
export VPN_HOST=<IP> VPN_PORT=<SSH端口> VPN_USER=root VPN_PASS=<密码>
python .tmp-deploy/ssh_init_new.py   # 连+注入部署公钥(幂等)+探测OS/arch/x-ui/jq
```
- 若 `BadAuthenticationType: allowed types: ['password']` → sshd 禁公钥, 全程走密码(脚本参数改 password)。
- 探测确认: 全新则无 x-ui; 若有则版本。
- 先 `apt-get install -y jq`(缺 jq 多处脚本崩)。

### 3. 上传 kit
运行(继续用已导出的 VPN_* 环境变量):
```bash
python .tmp-deploy/upload_kit_new.py  # SFTP 上传到 /opt/vpn-deploy-kit/ + 远程验证
```
上传后必去 CRLF:`sed -i 's/\r$//' bootstrap.sh scripts/*.sh`。

### 4. 跑部署
运行(会阻塞执行 `deploy_remote.sh`):
```bash
python .tmp-deploy/exec_deploy_new.py  # 远程: 去CRLF + bash-n + reset state + 跑 bootstrap
```
`deploy_remote.sh` 每次会: `echo '{}' > output/state.json`(清零03 failure cap) + 停残留 x-ui + 清旧 iptables DROP + 跑 `bash bootstrap.sh`。

### 5. 回收产物
```bash
python -c "...sftp.get(...)"   # 取 output/client-<IP>.yaml + secrets-<IP>.md 到本地 output/
```
核对 yaml: 双节点 us-reality/us-hy2 + DNS 分流规则完整。

### 6. 交付
- Clash Verge 导入 yaml(删旧配置→import→激活)
- **必须关 DNS 开关**(Verge 设置→DNS设置→关闭), 否则覆盖配置 DNS
- 交付 client yaml + secrets md

## ⚠️ 踩坑速查表(x-ui v2.9.4 关键; 高价值)

| # | 症状 | 根因 | 修复 |
|---|------|------|------|
| 1 | 上传后脚本全崩 `$'\r'` | 本地 .sh 是 CRLF | 远程 `sed -i 's/\r$//' bootstrap.sh scripts/*.sh`; `grep -rl $'\r'` 在 Git Bash 会误报, 用 xxd 确认 |
| 2 | bootstrap rc=1 无日志 | `> output/x.log` 时 output 目录不存在 | 先 `mkdir -p output` |
| 3 | `jq: command not found` | 系统缺 jq | `apt-get install -y jq` |
| 4 | 03 卡死 "already in use"/CLI失效 | **v2.9.4 旧 `x-ui setting` CLI 失效**(交互式) | 改 03 脚本: sqlite `UPDATE settings SET value='<openssl rand -hex 16>' WHERE key='secret'`; 面板安全靠 `iptables -I INPUT ! -i lo -p tcp --dport 2053 -j DROP` + ufw deny; port precheck 仅 FORCE=0 |
| 5 | curl 校验失败 rollback | panel 绑 `*`(双栈), `curl [::1]` rc=7 | 用 **IPv4 回环** `curl http://127.0.0.1:2053/` |
| 6 | 脚本 exit 28 秒退 | `code=$(curl...)` 超时返回非零触 `set -e` | `code="$(curl ... || true)"` |
| 7 | x-ui install 后无 db/服务 dead | install.sh 不自动建 db | 手动 `x-ui start` 后建 `/etc/x-ui/x-ui.db` (03 会再重装, 无碍) |
| 8 | Defense 3 误回滚(xray stale) | 秒级时钟竞态 | `xray_lstart_ts+60 < restart_ts` 才判 stale(改 04 脚本) |
| 9 | fail2ban 封本机 IP → SSH 零响应 | 旧机场景 | 让用户走 VNC `fail2ban-client set sshd unbanip <本机IP>`; 新机同线路一般无此问题 |
| 10 | xray 26.x x25519 输出格式变化 | `Private key:`→`PrivateKey:`/`Password (PublicKey):` | awk 解析改 `grep -iE 'private[[:space:]]*key' | sed 's/^[^:]*:[[:space:]]*//'` |

## 存档脚本清单(`archive/2026-08-21/deploy/scripts/`)
| 脚本 | 作用 |
|------|------|
| ssh_init_new.py | 密码连+注入公钥+探测(OS/arch/x-ui/jq) |
| upload_kit_new.py | SFTP 上传 kit 到 /opt/vpn-deploy-kit + 远程验证 |
| deploy_remote.sh | 远程: 去CRLF + bash-n + reset state + 停残留 + 跑 bootstrap |
| exec_deploy_new.py | 上传 deploy_remote.sh 并阻塞执行(长超时) |
| manual_reality.sh | (备用) x-ui 重启竞态兜底手动 Reality 部署 |

> 本技能目录 `scripts/` 下有这些模板副本, 复用前先把顶部凭证改新服务器。

## 参考
- 完整踩坑与归档: `archive/2026-08-21/deploy/README.md`
- 工作日志: `.workbuddy/memory/2026-08-21.md`
