# Doris ETL 入仓实践指南

> 面向本仓库这套 6 节点 Doris 集群（4.0.8 / 3 FE 4C8G / 3 BE 8C16G / 3 副本）。
> 目标：把 MES、ERP、质量系统、文件、Kafka 的数据稳定、可重复、可回溯地灌进 Doris。

---

## 0. 先纠正一个认知：Doris 的"ETL"是两段，不是一段

传统数仓里 ETL 是一个工具从头干到尾（抽 → 转 → 载）。Doris 的做法不一样：

| 阶段 | 由谁承担 | 用什么 | 特点 |
|---|---|---|---|
| **入仓**（Extract + Load） | Doris 导入机制 / 外部连接器 | Stream Load、Broker Load、Routine Load、JDBC Catalog | Doris 自己定义的一套协议，**不是标准 SQL** |
| **加工**（Transform） | Doris SQL 引擎 | `INSERT INTO ... SELECT`、异步物化视图 | 就是普通 SQL，跑在 BE 上 |

理解这一点，后面所有选型都清楚了：

- **数据从哪来 → 决定用哪种导入方式**（第 2 节的矩阵）
- **仓内怎么加工 → 就是写 SQL**（第 3.5 节），没有"存储过程"这一说

另外两个必须知道的事实：

1. **Doris 所有查询都要经过 BE**，包括 `SELECT 1`。所以"连得上 FE 但报 No backend available"是 BE 没注册，不是网络问题。
2. **每次导入都会生成一个新版本（version）**。这是后面"版本堆积"问题的根源，也是 ETL 设计里最容易踩的坑（见 §4.4）。

---

## 1. 分层怎么分，每层用什么表模型

制造业数据仓建议四层，跟业界 ODS/DWD/DWS/ADS 一致：

```
源系统                 ODS（贴源）            DWD（明细）        DWS（汇总）        ADS（应用）
MES ─┐
ERP ─┼─→ ods_xxx ──────→ dwd_xxx ────────→ dws_xxx ───────→ ads_xxx ──→ BI / 报表 / 接口
QMS ─┤   Duplicate        Unique/Dup        Aggregate/Unique   Unique
文件 ┘   按天分区          按天分区           按天+维度聚合       小表直查
```

| 层 | 表模型 | 分区 | 分桶 | 谁写入 | 保留 |
|---|---|---|---|---|---|
| **ODS** | Duplicate（不聚合、不去重，原样落地） | 按天 | 3（= BE 数） | ETL 导入 | 90 天（够回溯即可） |
| **DWD** | Unique Key（同主键覆盖，天然幂等） | 按天 | 3~6 | `INSERT INTO SELECT` | 1~2 年 |
| **DWS** | Aggregate 或 Unique | 按天/按月 | 3 | `INSERT INTO SELECT` | 2 年 |
| **ADS** | Unique | 不分区/按月 | 1~3 | 物化视图或 SQL | 不限 |

**关键约定**：

- ODS **不要**做任何清洗。字段名、类型、空值全部照抄源系统，只加三列：`etl_time`（入仓时间）、`src_sys`（来源系统）、`batch_id`（批次号）。出了问题才能回查。
- DWD 才做清洗、去重、维度关联、码值标准化。
- DWS 只放**可复用**的聚合（按产线/产品/班次/日期）。一次性需求直接写 ADS 或临时 SQL，别往 DWS 塞。

本仓库 `sql/01-init.sql` 里的 `demo.dwd_yield_daily` 就是 DWD 层的样板。

### 命名规范（建议强制）

| 对象 | 规则 | 示例 |
|---|---|---|
| ODS 表 | `ods_{源系统}_{表名}` | `ods_mes_work_order` |
| DWD 表 | `dwd_{主题}_{粒度}` | `dwd_yield_daily` |
| DWS 表 | `dws_{主题}_{维度}_{周期}` | `dws_yield_line_1d` |
| ADS 表 | `ads_{应用}_{指标}` | `ads_yield_dashboard` |
| 分区名 | `p{yyyyMMdd}` | `p20261101` |
| 导入 Label | `{db}_{table}_{分区}_{批次时间戳}` | `demo_ods_mes_wo_p20261101_20261101103000` |

