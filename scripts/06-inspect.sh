#!/usr/bin/env bash
# ============================================================
# 06-inspect.sh   Doris 集群巡检（在任一 FE 节点执行，推荐 node-01）
#
# 用法:
#   ./06-inspect.sh                  巡检，Markdown 报告打印到终端
#   ./06-inspect.sh -o report.md     同时写入文件
#   ./06-inspect.sh -H 168           审计窗口改为近 7 天
#   ./06-inspect.sh -q               只打印一行摘要（适合 cron）
#   ./06-inspect.sh --no-ssh         跳过主机层采集
#
# 退出码: 0=全部正常  1=有 WARN  2=有 CRIT  9=参数/连接错误
#
# 覆盖 7 个维度 40+ 项：FE 拓扑、BE 状态、副本完整性、容量磁盘、
# 库表分区、导入任务、查询审计、主机基线、关键配置。
# 判定 OK/WARN/CRIT，CRIT 扣 15 分、WARN 扣 5 分，满分 100。
# ============================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../nodes.env" 2>/dev/null || {
  echo "[FATAL] 找不到 ${SCRIPT_DIR}/../nodes.env"; exit 9; }

HOURS=24; OUTFILE=""; QUIET=0; NO_SSH=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -H|--hours)  HOURS="${2:-24}"; shift 2 ;;
    -o|--output) OUTFILE="${2:-}"; shift 2 ;;
    -q|--quiet)  QUIET=1; shift ;;
    --no-ssh)    NO_SSH=1; shift ;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $1"; exit 9 ;;
  esac
done

# ---------- 阈值 ----------
TH_DISK_WARN=75; TH_DISK_CRIT=85
TH_JOURNAL_WARN=100; TH_JOURNAL_CRIT=1000
TH_COMPACTION_WARN=100; TH_COMPACTION_CRIT=500
TH_TRASH_PCT=10
TH_LOAD_PCT=200
TH_MEM_AVAIL_PCT=10
TH_QUERY_ERR_PCT=5
TH_CLOCK_SEC=1

# ---------- 连接 ----------
MYSQL_ARGS=(-h "${FE_LEADER_IP}" -P 9030 -uroot --connect-timeout=10 --batch --raw)
[[ -n "${MYSQL_AUTH_OPT:-}" ]] && MYSQL_ARGS+=("${MYSQL_AUTH_OPT}")
[[ -n "${MYSQL_ROOT_PASSWORD:-}" ]] && MYSQL_ARGS+=("-p${MYSQL_ROOT_PASSWORD}")

sql()  { mysql "${MYSQL_ARGS[@]}" -e "$1" 2>/dev/null; }
sqlv() { sql "$1" | tail -n +2; }
col_idx() { printf '%s' "$1" | tr '\t' '\n' | grep -nx "$2" | head -1 | cut -d: -f1; }
# fld 表头 列名 行  → 取该列值（按表头定位，避免版本间列序变化）
fld() {
  local idx; idx=$(col_idx "$1" "$2")
  [[ -z "${idx}" ]] && { echo ""; return; }
  printf '%s' "$3" | cut -f"${idx}"
}

node_ssh() {
  sshpass -p "${NODE_SSH_PASSWORD:-}" ssh -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=6 \
    "${NODE_SSH_USER:-lumz}@$1" "$2" 2>/dev/null
}

NOW="$(date '+%Y-%m-%d %H:%M:%S')"
TODAY="$(date '+%Y%m%d')"
BODY="$(mktemp /tmp/doris-inspect-body.XXXXXX)"
ALL="$(mktemp /tmp/doris-inspect-all.XXXXXX)"
trap 'rm -f "${BODY}" "${ALL}"' EXIT
emit() { printf '%s\n' "$*" >>"${BODY}"; }

declare -a CHECKS=()
add_chk() { CHECKS+=("$1|$2|$3|${4:-}"); }

sql "SELECT 1" >/dev/null || { echo "[FATAL] 连不上 ${FE_LEADER_IP}:9030"; exit 9; }

# ============================================================
# 采集：FE
# ============================================================
FE_OUT="$(sql "SHOW FRONTENDS")"
FE_HDR="$(printf '%s\n' "${FE_OUT}" | head -1)"
FE_BODY="$(printf '%s\n' "${FE_OUT}" | tail -n +2)"
[[ -z "${FE_BODY}" ]] && { echo "[FATAL] SHOW FRONTENDS 无返回"; exit 9; }

f_host=$(col_idx "${FE_HDR}" Host);       f_role=$(col_idx "${FE_HDR}" Role)
f_master=$(col_idx "${FE_HDR}" IsMaster); f_alive=$(col_idx "${FE_HDR}" Alive)
f_jrnl=$(col_idx "${FE_HDR}" ReplayedJournalId)
f_ver=$(col_idx "${FE_HDR}" Version);     f_hb=$(col_idx "${FE_HDR}" LastHeartbeat)
f_start=$(col_idx "${FE_HDR}" LastStartTime); f_cluster=$(col_idx "${FE_HDR}" ClusterId)

FE_ALIVE=$(printf '%s\n' "${FE_BODY}" | awk -F'\t' -v i="${f_alive}" '$i=="true"' | wc -l | tr -d ' ')
FE_TOTAL=$(printf '%s\n' "${FE_BODY}" | grep -c . )
FE_MASTER=$(printf '%s\n' "${FE_BODY}" | awk -F'\t' -v i="${f_master}" '$i=="true"' | wc -l | tr -d ' ')
FE_VERSION=$(printf '%s\n' "${FE_BODY}" | awk -F'\t' -v i="${f_ver}" 'NR==1{print $i}')
CLUSTER_ID=$(printf '%s\n' "${FE_BODY}" | awk -F'\t' -v i="${f_cluster}" 'NR==1{print $i}')
FE_BOOT=$(printf '%s\n' "${FE_BODY}" | awk -F'\t' -v i="${f_start}" 'NR==1{print $i}')
JRNL_MAX=$(printf '%s\n' "${FE_BODY}" | awk -F'\t' -v i="${f_jrnl}" '{print $i}' | sort -n | tail -1)

# ============================================================
# 采集：BE
# ============================================================
BE_OUT="$(sql "SHOW BACKENDS")"
BE_HDR="$(printf '%s\n' "${BE_OUT}" | head -1)"
BE_BODY="$(printf '%s\n' "${BE_OUT}" | tail -n +2)"
b_host=$(col_idx "${BE_HDR}" Host);        b_alive=$(col_idx "${BE_HDR}" Alive)
b_tablet=$(col_idx "${BE_HDR}" TabletNum); b_usedpct=$(col_idx "${BE_HDR}" UsedPct)
b_total=$(col_idx "${BE_HDR}" TotalCapacity); b_avail=$(col_idx "${BE_HDR}" AvailCapacity)
b_trash=$(col_idx "${BE_HDR}" TrashUsedCapacity)
b_hbfail=$(col_idx "${BE_HDR}" HeartbeatFailureCounter)
b_status=$(col_idx "${BE_HDR}" Status);    b_cores=$(col_idx "${BE_HDR}" CpuCores)
b_mem=$(col_idx "${BE_HDR}" Memory);       b_decom=$(col_idx "${BE_HDR}" SystemDecommissioned)

