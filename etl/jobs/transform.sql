-- =============================================================================
-- 层间加工：ODS → DWD → DWS → ADS
-- __DT__ 由 run_daily.sh 替换成具体日期，请勿直接执行本文件
--
-- 三条纪律（docs/etl-guide.md §3.5）：
--   1. 每条语句都必须带日期过滤，否则全表扫描 + 全量重写
--   2. 目标表是 Unique Key → 重复执行自动覆盖，不会翻倍
--   3. 先 DWD 后 DWS 后 ADS，顺序不能乱
-- =============================================================================

-- -----------------------------------------------------------------------------
-- ① ODS → DWD：清洗 + 过滤 + 按粒度聚合
--    过滤规则：投入量为 0 或负数视为脏数据
-- -----------------------------------------------------------------------------
INSERT INTO demo.dwd_yield_daily
    (stat_date, factory_code, line_code, product_code, process_code,
     input_qty, output_qty, defect_qty, yield_rate, etl_time)
SELECT
    stat_date,
    factory_code,
    line_code,
    product_code,
    process_code,
    SUM(input_qty)                                             AS input_qty,
    SUM(output_qty)                                            AS output_qty,
    SUM(defect_qty)                                            AS defect_qty,
    ROUND(SUM(output_qty) / NULLIF(SUM(input_qty), 0) * 100, 4) AS yield_rate,
    NOW()                                                      AS etl_time
FROM ods.ods_mes_yield_raw
WHERE stat_date = '__DT__'
  AND input_qty > 0
  AND output_qty >= 0
GROUP BY stat_date, factory_code, line_code, product_code, process_code;

-- -----------------------------------------------------------------------------
-- ② DWD → DWS：产线 × 日 汇总
-- -----------------------------------------------------------------------------
INSERT INTO dws.dws_yield_line_1d
    (stat_date, factory_code, line_code, input_qty, output_qty,
     defect_qty, yield_rate, batch_count, etl_time)
SELECT
    stat_date,
    factory_code,
    line_code,
    SUM(input_qty),
    SUM(output_qty),
    SUM(defect_qty),
    ROUND(SUM(output_qty) / NULLIF(SUM(input_qty), 0) * 100, 4),
    COUNT(*),
    NOW()
FROM demo.dwd_yield_daily
WHERE stat_date = '__DT__'
GROUP BY stat_date, factory_code, line_code;

-- -----------------------------------------------------------------------------
-- ③ DWS → ADS：全厂快照（含良率最低产线）
--    用窗口函数取最差产线；比子查询里 LIMIT 1 更稳，且一次扫描搞定
-- -----------------------------------------------------------------------------
INSERT INTO ads.ads_yield_daily_summary
    (stat_date, factory_code, total_input, total_output, total_defect,
     yield_rate, worst_line, worst_line_rate, refresh_time)
SELECT
    '__DT__'                                            AS stat_date,
    a.factory_code,
    a.total_input,
    a.total_output,
    a.total_defect,
    ROUND(a.total_output / NULLIF(a.total_input, 0) * 100, 4) AS yield_rate,
    w.line_code                                         AS worst_line,
    w.yield_rate                                        AS worst_line_rate,
    NOW()
FROM (
    SELECT factory_code,
           SUM(input_qty)  AS total_input,
           SUM(output_qty) AS total_output,
           SUM(defect_qty) AS total_defect
    FROM dws.dws_yield_line_1d
    WHERE stat_date = '__DT__'
    GROUP BY factory_code
) a
LEFT JOIN (
    SELECT factory_code, line_code, yield_rate,
           ROW_NUMBER() OVER (PARTITION BY factory_code ORDER BY yield_rate ASC) AS rn
    FROM dws.dws_yield_line_1d
    WHERE stat_date = '__DT__'
) w ON a.factory_code = w.factory_code AND w.rn = 1;

-- -----------------------------------------------------------------------------
-- ④ 校验：三条 SQL 结果应满足 良率区间 [0,100]，否则说明源数据有问题
-- -----------------------------------------------------------------------------
SELECT 'DWD' AS layer, COUNT(*) AS rows_cnt, MIN(yield_rate) AS min_rate, MAX(yield_rate) AS max_rate
FROM demo.dwd_yield_daily WHERE stat_date = '__DT__'
UNION ALL
SELECT 'DWS', COUNT(*), MIN(yield_rate), MAX(yield_rate)
FROM dws.dws_yield_line_1d WHERE stat_date = '__DT__';
