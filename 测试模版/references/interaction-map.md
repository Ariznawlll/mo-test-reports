# 跨能力交互图

Feature 测试设计先选主能力，再按下表加入 required/high-risk 交互。Common/conditional 交互需结合范围判断。

| 主能力域 | Required | Common | High-risk / Conditional |
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
| `observability` | target capability | `security` | high-volume logging、redaction、observer side effects |
| `ecosystem` | `session`, `sql` | `security`, `schema` | metadata/type/error/protocol compatibility |

## 交互强度

- **Required:** 缺少该能力，Feature 无法成立；必须覆盖。
- **Common:** 真实用户高频组合；按 Feature 使用场景选择。
- **High-risk:** 历史上容易出现错误结果、状态污染、泄漏或恢复失败；只要路径可达就覆盖。
- **Conditional:** 仅在特定部署、配置、产品版本或合同下适用；写明条件。

## 组合规则

1. 每个主能力至少展开 required 交互。
2. 状态写入类 Feature 默认检查 transaction、storage、schema 和 observability。
3. 异步 Feature 默认检查 readiness、incremental change、cancel/retry、restart 和 cleanup。
4. 跨连接 Feature 默认检查 session、transaction、security 和 Proxy/多 CN 条件。
5. 数据恢复 Feature 默认检查 source/target 隔离、Catalog/data 一致、GC/history 和权限。
6. 优化 Feature 必须保留独立结果 oracle；不能只断言 EXPLAIN。
7. 兼容 Feature 必须先引用官方兼容边界，不能假设完整 MySQL 等价。

## 常见 Feature 映射

| Feature | 主能力 | 必查交互 |
|---|---|---|
| ALTER TABLE | `schema.ddl.alter-table` | transaction、lock/concurrency、index/constraint、CDC、recovery |
| Prepared query | `session.prepared-statement` | type conversion、plan cache、transaction、metadata、migration |
| Secondary/vector/fulltext index | 对应 index ID | DML、optimizer、async build、checkpoint/compaction、restart |
| CDC task | `cdc.change-data-capture` | transaction、schema evolution、checkpoint、sink/source failure |
| Proxy routing | `session.proxy-routing` | session state、prepared、transaction、CN drain/disconnect |
| PITR/restore | `recovery.pitr` | Catalog、storage、GC/history、tenant/security、conflict |
| Data Branch operation | `branch.data-branch` | history、schema、transaction、conflict、snapshot/GC |
