# 存储、Checkpoint、Compaction、Cache 与 GC

## storage.data-durability

- **Status:** supported
- **User entry:** 所有持久表写入、commit、restart 后查询和正式 durability/consistency 合同
- **Support evidence:** MatrixOne architecture/storage documentation
- **Scope:** 正式部署中的事务持久化、WAL/checkpoint replay 和 committed data durability
- **Limitations:** RPO/RTO 和外部对象存储保证按部署；内部 WAL 格式不是用户接口
- **State and invariants:** committed 数据重启后存在；uncommitted 不出现；Catalog/data/index 一致；无重复/丢失
- **Test routing:** storage/txn UT、disttae BVT、restart/recovery/chaos、长稳写入
- **Repository evidence:** `repo:docs/ai-skills/storage-engine.md`, `repo:test/distributed/cases/disttae`, `repo:pkg/logservice`
- **Interactions:** required `transaction.explicit-transaction`; high-risk checkpoint、object failure、GC、restore
- **Coverage gaps:** 不重启的 SQL 回归不能证明 durability

## storage.checkpoint-compaction-gc

- **Status:** supported-with-conditions
- **User entry:** 用户 DDL/DML 在后台 checkpoint、merge/compaction、GC 期间保持正确；正式管理入口（若有）
- **Support evidence:** MatrixOne storage/maintenance documentation and formal storage tests
- **Scope:** 后台生命周期对用户数据、索引、snapshot/history 和资源的公开保证
- **Limitations:** 调度算法和内部表不是稳定接口；强制触发可能需要专用测试配置
- **State and invariants:** 前后结果/metadata 一致；无 resurrection/duplicate/lost row；GC 不删除仍可见历史；资源回收
- **Test routing:** TAE/disttae UT、storage BVT、stability、restart/chaos、snapshot/PITR workflow
- **Repository evidence:** `repo:pkg/vm/engine/tae`, `repo:pkg/vm/engine/disttae`
- **Interactions:** required `storage.data-durability`; high-risk index、online DDL、CDC checkpoint、branch/recovery
- **Coverage gaps:** 未证明 checkpoint/compaction 实际发生时，普通 SQL 仅是语义控制

## storage.object-storage-and-cache

- **Status:** supported-with-conditions
- **User entry:** 正式对象存储部署、Stage/External/LOAD、查询和运维配置
- **Support evidence:** MatrixOne deployment/FileService/object storage documentation
- **Scope:** 文档化 S3-compatible/local fileservice、缓存和重试可观察合同
- **Limitations:** provider、credential、network 和容量条件按部署；cache 策略为实现细节
- **State and invariants:** cache hit/miss 结果一致；对象失败正常传播/重试；无 stale/cross-tenant data；临时对象清理
- **Test routing:** fileservice/objectio UT、stage/load BVT、对象存储 integration、big-data、failure chaos
- **Repository evidence:** `repo:pkg/fileservice`, `repo:pkg/objectio`, `repo:docs/ai-skills/fileservice.md`
- **Interactions:** required `security.authorization-and-isolation`; high-risk spill、load、backup、network failure
- **Coverage gaps:** memory/local FS 不能替代远端对象存储故障和一致性
