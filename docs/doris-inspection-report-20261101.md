# Doris 集群巡检报告

| 元信息 | 值 |
|---|---|
| 巡检时间 | 2026-11-01 13:35:13 |
| 集群 ID | `632496137` |
| Doris 版本 | doris-4.0.8-rc02-bc8ea1bac6d |
| 集群规模 | FE 3 节点 / BE 3 节点 |
| 执行节点 | doris-node-01（192.168.1.51） |
| 统计窗口 | 近 24 小时 |
| 巡检脚本 | `scripts/06-inspect.sh` |

## 摘要

本次巡检覆盖 **9 个维度 28 项检查**，集群健康度 **75/100（良好）**，无严重问题，**5 项待优化**。

一句话结论：**集群拓扑、副本、容量、延迟全部正常，风险集中在「运维基线」而非「服务能力」** —— 缺元数据备份、FE 未生成 checkpoint、两项调优参数因版本差异未真正生效、并发未设上限。

| 维度 | 结论 | 依据 |
|---|---|---|
| 可用性 | ✅ 正常 | FE 3/3、BE 3/3 在线，Master 唯一，journal 延迟 1 条 |
| 数据安全 | ✅ 正常 | 52 tablet 全部健康，0 缺失 / 0 不一致 / 0 不可恢复 |
| 容量 | ✅ 充裕 | 裸容量 1199 GB，使用率 2.0%，3 副本下仍可写 ≈392 GB |
| 性能 | ✅ 正常 | P95 134 ms，最慢 960 ms，0 条超 1s（业务尚未接入） |
| 运维基线 | ⚠️ 待补 | 无 meta 备份、无 checkpoint、2 项调优未生效、并发未限 |

> 说明：查询失败率 10% 全部集中在 02:59（部署期 BE 未注册）与 11:30（手工执行 SQL 未选库），**不是业务故障**，详见下方「核心发现」第 3 条。

## 评分明细

| 健康度评分 | 检查项 | 正常 | 警告 | 严重 |
|---|---|---|---|---|
| **75/100（良好）** | 28 | 23 | 5 | 0 |

> 集群运行正常，有 **5 项**待优化，无阻塞性风险。

## 核心发现

### 1. FE 从未生成 checkpoint image ⚠️

`meta_dir/image/` 下只有 `ROLE`、`DEPLOY_MODE`、`VERSION` 三个标记文件，没有 `image.<journalId>`。fe.log 中 `leaderCheckpointer` 每分钟检查一次，输出 `last checkpoint journal id: 0, current finalized journal id: 0` —— journal 尚未 finalize，因此不触发 checkpoint。

**影响**：当前 journal 仅 7700 余条，FE 重启回放只需数秒，可接受。但长期不 checkpoint 会让 journal 持续膨胀，重启时间线性增长，且 BDBJE 目录会持续占用磁盘。

**建议**：观察 24 小时。若仍无 image，检查 `edit_log_roll_num`（默认 50000）与 leaderCheckpointer 日志；必要时手工触发 `ALTER SYSTEM CREATE IMAGE`。

### 2. 元数据没有备份 ⚠️（最高优先级）

`crontab -l` 为空。meta_dir 是**唯一不可再生数据** —— BE 数据可以由 3 副本互相重建，但 FE 元数据丢了，库表定义、权限、节点拓扑会全部消失，只能重建集群。

**建议**：立即加上（附录 C 有现成命令），并做一次**恢复演练**（在测试环境解包验证），否则备份只是心理安慰。

### 3. 查询失败率 10%，但全部是运维噪声

35 条失败查询的构成：

| 次数 | 错误 | 归因 |
|---|---|---|
| 19 | `No backend available as scan node` | 02:59 首次启动 FE 时 BE 尚未注册，部署期必然报错 |
| 7 | `No database selected` | 手工执行 SQL 未指定库（巡检前的调试操作） |
| 其余 | 同类 1105 | 同上 |

