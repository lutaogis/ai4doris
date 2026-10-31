# ai4doris —— 6 节点 Apache Doris 集群

> 3 FE + 3 BE，存算一体，3 副本，单宿主机故障不丢服务。
>
> **集群已搭建完成（2026-11-01）**：连接 `mysql -h192.168.1.51 -P9030 -uroot -p'Doris@2026'`，
> 部署实录见 [docs/doris-deployment-record.md](docs/doris-deployment-record.md)。

**架构原理文档**：[docs/doris-architecture.md](docs/doris-architecture.md)（分层架构、FE/BE 内部机制、数据组织、查询链路、存算分离对比、常见误区）

## 1. 规格与容量

| 角色 | 主机 | vCPU | 内存 | 系统盘 | 数据盘 |
|---|---|---|---|---|---|
| FE ×3 | doris-node-01/02/03（192.168.1.51-53） | 4C | 8G | 100G | — |
| BE ×3 | doris-node-04/05/06（192.168.1.54-56） | 8C | 16G | 100G | 2 × 200G |

**放置**：3 台宿主机，每台 1 FE + 1 BE（A:01+04 / B:02+05 / C:03+06），必须做反亲和。
单台宿主机资源需求：**≥ 24C / 64G / 4 × 200G+**。

**容量测算**

| 项 | 数值 |
|---|---|
| 单 BE 裸盘 | 400G（2×200G），XFS 预留 5% → ≈380G |
| 按 80% 写入水位 | ≈304G / BE |
| 3 BE 合计裸可用 | ≈912G |
| ÷ 3 副本 | **≈304G 可用（压缩后）** |
| 按 3:1 压缩反推原始数据 | **≈900G** |
| 日增 20G → 保留天数 | **≈45 天** |

**适用边界**：部门级生产 / 中小报表 / 良率类日增量数据，日增 ≤ 20G、保留 ≤ 3 个月。
不适合：PB 级、高并发点查、原始日志全量留存。

## 2. 目录结构

```
ai4doris/
├── nodes.env                  节点清单（改 IP 只改这里）
├── conf/
│   ├── fe.conf                FE 配置（4C/8G 调优）
│   └── be.conf                BE 配置（16G 内存收紧）
├── scripts/
│   ├── 00-init-os.sh          系统初始化（六台）
│   ├── 01-install.sh          解包 + 铺配置（fe|be）
│   ├── 02-start-fe.sh         启动 FE（首节点 / --follower）
│   ├── 03-register.sh         注册 FOLLOWER / BACKEND（仅 node-01）
│   ├── 04-start-be.sh         启动 BE（node-04/05/06）
│   └── 05-verify.sh           验收巡检（--smoke 冒烟）
└── sql/01-init.sql            建库 + 良率示例表（3 分桶）
```

## 3. 部署六步

> 仓库在集群各节点上的实际位置是 `/opt/ai4doris`（2026-11-01 部署时从 `~/ai4doris` 迁移，
> 因为 `doris` 用户无法读 `/home/lumz`（750 权限）下的文件）。

**前置**：安装包 `apache-doris-4.0.8-bin-x64.tar.gz` 放到每台的 `/opt/doris/pkg/`（FE、BE 节点各需对应包）。

```bash
# 步骤 1：六台都初始化（BE 三台额外格式数据盘）
sudo ./00-init-os.sh doris-node-01 192.168.1.51
...
sudo DATA_DISKS="/dev/vdb /dev/vdc" CONFIRM_FORMAT=yes \
     ./00-init-os.sh doris-node-04 192.168.1.54

# 步骤 2：装包（FE 节点装 fe，BE 节点装 be）
sudo ./01-install.sh fe     # 01/02/03
sudo ./01-install.sh be     # 04/05/06

# 步骤 3：只起首节点
su - doris -c '~/ai4doris/scripts/02-start-fe.sh'

# 步骤 4：注册 follower（此时 02/03 应显示 Alive=false）
./03-register.sh fe

# 步骤 5：起另外两个 FE
su - doris -c '~/ai4doris/scripts/02-start-fe.sh --follower'   # 02、03

# 步骤 6：起 BE 并注册
su - doris -c '~/ai4doris/scripts/04-start-be.sh'              # 04、05、06
./03-register.sh be

# 验收
./05-verify.sh --smoke
```

