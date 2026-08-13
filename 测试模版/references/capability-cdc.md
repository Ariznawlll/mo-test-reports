# CDC 与数据集成

## cdc.change-data-capture

- **支持状态:** supported-with-conditions
- **用户入口:** 正式 `mo_cdc`/CDC task CLI/API、source/sink 配置和 task lifecycle
- **支持证据:** MatrixOne CDC official documentation and release notes
- **支持范围:** 文档化 MatrixOne source/downstream、initial scan、incremental DML、checkpoint、start/pause/resume/cancel
- **限制条件:** 支持下游、DDL/schema evolution、数据类型、部署和凭据条件按当前 CDC 文档
- **状态与不变量:** source/sink 行级一致；无丢失/重复；checkpoint 单调；restart/resume 不重放错误；凭据隔离
- **测试分层:** CDC 集成/场景测试、CDC UT、长期 stability、CN/TN/上游/下游故障 Chaos
- **仓库证据:** `repo:pkg/cdc`, `repo:docs/ai-skills/cdc.md`, `repo:test/distributed/cases/task`
- **关联能力:** 必需 `transaction.explicit-transaction`, `schema.ddl-lifecycle`, `storage.data-durability`; 高风险 schema change、checkpoint、network、tenant
- **覆盖缺口:** task running 不是通过，必须验证 checkpoint 和 source/sink 数据

## cdc.publication-subscription

- **支持状态:** supported-with-conditions
- **用户入口:** CREATE/ALTER/DROP PUBLICATION/SUBSCRIPTION、SHOW 和跨账户订阅
- **支持证据:** MatrixOne publication/subscription official SQL documentation and release notes
- **支持范围:** 文档化 database/table 发布范围、订阅、权限和数据可见性
- **限制条件:** 跨租户、DDL、写入权限和对象范围按文档
- **状态与不变量:** 仅授权对象可见；发布者变化按合同反映；drop/recreate 不串数据；跨租户隔离
- **测试分层:** publication_subscription BVT、multi-tenant MOTR、lifecycle/recovery scenario
- **仓库证据:** `repo:test/distributed/cases/publication_subscription`, `repo:pkg/frontend`
- **关联能力:** 必需 `security.authorization-and-isolation`, `schema.ddl-lifecycle`; 高风险 account lifecycle、restore、schema change
- **覆盖缺口:** 单租户查询不能证明 cross-account isolation