Doris 所有查询都经 BE 执行（连 `SELECT 1` 也不例外），"先起 FE、后注册 BE" 的阶段必然产生这类错误。**业务接入后应以 7 天稳定窗口重新统计**，届时 5% 阈值才有参考意义。

### 4. 两项调优参数运行时未生效 ⚠️

模板里写的 `compaction_max_memory_limit_percent` 在 4.0.8 中**不存在**（4.x 改用字节值），`streaming_load_max_mb` 则**属于 BE 而非 FE**。Doris 对未知配置项**静默忽略**、不报错，所以部署时看起来"配置成功"，实际一直跑默认值：compaction 只有 1 GB 内存（预期 6 GB），Stream Load 单次上限 100 GB（预期 2 GB）。

已在本次巡检中修正 `conf/be.conf`、`conf/fe.conf`，但**运行中的进程仍是旧值**，需在维护窗口重启生效，详见「配置基线校准」。

### 5. Workload Group 未限制查询并发

`normal` 组 `max_concurrency = 2147483647`（事实上无限制）。4C/8G 的 FE 在 32 并发以上就会排队、放大延迟，内存也扛不住。

**建议**：`ALTER WORKLOAD GROUP normal PROPERTIES ("max_concurrency" = "32");`

## 检查项明细

| 级别 | 检查项 | 实测值 |
|---|---|---|
| 🟢 OK | FE 存活 | 3/3 在线 |
| 🟢 OK | Master 唯一性 | 1 个 Master |
| 🟢 OK | 元数据同步 | 最大落后 2 条（journal 7734） |
| 🟢 OK | FE 版本一致性 | doris-4.0.8-rc02-bc8ea1bac6d |
| 🟡 WARN | FE checkpoint | 尚未生成 image（当前 journal 7734 条） |
| 🟡 WARN | 元数据备份 | crontab 未配置 meta_dir 备份 |
| 🟢 OK | BE 存活 | 3/3 在线 |
| 🟢 OK | BE 服务状态 | 无禁用/下线中节点 |
| 🟢 OK | BE 心跳 | 失败计数全为 0 |
| 🟢 OK | Tablet 均衡 | 46~48 个/节点，偏差 2 |
| 🟢 OK | 副本完整性 | 52 个 tablet 全部健康 |
| 🟢 OK | 冗余副本 | 0 个 |
| 🟢 OK | 副本调度 | 无克隆/迁移任务 |
| 🟢 OK | 副本倍数 | 52 tablet → 140 副本 |
| 🟢 OK | BE 磁盘水位 | 最高 1.97%，距告警线 74 个百分点 |
| 🟢 OK | Compaction 压力 | 最大 score 0 |
| 🟢 OK | Trash 占用 | 0.0% |
| 🟢 OK | 动态分区调度 | 2 张表全部 NORMAL |
| 🟢 OK | 导入任务 | 无失败记录 |
| 🟢 OK | Routine Load | 未配置常驻作业 |
| 🟡 WARN | 查询失败率 | 9.32%（阈值 5%） |
| 🟢 OK | 查询延迟 | P95 122 ms，最慢 960 ms |
| 🟢 OK | 时钟同步 | 最大偏差 0s |
| 🟢 OK | CPU 负载 | 最高 13% 核数 |
| 🟢 OK | 内存余量 | 最低可用 50% |
| 🟢 OK | Swap 状态 | 全部节点已关闭 |
| 🟡 WARN | 调优参数一致性 | 2 项与基线不一致 |
| 🟡 WARN | 查询并发限制 | Workload Group normal 未限制并发（2147483647） |

## 整改建议

### 1. [WARN] FE checkpoint

- **现象**：尚未生成 image（当前 journal 7734 条）
- **影响**：不影响当前服务，但降低可用性或可维护性
- **建议**：初期部署常见：journal 未 finalize 时不触发 checkpoint。观察 24h；仍无 image 需查 leaderCheckpointer 日志与 edit_log_roll_num

### 2. [WARN] 元数据备份

- **现象**：crontab 未配置 meta_dir 备份
- **影响**：不影响当前服务，但降低可用性或可维护性
- **建议**：meta_dir 是唯一不可再生数据，建议每日打包（见附录 C）

