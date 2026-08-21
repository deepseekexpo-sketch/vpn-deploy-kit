#!/usr/bin/env bash
set -euo pipefail

KIT_DIR="/opt/vpn-deploy-kit"
source "${KIT_DIR}/config.env"
OUTPUT_DIR="${KIT_DIR}/output"
source "${KIT_DIR}/scripts/lib.sh"

xray_bin="/usr/local/x-ui/bin/xray-linux-amd64"

echo "=== Generating Reality keys ==="
output=$("$xray_bin" x25519)
REALITY_PRIVKEY=$(echo "$output" | grep 'PrivateKey' | head -1 | sed 's/^[^:]*: //')
REALITY_PUBKEY=$(echo "$output" | grep 'PublicKey' | head -1 | sed 's/^[^:]*: //')
REALITY_UUID=$(uuidgen)
REALITY_SHORT_ID=$(openssl rand -hex 8)
REALITY_SUB_ID=$(openssl rand -hex 8)

echo "PRIV=${REALITY_PRIVKEY:0:20}..."
echo "PUB=${REALITY_PUBKEY:0:20}..."
echo "UUID=${REALITY_UUID}"

if [[ -z "$REALITY_PRIVKEY" || -z "$REALITY_PUBKEY" ]]; then
    echo "FATAL: key generation failed"
    exit 1
fi

echo "=== Creating temp dir ==="
tmp_dir=$(mktemp -d -p /root vpn-deploy-kit-04.XXXXXX)
chmod 700 "$tmp_dir"

echo "=== Rendering templates ==="
export REALITY_UUID REALITY_SUB_ID REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}" REALITY_PRIVKEY REALITY_PUBKEY REALITY_SHORT_ID CLIENT_NAME_PREFIX
envsubst < "${KIT_DIR}/templates/reality-settings.json.tmpl" > "${tmp_dir}/settings.json"
envsubst < "${KIT_DIR}/templates/reality-stream-settings.json.tmpl" > "${tmp_dir}/stream.json"

# Verify no unrendered placeholders
if grep -q '${' "${tmp_dir}/settings.json" || grep -q '${' "${tmp_dir}/stream.json"; then
    echo "ERROR: unrendered placeholders found"
    cat "${tmp_dir}/settings.json"
    exit 1
fi

echo "=== Inserting into x-ui DB ==="
reality_port="${REALITY_PORT_ACTUAL:-${REALITY_PORT:-443}}"
INBOUND_TAG="inbound-${reality_port}"
INBOUND_REMARK="${CLIENT_NAME_PREFIX}-reality"

sqlite3 /etc/x-ui/x-ui.db <<SQL
BEGIN IMMEDIATE;
DELETE FROM inbounds WHERE tag='${INBOUND_TAG}';
DELETE FROM client_traffics WHERE inbound_id IN (SELECT id FROM inbounds WHERE tag = '${INBOUND_TAG}');
INSERT INTO inbounds (
    user_id, up, down, total, all_time, remark, enable, expiry_time,
    traffic_reset, last_traffic_reset_time, listen, port, protocol,
    settings, stream_settings, tag, sniffing
) VALUES (
    1, 0, 0, 0, 0, '${INBOUND_REMARK}', 1, 0,
    'never', 0, '', ${reality_port}, 'vless',
    CAST(readfile('${tmp_dir}/settings.json') AS TEXT),
    CAST(readfile('${tmp_dir}/stream.json') AS TEXT),
    '${INBOUND_TAG}',
    '{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'
);
INSERT INTO client_traffics (
    inbound_id, enable, email, up, down, all_time, expiry_time, total, reset, last_online
) VALUES (
    (SELECT id FROM inbounds WHERE tag = '${INBOUND_TAG}'), 1, '${CLIENT_NAME_PREFIX}', 0, 0, 0, 0, 0, 0, 0
);
COMMIT;
SQL

echo "DB INSERT done. Restarting x-ui..."
x-ui restart
echo "Waiting for xray to start..."
sleep 8

# Verify
if ss -tlnp | grep -q ":${reality_port}.*xray"; then
    echo "SUCCESS: xray listening on port ${reality_port}"
else
    echo "WARNING: xray not yet listening on ${reality_port}, checking anyway..."
    ss -tlnp | grep "${reality_port}" || true
fi

# Save runtime values
write_runtime "REALITY_PORT_ACTUAL=${reality_port}"
write_runtime "REALITY_SNI=${REALITY_SNI:-addons.mozilla.org}"
write_runtime "REALITY_UUID=${REALITY_UUID}"
write_runtime "REALITY_PUBKEY=${REALITY_PUBKEY}"
write_runtime "REALITY_SHORT_ID=${REALITY_SHORT_ID}"
write_runtime "REALITY_SUB_ID=${REALITY_SUB_ID}"

write_secrets_env "REALITY_PRIVKEY=${REALITY_PRIVKEY}"

# Mark step done
state_set "step.04.completed" "true"
touch "${OUTPUT_DIR}/.step-04-add-reality"
step_ok "04-add-reality"

echo ""
echo "=== REALITY DEPLOYMENT COMPLETE ==="
echo "Port: ${reality_port}"
echo "SNI: ${REALITY_SNI:-addons.mozilla.org}"
echo "UUID: ${REALITY_UUID}"
echo "PubKey: ${REALITY_PUBKEY}"

# Cleanup
rm -rf "${tmp_dir}" 2>/dev/null || true
