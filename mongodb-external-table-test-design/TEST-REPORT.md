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
