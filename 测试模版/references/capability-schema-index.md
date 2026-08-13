# Schema、约束、DDL 与索引

## schema.ddl-lifecycle

- **Status:** supported-with-conditions
- **User entry:** CREATE/DROP DATABASE/TABLE/VIEW/TEMPORARY TABLE/SEQUENCE、ALTER、TRUNCATE、RENAME
- **Support evidence:** [Feature List DDL](https://docs.matrixorigin.cn/en/v25.3.0.2/MatrixOne/Overview/matrixone-feature-list/), [Compatibility Matrix](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)
- **Scope:** 文档标为正式支持的对象和 ALTER 子句；组合限制按当前文档
- **Limitations:** Experimental/N 子句不进入范围；部分 ALTER 组合和 MySQL 差异必须逐项确认
- **State and invariants:** 成功后 Catalog/data/依赖一致；拒绝无部分对象、隐藏表或数据变更；rename/drop/recreate 无陈旧 cache
- **Test routing:** ddl/table/view/temporary/sequence BVT；并发/多会话 MOTR；Catalog ownership UT
- **Repository evidence:** `repo:test/distributed/cases/ddl`, `repo:test/distributed/cases/table`, `repo:test/distributed/cases/view`, `repo:test/distributed/cases/temporary`
- **Interactions:** required `transaction.statement-atomicity`, `storage.checkpoint-compaction-gc`; high-risk index/constraint、concurrent DML、CDC、recovery
- **Coverage gaps:** Feature 设计必须引用具体 ALTER 支持条款

## schema.constraints

- **Status:** supported
- **User entry:** PRIMARY KEY、UNIQUE、FOREIGN KEY、NOT NULL、DEFAULT、CHECK、AUTO_INCREMENT
- **Support evidence:** [Feature List indexing and constraints](https://docs.matrixorigin.cn/en/v25.3.0.2/MatrixOne/Overview/matrixone-feature-list/), Schema design docs
- **Scope:** 表定义和正式 ALTER 路径中的约束创建、校验、DML 执行与删除
- **Limitations:** defer/cascade/IGNORE/MySQL 宽松语义以专项文档和兼容矩阵为准
- **State and invariants:** 约束始终成立；混合成功/拒绝符合 statement 合同；失败无隐藏索引/Catalog 残留
- **Test routing:** foreign_key/auto_increment/ddl/dml BVT；并发唯一性与在线 DDL scenario；内部 UT
- **Repository evidence:** `repo:test/distributed/cases/foreign_key`, `repo:test/distributed/cases/auto_increment`, `repo:test/distributed/cases/fake_pk`
- **Interactions:** required `transaction.statement-atomicity`, `schema.indexes`; high-risk LOAD/IGNORE、concurrent DML、branch/restore
- **Coverage gaps:** 每种错误后立即复核全表和 Catalog

## schema.indexes

- **Status:** supported
- **User entry:** CREATE/DROP INDEX、PRIMARY/UNIQUE/secondary index、EXPLAIN index scan
- **Support evidence:** [Schema index overview](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Develop/schema-design/overview/), [Compatibility Matrix CREATE INDEX](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)
- **Scope:** 正式普通/唯一/主键索引、查询优化参与、DML 维护和生命周期
- **Limitations:** index hint、函数索引和专用全文/向量语法按兼容矩阵；特殊索引见专项域
- **State and invariants:** index/table scan 结果等价；DML 后一致；失败创建无 Catalog/hidden table；drop/recreate 无陈旧计划
- **Test routing:** index/optimizer BVT、planner/storage UT、在线 DDL/多连接 MOTR、规模计划才 big-data
- **Repository evidence:** `repo:test/distributed/cases/optimizer`, `repo:test/distributed/cases/ddl`, `repo:pkg/sql/plan`
- **Interactions:** required `query.optimizer-and-plan`, `storage.checkpoint-compaction-gc`; high-risk concurrent DML、restart、async specialized index
- **Coverage gaps:** 普通索引条目不替代 fulltext/vector 专项条件
