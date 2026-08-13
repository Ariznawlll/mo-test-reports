# 事务、锁与并发

## transaction.explicit-transaction

- **支持状态:** supported
- **用户入口:** BEGIN/START TRANSACTION、COMMIT、ROLLBACK、AUTOCOMMIT
- **支持证据:** [Feature List 事务](https://docs.matrixorigin.cn/en/v25.3.0.2/MatrixOne/Overview/matrixone-feature-list/)、SQL TCL 参考文档
- **支持范围:** 显式/自动提交、支持的乐观/悲观模式、事务内 DML/查询和 rollback
- **限制条件:** 隔离级别和 DDL 事务边界按 MatrixOne 文档，不假设完整 MySQL/InnoDB 行为
- **状态与不变量:** commit 原子可见；rollback 恢复数据/元数据；错误和断连不留下可提交脏状态
- **测试分层:** optimistic/pessimistic BVT、multi-session MOTR、txn/storage UT、restart/partition chaos
- **仓库证据:** `repo:test/distributed/cases/optimistic`, `repo:test/distributed/cases/pessimistic_transaction`, `repo:docs/ai-skills/transaction.md`
- **关联能力:** 必需 `session.connection-lifecycle`, `storage.data-durability`; 高风险 locks、DDL、Proxy、restart
- **覆盖缺口:** 真实 commit-ack 不确定窗口需要 chaos，普通 SQL 不足

## transaction.locking-and-conflicts

- **支持状态:** supported-with-conditions
- **用户入口:** 悲观事务、SELECT…FOR UPDATE/FOR SHARE（正式语法）、并发 DML
- **支持证据:** MatrixOne transaction/locking documentation and formal BVT
- **支持范围:** 支持的锁模式、等待、冲突、死锁检测、commit/rollback/disconnect 释放
- **限制条件:** LOCK TABLES 等兼容矩阵标 N 的入口不纳入；超时和隔离配置按环境
- **状态与不变量:** shared/exclusive 兼容矩阵正确；writer 不越过持锁者；死锁有界处理；释放后无 orphan lock
- **测试分层:** 悲观事务 BVT、多客户端 MOTR、LockService/事务 UT + `-race`、节点故障 Chaos
- **仓库证据:** `repo:pkg/lockservice`, `repo:test/distributed/cases/pessimistic_transaction`
- **关联能力:** 必需 `transaction.explicit-transaction`; 高风险 Proxy disconnect、multi-CN、DDL/DML concurrency
- **覆盖缺口:** 单连接只能证明语法，不能证明锁语义

## transaction.statement-atomicity

- **支持状态:** supported
- **用户入口:** DML/DDL/LOAD/索引操作的成功或错误返回
- **支持证据:** 正式事务语义和各语句错误合同
- **支持范围:** 单 statement 失败时数据、Catalog、隐藏对象和 affected rows 的原子合同
- **限制条件:** INSERT IGNORE/宽松转换等按语句正式语义，不统一假设全 statement 回滚
- **状态与不变量:** 拒绝后立即读取的全部参与状态与预期一致；恢复操作不得掩盖部分写入
- **测试分层:** BVT/MOTR 黑盒为主；内部 ownership/fault UT
- **仓库证据:** `repo:test/distributed/cases/dml`, `repo:test/distributed/cases/ddl`, `repo:test/distributed/cases/load_data`
- **关联能力:** 必需 所有写入能力；高风险 constraint/index/online DDL/external object
- **覆盖缺口:** 测试设计必须为具体语句定义原子粒度
