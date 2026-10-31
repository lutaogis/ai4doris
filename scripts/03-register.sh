#!/usr/bin/env bash
# ============================================================
# 03-register.sh  注册节点（只在 doris-node-01 执行，幂等）
# 用法:
#   ./03-register.sh fe    # 首节点起好后立刻执行，再启动 02/03 的 FE
#   ./03-register.sh be    # 三台 BE 起来后执行
# 依赖：本机有 mysql 客户端
# ============================================================
set -euo pipefail

STAGE="${1:?用法: $0 fe|be}"
[[ "${STAGE}" == "fe" || "${STAGE}" == "be" ]] || { echo "[ERROR] 参数只能是 fe 或 be"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../nodes.env"

MYSQL_ARGS=(-h "${FE_LEADER_IP}" -P 9030 -uroot --connect-timeout=10 --batch --raw)
[[ -n "${MYSQL_AUTH_OPT}" ]] && MYSQL_ARGS+=("${MYSQL_AUTH_OPT}")
[[ -n "${MYSQL_ROOT_PASSWORD:-}" ]] && MYSQL_ARGS+=("-p${MYSQL_ROOT_PASSWORD}")

run_sql() { mysql "${MYSQL_ARGS[@]}" -e "$1"; }

echo "==> 连接 FE ${FE_LEADER_IP}:9030"
# 注意：集群没有 BE 时 SELECT 1 会报 No backend available，改用 SHOW FRONTENDS 探活
run_sql "SHOW FRONTENDS" >/dev/null || { echo "[ERROR] 连不上 FE，确认 02-start-fe.sh 已执行"; exit 1; }

if [[ "${STAGE}" == "fe" ]]; then
  echo "==> 注册 FE Follower"
  for item in "${ALL_NODES[@]}"; do
    h="${item%%:*}"; rest="${item#*:}"; ip="${rest%%:*}"; role="${rest#*:}"
    [[ "${role}" != "fe" ]] && continue
    [[ "${ip}" == "${FE_LEADER_IP}" ]] && continue
    echo "    + ${h} (${ip})"
    run_sql "ALTER SYSTEM ADD FOLLOWER \"${ip}:9010\"" 2>&1 | grep -v "^$" || true
  done
  echo ""
  echo "==> 当前 FE 列表（此时 02/03 应为 Alive=false，属于正常）"
  run_sql "SHOW FRONTENDS"
  echo ""
  echo "==> 下一步：去 node-02 / node-03 执行"
  echo "    su - doris -c '~/ai4doris/scripts/02-start-fe.sh --follower'"
else
  echo "==> 注册 BE"
  for item in "${ALL_NODES[@]}"; do
    h="${item%%:*}"; rest="${item#*:}"; ip="${rest%%:*}"; role="${rest#*:}"
    [[ "${role}" != "be" ]] && continue
    echo "    + ${h} (${ip})"
    run_sql "ALTER SYSTEM ADD BACKEND \"${ip}:9050\"" 2>&1 | grep -v "^$" || true
  done
  echo ""
  echo "==> 等待 BE 心跳（最多 30s）"
  for i in $(seq 1 30); do
    alive="$(run_sql "SHOW BACKENDS" | awk 'NR>1 && $2=="true"' | wc -l | tr -d ' ')"
    [[ "${alive}" -ge 3 ]] && break
    sleep 1
  done
  run_sql "SHOW BACKENDS"
fi
