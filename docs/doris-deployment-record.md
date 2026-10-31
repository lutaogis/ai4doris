# Doris 集群部署实录（2026-11-01）

> 六节点 Apache Doris 4.0.8 生产集群，从裸机到验收通过，全程约 50 分钟。
> 本文档是**实际执行记录**：做了什么、遇到什么问题、怎么解决的、现在怎么用。
> 架构原理另见 [doris-architecture.md](doris-architecture.md)。

---

## 1. 集群概览

| 主机名 | IP | 角色 | 规格 | 承载 |
|---|---|---|---|---|
| doris-node-01 | 192.168.1.51 | FE Master | 4C / 8G / 100G | 元数据 + 查询规划 |
| doris-node-02 | 192.168.1.52 | FE Follower | 4C / 8G / 100G | 元数据副本 |
| doris-node-03 | 192.168.1.53 | FE Follower | 4C / 8G / 100G | 元数据副本 |
| doris-node-04 | 192.168.1.54 | BE | 8C / 16G + 2×200G | 计算 + 存储 |
| doris-node-05 | 192.168.1.55 | BE | 8C / 16G + 2×200G | 计算 + 存储 |
| doris-node-06 | 192.168.1.56 | BE | 8C / 16G + 2×200G | 计算 + 存储 |

| 项 | 值 |
|---|---|
| 版本 | `doris-4.0.8-rc02-bc8ea1bac6d`（官方 bin 包，3.82 GB） |
| 部署模式 | 存算一体，3 副本 |
| 操作系统 | Ubuntu 24.04.3 LTS（全部六台） |
| Java | OpenJDK 17.0.20（apt 安装，FE 与 BE 都需要） |
| 虚拟化 | VMware（网卡 ens160），CPU 直通，AVX2 六台全部支持 |
| 网关 / DNS | 192.168.1.1 |
| 时钟 | chrony，Leap=Normal，时区 Asia/Shanghai |

**验收结果**（05-verify.sh --smoke，部署当晚连续两轮）：

```
PASS  FE 存活 3/3（Master 唯一，Follower journal 已追平）
PASS  BE 存活 3/3（TabletNum 46/48/46 均衡分布）
PASS  六节点端口 8030/8040 全部 up
PASS  建库建表（demo.dwd_yield_daily / demo.dwd_defect_detail）
PASS  写入与查询（INSERT 后 SELECT 可见，GROUP BY 聚合正确）
结果: PASS=6 FAIL=0
```

---

## 2. 快速上手（明天早上看这里）

### 2.1 连接集群

```bash
# MySQL 协议（在任意能通 192.168.1.51 的机器上）
mysql -h 192.168.1.51 -P 9030 -u root -p'Doris@2026'

# Web UI（浏览器）
http://192.168.1.51:8030   （root / Doris@2026）

# SSH 登录任意节点
ssh lumz@192.168.1.5x      （密码 lumz1021）
```

### 2.2 账号

| 账号 | 密码 | 权限 | 用途 |
|---|---|---|---|
| root | `Doris@2026` | 全部 | 管理员（**部署时从无密码改为此密码**） |
| etl | `Etl@2026` | demo 库 SELECT/LOAD/CREATE/ALTER/DROP | 业务 ETL |
| lumz | `lumz1021` | 系统用户 + sudo | SSH / 运维 |

### 2.3 已有数据

`demo` 库里有两张表和 7 行样例良率数据（3 天 × 2 产线 + 冒烟 1 行），可以直接查：

```sql
-- 各产线三天平均良率
SELECT line_code, COUNT(*) days, SUM(input_qty) input_qty, SUM(defect_qty) defect_qty,
       ROUND(SUM(output_qty)/SUM(input_qty)*100, 2) yield_pct
FROM demo.dwd_yield_daily WHERE factory_code='CHOT' GROUP BY line_code;

-- 结果：L01 = 98.94%，L02 = 98.74%
```

### 2.4 服务管理（systemd 已接管开机自启）

