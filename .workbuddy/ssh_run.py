#!/usr/bin/env python
"""远程执行辅助：python ssh_run.py <ip> <命令> [--sudo]
并发探测：python ssh_run.py --probe
"""
import sys
import threading

import paramiko

HOSTS = {
    "51": "doris-node-01",
    "52": "doris-node-02",
    "53": "doris-node-03",
    "54": "doris-node-04",
    "55": "doris-node-05",
    "56": "doris-node-06",
}
USER = "lumz"
PASSWORD = "lumz1021"


def connect(ip_suffix, timeout=12):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(f"192.168.1.{ip_suffix}", username=USER, password=PASSWORD,
              timeout=timeout, banner_timeout=timeout, auth_timeout=timeout)
    return c


def run(ip_suffix, cmd, timeout=120, sudo=False):
    c = connect(ip_suffix)
    try:
        if sudo:
            cmd = f"echo '{PASSWORD}' | sudo -S bash -c {shell_quote(cmd)}"
        _, out, err = c.exec_command(cmd, timeout=timeout)
        o = out.read().decode("utf-8", "replace").strip()
        e = err.read().decode("utf-8", "replace").strip()
        rc = out.channel.recv_exit_status()
        return rc, o, e
    finally:
        c.close()


def shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


def probe_all():
    results = {}

    def work(suffix):
        try:
            rc, o, e = run(suffix, PROBE_CMD, timeout=90)
            results[suffix] = o if rc == 0 else f"[rc={rc}] {o}\n[stderr] {e[:300]}"
        except Exception as exc:  # noqa: BLE001
            results[suffix] = f"[连接失败] {exc}"

    threads = [threading.Thread(target=work, args=(s,)) for s in HOSTS]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    for suffix in sorted(HOSTS):
        print(f"========== 192.168.1.{suffix} ==========")
        print(results.get(suffix, "(无结果)"))
        print()


PROBE_CMD = r'''
echo "-- hostname --"; hostname
echo "-- ip --"; ip -4 -o addr show | awk '$4!~/^127/{print $2, $4}'
echo "-- os --"; . /etc/os-release && echo "$PRETTY_NAME"
echo "-- cpu/mem --"; echo "nproc=$(nproc)"; free -h | awk 'NR==2{print $2}'
echo "-- avx2 --"; grep -q avx2 /proc/cpuinfo && echo YES || echo NO
echo "-- disks --"; lsblk -d -o NAME,SIZE,TYPE | grep disk
echo "-- mounts --"; df -h / /data1 /data2 2>/dev/null | tail -n +2
echo "-- net --"; curl -sI --max-time 6 -o /dev/null -w "aliyun-mirror:%{http_code}\n" http://mirrors.aliyun.com 2>/dev/null || echo "net:FAIL"
echo "-- java --"; java -version 2>&1 | head -1 || echo "no java"
echo "-- swap --"; swapon --show | wc -l
'''

if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "--probe":
        probe_all()
    else:
        suffix = sys.argv[1]
        cmd = sys.argv[2]
        sudo = "--sudo" in sys.argv
        rc, o, e = run(suffix, cmd, timeout=600, sudo=sudo)
        if o:
            print(o)
        if e:
            print("[stderr]", e, file=sys.stderr)
        sys.exit(rc)
