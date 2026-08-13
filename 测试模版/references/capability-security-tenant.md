# 多租户、安全与权限

## security.accounts-users-roles

- **支持状态:** supported
- **用户入口:** CREATE/DROP/ALTER ACCOUNT、USER、ROLE，登录认证和密码管理
- **支持证据:** MatrixOne 访问控制官方文档、[基础 SQL](https://docs.matrixorigin.cn/en/v26.3.0.8/MatrixOne/Get-Started/basic-sql/)
- **支持范围:** 正式用户、角色、账户生命周期和认证策略
- **限制条件:** sys/account admin 边界、密码策略和云/企业差异按部署文档
- **状态与不变量:** 账户间数据/Catalog 隔离；生命周期和认证状态正确；日志不泄露凭据
- **测试分层:** tenant/security/access-control BVT；真实连接/多租户 MOTR；审计/规模用专用环境
- **仓库证据:** `repo:test/distributed/cases/tenant`, `repo:test/distributed/cases/security`, `repo:test/distributed/cases/zz_accesscontrol`
- **关联能力:** 必需 `session.mysql-protocol`; 高风险 recovery、CDC、stage、publication、system catalog
- **覆盖缺口:** 测试凭据必须使用隔离的非生产账户并脱敏

## security.authorization-and-isolation

- **支持状态:** supported
- **用户入口:** GRANT/REVOKE、对象权限、角色继承、publication/subscription 权限
- **支持证据:** MatrixOne 访问控制和权限 SQL 参考文档
- **支持范围:** 正式对象级/系统级权限、角色授权和 metadata visibility
- **限制条件:** 权限粒度和 MySQL 差异按兼容矩阵；不假设未文档化隐式权限
- **状态与不变量:** 最小权限、授权即时生效/撤销、越权拒绝；失败无数据/Catalog 修改；跨租户不可见
- **测试分层:** security/tenant/zz_accesscontrol BVT；多连接/跨租户 MOTR
- **仓库证据:** `repo:test/distributed/cases/zz_accesscontrol`, `repo:test/distributed/cases/publication_subscription`
- **关联能力:** 必需 所有对象能力；高风险 restore/clone/CDC/stage/system table
- **覆盖缺口:** 每个 Feature 必须列 owner/admin/ordinary user 和 cross-tenant 适用性
