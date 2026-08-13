# 查询优化与执行

## query.optimizer-and-plan

- **支持状态:** supported
- **用户入口:** SQL 查询、EXPLAIN、ANALYZE TABLE/统计信息、Hint（正式文档范围）
- **支持证据:** [EXPLAIN in Feature List](https://docs.matrixorigin.cn/en/v25.3.0.2/MatrixOne/Overview/matrixone-feature-list/), MatrixOne SQL Reference
- **支持范围:** 逻辑/物理计划生成、正式支持的改写、join/subquery/CTE/window/index 选择和统计信息
- **限制条件:** 内部算法可演进；只把用户可观察的正确性和关键计划合同作为稳定接口
- **状态与不变量:** 优化前后结果等价；无丢行/重复/错误 NULL；EXPLAIN 关键路径与实际功能一致
- **测试分层:** optimizer/plan_cache BVT、planner UT、跨功能 MOTR；规模切换才用 big-data
- **仓库证据:** `repo:pkg/sql/plan`, `repo:test/distributed/cases/optimizer`, `repo:test/distributed/cases/analyze`
- **关联能力:** 必需 `sql.relational-query`, `storage.data-durability`; 高风险 `schema.indexes`, `query.memory-and-spill`
- **覆盖缺口:** 避免锁定空格、大小写和非合同 EXPLAIN 文本

## query.distributed-and-parallel-execution

- **支持状态:** supported-with-conditions
- **用户入口:** 普通查询在分布式/多 CN 部署上的透明执行和取消
- **支持证据:** [MatrixOne architecture](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Overview/architecture/), 正式部署文档
- **支持范围:** 正式部署拓扑中的并行 pipeline、remote operator 和结果汇聚
- **限制条件:** 并行度、调度和算子分布是实现细节；多 CN 需要对应部署环境
- **状态与不变量:** 单/多节点结果等价；取消有界返回；无 batch/receiver/session 泄漏或重复结果
- **测试分层:** compile/colexec UT、分布式 BVT/MOTR、multi-CN scenario；长稳资源进入 stability
- **仓库证据:** `repo:pkg/sql/compile`, `repo:pkg/sql/colexec`, `repo:test/distributed/cases/qexec`
- **关联能力:** 必需 `cluster.multi-cn`, `session.connection-lifecycle`; 高风险 cancel、CN drain、network failure
- **覆盖缺口:** 单 CN 测试不能证明跨 CN 调度与生命周期

## query.memory-and-spill

- **支持状态:** supported-with-conditions
- **用户入口:** 查询资源限制、EXPLAIN ANALYZE spill 指标、在内存压力下完成支持的算子
- **支持证据:** MatrixOne 正式配置/运维文档和查询执行测试资产
- **支持范围:** 支持算子的内存管理、spill 与 cleanup；sort/hash join/aggregate/window 等以当前实现文档为准
- **限制条件:** 必须证明实际跨阈值/发生 spill；小查询不能替代该路径
- **状态与不变量:** spill/non-spill 结果一致；拒绝映射稳定；无 OOM/restart/临时文件或 mpool 泄漏
- **测试分层:** ownership UT + big-data；小型 MOTR 只覆盖语义控制
- **仓库证据:** `repo:pkg/sql/colexec`, `repo:test/distributed/cases/feature_limit`
- **关联能力:** 必需 `storage.object-storage-and-cache`, `observability.explain-and-diagnostics`; 高风险 cancel、disk/object failure
- **覆盖缺口:** 设计必须记录阈值、peak memory、spill bytes/files 和结果摘要

## query.plan-cache-and-cancellation

- **支持状态:** supported
- **用户入口:** 重复 SQL/Prepared 查询、KILL QUERY/客户端取消、statement timeout（正式入口）
- **支持证据:** 正式 SQL/系统变量文档及 BVT
- **支持范围:** 重用计划时保持参数/Schema/session 正确性；查询取消和后续连接恢复
- **限制条件:** cache key 和内部失效算法不是用户合同
- **状态与不变量:** DDL/session/参数变化后无陈旧计划；取消不提交部分状态；连接和资源按合同恢复
- **测试分层:** plan_cache BVT、prepare/scenario、frontend/compile UT 与 `-race`
- **仓库证据:** `repo:test/distributed/cases/plan_cache`, `repo:test/distributed/cases/prepare`, `repo:pkg/frontend`
- **关联能力:** 必需 `session.prepared-statement`, `schema.ddl-lifecycle`; 高风险 Proxy migration、concurrent DDL
- **覆盖缺口:** 多连接 cache invalidation 需 scenario，单 SQL case 不足
