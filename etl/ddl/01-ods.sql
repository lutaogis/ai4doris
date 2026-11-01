-- =============================================================================
-- ODS 层建表：贴源、不加工、可回溯
-- 执行：mysql -h192.168.1.51 -P9030 -uroot -p'Doris@2026' < etl/ddl/01-ods.sql
--
-- 原则（docs/etl-guide.md §1）：
--   1. 字段名/类型照抄源系统，ODS 不做任何清洗
--   2. 用 Duplicate 模型保留原始快照（不对账时能查到"到底导进来了什么"）
--   3. 必备三列：etl_time / src_sys / batch_id
--   4. 按天分区 + 3 分桶（= BE 数量），动态分区保留 90 天
-- =============================================================================

CREATE DATABASE IF NOT EXISTS ods;

-- -----------------------------------------------------------------------------
-- 1. MES 工单明细
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ods.ods_mes_work_order (
    stat_date        DATE          NOT NULL COMMENT '业务日期（分区键，来自源表业务时间）',
    wo_no            VARCHAR(64)   NOT NULL COMMENT '工单号',
    line_code        VARCHAR(32)            COMMENT '产线编码',
    product_code     VARCHAR(64)            COMMENT '产品编码',
    process_code     VARCHAR(32)            COMMENT '工序编码',
    plan_qty         BIGINT                 COMMENT '计划数量',
    finish_qty       BIGINT                 COMMENT '完工数量',
    defect_qty       BIGINT                 COMMENT '不良数量',
    wo_status        VARCHAR(16)            COMMENT '工单状态',
    start_time       DATETIME               COMMENT '开工时间',
    end_time         DATETIME               COMMENT '完工时间',
    src_update_time  DATETIME               COMMENT '源表更新时间（增量水位依据）',
    etl_time         DATETIME      DEFAULT CURRENT_TIMESTAMP COMMENT '入仓时间',
    src_sys          VARCHAR(32)   DEFAULT 'MES' COMMENT '来源系统',
    batch_id         VARCHAR(64)            COMMENT 'ETL 批次号'
)
DUPLICATE KEY(stat_date, wo_no)
PARTITION BY RANGE(stat_date) ()
DISTRIBUTED BY HASH(wo_no) BUCKETS 3
PROPERTIES (
    "replication_allocation" = "tag.location.default: 3",
    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "DAY",
    "dynamic_partition.start" = "-90",
    "dynamic_partition.end" = "3",
    "dynamic_partition.prefix" = "p",
    "dynamic_partition.buckets" = "3",
    "dynamic_partition.history_partition_num" = "7"
);

-- -----------------------------------------------------------------------------
-- 2. MES 良率原始记录（按产线/产品/工序/班次的原始上报）
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ods.ods_mes_yield_raw (
    stat_date        DATE          NOT NULL COMMENT '业务日期',
    factory_code     VARCHAR(32)            COMMENT '工厂编码',
    line_code        VARCHAR(32)            COMMENT '产线编码',
    product_code     VARCHAR(64)            COMMENT '产品编码',
    process_code     VARCHAR(32)            COMMENT '工序编码',
    shift_code       VARCHAR(16)            COMMENT '班次：D/N',
    input_qty        BIGINT                 COMMENT '投入数量',
    output_qty       BIGINT                 COMMENT '产出数量',
    defect_qty       BIGINT                 COMMENT '不良数量',
    report_time      DATETIME               COMMENT '上报时间',
    etl_time         DATETIME      DEFAULT CURRENT_TIMESTAMP COMMENT '入仓时间',
    src_sys          VARCHAR(32)   DEFAULT 'MES' COMMENT '来源系统',
    batch_id         VARCHAR(64)            COMMENT 'ETL 批次号'
)
DUPLICATE KEY(stat_date, factory_code, line_code, product_code)
PARTITION BY RANGE(stat_date) ()
DISTRIBUTED BY HASH(line_code) BUCKETS 3
PROPERTIES (
    "replication_allocation" = "tag.location.default: 3",
    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "DAY",
    "dynamic_partition.start" = "-90",
    "dynamic_partition.end" = "3",
    "dynamic_partition.prefix" = "p",
    "dynamic_partition.buckets" = "3",
    "dynamic_partition.history_partition_num" = "7"
);

-- -----------------------------------------------------------------------------
-- 3. ETL 作业日志（每次导入必写，用于回溯与对账）
-- -----------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS ops;

CREATE TABLE IF NOT EXISTS ops.etl_job_log (
    batch_id         VARCHAR(64)   NOT NULL COMMENT '批次号（= Stream Load 的 label）',
    job_name         VARCHAR(128)           COMMENT '作业名',
    src_desc         VARCHAR(256)           COMMENT '源描述',
    tgt_table        VARCHAR(128)           COMMENT '目标表',
    stat_date        DATE                   COMMENT '业务日期',
    src_rows         BIGINT                 COMMENT '源行数',
    loaded_rows      BIGINT                 COMMENT '入库行数',
    filtered_rows    BIGINT                 COMMENT '过滤行数',
    status           VARCHAR(16)            COMMENT 'SUCCESS/FAILED',
    error_msg        VARCHAR(1024)          COMMENT '错误摘要',
    start_time       DATETIME               COMMENT '开始时间',
    end_time         DATETIME               COMMENT '结束时间',
    duration_sec     INT                    COMMENT '耗时（秒）'
)
UNIQUE KEY(batch_id)
DISTRIBUTED BY HASH(batch_id) BUCKETS 3
PROPERTIES (
    "replication_allocation" = "tag.location.default: 3"
);

-- 建议：定期清理 180 天前的日志（可放进每日调度）
-- DELETE FROM ops.etl_job_log WHERE start_time < DATE_SUB(NOW(), INTERVAL 180 DAY);
