-- =============================================================================
-- DWD / DWS / ADS 层建表
-- 执行：mysql -h192.168.1.51 -P9030 -uroot -p'Doris@2026' < etl/ddl/02-dwd-dws.sql
--
-- 模型选择理由（docs/etl-guide.md §4.8）：
--   DWD：Unique Key —— 同主键覆盖，重跑天然幂等
--   DWS：Unique Key —— 存"已预聚合"的结果，重跑覆盖（而不是 Aggregate 累加翻倍）
--   ADS：Unique Key —— 一行一个指标的快照，供 BI 直查
-- =============================================================================

CREATE DATABASE IF NOT EXISTS dws;
CREATE DATABASE IF NOT EXISTS ads;

-- -----------------------------------------------------------------------------
-- DWS：产线 × 日 良率汇总
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dws.dws_yield_line_1d (
    stat_date        DATE          NOT NULL COMMENT '业务日期',
    factory_code     VARCHAR(32)   NOT NULL COMMENT '工厂编码',
    line_code        VARCHAR(32)   NOT NULL COMMENT '产线编码',
    input_qty        BIGINT                 COMMENT '投入合计',
    output_qty       BIGINT                 COMMENT '产出合计',
    defect_qty       BIGINT                 COMMENT '不良合计',
    yield_rate       DECIMAL(10,4)          COMMENT '良率 %',
    batch_count      INT                    COMMENT '上报批次数',
    etl_time         DATETIME               COMMENT '加工时间'
)
UNIQUE KEY(stat_date, factory_code, line_code)
PARTITION BY RANGE(stat_date) ()
DISTRIBUTED BY HASH(line_code) BUCKETS 3
PROPERTIES (
    "replication_allocation" = "tag.location.default: 3",
    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "DAY",
    "dynamic_partition.start" = "-365",
    "dynamic_partition.end" = "3",
    "dynamic_partition.prefix" = "p",
    "dynamic_partition.buckets" = "3",
    "dynamic_partition.history_partition_num" = "30"
);

-- -----------------------------------------------------------------------------
-- ADS：全厂单日良率快照（看板直接用，避免每次扫明细）
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ads.ads_yield_daily_summary (
    stat_date        DATE          NOT NULL COMMENT '业务日期',
    factory_code     VARCHAR(32)   NOT NULL COMMENT '工厂编码',
    total_input      BIGINT                 COMMENT '全厂投入',
    total_output     BIGINT                 COMMENT '全厂产出',
    total_defect     BIGINT                 COMMENT '全厂不良',
    yield_rate       DECIMAL(10,4)          COMMENT '全厂良率 %',
    worst_line       VARCHAR(32)            COMMENT '良率最低产线',
    worst_line_rate  DECIMAL(10,4)          COMMENT '最低产线良率 %',
    refresh_time     DATETIME               COMMENT '刷新时间'
)
UNIQUE KEY(stat_date, factory_code)
PARTITION BY RANGE(stat_date) ()
DISTRIBUTED BY HASH(factory_code) BUCKETS 3
PROPERTIES (
    "replication_allocation" = "tag.location.default: 3",
    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "DAY",
    "dynamic_partition.start" = "-365",
    "dynamic_partition.end" = "3",
    "dynamic_partition.prefix" = "p",
    "dynamic_partition.buckets" = "3",
    "dynamic_partition.history_partition_num" = "30"
);
