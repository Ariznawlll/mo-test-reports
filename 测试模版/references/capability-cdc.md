# CDC 与数据集成

## cdc.change-data-capture

- **Status:** supported-with-conditions
- **User entry:** 正式 `mo_cdc`/CDC task CLI/API、source/sink 配置和 task lifecycle
- **Support evidence:** MatrixOne CDC official documentation and release notes
- **Scope:** 文档化 MatrixOne source/downstream、initial scan、incremental DML、checkpoint、start/pause/resume/cancel
- **Limitations:** 支持下游、DDL/schema evolution、数据类型、部署和凭据条件按当前 CDC 文档
- **State and invariants:** source/sink 行级一致；无丢失/重复；checkpoint 单调；restart/resume 不重放错误；凭据隔离
- **Test routing:** CDC integration/scenario、CDC UT、long-running stability、CN/TN/source/sink failure chaos
- **Repository evidence:** `repo:pkg/cdc`, `repo:docs/ai-skills/cdc.md`, `repo:test/distributed/cases/task`
- **Interactions:** required `transaction.explicit-transaction`, `schema.ddl-lifecycle`, `storage.data-durability`; high-risk schema change、checkpoint、network、tenant
- **Coverage gaps:** task running 不是通过，必须验证 checkpoint 和 source/sink 数据

## cdc.publication-subscription

- **Status:** supported-with-conditions
- **User entry:** CREATE/ALTER/DROP PUBLICATION/SUBSCRIPTION、SHOW 和跨账户订阅
- **Support evidence:** MatrixOne publication/subscription official SQL documentation and release notes
- **Scope:** 文档化 database/table 发布范围、订阅、权限和数据可见性
- **Limitations:** 跨租户、DDL、写入权限和对象范围按文档
- **State and invariants:** 仅授权对象可见；发布者变化按合同反映；drop/recreate 不串数据；跨租户隔离
- **Test routing:** publication_subscription BVT、multi-tenant MOTR、lifecycle/recovery scenario
- **Repository evidence:** `repo:test/distributed/cases/publication_subscription`, `repo:pkg/frontend`
- **Interactions:** required `security.authorization-and-isolation`, `schema.ddl-lifecycle`; high-risk account lifecycle、restore、schema change
- **Coverage gaps:** 单租户查询不能证明 cross-account isolation
