# 全文与向量能力

## fulltext.search-and-index

- **Status:** supported-with-conditions
- **User entry:** CREATE FULLTEXT INDEX、MATCH、natural language/boolean mode 和正式 parser 配置
- **Support evidence:** [Create Fulltext Index](https://docs.matrixorigin.cn/v26.3.0.11/MatrixOne/Reference/SQL-Reference/Data-Definition-Language/create-fulltext-index/), [Compatibility Matrix](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)
- **Scope:** 文档化 char/varchar/text/json/datalink 列、英语/CJK、支持 parser/mode、构建/查询/DML 生命周期
- **Limitations:** stopword、parser、排序和 MySQL FULLTEXT 语义为 Partial；异步 readiness 需按当前合同
- **State and invariants:** index/table semantic oracle 一致；增量 DML 可见；NULL/空文档合同稳定；drop/recreate 无残留
- **Test routing:** fulltext BVT/MOTR、planner/fulltext UT、异步 scenario、规模/性能用 big-data/stability
- **Repository evidence:** `repo:test/distributed/cases/fulltext`, `repo:pkg/fulltext`, `repo:docs/ai-skills/fulltext-vector.md`
- **Interactions:** required `schema.indexes`, `query.optimizer-and-plan`, `storage.checkpoint-compaction-gc`; high-risk async、nested rewrite、DML、restart
- **Coverage gaps:** 固定 sleep 不算 readiness；必须轮询精确结果和关键计划

## vector.types-and-functions

- **Status:** supported
- **User entry:** VECF32/VECF64 等正式向量类型、距离/算术/归一化函数
- **Support evidence:** [Schema Vector overview](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Develop/schema-design/overview/), MatrixOne Vector Reference
- **Scope:** 官方文档中的向量类型、dimension 和函数
- **Limitations:** 最大维度、NULL、NaN/Inf、精度和函数组合按目标文档
- **State and invariants:** 值/维度/类型/距离正确；非法维度稳定拒绝；错误后连接/数据恢复
- **Test routing:** vector BVT、container/function UT、Driver metadata（相关时）
- **Repository evidence:** `repo:test/distributed/cases/vector`, `repo:pkg/container`
- **Interactions:** required `sql.data-types-and-conversion`; common load/export、prepared、protocol metadata
- **Coverage gaps:** 为目标函数选择数值容差，但不能用宽容差掩盖错误排序

## vector.ann-indexes

- **Status:** supported-with-conditions
- **User entry:** 文档化 IVFFLAT/HNSW/其他正式 ANN index、Top-K、ALTER REINDEX
- **Support evidence:** [Compatibility Matrix vector index entries](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/), MatrixOne Vector Index docs
- **Scope:** 正式声明的 CPU/GPU 索引类型、op_type、build/query/rebuild/drop、增量 DML
- **Limitations:** CPU/GPU、experimental flags、支持距离、维度和 async build 条件必须逐索引写明；未正式索引不纳入
- **State and invariants:** index Top-K 与 scan oracle/召回合同一致；计划确实走目标索引；DML/rebuild/restart 后一致；无隐藏表残留
- **Test routing:** vector BVT/MOTR scenario、planner/index UT、GPU workflow、规模 recall/performance big-data
- **Repository evidence:** `repo:test/distributed/cases/vector`, `repo:pkg/sql/plan`
- **Interactions:** required `schema.indexes`, `query.optimizer-and-plan`, `storage.checkpoint-compaction-gc`; high-risk async readiness、CPU/GPU、wrapped expression、restart
- **Coverage gaps:** CPU binary 接受 gpu_mode 不等于 GPU 验收
