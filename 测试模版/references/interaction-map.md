# 跨能力交互图

Feature 测试设计先选主能力，再按下表加入必需和高风险交互；常见和条件适用交互需结合范围判断。

| 主能力域 | 必需 | 常见 | 高风险/条件适用 |
|---|---|---|---|
| `sql` | `schema`, `query` | `session`, `transaction` | timezone/type coercion、prepare、compatibility |
| `query` | `sql`, `storage` | `schema`, `observability` | index rewrite、spill、distributed execution、cancel |
| `schema` | `sql`, `transaction`, `storage` | `security`, `observability` | concurrent DML、index/constraint、CDC、recovery、branch |
| `transaction` | `session`, `storage` | `schema`, `observability` | Proxy migration、disconnect、node restart、deadlock |
| `dataio` | `schema`, `storage`, `security` | `sql`, `session` | object failure、conversion、partial load、large data |
| `fulltext` | `schema`, `query`, `storage` | `dataio`, `observability` | async readiness、incremental DML、compaction、parser |
| `vector` | `schema`, `query`, `storage` | `session`, `observability` | async readiness、CPU/GPU、dimension、compaction |
| `cdc` | `transaction`, `storage`, `schema` | `security`, `observability` | checkpoint、source/sink failure、restart、schema evolution |
| `security` | `session`, `schema` | `observability` | cross-tenant data/recovery/CDC/external resource |
| `session` | `sql`, `security` | `transaction`, `query` | prepared state、Proxy cache、migration、disconnect |
| `cluster` | `session`, `storage`, `observability` | `transaction` | scale/drain/restart/network partition/leader change |
| `storage` | `transaction`, `schema` | `query`, `observability` | checkpoint/GC/compaction/object failure/restart |
| `recovery` | `storage`, `schema`, `security` | `transaction`, `observability` | GC/history、conflicting target、cross-account、restart |
| `branch` | `storage`, `schema`, `transaction` | `recovery`, `security` | history/LCA、conflict、GC、schema divergence |
| `observability` | 目标能力 | `security` | 大量日志、脱敏、观测行为副作用 |
| `ecosystem` | `session`, `sql` | `security`, `schema` | metadata/type/error/protocol compatibility |

## 交互强度

- **必需：** 缺少该能力，Feature 无法成立；必须覆盖。
- **常见：** 真实用户高频组合；按 Feature 使用场景选择。
- **高风险：** 历史上容易出现错误结果、状态污染、泄漏或恢复失败；只要路径可达就覆盖。
- **条件适用：** 仅在特定部署、配置、产品版本或合同下适用；写明条件。

## 组合规则

1. 每个主能力至少展开必需交互。
2. 状态写入类 Feature 默认检查事务、存储、Schema 和可观测性。
3. 异步 Feature 默认检查就绪、增量变更、取消/重试、重启和清理。
4. 跨连接 Feature 默认检查会话、事务、安全和 Proxy/多 CN 条件。
5. 数据恢复 Feature 默认检查源/目标隔离、Catalog/数据一致、GC/历史和权限。
6. 优化 Feature 必须保留独立结果 Oracle；不能只断言 EXPLAIN。
7. 兼容 Feature 必须先引用官方兼容边界，不能假设完整 MySQL 等价。

## 常见 Feature 映射

| Feature | 主能力 | 必查交互 |
|---|---|---|
| ALTER TABLE | `schema.ddl.alter-table` | transaction、lock/concurrency、index/constraint、CDC、recovery |
| Prepared Query | `session.prepared-statement` | 类型转换、Plan Cache、事务、metadata、迁移 |
| 二级/向量/全文索引 | 对应索引 ID | DML、优化器、异步构建、Checkpoint/Compaction、重启 |
| CDC 任务 | `cdc.change-data-capture` | 事务、Schema 演进、Checkpoint、下游/上游故障 |
| Proxy 路由 | `session.proxy-routing` | 会话状态、Prepared、事务、CN Drain/断连 |
| PITR/restore | `recovery.pitr` | Catalog、storage、GC/history、tenant/security、conflict |
| Data Branch 操作 | `branch.data-branch` | 历史、Schema、事务、冲突、Snapshot/GC |