BE_ALIVE=$(printf '%s\n' "${BE_BODY}" | awk -F'\t' -v i="${b_alive}" '$i=="true"' | wc -l | tr -d ' ')
BE_TOTAL=$(printf '%s\n' "${BE_BODY}" | grep -c . )

STAT="$(sql "SHOW PROC '/statistic'" | awk -F'\t' '$1=="Total"')"
S_TABLE=$(printf '%s' "${STAT}"  | cut -f3); S_PART=$(printf '%s' "${STAT}"  | cut -f4)
S_TABLET=$(printf '%s' "${STAT}" | cut -f6); S_REPLICA=$(printf '%s' "${STAT}" | cut -f7)

# ============================================================
# 一、FE 集群
# ============================================================
emit "## 一、FE 集群"
emit ""
emit "| 节点 | 角色 | Master | Alive | Journal | 最近心跳 |"
emit "|---|---|---|---|---|---|"
printf '%s\n' "${FE_BODY}" | while IFS=$'\t' read -r -a row; do
  h="${row[$((f_host-1))]}"; r="${row[$((f_role-1))]}"
  m="${row[$((f_master-1))]}"; a="${row[$((f_alive-1))]}"
  j="${row[$((f_jrnl-1))]}"; hb="${row[$((f_hb-1))]}"
  [[ "${m}" == "true" ]] && m="**是**" || m="否"
  [[ "${a}" == "true" ]] && a="是" || a="**否**"
  emit "| ${h} | ${r} | ${m} | ${a} | ${j} | ${hb} |"
done
emit ""
emit "- 版本：\`${FE_VERSION}\`　集群 ID：\`${CLUSTER_ID}\`　首节点启动于：${FE_BOOT}"
emit ""

if [[ "${FE_ALIVE}" -eq "${FE_TOTAL}" ]]; then
  add_chk OK "FE 存活" "${FE_ALIVE}/${FE_TOTAL} 在线" ""
else
  add_chk CRIT "FE 存活" "${FE_ALIVE}/${FE_TOTAL} 在线" "立即检查失联 FE 的进程与 9010 端口；2 个 FE 存活时仍可读，但失去容灾能力"
fi
if [[ "${FE_MASTER}" -eq 1 ]]; then
  add_chk OK "Master 唯一性" "1 个 Master" ""
else
  add_chk CRIT "Master 唯一性" "${FE_MASTER} 个 Master" "选举异常：检查 FE 间 9010 连通、时钟同步、BDBJE 日志"
fi

JRNL_LAG=0
for j in $(printf '%s\n' "${FE_BODY}" | awk -F'\t' -v i="${f_jrnl}" -v m="${JRNL_MAX}" '{d=m-$i; if(d>0)print d}'); do
  [[ "${j}" -gt "${JRNL_LAG}" ]] && JRNL_LAG="${j}"
done
if [[ "${JRNL_LAG}" -le "${TH_JOURNAL_WARN}" ]]; then
  add_chk OK "元数据同步" "最大落后 ${JRNL_LAG} 条（journal ${JRNL_MAX}）" ""
elif [[ "${JRNL_LAG}" -le "${TH_JOURNAL_CRIT}" ]]; then
  add_chk WARN "元数据同步" "最大落后 ${JRNL_LAG} 条" "关注 FE 磁盘 IO；若持续增长说明 BDBJE 回放受阻"
else
  add_chk CRIT "元数据同步" "最大落后 ${JRNL_LAG} 条" "Follower 严重滞后，故障时会丢失元数据变更，需重启落后节点追平"
fi

FE_VER_UNIQ=$(printf '%s\n' "${FE_BODY}" | awk -F'\t' -v i="${f_ver}" '{print $i}' | sort -u | wc -l | tr -d ' ')
if [[ "${FE_VER_UNIQ}" -eq 1 ]]; then
  add_chk OK "FE 版本一致性" "${FE_VERSION}" ""
else
  add_chk WARN "FE 版本一致性" "存在 ${FE_VER_UNIQ} 个版本" "滚动升级未完成或混装，确认各节点二进制一致"
fi

META_DIR="${DORIS_HOME}/fe/meta"
IMG_NEW=$(ls -t "${META_DIR}"/image/image.* 2>/dev/null | head -1)
if [[ -n "${IMG_NEW}" ]]; then
  IMG_H=$(( ( $(date +%s) - $(stat -c %Y "${IMG_NEW}") ) / 3600 ))
  add_chk OK "FE 元数据 image" "$(basename "${IMG_NEW}")，${IMG_H} 小时前生成" ""
else
  add_chk WARN "FE checkpoint" "尚未生成 image（当前 journal ${JRNL_MAX} 条）" "初期部署常见：journal 未 finalize 时不触发 checkpoint。观察 24h；仍无 image 需查 leaderCheckpointer 日志与 edit_log_roll_num"
fi
if crontab -l 2>/dev/null | grep -qiE 'meta|doris.*bak'; then
  add_chk OK "元数据备份" "crontab 已配置备份" ""
else
  add_chk WARN "元数据备份" "crontab 未配置 meta_dir 备份" "meta_dir 是唯一不可再生数据，建议每日打包（见附录 C）"
fi

