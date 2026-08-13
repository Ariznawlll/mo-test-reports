# SQL 语言、类型与兼容性

## sql.schema-and-data-statements

- **支持状态:** supported
- **用户入口:** CREATE/DROP/TRUNCATE/RENAME、SELECT、INSERT、UPDATE、DELETE、REPLACE、INSERT…SELECT/ODKU
- **支持证据:** [Feature List](https://docs.matrixorigin.cn/en/v25.3.0.2/MatrixOne/Overview/matrixone-feature-list/), [SQL categories](https://docs.matrixorigin.cn/en/m1intelligence/MatrixOne-Intelligence/Reference/SQL-Reference/SQL-Type/)
- **支持范围:** 正式文档列出的 DDL、DML、DQL 和 TCL；具体 ALTER/对象能力由 schema 域限定
- **限制条件:** 以兼容矩阵为准；不得从 Parser 接受推断完整 MySQL 语义
- **状态与不变量:** 精确结果、类型和 affected rows；拒绝语句不产生部分数据或 Catalog 修改
- **测试分层:** SQL BVT；跨功能语义进入 MOTR；内部表达式/编码进入 UT
- **仓库证据:** `repo:test/distributed/cases/ddl`, `repo:test/distributed/cases/dml`, `repo:test/distributed/cases/operator`
- **关联能力:** 必需 `schema.ddl-lifecycle`, `query.relational-query`; 常见 `transaction.explicit-transaction`, `session.prepared-statement`
- **覆盖缺口:** 按具体语句读取兼容矩阵，不能用本总条目替代语法级支持确认

## sql.relational-query

- **支持状态:** supported
- **用户入口:** SELECT、JOIN、GROUP BY、ORDER BY、UNION/INTERSECT/EXCEPT、subquery、CTE/recursive CTE、window
- **支持证据:** [Feature List](https://docs.matrixorigin.cn/en/v25.3.0.2/MatrixOne/Overview/matrixone-feature-list/), [SQL categories](https://docs.matrixorigin.cn/en/m1intelligence/MatrixOne-Intelligence/Reference/SQL-Reference/SQL-Type/)
- **支持范围:** 正式列出的关系查询组合、聚合、集合运算、相关/非相关子查询、CTE 和窗口
- **限制条件:** 方言、NULL、排序和不支持形状以当前兼容矩阵/专项文档为准
- **状态与不变量:** 完整 multiset、NULL 三值逻辑、确定排序、聚合/窗口边界和不同等价查询结果一致
- **测试分层:** BVT；复杂跨算子回归进入 MOTR；大规模计划只在规模触发时进入 big-data
- **仓库证据:** `repo:test/distributed/cases/join`, `repo:test/distributed/cases/subquery`, `repo:test/distributed/cases/cte`, `repo:test/distributed/cases/window`, `repo:test/distributed/cases/union`
- **关联能力:** 必需 `query.optimizer-and-plan`, `sql.data-types-and-conversion`; 高风险 `schema.indexes`, `query.memory-and-spill`
- **覆盖缺口:** 使用 Feature 的实际查询形状选择算子组合，不做全 SQL 笛卡尔积

## sql.data-types-and-conversion

- **支持状态:** supported-with-conditions
- **用户入口:** 表列类型、CAST/CONVERT、隐式赋值/比较转换、函数参数与结果类型
- **支持证据:** [Feature List 数据类型](https://docs.matrixorigin.cn/en/v25.3.0.2/MatrixOne/Overview/matrixone-feature-list/)、[兼容性矩阵](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)
- **支持范围:** 文档标为 Y/正式支持的数值、字符串、二进制、日期时间、JSON、数组和向量类型及公开转换
- **限制条件:** BIT、charset/collation、ENUM 排序过滤和宽松 MySQL cast 等差异必须按兼容矩阵逐项确认
- **状态与不变量:** 值、类型、精度、scale、符号、timezone 和 NULL 正确；失败 cast 不部分写入
- **测试分层:** dtype/expression/function BVT；转换内核 UT；协议 metadata 用 scenario
- **仓库证据:** `repo:test/distributed/cases/dtype`, `repo:test/distributed/cases/pg_cast`, `repo:test/distributed/cases/expression`
- **关联能力:** 必需 `session.timezone-and-sql-mode`; 常见 `session.prepared-statement`, `dataio.load-and-export`
- **覆盖缺口:** 每个 Feature 只选择实际可达类型族和合法边界

## sql.functions-time-window-and-expressions

- **支持状态:** supported-with-conditions
- **用户入口:** 内置函数、操作符、CASE、时间函数、Time Window/Sliding/Gapfill 文档化语法
- **支持证据:** [Feature List 函数与时序](https://docs.matrixorigin.cn/en/v25.3.0.2/MatrixOne/Overview/matrixone-feature-list/)
- **支持范围:** 官方 SQL Reference 中列出的函数/操作符和标为 Y 的 timing 能力
- **限制条件:** 函数级限制、精度、NULL 和 MySQL 差异以各函数页面为准；未列函数不从代码推断支持
- **状态与不变量:** 确定输入产生精确值/类型；NULL 与边界符合合同；非法参数走普通错误路径且无 panic
- **测试分层:** function/expression/time_window BVT；函数内核 UT；跨功能 MOTR
- **仓库证据:** `repo:test/distributed/cases/function`, `repo:test/distributed/cases/expression`, `repo:test/distributed/cases/time_window`
- **关联能力:** 必需 `sql.data-types-and-conversion`; 常见 `session.timezone-and-sql-mode`, `query.optimizer-and-plan`
- **覆盖缺口:** 目录不复制所有函数；设计前读取目标函数正式文档

## sql.mysql-compatibility

- **支持状态:** supported-with-conditions
- **用户入口:** MySQL SQL 方言、错误/metadata、MySQL client 和兼容 Driver
- **支持证据:** [MySQL 兼容性矩阵](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)
- **支持范围:** 兼容矩阵标记 Compatible/Partial 的公开合同及 MatrixOne-only 扩展
- **限制条件:** Partial 不是完整兼容；MO-only 不能用 MySQL 结果作为唯一 oracle
- **状态与不变量:** 兼容范围内语义、类型、metadata、error code/SQLSTATE 和事务行为稳定
- **测试分层:** BVT + 真实客户端/Driver compatibility；协议差异用 scenario
- **仓库证据:** `repo:docs/cn/mysql-compatibility-exceptions.md`, `repo:test/distributed/cases/metadata`
- **关联能力:** 必需 `session.mysql-protocol`; 常见 所有 SQL 能力
- **覆盖缺口:** 测试设计必须引用具体兼容矩阵条目
