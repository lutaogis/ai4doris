-- =============================================================================
-- 参考模板：Kafka → Doris 实时导入（Routine Load）
--
-- 前提：集群能访问 Kafka broker；主题里的消息是 JSON 或 CSV。
-- 本文件不会自动执行，请按实际地址修改后手工运行。
-- 详细说明见 docs/etl-guide.md §3.6
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. 实时表：与批处理表分开建，避免互相干扰（命名加 _rt 后缀）
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ods.ods_mes_yield_rt (
    stat_date        DATE          NOT NULL,
    factory_code     VARCHAR(32),
    line_code        VARCHAR(32),
    product_code     VARCHAR(64),
    process_code     VARCHAR(32),
    input_qty        BIGINT,
    output_qty       BIGINT,
    defect_qty       BIGINT,
    yield_rate       DECIMAL(10,4),
    etl_time         DATETIME      DEFAULT CURRENT_TIMESTAMP
)
DUPLICATE KEY(stat_date, line_code)
PARTITION BY RANGE(stat_date) ()
DISTRIBUTED BY HASH(line_code) BUCKETS 3
PROPERTIES (
    "replication_allocation" = "tag.location.default: 3",
    "dynamic_partition.enable" = "true",
    "dynamic_partition.time_unit" = "DAY",
    "dynamic_partition.start" = "-7",
    "dynamic_partition.end" = "1",
    "dynamic_partition.prefix" = "p",
    "dynamic_partition.buckets" = "3"
);

-- -----------------------------------------------------------------------------
-- 2. 创建常驻作业
--    要点：
--      * max_batch_interval/size 决定攒批力度，太小会打爆版本数（§4.4）
--      * max_error_number 到阈值作业自动 PAUSE，不会静默丢数
--      * OFFSET_END 只消费新数据；要补历史用 OFFSET_BEGINNING
-- -----------------------------------------------------------------------------
CREATE ROUTINE LOAD ods.rl_yield_rt ON ods_mes_yield_rt
COLUMNS(stat_date, factory_code, line_code, product_code, process_code,
        input_qty, output_qty, defect_qty, yield_rate, etl_time = now())
PROPERTIES (
    "format"                  = "json",
    "jsonpaths"               = "[\"$.stat_date\",\"$.factory_code\",\"$.line_code\",\"$.product_code\",\"$.process_code\",\"$.input_qty\",\"$.output_qty\",\"$.defect_qty\",\"$.yield_rate\"]",
    "strip_outer_array"       = "false",
    "max_batch_interval"      = "20",
    "max_batch_rows"          = "300000",
    "max_batch_size"          = "209715200",
    "max_error_number"        = "100",
    "strict_mode"             = "false",
    "timezone"                = "Asia/Shanghai",
    "desired_concurrent_number" = "3"
)
FROM KAFKA (
    "kafka_broker_list"              = "192.168.1.90:9092",
    "kafka_topic"                    = "mes.yield.realtime",
    "property.group.id"              = "doris_yield_rt",
    "property.kafka_default_offsets" = "OFFSET_END",
    "property.security.protocol"     = "PLAINTEXT"
);

-- -----------------------------------------------------------------------------
-- 3. 日常运维命令
-- -----------------------------------------------------------------------------
-- 看状态：State=RUNNING、Lag 是否持续增长、ErrorRows 是否上升
-- SHOW ROUTINE LOAD FOR ods.rl_yield_rt\G

-- 看历史任务
-- SHOW ROUTINE LOAD;

-- 暂停 / 恢复 / 停止
-- PAUSE  ROUTINE LOAD FOR ods.rl_yield_rt;
-- RESUME ROUTINE LOAD FOR ods.rl_yield_rt;
-- STOP   ROUTINE LOAD FOR ods.rl_yield_rt;

-- 从指定时间点重置消费位点（补数用）
-- ALTER ROUTINE LOAD FOR ods.rl_yield_rt
-- PROPERTIES("kafka_partitions" = "0,1,2", "kafka_offsets" = "OFFSET_BEGINNING");
