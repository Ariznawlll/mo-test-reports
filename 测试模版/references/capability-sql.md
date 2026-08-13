# SQL 语言、类型与兼容性

## sql.schema-and-data-statements

- **Status:** supported
- **User entry:** CREATE/DROP/TRUNCATE/RENAME、SELECT、INSERT、UPDATE、DELETE、REPLACE、INSERT…SELECT/ODKU
- **Support evidence:** [Feature List](https://docs.matrixorigin.cn/en/v25.3.0.2/MatrixOne/Overview/matrixone-feature-list/), [SQL categories](https://docs.matrixorigin.cn/en/m1intelligence/MatrixOne-Intelligence/Reference/SQL-Reference/SQL-Type/)
- **Scope:** 正式文档列出的 DDL、DML、DQL 和 TCL；具体 ALTER/对象能力由 schema 域限定
- **Limitations:** 以兼容矩阵为准；不得从 Parser 接受推断完整 MySQL 语义
- **State and invariants:** 精确结果、类型和 affected rows；拒绝语句不产生部分数据或 Catalog 修改
- **Test routing:** SQL BVT；跨功能语义进入 MOTR；内部表达式/编码进入 UT
- **Repository evidence:** `repo:test/distributed/cases/ddl`, `repo:test/distributed/cases/dml`, `repo:test/distributed/cases/operator`
- **Interactions:** required `schema.ddl-lifecycle`, `query.relational-query`; common `transaction.explicit-transaction`, `session.prepared-statement`
- **Coverage gaps:** 按具体语句读取兼容矩阵，不能用本总条目替代语法级支持确认

## sql.relational-query

- **Status:** supported
- **User entry:** SELECT、JOIN、GROUP BY、ORDER BY、UNION/INTERSECT/EXCEPT、subquery、CTE/recursive CTE、window
- **Support evidence:** [Feature List](https://docs.matrixorigin.cn/en/v25.3.0.2/MatrixOne/Overview/matrixone-feature-list/), [SQL categories](https://docs.matrixorigin.cn/en/m1intelligence/MatrixOne-Intelligence/Reference/SQL-Reference/SQL-Type/)
- **Scope:** 正式列出的关系查询组合、聚合、集合运算、相关/非相关子查询、CTE 和窗口
- **Limitations:** 方言、NULL、排序和不支持形状以当前兼容矩阵/专项文档为准
- **State and invariants:** 完整 multiset、NULL 三值逻辑、确定排序、聚合/窗口边界和不同等价查询结果一致
- **Test routing:** BVT；复杂跨算子回归进入 MOTR；大规模计划只在规模触发时进入 big-data
- **Repository evidence:** `repo:test/distributed/cases/join`, `repo:test/distributed/cases/subquery`, `repo:test/distributed/cases/cte`, `repo:test/distributed/cases/window`, `repo:test/distributed/cases/union`
- **Interactions:** required `query.optimizer-and-plan`, `sql.data-types-and-conversion`; high-risk `schema.indexes`, `query.memory-and-spill`
- **Coverage gaps:** 使用 Feature 的实际查询形状选择算子组合，不做全 SQL 笛卡尔积

## sql.data-types-and-conversion

- **Status:** supported-with-conditions
- **User entry:** 表列类型、CAST/CONVERT、隐式赋值/比较转换、函数参数与结果类型
- **Support evidence:** [Feature List data types](https://docs.matrixorigin.cn/en/v25.3.0.2/MatrixOne/Overview/matrixone-feature-list/), [Compatibility Matrix](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)
- **Scope:** 文档标为 Y/正式支持的数值、字符串、二进制、日期时间、JSON、数组和向量类型及公开转换
- **Limitations:** BIT、charset/collation、ENUM 排序过滤和宽松 MySQL cast 等差异必须按兼容矩阵逐项确认
- **State and invariants:** 值、类型、精度、scale、符号、timezone 和 NULL 正确；失败 cast 不部分写入
- **Test routing:** dtype/expression/function BVT；转换内核 UT；协议 metadata 用 scenario
- **Repository evidence:** `repo:test/distributed/cases/dtype`, `repo:test/distributed/cases/pg_cast`, `repo:test/distributed/cases/expression`
- **Interactions:** required `session.timezone-and-sql-mode`; common `session.prepared-statement`, `dataio.load-and-export`
- **Coverage gaps:** 每个 Feature 只选择实际可达类型族和合法边界

## sql.functions-time-window-and-expressions

- **Status:** supported-with-conditions
- **User entry:** 内置函数、操作符、CASE、时间函数、Time Window/Sliding/Gapfill 文档化语法
- **Support evidence:** [Feature List functions/timing](https://docs.matrixorigin.cn/en/v25.3.0.2/MatrixOne/Overview/matrixone-feature-list/)
- **Scope:** 官方 SQL Reference 中列出的函数/操作符和标为 Y 的 timing 能力
- **Limitations:** 函数级限制、精度、NULL 和 MySQL 差异以各函数页面为准；未列函数不从代码推断支持
- **State and invariants:** 确定输入产生精确值/类型；NULL 与边界符合合同；非法参数走普通错误路径且无 panic
- **Test routing:** function/expression/time_window BVT；函数内核 UT；跨功能 MOTR
- **Repository evidence:** `repo:test/distributed/cases/function`, `repo:test/distributed/cases/expression`, `repo:test/distributed/cases/time_window`
- **Interactions:** required `sql.data-types-and-conversion`; common `session.timezone-and-sql-mode`, `query.optimizer-and-plan`
- **Coverage gaps:** 目录不复制所有函数；设计前读取目标函数正式文档

## sql.mysql-compatibility

- **Status:** supported-with-conditions
- **User entry:** MySQL SQL 方言、错误/metadata、MySQL client 和兼容 Driver
- **Support evidence:** [MySQL Compatibility Matrix](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)
- **Scope:** 兼容矩阵标记 Compatible/Partial 的公开合同及 MatrixOne-only 扩展
- **Limitations:** Partial 不是完整兼容；MO-only 不能用 MySQL 结果作为唯一 oracle
- **State and invariants:** 兼容范围内语义、类型、metadata、error code/SQLSTATE 和事务行为稳定
- **Test routing:** BVT + 真实客户端/Driver compatibility；协议差异用 scenario
- **Repository evidence:** `repo:docs/cn/mysql-compatibility-exceptions.md`, `repo:test/distributed/cases/metadata`
- **Interactions:** required `session.mysql-protocol`; common 所有 SQL 能力
- **Coverage gaps:** 测试设计必须引用具体兼容矩阵条目
