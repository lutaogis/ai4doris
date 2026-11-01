# Doris 集群关机 / 开机操作手册

> 适用集群：doris-node-01 ~ 06（192.168.1.51-56），Doris 4.0.8，3 FE + 3 BE，3 副本
> 文档版本：2026-11-01 21:45 ｜ 基于本集群实测，非通用抄录

---

## 0. 一句话版本

```bash
cd /opt/ai4doris/scripts

# 关机（停进程，不关系统）
./07-stop-cluster.sh --yes

# 关机（停进程 + 逐台 poweroff）
./07-stop-cluster.sh --yes --poweroff

# 开机（自动按 FE Master → FE Follower → BE 顺序拉起并等就绪）
./08-start-cluster.sh
```

**顺序红线**：关机 `BE → FE Follower → FE Master`；开机 `FE Master → FE Follower → BE`。反了不会丢数据，但会多出一堆 unhealthy 副本和告警，恢复时间从 1 分钟变成 10 分钟。

---

## 1. 关机前的集群现状（2026-11-01 21:40 实测）

| 项目 | 实测值 | 对关机的影响 |
|---|---|---|
| FE | 3/3 alive，Master = 192.168.1.51 | 无风险，可正常滚动停止 |
| BE | 3/3 alive，TabletNum 97/99/97 | 无风险 |
| Tablet | **103/103 healthy**，异常列全 0 | 停前状态干净，重启后容易收敛 |
| 数据量 | DataUsed 每台 120~240 KB，总容量 399.8 GB/台 | 数据量极小，副本修复几乎瞬时 |
| Routine Load | **无**（ETL 用的是 Stream Load 一次性任务） | 不存在消费位点堆积问题 |
| 活跃查询 | 无 | 可直接停 |
| FE journal | ReplayedJournalId = 13513，仍在增长 | 见坑 3 |
| FE image | **image 目录只有 ROLE/VERSION/DEPLOY_MODE，没有 image.xxxx** | 见坑 3，必须冷备 |
| 进程托管 | systemd 已 enabled，但进程原本是手工启动（systemd 显示 inactive） | 见坑 2 |
| 时钟 | 6 台 NTPSynchronized = yes | 开机后仍需复核 |

结论：**当前状态可以安全关机**。唯一必须额外做的动作是元数据冷备，因为集群至今没有生成过 image 快照。

---

## 2. 六个必须知道的坑

### 坑 1：`stop_be.sh` / `stop_fe.sh` 默认发 SIGKILL，不是 SIGTERM

官方脚本第 47-49 行写死：

```bash
signum=9
if [[ "$1" = "--grace" ]]; then
    signum=15
fi
```

也就是说 `bin/stop_be.sh` 等价于 `kill -9`。后果：

- BE 来不及 flush memtable、关闭 tablet、写完 rowset 元信息 → 下次启动多做副本修复，极端情况出现 `-235` 或 trash 膨胀
- FE 被 `-9` 可能残留 `meta/bdb/je.lck`，下次启动报 *"The environment is currently locked"*

**正确写法**：`stop_be.sh --grace` / `stop_fe.sh --grace`，并**以 doris 用户执行**（否则读不到 pid 文件）。

### 坑 2：`systemctl stop` 原本也是 SIGKILL，且会「假成功」

原始 unit 里是 `ExecStop=/opt/doris/fe/bin/stop_fe.sh`，没有 `--grace` → `systemctl stop` 同样 `kill -9`。

更要命的是：**当前运行的进程是部署时手工 `start_fe.sh --daemon` 起的**，systemd 认为服务未运行，于是：

```bash
systemctl stop doris-fe     # 返回成功、什么都不做，进程还在跑
```

你以为是优雅停机，实际上是等会儿直接拔电源。

**本次已修复并同步到六台**（见 §8）：unit 改为 `--grace` + `KillSignal=SIGTERM` + `PIDFile=`，六台 `systemd-analyze verify` 通过、`is-enabled` 均为 enabled。现在 `systemctl stop` 才是真的优雅停止。

