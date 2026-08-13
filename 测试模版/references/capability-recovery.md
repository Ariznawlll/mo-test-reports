# Snapshot、PITR、备份与恢复

## recovery.snapshot

- **Status:** supported-with-conditions
- **User entry:** CREATE/DROP/SHOW SNAPSHOT、正式 scope 的 RESTORE
- **Support evidence:** MatrixOne Snapshot official docs and release notes
- **Scope:** 文档支持的 cluster/account/database/table snapshot 和恢复范围
- **Limitations:** edition、scope、cross-account、保留期和冲突规则按当前文档
- **State and invariants:** snapshot 时点数据/Catalog 一致；restore 精确；源对象不被修改；权限/租户隔离；失败原子
- **Test routing:** snapshot BVT + dedicated workflow；large data/restart/GC 进入 recovery/stability/chaos
- **Repository evidence:** `repo:test/distributed/cases/snapshot`, `repo:docs/ai-skills/backup-restore.md`
- **Interactions:** required `storage.data-durability`, `security.authorization-and-isolation`, `schema.ddl-lifecycle`; high-risk GC、conflicting target、restart
- **Coverage gaps:** 不默认恢复整个 sys；必须使用隔离对象范围

## recovery.pitr

- **Status:** supported-with-conditions
- **User entry:** CREATE/ALTER/DROP/SHOW PITR、RESTORE、正式 `mo_br` PITR 流程
- **Support evidence:** [mo_br PITR](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Maintain/backup-restore/mobr-backup-restore/mobr-pitr-backup-restore/), MatrixOne PITR SQL docs
- **Scope:** 文档支持的 SQL 与工具恢复方式、时间范围和对象 scope
- **Limitations:** `mo_br`/企业工具获取、保留期、基础备份、部署和权限条件必须写明
- **State and invariants:** 目标恢复到精确时点；范围外对象不变；过期/非法时点和冲突正常拒绝；恢复可重试/清理
- **Test routing:** pitr BVT + full recovery workflow；GC/restart/large data/chaos 按合同
- **Repository evidence:** `repo:test/distributed/cases/pitr`, `repo:docs/ai-skills/backup-restore.md`
- **Interactions:** required `storage.checkpoint-compaction-gc`, `security.authorization-and-isolation`; high-risk history/GC、cross-account、schema evolution
- **Coverage gaps:** BVT 不能替代 full backup + incremental log 的完整工具流程

## recovery.backup-restore

- **Status:** supported-with-conditions
- **User entry:** 正式 `mo_br`/backup CLI、全量/增量备份与恢复
- **Support evidence:** MatrixOne backup/restore official maintenance documentation
- **Scope:** 正式工具支持的备份介质、对象范围、恢复和校验流程
- **Limitations:** 工具版本、产品 edition、对象存储、凭据和拓扑条件按文档
- **State and invariants:** manifest/data/Catalog 一致；恢复后精确校验；失败可清理/重试；备份不影响源业务合同
- **Test routing:** dedicated backup-restore workflow、big-data、stability、object/node failure chaos
- **Repository evidence:** `repo:pkg/backup`, `repo:docs/ai-skills/backup-restore.md`
- **Interactions:** required `storage.object-storage-and-cache`, `security.authorization-and-isolation`; high-risk concurrent DDL/DML、version compatibility
- **Coverage gaps:** SQL snapshot 控制不能替代外部备份工具验证
