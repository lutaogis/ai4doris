#!/usr/bin/env bash
# ============================================================
# 07-stop-cluster.sh   Doris 集群优雅停机（BE → FE Follower → FE Master）
#
# 在能 ssh 到六台节点的管理机（或 node-01 自身）执行，依赖 sshpass。
#
# 用法:
#   ./07-stop-cluster.sh --dry-run    演练：只做体检 + 元数据冷备，不停止任何进程
#   ./07-stop-cluster.sh              交互确认后停进程（不关操作系统）
#   ./07-stop-cluster.sh --yes        跳过交互确认
#   ./07-stop-cluster.sh --yes --poweroff   停完进程后逐台 poweroff
#   ./07-stop-cluster.sh --no-backup  跳过元数据冷备（不推荐，仅限已备份过）
#
# 选项:
#   --wait N       单节点等待进程退出的秒数，默认 120
#   --interval N   节点之间间隔秒数，默认 10
#
# 退出码: 0=全部干净停止  1=有节点未停干净  9=参数/连接错误
#
# 关键约束（详见 docs/doris-shutdown-guide.md）:
#   1. stop_be.sh / stop_fe.sh 默认发 SIGKILL(9)，必须显式 --grace 才是 SIGTERM(15)
#   2. 必须以 doris 用户执行停止脚本，否则读不到 pid 文件
#   3. 顺序不能反：先 BE 后 FE，FE 内部先 Follower 后 Master
#   4. 停完必须校验进程真的退出，再做 poweroff
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../nodes.env" 2>/dev/null || {
  echo "[FATAL] 找不到 ${SCRIPT_DIR}/../nodes.env"; exit 9; }

ASSUME_YES=0; DRY_RUN=0; POWEROFF=0; DO_BACKUP=1
WAIT_SEC=120; INTERVAL=10
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)    DRY_RUN=1; shift ;;
    --yes|-y)     ASSUME_YES=1; shift ;;
    --poweroff)   POWEROFF=1; shift ;;
    --no-backup)  DO_BACKUP=0; shift ;;
    --wait)       WAIT_SEC="${2:-120}"; shift 2 ;;
    --interval)   INTERVAL="${2:-10}"; shift 2 ;;
    -h|--help)    sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 9 ;;
  esac
done

# ---------- 节点分组 ----------
FE_FOLLOWERS=(); FE_MASTERS=(); BE_HOSTS=()
for entry in "${ALL_NODES[@]}"; do
  IFS=':' read -r h ip role <<< "${entry}"
  if [[ "${role}" == "fe" ]]; then
    if [[ "${ip}" == "${FE_LEADER_IP}" ]]; then FE_MASTERS+=("${ip}"); else FE_FOLLOWERS+=("${ip}"); fi
  else
    BE_HOSTS+=("${ip}")
  fi
done

TS="$(date '+%Y-%m-%d %H:%M:%S')"
STAMP="$(date '+%Y%m%d_%H%M%S')"
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
proc_alive() {  # $1=ip  $2=pidfile  → RUNNING / STOPPED / NOPID
  node_ssh "$1" "echo '${NODE_SSH_PASSWORD}' | sudo -S -p '' bash -c 'test -f $2 || { echo NOPID; exit 0; }; kill -0 \$(cat $2) 2>/dev/null && echo RUNNING || echo STOPPED'"
}

# 停止单个组件：systemd 托管的必须用 systemctl stop，
# 否则 stop_*.sh 发的 SIGTERM 会被 Restart=on-failure 判定为崩溃并自动拉起
stop_component() {  # $1=ip  $2=fe|be  → 回显使用的方式
  local ip="$1" role="$2" unit="doris-$2"
  if [[ "$(node_ssh "${ip}" "systemctl is-active ${unit} 2>/dev/null")" == "active" ]]; then
    node_ssh "${ip}" "echo '${NODE_SSH_PASSWORD}' | sudo -S -p '' systemctl stop ${unit}" >/dev/null 2>&1
    echo "systemctl stop ${unit}"
  else
    node_ssh "${ip}" "echo '${NODE_SSH_PASSWORD}' | sudo -S -p '' -u doris /opt/doris/${role}/bin/stop_${role}.sh --grace" >/dev/null 2>&1
    echo "bin/stop_${role}.sh --grace"
  fi
}