---

## 2. 导入方式选型矩阵（最重要的一张表）

| 数据源 / 场景 | 推荐方式 | 备选 | 理由 |
|---|---|---|---|
| 本地/脚本生成的文件（CSV、JSON） | **Stream Load** | MySQL Load | HTTP 同步返回，最灵活，几行 curl 就能跑 |
| 业务库 MySQL/Oracle/SQL Server 全量初始化 | **SeaTunnel / DataX**（内部走 Stream Load） | JDBC Catalog + `INSERT INTO SELECT` | 千万级以内一次拉完，自动分片并发 |
| 业务库增量（有 update/delete） | **Flink CDC** 或 SeaTunnel CDC | 时间戳增量 + Unique Key | 只有 CDC 能拿到删除，时间戳方案拿不到 |
| 业务库只需"能查"，不需入仓 | **JDBC Catalog**（联邦查询，不落库） | — | 省存储，适合维表关联和小表 |
| 对象存储 / HDFS 上的大文件（>10G） | **Broker Load** | Stream Load 分批 | 异步任务，FE 直接调度 BE 拉取，不经过客户端 |
| Kafka 实时流 | **Routine Load** | Flink + Doris Connector | 常驻作业，自动断点续传，无需额外组件 |
| 仓内层间加工（ODS→DWD→DWS） | **`INSERT INTO ... SELECT`** | 异步物化视图 | 就是 SQL，BE 并行执行 |
| 高频固定聚合（看板） | **异步物化视图** | 定时跑 DWS | 自动刷新，查询直接命中 MV |

**给你这套环境的建议路线**（按投入产出排序）：

```
第 1 周：Stream Load 打通文件入仓 + INSERT INTO SELECT 做层间加工   ← 覆盖 80% 场景，零额外组件
第 2 周：SeaTunnel 接 MySQL 全量 + 增量（有 update 用 Unique Key 覆盖）
第 3 周：Routine Load 接 Kafka（如果有实时需求）
以后：  Flink CDC、物化视图、DataX 按需补
```

**不要一上来就上 Flink**。3 个 BE、16G 内存的集群，Flink 集群本身就要吃掉一台机器，且 CDC 全量阶段对源库压力大。先把批处理跑稳。

---

## 3. 六种方式，逐个给可运行示例

### 3.1 Stream Load：文件入仓的主力

原理：HTTP PUT 到 **BE 的 8040 端口**（不是 FE 的 8030），BE 直接把数据写成 Rowset，同步返回结果。

```bash
curl --location-trusted \
  -u root:'Doris@2026' \
  -H 'label:demo_ods_mes_wo_p20261101_20261101103000' \
  -H 'column_separator:,' \
  -H 'columns:wo_no,line_code,product_code,qty,start_time,etl_time' \
  -H 'max_filter_ratio:0.01' \
  -H 'strict_mode:false' \
  -T /tmp/work_order.csv \
  'http://192.168.1.54:8040/api/ods/ods_mes_work_order/_stream_load'
```

返回体（务必解析，不要只看 HTTP 200）：

```json
{"Status":"Success","NumberTotalRows":10000,"NumberLoadedRows":9998,
 "NumberFilteredRows":2,"ErrorURL":"http://192.168.1.54:8040/api/_load_error_log?file=..."}
```

三个必须处理的点：

1. **`Status` 才是结果**。HTTP 200 但 `Status=Fail` 是常见情况（比如字段类型不符）。
2. **`ErrorURL` 是死信入口**，里面有被过滤行的原文和原因，ETL 一定要把它落盘留存。
3. **`label` 全局唯一**。同一个 label 重复提交，Doris 返回 `Label Already Exists` —— 这正是幂等的实现方式（§4.1）。

