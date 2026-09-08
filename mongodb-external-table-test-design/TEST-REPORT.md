# MongoDB External Table 测试执行报告

本报告按照同目录 `README.md` 测试设计执行，记录实际执行证据，不把 mock/UT 结果冒充成 MongoDB 到 MatrixOne 的真实 E2E 通过。

## 1. 执行基线

| 项目 | 值 |
|---|---|
| 执行日期 | 2026-08-18 |
| MatrixOne 测试 SHA | `e32c7dc95946c347710e706e70dfee2927bc84e0` |
| MatrixOne commit | `perf: avoid repeated full-row scans during group spill (#27203)` |
| 测试设计准入 SHA | `177a149f457be15f5bb14c723bdf0ea94254fea7` |
| MongoDB/FCV | 未启动真实 MongoDB fixture；不能宣称通过 |
| Go | `go1.26.5 darwin/arm64`，运行时去除了失效的旧 `GOROOT` |
| fixture manifest SHA256 | `9821df1a007b098fdbf64bc11ff2ca8decda512c5b6e958d1a6c0c892492b5d1` |
| `cn.toml` SHA256 | `813e1f4a91edd57cfcacf7f3dd997ed44b44455d47509b67cca8a670e187efc1` |
| local compose SHA256 | `fc1283b31ea4666e68eb78c389d57d0f01ddecf5f59c087884cad8b17fc53b55` |

设计准入 SHA 与实际测试 SHA 不一致，因此本报告只能作为当前 main 的回归证据，不能作为设计中要求的正式 acceptance report。

## 2. 执行结果总览

| 套件/层级 | 结果 | 证据 |
|---|---|---|
| Connector Contract：Python fixture/模板 | PASS | `env -u GOROOT python3 -m unittest discover -s test/mongodb -p 'test_*.py'`，11 tests OK |
| Connector Contract：MongoDB converter/catalog/predicate/pool | PASS | `mo-cgo-test -race -count=10 ./pkg/sql/mongodb` |
| Connector Contract：MongoScan/lifecycle/cleanup | PASS | `mo-cgo-test -race -count=10 ./pkg/sql/colexec/mongoscan` |
| Connector Contract：max_by/varlen/multi-group | PASS | `mo-cgo-test -race -count=10 ./pkg/sql/colexec/aggexec` |
| Connector Contract：TimeWin/GAPFILL operator | PASS | `mo-cgo-test -race -count=10 ./pkg/sql/colexec/timewin` |
| Runner/SQL contract | PASS | `mo-cgo-test -race -count=10 ./test/mongodb` |
| MySQL Mongo parser | PASS | `mo-cgo-test -race -count=10 -run 'MongoDB\|Mongo' ./pkg/sql/parsers/dialect/mysql` |
| MongoDB frontend/plan/DDL surface | PASS | `mo-cgo-test -race -count=10 -run 'MongoDB\|Mongo' ./pkg/frontend ./pkg/sql/plan ./pkg/sql/compile` |
| 官方 MongoDB unit 入口 | PASS | `env -u GOROOT make test-mongodb-unit` |
| 真实 Local E2E | BLOCKED | Docker daemon 不可用；Podman machine 初始化后卡在 `Currently starting`，已清理 |
| BVT/MOTR 黑盒 SQL | BLOCKED | 依赖 MatrixOne + MongoDB 运行环境；当前没有可用容器 socket |
| Snapshot/PITR/Chaos/Recovery | BLOCKED | 需要专用恢复/故障注入环境，未以 unit 代替 |
| BD-LOAD/BD-WIDE/BD-MAXBY/STAB | BLOCKED | 需要 MongoDB/MatrixOne 独占环境和资源指标 |
| NESR Cutover Gate | BLOCKED | 缺少 NESR 脚本 URL/SHA、客户配置和四集合 fixture |

## 3. 已实际验证的设计内容

以下是有测试证据的内部不变量，不等于真实 SQL E2E 已通过：

