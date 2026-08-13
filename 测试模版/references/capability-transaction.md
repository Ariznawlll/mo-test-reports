# 事务、锁与并发

## transaction.explicit-transaction

- **Status:** supported
- **User entry:** BEGIN/START TRANSACTION、COMMIT、ROLLBACK、AUTOCOMMIT
- **Support evidence:** [Feature List transactions](https://docs.matrixorigin.cn/en/v25.3.0.2/MatrixOne/Overview/matrixone-feature-list/), SQL TCL Reference
- **Scope:** 显式/自动提交、支持的乐观/悲观模式、事务内 DML/查询和 rollback
- **Limitations:** 隔离级别和 DDL 事务边界按 MatrixOne 文档，不假设完整 MySQL/InnoDB 行为
- **State and invariants:** commit 原子可见；rollback 恢复数据/元数据；错误和断连不留下可提交脏状态
- **Test routing:** optimistic/pessimistic BVT、multi-session MOTR、txn/storage UT、restart/partition chaos
- **Repository evidence:** `repo:test/distributed/cases/optimistic`, `repo:test/distributed/cases/pessimistic_transaction`, `repo:docs/ai-skills/transaction.md`
- **Interactions:** required `session.connection-lifecycle`, `storage.data-durability`; high-risk locks、DDL、Proxy、restart
- **Coverage gaps:** 真实 commit-ack 不确定窗口需要 chaos，普通 SQL 不足

## transaction.locking-and-conflicts

- **Status:** supported-with-conditions
- **User entry:** 悲观事务、SELECT…FOR UPDATE/FOR SHARE（正式语法）、并发 DML
- **Support evidence:** MatrixOne transaction/locking documentation and formal BVT
- **Scope:** 支持的锁模式、等待、冲突、死锁检测、commit/rollback/disconnect 释放
- **Limitations:** LOCK TABLES 等兼容矩阵标 N 的入口不纳入；超时和隔离配置按环境
- **State and invariants:** shared/exclusive 兼容矩阵正确；writer 不越过持锁者；死锁有界处理；释放后无 orphan lock
- **Test routing:** pessimistic BVT、multi-client MOTR、lockservice/txn UT + `-race`、node failure chaos
- **Repository evidence:** `repo:pkg/lockservice`, `repo:test/distributed/cases/pessimistic_transaction`
- **Interactions:** required `transaction.explicit-transaction`; high-risk Proxy disconnect、multi-CN、DDL/DML concurrency
- **Coverage gaps:** 单连接只能证明语法，不能证明锁语义

## transaction.statement-atomicity

- **Status:** supported
- **User entry:** DML/DDL/LOAD/索引操作的成功或错误返回
- **Support evidence:** 正式事务语义和各语句错误合同
- **Scope:** 单 statement 失败时数据、Catalog、隐藏对象和 affected rows 的原子合同
- **Limitations:** INSERT IGNORE/宽松转换等按语句正式语义，不统一假设全 statement 回滚
- **State and invariants:** 拒绝后立即读取的全部参与状态与预期一致；恢复操作不得掩盖部分写入
- **Test routing:** BVT/MOTR 黑盒为主；内部 ownership/fault UT
- **Repository evidence:** `repo:test/distributed/cases/dml`, `repo:test/distributed/cases/ddl`, `repo:test/distributed/cases/load_data`
- **Interactions:** required 所有写入能力；high-risk constraint/index/online DDL/external object
- **Coverage gaps:** 测试设计必须为具体语句定义原子粒度