`-H 'columns:...'` 可以只写一部分列，其余列走默认值；也可以写表达式做轻量转换：

```
-H 'columns:wo_no,line_code,qty,start_time=now(),etl_time=now()'
-H 'columns:dt,col1,col2,tmp_col' -H 'where: tmp_col != ""'   # 过滤行
```

### 3.2 MySQL 全量 / 增量：脚本版（零依赖）

`etl/jobs/mysql_to_doris.sh` 是最小可用方案：用 `mysql` 客户端导出 TSV，`curl` 推到 BE。不装任何 Python 包，服务器上就能跑。适合日增几十万行以内的表。

```bash
# 全量
./mysql_to_doris.sh --source-host 192.168.1.80 --source-db mes --source-table work_order \
                    --target-db ods --target-table ods_mes_work_order --mode full

# 增量（用 update_time 水位，自动记录到 .watermark 文件）
./mysql_to_doris.sh ... --mode incr --cursor-col update_time
```

### 3.3 SeaTunnel：业务库入仓的推荐工具

SeaTunnel 是 Doris 官方生态里最顺手的批流一体 ETL 工具，配置即代码，内置 Doris Sink（内部用 Stream Load），支持断点续传、分片并发。

最小配置 `mysql2doris.conf`：

```hocon
env {
  parallelism = 3          # 与 BE 数量对齐，别超过 BE 数太多
  job.mode = "BATCH"
}

source {
  Jdbc {
    url = "jdbc:mysql://192.168.1.80:3306/mes"
    driver = "com.mysql.cj.jdbc.Driver"
    user = "readonly"
    password = "***"
    query = "SELECT wo_no,line_code,product_code,qty,start_time,update_time FROM work_order WHERE update_time >= '${last_ts}'"
    partition_column = "id"     # 全量时按主键切分并发
    partition_num = 3
  }
}

sink {
  Doris {
    fenodes = "192.168.1.51:8030"
    username = "etl"
    password = "Etl@2026"
    database = "ods"
    table = "ods_mes_work_order"
    sink.enable-2pc = "true"            # 两阶段提交，保证一批全成功或全失败
    sink.label-prefix = "ods_wo_${batch_id}"
    doris.config = {
      format = "json"
      read_json_by_line = "true"
    }
  }
}
```

装法（单机模式足够，跑在 node-01 或一台独立 ETL 机上）：

```bash
wget https://archive.apache.org/dist/seatunnel/2.3.9/apache-seatunnel-2.3.9-bin.tar.gz
tar xzf apache-seatunnel-2.3.9-bin.tar.gz -C /opt/
cd /opt/apache-seatunnel-2.3.9 && ./bin/install-plugin.sh 2.3.9
./bin/seatunnel.sh -c mysql2doris.conf -m local
```

### 3.4 JDBC Catalog：不入仓也能查（维表首选）

适合"源表不大、变化频繁、不想到 Doris 存一份"的场景，比如供应商主数据、物料主数据。

```sql
CREATE CATALOG IF NOT EXISTS mysql_mes PROPERTIES (
  "type"         = "jdbc",
  "user"         = "readonly",
  "password"     = "***",
  "jdbc_url"     = "jdbc:mysql://192.168.1.80:3306/mes?useSSL=false",
  "driver_url"   = "mysql-connector-java-8.0.30.jar",
  "driver_class" = "com.mysql.cj.jdbc.Driver"
);

-- 直接联邦查询，Doris 负责把谓词下推给 MySQL
SELECT d.line_code, m.material_name, SUM(d.qty)
FROM demo.dwd_yield_daily d
JOIN mysql_mes.material m ON d.product_code = m.code
GROUP BY 1,2;
```