- BSON path、scalar/Decimal/Binary/JSON、missing/null/undefined、strict/try_null、NOT NULL、时间域/scale、数值边界和宽度转换。
- 安全 predicate candidate、低精度 temporal residual、compound `IN`、reversed comparison，以及 mapping snapshot/version/generation 校验。
- MongoScan 多 batch、empty/find failure、getMore/cursor error、cancel、mapping drift、statement/batch limit、lease/资源释放和 generation reuse。
- decoded/vector budget、mpool failure rollback、conversion error count/rate、max_by varlen ownership、多 group、tie/NaN/merge/spill 语义。
- connection DDL 生命周期、option validation、tenant-scoped pool isolation、secret rotation、retirement、endpoint/DNS rebinding/metadata address 拒绝和敏感信息脱敏。
- MongoDB parser、plan deep copy、typed discriminator、frontend DDL/catalog persistence、系统表初始化和 feature gate。
- runner 不导入 kernel package、fixture manifest、SQL 模板边界、exact hash/tolerance 和 report redaction。

## 4. 尚未执行的真实验收项

### MatrixOne Integration

由于 local E2E 无法启动，以下用例仍为 `BLOCKED`，不是通过：

- HP-001～HP-008：connection/table 真实生命周期、scan、Join/CTAS/REPLACE、watermark、租户和四集合 cutover。
- UH-001～UH-010：allowlist、认证/TLS/SRV、转换失败、cursor 中途失败、target constraint rollback、取消/断连、stale client、Snapshot/PITR。
- TX-001～TX-006：target/control 同事务、并发 fence、rotation/disable generation、commit ack 不确定。
- SEC-001～SEC-007：system/tenant/普通用户真实身份、跨租户不可见、secret precedence、SHOW/EXPLAIN/log/query history 脱敏。

### NESR Cutover Gate

四 collection `UNION ALL`、空 collection、跨 collection duplicate natural key、nested `meta.crew/meta.subject_id`、单 collection cursor/auth/schema failure、overlap 外删除、full/range rebuild、FAILED run 和 fence 状态机均未执行。

客户峰值约 18,032,280 rows/10 min、600 秒目标、约 30,054 rows/s，以及每 collection scan/aggregate/target write、`docsExamined`/`keysExamined`、legacy Python 差分均未执行。缺少 NESR 真实脚本和 fixture 时不能生成正式通过结论。

## 5. 非 MongoDB 相关 suite 失败

为验证通用租户/DDL/恢复交互，额外运行了 frontend/plan/compile 的完整 `-race -count=3` 批次。MongoDB 相关筛选批次通过，但完整批次包含以下与本 Feature 无关的已有失败：

- `pkg/frontend.TestHandleDelsOnLCA_SQLPaths`：`BackgroundExec` mock 类型断言 panic。
- `pkg/sql/compile` 多个 ISCP lease/runner 时序测试在 race 批次中断言失败。

这些失败不计入 MongoDB Feature 失败，但也不能把完整 frontend/compile race 批次写成通过。

## 6. 下一步解除阻塞

1. 恢复 Docker Desktop 或提供可用的 Linux container runtime/socket。
2. 重新执行 `env -u GOROOT make test-mongodb-e2e-local`，保存脱敏 report 和运行时指纹。
3. 在 E2/E3/E4/E5 环境执行 BVT/MOTR、TLS/SRV、真实 tenant、target constraints、事务、cancel/断连和 recovery case。
4. 提供 NESR 脚本仓库 URL/SHA、配置 hash、四 collection fixture manifest 和客户峰值运行环境。
5. 用同一 MatrixOne SHA、build flags、MongoDB version/FCV、configuration hash、NESR SHA、fixture manifest hash 重新生成正式 acceptance report。

## 7. 2026-09-07 TKE 补测增量

在 129 的 `mo-search-commit-4fdb9e916-20260907` namespace 中补测，MatrixOne 为 `commit-4fdb9e916`（3 CN / 1 DN / 3 Log / 2 Proxy），MongoDB 8.0.12 为 3-member `rs0`。本节只记录该 namespace 的操作。