> 判断当前进程归谁管：`systemctl is-active doris-fe` 返回 `inactive` 但 `pgrep` 有进程，就是手工启动的。

### 坑 3：FE 没有 image 兜底，只能靠 journal 回放

实测现象：

- `ReplayedJournalId = 13513` 一直在涨，但 `/opt/doris/fe/meta/image/` 里始终只有 `ROLE`、`VERSION`、`DEPLOY_MODE` 三个标记文件
- `ALTER SYSTEM CREATE IMAGE` → 4.0.8 语法错误（该语句已被移除）
- 置 `force_do_metadata_checkpoint=true` 后观察 100 秒，`leaderCheckpointer` 仍打印 `last checkpoint journal id: 0, current finalized journal id: 0`，未生成 image

后果：重启时 FE 只能从 BDBJE journal 回放全部 13513 条元数据变更。正常关机（SIGTERM + 正常 poweroff）回放没问题，几十秒内完成；**但如果是硬断电导致 `meta/bdb/00000000.jdb` 损坏，没有 image 就没有第二份可恢复的元数据**。

对策（`07-stop-cluster.sh` 已内置）：

```bash
sudo tar czf /opt/doris/backup/fe-meta-<时间戳>.tar.gz -C /opt/doris/fe meta
```

9.1 MB 的 meta 目录，压缩后秒级完成，落盘到 `/opt/doris/backup/`，同时复制一份到 `/opt/ai4doris/backup/`。**这是本集群关机前唯一不可省略的步骤。**

> 脚本默认在 node-01 上执行，「拉回本地」指 node-01 的 `/opt/ai4doris/backup/`。若整台宿主机要下架或重装，请再手工把该文件拷到管理机/共享存储。

### 坑 4：关机/开机顺序不能反

| 阶段 | 顺序 | 原因 |
|---|---|---|
| 关机 | BE(54/55/56) → FE Follower(52/53) → FE Master(51) | BE 的 graceful shutdown 要联系 FE 汇报退出；先停 FE 就只能硬停 BE。FE 先停 Follower 再停 Master，可避免 BDBJE 重新选主 |
| 开机 | FE Master(51) → FE Follower(52/53) → BE(54/55/56) | FE 先就绪，BE 才能注册成功；3 台 FE 同时起会抢主，虽然能收敛但首次查询会慢 |

### 坑 5：别用 VMware 挂起（Suspend），别在 vCenter 直接 Power Off

- **Suspend → Resume**：guest 时钟跳变，FE 的租约、BE 心跳超时判断全部错乱，容易出现「BE 明明活着却显示 dead」
- **Power Off（硬关）**：等于拔电源，文件系统脏页丢失，等同于对每个进程 `kill -9`
- **正确姿势**：guest 内 `sudo shutdown -h now`，等 VMware 显示 Powered Off

宿主机要维护（打补丁、换硬件）时，也是先在 guest 内关机，再动宿主机。

### 坑 6：关机跨天，动态分区会自动补建

`demo.dwd_yield_daily` 是动态分区表（`-90 ~ +3` 天）。关机跨过零点后，开机时动态分区调度会一次性补齐缺失分区，短时间内出现一批建分区 DDL——属正常现象，不要误判为异常写入。

同理，若后续上线了 Routine Load（Kafka），开机后 BE 会从上次 committed offset 继续消费，可能出现短时堆积，属正常。

### 坑 7：用 stop 脚本停「systemd 托管」的节点，15 秒后会被自动拉起

**2026-11-01 21:51 实机停机时现场踩到**：

- 21:50:52 对 52 执行 `stop_fe.sh --grace`，21:50:56 显示进程已退出
- 21:51:20 停机脚本做残留校验时，52 的 FE 又活了；56 的 BE 同样复活
- 根因：52/56 的状态是我们用 `systemctl start` 接管过的，unit 里 `Restart=on-failure`，SIGTERM 退出被 systemd 判定为「失败」→ `RestartSec=15` 后自动重新拉起

后果：如果脚本不做残留校验就直接 poweroff，实际是「进程被 15 秒后重建，然后机器下电强杀」，等于白停一次。