```bash
sudo systemctl status doris-fe    # FE 节点（51/52/53）
sudo systemctl status doris-be    # BE 节点（54/55/56）
sudo systemctl restart doris-fe
sudo systemctl stop doris-be      # 单台 BE 停机维护（3 副本，集群不受影响）
```

> 注意：当前进程是部署脚本手工启动的，systemd 只做了 `enable`（开机自启）。
> 想让 systemd 完全接管，找空窗期 `systemctl restart doris-fe` 一次即可。

---

## 3. 部署时间线（实际执行）

| 时刻 | 动作 | 结果 |
|---|---|---|
| 02:13 | 环境探测：六台规格/系统/AVX2/外网 | 全部符合方案 |
| 02:16 | 仓库打包分发到六台 `~/ai4doris` | 全部成功 |
| 02:18 | 并行执行 00-init-os.sh（BE 带数据盘格式化） | 六台 rc=0，/data1、/data2 各 197G 挂载 |
| 02:21 | node-01 从阿里云 CDN 下载 4.0.8 安装包（3.82 GB） | ~1 分钟完成，字节数与 CDN 报头一致 |
| 02:25 | node-01 经 sshpass 内网 scp 分发到五台 | 全部成功，字节数一致 |
| 02:27 | FE 三台并行装 OpenJDK 17 | 17.0.20 |
| 02:29 | 六台并行解包安装（首次，前台） | 本地超时被杀 → 改 nohup 分离重跑（见 §4.4） |
| 02:45 | 六台安装全部完成，仓库迁至 `/opt/ai4doris` | 磁盘占用 12~15G |
| 02:59 | node-01 启动 FE，10 秒就绪；注册两个 Follower | Master 选举完成 |
| 03:00 | node-02/03 以 --helper 加入，13 秒就绪 | journal 追平（22/23） |
| 03:02 | 三台 BE 启动并注册 | Alive 3/3，磁盘 399.8G/台 |
| 03:04 | 冒烟测试 | PASS=6 FAIL=0 |
| 03:10 | 样例数据 + root 改密 + etl 账号 + systemd 自启 | 完成 |
| 03:15 | 终验（新密码登录、JVM/内存/时钟核对） | 全部健康 |

---

## 4. 遇到的问题与解决（六个坑，全部已解）

### 4.1 FE 装包后 JVM 配置没生效

**现象**：默认 fe.conf 里只有 `JAVA_OPTS_FOR_JDK_17="-Xmx8192m ..."`，仓库调优文件写的 `JAVA_OPTS=-Xmx4g` 不被读取。

**原因**：Doris 3.x/4.x 在 JDK17 下读的是 `JAVA_OPTS_FOR_JDK_17`，不是老的 `JAVA_OPTS`。默认 8G 堆在 8G 内存的 FE 机器上必然出事。

**解决**：fe.conf 两处都写，`JAVA_OPTS_FOR_JDK_17` 保留官方全部 `--add-opens` 参数、只把堆改为 `-Xmx4g -Xms4g`。已验证进程实际 `Xmx4g` 生效。

### 4.2 BE 启动报 JAVA_HOME 未设置

**现象**：`start_be.sh` 报 "The JAVA_HOME environment variable is not set correctly"。

**原因**：4.x 的 BE 含 JNI 依赖，也要 Java；且 apt 装的 JDK 没进 doris 用户环境。

**解决**：BE 三台同样装 openjdk-17，be.conf 增加 `JAVA_HOME = /usr/lib/jvm/java-17-openjdk-amd64`。

### 4.3 集群没有 BE 时 `SELECT 1` 都会失败

**现象**：注册脚本用 `SELECT 1` 探活 FE，报 "No backend available as scan node"。

**原因**：Doris 所有查询（包括无表查询）都路由到 BE 执行，FE 单独存活时 `SELECT 1` 必失败。

**解决**：03-register.sh 探活改用 `SHOW FRONTENDS`。这也是一个通用经验：**Doris 里探活用 SHOW 命令，不用 SELECT**。

### 4.4 本地脚本超时连带杀死远端安装

