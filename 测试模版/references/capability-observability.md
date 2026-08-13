# 可观测性与运维

## observability.explain-and-diagnostics

- **Status:** supported
- **User entry:** EXPLAIN、EXPLAIN ANALYZE、statement/query diagnostics 和正式系统表
- **Support evidence:** [Feature List EXPLAIN](https://docs.matrixorigin.cn/en/v25.3.0.2/MatrixOne/Overview/matrixone-feature-list/), MatrixOne observability SQL docs
- **Scope:** 文档化逻辑/物理计划、运行统计、查询/语句诊断和 metadata
- **Limitations:** 非合同文本格式和内部 operator 名可能演进；敏感 SQL/参数需脱敏
- **State and invariants:** 关键算子/行数/资源与执行一致；观测不改变结果；无非法 UTF-8/secret 泄露
- **Test routing:** analyze/log/metadata BVT、plan/compile UT、spill/profile integration
- **Repository evidence:** `repo:test/distributed/cases/analyze`, `repo:test/distributed/cases/log`, `repo:test/distributed/cases/metadata`
- **Interactions:** required 被观测能力；high-risk spill、async task、failed query、large statement
- **Coverage gaps:** 只断言 EXPLAIN 不能证明结果正确

## observability.system-status

- **Status:** supported-with-conditions
- **User entry:** SHOW、information_schema/mo_catalog/system tables、正式 metrics/logs/cluster/task status
- **Support evidence:** MatrixOne system tables and operations documentation
- **Scope:** 文档化 metadata、cluster/task/storage/session 状态和运维观测
- **Limitations:** sys-only/权限、保留期和字段兼容按文档；内部表不自动视为稳定接口
- **State and invariants:** 状态及时且租户隔离；计数/进度与实际一致；查询无副作用；日志/metric 可关联但不泄密
- **Test routing:** system/metadata/task BVT、ops integration、stability/chaos verification
- **Repository evidence:** `repo:test/distributed/cases/system`, `repo:test/distributed/cases/task`, `repo:test/distributed/cases/metadata`
- **Interactions:** required `security.authorization-and-isolation`; common 所有异步/集群/存储能力
- **Coverage gaps:** “running”状态必须结合进度和最终数据，不能单独判通过
