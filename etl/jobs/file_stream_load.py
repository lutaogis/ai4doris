#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
file_stream_load.py —— 把本地文件导入 Doris（Stream Load 命令行封装）

特性：
  * label 默认由「文件名 + 大小 + 库表」推导 → 同一个文件重跑自动幂等
  * 超过 --split-mb 的大文件自动按行切分，分批导入（单个 ≤2G 的硬约束）
  * 失败时自动下载被过滤的脏数据到 /tmp/doris_error/

用法：
  python3 file_stream_load.py \
      --file /data/work_order_20261101.csv \
      --db ods --table ods_mes_work_order \
      --columns stat_date,wo_no,line_code,product_code,plan_qty,finish_qty \
      --delimiter ',' --max-filter-ratio 0.01

  # 只校验参数不真导入
  python3 file_stream_load.py --file x.csv --db ods --table t --dry-run
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

from doris_loader import DorisLoader, DorisLoadError  # noqa: E402

DEFAULT_HOSTS = "192.168.1.54:8040,192.168.1.55:8040,192.168.1.56:8040"


def build_label(db: str, table: str, path: str) -> str:
    """由文件内容指纹推导 label：文件不变 → label 不变 → 重跑不会重复写入。"""
    size = os.path.getsize(path)
    stem = re.sub(r"[^0-9A-Za-z_]", "_", os.path.splitext(os.path.basename(path))[0])[:40]
    digest = hashlib.md5(f"{os.path.abspath(path)}|{size}".encode()).hexdigest()[:10]
    return f"{db}_{table}_{stem}_{digest}"[:128]


def iter_chunks(path: str, max_bytes: int):
    """按行切分，产出 (序号, bytes)。保证不会把一行拆断。"""
    buf: list[str] = []
    size = 0
    index = 0
    with open(path, "r", encoding="utf-8", errors="replace", newline="") as f:
        for line in f:
            buf.append(line)
            size += len(line.encode("utf-8"))
            if size >= max_bytes:
                index += 1
                yield index, "".join(buf).encode("utf-8")
                buf, size = [], 0
    if buf:
        index += 1
        yield index, "".join(buf).encode("utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description="本地文件 → Doris（Stream Load）")
    ap.add_argument("--file", required=True, help="本地文件路径")
    ap.add_argument("--db", required=True, help="目标库")
    ap.add_argument("--table", required=True, help="目标表")
    ap.add_argument("--format", default="csv", choices=["csv", "json", "parquet", "orc"])
    ap.add_argument("--columns", default=None, help="列清单，逗号分隔；可含表达式 c1,c2,dt=now()")
    ap.add_argument("--delimiter", default=",", help="CSV 分隔符，默认逗号")
    ap.add_argument("--label", default=None, help="自定义 label（默认按文件指纹生成）")
    ap.add_argument("--partition", default=None, help="指定目标分区名")
    ap.add_argument("--max-filter-ratio", type=float, default=0.01)
    ap.add_argument("--strict", action="store_true", help="开启严格模式（类型不符直接报错）")
    ap.add_argument("--split-mb", type=int, default=1024, help="单批最大 MB，超过则切分，默认 1024")
    ap.add_argument("--hosts", default=DEFAULT_HOSTS, help="BE 列表，逗号分隔")
    ap.add_argument("--user", default=os.environ.get("DORIS_USER", "root"))
    ap.add_argument("--password", default=os.environ.get("DORIS_PASSWORD", ""))
    ap.add_argument("--keep-error-rows", action="store_true", help="失败时下载脏数据")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if not os.path.isfile(args.file):
        print(f"[ERROR] 文件不存在：{args.file}", file=sys.stderr)
        return 2

    label = args.label or build_label(args.db, args.table, args.file)
    size_mb = os.path.getsize(args.file) / 1024 / 1024

    print(f"文件    : {args.file} ({size_mb:.1f} MB)")
    print(f"目标    : {args.db}.{args.table}")
    print(f"label   : {label}")
    print(f"BE      : {args.hosts}")

    if args.dry_run:
        print("[DRY-RUN] 参数校验通过，未执行导入")
        return 0

    loader = DorisLoader(
        be_hosts=args.hosts.split(","),
        user=args.user,
        password=args.password,
        database=args.db,
    )

    headers = {"column_separator": args.delimiter}
    if args.format == "json":
        headers.pop("column_separator", None)
        headers["read_json_by_line"] = "true"

    total_loaded = total_filtered = 0
    chunks = list(iter_chunks(args.file, args.split_mb * 1024 * 1024))
    print(f"批次    : 共 {len(chunks)} 批\n")

    for idx, payload in chunks:
        part_label = label if len(chunks) == 1 else f"{label}_p{idx}"
        try:
            result = loader.load(
                table=args.table,
                body=payload,
                label=part_label,
                fmt=args.format,
                columns=args.columns,
                max_filter_ratio=args.max_filter_ratio,
                strict_mode=args.strict,
                partition=args.partition,
                extra_headers=headers,
            )
        except DorisLoadError as exc:
            print(f"[FAIL] 第 {idx} 批：{exc}", file=sys.stderr)
            if args.keep_error_rows and exc.result:
                p = loader.save_error_rows(exc.result)
                if p:
                    print(f"[INFO] 脏数据已保存：{p}", file=sys.stderr)
            return 1

        n_loaded = int(result.get("NumberLoadedRows") or 0)
        n_filtered = int(result.get("NumberFilteredRows") or 0)
        total_loaded += n_loaded
        total_filtered += n_filtered
        tag = " (幂等命中)" if result.get("Duplicated") else ""
        print(f"  批 {idx}: 成功 {n_loaded} 行, 过滤 {n_filtered} 行{tag}")

    print(f"\n合计：成功 {total_loaded} 行，过滤 {total_filtered} 行")
    if total_filtered > 0:
        print("[WARN] 存在被过滤的行，请检查数据质量（加 --keep-error-rows 留存原文）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
