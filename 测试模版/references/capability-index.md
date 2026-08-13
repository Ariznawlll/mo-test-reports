# MatrixOne 正式产品能力索引

## 版本

- 官方 `main`：`bdbd613fdece966769eb68481a3e58bfbc36b30c`
- 核验日期：2026-08-13
- 状态口径：只包含 `supported` 和 `supported-with-conditions`

本索引是测试设计入口，不是 SQL 语法手册。生成设计时读取主能力域、所有直接交互能力和通用测试维度。

## 能力域

| 域 ID | 用户能力域 | 参考文件 | 主要仓库证据 |
|---|---|---|---|
| `sql` | SQL 语言、类型、函数与兼容性 | [capability-sql.md](capability-sql.md) | `docs/ai-skills/sql-engine.md`, `test/distributed/cases/` |
| `query` | 查询优化与执行 | [capability-query-engine.md](capability-query-engine.md) | `pkg/sql/plan`, `pkg/sql/colexec` |
| `schema` | Schema、约束、DDL 与索引 | [capability-schema-index.md](capability-schema-index.md) | DDL/index BVT |
| `transaction` | 事务、锁与并发 | [capability-transaction.md](capability-transaction.md) | `docs/ai-skills/transaction.md` |
| `dataio` | 导入、导出、Stage 与外部数据 | [capability-load-external.md](capability-load-external.md) | load/stage BVT |
| `fulltext`, `vector` | 全文与向量 | [capability-fulltext-vector.md](capability-fulltext-vector.md) | fulltext/vector BVT |
| `cdc` | CDC 与数据集成 | [capability-cdc.md](capability-cdc.md) | CDC docs/tests |
| `security` | 多租户、安全和权限 | [capability-security-tenant.md](capability-security-tenant.md) | tenant/security/access-control BVT |
| `session` | 会话、协议、Driver 和 Proxy | [capability-session-protocol.md](capability-session-protocol.md) | prepare/system-variable/proxy tests |
| `cluster` | 部署、扩缩容和高可用 | [capability-cluster-ha.md](capability-cluster-ha.md) | multi-CN/chaos assets |
| `storage` | 存储、Checkpoint、Compaction、Cache、GC | [capability-storage-lifecycle.md](capability-storage-lifecycle.md) | storage engine tests |
| `recovery` | Snapshot、PITR、备份与恢复 | [capability-recovery.md](capability-recovery.md) | snapshot/pitr BVT/workflows |
| `branch` | Data Branch / Git4Data | [capability-data-branch.md](capability-data-branch.md) | Git4Data tests/docs |
| `observability` | 可观测性与运维 | [capability-observability.md](capability-observability.md) | system tables/EXPLAIN/log/metric assets |
| `ecosystem` | 正式支持的客户端与生态兼容 | [capability-ecosystem.md](capability-ecosystem.md) | compatibility docs/tests |

## 使用顺序

1. 从 Feature 用户合同选择主能力 ID。
2. 读取条目的 Interactions，加入 required 和 high-risk 能力。
3. 对 common/conditional 交互按 Feature 范围选择，并记录未选择原因。
4. 应用 [universal-test-dimensions.md](universal-test-dimensions.md)。
5. 使用 [test-routing.md](test-routing.md) 分层测试。
6. 按 [test-plan-template.md](test-plan-template.md) 输出并运行校验器。

## 正式来源入口

- [MatrixOne Feature List](https://docs.matrixorigin.cn/en/v25.3.0.2/MatrixOne/Overview/matrixone-feature-list/)
- [MySQL Compatibility Matrix](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)
- [SQL Statement Categories](https://docs.matrixorigin.cn/en/m1intelligence/MatrixOne-Intelligence/Reference/SQL-Reference/SQL-Type/)
- [MatrixOne Release Notes](https://docs.matrixorigin.cn/en/dev/MatrixOne/Release-Notes/)
- MatrixOne `docs/ai-skills/` 和 `test/distributed/cases/`
