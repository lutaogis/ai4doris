#!/usr/bin/env bash
# ============================================================
# 08-start-cluster.sh   Doris 集群开机启动（FE Master → FE Follower → BE）
#
# 在能 ssh 到六台节点的管理机（或 node-01 自身）执行，依赖 sshpass。
#
# 用法:
#   ./08-start-cluster.sh              按顺序启动并等待就绪（默认 systemd）
#   ./08-start-cluster.sh --method bin 用 bin/start_*.sh --daemon 启动（systemd 未就绪时）
#   ./08-start-cluster.sh --no-wait    只发启动命令，不等待就绪
#
# 选项:
#   --timeout N    等待 FE 就绪的秒数，默认 240；等待 tablet 收敛固定 300s
#
# 退出码: 0=全部就绪  1=有组件未就绪（附诊断提示）  9=参数错误
#
# 说明:
#   启动顺序不能反。3 台 FE 同时冷启会触发 BDBJE 抢主，
#   虽然最终能收敛，但先起 Master 能让首次查询更快可用。
#   本脚本幂等：已在运行的节点会跳过。
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../nodes.env" 2>/dev/null || {
  echo "[FATAL] 找不到 ${SCRIPT_DIR}/../nodes.env"; exit 9; }

METHOD="systemd"; DO_WAIT=1; FE_TIMEOUT=240
while [[ $# -gt 0 ]]; do
  case "$1" in
    --method)   METHOD="${2:-systemd}"; shift 2 ;;
    --no-wait)  DO_WAIT=0; shift ;;
    --timeout)  FE_TIMEOUT="${2:-240}"; shift 2 ;;
    -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 9 ;;
  esac
done

FE_FOLLOWERS=(); FE_MASTERS=(); BE_HOSTS=()
for entry in "${ALL_NODES[@]}"; do
  IFS=':' read -r h ip role <<< "${entry}"
  if [[ "${role}" == "fe" ]]; then
    if [[ "${ip}" == "${FE_LEADER_IP}" ]]; then FE_MASTERS+=("${ip}"); else FE_FOLLOWERS+=("${ip}"); fi
  else
    BE_HOSTS+=("${ip}")
  fi
done

