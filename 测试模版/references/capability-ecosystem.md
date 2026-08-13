# 客户端与生态兼容

## ecosystem.mysql-clients-and-drivers

- **支持状态:** supported-with-conditions
- **用户入口:** 官方文档列出的 MySQL client、JDBC/Go/Python 等 Driver 和连接串
- **支持证据:** MatrixOne 客户端连接文档、[MySQL 兼容性矩阵](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)
- **支持范围:** 正式列出的客户端/Driver 版本与 SQL/protocol/metadata 合同
- **限制条件:** 未列工具、ORM 或版本不推断支持；ODBC/JDBC 必须在真实环境验证
- **状态与不变量:** connect/auth/query/prepare/transaction/metadata/error/affected rows 与正式合同一致
- **测试分层:** 真实客户端 compatibility suite、MOTR scenario、SQL/BVT control
- **仓库证据:** `repo:README.md`, `repo:pkg/frontend`, `repo:test/distributed/cases/metadata`
- **关联能力:** 必需 `session.mysql-protocol`, `sql.mysql-compatibility`; 高风险 binary prepare、timezone、large result、Proxy
- **覆盖缺口:** mysql CLI 通过不能代表所有 Driver

## ecosystem.management-tools

- **支持状态:** supported-with-conditions
- **用户入口:** 官方发布并文档化的 mo_br、mo_cdc、备份/恢复/运维工具
- **支持证据:** MatrixOne 官方运维工具文档和发布说明
- **支持范围:** 每个工具正式文档的命令、版本、产品形态和工作流
- **限制条件:** enterprise/cloud 获取方式、版本配套、权限和外部依赖必须写明
- **状态与不变量:** 命令结果、目标状态、重试/恢复、日志脱敏和资源清理符合工具合同
- **测试分层:** 工具 integration、dedicated workflow、stability/chaos/big-data 按用途
- **仓库证据:** `repo:docs/ai-skills/backup-restore.md`, `repo:docs/ai-skills/cdc.md`
- **关联能力:** 必需 对应 `cdc.change-data-capture` 或 recovery 能力；高风险 version mismatch、credential、external storage
- **覆盖缺口:** 仅 SQL 层验证不能替代工具二进制和部署流程
