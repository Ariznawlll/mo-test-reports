# 会话、协议、Driver 与 Proxy

## session.mysql-protocol

- **支持状态:** supported-with-conditions
- **用户入口:** MySQL 文本协议、认证、查询/结果/错误/metadata、正式支持的 MySQL 客户端和 Driver
- **支持证据:** MatrixOne 客户端连接文档、[兼容性矩阵](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)
- **支持范围:** 正式连接、COM_QUERY、结果列 metadata、affected rows、warning/error 和连接生命周期
- **限制条件:** 仅兼容矩阵承诺范围；具体 JDBC/ODBC/ORM 见 ecosystem 条目
- **状态与不变量:** SQL 与 wire 结果一致；字段 metadata 稳定；错误不破坏协议同步；凭据不泄露
- **测试分层:** frontend UT/BVT、真实 Driver/MOTR scenario、Proxy 拓扑 scenario
- **仓库证据:** `repo:pkg/frontend`, `repo:test/distributed/cases/metadata`
- **关联能力:** 必需 `security.accounts-users-roles`, `sql.mysql-compatibility`; 高风险 large result、cancel、Proxy cache
- **覆盖缺口:** mysql CLI 通过不能替代 binary/JDBC/ODBC 合同

## session.prepared-statement

- **支持状态:** supported
- **用户入口:** SQL PREPARE/EXECUTE/DEALLOCATE、COM_STMT_PREPARE/EXECUTE、Driver prepare
- **支持证据:** [Feature List PREPARE](https://docs.matrixorigin.cn/en/v25.3.0.2/MatrixOne/Overview/matrixone-feature-list/)、MySQL 协议兼容文档
- **支持范围:** 参数绑定、重复执行、错误恢复、statement 生命周期和正式 metadata
- **限制条件:** marker 位置、DDL、类型 coercion 和 migration 边界按当前文档
- **状态与不变量:** 每次执行使用当前参数/类型/NULL；拒绝不污染 handle/plan/session；metadata 和 affected rows 正确
- **测试分层:** Prepare BVT、真实二进制协议 MOTR 场景、Planner/Frontend UT
- **仓库证据:** `repo:test/distributed/cases/prepare`, `repo:pkg/frontend`
- **关联能力:** 必需 `sql.data-types-and-conversion`, `query.plan-cache-and-cancellation`; 高风险 transaction、session variable、Proxy migration
- **覆盖缺口:** SQL PREPARE 不能替代真实 binary protocol

## session.timezone-and-sql-mode

- **支持状态:** supported-with-conditions
- **用户入口:** SET time_zone、SQL mode、charset/collation 和 session/global variables
- **支持证据:** MatrixOne system-variable and temporal/compatibility documentation
- **支持范围:** 正式列出的变量作用域、读取/设置和对 SQL 语义的影响
- **限制条件:** 只覆盖文档化变量和值；部分 charset/collation 语义有限
- **状态与不变量:** session 隔离；新连接继承规则正确；prepared/cache/Proxy 重用无陈旧状态
- **测试分层:** system_variable/set BVT、多连接/Proxy MOTR、frontend UT
- **仓库证据:** `repo:test/distributed/cases/system_variable`, `repo:test/distributed/cases/set`
- **关联能力:** 必需 `session.connection-lifecycle`; 高风险 temporal conversion、plan cache、connection cache
- **覆盖缺口:** 本地 SYSTEM timezone 不得作为跨环境固定 baseline

## session.connection-lifecycle

- **支持状态:** supported-with-conditions
- **用户入口:** connect/disconnect、Proxy routing、连接缓存、CN migration/drain（部署支持时）、query cancel
- **支持证据:** MatrixOne Proxy/多 CN 官方部署文档
- **支持范围:** 正式 Proxy 拓扑的路由、backend cleanup、session reset/preservation 和断连行为
- **限制条件:** 直连 CN 不能证明 Proxy；cache 配置和迁移条件必须记录
- **状态与不变量:** 断连取消/回滚符合合同；无 orphan session/lock/backend；恢复连接可读写；session state 不串线
- **测试分层:** Proxy/multi-client MOTR、proxy/frontend UT + `-race`、CN failure chaos
- **仓库证据:** `repo:pkg/proxy`, `repo:docs/ai-skills/multi-cn.md`
- **关联能力:** 必需 `transaction.explicit-transaction`, `security.authorization-and-isolation`; 高风险 prepared、variables、CN drain
- **覆盖缺口:** 需要实际 Proxy 端口和干净拓扑，不能用直连 CN 夹具替代
