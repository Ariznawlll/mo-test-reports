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
