# Snapshot、PITR、备份与恢复

## recovery.snapshot

- **支持状态:** supported-with-conditions
- **用户入口:** CREATE/DROP/SHOW SNAPSHOT、正式 scope 的 RESTORE
- **支持证据:** MatrixOne Snapshot 官方文档和发布说明
- **支持范围:** 文档支持的 cluster/account/database/table snapshot 和恢复范围
- **限制条件:** edition、scope、cross-account、保留期和冲突规则按当前文档
- **状态与不变量:** snapshot 时点数据/Catalog 一致；restore 精确；源对象不被修改；权限/租户隔离；失败原子
- **测试分层:** snapshot BVT + dedicated workflow；large data/restart/GC 进入 recovery/stability/chaos
- **仓库证据:** `repo:test/distributed/cases/snapshot`, `repo:docs/ai-skills/backup-restore.md`
- **关联能力:** 必需 `storage.data-durability`, `security.authorization-and-isolation`, `schema.ddl-lifecycle`; 高风险 GC、conflicting target、restart
- **覆盖缺口:** 不默认恢复整个 sys；必须使用隔离对象范围

## recovery.pitr

- **支持状态:** supported-with-conditions
- **用户入口:** CREATE/ALTER/DROP/SHOW PITR、RESTORE、正式 `mo_br` PITR 流程
- **支持证据:** [mo_br PITR](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Maintain/backup-restore/mobr-backup-restore/mobr-pitr-backup-restore/), MatrixOne PITR SQL docs
- **支持范围:** 文档支持的 SQL 与工具恢复方式、时间范围和对象 scope
- **限制条件:** `mo_br`/企业工具获取、保留期、基础备份、部署和权限条件必须写明
- **状态与不变量:** 目标恢复到精确时点；范围外对象不变；过期/非法时点和冲突正常拒绝；恢复可重试/清理
- **测试分层:** PITR BVT + 完整恢复工作流；GC、重启、大数据和 Chaos 按合同选择
- **仓库证据:** `repo:test/distributed/cases/pitr`, `repo:docs/ai-skills/backup-restore.md`
- **关联能力:** 必需 `storage.checkpoint-compaction-gc`, `security.authorization-and-isolation`; 高风险 history/GC、cross-account、schema evolution
- **覆盖缺口:** BVT 不能替代 full backup + incremental log 的完整工具流程

## recovery.backup-restore

- **支持状态:** supported-with-conditions
- **用户入口:** 正式 `mo_br`/backup CLI、全量/增量备份与恢复
- **支持证据:** MatrixOne 备份恢复官方运维文档
- **支持范围:** 正式工具支持的备份介质、对象范围、恢复和校验流程
- **限制条件:** 工具版本、产品 edition、对象存储、凭据和拓扑条件按文档
- **状态与不变量:** manifest/data/Catalog 一致；恢复后精确校验；失败可清理/重试；备份不影响源业务合同
- **测试分层:** 专用备份恢复工作流、big-data、stability、对象/节点故障 Chaos
- **仓库证据:** `repo:pkg/backup`, `repo:docs/ai-skills/backup-restore.md`
- **关联能力:** 必需 `storage.object-storage-and-cache`, `security.authorization-and-isolation`; 高风险 concurrent DDL/DML、version compatibility
- **覆盖缺口:** SQL snapshot 控制不能替代外部备份工具验证