> 注意：Catalog 的 `driver_url` 需要把 jar 放到 FE 的 `jdbc_drivers/` 目录，或用 HTTP URL 指向内网可达地址。**联邦查询适合小表关联，大表 JOIN 会把压力压到源库**，别拿它当 ETL 用。

### 3.5 层间加工：`INSERT INTO SELECT`

这是 Doris 里"写 ETL 逻辑"的标准形式。它走的是导入通道（会生成新版本），所以也有事务性和幂等性。

```sql
-- ODS → DWD：清洗 + 去重 + 补维度（按分区覆盖，避免重复累加）
INSERT INTO demo.dwd_yield_daily
SELECT
    stat_date, factory_code, line_code, product_code, process_code,
    SUM(input_qty), SUM(output_qty), SUM(defect_qty),
    ROUND(SUM(output_qty) / NULLIF(SUM(input_qty),0) * 100, 4),
    NOW()
FROM ods.ods_mes_yield_raw
WHERE stat_date = '2026-11-01'          -- 只跑当天分区
  AND input_qty > 0                      -- 过滤脏数据
GROUP BY 1,2,3,4,5;
```

**三条纪律**：

1. **必须带分区过滤**。不带 `WHERE dt = ...` 会全表扫描 + 全量重写，16G 的 BE 直接 OOM。
2. **先删/后写，或依赖 Unique Key 覆盖**。Duplicate 模型重复跑会翻倍，Unique 模型天然覆盖。
3. **`INSERT INTO ... VALUES` 只用于测试**。生产环境每条 insert 都会生成一个小文件，几百次之后就是灾难。

### 3.6 Kafka：Routine Load

常驻作业，Doris 自己消费 Kafka，不需要外部程序。

```sql
CREATE ROUTINE LOAD demo.rl_yield_rt ON dwd_yield_rt
COLUMNS(stat_date, factory_code, line_code, product_code, process_code,
        input_qty, output_qty, defect_qty, yield_rate, etl_time=now())
PROPERTIES (
  "format"                = "json",
  "jsonpaths"             = "[\"$.stat_date\",\"$.factory_code\",\"$.line_code\",\"$.product_code\",\"$.process_code\",\"$.input_qty\",\"$.output_qty\",\"$.defect_qty\",\"$.yield_rate\"]",
  "max_batch_interval"    = "20",        -- 最长 20 秒攒一批
  "max_batch_rows"        = "300000",
  "max_batch_size"        = "209715200", -- 200MB，配合 16G BE 的合理上限
  "max_error_number"      = "100",       -- 允许的脏数据条数，超过则作业暂停
  "strict_mode"           = "false"
)
FROM KAFKA (
  "kafka_broker_list"        = "192.168.1.90:9092",
  "kafka_topic"              = "mes.yield.realtime",
  "property.group.id"        = "doris_yield_rt",
  "property.kafka_default_offsets" = "OFFSET_END"
);
```

运维命令：

```sql
SHOW ROUTINE LOAD FOR demo.rl_yield_rt\G      -- State=RUNNING、Lag、ErrorRows
PAUSE ROUTINE LOAD FOR demo.rl_yield_rt;
RESUME ROUTINE LOAD FOR demo.rl_yield_rt;
STOP ROUTINE LOAD FOR demo.rl_yield_rt;
```

### 3.7 大文件：Broker Load

数据已经在 S3 / HDFS / OSS 上（>10G），不要让客户端中转：

```sql
LOAD LABEL ods.ods_wo_20261101
(
  DATA INFILE("s3://chot-data/ods/work_order/20261101/*.parquet")
  INTO TABLE ods.ods_mes_work_order
  FORMAT AS "parquet"
)
WITH S3 (
  "AWS_ENDPOINT"   = "http://192.168.1.100:9000",
  "AWS_ACCESS_KEY" = "minioadmin",
  "AWS_SECRET_KEY" = "***",
  "AWS_REGION"     = "us-east-1"
)
PROPERTIES ("timeout" = "3600", "max_filter_ratio" = "0.01");
```

