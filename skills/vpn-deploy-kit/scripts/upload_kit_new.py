#!/usr/bin/env python3
"""上传 vpn-deploy-kit 到新 VPS /opt/vpn-deploy-kit/，并验证大小+无CRLF。
凭据从环境变量读取: VPN_HOST / VPN_PORT / VPN_USER / VPN_PASS。
"""
import os, sys, posixpath, paramiko

HOST = os.environ.get("VPN_HOST", "")
PORT = int(os.environ.get("VPN_PORT", "22"))
USER = os.environ.get("VPN_USER", "root")
PASS = os.environ.get("VPN_PASS", "")
SRC = os.environ.get("VPN_SRC", r"E:/workspace/vpn")
DST = "/opt/vpn-deploy-kit"
if not HOST or not PASS:
    print("ERROR: 请设置环境变量 VPN_HOST / VPN_PASS")
    sys.exit(3)

# 只上传部署必需的文件(相对路径, 目录=递归)
ITEMS = [
    "bootstrap.sh",
    "config.env",
    "config.example.env",
    "CLAUDE.md",
    "DESIGN.md",
    "scripts",
    "templates",
    "docs",
    "tests",
]

def flist(src):
    """递归展开相对路径文件列表"""
    out = {}
    for base in os.walk(src):
        for fn in base[2]:
            full = os.path.join(base[0], fn)
            rel = os.path.relpath(full, src).replace("\\", "/")
            out[rel] = full
    return out

def upload(c):
    sftp = c.open_sftp()
    # mkdir -p DST
    def mkdir_p(path):
        parts = path.strip("/").split("/")
        cur = ""
        for p in parts:
            cur = cur + "/" + p
            try:
                sftp.stat(cur)
            except IOError:
                sftp.mkdir(cur)
    mkdir_p(DST)

    # 过滤: 只传 ITEMS 开头的文件
    allf = flist(SRC)
    to_upload = {rel: f for rel, f in allf.items()
                 if rel.split("/")[0] in ITEMS}
    print(f"待上传 {len(to_upload)} 个文件")
    for rel in sorted(to_upload):
        src = to_upload[rel]
        dst = posixpath.join(DST, rel)
        # mkdir parent
        parent = posixpath.dirname(dst)
        parts = parent.strip("/").split("/")
        cur = ""
        for p in parts:
            cur += "/" + p
            try:
                sftp.stat(cur)
            except IOError:
                sftp.mkdir(cur)
        sftp.put(src, dst)
        # 保持可执行位(仅 .sh / bootstrap)
        if os.path.basename(rel).endswith(".sh") or rel == "bootstrap.sh":
            sftp.chmod(dst, 0o755)
        print(f"  UP {rel} ({os.path.getsize(src)}B)")
    sftp.close()

def verify(c):
    """远程验证: 大小一致 + 无 CRLF + bash -n"""
    cmd = (
        "cd /opt/vpn-deploy-kit && "
        "echo '=== 大小校验 ===' && "
        "for f in bootstrap.sh config.env; do echo \"$f $(wc -c < $f))B\"; done; "
        "echo '=== CRLF 检查(应无输出) ===' && "
        "grep -rl $'\\r' bootstrap.sh scripts/*.sh 2>/dev/null || echo 'NO_CRLF'; "
        "echo '=== bash -n ===' && "
        "for f in bootstrap.sh scripts/*.sh; do bash -n \"$f\" || echo \"SYNTAX_FAIL $f\"; done; echo 'SYNTAX_DONE'"
    )
    sh = c.get_transport().open_session()
    sh.settimeout(120)
    sh.exec_command(cmd)
    o = sh.makefile().read().decode("utf-8", "replace")
    e = sh.makefile_stderr().read().decode("utf-8", "replace")
    rc = sh.recv_exit_status()
    sh.close()
    print("=== VERIFY ===")
    print(o)
    if e.strip():
        print("STDERR:", e.strip()[:1500])
    print("verify rc=", rc)

def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    try:
        c.connect(HOST, port=PORT, username=USER, password=PASS,
                  timeout=40, banner_timeout=60, auth_timeout=60,
                  look_for_keys=False, allow_agent=False)
    except Exception as ex:
        print(f"CONNECT_FAIL: {type(ex).__name__}: {ex}")
        raise
    print("CONNECT_OK (免密)")
    upload(c)
    verify(c)
    c.close()
    print("DONE")

if __name__ == "__main__":
    main()
