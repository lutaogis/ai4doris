#!/usr/bin/env bash
# =============================================================================
# mysql_to_doris.sh —— MySQL 单表 → Doris ODS（全量 / 游标增量）
#
# 零第三方依赖：只用 mysql 客户端 + curl + python3（仅解析 JSON）
# 内部走 Stream Load，符合 docs/etl-guide.md 的幂等与攒批原则。
#
# 用法：
#   # 全量（首次初始化）
#   ./mysql_to_doris.sh --source-host 192.168.1.80 --source-user readonly --source-pass *** \
#       --source-db mes --source-table work_order \
#       --target-db ods --target-table ods_mes_work_order \
#       --columns stat_date,wo_no,line_code,product_code,plan_qty,finish_qty \
#       --mode full
#
#   # 增量（按 update_time 水位，水位自动存盘）
#   ./mysql_to_doris.sh ... --mode incr --cursor-col update_time
#
# 退出码：0 成功（含幂等命中），1 失败，2 参数错误
# =============================================================================
set -euo pipefail

# ------------------------------- 默认值 --------------------------------------
SRC_HOST=""; SRC_PORT=3306; SRC_USER=""; SRC_PASS=""; SRC_DB=""; SRC_TABLE=""
TGT_HOSTS="192.168.1.54:8040,192.168.1.55:8040,192.168.1.56:8040"
TGT_USER="root"; TGT_PASS="${DORIS_PASSWORD:-}"; TGT_DB=""; TGT_TABLE=""
COLUMNS=""; MODE="full"; CURSOR_COL=""; MAX_FILTER_RATIO="0.01"
STATE_DIR="${ETL_STATE_DIR:-/var/lib/etl}"
PARTITION=""; DRY_RUN=no; KEEP_TMP=no

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { printf '[%s] [ERROR] %s\n' "$(date '+%F %T')" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-host)    SRC_HOST="$2"; shift 2 ;;
    --source-port)    SRC_PORT="$2"; shift 2 ;;
    --source-user)    SRC_USER="$2"; shift 2 ;;
    --source-pass)    SRC_PASS="$2"; shift 2 ;;
    --source-db)      SRC_DB="$2"; shift 2 ;;
    --source-table)   SRC_TABLE="$2"; shift 2 ;;
    --target-hosts)   TGT_HOSTS="$2"; shift 2 ;;
    --target-user)    TGT_USER="$2"; shift 2 ;;
    --target-pass)    TGT_PASS="$2"; shift 2 ;;
    --target-db)      TGT_DB="$2"; shift 2 ;;
    --target-table)   TGT_TABLE="$2"; shift 2 ;;
    --columns)        COLUMNS="$2"; shift 2 ;;
    --mode)           MODE="$2"; shift 2 ;;
    --cursor-col)     CURSOR_COL="$2"; shift 2 ;;
    --max-filter-ratio) MAX_FILTER_RATIO="$2"; shift 2 ;;
    --partition)      PARTITION="$2"; shift 2 ;;
    --state-dir)      STATE_DIR="$2"; shift 2 ;;
    --dry-run)        DRY_RUN=yes; shift ;;
    --keep-tmp)       KEEP_TMP=yes; shift ;;
    -h|--help)        usage ;;
    *) die "未知参数：$1" ;;
  esac
done

[[ -n "$SRC_HOST" && -n "$SRC_USER" && -n "$SRC_DB" && -n "$SRC_TABLE" ]] || die "缺少源库参数"
[[ -n "$TGT_DB" && -n "$TGT_TABLE" ]] || die "缺少目标库表参数"
[[ -n "$COLUMNS" ]] || die "--columns 必填（Doris 需要显式列清单才能对齐）"
[[ "$MODE" == "incr" && -z "$CURSOR_COL" ]] && die "增量模式必须指定 --cursor-col"

command -v mysql >/dev/null || die "本机没有 mysql 客户端"
command -v curl  >/dev/null || die "本机没有 curl"
command -v python3 >/dev/null || die "本机没有 python3（仅用于解析返回 JSON）"

mkdir -p "$STATE_DIR"

# ------------------------------- 水位与边界 ----------------------------------
# 关键：先取一个固定的上界（NOW），本次只导 <= 上界的数据，
# 导成功后把水位推进到上界，避免"导入过程中新写入的数据被跳过或重复"。
WM_FILE="$STATE_DIR/${SRC_DB}.${SRC_TABLE}.watermark"
STAMP="$(date +%Y%m%d%H%M%S)"
UPPER_BOUND="$(date '+%Y-%m-%d %H:%M:%S')"
WHERE=""

if [[ "$MODE" == "incr" ]]; then
  if [[ -f "$WM_FILE" ]]; then
    LOWER_BOUND="$(cat "$WM_FILE")"
  else
    LOWER_BOUND="1970-01-01 00:00:00"
    log "首次增量：水位为空，从 $LOWER_BOUND 开始（相当于全量）"
  fi
  WHERE="WHERE \`${CURSOR_COL}\` > '${LOWER_BOUND}' AND \`${CURSOR_COL}\` <= '${UPPER_BOUND}'"