- 基础外表、filter/group/aggregate/self-join/UNION、JSON/BINARY/temporal mapping 和 DROP/recreate 均保持 `count=5, sum(measurement)=74`。
- 单列 PK、复合 PK、UNIQUE、NOT NULL、AUTO_INCREMENT、GENERATED 目标表交叉写入完成；NOT NULL/UNIQUE 冲突未产生部分写入，后续查询可复用。
- 12 路并发 scan-only 查询全部返回 `5/74`；Mongo PRIMARY Pod 删除和 CN Pod 删除后的恢复查询仍为 `5/74`，最终 MO Ready、Mongo 为 1 PRIMARY + 2 SECONDARY。
- Mongo 只读账号直接写 source collection、读取 `admin.system.users` 均被拒绝，源集合计数仍为 5。
- 客户端 2 秒超时取消含外表扫描的 8 秒语句，连续 3 轮有界退出；取消后查询恢复 `5/74`。IP endpoint 未配置 CIDR 时建连接连续 3 轮 fail-closed，临时 connection 已清理。
- CHECK/FK/REPLACE/索引与事务补测：REPLACE 目标为 `5/74`；CHECK/FK 冲突后目标均为 0 行；二级索引点查为 4 行；control/target rollback 后为 `0/0`、commit 后为 `5/5`；同一 control row 并发持锁时等待方有界退出，锁释放后后续更新成功。
- 多租户/TLS 负向补测：临时 tenant A/B 可创建，但 tenant 侧解析 `secret://env` 凭证失败，未判为隔离通过，已清理；TLS required 连接非 TLS Mongo 返回 server selection/auth failure，临时对象已清理。
- 认证/stale/恢复/脱敏补测：错误 `auth_source`、缺失 Secret 各 3/3 稳定失败；connection disable 期间在途查询完成、新查询拒绝、enable 后恢复；SHOW CREATE TABLE/EXPLAIN 未发现 password、Mongo URI 或证书；删除 Mongo SECONDARY 和 DN Pod 后查询均恢复 `5/74`，CR 最终回到 `Ready`。

本次没有新增可归因于产品且未覆盖的重复 Bug。剩余项目仍包括完整 24×768 组合、pushed>0、getMore/网络断流/服务端取消、watermark/并发 commit-ack、TLS/SRV/TXT、多租户/Cluster Table、普通/Iceberg External 跨源、Snapshot/PITR、NESR 和大数据/稳定性性能；不能将本补测增量写成完整 acceptance 结论。

## 8. 2026-09-07 #27536 显式查询补测