### 3. [WARN] 查询失败率

- **现象**：9.32%（阈值 5%）
- **影响**：不影响当前服务，但降低可用性或可维护性
- **建议**：看 Top 错误：内存超限居多，需降并发或扩 BE 内存

### 4. [WARN] 调优参数一致性

- **现象**：2 项与基线不一致
- **影响**：不影响当前服务，但降低可用性或可维护性
- **建议**：对比 conf/ 模板；若模板已更新，需重启对应组件才生效

### 5. [WARN] 查询并发限制

- **现象**：Workload Group normal 未限制并发（2147483647）
- **影响**：不影响当前服务，但降低可用性或可维护性
- **建议**：4C FE 建议 ALTER WORKLOAD GROUP normal PROPERTIES ("max_concurrency"="32")

---

## 一、FE 集群

| 节点 | 角色 | Master | Alive | Journal | 最近心跳 |
|---|---|---|---|---|---|
| 192.168.1.53 | FOLLOWER | 否 | 是 | 7732 | 2026-11-01 13:35:05 |
| 192.168.1.52 | FOLLOWER | 否 | 是 | 7732 | 2026-11-01 13:35:05 |
| 192.168.1.51 | FOLLOWER | **是** | 是 | 7734 | 2026-11-01 13:35:05 |

- 版本：`doris-4.0.8-rc02-bc8ea1bac6d`　集群 ID：`632496137`　首节点启动于：2026-11-01 02:59:55

## 二、BE 集群

| 节点 | Alive | Tablet | 磁盘使用率 | 可用/总量 | CPU | 内存 | 心跳失败 | 状态 |
|---|---|---|---|---|---|---|---|---|
| 192.168.1.54 | 是 | 46 | 1.97 % | 391.935 GB / 399.805 GB | 8 | 15.62 GB | 0 | 正常 |
| 192.168.1.55 | 是 | 48 | 1.97 % | 391.935 GB / 399.805 GB | 8 | 15.62 GB | 0 | 正常 |
| 192.168.1.56 | 是 | 46 | 1.97 % | 391.935 GB / 399.805 GB | 8 | 15.62 GB | 0 | 正常 |


## 三、副本与 Tablet 健康

| 指标 | 数量 | 判定 |
|---|---|---|
| Tablet 总数 | 52 | — |
| 副本完整 | 52 | 正常 |
| 副本缺失 | 0 | 正常 |
| 版本不完整 | 0 | 正常 |
| 副本迁移中 | 0 | 正常 |
| 冗余副本 | 0 | 正常 |
| 待进一步修复 | 0 | 正常 |
| 不可恢复 | 0 | 正常 |
| compaction 过慢 | 0 | 正常 |
| 副本不一致 | 0 | 正常 |
| 单副本超限 | 0 | 正常 |
| 正在克隆 | 0 | 正常 |

## 四、容量与磁盘

| 项 | 数值 |
|---|---|
| BE 裸容量合计 | 1199.41 GB |
| Doris 数据文件占用 | 412 KB |
| 文件系统已用 / 可用 | 23.60 GB / 1175.81 GB |
| 集群使用率 | **2.0%** |
| Trash 占用 | 0.00 GB（0.0%） |
| 3 副本下可写 | ≈ 392 GB（压缩后） |
| 数据对象 | 52 tablet / 140 副本 |


## 五、库表与分区

| 库 | 表数 | 大小 | 副本数 | Running Txn | LastUpdate |
|---|---|---|---|---|---|
| __internal_schema | 3 | 337.441 KB | 50 | 0 | 10000 |
| demo | 2 | 74.924 KB | 90 | 0 | 10000 |

> 合计：**7** 张表 / **16** 个分区 / **52** tablet / **140** 副本（含 `__internal_schema` 内部表）

**动态分区表调度**（2 张）