echo "============================================================"
echo " Doris 集群停机  ${TS}"
echo " FE: Master=${FE_MASTERS[*]}  Follower=${FE_FOLLOWERS[*]}"
echo " BE: ${BE_HOSTS[*]}"
echo " 模式: $([[ ${DRY_RUN} -eq 1 ]] && echo '演练(dry-run)' || echo '实际停机')$([[ ${POWEROFF} -eq 1 ]] && echo ' + 关闭操作系统')"
echo "============================================================"
echo

# ============================================================
# 阶段 1  前置体检
# ============================================================
log "阶段 1/5  前置体检"
sql_remote "SELECT 1" >/dev/null 2>&1 || die "连不上 ${FE_LEADER_IP}:9030，集群状态未知，终止"

FE_ROWS="$(sql_remote "SHOW FRONTENDS")"
FE_ALIVE="$(printf '%s\n' "${FE_ROWS}" | awk -F'\t' '$12=="true"' | wc -l)"
log "   FE 存活 ${FE_ALIVE}/3"

BE_ROWS="$(sql_remote "SHOW BACKENDS")"
BE_ALIVE="$(printf '%s\n' "${BE_ROWS}" | awk -F'\t' '$10=="true"' | wc -l)"
log "   BE 存活 ${BE_ALIVE}/3"
[[ "${BE_ALIVE}" -lt 3 ]] && warn "BE 未全部存活，停机无数据风险，但启动前需查明原因"

TH_ROW="$(sql_remote "SHOW PROC '/cluster_health/tablet_health'" | awk -F'\t' '$1=="Total"')"
if [[ -n "${TH_ROW}" ]]; then
  T_TOTAL="$(printf '%s' "${TH_ROW}" | cut -f3)"
  T_HEALTHY="$(printf '%s' "${TH_ROW}" | cut -f4)"
  log "   Tablet ${T_HEALTHY}/${T_TOTAL} healthy"
  [[ "${T_TOTAL}" != "${T_HEALTHY}" ]] && warn "存在不健康副本，建议先记录当前状态再停机"
else
  warn "读不到 tablet_health 汇总行"
fi

BUSY="$(sql_remote "SHOW PROCESSLIST" | grep -c . || true)"
if [[ "${BUSY}" -gt 1 ]]; then
  warn "当前有 $((BUSY - 1)) 个活跃会话（含可能的长查询），建议先确认再停"
else
  log "   无活跃查询"
fi

RUNNING_LOAD="$(sql_remote "SHOW LOAD" | awk -F'\t' '$3 ~ /LOADING|PENDING/' | wc -l)"
[[ "${RUNNING_LOAD}" -gt 0 ]] && warn "有 ${RUNNING_LOAD} 个未完成的导入作业，停机将导致失败/重试"
echo

# ============================================================
# 阶段 2  元数据冷备（FE Master）
# ============================================================
if [[ ${DO_BACKUP} -eq 1 ]]; then
  log "阶段 2/5  元数据冷备（FE Master 的 meta 目录）"
  BK_PATH="$(node_ssh "${FE_LEADER_IP}" "echo '${NODE_SSH_PASSWORD}' | sudo -S -p '' bash -c 'mkdir -p /opt/doris/backup && tar czf /opt/doris/backup/fe-meta-${STAMP}.tar.gz -C /opt/doris/fe meta && ls -l /opt/doris/backup/fe-meta-${STAMP}.tar.gz'" | awk '{print $NF}')"
  if [[ -n "${BK_PATH}" ]]; then
    log "   远端备份: ${BK_PATH}"
    mkdir -p "${SCRIPT_DIR}/../backup"
    if sshpass -p "${NODE_SSH_PASSWORD}" scp -o StrictHostKeyChecking=no -o LogLevel=ERROR \
         "${NODE_SSH_USER}@${FE_LEADER_IP}:${BK_PATH}" "${SCRIPT_DIR}/../backup/" 2>/dev/null; then
      log "   已拉回本地: backup/$(basename "${BK_PATH}")"
    else
      warn "scp 拉回失败，备份仅留在 node 本地（宿主机重装会丢，请手动取回）"
    fi
  else
    warn "元数据备份失败，继续停机但风险自负（建议先排查 sudo/tar 权限）"
  fi
else
  log "阶段 2/5  已按 --no-backup 跳过元数据冷备"
fi
echo

if [[ ${DRY_RUN} -eq 1 ]]; then
  log "dry-run 结束：未停止任何进程。去掉 --dry-run 才会真正停机。"
  exit 0
fi