log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn() { printf '[%s] [WARN] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die()  { printf '[%s] [FATAL] %s\n' "$(date '+%H:%M:%S')" "$*"; exit "${2:-1}"; }

node_ssh() {
  sshpass -p "${NODE_SSH_PASSWORD:-}" ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 \
    "${NODE_SSH_USER:-lumz}@$1" "$2" 2>/dev/null
}
sql_remote() {
  node_ssh "${FE_LEADER_IP}" "mysql -h127.0.0.1 -P9030 -uroot -p'${MYSQL_ROOT_PASSWORD}' -N -e \"$1\" 2>/dev/null"
}
proc_alive() {  # $1=ip $2=pidfile
  node_ssh "$1" "echo '${NODE_SSH_PASSWORD}' | sudo -S -p '' bash -c 'test -f $2 || { echo NOPID; exit 0; }; kill -0 \$(cat $2) 2>/dev/null && echo RUNNING || echo STOPPED'"
}

# 启动单个组件：systemd 优先，失败则回退 bin 方式
start_one() {  # $1=ip  $2=fe|be  $3=显示名
  local ip="$1" role="$2" name="$3"
  if [[ "$(proc_alive "${ip}" /opt/doris/${role}/bin/${role}.pid)" == "RUNNING" ]]; then
    log "   ${name}(${ip}) 已在运行，跳过"
    return 0
  fi
  if [[ "${METHOD}" == "systemd" ]]; then
    node_ssh "${ip}" "echo '${NODE_SSH_PASSWORD}' | sudo -S -p '' systemctl start doris-${role}" >/dev/null 2>&1
  fi
  sleep 5
  if [[ "$(proc_alive "${ip}" /opt/doris/${role}/bin/${role}.pid)" != "RUNNING" ]]; then
    warn "${name}(${ip}) systemd 启动未生效，回退 bin/start_${role}.sh --daemon"
    node_ssh "${ip}" "echo '${NODE_SSH_PASSWORD}' | sudo -S -p '' -u doris /opt/doris/${role}/bin/start_${role}.sh --daemon" >/dev/null 2>&1
    sleep 8
  fi
  [[ "$(proc_alive "${ip}" /opt/doris/${role}/bin/${role}.pid)" == "RUNNING" ]] \
    && log "   ${name}(${ip}) 已拉起" || warn "${name}(${ip}) 启动失败，查 /opt/doris/${role}/log/${role}.out"
}

wait_master() {
  local deadline=$((SECONDS + FE_TIMEOUT))
  while [[ ${SECONDS} -lt ${deadline} ]]; do
    if [[ -n "$(sql_remote "SHOW FRONTENDS" | awk -F'\t' '$9=="true" && $12=="true"')" ]]; then
      return 0
    fi
    sleep 3
  done
  return 1
}
wait_fe_count() {  # $1=期望存活数
  local deadline=$((SECONDS + FE_TIMEOUT)) n
  while [[ ${SECONDS} -lt ${deadline} ]]; do
    n="$(sql_remote "SHOW FRONTENDS" | awk -F'\t' '$12=="true"' | wc -l)"
    [[ "${n}" -ge "$1" ]] && { echo "${n}"; return 0; }
    sleep 3
  done
  echo "${n:-0}"; return 1
}
wait_be_count() {  # $1=期望存活数
  local deadline=$((SECONDS + 180)) n
  while [[ ${SECONDS} -lt ${deadline} ]]; do
    n="$(sql_remote "SHOW BACKENDS" | awk -F'\t' '$10=="true"' | wc -l)"
    [[ "${n}" -ge "$1" ]] && { echo "${n}"; return 0; }
    sleep 5
  done
  echo "${n:-0}"; return 1
}
wait_tablet() {
  local deadline=$((SECONDS + 300)) row tot heal
  while [[ ${SECONDS} -lt ${deadline} ]]; do
    row="$(sql_remote "SHOW PROC '/cluster_health/tablet_health'" | awk -F'\t' '$1=="Total"')"
    if [[ -n "${row}" ]]; then
      tot="$(printf '%s' "${row}" | cut -f3)"; heal="$(printf '%s' "${row}" | cut -f4)"
      [[ -n "${tot}" && "${tot}" == "${heal}" ]] && { echo "${heal}/${tot}"; return 0; }
    fi
    sleep 5
  done
  echo "${heal:-?}/${tot:-?}"; return 1
}

echo "============================================================"
echo " Doris 集群启动  $(date '+%Y-%m-%d %H:%M:%S')   方式: ${METHOD}"
echo " FE: Master=${FE_MASTERS[*]}  Follower=${FE_FOLLOWERS[*]}"
echo " BE: ${BE_HOSTS[*]}"
echo "============================================================"
echo

# ---------- 0. 时钟 ----------
log "阶段 0/4  主机时钟检查"
for entry in "${ALL_NODES[@]}"; do
  IFS=':' read -r h ip role <<< "${entry}"
  sync_st="$(node_ssh "${ip}" "timedatectl show -p NTPSynchronized --value 2>/dev/null")"
  [[ "${sync_st}" == "yes" ]] || warn "${h}(${ip}) 时钟未同步（NTPSynchronized=${sync_st:-?}），先 sudo chronyc makestep"
done
echo

# ---------- 1. FE Master ----------
log "阶段 1/4  启动 FE Master（${FE_MASTERS[*]}）"
for ip in "${FE_MASTERS[@]}"; do start_one "${ip}" fe "FE-Master"; done
if [[ ${DO_WAIT} -eq 1 ]]; then
  if wait_master; then log "   Master 已可服务（9030 可连、IsMaster=true）"
  else die "Master 在 ${FE_TIMEOUT}s 内未就绪：看 /opt/doris/fe/log/fe.log，常见原因是 meta 损坏或端口占用"; fi
fi
echo

# ---------- 2. FE Follower ----------
log "阶段 2/4  启动 FE Follower（${FE_FOLLOWERS[*]}）"
for ip in "${FE_FOLLOWERS[@]}"; do start_one "${ip}" fe "FE-Follower"; sleep 3; done
if [[ ${DO_WAIT} -eq 1 ]]; then
  cnt="$(wait_fe_count 3)" && log "   FE 存活 ${cnt}/3" || warn "FE 仅存活 ${cnt}/3，检查未加入节点的 fe.log"
fi
echo

# ---------- 3. BE ----------
log "阶段 3/4  启动 BE（${BE_HOSTS[*]}，逐台间隔 20s 避免注册风暴）"
first=1
for ip in "${BE_HOSTS[@]}"; do
  [[ ${first} -eq 1 ]] || sleep 20
  first=0
  start_one "${ip}" be "BE"
done
if [[ ${DO_WAIT} -eq 1 ]]; then
  cnt="$(wait_be_count 3)" && log "   BE 存活 ${cnt}/3" || warn "BE 仅存活 ${cnt}/3，检查 be.out 与 Heartbeat 状态"
fi
echo

# ---------- 4. tablet 收敛 ----------
log "阶段 4/4  等待 Tablet 收敛（3 副本全部 healthy）"
if [[ ${DO_WAIT} -eq 1 ]]; then
  if res="$(wait_tablet)"; then log "   Tablet ${res} healthy，集群可用"
  else warn "Tablet 尚未收敛（${res}），BE 重启后恢复 3~10 分钟属正常，持续不收敛请看 SHOW PROC '/cluster_health/tablet_health'"; fi
fi
echo

echo "============================================================"
log "启动完成。建议接着执行："
echo "   ./06-inspect.sh -o ../docs/inspection-\$(date +%Y%m%d).md"
echo "   验证读写：mysql -h${FE_LEADER_IP} -P9030 -uroot -p'${MYSQL_ROOT_PASSWORD}' -e 'SHOW DATABASES'"
echo "   重跑 ETL：etl/jobs/run_daily.sh（确认无重复累加）"
echo "============================================================"
