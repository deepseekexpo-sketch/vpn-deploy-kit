#!/usr/bin/env python3
"""上传 deploy_remote.sh 到 VPS 并阻塞执行(bootstrap 全流程)。
凭据从环境变量读取: VPN_HOST / VPN_PORT / VPN_USER / VPN_PASS。
"""
import sys, os, paramiko

HOST = os.environ.get("VPN_HOST", "")
PORT = int(os.environ.get("VPN_PORT", "22"))
USER = os.environ.get("VPN_USER", "root")
PASS = os.environ.get("VPN_PASS", "")
LOCAL = os.environ.get("VPN_DEPLOY_SCRIPT", r"E:/workspace/vpn/.tmp-deploy/deploy_remote.sh")
REMOTE = "/opt/vpn-deploy-kit/deploy_remote.sh"
if not HOST or not PASS:
    print("ERROR: 请设置环境变量 VPN_HOST / VPN_PASS")
    sys.exit(3)

c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST, port=PORT, username=USER, password=PASS, timeout=30,
          banner_timeout=45, auth_timeout=45, look_for_keys=False, allow_agent=False)
sftp = c.open_sftp()
sftp.put(LOCAL, REMOTE)
sftp.chmod(REMOTE, 0o755)
sftp.close()
print("UPLOADED")

# 阻塞执行, 长超时(30 min)。bootstrap 幂等, 失败标志在输出里判断。
sh = c.get_transport().open_session()
sh.settimeout(1800)
sh.exec_command(f"bash {REMOTE}")
# 流式读取输出
o = sh.makefile().read().decode("utf-8", "replace")
e = sh.makefile_stderr().read().decode("utf-8", "replace")
rc = sh.recv_exit_status()
sh.close()
print(o)
if e.strip():
    print("=== STDERR ===")
    print(e[-3000:])
print("=== EXIT_CODE:", rc, "===")
c.close()
