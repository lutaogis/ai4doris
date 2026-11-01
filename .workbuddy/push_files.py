#!/usr/bin/env python
"""把本地文件推到远端（走 exec + base64，不依赖 sftp 子系统）
用法: python push_files.py <本地路径> [<远端路径>] [--ip 51] [--sudo]
"""
import base64
import os
import sys

import paramiko

HOST, USER, PASSWORD = "192.168.1.51", "lumz", "lumz1021"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        print("用法: push_files.py <本地路径> [远端路径] [--ip 51] [--sudo]")
        return 1
    local = args[0]
    remote = args[1] if len(args) > 1 else "/tmp/" + os.path.basename(local)

    ip = HOST
    if "--ip" in sys.argv:
        ip = "192.168.1." + sys.argv[sys.argv.index("--ip") + 1]

    with open(local, "rb") as fh:
        payload = base64.b64encode(fh.read()).decode()

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(ip, username=USER, password=PASSWORD, timeout=15)
    try:
        cmd = f"base64 -d > '{remote}' <<'B64EOF'\n{payload}\nB64EOF\nchmod +x '{remote}' && ls -l '{remote}'"
        _, out, err = c.exec_command(cmd, timeout=90)
        text = out.read().decode("utf-8", "replace").strip()
        etext = err.read().decode("utf-8", "replace").strip()
        rc = out.channel.recv_exit_status()
        if rc != 0:
            print(f"[FAIL] {remote}: {etext[:300]}")
            return 1
        print(f"[OK] {local} -> {ip}:{remote}")
        if text:
            print(text)
        if "--sudo" in sys.argv:
            sudo_cmd = (
                f"echo '{PASSWORD}' | sudo -S -p '' bash -c "
                f"\"cp '{remote}' /opt/ai4doris/scripts/ && chmod +x /opt/ai4doris/scripts/{os.path.basename(remote)}\""
            )
            _, out2, err2 = c.exec_command(sudo_cmd, timeout=60)
            out2.channel.recv_exit_status()
            msg = out2.read().decode("utf-8", "replace").strip() or err2.read().decode("utf-8", "replace").strip()
            print("[OK] 已复制到 /opt/ai4doris/scripts/" if "denied" not in msg else f"[WARN] {msg[:200]}")
    finally:
        c.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
