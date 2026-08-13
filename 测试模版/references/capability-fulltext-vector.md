# 全文与向量能力

## fulltext.search-and-index

- **支持状态:** supported-with-conditions
- **用户入口:** CREATE FULLTEXT INDEX、MATCH、自然语言/布尔模式和正式 Parser 配置
- **支持证据:** [创建全文索引](https://docs.matrixorigin.cn/v26.3.0.11/MatrixOne/Reference/SQL-Reference/Data-Definition-Language/create-fulltext-index/)、[兼容性矩阵](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)
- **支持范围:** 文档化 char/varchar/text/json/datalink 列、英语/CJK、支持 parser/mode、构建/查询/DML 生命周期
- **限制条件:** stopword、parser、排序和 MySQL FULLTEXT 语义为 Partial；异步 readiness 需按当前合同
- **状态与不变量:** 索引与表扫描语义 Oracle 一致；增量 DML 可见；NULL/空文档合同稳定；删除后重建无残留
- **测试分层:** fulltext BVT/MOTR、planner/fulltext UT、异步 scenario、规模/性能用 big-data/stability
- **仓库证据:** `repo:test/distributed/cases/fulltext`, `repo:pkg/fulltext`, `repo:docs/ai-skills/fulltext-vector.md`
- **关联能力:** 必需 `schema.indexes`, `query.optimizer-and-plan`, `storage.checkpoint-compaction-gc`; 高风险 async、nested rewrite、DML、restart
- **覆盖缺口:** 固定 sleep 不算 readiness；必须轮询精确结果和关键计划

## vector.types-and-functions

- **支持状态:** supported
- **用户入口:** VECF32/VECF64 等正式向量类型、距离/算术/归一化函数
- **支持证据:** [Schema 向量能力概览](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Develop/schema-design/overview/)、MatrixOne 向量参考文档
- **支持范围:** 官方文档中的向量类型、dimension 和函数
- **限制条件:** 最大维度、NULL、NaN/Inf、精度和函数组合按目标文档
- **状态与不变量:** 值/维度/类型/距离正确；非法维度稳定拒绝；错误后连接/数据恢复
- **测试分层:** vector BVT、container/function UT、Driver metadata（相关时）
- **仓库证据:** `repo:test/distributed/cases/vector`, `repo:pkg/container`
- **关联能力:** 必需 `sql.data-types-and-conversion`; 常见 load/export、prepared、protocol metadata
- **覆盖缺口:** 为目标函数选择数值容差，但不能用宽容差掩盖错误排序

## vector.ann-indexes

- **支持状态:** supported-with-conditions
- **用户入口:** 文档化 IVFFLAT/HNSW/其他正式 ANN index、Top-K、ALTER REINDEX
- **支持证据:** [兼容性矩阵向量索引条目](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)、MatrixOne 向量索引文档
- **支持范围:** 正式声明的 CPU/GPU 索引类型、op_type、build/query/rebuild/drop、增量 DML
- **限制条件:** CPU/GPU、experimental flags、支持距离、维度和 async build 条件必须逐索引写明；未正式索引不纳入
- **状态与不变量:** index Top-K 与 scan oracle/召回合同一致；计划确实走目标索引；DML/rebuild/restart 后一致；无隐藏表残留
- **测试分层:** vector BVT/MOTR scenario、planner/index UT、GPU workflow、规模 recall/performance big-data
- **仓库证据:** `repo:test/distributed/cases/vector`, `repo:pkg/sql/plan`
- **关联能力:** 必需 `schema.indexes`, `query.optimizer-and-plan`, `storage.checkpoint-compaction-gc`; 高风险 async readiness、CPU/GPU、wrapped expression、restart
- **覆盖缺口:** CPU binary 接受 gpu_mode 不等于 GPU 验收