正确做法（`07-stop-cluster.sh` 已内置 `stop_component()`）：

```bash
# 先判断归属，再选停止方式
if [[ "$(systemctl is-active doris-fe 2>/dev/null)" == "active" ]]; then
    sudo systemctl stop doris-fe          # systemd 自身发起的停止，不会触发 Restart
else
    sudo -u doris /opt/doris/fe/bin/stop_fe.sh --grace   # 手工托管的进程
fi
```

**并且停完必须校验**：`pgrep` 有残留就中止 poweroff（本次正是这条校验拦住了错误下电）。

> 记忆点：`Restart=on-failure` 是崩溃自愈的好配置，但它的副作用是「外部 kill」≠「正常停止」。停止一律走 `systemctl stop`。

---

## 3. 关机执行计划

### 3.1 时间轴

| 时间 | 阶段 | 动作 | 命令 / 校验 | 预计耗时 |
|---|---|---|---|---|
| T-30m | 通知 | 告知下游停写、停 BI 报表、停 ETL 定时任务 | 确认 crontab / Airflow 已暂停 | — |
| T-20m | 体检 | 跑一次演练，只检查不动手 | `./07-stop-cluster.sh --dry-run` | 10s |
| T-15m | 冻结 | 停止导入（无 Routine Load 可跳过） | `SHOW LOAD` 无 LOADING/PENDING | — |
| T-10m | 备份 | 元数据冷备（脚本自动） | 看到 `已拉回本地: backup/fe-meta-*.tar.gz` | 5s |
| T-0 | 停 BE | 54 → 55 → 56，每台等进程退出 | `pgrep -u doris -f doris_be` 无输出 | 1~3 min |
| T+2m | 停 FE | 52 → 53 → 51（Follower 先，Master 后） | `pgrep -u doris -f org.apache.doris` 无输出 | 1~2 min |
| T+5m | 校验 | 六台确认无残留进程 | 脚本阶段 5 全绿 | 30s |
| T+6m | 下电 | 逐台 `shutdown -h now` | VMware 显示 Powered Off | 1 min |

### 3.2 手工版（不用脚本时）

```bash
# ⓿ 先判断每台归谁管：active = systemd 托管，inactive = 手工启动
systemctl is-active doris-fe doris-be

# ① BE：54 / 55 / 56 依次执行，每台间隔 10 秒
sudo systemctl stop doris-be                            # systemd 托管（推荐）
# 或手工启动的进程：
sudo -u doris /opt/doris/be/bin/stop_be.sh --grace
# 等待输出 "stop doris_be and remove PID file"
pgrep -u doris -f doris_be || echo "BE 已退出"

# ② FE Follower：52 / 53
sudo systemctl stop doris-fe                            # systemd 托管
# 或
sudo -u doris /opt/doris/fe/bin/stop_fe.sh --grace
# 等待输出 "stop java and remove PID file"

# ③ FE Master：51
sudo systemctl stop doris-fe
# 或
sudo -u doris /opt/doris/fe/bin/stop_fe.sh --grace

# ④ 六台全部校验（应为空）
pgrep -u doris -f 'doris_be|org.apache.doris'

# ⑤ 逐台关机
sudo sync && sudo shutdown -h now
```

> 注意：不要用 `systemctl stop` 去停「手工启动」的进程，它会假成功且什么都不做（坑 2）。系统 reboot 过、进程由 systemd 拉起之后，用 `systemctl stop doris-fe` 才等价于优雅停止。

---

## 4. 开机执行计划

| 时间 | 阶段 | 动作 | 校验 | 预计耗时 |
|---|---|---|---|---|
| T-2m | 上电 | VMware 依次开机（建议 51 先开） | 能 ssh | 1 min |
| T+0 | 时钟 | 确认 NTP 已同步 | `timedatectl show -p NTPSynchronized --value` = yes | 10s |
| T+1m | FE Master | `systemctl start doris-fe`（51） | `mysql -h127.0.0.1 -P9030 -uroot -p'Doris@2026' -e "SHOW FRONTENDS"` 且 IsMaster=true | 30~60s |
| T+3m | FE Follower | 52、53 依次启动 | `SHOW FRONTENDS` 三台 alive | 40s |
| T+5m | BE | 54 → 55 → 56，间隔 20s | `SHOW BACKENDS` 三台 Alive=true | 1~2 min |
| T+8m | Tablet | 等副本收敛 | `SHOW PROC '/cluster_health/tablet_health'` Total 行 TabletNum == HealthyNum | 1~10 min |
| T+15m | 验收 | 跑巡检 + 抽查读写 | `./06-inspect.sh` 分数 ≥ 75 | 1 min |