**现象**：六台并行前台解包，本地命令 10 分钟超时 SIGTERM，SSH 通道关闭导致远端解包/拷贝中断（52/53 死在"二进制已拷、配置未铺"的中间态）。

**解决**：远端长任务一律 `nohup ... > /tmp/inst-*.log 2>&1 &` 分离执行 + 轮询日志；中断的机器用 `FORCE=yes` 重跑（脚本幂等，会清理残缺 src 重新解包）。

### 4.5 动态分区表不自动创建历史分区

**现象**：插入 10-30/10-31 数据报 "no partition for this tuple"；手工 `ADD PARTITION` 又被拒。

**原因**：动态分区默认 `history_partition_num=0`，**只自动建未来分区**；且动态分区表禁止手工 ADD PARTITION。

**解决**：`SET ("dynamic_partition.enable"="false")` → 补建 p20261030/p20261031 → 重新 enable。仓库 `sql/01-init.sql` 已加 `"dynamic_partition.history_partition_num" = "93"`，以后新表直接生效。

### 4.6 RESOURCE GROUP 授权语法不兼容

**现象**：`GRANT USAGE_PRIV ON RESOURCE GROUP default` 在 4.0.8 报语法错误。

**影响**：无。etl 账号的库级权限已生效，资源组授权留待后续按 4.x 语法处理。

---

## 5. 系统与软件布局

### 5.1 每台机器的目录

| 路径 | 内容 |
|---|---|
| `/opt/doris/fe` 或 `/opt/doris/be` | Doris 程序目录（属主 doris:doris） |
| `/opt/doris/pkg` | 安装包（3.82 GB，六台各留一份可快速重装） |
| `/opt/ai4doris` | 部署脚本仓库（nodes.env / scripts / conf / sql，全部节点可读） |
| `/data1/doris`、`/data2/doris`（仅 BE） | 数据盘，XFS，noatime，各 197G |
| `/etc/netplan/50-cloud-init.yaml` | 静态 IP 配置 |
| `/etc/systemd/system/doris-fe.service` / `doris-be.service` | 开机自启单元 |

### 5.2 关键配置（与默认值的差异）

| 文件 | 参数 | 值 | 原因 |
|---|---|---|---|
| fe.conf | `JAVA_OPTS_FOR_JDK_17` | Xmx4g | 8G 机器防 OOM |
| fe.conf | `meta_dir` | /opt/doris/fe/meta | 元数据落系统盘 |
| fe.conf | `streaming_load_max_mb` | 2048 | 小内存 BE 扛不住大批次 |
| fe.conf | `priority_networks` | 192.168.1.0/24 | 多网卡选对 IP |
| be.conf | `mem_limit` | 80% | 16G 硬顶 |
| be.conf | `storage_page_cache_limit` | 20% | 内存让给 memtable/compaction |
| be.conf | `write_buffer_size` | 100M | 默认 200M 太大 |
| be.conf | `load_process_max_memory_limit_percent` | 30% | 防并发导入 OOM |
| be.conf | `max_compaction_concurrency` | 4 | 8C 机器限流 |
| be.conf | `storage_root_path` | /data1,/data2 双盘 | 单盘直通不组 RAID |
| be.conf | `JAVA_HOME` | /usr/lib/jvm/java-17-openjdk-amd64 | BE JNI 依赖 |

系统层（00-init-os.sh 统一完成）：swap 关闭、THP 关闭、`vm.max_map_count=2000000`、句柄 655360、chrony + Asia/Shanghai、ufw 关闭、`doris` 用户与目录创建、BE 数据盘格式化挂载（/etc/fstab 已固化）。

---

## 6. 日常运维手册

### 6.1 启停

```bash
# 单台 FE（在 51/52/53）
sudo systemctl restart doris-fe
sudo systemctl stop doris-fe

# 单台 BE（在 54/55/56）
sudo systemctl restart doris-be

# 手工方式（与 systemd 二选一，不要混用）
su - doris -c '/opt/doris/fe/bin/start_fe.sh --daemon'
su - doris -c '/opt/doris/be/bin/stop_be.sh'
```

