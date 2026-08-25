#!/usr/bin/env bash
# 03-install-3xui.sh — 装 3x-ui panel(pin v2.9.4)+ 锁 127.0.0.1
# 跟 spec v3 §2 一致。本机模型(VPS 上 root 跑)。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=/dev/null
source "${KIT_DIR}/config.env"
# shellcheck source=/dev/null
[[ -f "${RUNTIME_ENV}" ]] && source "${RUNTIME_ENV}"

init_output
state_init

# ============================================================================
# Idempotent guards (Phase A: read-only)
# ============================================================================
if step_done "03-install-3xui"; then
    step_ok "03-install-3xui"
    exit 0
fi

# failure_count cap at 2 (Ops F-5 / spec v3 §2.4)
cnt03=$(state_get "step.03.failure_count" "0")
if [[ "${cnt03}" -ge 2 ]]; then
    log_error "step 03 has failed ${cnt03} times. Run ./scripts/99-uninstall.sh --scope=full and investigate"
    exit 2
fi

# F-CN-1 + DESIGN.md §0.4: strict greenfield, no user-pre-installed 3x-ui
if command -v x-ui &>/dev/null; then
    if [[ "${BOOTSTRAP_FORCE:-0}" == "1" ]]; then
        log_warn "x-ui already exists but BOOTSTRAP_FORCE=1; continuing (no safe rollback guaranteed)"
    else
        log_error "x-ui binary already present. vpn-deploy-kit only supports greenfield VPS (DESIGN.md §0.4)."
        log_error "Run './scripts/99-uninstall.sh --scope=full' first, or BOOTSTRAP_FORCE=1 to override."
        exit 1
    fi
fi

# I-2 mitigation: non-root-user enumeration (spec v3 §2.3 step 2)
non_root_users=$(awk -F: '$3>=1000 && $1 !~ /^(nobody|systemd|sync)/ {print $1}' /etc/passwd | tr '\n' ',' | sed 's/,$//')
if [[ -n "${non_root_users}" ]]; then
    if [[ "${BOOTSTRAP_FORCE:-0}" == "1" ]]; then
        log_warn "Non-root users present (${non_root_users}); BOOTSTRAP_FORCE=1 overrides /proc/cmdline leak protection"
    else
        log_error "Non-root users detected: ${non_root_users}"
        log_error "x-ui setting -password writes password into /proc/<pid>/cmdline temporarily;"
        log_error "set BOOTSTRAP_FORCE=1 only if you fully trust those users."
        exit 1
    fi
fi

# Resolve panel config defaults
PANEL_PORT_ACTUAL="${PANEL_PORT:-2053}"
PANEL_PATH_ACTUAL="${PANEL_PATH:-$(rand_hex 8)}"
PANEL_USER_ACTUAL="${PANEL_USER:-admin-$(rand_hex 4)}"
PANEL_PASS_ACTUAL="${PANEL_PASS:-$(openssl rand -hex 24)}"

# Sanity (assert_charset will exit on mismatch)
assert_charset "${PANEL_PORT_ACTUAL}" '^[0-9]+$' "PANEL_PORT must be numeric"
assert_charset "${PANEL_PATH_ACTUAL}" '^[A-Za-z0-9_-]+$' "PANEL_PATH must be url-safe charset"
assert_charset "${PANEL_USER_ACTUAL}" '^[A-Za-z0-9_-]+$' "PANEL_USER must be [A-Za-z0-9_-]"

# Port-in-use precheck (BOOTSTRAP_FORCE=1 跳过: 幂等重跑时 x-ui 可能已在监听)
if [[ "${BOOTSTRAP_FORCE:-0}" != "1" ]]; then
    if ss -tlnp 2>/dev/null | grep -q ":${PANEL_PORT_ACTUAL} "; then
        log_error "PANEL_PORT ${PANEL_PORT_ACTUAL} already in use"
        exit 1
    fi
fi

log_info "Phase A passed; will install 3x-ui ${XUI_VERSION_PIN}"
log_info "  panel port: ${PANEL_PORT_ACTUAL} (loopback)"
log_info "  panel path: /${PANEL_PATH_ACTUAL}/"
log_info "  panel user: ${PANEL_USER_ACTUAL}"