提交后是异步任务，用 `SHOW LOAD WHERE LABEL='ods_wo_20261101'` 查进度。

---

## 4. 十条编写原则（踩过的坑都在这）

### 4.1 幂等：靠 Label，不靠"小心"

**原则**：任何一次导入都必须可以用同一个 Label 重复执行而不产生重复数据。

```python
label = f"{db}_{table}_{partition}_{batch_ts}"   # 批次级唯一，不是随机
```

- 同一个 Label 重复提交 → Doris 返回 `Label Already Exists`，**直接当成成功**。
- 重试时**必须用原 Label**，不要生成新的（生成新的就变成重复写入）。
- Label 默认保留 3 天（`label_keep_max_second`），三天内可重放；跨天的重跑要靠分区覆盖（§4.2）。

> 这就是"至少一次投递 + 幂等写入 = 恰好一次"的工程实现。

### 4.2 分区对齐：所有重跑都必须是"覆盖"，不是"追加"

| 表模型 | 重跑行为 | 正确做法 |
|---|---|---|
| Duplicate（ODS） | 重复追加 → 数据翻倍 | 跑前 `TRUNCATE PARTITION` 或 `DELETE FROM ... WHERE dt=` |
| Unique（DWD/ADS） | 同 key 覆盖，天然幂等 | 直接重跑即可 |
| Aggregate（DWS） | **累加**，重跑必错 | 必须覆盖分区，不能重跑 |

ODS 层用 Duplicate 是为了保留原始快照，代价就是必须自己管覆盖：

```sql
ALTER TABLE ods.ods_mes_work_order DROP PARTITION IF EXISTS p20261101;
ALTER TABLE ods.ods_mes_work_order ADD PARTITION p20261101 VALUES [("2026-11-01"),("2026-11-02"));
-- 再导入
```

> **实测提醒**：`dynamic_partition.history_partition_num` 在本集群（4.0.8-rc02）**没有生效** —— 建表后只生成了当天及之后的分区，历史分区仍需按上面的方式手工补。别指望这个参数做历史回补。

### 4.3 攒批：单批 100MB ~ 1GB

| 批次太小（<10MB） | 批次太大（>2GB） |
|---|---|
| 版本堆积、compaction 追不上、元数据膨胀 | 超过 `streaming_load_max_mb`，导入失败；内存吃满 |

- 批处理场景：**每次导入 100MB~1GB**，或按天/按小时聚合后导入。
- 实时场景：`max_batch_interval` 设 10~20 秒，`max_batch_size` 设 100~200MB。
- 集合通信设备（MES 类）日增通常几十 MB 到几百 MB，**一天 1~4 批**就够。

### 4.4 控制版本数：这是 Doris 最容易炸的地方

每次导入，**每个 tablet 都会生成一个新版本**。3 分桶 × 3 副本 = 9 个版本/次导入；一天导 100 次就是 900 个版本。

本集群 `max_tablet_version_num = 2000`，超过就报：

```
[E-235] Too many versions. tablet_id: xxx, version_count: 2001
```

四个应对手段，按优先级：

| 手段 | 做法 | 代价 |
|---|---|---|
| **减少导入频次**（最有效） | 攒批，一天 1~4 次 | 数据延迟增加 |
| 减少分桶数 | 小表 1~3 分桶即可，别按"分桶越多越快"来 | 并行度下降 |
| 强制 compaction | `ALTER TABLE t COMPACT;`（可指定分区） | 占 IO，短时影响查询 |
| 调大上限 | `max_tablet_version_num = 5000` | 查询时要合并更多版本，变慢 |

**判断依据**：巡检里看 `SHOW PROC '/statistic'` 的 `UnhealthyTabletNum`，以及 BE metrics 的 `doris_be_engine_requests_total{type="compaction"}`。

### 4.5 错误容忍：`max_filter_ratio` 不是越大越好

