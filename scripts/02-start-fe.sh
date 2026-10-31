#!/usr/bin/env bash
# ============================================================
# 02-start-fe.sh  启动 FE（在 FE 节点执行，必须用 doris 用户）
# 用法:
#   首节点:  su - doris -c './02-start-fe.sh'
#   其余FE:  su - doris -c './02-start-fe.sh --follower'
# 顺序铁律：先在 01 上启动 -> 03-register.sh fe -> 再启动 02/03
# ============================================================
set -euo pipefail

if [[ $EUID -eq 0 ]]; then
  echo "[ERROR] Doris 不允许 root 启动，请用: su - doris -c '$0 $*'"
  exit 1
fi

MODE="leader"
[[ "${1:-}" == "--follower" ]] && MODE="follower"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../nodes.env"

FE_HOME="${DORIS_HOME}/fe"
CUR_HOST="$(hostname -s)"

# 堆内存兜底（fe.conf 里的 JAVA_OPTS 若被版本忽略，这里再压一次）
export JAVA_OPTS="${JAVA_OPTS:--Xmx4g -Xms4g -XX:+UseG1GC -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=${FE_HOME}/log}"

# 单机不允许起两个 FE
if pgrep -f "org.apache.doris.DorisFE" >/dev/null 2>&1; then
  echo "[SKIP] FE 已在运行 (pid $(pgrep -f org.apache.doris.DorisFE | head -1))"
  exit 0
fi

if [[ "${MODE}" == "follower" ]]; then
  echo "==> 检查 leader ${FE_LEADER_IP}:9010 是否可达"
  if ! timeout 3 bash -c "</dev/tcp/${FE_LEADER_IP}/9010" 2>/dev/null; then
    echo "[ERROR] 连不上 ${FE_LEADER_IP}:9010"
    echo "        请确认: 1) node-01 的 FE 已启动  2) 已执行 03-register.sh fe"
    exit 1
  fi
  echo "==> 以 --helper 方式加入集群（主机 ${CUR_HOST}）"
  "${FE_HOME}/bin/start_fe.sh" --helper "${FE_LEADER_IP}:9010" --daemon
else
  echo "==> 以首节点方式启动（主机 ${CUR_HOST}）"
  "${FE_HOME}/bin/start_fe.sh" --daemon
fi

echo "==> 等待 8030 端口就绪（最多 60s）"
for i in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:8030/api/bootstrap" >/dev/null 2>&1 \
     || timeout 1 bash -c "</dev/tcp/127.0.0.1/8030" 2>/dev/null; then
    echo "    OK (${i}s)"
    break
  fi
  if [[ $i -eq 60 ]]; then
    echo "[ERROR] 60s 内未就绪，查看日志: ${FE_HOME}/log/fe.log"
    tail -30 "${FE_HOME}/log/fe.log" || true
    exit 1
  fi
  sleep 1
done

echo ""
echo "==> FE 已启动: $(hostname -s)"
echo "    Web UI : http://$(hostname -I | awk '{print $1}'):8030"
echo "    MySQL  : mysql -h $(hostname -I | awk '{print $1}') -P 9030 -uroot"
