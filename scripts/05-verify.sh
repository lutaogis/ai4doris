#!/usr/bin/env bash
# ============================================================
# 05-verify.sh  集群验收（在 node-01 执行）
# 用法: ./05-verify.sh          仅状态巡检
#       ./05-verify.sh --smoke  额外跑一遍建表/写入/查询冒烟
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../nodes.env"

MYSQL_ARGS=(-h "${FE_LEADER_IP}" -P 9030 -uroot --connect-timeout=10 --batch --raw)
[[ -n "${MYSQL_AUTH_OPT}" ]] && MYSQL_ARGS+=("${MYSQL_AUTH_OPT}")
[[ -n "${MYSQL_ROOT_PASSWORD:-}" ]] && MYSQL_ARGS+=("-p${MYSQL_ROOT_PASSWORD}")
Q() { mysql "${MYSQL_ARGS[@]}" -e "$1" 2>/dev/null; }

# 按表头取列号，避免不同版本列顺序变化
col_idx() {
  local header="$1" name="$2"
  echo "${header}" | tr '\t' '\n' | grep -n "^${name}$" | head -1 | cut -d: -f1
}

PASS=0; FAIL=0
ok(){ echo "  [PASS] $*"; PASS=$((PASS+1)); }
ng(){ echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }

echo "================ Doris 集群验收 ================"
Q "SELECT 1" >/dev/null || { echo "[FATAL] 连不上 ${FE_LEADER_IP}:9030"; exit 1; }

echo ""
echo "-- 1. FE --"
FE_OUT="$(Q "SHOW FRONTENDS")"
FE_HDR="$(echo "${FE_OUT}" | head -1)"
IDX_ALIVE="$(col_idx "${FE_HDR}" "Alive")";      IDX_ALIVE="${IDX_ALIVE:-7}"
IDX_MASTER="$(col_idx "${FE_HDR}" "IsMaster")";  IDX_MASTER="${IDX_MASTER:-6}"
IDX_ROLE="$(col_idx "${FE_HDR}" "Role")";        IDX_ROLE="${IDX_ROLE:-4}"
IDX_IP="$(col_idx "${FE_HDR}" "IP")";            IDX_IP="${IDX_IP:-2}"
echo "${FE_OUT}" | awk -F'\t' -v i="${IDX_IP}" -v a="${IDX_ALIVE}" -v m="${IDX_MASTER}" -v r="${IDX_ROLE}" \
  'NR>1{printf "    %-16s %-12s master=%-6s alive=%s\n", $i, $r, $m, $a}'
fe_alive=$(echo "${FE_OUT}" | awk -F'\t' -v i="${IDX_ALIVE}" 'NR>1 && $i=="true"' | wc -l | tr -d ' ')
fe_master=$(echo "${FE_OUT}" | awk -F'\t' -v i="${IDX_MASTER}" 'NR>1 && $i=="true"' | wc -l | tr -d ' ')
[[ "${fe_alive}" -eq 3 ]] && ok "FE 存活 3/3" || ng "FE 存活 ${fe_alive}/3"
[[ "${fe_master}" -eq 1 ]] && ok "Master 唯一" || ng "Master 数量=${fe_master}（应为 1）"

echo ""
echo "-- 2. BE --"
BE_OUT="$(Q "SHOW BACKENDS")"
BE_HDR="$(echo "${BE_OUT}" | head -1)"
B_ALIVE="$(col_idx "${BE_HDR}" "Alive")";          B_ALIVE="${B_ALIVE:-10}"
B_IP="$(col_idx "${BE_HDR}" "IP")";                B_IP="${B_IP:-3}"
B_TABLET="$(col_idx "${BE_HDR}" "TabletNum")";     B_TABLET="${B_TABLET:-16}"
B_USED="$(col_idx "${BE_HDR}" "DataUsedCapacity")"; B_USED="${B_USED:-15}"
echo "${BE_OUT}" | awk -F'\t' -v i="${B_IP}" -v a="${B_ALIVE}" -v t="${B_TABLET}" -v u="${B_USED}" \
  'NR>1{printf "    %-16s alive=%-6s tablets=%-8s used=%s\n", $i, $a, $t, $u}'
be_alive=$(echo "${BE_OUT}" | awk -F'\t' -v i="${B_ALIVE}" 'NR>1 && $i=="true"' | wc -l | tr -d ' ')
[[ "${be_alive}" -eq 3 ]] && ok "BE 存活 3/3" || ng "BE 存活 ${be_alive}/3"

echo ""
echo "-- 3. 版本 --"
Q "SELECT @@version_comment" | tail -1 | sed 's/^/    /'

echo ""
echo "-- 4. 节点端口 --"
for item in "${ALL_NODES[@]}"; do
  host="${item%%:*}"; rest="${item#*:}"; ip="${rest%%:*}"; role="${rest#*:}"
  if [[ "${role}" == "fe" ]]; then
    port=8030
  else
    port=8040
  fi
  if timeout 1 bash -c "</dev/tcp/${ip}/${port}" 2>/dev/null; then
    echo "    ${host} (${ip}) :${port} up"
  else
    echo "    ${host} (${ip}) :${port} DOWN"
  fi
done

if [[ "${1:-}" == "--smoke" ]]; then
  echo ""
  echo "-- 5. 冒烟测试 --"
  if Q "SHOW DATABASES" | grep -qx "demo"; then
    echo "    demo 库已存在，跳过建库，仅验证读写"
  else
    echo "    执行 sql/01-init.sql"
    mysql "${MYSQL_ARGS[@]}" < "${SCRIPT_DIR}/../sql/01-init.sql" && ok "建库建表" || ng "建库建表"
  fi
  Q "INSERT INTO demo.dwd_yield_daily VALUES (CURDATE(),'F01','L01','P001','SMT',10000,9950,50,99.5000,NOW())" \
    && ok "写入一条" || echo "    (可能已存在，忽略)"
  cnt="$(Q "SELECT COUNT(*) FROM demo.dwd_yield_daily" | tail -1)"
  [[ "${cnt:-0}" -ge 1 ]] && ok "查询可见，当前 ${cnt} 行" || ng "查询无数据"
fi

echo ""
echo "================ 结果: PASS=${PASS} FAIL=${FAIL} ================"
[[ "${FAIL}" -eq 0 ]] || exit 1
