# 客户端与生态兼容

## ecosystem.mysql-clients-and-drivers

- **Status:** supported-with-conditions
- **User entry:** 官方文档列出的 MySQL client、JDBC/Go/Python 等 Driver 和连接串
- **Support evidence:** MatrixOne client connection documentation, [MySQL Compatibility Matrix](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)
- **Scope:** 正式列出的客户端/Driver 版本与 SQL/protocol/metadata 合同
- **Limitations:** 未列工具、ORM 或版本不推断支持；ODBC/JDBC 必须在真实环境验证
- **State and invariants:** connect/auth/query/prepare/transaction/metadata/error/affected rows 与正式合同一致
- **Test routing:** 真实客户端 compatibility suite、MOTR scenario、SQL/BVT control
- **Repository evidence:** `repo:README.md`, `repo:pkg/frontend`, `repo:test/distributed/cases/metadata`
- **Interactions:** required `session.mysql-protocol`, `sql.mysql-compatibility`; high-risk binary prepare、timezone、large result、Proxy
- **Coverage gaps:** mysql CLI 通过不能代表所有 Driver

## ecosystem.management-tools

- **Status:** supported-with-conditions
- **User entry:** 官方发布并文档化的 mo_br、mo_cdc、备份/恢复/运维工具
- **Support evidence:** MatrixOne official Maintain/Tools documentation and release notes
- **Scope:** 每个工具正式文档的命令、版本、产品形态和工作流
- **Limitations:** enterprise/cloud 获取方式、版本配套、权限和外部依赖必须写明
- **State and invariants:** 命令结果、目标状态、重试/恢复、日志脱敏和资源清理符合工具合同
- **Test routing:** 工具 integration、dedicated workflow、stability/chaos/big-data 按用途
- **Repository evidence:** `repo:docs/ai-skills/backup-restore.md`, `repo:docs/ai-skills/cdc.md`
- **Interactions:** required 对应 `cdc.change-data-capture` 或 recovery 能力；high-risk version mismatch、credential、external storage
- **Coverage gaps:** 仅 SQL 层验证不能替代工具二进制和部署流程