# ============================================================
# 二、BE 集群
# ============================================================
emit "## 二、BE 集群"
emit ""
emit "| 节点 | Alive | Tablet | 磁盘使用率 | 可用/总量 | CPU | 内存 | 心跳失败 | 状态 |"
emit "|---|---|---|---|---|---|---|---|---|"
# 注意：SHOW BACKENDS 的 ErrMsg 常为空，bash read -a 会把连续 tab 折叠导致列错位，
# 必须用 awk -F'\t' 处理（awk 保留空字段）。
BE_TBL=$(printf '%s\n' "${BE_BODY}" | awk -F'\t' \
  -v h="${b_host}" -v a="${b_alive}" -v t="${b_tablet}" -v u="${b_usedpct}" \
  -v tc="${b_total}" -v ac="${b_avail}" -v c="${b_cores}" -v m="${b_mem}" \
  -v hf="${b_hbfail}" -v st="${b_status}" '{
    flag="正常";
    if($st ~ /isQueryDisabled":true/) flag="**查询禁用**";
    if($st ~ /isLoadDisabled":true/)  flag="**导入禁用**";
    if($a!="true") flag="**离线**";
    av=($a=="true")?"是":"**否**";
    printf "| %s | %s | %s | %s | %s / %s | %s | %s | %s | %s |\n", $h, av, $t, $u, $ac, $tc, $c, $m, $hf, flag
  }')
emit "${BE_TBL}"
emit ""

if [[ "${BE_ALIVE}" -eq "${BE_TOTAL}" ]]; then
  add_chk OK "BE 存活" "${BE_ALIVE}/${BE_TOTAL} 在线" ""
else
  add_chk CRIT "BE 存活" "${BE_ALIVE}/${BE_TOTAL} 在线" "查 be.WARNING 与 9050/9060 连通；副本会自动补齐但期间写入降级"
fi

BE_DISABLED=$(printf '%s\n' "${BE_BODY}" | awk -F'\t' -v i="${b_status}" '$i ~ /isQueryDisabled":true|isLoadDisabled":true/' | wc -l | tr -d ' ')
DECOM=$(printf '%s\n' "${BE_BODY}" | awk -F'\t' -v i="${b_decom}" '$i=="true"' | wc -l | tr -d ' ')
if [[ "${BE_DISABLED}" -eq 0 && "${DECOM}" -eq 0 ]]; then
  add_chk OK "BE 服务状态" "无禁用/下线中节点" ""
else
  add_chk WARN "BE 服务状态" "禁用 ${BE_DISABLED} 台，下线中 ${DECOM} 台" "确认是否人为操作；非预期需查坏盘与内存水位"
fi

HB_FAIL=$(printf '%s\n' "${BE_BODY}" | awk -F'\t' -v i="${b_hbfail}" '{print $i}' | sort -n | tail -1)
HB_FAIL="${HB_FAIL:-0}"
if [[ "${HB_FAIL}" -eq 0 ]]; then
  add_chk OK "BE 心跳" "失败计数全为 0" ""
elif [[ "${HB_FAIL}" -lt 10 ]]; then
  add_chk WARN "BE 心跳" "最大失败 ${HB_FAIL} 次" "偶发抖动，观察网络丢包与 FE 负载"
else
  add_chk CRIT "BE 心跳" "最大失败 ${HB_FAIL} 次" "心跳失败会导致 node unavailable，查网络与 FE GC 停顿"
fi

T_MIN=$(printf '%s\n' "${BE_BODY}" | awk -F'\t' -v i="${b_tablet}" '{print $i}' | sort -n | head -1)
T_MAX=$(printf '%s\n' "${BE_BODY}" | awk -F'\t' -v i="${b_tablet}" '{print $i}' | sort -n | tail -1)
T_MIN="${T_MIN:-0}"; T_MAX="${T_MAX:-0}"
T_DIFF=$(( T_MAX - T_MIN ))
if [[ "${T_MAX}" -gt 0 ]] && [[ $(( T_DIFF * 100 / T_MAX )) -le 10 ]]; then
  add_chk OK "Tablet 均衡" "${T_MIN}~${T_MAX} 个/节点，偏差 ${T_DIFF}" ""
else
  add_chk WARN "Tablet 均衡" "${T_MIN}~${T_MAX} 个/节点，偏差 ${T_DIFF}" "偏差 >10%：等均衡调度，或扩缩容后手工触发均衡"
fi
emit ""

# ============================================================
# 三、副本与 Tablet 健康
# ============================================================
emit "## 三、副本与 Tablet 健康"
emit ""
HEALTH="$(sql "SHOW PROC '/cluster_health/tablet_health'" | awk -F'\t' '$1=="Total"')"
if [[ -n "${HEALTH}" ]]; then
  IFS=$'\t' read -r -a hr <<<"${HEALTH}"
  H_TABLET="${hr[2]:-0}"; H_OK="${hr[3]:-0}"
  H_MISS="${hr[4]:-0}";   H_VERINC="${hr[5]:-0}"; H_RELOC="${hr[6]:-0}"
  H_REDUN="${hr[7]:-0}";  H_TAGMISS="${hr[8]:-0}"; H_FORCE="${hr[9]:-0}"
  H_REPAIR="${hr[12]:-0}"; H_UNREC="${hr[13]:-0}"; H_CSLOW="${hr[14]:-0}"
  H_INCONS="${hr[15]:-0}"; H_OVER="${hr[16]:-0}";  H_CLONE="${hr[17]:-0}"

  emit "| 指标 | 数量 | 判定 |"
  emit "|---|---|---|"
  emit "| Tablet 总数 | ${H_TABLET} | — |"
  emit "| 副本完整 | ${H_OK} | $([[ "${H_OK}" == "${H_TABLET}" ]] && echo 正常 || echo **异常**) |"
  emit "| 副本缺失 | ${H_MISS} | $([[ "${H_MISS}" -gt 0 ]] && echo **异常** || echo 正常) |"
  emit "| 版本不完整 | ${H_VERINC} | $([[ "${H_VERINC}" -gt 0 ]] && echo **异常** || echo 正常) |"
  emit "| 副本迁移中 | ${H_RELOC} | $([[ "${H_RELOC}" -gt 5 ]] && echo 观察 || echo 正常) |"
  emit "| 冗余副本 | ${H_REDUN} | $([[ "${H_REDUN}" -gt 0 ]] && echo 观察 || echo 正常) |"
  emit "| 待进一步修复 | ${H_REPAIR} | $([[ "${H_REPAIR}" -gt 0 ]] && echo **异常** || echo 正常) |"
  emit "| 不可恢复 | ${H_UNREC} | $([[ "${H_UNREC}" -gt 0 ]] && echo **异常** || echo 正常) |"
  emit "| compaction 过慢 | ${H_CSLOW} | $([[ "${H_CSLOW}" -gt 0 ]] && echo 观察 || echo 正常) |"
  emit "| 副本不一致 | ${H_INCONS} | $([[ "${H_INCONS}" -gt 0 ]] && echo **异常** || echo 正常) |"
  emit "| 单副本超限 | ${H_OVER} | $([[ "${H_OVER}" -gt 0 ]] && echo 观察 || echo 正常) |"
  emit "| 正在克隆 | ${H_CLONE} | $([[ "${H_CLONE}" -gt 0 ]] && echo 观察 || echo 正常) |"
  emit ""

  BAD=$(( H_MISS + H_VERINC + H_UNREC + H_INCONS + H_TAGMISS + H_REPAIR ))
  if [[ "${BAD}" -eq 0 ]]; then
    add_chk OK "副本完整性" "${H_TABLET} 个 tablet 全部健康" ""
  else
    add_chk CRIT "副本完整性" "${BAD} 个异常副本（缺失 ${H_MISS}/版本不全 ${H_VERINC}/不可恢复 ${H_UNREC}/不一致 ${H_INCONS}）" \
      "用 SHOW REPLICA STATUS FROM db.tbl 定位，必要时 ADMIN REPAIR TABLE / 加 BE 让副本重建"
  fi
  if [[ "${H_REDUN}" -gt 0 ]]; then
    add_chk WARN "冗余副本" "${H_REDUN} 个" "多为调小副本数或缩容遗留，FE 会自动回收；持续存在说明回收线程受阻"
  else
    add_chk OK "冗余副本" "0 个" ""
  fi
  if [[ "${H_CLONE}" -gt 0 || "${H_RELOC}" -gt 0 ]]; then
    add_chk WARN "副本调度" "克隆中 ${H_CLONE}，迁移中 ${H_RELOC}" "正常修复过程；若长时间不动说明 BE 间 8060 带宽不足"
  else
    add_chk OK "副本调度" "无克隆/迁移任务" ""
  fi
else
  add_chk WARN "副本健康视图" "tablet_health 无 Total 行" "确认 FE 版本支持该视图"
  emit "_副本健康视图不可用_"
  emit ""
fi
if [[ "${S_TABLET:-0}" -gt 0 ]]; then
  add_chk OK "副本倍数" "${S_TABLET} tablet → ${S_REPLICA} 副本" ""
fi

# ============================================================
# 四、容量与磁盘
# ============================================================
emit "## 四、容量与磁盘"
emit ""
to_gb() { awk '{v=$1+0; u=$2; if(u=="TB")v*=1024; else if(u=="MB")v/=1024; else if(u=="KB")v/=1048576; else if(u=="B")v/=1073741824; printf "%.2f", v}'; }
b_dataused=$(col_idx "${BE_HDR}" DataUsedCapacity)
read -r CAP_TOTAL CAP_AVAIL CAP_TRASH CAP_DATA < <(printf '%s\n' "${BE_BODY}" | awk -F'\t' \
  -v t="${b_total}" -v a="${b_avail}" -v r="${b_trash}" -v d="${b_dataused}" '
  function gb(s,   p,n,u){ split(s,p," "); n=p[1]+0; u=p[2];
    if(u=="TB")n*=1024; else if(u=="MB")n/=1024; else if(u=="KB")n/=1048576; else if(u=="B")n/=1073741824; return n }
  { T+=gb($t); A+=gb($a); R+=gb($r); D+=gb($d) }
  END{ printf "%.2f %.2f %.2f %.6f\n", T, A, R, D }')

CAP_USED=$(awk -v t="${CAP_TOTAL}" -v a="${CAP_AVAIL}" 'BEGIN{printf "%.2f", t-a}')
CAP_PCT=$(awk -v t="${CAP_TOTAL}" -v u="${CAP_USED}" 'BEGIN{if(t>0)printf "%.1f",u/t*100;else print 0}')
TRASH_PCT=$(awk -v t="${CAP_TOTAL}" -v u="${CAP_TRASH}" 'BEGIN{if(t>0)printf "%.1f",u/t*100;else print 0}')
USABLE=$(awk -v a="${CAP_AVAIL}" 'BEGIN{printf "%.0f", a/3}')
DISK_MAX=$(printf '%s\n' "${BE_BODY}" | awk -F'\t' -v i="${b_usedpct}" '{gsub(/[ %]/,"",$i); print $i}' | sort -n | tail -1)
DISK_MAX="${DISK_MAX:-0}"

emit "| 项 | 数值 |"
emit "|---|---|"
emit "| BE 裸容量合计 | ${CAP_TOTAL} GB |"
emit "| Doris 数据文件占用 | $(awk -v d="${CAP_DATA}" 'BEGIN{if(d<0.01) printf "%.0f KB", d*1048576; else if(d<1) printf "%.0f MB", d*1024; else printf "%.2f GB", d}') |"
emit "| 文件系统已用 / 可用 | ${CAP_USED} GB / ${CAP_AVAIL} GB |"
emit "| 集群使用率 | **${CAP_PCT}%** |"
emit "| Trash 占用 | ${CAP_TRASH} GB（${TRASH_PCT}%） |"
emit "| 3 副本下可写 | ≈ ${USABLE} GB（压缩后） |"
emit "| 数据对象 | ${S_TABLET} tablet / ${S_REPLICA} 副本 |"
emit ""

if [[ "${DISK_MAX%.*}" -ge "${TH_DISK_CRIT}" ]]; then
  add_chk CRIT "BE 磁盘水位" "最高 ${DISK_MAX}%（CRIT 线 ${TH_DISK_CRIT}%）" "立即扩容或清理：到 90% 会自动拒写且无法修复副本"
elif [[ "${DISK_MAX%.*}" -ge "${TH_DISK_WARN}" ]]; then
  add_chk WARN "BE 磁盘水位" "最高 ${DISK_MAX}%（WARN 线 ${TH_DISK_WARN}%）" "规划扩容；加盘时内存要同步加（内存:盘 ≈ 1:20~30）"
else
  add_chk OK "BE 磁盘水位" "最高 ${DISK_MAX}%，距告警线 $(( TH_DISK_WARN - ${DISK_MAX%.*} )) 个百分点" ""
fi

# compaction score 需要访问 BE 8040
CMAX=0
if [[ ${NO_SSH} -eq 0 ]] && command -v sshpass >/dev/null 2>&1; then
  for item in "${ALL_NODES[@]}"; do
    [[ "$(printf '%s' "${item}" | cut -d: -f3)" == "be" ]] || continue
    ip=$(printf '%s' "${item}" | cut -d: -f2)
    v=$(node_ssh "${ip}" "curl -s --max-time 5 http://127.0.0.1:8040/metrics | awk '/^doris_be_disks_compaction_score/{print \$2}' | sort -n | tail -1")
    v="${v:-0}"; v="${v%.*}"
    [[ "${v:-0}" -gt "${CMAX}" ]] && CMAX="${v}"
  done
fi
if [[ ${CMAX} -ge ${TH_COMPACTION_CRIT} ]]; then
  add_chk CRIT "Compaction 压力" "最大 score ${CMAX}" "已严重积压，查询与写入都会变慢；查 compaction 内存限制与导入频率"
elif [[ ${CMAX} -ge ${TH_COMPACTION_WARN} ]]; then
  add_chk WARN "Compaction 压力" "最大 score ${CMAX}" "关注是否持续升高；可调大 compaction_max_memory_limit_percent"
else
  add_chk OK "Compaction 压力" "最大 score ${CMAX}" ""
fi
if [[ "${TRASH_PCT%.*}" -ge "${TH_TRASH_PCT}" ]]; then
  add_chk WARN "Trash 占用" "${TRASH_PCT}%" "trash 保留 1 天；占比高说明近期频繁删表或导入失败"
else
  add_chk OK "Trash 占用" "${TRASH_PCT}%" ""
fi
emit ""

# ============================================================
# 五、库表与分区
# ============================================================
emit "## 五、库表与分区"
emit ""
emit "| 库 | 表数 | 大小 | 副本数 | Running Txn | LastUpdate |"
emit "|---|---|---|---|---|---|"
DBS_OUT="$(sqlv "SHOW PROC '/dbs'")"
printf '%s\n' "${DBS_OUT}" | awk -F'\t' '$2!="information_schema" && $2!="mysql"{printf "%s\t%s\t%s\t%s\t%s\t%s\n",$2,$3,$4,$7,$9,$10}' \
  | while IFS=$'\t' read -r db tn sz rp tx lu; do
      emit "| ${db} | ${tn} | ${sz} | ${rp} | ${tx} | ${lu} |"
    done
emit ""
emit "> 合计：**${S_TABLE}** 张表 / **${S_PART}** 个分区 / **${S_TABLET}** tablet / **${S_REPLICA}** 副本（含 \`__internal_schema\` 内部表）"
emit ""

USER_DBS=$(sqlv "SHOW DATABASES" | grep -vE '^(information_schema|__internal_schema|mysql|sys)$')
DYN_TOTAL=0; DYN_BAD=0; DYN_ROWS=""
for db in ${USER_DBS}; do
  dh="$(sql "SHOW DYNAMIC PARTITION TABLES FROM \`${db}\`" | head -1)"
  dbody="$(sqlv "SHOW DYNAMIC PARTITION TABLES FROM \`${db}\`")"
  [[ -z "${dbody}" ]] && continue
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    tname=$(fld "${dh}" TableName "${line}")
    state=$(fld "${dh}" State "${line}")
    lastrun=$(fld "${dh}" LastSchedulerTime "${line}")
    DYN_TOTAL=$((DYN_TOTAL+1))
    [[ "${state}" != "NORMAL" ]] && DYN_BAD=$((DYN_BAD+1))
    DYN_ROWS+="| ${db}.${tname} | ${state} | ${lastrun} |"$'\n'
  done <<<"${dbody}"
done
if [[ "${DYN_TOTAL}" -gt 0 ]]; then
  emit "**动态分区表调度**（${DYN_TOTAL} 张）"
  emit ""
  emit "| 表 | 调度状态 | 最近调度时间 |"
  emit "|---|---|---|"
  while IFS= read -r l; do [[ -n "${l}" ]] && emit "${l}"; done <<<"${DYN_ROWS}"
  emit ""
  if [[ "${DYN_BAD}" -eq 0 ]]; then
    add_chk OK "动态分区调度" "${DYN_TOTAL} 张表全部 NORMAL" ""
  else
    add_chk WARN "动态分区调度" "${DYN_BAD}/${DYN_TOTAL} 张异常" "检查 dynamic_partition_check_interval_seconds（默认 600s）与 FE 调度线程"
  fi
else
  add_chk OK "动态分区调度" "无动态分区表" ""
fi

# ============================================================
# 六、导入任务
# ============================================================
emit "## 六、导入任务"
emit ""
LOAD_ALL="$(sql "SHOW LOAD")"
if [[ -n "$(printf '%s\n' "${LOAD_ALL}" | tail -n +2)" ]]; then
  LH="$(printf '%s\n' "${LOAD_ALL}" | head -1)"
  LB="$(printf '%s\n' "${LOAD_ALL}" | tail -n +2 | head -20)"
  L_TOTAL=$(printf '%s\n' "${LB}" | grep -c . )
  L_CANCEL=0
  while IFS= read -r line; do
    [[ "$(fld "${LH}" State "${line}")" == "CANCELLED" ]] && L_CANCEL=$((L_CANCEL+1))
  done <<<"${LB}"
  emit "近期 Load 任务 ${L_TOTAL} 条，CANCELLED ${L_CANCEL} 条。"
  if [[ "${L_CANCEL}" -gt 0 ]]; then
    emit ""
    emit "| JobId | Label | 错误信息 |"
    emit "|---|---|---|"
    while IFS= read -r line; do
      [[ "$(fld "${LH}" State "${line}")" == "CANCELLED" ]] || continue
      emit "| $(fld "${LH}" JobId "${line}") | $(fld "${LH}" Label "${line}") | $(fld "${LH}" ErrorMsg "${line}" | cut -c1-90) |"
    done <<<"${LB}"
    add_chk WARN "导入任务" "${L_CANCEL}/${L_TOTAL} 条 CANCELLED" "按 ErrorMsg 定位：多为 schema 不匹配、内存超限、版本冲突"
  else
    add_chk OK "导入任务" "${L_TOTAL} 条任务无失败" ""
  fi
else
  emit "无 Load 历史（尚未发起 Broker/Stream Load）。"
  add_chk OK "导入任务" "无失败记录" ""
fi

ROUTINE="$(sqlv "SHOW ROUTINE LOAD")"
if [[ -n "${ROUTINE}" ]]; then
  R_BAD=$(printf '%s\n' "${ROUTINE}" | grep -cE 'PAUSED|STOPPED')
  emit ""
  emit "Routine Load 作业 $(printf '%s\n' "${ROUTINE}" | grep -c .) 个，非 RUNNING ${R_BAD} 个。"
  if [[ "${R_BAD}" -gt 0 ]]; then
    add_chk WARN "Routine Load" "${R_BAD} 个作业暂停/停止" "查 Kafka 连通性与 SHOW ROUTINE LOAD 的 ErrorLogUrls"
  else
    add_chk OK "Routine Load" "全部 RUNNING" ""
  fi
else
  add_chk OK "Routine Load" "未配置常驻作业" ""
fi
emit ""

# ============================================================
# 七、查询负载与审计
# ============================================================
emit "## 七、查询负载与审计"
emit ""
CONN=$(sqlv "SELECT COUNT(*) FROM information_schema.processlist" | head -1)
emit "| 指标 | 数值 |"
emit "|---|---|"
emit "| 当前连接数 | ${CONN:-0} |"

AUDIT_F="${DORIS_HOME}/fe/log/fe.audit.log"
SINCE=$(date -d "-${HOURS} hours" '+%Y-%m-%d %H:%M:%S')
if [[ -r "${AUDIT_F}" ]]; then
  TMP_T="$(mktemp)"
  awk -F'|' -v since="${SINCE}" '
    /\[query\]/ {
      ts=substr($1,1,19); if (ts < since) next;
      t=-1
      for(i=1;i<=NF;i++) if($i ~ /^Time\(ms\)=/){ split($i,a,"="); t=a[2]+0 }
      if(t>=0) print t
    }' "${AUDIT_F}" >"${TMP_T}"
  Q_TOTAL=$(grep -c . "${TMP_T}")
  Q_TOTAL="${Q_TOTAL:-0}"
  if [[ "${Q_TOTAL}" -gt 0 ]]; then
    sort -n "${TMP_T}" -o "${TMP_T}"
    Q_SUM=$(awk '{s+=$1} END{printf "%.0f", s+0}' "${TMP_T}")
    Q_AVG=$(( Q_SUM / Q_TOTAL ))
    P50=$(awk -v n="${Q_TOTAL}" 'NR==int(n*0.5)+1{print; exit}' "${TMP_T}")
    P95=$(awk -v n="${Q_TOTAL}" 'NR==int(n*0.95)+1{print; exit}' "${TMP_T}")
    PMAX=$(tail -1 "${TMP_T}")
    SLOW=$(awk '$1>=1000' "${TMP_T}" | wc -l | tr -d ' ')
    QPS=$(awk -v c="${Q_TOTAL}" -v h="${HOURS}" 'BEGIN{printf "%.3f", c/(h*3600)}')
    emit "| 近 ${HOURS}h 查询数 | ${Q_TOTAL} |"
    emit "| 平均耗时 | ${Q_AVG} ms |"
    emit "| P50 / P95 | ${P50} ms / ${P95} ms |"
    emit "| 最慢查询 | ${PMAX} ms |"
    emit "| 超过 1s | ${SLOW} 条（$(awk -v s="${SLOW}" -v t="${Q_TOTAL}" 'BEGIN{printf "%.1f", s/t*100}')%） |"
    emit "| 平均 QPS | ${QPS} |"

    ERR_STAT=$(awk -F'|' -v since="${SINCE}" '
      /\[query\]/ {
        ts=substr($1,1,19); if(ts<since) next;
        ec=0; msg=""
        for(i=1;i<=NF;i++){
          if($i ~ /^ErrorCode=/){ split($i,b,"="); ec=b[2]+0 }
          if($i ~ /^ErrorMessage=/){ msg=substr($i,14) }
        }
        if(ec!=0){
          n++; if(first=="") first=ts; last=ts;
          if(msg=="") msg="(服务端未返回错误信息)"
          cnt[ec SUBSEP msg]++
        }
      }
      END{
        printf "COUNT\t%d\n", n+0
        printf "RANGE\t%s ~ %s\n", first, last
        for(k in cnt){ split(k,p,SUBSEP); printf "TOP\t%d\t%s\t%s\n", cnt[k], p[1], p[2] }
      }' "${AUDIT_F}")
    Q_ERR=$(printf '%s\n' "${ERR_STAT}" | awk -F'\t' '$1=="COUNT"{print $2}')
    Q_ERR="${Q_ERR:-0}"
    ERR_RANGE=$(printf '%s\n' "${ERR_STAT}" | awk -F'\t' '$1=="RANGE"{print $2}')
    ERR_TOP=$(printf '%s\n' "${ERR_STAT}" | awk -F'\t' '$1=="TOP"' | sort -t$'\t' -k2 -rn | head -3)
    ERR_PCT=$(awk -v e="${Q_ERR}" -v t="${Q_TOTAL}" 'BEGIN{printf "%.2f", e/t*100}')
    emit "| 失败查询 | ${Q_ERR} 条（${ERR_PCT}%） |"
    emit ""
    if [[ "${Q_ERR}" -gt 0 ]]; then
      emit "**失败查询明细**（发生时段：${ERR_RANGE}）"
      emit ""
      emit "| 次数 | ErrorCode | 错误信息 |"
      emit "|---|---|---|"
      while IFS=$'\t' read -r tag c code msg; do
        [[ -z "${c}" ]] && continue
        emit "| ${c} | ${code} | $(printf '%s' "${msg}" | cut -c1-110) |"
      done <<<"${ERR_TOP}"
      emit ""
    fi
    if awk -v p="${ERR_PCT}" -v th="${TH_QUERY_ERR_PCT}" 'BEGIN{exit !(p>=th)}'; then
      add_chk WARN "查询失败率" "${ERR_PCT}%（阈值 ${TH_QUERY_ERR_PCT}%）" "看 Top 错误：内存超限居多，需降并发或扩 BE 内存"
    else
      add_chk OK "查询失败率" "${ERR_PCT}%（${Q_ERR}/${Q_TOTAL}）" ""
    fi
    if [[ "${P95}" -gt 3000 ]]; then
      add_chk WARN "查询延迟" "P95 ${P95} ms，最慢 ${PMAX} ms" "查 compaction 积压与分桶数是否过少"
    else
      add_chk OK "查询延迟" "P95 ${P95} ms，最慢 ${PMAX} ms" ""
    fi
  else
    emit "| 近 ${HOURS}h 查询数 | 0（窗口内无业务查询） |"
    add_chk OK "查询负载" "窗口内无查询" ""
  fi
  rm -f "${TMP_T}"
else
  emit "| 审计日志 | 不可读（${AUDIT_F}） |"
  add_chk WARN "审计日志" "无法读取 fe.audit.log" "确认 audit 插件开启且当前用户有读权限"
fi
emit ""

# ============================================================
# 八、主机系统层
# ============================================================
emit "## 八、主机系统层"
emit ""
if [[ ${NO_SSH} -eq 0 ]] && command -v sshpass >/dev/null 2>&1; then
  emit "| 节点 | 角色 | Load(1m) | 核 | 负载比 | 内存可用 | Swap | 时钟偏差 | 根盘 | 进程 RSS | 日志 ERROR |"
  emit "|---|---|---|---|---|---|---|---|---|---|---|"
  CLOCK_MAX=0; LOAD_MAX=0; MEM_MIN=100; SWAP_ON=""
  for item in "${ALL_NODES[@]}"; do
    host=$(printf '%s' "${item}" | cut -d: -f1)
    ip=$(printf '%s' "${item}" | cut -d: -f2)
    role=$(printf '%s' "${item}" | cut -d: -f3)
    raw=$(node_ssh "${ip}" 'echo "LOAD=$(awk "{print \$1}" /proc/loadavg)"; echo "CORES=$(nproc)"; echo "MEMTOT=$(free -m | awk "/^Mem:/{print \$2}")"; echo "MEMAVAIL=$(free -m | awk "/^Mem:/{print \$7}")"; echo "SWAP=$(free -m | awk "/^Swap:/{print \$2}")"; echo "ROOT=$(df -h / | awk "NR==2{print \$5}")"; echo "CLOCK=$(chronyc tracking 2>/dev/null | awk "/System time/{print \$4}")"; if pgrep -x doris_be >/dev/null; then echo "RSS=$(ps -eo comm,rss | awk "/^doris_be/{s+=\$2} END{printf \"%.1f\", s/1048576}")"; else echo "RSS=$(ps -eo comm,rss | awk "/^java/{s+=\$2} END{printf \"%.1f\", s/1048576}")"; fi')
    if [[ -z "${raw}" ]]; then
      emit "| ${host} | ${role} | **采集失败** | | | | | | | | |"
      continue
    fi
    LOAD=""; CORES=""; MEMTOT=""; MEMAVAIL=""; SWAP=""; ROOT=""; CLOCK=""; RSS=""
    eval "$(printf '%s\n' "${raw}" | grep -E '^[A-Z]+=')"
    LOAD="${LOAD:-0}"; CORES="${CORES:-1}"; MEMTOT="${MEMTOT:-0}"; MEMAVAIL="${MEMAVAIL:-0}"
    SWAP="${SWAP:-0}"; ROOT="${ROOT:-?}"; RSS="${RSS:-?}"
    [[ -z "${CLOCK}" ]] && CLOCK="0"
    mempct=$(awk -v a="${MEMAVAIL}" -v t="${MEMTOT}" 'BEGIN{if(t>0)printf "%.0f",a/t*100;else print 0}')
    loadpct=$(awk -v l="${LOAD}" -v c="${CORES}" 'BEGIN{if(c>0)printf "%.0f",l/c*100;else print 0}')
    clockabs=$(awk -v c="${CLOCK}" 'BEGIN{v=c+0;if(v<0)v=-v;printf "%.3f",v}')
    # BE 日志需 root，单独一次 sudo
    LOGERR="NA"
    if [[ "${role}" == "be" ]]; then
      LOGERR=$(node_ssh "${ip}" "echo ${NODE_SSH_PASSWORD:-} | sudo -S sh -c 'tail -n 3000 /opt/doris/be/log/be.WARNING 2>/dev/null | grep -cE \"^E[0-9]{4}\"' 2>/dev/null" | tr -d '\r')
    else
      LOGERR=$(node_ssh "${ip}" "grep -c ' ERROR ' /opt/doris/fe/log/fe.log 2>/dev/null")
    fi
    LOGERR="${LOGERR:-NA}"
    emit "| ${host} | ${role} | ${LOAD} | ${CORES} | ${loadpct}% | ${MEMAVAIL}M/${MEMTOT}M (${mempct}%) | ${SWAP}M | ${clockabs}s | ${ROOT} | ${RSS}G | ${LOGERR} |"
    awk -v a="${clockabs}" -v b="${CLOCK_MAX}" 'BEGIN{exit !(a>b)}' && CLOCK_MAX="${clockabs}"
    awk -v a="${loadpct}"  -v b="${LOAD_MAX}"  'BEGIN{exit !(a>b)}' && LOAD_MAX="${loadpct}"
    awk -v a="${mempct}"   -v b="${MEM_MIN}"   'BEGIN{exit !(a<b)}' && MEM_MIN="${mempct}"
    [[ "${SWAP}" -gt 0 ]] && SWAP_ON="${SWAP_ON}${host} "
  done
  emit ""

  if awk -v c="${CLOCK_MAX}" -v th="${TH_CLOCK_SEC}" 'BEGIN{exit !(c>th)}'; then
    add_chk CRIT "时钟同步" "最大偏差 ${CLOCK_MAX}s" "FE 选举与 BE 心跳强依赖时钟，立即检查 chrony"
  else
    add_chk OK "时钟同步" "最大偏差 ${CLOCK_MAX}s" ""
  fi
  if [[ "${LOAD_MAX}" -ge "${TH_LOAD_PCT}" ]]; then
    add_chk WARN "CPU 负载" "最高 ${LOAD_MAX}% 核数" "负载超 2 倍核数，查大查询与 compaction 高峰"
  else
    add_chk OK "CPU 负载" "最高 ${LOAD_MAX}% 核数" ""
  fi
  if [[ "${MEM_MIN}" -lt "${TH_MEM_AVAIL_PCT}" ]]; then
    add_chk WARN "内存余量" "最低可用 ${MEM_MIN}%" "BE 内存吃紧会触发 Memory limit exceeded，需降并发或扩内存"
  else
    add_chk OK "内存余量" "最低可用 ${MEM_MIN}%" ""
  fi
  if [[ -n "${SWAP_ON}" ]]; then
    add_chk WARN "Swap 状态" "仍启用：${SWAP_ON}" "swap 会导致 BE 假死，swapoff -a 并注释 fstab"
  else
    add_chk OK "Swap 状态" "全部节点已关闭" ""
  fi
  emit "> 日志 ERROR 为最近 3000 行（BE）与全文件（FE）的累计计数，用于发现趋势，不作为告警阈值。"
else
  emit "_已跳过（--no-ssh 或缺少 sshpass）_"
  emit ""
fi
emit ""

# ============================================================
# 九、关键配置核对
# ============================================================
emit "## 九、关键配置核对"
emit ""
FECFG="$(sql "ADMIN SHOW FRONTEND CONFIG")"
BECFG="$(sql "ADMIN SHOW BACKEND CONFIG")"
emit "| 层 | 参数 | 基线期望 | 实际值 | 判定 |"
emit "|---|---|---|---|---|"
CFG_BAD=0; CFG_MISSING=0; CFG_OK=0; MISS_LIST=""
check_fe() {
  local k="$1" exp="$2" v mark="符合"
  v=$(printf '%s\n' "${FECFG}" | awk -F'\t' -v k="${k}" '$1==k{print $2; exit}')
  if [[ -z "${v}" ]]; then
    mark="**不存在**"; CFG_MISSING=$((CFG_MISSING+1)); MISS_LIST+="${k}（FE） "
  elif [[ "${v}" != "${exp}" ]]; then
    mark="**偏离**"; CFG_BAD=$((CFG_BAD+1))
  else
    CFG_OK=$((CFG_OK+1))
  fi
  emit "| FE | \`${k}\` | ${exp} | ${v:-—} | ${mark} |"
}
check_be() {
  local k="$1" exp="$2" v mark="符合"
  v=$(printf '%s\n' "${BECFG}" | awk -F'\t' -v k="${k}" '$3==k{print $4}' | sort -u | paste -sd, -)
  if [[ -z "${v}" ]]; then
    mark="**不存在**"; CFG_MISSING=$((CFG_MISSING+1)); MISS_LIST+="${k}（BE） "
  elif [[ "${v}" != "${exp}" ]]; then
    mark="**偏离**"; CFG_BAD=$((CFG_BAD+1))
  else
    CFG_OK=$((CFG_OK+1))
  fi
  emit "| BE | \`${k}\` | ${exp} | ${v:-—} | ${mark} |"
}
# 注：以下键名已按 Doris 4.0.8 校准 —— 4.x 移除了 max_query_concurrency、
# streaming_load_max_mb 不在 FE、compaction 内存改用字节值。旧键会被静默忽略。
check_fe query_port 9030
check_fe http_port 8030
check_fe edit_log_port 9010
check_fe priority_networks "${NET_PREFIX}"
check_fe qe_max_connection 1024
check_be mem_limit 80%
check_be write_buffer_size 104857600
check_be load_process_max_memory_limit_percent 30
check_be compaction_memory_bytes_limit 6442450944
check_be streaming_load_max_mb 2048
check_be be_port 9060
check_be heartbeat_service_port 9050
check_be storage_root_path "/data1/doris,medium:ssd;/data2/doris,medium:ssd"

# 4.x 的查询并发由 Workload Group 控制，单独检查
WG_ROW="$(sql "SHOW WORKLOAD GROUPS" | awk -F'\t' '$2=="normal"')"
WG_MAX=$(printf '%s' "${WG_ROW}" | cut -f7)
WG_MAX="${WG_MAX:-—}"
WG_MARK="符合"
if [[ "${WG_MAX}" =~ ^[0-9]+$ ]] && [[ "${WG_MAX}" -gt 32 ]]; then WG_MARK="**未限制**"; fi
emit "| 运行态 | \`normal.max_concurrency\` | 建议 ≤32（4C FE） | ${WG_MAX} | ${WG_MARK} |"
emit ""
emit "> 取的是**运行时生效值**（ADMIN SHOW CONFIG），不是配置文件内容。"
emit "> 「不存在」= 该参数在当前版本已被移除或属于其他组件（会被静默忽略，配置不生效）；"
emit "> 「偏离」= 参数存在但值与调优基线不同（多为改了 conf 未重启加载）。"
emit ""
if [[ "${CFG_MISSING}" -gt 0 ]]; then
  add_chk WARN "调优参数生效性" "${CFG_MISSING} 项参数在 4.0.8 中不存在：${MISS_LIST}" \
    "这些键会被静默忽略。并发用 Workload Group 控制；streaming_load_max_mb 属 BE；compaction 内存用 compaction_memory_bytes_limit（字节）"
fi
if [[ "${CFG_BAD}" -gt 0 ]]; then
  add_chk WARN "调优参数一致性" "${CFG_BAD} 项与基线不一致" "对比 conf/ 模板；若模板已更新，需重启对应组件才生效"
fi
if [[ "${CFG_MISSING}" -eq 0 && "${CFG_BAD}" -eq 0 ]]; then
  add_chk OK "关键参数" "${CFG_OK} 项运行时配置符合基线" ""
fi
if [[ "${WG_MARK}" != "符合" ]]; then
  add_chk WARN "查询并发限制" "Workload Group normal 未限制并发（${WG_MAX}）" "4C FE 建议 ALTER WORKLOAD GROUP normal PROPERTIES (\"max_concurrency\"=\"32\")"
else
  add_chk OK "查询并发限制" "normal.max_concurrency=${WG_MAX}" ""
fi

# ============================================================
# 汇总与组装
# ============================================================
CRIT=0; WARN=0; OKN=0
for c in "${CHECKS[@]}"; do
  case "${c%%|*}" in
    CRIT) CRIT=$((CRIT+1)) ;;
    WARN) WARN=$((WARN+1)) ;;
    OK)   OKN=$((OKN+1)) ;;
  esac
done
SCORE=$(( 100 - CRIT*15 - WARN*5 )); [[ ${SCORE} -lt 0 ]] && SCORE=0
if   [[ ${SCORE} -ge 90 ]]; then GRADE="优秀"
elif [[ ${SCORE} -ge 75 ]]; then GRADE="良好"
elif [[ ${SCORE} -ge 60 ]]; then GRADE="需关注"
else GRADE="风险"; fi
TOTAL_CHK=$(( OKN + WARN + CRIT ))

{
  printf '# Doris 集群巡检报告\n\n'
  printf '| 元信息 | 值 |\n|---|---|\n'
  printf '| 巡检时间 | %s |\n' "${NOW}"
  printf '| 集群 ID | `%s` |\n' "${CLUSTER_ID}"
  printf '| Doris 版本 | %s |\n' "${FE_VERSION}"
  printf '| 集群规模 | FE %s 节点 / BE %s 节点 |\n' "${FE_TOTAL}" "${BE_TOTAL}"
  printf '| 执行节点 | %s（%s） |\n' "$(hostname)" "${FE_LEADER_IP}"
  printf '| 统计窗口 | 近 %s 小时 |\n' "${HOURS}"
  printf '| 巡检脚本 | `scripts/06-inspect.sh` |\n\n'

  printf '## 巡检结论\n\n'
  printf '| 健康度评分 | 检查项 | 正常 | 警告 | 严重 |\n|---|---|---|---|---|\n'
  printf '| **%s/100（%s）** | %s | %s | %s | %s |\n\n' "${SCORE}" "${GRADE}" "${TOTAL_CHK}" "${OKN}" "${WARN}" "${CRIT}"
  if [[ ${CRIT} -gt 0 ]]; then
    printf '> 存在 **%s 项严重问题**，需立即处理；另有 %s 项警告。\n\n' "${CRIT}" "${WARN}"
  elif [[ ${WARN} -gt 0 ]]; then
    printf '> 集群运行正常，有 **%s 项**待优化，无阻塞性风险。\n\n' "${WARN}"
  else
    printf '> 全部 **%s 项**检查通过，集群处于健康状态。\n\n' "${OKN}"
  fi

  printf '## 检查项明细\n\n'
  printf '| 级别 | 检查项 | 实测值 |\n|---|---|---|\n'
  for c in "${CHECKS[@]}"; do
    IFS='|' read -r lv item detail _adv <<<"${c}"
    case "${lv}" in
      CRIT) icon="🔴 CRIT" ;;
      WARN) icon="🟡 WARN" ;;
      *)    icon="🟢 OK" ;;
    esac
    printf '| %s | %s | %s |\n' "${icon}" "${item}" "${detail}"
  done
  printf '\n'

  printf '## 整改建议\n\n'
  N=0
  for c in "${CHECKS[@]}"; do
    IFS='|' read -r lv item detail adv <<<"${c}"
    [[ "${lv}" == "OK" ]] && continue
    N=$((N+1))
    printf '### %s. [%s] %s\n\n' "${N}" "${lv}" "${item}"
    printf -- '- **现象**：%s\n' "${detail}"
    if [[ "${lv}" == "CRIT" ]]; then
      printf -- '- **影响**：可能导致服务不可用、数据不可读或容量耗尽\n'
    else
      printf -- '- **影响**：不影响当前服务，但降低可用性或可维护性\n'
    fi
    printf -- '- **建议**：%s\n\n' "${adv:-无}"
  done
  [[ ${N} -eq 0 ]] && printf '当前无待整改项。\n\n'

  printf -- '---\n\n'
  awk '/^## 一、FE 集群/{f=1} f' "${BODY}"

  printf -- '\n---\n\n'
  printf '## 附录\n\n'
  printf '### A. 巡检覆盖维度\n\n'
  printf '| 维度 | 检查内容 |\n|---|---|\n'
  printf '| FE 拓扑 | 存活、角色、Master 唯一、journal 同步、版本一致、元数据 image、备份任务 |\n'
  printf '| BE 状态 | 存活、心跳失败、查询/导入禁用标志、下线状态、tablet 均衡 |\n'
  printf '| 副本健康 | 缺失/版本不全/不可恢复/不一致/冗余/克隆迁移 |\n'
  printf '| 容量磁盘 | 磁盘水位、trash 占比、可写容量、compaction score |\n'
  printf '| 数据对象 | 库表分区统计、动态分区调度状态 |\n'
  printf '| 导入任务 | Broker/Stream Load 失败、Routine Load 状态 |\n'
  printf '| 查询审计 | 连接数、QPS、P50/P95、慢查询、失败率、Top 错误 |\n'
  printf '| 主机基线 | 负载、内存、swap、时钟偏差、根盘、进程 RSS、日志 ERROR |\n'
  printf '| 配置 | FE/BE 关键参数与 Workload Group 的运行时值 |\n\n'
  printf '### B. 阈值（脚本开头可调）\n\n'
  printf '| 指标 | WARN | CRIT |\n|---|---|---|\n'
  printf '| BE 磁盘使用率 | %s%% | %s%% |\n' "${TH_DISK_WARN}" "${TH_DISK_CRIT}"
  printf '| FE journal 落后 | %s 条 | %s 条 |\n' "${TH_JOURNAL_WARN}" "${TH_JOURNAL_CRIT}"
  printf '| Compaction score | %s | %s |\n' "${TH_COMPACTION_WARN}" "${TH_COMPACTION_CRIT}"
  printf '| Trash 占比 | %s%% | — |\n' "${TH_TRASH_PCT}"
  printf '| 时钟偏差 | — | %ss |\n' "${TH_CLOCK_SEC}"
  printf '| 查询失败率 | %s%% | — |\n' "${TH_QUERY_ERR_PCT}"
  printf '| Load / 核数 | %s%% | — |\n\n' "${TH_LOAD_PCT}"
  cat <<'EOS'
### C. 元数据备份（若检查项提示未配置）

```bash
# node-01 上每天 03:00 备份 FE meta，保留 7 天
sudo mkdir -p /opt/backup
sudo crontab -e
# 加入下面一行（crontab 中 % 需转义）
0 3 * * * tar czf /opt/backup/doris-meta-$(date +\%Y\%m\%d).tar.gz /opt/doris/fe/meta && find /opt/backup -name 'doris-meta-*' -mtime +7 -delete
```

EOS
  printf '> meta_dir 是唯一不可再生数据：BE 数据可由其他副本重建，元数据丢失则集群需重建。\n\n'
  printf '### D. 复现方式\n\n'
  printf '```bash\n'
  printf 'cd /opt/ai4doris\n'
  printf 'bash scripts/06-inspect.sh -o /tmp/doris-inspect-%s.md\n' "${TODAY}"
  printf 'echo $?   # 0=全绿 1=有 WARN 2=有 CRIT\n'
  printf '```\n'
} >"${ALL}"

if [[ -n "${OUTFILE}" ]]; then cp "${ALL}" "${OUTFILE}"; fi

if [[ ${QUIET} -eq 1 ]]; then
  echo "巡检完成 score=${SCORE} grade=${GRADE} ok=${OKN} warn=${WARN} crit=${CRIT}"
  [[ -n "${OUTFILE}" ]] && echo "报告: ${OUTFILE}"
else
  cat "${ALL}"
fi

[[ ${CRIT} -gt 0 ]] && exit 2
[[ ${WARN} -gt 0 ]] && exit 1
exit 0
