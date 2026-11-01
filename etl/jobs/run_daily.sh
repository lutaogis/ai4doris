#!/usr/bin/env bash
# =============================================================================
# run_daily.sh —— 日批调度入口（crontab 用）
#
#   ./run_daily.sh            # 加工昨天
#   ./run_daily.sh 2026-10-30 # 补数：加工指定日期
#
# 做的事：ODS→DWD→DWS→ADS 四层加工 + 结果校验 + 失败退出码
# 环境变量：DORIS_PASSWORD（必填）、DORIS_HOST（默认 127.0.0.1）
# =============================================================================
set -euo pipefail

DT="${1:-$(date -d 'yesterday' +%F)}"
HOST="${DORIS_HOST:-127.0.0.1}"
USER_NAME="${DORIS_USER:-root}"
PASS="${DORIS_PASSWORD:?请先 export DORIS_PASSWORD}"
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${ETL_LOG_DIR:-/var/log/etl}"

mkdir -p "$LOG_DIR"
LOG="${LOG_DIR}/transform_${DT}.log"
exec > >(tee -a "$LOG") 2>&1

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

if ! [[ "$DT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  log "[ERROR] 日期格式应为 YYYY-MM-DD，收到：$DT"
  exit 2
fi

log "===== 开始加工 ${DT} ====="

export MYSQL_PWD="$PASS"
mysql_run() {
  mysql -h "$HOST" -P 9030 -u "$USER_NAME" --batch --raw --connect-timeout=10 "$@"
}

# 连通性：不查 SELECT 1（无 BE 时会报错），查元数据更稳
mysql_run -e "SHOW FRONTENDS" >/dev/null || { log "[ERROR] 连不上 Doris ${HOST}:9030"; exit 1; }

# 上游为空时提前退出，避免空跑污染下游
ODS_CNT="$(mysql_run -N -B -e "SELECT COUNT(*) FROM ods.ods_mes_yield_raw WHERE stat_date='${DT}'")"
log "ODS 行数：${ODS_CNT}"
if [[ "${ODS_CNT}" -eq 0 ]]; then
  log "[WARN] ODS 无 ${DT} 数据，跳过加工（请先确认上游 ETL 是否成功）"
  exit 3
fi

log "执行层间加工..."
sed "s/__DT__/${DT}/g" "${BASE_DIR}/transform.sql" | mysql_run

log "加工完成：${DT}"
log "校验结果见上（min_rate/max_rate 应在 0~100 之间）"
log "===== 结束 ====="
