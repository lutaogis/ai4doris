-- =============================================================================
-- 参考模板：JDBC Catalog（不落库，直接联邦查询业务库）
--
-- 适用：维表关联、小表即席查询、POC 阶段先"能查"再考虑入仓。
-- 不适用：大表 JOIN（压力会打到源库，可能把生产库拖死）。
-- 详细说明见 docs/etl-guide.md §3.4
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1. 准备驱动
--    把 mysql-connector-java-8.0.30.jar 放到每台 FE 的 jdbc_drivers 目录：
--      /opt/doris/fe/jdbc_drivers/
--    或者用内网可访问的 HTTP 地址作为 driver_url。
-- -----------------------------------------------------------------------------

-- -----------------------------------------------------------------------------
-- 2. 创建 Catalog
-- -----------------------------------------------------------------------------
CREATE CATALOG IF NOT EXISTS mysql_mes PROPERTIES (
    "type"         = "jdbc",
    "user"         = "readonly",
    "password"     = "CHANGE_ME",
    "jdbc_url"     = "jdbc:mysql://192.168.1.80:3306/mes?useSSL=false&serverTimezone=Asia/Shanghai&characterEncoding=utf8",
    "driver_url"   = "mysql-connector-java-8.0.30.jar",
    "driver_class" = "com.mysql.cj.jdbc.Driver",
    "only_specified_database" = "true",
    "lower_case_table_names"  = "true"
);

-- -----------------------------------------------------------------------------
-- 3. 使用
-- -----------------------------------------------------------------------------
-- 切到该 Catalog 浏览
-- SWITCH mysql_mes;
-- SHOW DATABASES;
-- SHOW TABLES FROM mes;

-- 联邦查询（谓词、聚合会尽量下推到 MySQL）
-- SELECT d.line_code, m.material_name, SUM(d.input_qty)
-- FROM demo.dwd_yield_daily d
-- JOIN mysql_mes.mes.material m ON d.product_code = m.code
-- WHERE d.stat_date = '2026-11-01'
-- GROUP BY 1,2;

-- -----------------------------------------------------------------------------
-- 4. 把 Catalog 数据拉进 Doris（一次性小表初始化可用，大表请用 SeaTunnel）
--    注意：这会走 Doris 的导入通道，受 BE 内存与版本数限制
-- -----------------------------------------------------------------------------
-- INSERT INTO ods.ods_mes_material
-- SELECT code, name, spec, unit, now(), 'MES', 'catalog_init_20261101'
-- FROM mysql_mes.mes.material;

-- -----------------------------------------------------------------------------
-- 5. 运维
-- -----------------------------------------------------------------------------
-- SHOW CATALOGS;
-- REFRESH CATALOG mysql_mes;          -- 元数据缓存刷新
-- DROP CATALOG IF EXISTS mysql_mes;
