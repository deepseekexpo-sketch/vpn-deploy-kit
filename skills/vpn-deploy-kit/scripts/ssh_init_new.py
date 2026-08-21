#!/usr/bin/env python3
"""连新服务器: 密码登录 -> 注入部署公钥 -> 探测环境。
凭据从环境变量读取, 防止硬编码泄露:
  export VPN_HOST=<IP>  VPN_PORT=<SSH端口>  VPN_USER=root  VPN_PASS=<密码>
"""
import sys, os, paramiko

HOST = os.environ.get("VPN_HOST", "")
PORT = int(os.environ.get("VPN_PORT", "22"))
USER = os.environ.get("VPN_USER", "root")
PASS = os.environ.get("VPN_PASS", "")
PUBFILE = os.environ.get("VPN_PUBFILE", r"E:/workspace/vpn/.tmp-deploy/deploy_key.pub")
if not HOST or not PASS:
    print("ERROR: 请设置环境变量 VPN_HOST / VPN_PASS (可选 VPN_PORT/VPN_USER/VPN_PUBFILE)")
    sys.exit(3)

def run(c, cmd, tmo=90):
    sh = c.get_transport().open_session()
    sh.settimeout(tmo)
    sh.exec_command(cmd)
    o = sh.makefile().read().decode("utf-8", "replace")
    e = sh.makefile_stderr().read().decode("utf-8", "replace")
    rc = sh.recv_exit_status()
    sh.close()
    return o, e, rc

def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        c.connect(HOST, port=PORT, username=USER, password=PASS,
                  timeout=40, banner_timeout=60, auth_timeout=60,
                  look_for_keys=False, allow_agent=False)
    except Exception as ex:
        print(f"CONNECT_FAIL: {type(ex).__name__}: {ex}")
        sys.exit(1)
    print("CONNECT_OK")

    # 1) 注入部署公钥 (幂等)
    pub = open(PUBFILE).read().strip()
    cmd = (f"mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && "
           f"chmod 600 ~/.ssh/authorized_keys && "
           f"grep -qF '{pub}' ~/.ssh/authorized_keys 2>/dev/null || echo '{pub}' >> ~/.ssh/authorized_keys; "
           f"echo AUTH_OK; wc -l ~/.ssh/authorized_keys")
    o, e, rc = run(c, cmd)
    print("=== AUTH ===")
    print(o)
    if e.strip():
        print("STDERR:", e.strip()[:500])

    # 2) 探测环境
    probe = (
        ". /etc/os-release 2>/dev/null; echo OS=$PRETTY_NAME\n"
        "echo ARCH=$(uname -m)\n"
        "echo XUI=$([ -d /usr/local/x-ui ] && echo yes || echo no)\n"
        "echo XRAY_VER=$(/usr/local/x-ui/bin/xray-linux-amd64 version 2>/dev/null | head -1 || echo none)\n"
        "echo KIT_DIR=$([ -d /opt/vpn-deploy-kit ] && echo yes || echo no)\n"
        "for sq in /usr/local/x-ui/db/x-ui.db /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db; do "
        "[ -f \"$sq\" ] && echo DB_FOUND=$sq; done\n"
        "ls -la /usr/local/x-ui/bin/config.json 2>/dev/null | head -2\n"
        "echo PROBE_DONE\n"
    )
    o, e, rc = run(c, probe)
    print("=== PROBE ===")
    print(o)
    if e.strip():
        print("STDERR:", e.strip()[:1500])
    c.close()
    print("SESSION_DONE")

if __name__ == "__main__":
    main()