else
  LOWER_BOUND=""
fi

LABEL="${TGT_DB}_${TGT_TABLE}_${MODE}_${STAMP}"
TMPFILE="$(mktemp /tmp/etl_${SRC_TABLE}_XXXXXX.tsv)"
cleanup() { [[ "$KEEP_TMP" == "yes" ]] || rm -f "$TMPFILE"; }
trap cleanup EXIT

log "源      : ${SRC_HOST}:${SRC_PORT}/${SRC_DB}.${SRC_TABLE}"
log "目标    : ${TGT_DB}.${TGT_TABLE} @ ${TGT_HOSTS%%:*}"
log "模式    : ${MODE}  ${WHERE:+(${WHERE})}"
log "label   : ${LABEL}"

if [[ "$DRY_RUN" == "yes" ]]; then
  log "[DRY-RUN] 未执行导出与导入"
  exit 0
fi

# ------------------------------- 1. 导出 -------------------------------------
log "导出数据..."
MYSQL_PWD="$SRC_PASS" mysql \
  -h "$SRC_HOST" -P "$SRC_PORT" -u "$SRC_USER" \
  --batch --raw --default-character-set=utf8mb4 \
  --quick -e "SELECT ${COLUMNS} FROM \`${SRC_DB}\`.\`${SRC_TABLE}\` ${WHERE};" > "$TMPFILE"

ROWS_EXPORTED="$(wc -l < "$TMPFILE" | tr -d ' ')"
SIZE_MB="$(awk -v b="$(wc -c < "$TMPFILE")" 'BEGIN{printf "%.1f", b/1048576}')"
log "导出完成：${ROWS_EXPORTED} 行 / ${SIZE_MB} MB"

if [[ "$ROWS_EXPORTED" -eq 0 ]]; then
  log "无新数据，结束（水位保持不变）"
  exit 0
fi

# ------------------------------- 2. 导入 -------------------------------------
BE="${TGT_HOSTS%%,*}"
TAB=$'\t'
RESP="$(curl -sS --location-trusted \
  -u "${TGT_USER}:${TGT_PASS}" \
  -H "label: ${LABEL}" \
  -H "column_separator: ${TAB}" \
  -H "columns: ${COLUMNS}" \
  -H "max_filter_ratio: ${MAX_FILTER_RATIO}" \
  -H "strict_mode: false" \
  -H "timeout: 1800" \
  ${PARTITION:+-H "partition: ${PARTITION}"} \
  -T "$TMPFILE" \
  "http://${BE}/api/${TGT_DB}/${TGT_TABLE}/_stream_load")" || die "curl 请求失败（网络或 BE 不可达）"

json_get() { printf '%s' "$RESP" | python3 -c 'import json,sys;d=json.load(sys.stdin);print(d.get(sys.argv[1],""))' "$1" 2>/dev/null || true; }

STATUS="$(json_get Status)"
LOADED="$(json_get NumberLoadedRows)"; LOADED="${LOADED:-0}"
FILTERED="$(json_get NumberFilteredRows)"; FILTERED="${FILTERED:-0}"
MESSAGE="$(json_get Message)"
ERROR_URL="$(json_get ErrorURL)"

log "返回：Status=${STATUS:-?} Loaded=${LOADED} Filtered=${FILTERED}"
[[ -n "$MESSAGE" ]] && log "Message: ${MESSAGE}"

if [[ "$STATUS" != "Success" ]]; then
  if printf '%s' "$MESSAGE" | grep -qi 'label already exist'; then
    log "该批次已导入过（label 幂等命中），视为成功"
    exit 0
  fi
  [[ -n "$ERROR_URL" ]] && log "脏数据详情：${ERROR_URL}"
  die "导入失败：${MESSAGE:-未知错误}"
fi

# ------------------------------- 3. 对账 -------------------------------------
if [[ "$FILTERED" -gt 0 ]]; then
  log "[WARN] 有 ${FILTERED} 行被过滤（max_filter_ratio=${MAX_FILTER_RATIO}）"
  [[ -n "$ERROR_URL" ]] && log "[WARN] 脏数据详情：${ERROR_URL}"
fi

if [[ "$LOADED" != "$ROWS_EXPORTED" ]]; then
  log "[WARN] 对账不一致：导出 ${ROWS_EXPORTED} 行，入库 ${LOADED} 行"
else
  log "对账通过：${LOADED} 行"
fi

# ------------------------------- 4. 推进水位 ---------------------------------
if [[ "$MODE" == "incr" ]]; then
  printf '%s' "$UPPER_BOUND" > "$WM_FILE"
  log "水位推进到 ${UPPER_BOUND}（${WM_FILE}）"
fi

log "完成"