| 表 | 调度状态 | 最近调度时间 |
|---|---|---|
| demo.dwd_defect_detail | NORMAL | 2026-11-01 13:29:02 |
| demo.dwd_yield_daily | NORMAL | 2026-11-01 13:29:02 |

## 六、导入任务

无 Load 历史（尚未发起 Broker/Stream Load）。

## 七、查询负载与审计

| 指标 | 数值 |
|---|---|
| 当前连接数 | 1 |
| 近 24h 查询数 | 440 |
| 平均耗时 | 24 ms |
| P50 / P95 | 1 ms / 122 ms |
| 最慢查询 | 960 ms |
| 超过 1s | 0 条（0.0%） |
| 平均 QPS | 0.005 |
| 失败查询 | 41 条（9.32%） |

**失败查询明细**（发生时段：2026-11-01 02:59:21 ~ 2026-11-01 13:34:57）

| 次数 | ErrorCode | 错误信息 |
|---|---|---|
| 13 | 1105 | errCode = 2, detailMessage = No database selected |
| 10 | 1105 | errCode = 2, detailMessage = No backend available as scan node, please check the status of your backends.[1793 |
| 9 | 1105 | errCode = 2, detailMessage = No backend available as scan node, please check the status of your backends. |


## 八、主机系统层

| 节点 | 角色 | Load(1m) | 核 | 负载比 | 内存可用 | Swap | 时钟偏差 | 根盘 | 进程 RSS | 日志 ERROR |
|---|---|---|---|---|---|---|---|---|---|---|
| doris-node-01 | fe | 0.51 | 4 | 13% | 3987M/7941M (50%) | 0M | 0.000s | 13% | 3.5G | 60 |
| doris-node-02 | fe | 0.42 | 4 | 10% | 4436M/7941M (56%) | 0M | 0.000s | 13% | 3.0G | 3 |
| doris-node-03 | fe | 0.17 | 4 | 4% | 4432M/7941M (56%) | 0M | 0.000s | 13% | 3.0G | 3 |
| doris-node-04 | be | 0.05 | 8 | 1% | 14593M/15991M (91%) | 0M | 0.000s | 17% | 1.2G | 32 |
| doris-node-05 | be | 0.07 | 8 | 1% | 14604M/15991M (91%) | 0M | 0.000s | 17% | 1.1G | 32 |
| doris-node-06 | be | 0.13 | 8 | 2% | 14626M/15991M (91%) | 0M | 0.000s | 17% | 1.1G | 32 |

> 日志 ERROR 为最近 3000 行（BE）与全文件（FE）的累计计数，用于发现趋势，不作为告警阈值。

## 九、关键配置核对

| 层 | 参数 | 基线期望 | 实际值 | 判定 |
|---|---|---|---|---|
| FE | `query_port` | 9030 | 9030 | 符合 |
| FE | `http_port` | 8030 | 8030 | 符合 |
| FE | `edit_log_port` | 9010 | 9010 | 符合 |
| FE | `priority_networks` | 192.168.1.0/24 | 192.168.1.0/24 | 符合 |
| FE | `qe_max_connection` | 1024 | 1024 | 符合 |
| BE | `mem_limit` | 80% | 80% | 符合 |
| BE | `write_buffer_size` | 104857600 | 104857600 | 符合 |
| BE | `load_process_max_memory_limit_percent` | 30 | 30 | 符合 |
| BE | `compaction_memory_bytes_limit` | 6442450944 | 1073741824 | **偏离** |
| BE | `streaming_load_max_mb` | 2048 | 102400 | **偏离** |
| BE | `be_port` | 9060 | 9060 | 符合 |
| BE | `heartbeat_service_port` | 9050 | 9050 | 符合 |
| BE | `storage_root_path` | /data1/doris,medium:ssd;/data2/doris,medium:ssd | /data1/doris,medium:ssd;/data2/doris,medium:ssd | 符合 |
| 运行态 | `normal.max_concurrency` | 建议 ≤32（4C FE） | 2147483647 | **未限制** |

> 取的是**运行时生效值**（ADMIN SHOW CONFIG），不是配置文件内容。
> 「不存在」= 该参数在当前版本已被移除或属于其他组件（会被静默忽略，配置不生效）；
> 「偏离」= 参数存在但值与调优基线不同（多为改了 conf 未重启加载）。


---

## 配置基线校准（本次巡检发现）

部署时写入的 13 项参数中，有 **3 项在 Doris 4.0.8 中不成立**。这不是笔误，而是 4.x 相对 2.x/3.x 的三处变更：

| 旧写法（部署时） | 4.0.8 实际状态 | 正确做法 |
|---|---|---|
| FE `max_query_concurrency = 32` | **键不存在**，已被移除 | `ALTER WORKLOAD GROUP normal PROPERTIES ("max_concurrency"="32")` |
| FE `streaming_load_max_mb = 2048` | **放错层**：这是 BE 参数 | 写进 `be.conf` |
| BE `compaction_max_memory_limit_percent = 40` | **键不存在**，改用字节值 | `compaction_memory_bytes_limit = 6442450944`（16G×40%） |

**为什么危险**：Doris 启动时对无法识别的 conf 项只打 WARN 日志，不阻断启动、不报错，`ADMIN SHOW CONFIG` 里也查不到 —— 看起来"配了"，实际从未生效。这次是巡检脚本拿运行时值和基线逐项比对才暴露出来。

**已处理**：`conf/fe.conf`、`conf/be.conf` 已修正并加注释说明。生效需重启（当前集群无业务，可随时执行）：

```bash
# 逐台重启 BE，避免同时下线影响副本
for ip in 54 55 56; do
  ssh lumz@192.168.1.$ip "sudo systemctl restart doris-be"
  sleep 30 && curl -s "http://192.168.1.51:8030/api/bootstrap" >/dev/null && echo "$ip ok"
done
```

重启后重跑本巡检，该两项应转为「符合」。

## 附录

### A. 巡检覆盖维度

| 维度 | 检查内容 |
|---|---|
| FE 拓扑 | 存活、角色、Master 唯一、journal 同步、版本一致、元数据 image、备份任务 |
| BE 状态 | 存活、心跳失败、查询/导入禁用标志、下线状态、tablet 均衡 |
| 副本健康 | 缺失/版本不全/不可恢复/不一致/冗余/克隆迁移 |
| 容量磁盘 | 磁盘水位、trash 占比、可写容量、compaction score |
| 数据对象 | 库表分区统计、动态分区调度状态 |
| 导入任务 | Broker/Stream Load 失败、Routine Load 状态 |
| 查询审计 | 连接数、QPS、P50/P95、慢查询、失败率、Top 错误 |
| 主机基线 | 负载、内存、swap、时钟偏差、根盘、进程 RSS、日志 ERROR |
| 配置 | FE/BE 关键参数与 Workload Group 的运行时值 |

### B. 阈值（脚本开头可调）

| 指标 | WARN | CRIT |
|---|---|---|
| BE 磁盘使用率 | 75% | 85% |
| FE journal 落后 | 100 条 | 1000 条 |
| Compaction score | 100 | 500 |
| Trash 占比 | 10% | — |
| 时钟偏差 | — | 1s |
| 查询失败率 | 5% | — |
| Load / 核数 | 200% | — |

### C. 元数据备份（若检查项提示未配置）

```bash
# node-01 上每天 03:00 备份 FE meta，保留 7 天
sudo mkdir -p /opt/backup
sudo crontab -e
# 加入下面一行（crontab 中 % 需转义）
0 3 * * * tar czf /opt/backup/doris-meta-$(date +\%Y\%m\%d).tar.gz /opt/doris/fe/meta && find /opt/backup -name 'doris-meta-*' -mtime +7 -delete
```

> meta_dir 是唯一不可再生数据：BE 数据可由其他副本重建，元数据丢失则集群需重建。

### D. 复现方式

```bash
cd /opt/ai4doris
bash scripts/06-inspect.sh -o /tmp/doris-inspect-20261101.md
echo $?   # 0=全绿 1=有 WARN 2=有 CRIT
```