# ============================================================================
# rollback_03 (call on any Phase B failure)
# ============================================================================
default_port=""
db_backup_03=""
rollback_03() {
    local reason="$1"
    log_error "rollback_03: ${reason}"

    # 1. Release iptables / ufw temp block on default port if still in place
    if [[ -n "${default_port}" ]]; then
        iptables -D INPUT -p tcp --dport "${default_port}" -j DROP 2>/dev/null || true
        ufw_delete_by_comment "vpn-deploy-kit:panel-tmpblock" 2>/dev/null || true
    fi

    # 2. Stop x-ui (don't fail rollback on this)
    systemctl stop x-ui 2>/dev/null || true

    # 3. Restore db backup if we made one
    if [[ -n "${db_backup_03}" && -f "${db_backup_03}" ]]; then
        cp -p "${db_backup_03}" /etc/x-ui/x-ui.db 2>/dev/null || true
    fi

    # 4. Bump failure_count + record reason
    local new_cnt=$((cnt03 + 1))
    state_set "step.03.failure_count" "${new_cnt}"
    state_set "step.03.last_failure" "${reason}"

    if [[ "${new_cnt}" -ge 2 ]]; then
        log_error "step 03 failed twice. Run ./scripts/99-uninstall.sh --scope=full and start over"
        exit 2
    fi
    exit 1
}

# ============================================================================
# Phase B: install + config + verify
# ============================================================================

# Step 5: download install.sh + sed patch + run
log_info "Downloading install.sh for ${XUI_VERSION_PIN}"
curl -fsSL "https://raw.githubusercontent.com/MHSanaei/3x-ui/${XUI_VERSION_PIN}/install.sh" \
     -o /tmp/3xui-install.sh \
     || rollback_03 "failed to fetch install.sh for ${XUI_VERSION_PIN}"
chmod +x /tmp/3xui-install.sh

# Patch: skip config_after_install() to avoid SSL setup MANDATORY interactive flow.
# We'll configure via x-ui setting CLI in step 8 below.
sed -i.bak 's|^[[:space:]]*config_after_install[[:space:]]*$|# config_after_install: skipped by vpn-deploy-kit (spec v3 §2.3)|' /tmp/3xui-install.sh
grep -q "skipped by vpn-deploy-kit" /tmp/3xui-install.sh \
    || rollback_03 "sed patch on config_after_install failed (install.sh structure changed?)"

log_info "Running patched install.sh (stdin EOF)"
bash /tmp/3xui-install.sh "${XUI_VERSION_PIN}" </dev/null \
    || rollback_03 "install.sh exited non-zero"

command -v x-ui &>/dev/null || rollback_03 "install.sh succeeded but x-ui binary missing"
[[ -f /etc/x-ui/x-ui.db ]] || rollback_03 "install.sh succeeded but x-ui.db missing"

# Step 6: close public exposure window
# v2.9.4 安全模型与旧版不同: `x-ui setting -port/-username/-password/-webBasePath/-listenIP`
# 这些 flag 在 v2.9.4 已失效(CLI 交互式)。v2.9.4 用 settings.secret 认证, panel 默认 [::]:2053。
# 安全策略: 面板端口一律 ufw deny(仅本机/SSH 隧道可访问) + 下面强随机 secret。
default_port="${PANEL_PORT_ACTUAL}"   # 2053
log_info "锁定面板端口 ${default_port} 不对外开放(仅本机/SSH隧道), v2.9.4 secret 认证"
# DROP 仅针对非回环来源(-i ! lo): 否则会把 127.0.0.1/::1 回环自检也挡住
iptables -I INPUT ! -i lo -p tcp --dport "${default_port}" -j DROP 2>/dev/null || true
ufw deny "${default_port}/tcp" comment 'vpn-deploy-kit:panel-tmpblock' >/dev/null 2>&1 || true

# Step 7: backup db BEFORE any setting modifications (Codex P1-2 / F-CN spec v3 §2.3)
db_backup_03="/etc/x-ui/x-ui.db.bak.before-03-config.$(date +%s)"
cp -p /etc/x-ui/x-ui.db "${db_backup_03}" \
    || rollback_03 "failed to backup /etc/x-ui/x-ui.db"
state_set "step.03.db_backup_path" "${db_backup_03}"

# Step 8: 配置面板 — v2.9.4 用 settings.secret 认证(替代旧 username/password/webBasePath)。
# 生成强随机 secret 写入 db, 面板登录/访问靠它; 不再依赖失效的 `x-ui setting` CLI。
# 自举: 确保 sqlite3 存在(BOOTSTRAP_FORCE=1 会跳过 00-precheck 依赖检查, 缺 sqlite3 时这里补救, 见踩坑表#11)
if command -v sqlite3 &>/dev/null; then
    log_info "sqlite3 present ✓"
else
    log_warn "sqlite3 missing, installing (v2.9.4 secret write is a hard dep)"
    export DEBIAN_FRONTEND=noninteractive
    (apt-get update -qq && apt-get install -y -qq sqlite3) \
        || rollback_03 "failed to install sqlite3 (needed for settings.secret write)"
    command -v sqlite3 &>/dev/null || rollback_03 "sqlite3 still missing after install"
