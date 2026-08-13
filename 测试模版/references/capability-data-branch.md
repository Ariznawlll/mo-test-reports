# Data Branch / Git4Data

## branch.data-branch

- **Status:** supported-with-conditions
- **User entry:** 官方 CREATE … CLONE/branch、DIFF、MERGE、PICK、DELETE/OUTPUT 等 Git4Data SQL
- **Support evidence:** MatrixOne Data Branch/Git4Data official docs, [Compatibility Matrix MO-only entries](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)
- **Scope:** 文档化 table/database branch/clone、差异、合并、挑选、冲突策略和历史操作
- **Limitations:** object scope、history/GC、PK/no-PK、cross-account 和 schema change 条件按当前文档
- **State and invariants:** source/branch/target 隔离；selected/unselected 数据精确；冲突策略正确；拒绝无 target/部分 merge
- **Test routing:** git4data BVT/MOTR、history/storage UT、large history/GC recovery workflow
- **Repository evidence:** `repo:test/distributed/cases/git4data`, `repo:docs/design/data_branch_pick.md`
- **Interactions:** required `storage.data-durability`, `schema.ddl-lifecycle`, `transaction.statement-atomicity`; high-risk snapshot/GC、schema divergence、special values
- **Coverage gaps:** 每项设计先核对正式支持的 object scope 和 conflict strategy

## branch.protected-history

- **Status:** supported-with-conditions
- **User entry:** 文档化 branch protect snapshot/history 保留和相关管理 SQL
- **Support evidence:** [Compatibility Matrix Branch Protect Snapshots](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/), MatrixOne Data Branch docs
- **Scope:** 正式支持的保护快照、历史选择和 GC 交互
- **Limitations:** 保留期、scope 和企业/云条件按文档
- **State and invariants:** 仍被 branch/history 引用的数据不被 GC；删除/过期后资源最终回收；隔离正确
- **Test routing:** git4data/recovery BVT、GC/history integration、long-running cleanup
- **Repository evidence:** `repo:docs/design/data_branch_protect_snapshot.md`, `repo:test/distributed/cases/git4data`
- **Interactions:** required `storage.checkpoint-compaction-gc`, `recovery.snapshot`; high-risk concurrent branch/restore/drop
- **Coverage gaps:** 必须证明 GC/保护状态实际变化，普通查询不够