一条命令走完：

```bash
cd /opt/ai4doris/scripts && ./08-start-cluster.sh
```

脚本特性：已运行的节点自动跳过（幂等）、systemd 起不来自动回退 `bin/start_*.sh --daemon`、全程等待就绪而不是盲等固定秒数。

---

## 5. 校验清单

### 关机后

- [ ] 六台 `pgrep -u doris -f 'doris_be|org.apache.doris'` 均为空
- [ ] `backup/fe-meta-*.tar.gz` 已拉到本地，大小约 1~2 MB
- [ ] VMware 里状态是 **Powered Off**，不是 Suspended
- [ ] 若为单机维护，其余节点仍 `alive`（见 §7）

### 开机后

- [ ] `SHOW FRONTENDS`：3 条记录，`Alive=true`，**IsMaster 只有一个 true**
- [ ] `SHOW BACKENDS`：3 条记录，`Alive=true`，`SystemDecommissioned=false`
- [ ] `SHOW PROC '/cluster_health/tablet_health'`：`TabletNum == HealthyNum`，后 14 列全 0
- [ ] 六台 `NTPSynchronized=yes`
- [ ] `./06-inspect.sh` 得分不低于关机前（当前基线 75 分）
- [ ] 抽查一次读写：`SELECT COUNT(*) FROM demo.dwd_yield_daily`

---

## 6. 故障处置

| 现象 | 大概率原因 | 处置 |
|---|---|---|
| FE 起不来，fe.log 报 `Meta is corrupted` / 回放失败 | journal 或 BDB 损坏（硬断电） | 停进程 → 备份坏目录 → 解压 `backup/fe-meta-*.tar.gz` 覆盖 → 重启 |
| FE 起不来，报 `The environment is currently locked by another process` | 上次被 `kill -9`，残留 `meta/bdb/je.lck` | 确认无 FE 进程后删除 `je.lck`（**只有确认无进程时才能删**） |
| 9030 端口被占 | 手工 + systemd 双启，两个 FE 抢端口 | `ss -lntp \| grep 9030` 找 PID，保留一个、杀另一个 |
| `SHOW BACKENDS` 里 BE 一直 false | 起好了但注册失败 | 看 `be.out`；确认 `priority_networks=192.168.1.0/24` 与实际网段一致；确认 FE 先就绪 |
| tablet unhappy 迟迟不收敛 | 副本修复排队中 | 等 3~10 分钟；看 `SHOW PROC '/cluster_health/tablet_health'` 的 ReplicaMissingNum 是否在下降 |
| 查询报 `No backend available` | BE 全挂或全部未注册 | 检查 BE 的 9060(brpc)/8040(http) 端口与 `be.out` |
| 开机后首次查询特别慢 | 页缓存/元数据缓存冷启动 | 正常，跑一两次热查询即恢复 |

---

## 7. 变体：只停一部分节点

### 7.1 只做单机维护（推荐，不影响业务）

```bash
# 停一台 BE（3 副本下读写不受影响）
sudo -u doris /opt/doris/be/bin/stop_be.sh --grace
# 维护完
sudo systemctl start doris-be

# 停一台 FE Follower（quorum 2/3 仍满足）
sudo -u doris /opt/doris/fe/bin/stop_fe.sh --grace
```

停 BE 期间该节点的 tablet 副本会显示缺失，FE 会尝试在其他两台补副本；节点回来后自动对齐。

### 7.2 只重启 BE 使配置生效（本集群的遗留待办）

