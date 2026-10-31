#!/usr/bin/env bash
# ============================================================
# 04-start-be.sh  启动 BE（在 node-04/05/06 执行，doris 用户）
# 用法: su - doris -c './04-start-be.sh'
# ============================================================
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "[ERROR] Doris 不允许 root 启动，请用: su - doris -c '$0'"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../nodes.env"

BE_HOME="${DORIS_HOME}/be"

if pgrep -f "doris_be" >/dev/null 2>&1; then
  echo "[SKIP] BE 已在运行 (pid $(pgrep -f doris_be | head -1))"
  exit 0
fi

echo "==> [1/3] 检查数据盘"
for mnt in /data1 /data2; do
  if ! mountpoint -q "${mnt}"; then
    echo "[ERROR] ${mnt} 未挂载，BE 启动会因为路径不存在直接退出"
    echo "        先执行: sudo DATA_DISKS=\"/dev/vdb /dev/vdc\" CONFIRM_FORMAT=yes ./00-init-os.sh <host> <ip>"
    exit 1
  fi
  mkdir -p "${mnt}/doris"
  avail="$(df -BG --output=avail "${mnt}" | tail -1 | tr -dc '0-9')"
  echo "    ${mnt} 可用 ${avail}G"
  if [[ "${avail}" -lt 20 ]]; then
    echo "[WARN] ${mnt} 剩余空间不足 20G"
  fi
done

echo "==> [2/3] 启动 BE"
"${BE_HOME}/bin/start_be.sh" --daemon

echo "==> [3/3] 等待 8040 就绪（最多 60s）"
for i in $(seq 1 60); do
  if timeout 1 bash -c "</dev/tcp/127.0.0.1/8040" 2>/dev/null; then
    echo "    OK (${i}s)"
    break
  fi
  if [[ $i -eq 60 ]]; then
    echo "[ERROR] 启动超时，查看日志: ${BE_HOME}/log/be.WARNING"
    tail -30 "${BE_HOME}/log/be.WARNING" || true
    exit 1
  fi
  sleep 1
done

echo ""
echo "==> BE 已启动: $(hostname -s)"
echo "    本机 metrics: curl http://127.0.0.1:8040/metrics | head"
echo "    下一步（在 node-01 执行）: ./03-register.sh be"