fi
NEW_SECRET="$(openssl rand -hex 16)"
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value='${NEW_SECRET}' WHERE key='secret';" \
    || rollback_03 "sqlite 更新 settings.secret 失败 (v2.9.4)"
log_info "已写入 v2.9.4 强随机 secret(HMAC 认证); 面板不对外开放"

# Step 9: restart + wait for panel listen(SQLite 改动经重启生效)
log_info "Restarting x-ui and waiting for panel to listen"
systemctl restart x-ui || rollback_03 "systemctl restart x-ui failed"

PANEL_UP=""
for i in 1 2 3 5 8; do
    sleep "${i}"
    if ss -tlnp 2>/dev/null | grep -qE "(:|\.)${PANEL_PORT_ACTUAL} "; then
        PANEL_UP=1
        log_info "Panel listening on :${PANEL_PORT_ACTUAL}(v2.9.4) ✓"
        break
    fi
done
[[ -n "${PANEL_UP}" ]] \
    || rollback_03 "panel not listening on :${PANEL_PORT_ACTUAL} after retry loop (v2.9.4)"

# Step 10: loopback HTTP verify — panel 绑 *:2053(双栈), 用 IPv4 回环即可(IPv6 [::1] 常因
# v6only/回环路由不达返回 rc=7, 不作为判据)。curl 超时/拒连会返回非零(如 28/7),
# 在 set -e 下必须用 \"|| true\" 包住捕获, 否则脚本会被 curl 退出码带崩。
CURL_OK=""
code="$(curl -g -s --connect-timeout 3 --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PANEL_PORT_ACTUAL}/" 2>/dev/null || true)"
if [[ "${code}" =~ ^[1-5][0-9][0-9]$ ]]; then
    CURL_OK="127.0.0.1:${PANEL_PORT_ACTUAL} -> ${code}"
fi
if [[ -z "${CURL_OK}" ]]; then
    log_error "loopback curl 未拿到 HTTP 状态码(code='${code}'); 尝试带 exitcode 复测"
    rc2=""
    html="$(curl -g -sv --connect-timeout 3 --max-time 5 "http://127.0.0.1:${PANEL_PORT_ACTUAL}/" 2>&1 || true)"
    log_error "curl 复测输出(截断): $(printf '%s' "${html}" | head -5 | tr '\n' ' ')"
    rollback_03 "loopback curl to panel failed (v2.9.4): ipv4=${code}"
fi
log_info "panel 连通性验证:  ${CURL_OK}"

# Step 11: 面板安全由 ufw deny ${default_port} 保障(仅本机). 不撤销封锁.
log_info "panel 安全由 ufw deny ${default_port}(lo 除外) 保障, 保留封锁"

# Step 12: panel self-check (log-only, don't block)
log_info "Running x-ui settings self-check"
timeout 5 x-ui settings 2>&1 | grep -iE 'No.*configured|warning|error' \
    | tee -a "${OUTPUT_DIR}/deploy.log" || true

# Step 13: persist runtime + secrets + state (v2.9.4: 无独立账号密码, 用 secret)
write_runtime "PANEL_PORT_ACTUAL=${PANEL_PORT_ACTUAL}"
write_runtime "PANEL_PATH_ACTUAL="
write_runtime "PANEL_USER_ACTUAL="
write_runtime "PANEL_SECRET=${NEW_SECRET}"

write_secrets_env "PANEL_PORT=${PANEL_PORT_ACTUAL}"
write_secrets_env "PANEL_SECRET=${NEW_SECRET}"
write_secrets_env "PANEL_USER="
write_secrets_env "PANEL_PASS="

write_secrets ""
write_secrets "## 3x-ui Panel v2.9.4 (${XUI_VERSION_PIN})"
write_secrets "- 面板端口(仅本机):  ${PANEL_PORT_ACTUAL}  (公网已 ufw deny, 仅本机/SSH隧道)"
write_secrets "- 认证令牌(secret):  \`${NEW_SECRET}\`  (面板登录需此 header: \`SECRET\`)"
write_secrets "- DB backup: \`${db_backup_03}\`"
write_secrets ""
write_secrets "  本机访问: \`curl -H \"SECRET: ${NEW_SECRET}\" http://127.0.0.1:${PANEL_PORT_ACTUAL}/ -\`"
write_secrets "  SSH隧道:  \`ssh -L ${PANEL_PORT_ACTUAL}:127.0.0.1:${PANEL_PORT_ACTUAL} root@${VPS_IP} -p ${SSH_PORT}\` 然后浏览器开 http://127.0.0.1:${PANEL_PORT_ACTUAL}/"

state_set "step.03.completed" "true"
state_set "step.03.xui_version_installed" "${XUI_VERSION_PIN}"

mark_step_done "03-install-3xui"
step_ok "03-install-3xui"