**顺序不能乱**：FE 必须先注册再启动 follower（follower 靠 `--helper` 拉取元数据）；BE 必须先启动再 ADD BACKEND。

## 4. 关键参数为什么这么改

### FE（4C/8G，官方生产建议 16G，这里是下限）

| 参数 | 值 | 原因 |
|---|---|---|
| `JAVA_OPTS` | `-Xmx4g -Xms4g` | 8G 机器留 4G 给 OS、页缓存、BDBJE；堆开满会导致系统 OOM Killer 杀进程 |
| `sys_log_roll_num` | 10 | 系统盘只有 100G，日志必须限制滚动份数 |
| `streaming_load_max_mb` | 2048 | 单批导入不要超过 BE 可用内存，否则导入必失败 |
| `max_query_concurrency` | 32 | 4C 机器并发高了 CPU 打满，反而全慢 |

> 4G 堆大约支撑 **30~50 万 tablet**。按本集群数据量估算 tablet 在几万级，够用；后续表数量上千要优先扩 FE 内存。

### BE（8C/16G，官方最低要求）

| 参数 | 值 | 原因 |
|---|---|---|
| `mem_limit` | `80%` | 16G 必须硬顶，否则 BE 吃满整机内存被 OOM |
| `storage_page_cache_limit` | `20%` | 页缓存压缩到 2.5G，把内存让给 memtable 和 compaction |
| `write_buffer_size` | `100M` | 默认 200M，多 tablet 并发写入时会瞬间吃掉几个 G |
| `compaction_max_memory_limit_percent` | 40 | compaction 是内存大户，必须封顶 |
| `load_process_max_memory_limit_percent` | 30 | 默认 90%，两三个并发导入就崩 |
| `max_compaction_concurrency` | 4 | 8C 机器，并发太高会和查询抢 CPU |
| `storage_high_watermark_usage_percent` | 85 | 200G 小盘，到 85% 就拒绝写入，提前告警 |

## 5. 建表规范

- **分桶数取 3 的整数倍**（3 / 6 / 9），与 BE 数量对齐，否则数据倾斜。
- 分区按天 + 动态分区，`dynamic_partition.start = -90` 与 45 天实际保留期留了余量。
- 明细类用 DUPLICATE + ZSTD；需要去重/更新的汇总类用 UNIQUE。
- 单表 tablet 数控制在 `分区数 × 分桶数 ≤ 5000`，16G 的 BE 扛不住几十万 tablet。

## 6. 日常运维

```bash
# 启停（doris 用户）
/opt/doris/fe/bin/stop_fe.sh
/opt/doris/be/bin/stop_be.sh

# 日志
tail -f /opt/doris/fe/log/fe.log
tail -f /opt/doris/be/log/be.WARNING

# 元数据备份（FE leader 上，每天一次）
mysql -h192.168.1.51 -P9030 -uroot -e "BACKUP SNAPSHOT demo.snap_$(date +%F) TO demo_repo"
```

**升级顺序**：先升 3 台 BE，全部 Alive 后再升 FE（一次只升一台 FE，确认 `SHOW FRONTENDS` 正常再下一台）。

**故障处理**
| 场景 | 表现 | 处理 |
|---|---|---|
| 1 台 BE 挂 | 查询正常、写入降级（2 副本） | 重启 BE，副本自动补齐，无需干预 |
| 1 台 FE 挂 | 集群正常（2/3 法定人数） | 重启该 FE，自动追日志 |
| 2 台同时挂 | **集群不可用** | 禁止同机柜/同 UPS 回路批量维护 |

## 7. 已知瓶颈与扩容路径

1. **内存是最大瓶颈**：BE 16G 在大批量导入 + compaction 高峰时会报 `Memory limit exceeded`。缓解顺序：降并发导入 → 调小 `write_buffer_size` → 加内存。
2. **磁盘 400G/节点偏小**：单盘 200G 的 IOPS 和 compaction 效率都不理想。扩容优先给 BE 加盘（改 `storage_root_path` 后滚动重启，Doris 自动均衡）。
3. **扩容路径**：加 BE 最简单（`ALTER SYSTEM ADD BACKEND` + `ADMIN SET FRONTEND CONFIG` 调副本均衡）；数据量再涨就该考虑 3.0+ 存算分离 + MinIO。
4. **FE 单点写入压力**：所有元数据变更走 leader，DDL 频繁的场景会排队。当前规模不构成问题。