if [[ ${ASSUME_YES} -eq 0 && ${POWEROFF} -eq 1 ]]; then
  echo "即将停止全部进程并关闭 6 台操作系统。"
  read -r -p "输入 YES 确认: " ans
  [[ "${ans}" == "YES" ]] || die "已取消" 0
fi

# ============================================================
# 阶段 3  停止 BE（逐台，优雅退出）
# ============================================================
log "阶段 3/5  停止 BE（--grace / SIGTERM）"
for ip in "${BE_HOSTS[@]}"; do
  how="$(stop_component "${ip}" be)"
  log "   -> ${ip} 已发停止信号（${how}）"
  spent=0
  while [[ ${spent} -lt ${WAIT_SEC} ]]; do
    st="$(proc_alive "${ip}" /opt/doris/be/bin/be.pid)"
    [[ "${st}" != "RUNNING" ]] && break
    sleep 3; spent=$((spent + 3))
  done
  [[ "${st}" == "RUNNING" ]] && warn "${ip} BE 在 ${WAIT_SEC}s 内未退出，检查 be.out" || log "   ${ip} BE 已停止（${spent}s）"
  sleep "${INTERVAL}"
done
echo

# ============================================================
# 阶段 4  停止 FE（先 Follower，后 Master）
# ============================================================
log "阶段 4/5  停止 FE（先 Follower 后 Master）"
for ip in "${FE_FOLLOWERS[@]}" "${FE_MASTERS[@]}"; do
  how="$(stop_component "${ip}" fe)"
  log "   -> ${ip} 已发停止信号（${how}）"
  spent=0
  while [[ ${spent} -lt ${WAIT_SEC} ]]; do
    st="$(proc_alive "${ip}" /opt/doris/fe/bin/fe.pid)"
    [[ "${st}" != "RUNNING" ]] && break
    sleep 3; spent=$((spent + 3))
  done
  [[ "${st}" == "RUNNING" ]] && warn "${ip} FE 在 ${WAIT_SEC}s 内未退出，检查 fe.out" || log "   ${ip} FE 已停止（${spent}s）"
  sleep 5
done
echo

# ============================================================
# 阶段 5  残留校验 + 可选关系统
# ============================================================
log "阶段 5/5  残留进程校验"
DIRTY=0
for entry in "${ALL_NODES[@]}"; do
  IFS=':' read -r h ip role <<< "${entry}"
  if [[ "${role}" == "fe" ]]; then pidf=/opt/doris/fe/bin/fe.pid; else pidf=/opt/doris/be/bin/be.pid; fi
  st="$(proc_alive "${ip}" "${pidf}")"
  if [[ "${st}" == "RUNNING" ]]; then
    warn "${h}(${ip}) 仍有 ${role} 进程存活"; DIRTY=1
  else
    log "   ${h}(${ip}) 清理干净"
  fi
done

if [[ ${DIRTY} -eq 1 ]]; then
  warn "存在未退出进程，禁止直接关机。先看 fe.out / be.out 尾部日志，再手工 kill -TERM 后重试"
  exit 1
fi

log "全部 6 节点进程已优雅退出，可以安全关机（或执行 --poweroff）"

if [[ ${POWEROFF} -eq 1 ]]; then
  log "开始逐台 poweroff（脚本所在机最后关，留 1 分钟缓冲）"
  LOCAL_IPS=" $(hostname -I 2>/dev/null || true) "
  SELF_IP=""
  for entry in "${ALL_NODES[@]}"; do
    IFS=':' read -r h ip role <<< "${entry}"
    if [[ "${LOCAL_IPS}" == *" ${ip} "* ]]; then
      SELF_IP="${ip}"
      log "   ${h}(${ip}) 是本机，跳过（最后处理）"
      continue
    fi
    node_ssh "${ip}" "echo '${NODE_SSH_PASSWORD}' | sudo -S -p '' shutdown -h now" >/dev/null 2>&1 &
    log "   ${h}(${ip}) 已下电指令"
    sleep 3
  done
  if [[ -n "${SELF_IP}" ]]; then
    log "   本机 ${SELF_IP} 将在 1 分钟后关机（临时取消：sudo shutdown -c）"
    node_ssh "${SELF_IP}" "echo '${NODE_SSH_PASSWORD}' | sudo -S -p '' shutdown -h +1" >/dev/null 2>&1
  fi
  log "全部关机指令已发出，磁盘正在同步；1 分钟后本机最后下电，请在虚拟化平台确认状态为 Powered Off"
fi
exit 0