| 值 | 语义 | 适用 |
|---|---|---|
| `0` | 一条脏数据就整批失败 | 财务、结算类，绝不允许错 |
| `0.01` ~ `0.05` | 容忍 1%~5% | 一般业务数据，配合死信留存 |
| `1` | 全过滤也"成功" | **禁止**，等于关掉了数据质量门禁 |

**必须配套**：解析返回体里的 `ErrorURL`，把过滤行下载下来存档，并计入监控。否则"导入成功"只是假象。

### 4.6 顺序：先维表，后事实表

DWD 事实表要关联维表时，**维表必须先入仓**。调度上把依赖关系写进 DAG，不要靠"跑得快刚好赶上了"。

### 4.7 时间与类型：统一到毫秒 + UTC/本地二选一

| 项 | 约定 |
|---|---|
| 时间字段 | 统一 `DATETIME(3)`，**全链路统一时区**（建议源系统、ETL 机、Doris 都用 `Asia/Shanghai`） |
| 主键 | 用业务主键（`wo_no`、`batch_no`），不要用自增 ID |
| 金额/数量 | `DECIMAL(18,4)`，不要用 `FLOAT`（求和会漂） |
| 字符串 | ODS 层一律 `STRING`，DWD 层再收窄，避免源字段变长导致导入失败 |
| 空值 | CSV 用 `\N`，JSON 用 `null`，不要混用空字符串 |

### 4.8 模型选择错了，后面全是补丁

| 你的数据特征 | 用哪个模型 |
|---|---|
| 只追加（日志、流水、埋点） | **Duplicate** |
| 有更新（订单状态、工单进度） | **Unique Key**（4.x 默认写时合并，查询快） |
| 导入即聚合（按天按产线汇总） | **Aggregate**（SUM/REPLACE/MAX） |
| 需要部分列更新 | **Unique + `partial_columns=true`** |

### 4.9 资源隔离：ETL 别把查询打死

白天跑 ETL 会抢 BE 的 CPU 和内存，看板直接卡死。用 Workload Group 隔离：

```sql
CREATE WORKLOAD GROUP etl_group
PROPERTIES ("max_concurrency" = "8", "memory_limit" = "40%");

-- Stream Load 时指定
-H 'workload_group:etl_group'
```

或直接错峰：ETL 放在 01:00~06:00，看板高峰不跑重任务。

### 4.10 可观测：每个批次都要留痕

每次导入必须记录这张表（建议自己建一张 `ops.etl_job_log`）：

| 字段 | 用途 |
|---|---|
| `batch_id` / `label` | 回溯入口，能查到这次导了什么 |
| `src_rows` / `loaded_rows` / `filtered_rows` | 数据量对账 |
| `status` / `error_url` | 失败定位 |
| `start_ts` / `end_ts` / `duration` | 性能趋势 |
| `partition` | 覆盖范围 |

**对账是底线**：`源表 count` = `loaded_rows`，不等就告警。没有对账的 ETL，等于没有 ETL。

---

## 5. 本集群的参数红线（16G BE 专用）

| 参数 | 当前生效值 | ETL 含义 |
|---|---|---|
| `mem_limit` | 80%（约 12.8G） | BE 内存硬上限，超了直接 OOM Kill |
| `load_process_max_memory_limit_percent` | 30%（约 3.8G） | **所有导入加起来**只能用这么多，所以并发导入 ≤ 3 |
| `streaming_load_max_mb` | 2048（待重启生效，默认 102400） | 单次 Stream Load 上限 2G，超过就分批 |
| `compaction_memory_bytes_limit` | 1G（待重启改成 6G） | compaction 内存太小会追不上导入，版本堆积 |
| `max_tablet_version_num` | 2000 | 见 §4.4 |

**由此推出的三条硬约束**：

