# 多租户、安全与权限

## security.accounts-users-roles

- **Status:** supported
- **User entry:** CREATE/DROP/ALTER ACCOUNT、USER、ROLE，登录认证和密码管理
- **Support evidence:** MatrixOne Access Control official docs, [Basic SQL](https://docs.matrixorigin.cn/en/v26.3.0.8/MatrixOne/Get-Started/basic-sql/)
- **Scope:** 正式用户、角色、账户生命周期和认证策略
- **Limitations:** sys/account admin 边界、密码策略和云/企业差异按部署文档
- **State and invariants:** 账户间数据/Catalog 隔离；生命周期和认证状态正确；日志不泄露凭据
- **Test routing:** tenant/security/access-control BVT；真实连接/多租户 MOTR；审计/规模用专用环境
- **Repository evidence:** `repo:test/distributed/cases/tenant`, `repo:test/distributed/cases/security`, `repo:test/distributed/cases/zz_accesscontrol`
- **Interactions:** required `session.mysql-protocol`; high-risk recovery、CDC、stage、publication、system catalog
- **Coverage gaps:** 测试凭据必须使用隔离的非生产账户并脱敏

## security.authorization-and-isolation

- **Status:** supported
- **User entry:** GRANT/REVOKE、对象权限、角色继承、publication/subscription 权限
- **Support evidence:** MatrixOne Access Control and privilege SQL Reference
- **Scope:** 正式对象级/系统级权限、角色授权和 metadata visibility
- **Limitations:** 权限粒度和 MySQL 差异按兼容矩阵；不假设未文档化隐式权限
- **State and invariants:** 最小权限、授权即时生效/撤销、越权拒绝；失败无数据/Catalog 修改；跨租户不可见
- **Test routing:** security/tenant/zz_accesscontrol BVT；多连接/跨租户 MOTR
- **Repository evidence:** `repo:test/distributed/cases/zz_accesscontrol`, `repo:test/distributed/cases/publication_subscription`
- **Interactions:** required 所有对象能力；high-risk restore/clone/CDC/stage/system table
- **Coverage gaps:** 每个 Feature 必须列 owner/admin/ordinary user 和 cross-tenant 适用性
