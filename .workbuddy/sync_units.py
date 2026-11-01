#!/usr/bin/env python
"""把修正后的 systemd unit 同步到六台节点并校验语法。

FE 节点推 doris-fe.service，BE 节点推 doris-be.service。
只做 daemon-reload + systemd-analyze verify，不重启任何服务。
"""
import base64
import sys

import paramiko

PASSWORD = "lumz1021"
USER = "lumz"

FE_NODES = {"51": "doris/node-01", "52": "doris-node-02", "53": "doris-node-03"}
BE_NODES = {"54": "doris-node-04", "55": "doris-node-05", "56": "doris-node-06"}


def run(ip, cmd, timeout=90):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(f"192.168.1.{ip}", username=USER, password=PASSWORD, timeout=15)
    try:
        _, out, err = c.exec_command(cmd, timeout=timeout)
        o = out.read().decode("utf-8", "replace").strip()
        e = err.read().decode("utf-8", "replace").strip()
        return out.channel.recv_exit_status(), o, e
    finally:
        c.close()


def push(ip, local, remote):
    with open(local, "rb") as fh:
        payload = base64.b64encode(fh.read()).decode()
    cmd = f"base64 -d > {remote} <<'EOF'\n{payload}\nEOF\nls -l {remote}"
    return run(ip, cmd)


def deploy(ip, unit_name, local_path):
    tmp = f"/home/lumz/{unit_name}"
    rc, o, e = push(ip, local_path, tmp)
    if rc != 0:
        return f"[{ip}] 上传失败: {e[:120]}"

    sudo_cmd = (
        f"echo '{PASSWORD}' | sudo -S -p '' bash -c "
        f"\"cp {tmp} /etc/systemd/system/{unit_name} && "
        f"systemctl daemon-reload && "
        f"systemd-analyze verify /etc/systemd/system/{unit_name} 2>&1 | head -5; "
        f"systemctl is-enabled {unit_name} 2>&1\""
    )
    rc, o, e = run(ip, sudo_cmd)
    return f"[{ip}] rc={rc} {o.strip()[:200] or 'ok'}"


def main():
    results = []
    for ip in FE_NODES:
        results.append(deploy(ip, "doris-fe.service", "scripts/systemd/doris-fe.service"))
    for ip in BE_NODES:
        results.append(deploy(ip, "doris-be.service", "scripts/systemd/doris-be.service"))
    for line in results:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