1. **同时最多 3 个导入任务**（每个按 1.2G 估算）。第 4 个开始必出 `Memory limit exceeded`。
2. **单个文件不超过 2G**。大文件先 `split -l 500000` 切分再并发导入。
3. **日增数据量上限约 20G**（400G 盘 × 3 节点 ÷ 3 副本）。超了要加盘加内存，不是调参能解决的。

---

## 6. 调度编排

### 6.1 最小方案：crontab（适合 1~5 个作业）

```cron
# 每天 01:30 拉 ODS，02:00 加工 DWD，02:30 加工 DWS
30 1 * * * /opt/ai4doris/etl/jobs/run_daily.sh ods   >> /var/log/etl/ods.log 2>&1
0  2 * * * /opt/ai4doris/etl/jobs/run_daily.sh dwd   >> /var/log/etl/dwd.log 2>&1
30 2 * * * /opt/ai4doris/etl/jobs/run_daily.sh dws   >> /var/log/etl/dws.log 2>&1
```

**问题**：没有依赖、没有重试、没有告警。作业超过 5 个就该换。

### 6.2 推荐方案：DolphinScheduler（国产、可视化、轻量）

- 单机部署约 8G 内存（**别装在 BE 节点上**，会抢内存）
- 优势：DAG 可视化、失败重试、补数（按历史日期批量重跑）、告警（钉钉/企业微信）
- 对制造业场景非常合适，中文文档完善

### 6.3 标准 DAG 结构

```
[抽 ODS] ──→ [校验行数] ──→ [加工 DWD] ──→ [加工 DWS] ──→ [刷新 ADS/MV] ──→ [发日报]
     │             │
     └─失败→重试3次─┘──→ 失败告警（企业微信）
```

**核心是中间那个"校验行数"节点**：源表 count 与导入 `NumberLoadedRows` 对比，不等就阻断下游。这是防止"脏数据流到看板"的唯一有效手段。

---

## 7. 教程与资料（按学习顺序）

| 顺序 | 内容 | 地址 |
|---|---|---|
| 1 | 导入总览（先看这张选型图） | https://doris.apache.org/docs/data-operate/import/ |
| 2 | Stream Load 手册（最常用，精读） | https://doris.apache.org/docs/data-operate/import/import-way/stream-load-manual |
| 3 | 数据模型与建表（Duplicate/Unique/Aggregate） | https://doris.apache.org/docs/table-design/data-model/ |
| 4 | 分区分桶原理 | https://doris.apache.org/docs/table-design/data-partition/ |
| 5 | Routine Load（Kafka） | https://doris.apache.org/docs/data-operate/import/import-way/routine-load-manual |
| 6 | Broker Load（对象存储） | https://doris.apache.org/docs/data-operate/import/import-way/broker-load-manual |
| 7 | JDBC Catalog（联邦查询） | https://doris.apache.org/docs/lakehouse/database/jdbc |
| 8 | 物化视图 | https://doris.apache.org/docs/query/materialized-view/ |
| 9 | Flink Doris Connector | https://doris.apache.org/docs/ecosystem/flink-doris-connector |
| 10 | SeaTunnel Doris Sink | https://seatunnel.apache.org/docs/connector-v2/sink/Doris |

> 官方文档版本号要切到 **4.0**，默认可能展示最新版（4.1/5.x），部分语法有差异。

---

## 8. 落地路线（四周）

| 周 | 目标 | 产出 | 验收标准 |
|---|---|---|---|
| **1** | 打通文件入仓 | ODS 表 + `file_stream_load.py` + 一个能跑的批处理 | 手工放一个 CSV，能查到数 |
| **2** | 接一个真实业务表 | MySQL → ODS 全量 + 增量，DWD 加工 SQL | 源表 count = 入仓 count，重跑不翻倍 |
| **3** | 上调度 + 监控 | crontab 或 DolphinScheduler DAG + 对账告警 | 连续 5 天自动跑通，失败能收到告警 |
| **4** | 补第二个源 + 优化 | 第二张表、分区覆盖、版本数观察 | 巡检 `UnhealthyTabletNum = 0` |