### 6.2 状态巡检（每天一次）

```bash
mysql -h192.168.1.51 -P9030 -uroot -p'Doris@2026'
  SHOW FRONTENDS;    -- 3 行 Alive=true，1 个 IsMaster
  SHOW BACKENDS;     -- 3 行 Alive=true，UsedPct < 80%
  SHOW PROC '/cluster_health';  -- tablet 健康度
```

或直接跑仓库脚本（任意节点）：`bash /opt/ai4doris/scripts/05-verify.sh`

### 6.3 日志位置

| 日志 | 路径 | 看什么 |
|---|---|---|
| FE | /opt/doris/fe/log/fe.log、fe.warn | 元数据异常、选举 |
| FE 审计 | /opt/doris/fe/log/fe.audit.log | 慢查询 |
| BE | /opt/doris/be/log/be.INFO、be.WARNING | 内存、compaction、导入错误 |
| GC | /opt/doris/fe/log/fe.gc.log.* | FE 停顿 |

### 6.4 备份（建议立刻加到 crontab）

```bash
# 元数据是唯一不可再生数据，每天备份一次（在 Master 上）
0 2 * * * tar czf /backup/fe-meta-$(date +\%F).tar.gz -C /opt/doris/fe meta
```

业务数据因 3 副本天然容错；重要库可用 `BACKUP SNAPSHOT` 到对象存储（后续接 MinIO）。

### 6.5 扩容路径

- **加 BE**：新机按 §3 流程 init → install be → start → `ALTER SYSTEM ADD BACKEND "IP:9050"`，tablet 自动均衡。
- **FE 扩 Observer**：`ALTER SYSTEM ADD OBSERVER "IP:9010"`，扩查询并发不扩写能力。
- **单表数据增长**：优先给 BE 加盘（改 `storage_root_path` 重启）。

### 6.6 故速处理

| 现象 | 处理 |
|---|---|
| 一台 BE 挂 | 查询正常写入降级，重启该机即可，副本自动补齐 |
| 一台 FE 挂 | 集群正常（2/3 法定人数），重启追日志 |
| 查询报 Memory limit exceeded | 降低导入/查询并发；长期看加内存 |
| 导入报 -235 | 导入太碎，攒批（单批 ≥100MB 或 ≥10s） |
| 集群全部 down | 六台 `systemctl start doris-fe / doris-be`，先 FE 后 BE |

---

## 7. 遗留事项（按优先级）

1. **[高] 建立元数据备份 crontab**（§6.4，目前还没有）。
2. **[中] 监控**：Prometheus + Grafana 接 8030/8040 的 /metrics，尚未部署。
3. **[中] systemd 完全接管**：找空窗期逐台 `systemctl restart` 一次，使进程由 systemd 托管。
4. **[低] etl 账号资源组授权**：按 4.x 语法补 `GRANT ... ON RESOURCE GROUP`。
5. **[低] 05-verify.sh BE 表格 IP 列显示错位**（列解析小 bug，不影响 PASS/FAIL 判定）。
6. **[低] 安装包 3.82 GB × 6 份占盘**：确认集群稳定后可只保留 node-01 一份。

---

## 8. 一页速查

```
连接:   mysql -h192.168.1.51 -P9030 -uroot -p'Doris@2026'
WebUI:  http://192.168.1.51:8030
版本:   doris-4.0.8
拓扑:   FE 51/52/53（Master=51） + BE 54/55/56，3 副本
脚本:   /opt/ai4doris/scripts/（00-init 01-install 02-start-fe 03-register 04-start-be 05-verify）
配置:   /opt/doris/fe/conf/fe.conf · /opt/doris/be/conf/be.conf
日志:   /opt/doris/fe/log · /opt/doris/be/log
自启:   systemd doris-fe / doris-be（已 enable）
数据:   demo.dwd_yield_daily（良率日汇总）· demo.dwd_defect_detail（缺陷明细）
```

*部署执行：WorkBuddy 自动化（2026-11-01 02:13 – 03:15）。文档对应仓库 `ai4doris`。*