目标环境仍为 129 的 `mo-search-commit-4fdb9e916-20260907`，MatrixOne 为 3 CN / 1 DN / 3 Log / 2 Proxy，MongoDB 8.0.12 三成员 `rs0`。本节只记录 Issue [#27536](https://github.com/matrixorigin/matrixone/issues/27536) 的 `__mo_query` 验收，不改变前述其他套件状态。

| 验收项 | 结果 | 证据 |
|---|---|---|
| 显式 filter | ✅ | `site_id=site-west` 连续 3/3 返回 `COUNT=1` |
| 显式 pipeline | ✅ | `$match + $group + $project` 连续 3/3 返回 `device-001\|1\|30`；叠加 `event_count >= 1` 的 residual 对照也为 3/3 |
| 普通 SQL residual 对照 | ✅ | 不带 `__mo_query` 的 `site_id='site-west' AND measurement>0` 连续 3/3 返回 `COUNT=1` |
| 隐藏列/canonical | ✅ | 显式读取 `__mo_query` 连续 3/3 返回 canonical relaxed JSON；`SELECT *`/`DESC` 不包含隐藏列 |
| 严格 JSON 与安全拒绝 | ✅ | uppercase envelope、双 envelope 字段、重复 key、尾随内容、空 pipeline、`$out/$merge/$lookup/$unionWith/$function`、未知 stage 各 3/3 稳定返回 `20301` |
| 资源上限 | ✅ | 16 stages 连续 3/3 成功；17 stages、超过 64 KiB 各 3/3 返回 size/stage limit 错误 |
| 显式 filter + 普通 residual/排序 | ❌ | 叠加 `site_id='site-west'`、`measurement>0`、`OR`、投影或外层 `ORDER BY` 的变体各 3/3 触发 `index out of range`；`EXPLAIN` 为 `pushed=0`、`residual`，CN 日志栈落在 `ColumnExpressionExecutor.Eval` `evalExpression.go:1685` → `FunctionExpressionExecutor` → `Filter` |

失败后检查：CR 仍为 `Ready`，3 CN/1 DN/Mongo 三节点均 `Running` 且重启数为 0；外表基线连续 3/3 为 `COUNT=5, SUM(measurement)=74`。该失败已提交为 [#28333](https://github.com/matrixorigin/matrixone/issues/28333)，并追加了外层 `ORDER BY` 的 3/3 复现；issue 已指派 `iamlinjunhong`，标签为 `kind/bug`、`needs-triage`，Issue Type 为 `Bug`；正文注明当前构建不是官方最新 main，需继续主线复核。

`events_aggregate` 直接扫描时聚合列显示 NULL，是因为源 collection 文档没有这两个字段；使用 `$group` pipeline 生成同名输出字段后映射正常，未作为本 Issue 缺陷。

## 9. 2026-09-07 继续补测：投影、dotted path、边界与 getMore 条件

仍只操作 129 上的 `mo-search-commit-4fdb9e916-20260907` namespace。

| 项目 | 结果 | 证据/结论 |
|---|---|---|
| 普通投影重排对照 | ✅ | 无 `__mo_query` 的 `measurement, device_id, site_id` 连续 3/3 正常返回 5 行 |
| dotted `MONGODB_PATH` | ✅ | 临时显式 schema 映射 `payload.a`、`payload.b`、`arr`；全列/重排、pipeline 全投影和部分投影各 3/3 正确返回 `2/x/[1,2,3]` 或对应 NULL；临时 mapping 已用 `DROP TABLE` 清理 |
| pipeline 输出投影/重排 | ✅ | `events_aggregate` 的 `$project` 重排连续 3/3 返回 `device-001|1|30` |
| pipeline 转换失败 | ✅ | 将 `event_count` 产出为字符串，连续 3/3 稳定返回 `BIGINT` 转换错误；没有 panic，基线仍为 `5/74` |
| 显式 filter 普通行投影 | ❌ | 单列、三列重排各 3/3 为 `ColumnExpressionExecutor.Eval` 越界；外层 `LIMIT` 也 3/3 越界，已补充 [#28333](https://github.com/matrixorigin/matrixone/issues/28333) |
| 显式 filter 聚合边界 | ✅ | `COUNT(*)` + `LIMIT 1` 连续 3/3 返回 1；说明问题集中在行投影/下游表达式组合，不是 filter count 本身 |
| selector/envelope 边界 | ✅ | `OR`、`LIKE` 各 3/3 按单值 selector 约束拒绝；单值 `IN`、常量折叠表达式各 3/3 正常；query text 追加 `allowDiskUse` 各 3/3 拒绝 |
| `$sort/$unwind` | ❌/待契约确认 | 各 3/3 在 MongoDB 操作前返回 `pipeline stage is not allowed`；#27536 将二者列为首期候选，已提交 [#28337](https://github.com/matrixorigin/matrixone/issues/28337)，指派 `iamlinjunhong`，标签 `kind/bug`、`needs-triage`，类型 Bug |
| getMore/指标 | ⏸️ | 指标端点确认存在 `find/aggregate/get_more/kill_cursors`、cursor、pool、scan 文档/字节和转换错误指标；5 行 fixture 配默认 `batch-rows=8192` 只产生单 batch。曾在本 namespace 临时 patch CN ConfigMap 并串行重启尝试调到 2，但运行时未生效；已恢复 ConfigMap，3 CN Ready，不能据此宣称 getMore 已覆盖 |
| reducing aggregation 差分 | ✅ | 普通 raw scan + MO `GROUP BY` 与 Mongo `$group+$project` pipeline 结果一致；指标增量分别为 5 documents/223 bytes 与 2 documents/138 bytes，当前 fixture 满足“少传输/少解码”方向 |
| 转换失败资源闭环 | ✅/观测性缺口 | pipeline 产出字符串到 BIGINT 连续 3/3 返回稳定转换错误；各 CN cursor `open=close`、`pool_checked_out_connections=0`。`conversion_errors_total` 未因业务转换错误递增，已提交 [#28341](https://github.com/matrixorigin/matrixone/issues/28341)，请求研发确认/补齐指标合同 |

本轮 cleanup：临时 dotted mapping 已删除；MongoDB collection 未修改；目标外表基线仍为 `COUNT(*)=5, SUM(measurement)=74`；3 CN、1 DN、3 Mongo 节点均 Running 且重启数为 0。当前构建仍为 `commit-4fdb9e916`，不是官方最新 main，#28333/#28337 均需主线镜像复核。

## 10. 2026-09-07 最新 main 本地回归归档

在官方 `main` SHA `8edac64737db2633c250a527cffdf04707cd8c21` 上，以 macOS 本地单进程 MatrixOne 和 MongoDB 8.0.12 单节点 ReplicaSet 执行官方 `make test-mongodb-e2e-local`。独立运行 3 次，每轮均为 `status=passed`、24 个场景；三份结构化报告、校验和、白盒复核和清理记录已归档到：

- [`runs/2026-09-07-main-8edac647-local/`](runs/2026-09-07-main-8edac647-local/)

本轮没有发现新的产品缺陷。#27346 的 `TRUNCATE` 黑盒回归符合预期；#27347/#27348 的 mapping/DDL 白盒拒绝路径符合预期，但公开 SQL 黑盒 DDL 仍需单独复测。完整 24 类型交叉矩阵、TLS/SRV、多租户、多成员/网络/getMore 故障、Snapshot/PITR、NESR、big-data、stability 和 Chaos 未由本地归档覆盖，因此不改变 Issue #26229 的完整验收结论。

## 11. 2026-09-08 最新 main 本地扩展交叉测试

在官方 `main` SHA `f72ca9efbeb3a7c673701e4a135cc6670c33cfde` 上执行官方 MongoDB E2E 和扩展交叉矩阵。官方 E2E 为 25/25 PASS；扩展矩阵共 158 项，145 PASS、13 FAIL。结构化结果、逐项明细、可复现脚本和校验和已归档到：

- [`runs/2026-09-08-main-f72ca9ef-local/`](runs/2026-09-08-main-f72ca9ef-local/)

本地通过范围包括当前 converter 支持的全部 23 个 MO 类型/类型族、源表列属性和禁止约束、只读 DML、永久/临时/分区/View/CTAS/cluster 权限边界/file external、普通目标表全部主要约束、查询与 pipeline 边界、显式事务、10 路并发和双 tenant 隔离。`mongodb`、`mongoscan`、`aggexec`、`timewin` race 各重复 10/10 通过，cursor/pool 最终为 `open=134, close=134, checked_out=0`，归档敏感值扫描和本轮资源残留均为 0。

13 个失败全部归属于已登记问题：[#28333](https://github.com/matrixorigin/matrixone/issues/28333) 的 4 种显式 filter + residual/projection/order-limit 组合各 3/3 越界 panic，共 12 项；[#28341](https://github.com/matrixorigin/matrixone/issues/28341) 的 strict 转换失败指标不增长，共 1 项。已修复的 [#28337](https://github.com/matrixorigin/matrixone/issues/28337) `$sort`/`$unwind` 各 3/3 通过，并通过相邻边界验证。本轮未发现第三类新缺陷。

big-data、TLS/SRV/mongos、多成员和 getMore 网络故障、Snapshot/PITR、stability/Chaos、NESR cutover 仍需专用环境，不属于本地完成范围。
