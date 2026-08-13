# 可观测性与运维

## observability.explain-and-diagnostics

- **支持状态:** supported
- **用户入口:** EXPLAIN、EXPLAIN ANALYZE、statement/query diagnostics 和正式系统表
- **支持证据:** [Feature List EXPLAIN](https://docs.matrixorigin.cn/en/v25.3.0.2/MatrixOne/Overview/matrixone-feature-list/)、MatrixOne 可观测性 SQL 文档
- **支持范围:** 文档化逻辑/物理计划、运行统计、查询/语句诊断和 metadata
- **限制条件:** 非合同文本格式和内部 operator 名可能演进；敏感 SQL/参数需脱敏
- **状态与不变量:** 关键算子/行数/资源与执行一致；观测不改变结果；无非法 UTF-8/secret 泄露
- **测试分层:** analyze/log/metadata BVT、plan/compile UT、spill/profile integration
- **仓库证据:** `repo:test/distributed/cases/analyze`, `repo:test/distributed/cases/log`, `repo:test/distributed/cases/metadata`
- **关联能力:** 必需 被观测能力；高风险 spill、async task、failed query、large statement
- **覆盖缺口:** 只断言 EXPLAIN 不能证明结果正确

## observability.system-status

- **支持状态:** supported-with-conditions
- **用户入口:** SHOW、information_schema/mo_catalog/system tables、正式 metrics/logs/cluster/task status
- **支持证据:** MatrixOne 系统表和运维文档
- **支持范围:** 文档化 metadata、cluster/task/storage/session 状态和运维观测
- **限制条件:** sys-only/权限、保留期和字段兼容按文档；内部表不自动视为稳定接口
- **状态与不变量:** 状态及时且租户隔离；计数/进度与实际一致；查询无副作用；日志/metric 可关联但不泄密
- **测试分层:** system/metadata/task BVT、ops integration、stability/chaos verification
- **仓库证据:** `repo:test/distributed/cases/system`, `repo:test/distributed/cases/task`, `repo:test/distributed/cases/metadata`
- **关联能力:** 必需 `security.authorization-and-isolation`; 常见 所有异步/集群/存储能力
- **覆盖缺口:** “running”状态必须结合进度和最终数据，不能单独判通过
