-- ============================================================
-- 01-init.sql  建库 + 良率示例表（3 分桶 / 3 副本 / 动态分区）
-- 执行: mysql -h192.168.1.51 -P9030 -uroot < sql/01-init.sql
-- 分桶原则：桶数 = BE 数量（3）的整数倍，3/6/9 都可，别用 4/5
-- ============================================================

CREATE DATABASE IF NOT EXISTS demo;

USE demo;

-- 良率日汇总（UNIQUE 模型，按主键覆盖写入，适合 ETL 重跑）
CREATE TABLE IF NOT EXISTS demo.dwd_yield_daily (
  stat_date     DATE         NOT NULL COMMENT '统计日期',
  factory_code  VARCHAR(32)  NOT NULL COMMENT '工厂编码',
  line_code     VARCHAR(32)  NOT NULL COMMENT '产线编码',
  product_code  VARCHAR(64)  NOT NULL COMMENT '料号',
  process_code  VARCHAR(32)  NOT NULL COMMENT '工序',
  input_qty     BIGINT       NOT NULL DEFAULT "0" COMMENT '投入数',
  output_qty    BIGINT       NOT NULL DEFAULT "0" COMMENT '产出数',
  defect_qty    BIGINT       NOT NULL DEFAULT "0" COMMENT '不良数',
  yield_rate    DECIMAL(9,4) NULL COMMENT '良率 = output/input',
  etl_time      DATETIME     NULL COMMENT '入库时间'
)
UNIQUE KEY(stat_date, factory_code, line_code, product_code, process_code)
PARTITION BY RANGE(stat_date) ()
DISTRIBUTED BY HASH(line_code) BUCKETS 3
PROPERTIES (
  "replication_num" = "3",
  "compression" = "ZSTD",
  "dynamic_partition.enable" = "true",
  "dynamic_partition.time_unit" = "DAY",
  "dynamic_partition.start" = "-90",
  "dynamic_partition.end" = "3",
  "dynamic_partition.prefix" = "p",
  "dynamic_partition.buckets" = "3",
  "dynamic_partition.history_partition_num" = "93",
  "dynamic_partition.replication_num" = "3",
  "in_memory" = "false",
  "storage_medium" = "SSD"
);

-- 明细表（DUPLICATE 模型，逐笔记录，压缩更好）
CREATE TABLE IF NOT EXISTS demo.dwd_defect_detail (
  stat_date     DATE         NOT NULL COMMENT '统计日期',
  line_code     VARCHAR(32)  NOT NULL COMMENT '产线',
  product_code  VARCHAR(64)  NOT NULL COMMENT '料号',
  process_code  VARCHAR(32)  NULL COMMENT '工序',
  defect_code   VARCHAR(32)  NULL COMMENT '缺陷代码',
  defect_qty    BIGINT       NULL COMMENT '数量',
  create_time   DATETIME     NULL COMMENT '发生时间'
)
DUPLICATE KEY(stat_date, line_code, product_code)
PARTITION BY RANGE(stat_date) ()
DISTRIBUTED BY HASH(line_code) BUCKETS 3
PROPERTIES (
  "replication_num" = "3",
  "compression" = "ZSTD",
  "dynamic_partition.enable" = "true",
  "dynamic_partition.time_unit" = "DAY",
  "dynamic_partition.start" = "-90",
  "dynamic_partition.end" = "3",
  "dynamic_partition.prefix" = "p",
  "dynamic_partition.buckets" = "3",
  "dynamic_partition.history_partition_num" = "93"
);

-- 验证
SHOW TABLES FROM demo;
SELECT COUNT(*) AS yield_rows FROM demo.dwd_yield_daily;
