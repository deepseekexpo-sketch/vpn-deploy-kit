# vpn-deploy-kit · 一键全自动 VPN 部署

在全新 Ubuntu VPS 上**一键部署双协议 VPN：Reality(VLESS/tcp 443) + Hysteria2(udp 8443)**，并自动生成 Clash Verge 客户端配置。
**单仓库自包含**——克隆下来，设 3 个环境变量，跑一条命令即可，无需再拉任何其他仓库。

> 本仓库为**脱敏版**：不含任何真实服务器凭据，可安全公开。凭据通过环境变量传入。

## 特性
- ✅ **一键全自动**：上传套件 → 部署 → 回收客户端配置，一条 `python deploy.py` 搞定
- ✅ **兼容 3x-ui v2.9.4**：已内置面板认证模型迁移（secret）与全部踩坑修复
- ✅ **双协议高可用**：Reality（TCP 抗封锁）+ Hysteria2（UDP 低延迟），任一可用即可连
- ✅ 客户端分流规则完善：chatgpt/openai 走代理，国内站直连
- ✅ 适配 **Windows Git Bash**（paramiko 驱动，无 sleep/chmod/which 也可用）

## 快速开始（同事视角，30 秒上手）

```bash
# 0. 克隆并装依赖
git clone https://github.com/deepseekexpo-sketch/vpn-deploy-kit.git
cd vpn-deploy-kit
pip install paramiko

# 1. 设置你的 VPS 凭据（环境变量，命令结束后即失效，不会入库）
export VPN_HOST=<你的VPS公网IP>
export VPN_PORT=<SSH端口>        # 可选，默认 22
export VPN_USER=root
export VPN_PASS=<root密码>

# 2. 一键全自动部署
python deploy.py
```

部署完成后：
- VPS 上自动监听 **443/tcp（Reality）+ 8443/udp（Hysteria2）**
- 客户端配置自动拉到 **`deliverables/client-<IP>.yaml`** 和 `deliverables/secrets-<IP>.md`

### Clash Verge 导入
1. 删旧配置 → 导入 `deliverables/client-<IP>.yaml` → 激活
2. **必须关闭 Verge「设置 → DNS 设置」开关**，否则会覆盖配置里的 DNS（致 ChatGPT 回源、国内站 5s 慢）

*注：`python deploy.py` 结束后环境变量仍在当前 shell，若担心可 `unset VPN_PASS`。*

## 仓库结构

```
vpn-deploy-kit/
├── deploy.py               # ★ 一键全自动入口（跑这个就行）
├── kit/                    # vpn-deploy-kit 完整套件（自包含，带 v2.9.4 修复）
│   ├── bootstrap.sh        # 编排器
│   ├── config.example.env  # 配置模板
│   ├── scripts/            # 00-precheck … 08-gen-client-yaml + lib.sh
│   ├── templates/          # Reality/Hysteria2/客户端模板
│   └── tests/              # 模板渲染测试
├── scripts/                # （调试用）分步部署辅助脚本，环境变量版
├── skills/                 # WorkBuddy AI 部署技能（脱敏）
│   └── vpn-deploy-kit/     # SKILL.md + 5 个环境变量版辅助脚本模板
├── templates/
│   └── client.example.yaml # 客户端配置格式参考（占位示例）
└── deliverables/           # 部署后自动生成（gitignore，不入库）
```

## skills/ · AI 部署技能（可选）

`skills/vpn-deploy-kit/` 是给 **WorkBuddy / AI 助手** 用的部署技能（脱敏），不是部署代码本身：

- `SKILL.md` —— 让 AI 学会整套部署流程（触发场景 / 环境约束 / 部署步骤 / 10 条踩坑速查表）
- `scripts/` —— 5 个**环境变量版**辅助脚本模板（`ssh_init` / `upload_kit` / `deploy_remote` / `exec_deploy` / `manual_reality`），凭据从 `VPN_HOST/VPN_PORT/VPN_USER/VPN_PASS` 读取，无硬编码

**用法**（3 选 1）：
1. 让 AI 助手直接读取 `skills/vpn-deploy-kit/SKILL.md`，指导它按技能流程部署；
2. 在 WorkBuddy 中把 `skills/vpn-deploy-kit/` 装为用户级技能（`~/.workbuddy/skills/`）；
3. 手动阅读 `scripts/` 模板，照做即可。

> 与 `kit/` 的区别：`kit/` 是**实际一键部署的所有脚本**（`deploy.py` 直接上传它）；`skills/` 是**教 AI 上手**的技能说明 + 参考脚本，二者互补、内容都已脱敏。

## 部署原理

`deploy.py` 自动完成 5 步：
1. 用环境变量生成 `kit/config.env`（写入你的 VPS IP / SSH 端口 / 公钥）
2. SFTP 上传整个 `kit/` 到 VPS `/opt/vpn-deploy-kit/`
3. 远程去除 CRLF + `bash -n` 语法检查
4. 跑 `bootstrap.sh`（Reality 443 + Hysteria2 8443），幂等可重跑
5. 回收客户端配置到 `deliverables/`

## 常见问题

| 问题 | 处理 |
|------|------|
| `连接失败: …` | 检查 VPN_HOST/PORT/PASS；SSH 被 fail2ban 封则去商家 VNC 解封本机 IP |
| 部署失败卡在 `03-install-3xui` | 已内置 v2.9.4 修复；必要时重设 `VPN_*` 后重跑 `python deploy.py`（幂等） |
| `jq: command not found` | kit 部署前会自动 `apt-get install -y jq`（bootstrap 前置） |
| 导入后 ChatGPT 打不开 | 未关闭 Verge「DNS 设置」开关 → 关掉重启 |

## 安全说明
- 仓库**不含任何真实密码/IP/密钥**，凭据全走环境变量
- `kit/config.env`、`deliverables/` 等含凭据文件已被 `.gitignore` 排除
- 面板（3x-ui 2053）默认仅本机/SSH 隧道可访问（iptables + ufw deny）
- 完整踩坑记录见 `kit/DESIGN.md`（含 3x-ui v2.9.4 兼容说明）

## License
MIT
