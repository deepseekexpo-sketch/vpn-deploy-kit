#!/usr/bin/env bash
# 远程执行: 在 VPS 上跑 bootstrap 完整流程, 等待结束, 打印最终状态。
set -u
cd /opt/vpn-deploy-kit

echo "=== [phase0] 去 CRLF ==="
sed -i 's/\r$//' bootstrap.sh scripts/*.sh
echo "CRLF_STRIPPED"

echo "=== [phase1] bash -n 复检 ==="
fail=0
for f in bootstrap.sh scripts/*.sh; do
  if ! bash -n "$f" 2>/dev/null; then echo "FAIL:$f"; fail=1; fi
done
if [ "$fail" = "1" ]; then echo "FATAL_SYNTAX_ERROR"; exit 2; fi
echo "SYNTAX_ALL_OK"

echo "=== [phase2] bootstrap.sh (可重复进入, 幂等) ==="
mkdir -p output
# 重置 state(清零 03 failure_count, 避免 cap) + 停止残留 x-ui(释放 2053) + 清除旧 DROP 规则
echo '{}' > output/state.json
rm -f output/.step-* output/runtime.env
x-ui stop >/dev/null 2>&1 || true
iptables -D INPUT -p tcp --dport 2053 -j DROP 2>/dev/null || true
iptables -D INPUT ! -i lo -p tcp --dport 2053 -j DROP 2>/dev/null || true
sleep 1
rm -f output/deploy_console.log
bash bootstrap.sh > output/deploy_console.log 2>&1
rc=$?
echo "BOOTSTRAP_RC=$rc"
echo "----- deploy_console.log (最后 40 行) -----"
tail -n 40 output/deploy_console.log
echo "----- STEP_OK 检查 -----"
grep -c "STEP_OK:" output/deploy_console.log || true

echo "=== [phase3] 最终状态 ==="
echo "-- state.json --"
cat output/state.json 2>/dev/null || echo "(no state.json)"
echo
echo "-- 监听端口 --"
ss -tlnup 2>/dev/null | grep -E ':443 |:8443 ' || echo "NO_LISTEN"
echo "-- 产物文件 --"
ls -la output/*.yaml output/secrets*.md 2>/dev/null || echo "(no outputs)"

echo "ALL_DONE rc=$rc"