**第一周只要能跑通"一个 CSV 进 ODS 再进 DWD"，这个项目就成功了 70%**。剩下的都是复制粘贴。

---

## 9. 故障速查

| 现象 | 原因 | 处理 |
|---|---|---|
| `[E-235] Too many versions` | 导入太频繁，版本堆积 | 攒批 / `ALTER TABLE t COMPACT` / 调大 `max_tablet_version_num` |
| `Label Already Exists` | 同一 label 重复提交 | **视为成功**；要重跑就换 label 或先删分区 |
| `Memory limit exceeded` | 并发导入超过 `load_process_max_memory_limit` | 降到 ≤3 并发，或缩小批次 |
| `No backend available` | BE 未注册 / 全部 dead | `SHOW BACKENDS` 检查，FE 起来后必须 `ADD BACKEND` |
| 导入 HTTP 200 但 `Status=Fail` | 字段类型不符 / 分区不存在 | 看 `Message` 和 `ErrorURL`；动态分区表注意历史分区（§4.2） |
| `TabletWriter write failed, err=-235` | 同上 | 同上 |
| 导入卡住不返回 | 超时太短 | `-H 'timeout:1800'`，FE 侧 `stream_load_default_timeout_second` |
| 数据进去了但查不到 | 事务未 Publish | `SHOW TRANSACTION WHERE LABEL='xxx'` 看状态 |
| 中文乱码 | 编码不是 UTF-8 | Stream Load 加 `-H 'charset:utf-8'`，源文件确认 UTF-8 无 BOM |

---

## 10. 一句话总结

**入仓用 Stream Load（文件）/ SeaTunnel（库）/ Routine Load（流），加工用 `INSERT INTO SELECT`；幂等靠 Label、重跑靠分区覆盖、稳定靠攒批、可信靠对账。**

---

## 11. 实测踩坑（本仓库模板在 4.0.8 上跑通过程中遇到的）

这四条是**写文档时查不到、只有真跑才会暴露**的问题，直接抄模板时不会再踩：

| # | 现象 | 原因 | 解法 |
|---|---|---|---|
| 1 | 建表报 `Unknown properties: {comment=...}` | 4.0.8 **不支持**表属性 `"comment"` | 删掉该属性；注释写在列 `COMMENT` 里 |
| 2 | 建表报 `Key columns should be a ordered prefix of the schema` | `DUPLICATE KEY` 必须是**建表列顺序的前缀**，不能跳列 | key 列按 schema 顺序排列，如 `stat_date, factory_code, line_code, product_code` |
| 3 | 重复导入被判为失败，幂等逻辑不生效 | Doris 返回的是 `[LABEL_ALREADY_EXISTS]`（下划线），不是 `Label already exists` | 判断要同时匹配 `label_already_exists` / `label already exist` / `has already been used` 三种写法 |
| 4 | 动态分区表历史分区补不出来 | `history_partition_num` 未生效 | 关动态分区 → `ADD PARTITION` → 开动态分区 |

第 3 条最隐蔽：不同 Doris 版本返回的提示文案不一样，而**幂等是 ETL 的地基**，判断写错会让"重跑"变成"重复写入"或"误报失败"。`etl/lib/doris_loader.py` 已经三种写法全覆盖。

### 实测验证结果（2026-11-01）

用 `etl/README.md` 的快速开始跑了一遍完整链路：

| 步骤 | 结果 |
|---|---|
| CSV → ODS（Stream Load） | 3 行全部成功，0 过滤 |
| 同一文件重跑 | 成功 0 行 + **幂等命中**，表内仍是 3 行 |
| ODS → DWD → DWS → ADS | 4 层全部写入成功 |
| ADS 结果 | `CHOT` 全厂 133000 投入 / 131833 产出 / **99.1226%**，最差产线 L04 98% |
| 重跑加工 | 结果**完全一致**（Unique Key 覆盖，未翻倍） |
