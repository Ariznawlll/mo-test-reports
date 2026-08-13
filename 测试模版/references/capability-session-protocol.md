# 会话、协议、Driver 与 Proxy

## session.mysql-protocol

- **Status:** supported-with-conditions
- **User entry:** MySQL text protocol、认证、query/result/error/metadata、正式支持的 MySQL clients/Drivers
- **Support evidence:** MatrixOne client connection docs, [Compatibility Matrix](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)
- **Scope:** 正式连接、COM_QUERY、结果列 metadata、affected rows、warning/error 和连接生命周期
- **Limitations:** 仅兼容矩阵承诺范围；具体 JDBC/ODBC/ORM 见 ecosystem 条目
- **State and invariants:** SQL 与 wire 结果一致；字段 metadata 稳定；错误不破坏协议同步；凭据不泄露
- **Test routing:** frontend UT/BVT、真实 Driver/MOTR scenario、Proxy 拓扑 scenario
- **Repository evidence:** `repo:pkg/frontend`, `repo:test/distributed/cases/metadata`
- **Interactions:** required `security.accounts-users-roles`, `sql.mysql-compatibility`; high-risk large result、cancel、Proxy cache
- **Coverage gaps:** mysql CLI 通过不能替代 binary/JDBC/ODBC 合同

## session.prepared-statement

- **Status:** supported
- **User entry:** SQL PREPARE/EXECUTE/DEALLOCATE、COM_STMT_PREPARE/EXECUTE、Driver prepare
- **Support evidence:** [Feature List PREPARE](https://docs.matrixorigin.cn/en/v25.3.0.2/MatrixOne/Overview/matrixone-feature-list/), MySQL protocol compatibility docs
- **Scope:** 参数绑定、重复执行、错误恢复、statement 生命周期和正式 metadata
- **Limitations:** marker 位置、DDL、类型 coercion 和 migration 边界按当前文档
- **State and invariants:** 每次执行使用当前参数/类型/NULL；拒绝不污染 handle/plan/session；metadata 和 affected rows 正确
- **Test routing:** prepare BVT、真实 binary protocol MOTR scenario、planner/frontend UT
- **Repository evidence:** `repo:test/distributed/cases/prepare`, `repo:pkg/frontend`
- **Interactions:** required `sql.data-types-and-conversion`, `query.plan-cache-and-cancellation`; high-risk transaction、session variable、Proxy migration
- **Coverage gaps:** SQL PREPARE 不能替代真实 binary protocol

## session.timezone-and-sql-mode

- **Status:** supported-with-conditions
- **User entry:** SET time_zone、SQL mode、charset/collation 和 session/global variables
- **Support evidence:** MatrixOne system-variable and temporal/compatibility documentation
- **Scope:** 正式列出的变量作用域、读取/设置和对 SQL 语义的影响
- **Limitations:** 只覆盖文档化变量和值；部分 charset/collation 语义有限
- **State and invariants:** session 隔离；新连接继承规则正确；prepared/cache/Proxy 重用无陈旧状态
- **Test routing:** system_variable/set BVT、多连接/Proxy MOTR、frontend UT
- **Repository evidence:** `repo:test/distributed/cases/system_variable`, `repo:test/distributed/cases/set`
- **Interactions:** required `session.connection-lifecycle`; high-risk temporal conversion、plan cache、connection cache
- **Coverage gaps:** 本地 SYSTEM timezone 不得作为跨环境固定 baseline

## session.connection-lifecycle

- **Status:** supported-with-conditions
- **User entry:** connect/disconnect、Proxy routing、连接缓存、CN migration/drain（部署支持时）、query cancel
- **Support evidence:** MatrixOne Proxy/multi-CN official deployment docs
- **Scope:** 正式 Proxy 拓扑的路由、backend cleanup、session reset/preservation 和断连行为
- **Limitations:** 直连 CN 不能证明 Proxy；cache 配置和迁移条件必须记录
- **State and invariants:** 断连取消/回滚符合合同；无 orphan session/lock/backend；恢复连接可读写；session state 不串线
- **Test routing:** Proxy/multi-client MOTR、proxy/frontend UT + `-race`、CN failure chaos
- **Repository evidence:** `repo:pkg/proxy`, `repo:docs/ai-skills/multi-cn.md`
- **Interactions:** required `transaction.explicit-transaction`, `security.authorization-and-isolation`; high-risk prepared、variables、CN drain
- **Coverage gaps:** 需要实际 Proxy 端口和干净拓扑，不能用直连 CN 夹具替代