```bash
# 54 → 55 → 56 逐台滚动，每台间隔 60 秒
sudo systemctl restart doris-be
```

滚动而非全停，集群始终有 2/3 副本在线。重启前建议先 `./07-stop-cluster.sh --dry-run` 确认 tablet 全健康。

### 7.3 全集群关机（本手册主体）

见 §3。

---

## 8. 本次已完成的实测与变更（2026-11-01）

| 演练项 | 方法 | 结果 |
|---|---|---|
| FE 优雅停机 | 在 52 上 `stop_fe.sh --grace` | 输出 `stop java and remove PID file`，PID 文件自动清理，8 秒退出 |
| FE systemd 启动 | `systemctl start doris-fe` | `active`，MainPID 43423，30 秒内重新 Join 集群（FOLLOWER / alive=true） |
| BE 优雅停机 | 在 56 上 `stop_be.sh --grace` | 输出 `stop doris_be and remove PID file`，5 秒退出 |
| BE systemd 启动 | `systemctl start doris-be` | `active`，MainPID 12853，45 秒内 tablet 回到 103/103 healthy |
| 停机脚本演练 | `07-stop-cluster.sh --dry-run` | 体检 3/3 + 3/3 + 103/103，元数据冷备成功并拉回本地 |
| 启动脚本幂等 | `08-start-cluster.sh`（节点已在运行） | 六个节点全部正确跳过，最终 3/3、3/3、103/103 |
| **正式停机执行** | `07-stop-cluster.sh --yes --poweroff`（21:48:37 起） | 体检 3/3+3/3+103/103 → 冷备 `fe-meta-20261101_214837.tar.gz` → 停 BE 54/55/56 → 停 FE 52/53/51 → **校验发现 52/56 被 systemd 拉回，脚本按设计中止下电** → 改用 `systemctl stop` 清掉 → 六台 `pgrep` 全 0 → 52-56 断电 → 51 延迟 1 分钟断电 → **六台 ping 全部不通** |

同时修改的文件：

- `scripts/systemd/doris-fe.service` / `doris-be.service`：`ExecStop` 加 `--grace`，新增 `PIDFile=`、`KillSignal=SIGTERM`、`SendSIGKILL=yes`、`TimeoutStopSec=180`
- 新增 `scripts/07-stop-cluster.sh`（顺序停机 + 体检 + 元数据冷备 + 残留校验 + 可选 poweroff；`stop_component()` 按 systemd/手工两种托管自动选停止方式）
- 新增 `scripts/08-start-cluster.sh`（顺序启动 + 幂等 + 就绪等待 + systemd 失败回退）
- 两个 unit 已同步到六台节点并 `systemctl daemon-reload`，`systemd-analyze verify` 全部通过

> ⚠️ 本次停机后集群已下电，`/opt/ai4doris/scripts/07-stop-cluster.sh` 仍是修复前的版本（缺少 `stop_component()`）。**下次开机后第一件事：把仓库里的最新脚本同步过去**，否则再次停机会重演坑 7。

---

## 9. 遗留项

0. **开机第一件事**：同步最新 `07-stop-cluster.sh` 到 `/opt/ai4doris/scripts/`（含 `stop_component()`），并检查 `systemctl is-active doris-fe/doris-be`，若为 `failed` 先 `sudo systemctl reset-failed doris-fe doris-be`。
1. **FE checkpoint 异常需跟进**：4.0.8-rc02 的 `finalized journal id` 恒为 0，导致 image 一直不生成。建议向社区确认是否为已知问题；在修复前，每条关机流程都必须保留元数据冷备。
2. **元数据备份上 crontab**（原待办，本手册提供了现成命令）：建议每天 03:00 备份一次，保留 7 天。
3. **BE 配置尚未生效**：`compaction_memory_bytes_limit` 等改动需要重启 BE 才能生效，可用 §7.2 的滚动方式，与关机维护合并做。
4. **Prometheus 监控未部署**：关机期间无告警能力，恢复后建议优先补。

---

*配套脚本：`scripts/07-stop-cluster.sh`、`scripts/08-start-cluster.sh`；单位文件：`scripts/systemd/`。*
