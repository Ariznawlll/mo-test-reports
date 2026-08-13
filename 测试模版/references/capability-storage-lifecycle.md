# 存储、Checkpoint、Compaction、Cache 与 GC

## storage.data-durability

- **支持状态:** supported
- **用户入口:** 所有持久表写入、commit、restart 后查询和正式 durability/consistency 合同
- **支持证据:** MatrixOne architecture/storage documentation
- **支持范围:** 正式部署中的事务持久化、WAL/Checkpoint 重放和已提交数据持久性
- **限制条件:** RPO/RTO 和外部对象存储保证按部署；内部 WAL 格式不是用户接口
- **状态与不变量:** committed 数据重启后存在；uncommitted 不出现；Catalog/data/index 一致；无重复/丢失
- **测试分层:** storage/txn UT、disttae BVT、restart/recovery/chaos、长稳写入
- **仓库证据:** `repo:docs/ai-skills/storage-engine.md`, `repo:test/distributed/cases/disttae`, `repo:pkg/logservice`
- **关联能力:** 必需 `transaction.explicit-transaction`; 高风险 checkpoint、object failure、GC、restore
- **覆盖缺口:** 不重启的 SQL 回归不能证明 durability

## storage.checkpoint-compaction-gc

- **支持状态:** supported-with-conditions
- **用户入口:** 用户 DDL/DML 在后台 checkpoint、merge/compaction、GC 期间保持正确；正式管理入口（若有）
- **支持证据:** MatrixOne 存储/维护文档和正式存储测试
- **支持范围:** 后台生命周期对用户数据、索引、snapshot/history 和资源的公开保证
- **限制条件:** 调度算法和内部表不是稳定接口；强制触发可能需要专用测试配置
- **状态与不变量:** 前后结果/metadata 一致；无 resurrection/duplicate/lost row；GC 不删除仍可见历史；资源回收
- **测试分层:** TAE/disttae UT、storage BVT、stability、restart/chaos、snapshot/PITR workflow
- **仓库证据:** `repo:pkg/vm/engine/tae`, `repo:pkg/vm/engine/disttae`
- **关联能力:** 必需 `storage.data-durability`; 高风险 index、online DDL、CDC checkpoint、branch/recovery
- **覆盖缺口:** 未证明 checkpoint/compaction 实际发生时，普通 SQL 仅是语义控制

## storage.object-storage-and-cache

- **支持状态:** supported-with-conditions
- **用户入口:** 正式对象存储部署、Stage/External/LOAD、查询和运维配置
- **支持证据:** MatrixOne 部署、FileService 和对象存储文档
- **支持范围:** 文档化 S3-compatible/local fileservice、缓存和重试可观察合同
- **限制条件:** provider、credential、network 和容量条件按部署；cache 策略为实现细节
- **状态与不变量:** cache hit/miss 结果一致；对象失败正常传播/重试；无 stale/cross-tenant data；临时对象清理
- **测试分层:** fileservice/objectio UT、stage/load BVT、对象存储 integration、big-data、failure chaos
- **仓库证据:** `repo:pkg/fileservice`, `repo:pkg/objectio`, `repo:docs/ai-skills/fileservice.md`
- **关联能力:** 必需 `security.authorization-and-isolation`; 高风险 spill、load、backup、network failure
- **覆盖缺口:** memory/local FS 不能替代远端对象存储故障和一致性
