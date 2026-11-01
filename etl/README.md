# ETL 模板集

配套文档：[../docs/etl-guide.md](../docs/etl-guide.md)（原理、选型矩阵、十条原则、故障速查）

## 目录

```
etl/
├── ddl/
│   ├── 01-ods.sql          ODS 贴源表 + ETL 批次日志表
│   └── 02-dwd-dws.sql      DWS 汇总表 + ADS 快照表
├── lib/
│   └── doris_loader.py     Stream Load 客户端（标准库，label 幂等 + 死信留存）
└── jobs/
    ├── file_stream_load.py 本地文件入仓（大文件自动切分）
    ├── mysql_to_doris.sh   MySQL 全量/增量入仓（零依赖）
    ├── transform.sql       层间加工 SQL（__DT__ 占位）
    ├── run_daily.sh        日批调度入口
    ├── routine_load.sql    Kafka 实时入仓模板（参考）
    └── jdbc_catalog.sql    JDBC Catalog 联邦查询模板（参考）
```

## 快速开始（5 步）

```bash
export DORIS_PASSWORD='Doris@2026'
cd /opt/ai4doris

# 1. 建库建表
mysql -h127.0.0.1 -P9030 -uroot -p"$DORIS_PASSWORD" < etl/ddl/01-ods.sql
mysql -h127.0.0.1 -P9030 -uroot -p"$DORIS_PASSWORD" < etl/ddl/02-dwd-dws.sql

# 2. 造一个测试文件（或换成你的真实 CSV）
cat > /tmp/yield_test.csv <<'EOF'
2026-11-01,CHOT,L03,P003,AOI,D,12000,11880,120,2026-11-01 08:30:00
2026-11-01,CHOT,L03,P003,AOI,N,11000,10890,110,2026-11-01 20:30:00
EOF

# 3. 入 ODS
python3 etl/jobs/file_stream_load.py \
  --file /tmp/yield_test.csv --db ods --table ods_mes_yield_raw \
  --columns stat_date,factory_code,line_code,product_code,process_code,shift_code,input_qty,output_qty,defect_qty,report_time \
  --password "$DORIS_PASSWORD"

# 4. 层间加工
bash etl/jobs/run_daily.sh 2026-11-01

# 5. 看结果
mysql -h127.0.0.1 -P9030 -uroot -p"$DORIS_PASSWORD" -e \
  "SELECT * FROM ads.ads_yield_daily_summary WHERE stat_date='2026-11-01'"
```

## 三条使用纪律

1. **不要手改 `__DT__`**，`run_daily.sh` 会按参数替换；直接执行 `transform.sql` 会报错。
2. **重跑同一文件是安全的**：`file_stream_load.py` 的 label 由文件指纹推导，重复跑会命中幂等，不产生重复数据。
3. **补历史分区**：动态分区表的 `history_partition_num` 只预建有限天数，超出范围要临时关开关：

```sql
ALTER TABLE ods.ods_mes_yield_raw SET ("dynamic_partition.enable" = "false");
ALTER TABLE ods.ods_mes_yield_raw ADD PARTITION p20260101 VALUES [("2026-01-01"),("2026-01-02"));
ALTER TABLE ods.ods_mes_yield_raw SET ("dynamic_partition.enable" = "true");
```

## 接入真实 MySQL 的示例

```bash
bash etl/jobs/mysql_to_doris.sh \
  --source-host 192.168.1.80 --source-user readonly --source-pass '***' \
  --source-db mes --source-table yield_report \
  --target-db ods --target-table ods_mes_yield_raw \
  --columns stat_date,factory_code,line_code,product_code,process_code,shift_code,input_qty,output_qty,defect_qty,report_time \
  --mode incr --cursor-col update_time
```

增量水位默认存 `/var/lib/etl/<db>.<table>.watermark`，可用 `--state-dir` 改。
