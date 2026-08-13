# Schema、约束、DDL 与索引

## schema.ddl-lifecycle

- **支持状态:** supported-with-conditions
- **用户入口:** CREATE/DROP DATABASE/TABLE/VIEW/TEMPORARY TABLE/SEQUENCE、ALTER、TRUNCATE、RENAME
- **支持证据:** [Feature List DDL](https://docs.matrixorigin.cn/en/v25.3.0.2/MatrixOne/Overview/matrixone-feature-list/), [Compatibility Matrix](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)
- **支持范围:** 文档标为正式支持的对象和 ALTER 子句；组合限制按当前文档
- **限制条件:** Experimental/N 子句不进入范围；部分 ALTER 组合和 MySQL 差异必须逐项确认
- **状态与不变量:** 成功后 Catalog/data/依赖一致；拒绝无部分对象、隐藏表或数据变更；rename/drop/recreate 无陈旧 cache
- **测试分层:** ddl/table/view/temporary/sequence BVT；并发/多会话 MOTR；Catalog ownership UT
- **仓库证据:** `repo:test/distributed/cases/ddl`, `repo:test/distributed/cases/table`, `repo:test/distributed/cases/view`, `repo:test/distributed/cases/temporary`
- **关联能力:** 必需 `transaction.statement-atomicity`, `storage.checkpoint-compaction-gc`; 高风险 index/constraint、concurrent DML、CDC、recovery
- **覆盖缺口:** Feature 设计必须引用具体 ALTER 支持条款

## schema.constraints

- **支持状态:** supported
- **用户入口:** PRIMARY KEY、UNIQUE、FOREIGN KEY、NOT NULL、DEFAULT、CHECK、AUTO_INCREMENT
- **支持证据:** [Feature List 索引与约束](https://docs.matrixorigin.cn/en/v25.3.0.2/MatrixOne/Overview/matrixone-feature-list/)、Schema 设计文档
- **支持范围:** 表定义和正式 ALTER 路径中的约束创建、校验、DML 执行与删除
- **限制条件:** defer/cascade/IGNORE/MySQL 宽松语义以专项文档和兼容矩阵为准
- **状态与不变量:** 约束始终成立；混合成功/拒绝符合 statement 合同；失败无隐藏索引/Catalog 残留
- **测试分层:** foreign_key/auto_increment/ddl/dml BVT；并发唯一性与在线 DDL scenario；内部 UT
- **仓库证据:** `repo:test/distributed/cases/foreign_key`, `repo:test/distributed/cases/auto_increment`, `repo:test/distributed/cases/fake_pk`
- **关联能力:** 必需 `transaction.statement-atomicity`, `schema.indexes`; 高风险 LOAD/IGNORE、concurrent DML、branch/restore
- **覆盖缺口:** 每种错误后立即复核全表和 Catalog

## schema.indexes

- **支持状态:** supported
- **用户入口:** CREATE/DROP INDEX、PRIMARY/UNIQUE/二级索引、EXPLAIN 索引扫描
- **支持证据:** [Schema 索引概览](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Develop/schema-design/overview/)、[兼容性矩阵 CREATE INDEX](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)
- **支持范围:** 正式普通/唯一/主键索引、查询优化参与、DML 维护和生命周期
- **限制条件:** index hint、函数索引和专用全文/向量语法按兼容矩阵；特殊索引见专项域
- **状态与不变量:** index/table scan 结果等价；DML 后一致；失败创建无 Catalog/hidden table；drop/recreate 无陈旧计划
- **测试分层:** index/optimizer BVT、planner/storage UT、在线 DDL/多连接 MOTR、规模计划才 big-data
- **仓库证据:** `repo:test/distributed/cases/optimizer`, `repo:test/distributed/cases/ddl`, `repo:pkg/sql/plan`
- **关联能力:** 必需 `query.optimizer-and-plan`、`storage.checkpoint-compaction-gc`；高风险并发 DML、重启、异步专用索引
- **覆盖缺口:** 普通索引条目不替代 fulltext/vector 专项条件
