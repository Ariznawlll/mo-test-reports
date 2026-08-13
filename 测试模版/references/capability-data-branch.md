# Data Branch / Git4Data

## branch.data-branch

- **支持状态:** supported-with-conditions
- **用户入口:** 官方 CREATE … CLONE/branch、DIFF、MERGE、PICK、DELETE/OUTPUT 等 Git4Data SQL
- **支持证据:** MatrixOne Data Branch/Git4Data 官方文档、[兼容性矩阵 MO-only 条目](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)
- **支持范围:** 文档化 table/database branch/clone、差异、合并、挑选、冲突策略和历史操作
- **限制条件:** object scope、history/GC、PK/no-PK、cross-account 和 schema change 条件按当前文档
- **状态与不变量:** source/branch/target 隔离；selected/unselected 数据精确；冲突策略正确；拒绝无 target/部分 merge
- **测试分层:** git4data BVT/MOTR、history/storage UT、large history/GC recovery workflow
- **仓库证据:** `repo:test/distributed/cases/git4data`, `repo:docs/design/data_branch_pick.md`
- **关联能力:** 必需 `storage.data-durability`, `schema.ddl-lifecycle`, `transaction.statement-atomicity`; 高风险 snapshot/GC、schema divergence、special values
- **覆盖缺口:** 每项设计先核对正式支持的 object scope 和 conflict strategy

## branch.protected-history

- **支持状态:** supported-with-conditions
- **用户入口:** 文档化的 Branch Protect、Snapshot/历史保留和相关管理 SQL
- **支持证据:** [兼容性矩阵 Branch Protect Snapshots](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)、MatrixOne Data Branch 文档
- **支持范围:** 正式支持的保护快照、历史选择和 GC 交互
- **限制条件:** 保留期、scope 和企业/云条件按文档
- **状态与不变量:** 仍被 branch/history 引用的数据不被 GC；删除/过期后资源最终回收；隔离正确
- **测试分层:** git4data/recovery BVT、GC/history integration、long-running cleanup
- **仓库证据:** `repo:docs/design/data_branch_protect_snapshot.md`, `repo:test/distributed/cases/git4data`
- **关联能力:** 必需 `storage.checkpoint-compaction-gc`, `recovery.snapshot`; 高风险 concurrent branch/restore/drop
- **覆盖缺口:** 必须证明 GC/保护状态实际变化，普通查询不够
