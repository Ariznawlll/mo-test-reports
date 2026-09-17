# Issue #27983 GROUP BY 函数依赖例外测试设计

- Feature Issue：[matrixorigin/matrixone#27983](https://github.com/matrixorigin/matrixone/issues/27983)
- 实现 PR：[matrixorigin/matrixone#28848](https://github.com/matrixorigin/matrixone/pull/28848)、[matrixorigin/matrixone#28873](https://github.com/matrixorigin/matrixone/pull/28873)
- 设计状态：验收与持续回归设计

## Feature 背景与范围

MatrixOne 在 `ONLY_FULL_GROUP_BY` 生效时，需要支持 SQL:1999 可选特性 T301 及 MySQL 8.0 的函数依赖例外：如果分组列能够唯一确定某个非聚合列，则该列可以出现在 `SELECT`、`HAVING` 或 `ORDER BY` 中，而不必机械地重复写入 `GROUP BY`。

原问题是三表查询按 `job.job_id`（主键）分组时选择 `job.source` 被拒绝。当前 `main` 已通过 #28848 和 #28873 扩展为以下窄合同：

1. 基表完整主键或完整 `NOT NULL UNIQUE` 键决定同一关系实例的其他列。
2. nullable UNIQUE 只有在每个 nullable 键列都被当前查询块中的显式 `IS NOT NULL` 合取条件约束后才可作为证明。
3. 直接投影可以把完整键和直接列依赖传播到派生表、非递归 CTE 和可合并 VIEW；每个关系实例独立。
4. `INNER JOIN`/WHERE 等值可双向传播依赖；`LEFT`/`RIGHT JOIN` 只能在满足 null-extension 安全条件时从保留侧向 nullable 侧传播。
5. 不支持的或不完整的证明必须 fail closed，保持既有“列必须出现在 GROUP BY 或聚合函数中”的错误。
6. `MATRIXONE_NATIVE` 保持严格行为，不启用 MySQL 函数依赖例外。

本设计适用于 MatrixOne 单机和分布式产品形态的公开 SQL/MySQL 协议入口。验收重点是语义接受/拒绝、精确结果和元数据失效，不把 planner 私有证明结构当作用户合同。

## 支持证据与版本基线

- 官方 main：`370c310a994de258ee01e87c31062590a7022f34`
- 核验日期：`2026-09-17`
- 正式支持证据：
  - [MatrixOne SQL Mode](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/Variable/system-variables/sql-mode/)：公开 `ONLY_FULL_GROUP_BY` 入口及 session/global 生效规则。
  - [MatrixOne MySQL Compatibility Matrix](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)：`SELECT` 为 Partial，JOIN、Derived Table、CTE 等按矩阵约束使用。
  - [MySQL 8.0 GROUP BY handling](https://dev.mysql.com/doc/refman/8.0/en/group-by-handling.html)：T301、主键/非空唯一键、WHERE 单值和拒绝行为的参考合同。
  - [MySQL 8.0 functional-dependence detection](https://dev.mysql.com/doc/refman/8.0/en/group-by-functional-dependence.html)：键、等值条件和外连接函数依赖的参考语义。
  - [#27983 研发范围与复现记录](https://github.com/matrixorigin/matrixone/issues/27983#issuecomment-5564434153)。
- 实现/测试证据：
  - `docs/design/group-by-dependency-proof.md`
  - `pkg/sql/plan/mysql_full_group_by.go`
  - `pkg/sql/plan/mysql_full_group_by_dependency.go`
  - `pkg/sql/plan/mysql_full_group_by_unique_test.go`
  - `pkg/sql/plan/mysql_full_group_by_dependency_test.go`
  - `pkg/tests/dml/group_by_unique_prepared_test.go`
  - `pkg/tests/dml/group_by_dependency_prepared_test.go`
  - `test/distributed/cases/dml/select/mysql_compat_only_full_group_by.sql`
- 新鲜度审计：能力目录基线为 `bdbd613fdece966769eb68481a3e58bfbc36b30c`，#28848/#28873 合入后以 `8e8e1998ef02b1f6233ddb1c2d3208f3b70d2d83` 完成首轮验证。本轮更新到 `370c310a994de258ee01e87c31062590a7022f34`，两个 SHA 之间上述 GROUP BY 实现和已有测试路径无变化，因此仍以合入 PR 的窄合同为准。公开 SQL Mode 文档仍描述“非聚合列必须显式出现在 GROUP BY”的旧规则，需在发布前同步文档，不能据此扩大到 MySQL 的全部函数依赖推导。

## 验收目标与非目标

### 验收目标

1. 原 issue 三表 SQL 在 `ONLY_FULL_GROUP_BY` 下成功，结果与显式补齐 `GROUP BY` 列的控制查询完全一致。
2. 完整主键、完整非空唯一键、满足显式非空条件的 nullable UNIQUE 能够建立正确依赖；不完整键不得建立依赖。
3. SELECT 表达式、HAVING、ORDER BY、派生表、CTE、VIEW 和支持的 JOIN 形状遵循相同函数依赖合同。
4. 外连接 unmatched/NULL-extended 行结果正确，禁止反向或不安全残余条件推导。
5. SQL PREPARE 和真实 COM_STMT_PREPARE 在 UNIQUE/VIEW DDL 前后重新验证，不使用陈旧 proof/plan。
6. `ONLY_FULL_GROUP_BY`、空 sql_mode、`MATRIXONE_NATIVE` 在不同 session 中相互隔离。
7. 所有成功用例使用精确结果或显式完整分组查询作为独立 Oracle；所有拒绝用例验证稳定错误原因及错误后的连接可复用性。

### 非目标

1. 不把函数依赖 proof 输出为 optimizer 唯一性属性，不以消除 AGG、缩减物理分组键或改写 DISTINCT/JOIN 作为验收目标。
2. generated key、prefix key、函数索引、递归 CTE、聚合/窗口/集合运算/LIMIT 边界后的新依赖传播不在当前实现合同内；必须保持拒绝而不是猜测。
3. 不承诺与 MySQL 完全相同的错误码/SQLSTATE；当前只要求 MatrixOne 稳定领域 cause，错误映射另行产品确认。
4. 不使用分区、存储过程或 UDF 扩展矩阵。

## 涉及的 MatrixOne 能力

主能力映射：capability_id: `sql.relational-query`。

| capability_id | 关系 | 选择理由与限制 |
|---|---|---|
| `sql.relational-query` | 主能力 | GROUP BY、聚合、JOIN、派生表、CTE、VIEW 的用户可观察语义。 |
| `sql.mysql-compatibility` | 必需 | Feature 明确对齐 MySQL `ONLY_FULL_GROUP_BY` 的 T301/函数依赖例外；只对齐已声明窄范围。 |
| `query.optimizer-and-plan` | 必需 | Binder/planner 决定接受或拒绝；执行计划变化不得改变精确结果。 |
| `schema.constraints` | 必需 | PRIMARY/UNIQUE/NOT NULL 是函数依赖证明来源；完整性与 nullable 边界必须覆盖。 |
| `schema.indexes` | 高风险 | UNIQUE 的 DROP/ADD、可见性和元数据失效直接影响 prepared 查询合法性。 |
| `schema.ddl-lifecycle` | 常见 | VIEW replacement 和 UNIQUE 生命周期必须触发 proof 重算。 |
| `session.mysql-protocol` | 必需 | 原问题来自 MySQL 兼容入口；SQL 和 wire 行为必须一致。 |
| `session.prepared-statement` | 高风险 | prepared handle 不能跨 DDL/VIEW 变更保留陈旧函数依赖。 |
| `query.plan-cache-and-cancellation` | 高风险 | 重点覆盖 schema/session 变化后的失效；取消不是该 Feature 的特有路径。 |
| `sql.data-types-and-conversion` | 条件适用 | 键和 JOIN 等值必须处于同一 SQL equality identity domain；有损 cast 不得作为证明。 |
| `ecosystem.mysql-clients-and-drivers` | 条件适用 | 使用真实 MySQL binary protocol 验证 COM_STMT_PREPARE；不外推所有 ORM。 |

## 架构、入口、数据流与状态对象

公开入口是文本协议 SQL、SQL `PREPARE/EXECUTE` 和 MySQL binary prepared statement。数据流为：

```text
SQL / COM_STMT_PREPARE
  → parser / binder
  → 读取当前 query block、sql_mode 与 Catalog key metadata
  → 建立直接 GROUP BY seed、WHERE 单值/IS NOT NULL facts
  → 沿直接投影和安全等值关系计算有界依赖闭包
  → 每个非聚合列逐一 accept 或 fail closed
  → 保留正常 AGG/JOIN 计划并执行
  → 返回精确结果或稳定语义错误
```

关键状态对象：

- 表及 PRIMARY/UNIQUE/NOT NULL Catalog 元数据；
- VIEW definition、派生关系和 CTE 每次引用的 binding identity；
- query block 内不可变 dependency facts 与当前 grouping-set closure；
- session `sql_mode`；
- prepared handle、plan/schema cache 与 DDL invalidation generation；
- 用户表数据及显式完整分组控制查询结果。

proof 不应写入 Catalog、存储层或跨 session 共享，也不应在 query block、CTE 实例或 prepared generation 之间泄漏。

## 风险与关键不变量

| 风险 | 关键不变量 |
|---|---|
| 错误接受非确定列，返回任意值 | 只有完整且安全的 determinant closure 才能接受；结果必须等于显式完整分组 Oracle。 |
| 错误拒绝合法 MySQL 查询 | 当前合同内的 PK、eligible UNIQUE、透明投影和安全 JOIN 依赖必须接受。 |
| nullable UNIQUE 被误当作唯一 | 每个 nullable component 必须在相同 query block 的 AND-conjunct `IS NOT NULL` 下被证明；OR/HAVING/outer ON 不得替代。 |
| 外连接方向或 NULL-extension 推导错误 | preserved → nullable 仅在完整 ON 输入已确定时成立；反向传播、FULL OUTER 和不稳定谓词必须拒绝。 |
| CTE/VIEW 不同实例串用 proof | dependency identity 使用 binding tag + ordinal；重复引用必须相互独立。 |
| DDL 后 prepared 使用陈旧 proof | DROP/ADD UNIQUE、CREATE OR REPLACE VIEW 后下一次 execute 必须基于当前 metadata 重新接受或拒绝。 |
| sql_mode 跨连接污染 | 每个 session 按自身 mode 判定；关闭/启用不能影响其他连接或 prepared handle。 |
| proof 复杂度随数据量增长 | 规划开销只与列、键和谓词数量有界相关，不随表行数增长；无 panic、hang 或 goroutine/memory 持续增长。 |

## 测试环境、拓扑、配置与数据

### 环境

- MatrixOne：官方 `main`，完整 SHA 必须与执行记录一致。
- MOTR：单 CN 标准 MySQL 端口，至少两个独立物理连接；binary prepare 使用 Go `database/sql` + `go-sql-driver/mysql`，`ONLY_FULL_GROUP_BY` 由用例显式设置并恢复。
- 兼容性 Oracle：MySQL 8.0.45，记录 `SELECT VERSION()` 与 `@@session.sql_mode`；仅比较双方共同支持的语法。
- 重复：MOTR 场景至少执行 3 轮，每轮包含 10 个 fresh database；planner benchmark 5 轮并报告 `ns/op`、`allocs/op`。
- 每轮使用唯一 database 名，清理失败直接判失败，不使用共享表或固定 sleep。

### 数据模型

1. 原问题表：
   - `job(job_id BIGINT PRIMARY KEY, source VARCHAR(255), owner_id BIGINT)`
   - `cv(cv_id BIGINT PRIMARY KEY, job_id BIGINT)`
   - `app_user(user_id BIGINT PRIMARY KEY, full_name VARCHAR(255))`
   - 数据至少覆盖一个 job 多个 cv、零 cv、两个 job 同 owner、无 owner 匹配。
2. 候选键表：单列 `NOT NULL UNIQUE`、复合 `NOT NULL UNIQUE`、包含一个/多个 nullable component 的 UNIQUE，并加入重复 NULL 行。
3. JOIN 表：parent/child 包含匹配、未匹配、NULL FK、重复 fanout、残余 flag 真/假。
4. 类型控制：`BIGINT`、有效 DECIMAL、DATE/DATETIME、BINARY/VARBINARY；FLOAT/DOUBLE、CHAR、collated VARCHAR 和跨类型 cast 作为拒绝或产品确认边界。

所有结果查询使用确定性 `ORDER BY`。NULL、字符串和值按列逐项比较，不能只比较行数或“查询成功”。

## 功能测试矩阵

| 用例 ID | 验收目标 / capability_id / 不变量 | 前置状态与输入/操作 | 预期结果与独立 Oracle | 状态/清理断言 | 环境 / 测试层 |
|---|---|---|---|---|---|
| FD-HP-001 | 原 issue；`sql.relational-query`；PK 决定同表列 | 创建原三表数据，执行 issue 原 SQL | 成功；结果逐行等于把 `job.source` 加入 GROUP BY 的控制查询 | 原表行数不变；drop database 成功 | 1-CN / MOTR，3 轮 |
| FD-HP-002 | SELECT/HAVING/ORDER；`sql.mysql-compatibility` | 按 PK 分组，在表达式、HAVING、ORDER BY 引用 payload | 成功且表达式值、过滤、顺序与完整分组 Oracle 一致 | session mode 恢复 | MOTR |
| FD-HP-003 | 非空单列 UNIQUE；`schema.constraints` | `UNIQUE(k)` 且 `k NOT NULL`，按 k 分组选择 payload | 每组唯一 payload 和精确 SUM/COUNT | 不改变索引或数据 | MOTR + planner UT |
| FD-HP-004 | 非空复合 UNIQUE；`schema.constraints` | `UNIQUE(a,b)`，以 `GROUP BY b,a` 分组 | 成功；键顺序不影响完整性；与显式 payload 分组相同 | cleanup | MOTR + UT |
| FD-HP-005 | nullable UNIQUE；`schema.constraints` | 所有 nullable components 均在 WHERE 中 `IS NOT NULL`，完整键分组 | 仅非 NULL 行进入；payload 唯一且结果精确 | NULL 行仍存在且未被修改 | MOTR + UT |
| FD-HP-006 | WHERE 单值；`sql.mysql-compatibility` | 非分组列由 `col = literal/parameter` 的 AND 条件限制 | 成功；值等于 literal/parameter，聚合精确 | prepared 可重复执行 | MOTR + binary prepare |
| FD-HP-007 | 派生表；`query.optimizer-and-plan` | 直接列投影、重命名、嵌套两层后按导出键分组 | 成功；投影前后结果一致 | 不缓存跨 query proof | MOTR + UT |
| FD-HP-008 | CTE/VIEW；`schema.ddl-lifecycle` | 非递归 CTE、VIEW 直接投影完整键 | 成功；与基表查询一致 | DROP VIEW 后无残留 | MOTR |
| FD-HP-009 | INNER JOIN；`sql.relational-query` | ON、逗号 JOIN + WHERE、USING 三种等值入口 | 分组侧键可决定唯一侧 payload；三种结果相同 | fanout COUNT/SUM 精确 | MOTR + UT |
| FD-HP-010 | LEFT/RIGHT JOIN；外连接方向不变量 | 加入 matched、unmatched、NULL FK，按 preserved-side determinant 分组 | unmatched 行 payload 为 NULL；LEFT/RIGHT 归一化结果一致 | 不丢行、不重复行 | MOTR + UT |
| FD-HP-011 | JOIN chain；闭包传递性 | child → parent → parent_alias 的安全等值链 | 允许末端 payload；结果等于完整分组 Oracle | 每个 binding 独立 | MOTR + UT |
| FD-HP-012 | `session.prepared-statement` | SQL PREPARE 与 COM_STMT_PREPARE 重复执行不同参数 | 每次使用当前参数，结果 metadata/value 正确 | deallocate/close handle 后无残留 | MOTR scenario |
| FD-HP-013 | 恢复后的正常控制 | 先触发一个非法 GROUP BY，再在同一连接执行合法 FD 查询 | 非法语句返回后连接仍同步，合法查询成功 | 无 stuck transaction/session | MOTR |
| FD-BD-001 | 空/单行/多行边界 | 空表、单行、重复 fanout 分别按完整键分组 | 空集、单行和精确 fanout 结果 | 无意外 NULL/重复 | MOTR |
| FD-BD-002 | 完整复合键边界 | GROUP BY 包含完整键加额外列、键列顺序交换 | 仍可选择 payload；结果与完整分组一致 | cleanup | MOTR |
| FD-BD-003 | equality domain；`sql.data-types-and-conversion` | 合法数值、DECIMAL、日期时间、binary 键；同类型等值 JOIN | 支持类型接受且结果精确 | 记录实际类型 metadata | Planner UT + MOTR |
| FD-UN-001 | 不完整复合键 fail closed | `UNIQUE(a,b)` 只 GROUP BY a | 稳定拒绝，cause 含 `must appear in the GROUP BY` | 随后合法查询成功 | MOTR + UT |
| FD-UN-002 | nullable key fail closed | nullable UNIQUE 无过滤、仅部分 component 过滤 | 稳定拒绝；不得从实际数据“碰巧唯一”推导 | 数据不变 | MOTR + UT |
| FD-UN-003 | predicate scope | `IS NOT NULL` 位于 OR、HAVING、nullable-side outer ON | 稳定拒绝；这些位置不能成为当前块非空证明 | 同连接恢复 | UT + MOTR |
| FD-UN-004 | transformed determinant | GROUP BY `k+1`、有损 CAST 或函数表达式 | 稳定拒绝；表达式不能冒充完整 storage key | 无 planner panic | UT + MOTR |
| FD-UN-005 | 跨 binding 隔离 | 按表 A 的键分组却选择无等值证明的表 B payload | 稳定拒绝，即使测试数据碰巧一一对应 | 显式分组控制成功 | MOTR |
| FD-UN-006 | outer join 反向传播 | 从 nullable side 向 preserved side 推导，或 ON 残余列未被 determinant 决定 | 稳定拒绝 | unmatched 数据保留 | UT + MOTR |
| FD-UN-007 | volatile/null-safe/lossy equality | `RAND()` 残余、`<=>`、跨类型/有损 CAST equality | 稳定拒绝，不能形成 identity proof | 无 hang/panic | UT |
| FD-UN-008 | 关系边界 | LIMIT、DISTINCT、UNION/INTERSECT、聚合、窗口、递归 CTE 后尝试传播键 | 当前合同均 fail closed；外层显式完整分组控制可执行 | 不泄漏子查询 proof | UT；支持语法补 MOTR |
| FD-UN-009 | grouping sets | ROLLUP/CUBE 某 branch 中键不 active | 稳定拒绝，不把其他 branch 的完整键复用 | 普通 GROUP BY 控制成功 | UT + MOTR |
| FD-UN-010 | 重复 CTE identity | 同一 CTE 两次 CROSS JOIN，按实例 A 键选择实例 B payload | 稳定拒绝；增加 A=B 等值后对应正向用例成功 | binding 不串线 | UT + MOTR |
| FD-LC-001 | UNIQUE lifecycle；`schema.indexes` | prepare 合法查询 → DROP UNIQUE → 插入重复 key/payload → execute | execute 立即拒绝；不得返回任意 payload | 删除冲突行并 ADD UNIQUE 后 execute 恢复 | Binary prepare，10 轮 |
| FD-LC-002 | VIEW lifecycle；`schema.ddl-lifecycle` | prepare VIEW 查询 → replace 为非 key-preserving 投影 → execute | 替换后拒绝；恢复 key-preserving VIEW 后成功 | 当前 view definition 生效 | Binary prepare，10 轮 |
| FD-LC-003 | 跨连接失效 | A prepare；B DROP/ADD UNIQUE 或 replace VIEW 并提交；A execute | A 下一次执行观察当前 metadata，不使用陈旧 proof | 两连接均可继续使用 | MOTR multi-client，10 轮 |
| FD-SE-001 | sql_mode session 隔离 | A=`ONLY_FULL_GROUP_BY`，B=`ONLY_FULL_GROUP_BY,MATRIXONE_NATIVE`，C 关闭该 mode | A 按窄合同接受；B 严格拒绝；C 仅在数据确定时用结果 Oracle，否则只断言语句可执行 | 三连接互不改变 mode | MOTR |
| FD-SE-002 | 最小权限 | 仅有相关表 SELECT 权限的用户执行合法/非法查询 | 与管理员得到相同语义判定；无权限用户先被权限系统拒绝 | 无额外 metadata/data 可见性 | MOTR |
| FD-PF-001 | 有界规划成本 | 10/50/100 列投影与 1/5/10 层等值链 benchmark | 无超线性失控、panic 或 timeout；报告 ns/op、allocs/op，不设脆弱绝对阈值 | benchmark 后内存回落 | Go benchmark，5 轮 |

## 正常路径（Happy Path）

执行 FD-HP-001～013。每个接受用例必须同时执行显式完整分组控制查询，并对比完整 ordered rows、NULL、列类型和聚合值。原 issue SQL 不能只用简化等价 SQL 替代。

主键、UNIQUE、projection 和 JOIN 证明只允许影响语义校验；`EXPLAIN` 中仍应存在正常 AGG/JOIN 关键节点。计划文本、node id 和 cost 不作为 golden。

## 边界路径（Boundary Path）

执行 FD-BD-001～003，并补充：

- composite key 列顺序交换和额外 GROUP BY 列；
- payload 为 NULL、空字符串、长字符串；
- zero-row、one-row、重复 join fanout；
- nullable UNIQUE 的一个、多个、全部 nullable component；
- 表 alias、列 alias、同名列、大小写引用；
- supported equality domain 的 min/max 和 DECIMAL scale。

所有合法边界使用精确值，不把 NULL 或空表误列为异常路径。

## 异常路径（Unhappy Path）

执行 FD-UN-001～010。拒绝断言包含：

1. statement 返回稳定 GROUP BY 领域 cause；
2. 不返回部分结果；
3. session/protocol 保持同步；
4. 紧接着执行 `SELECT 1` 和一个合法 FD 查询均成功；
5. 不通过改 expected、关闭 `ONLY_FULL_GROUP_BY` 或使用 `ANY_VALUE()` 掩盖失败。

## 事务与并发

GROUP BY 校验是只读 statement 语义，不新增持久状态。补充以下最小覆盖：

1. autocommit 与显式只读事务中的同一合法/非法查询判定一致；ROLLBACK 后连接可复用。
2. FD-LC-003 使用两个物理连接验证已提交 DDL 后 prepared 重算；执行顺序由 DDL 完成信号控制，不使用 sleep。
3. 不要求为该语义单独覆盖死锁、write/write 冲突或高并发 DML；这些不改变 determinant 合同。

## 安全与租户隔离

执行 FD-SE-002，确认 Feature 不绕过现有表级 SELECT 授权。函数依赖 proof 只读取当前账号可见的 Catalog metadata，不跨 account/tenant 共享。跨租户数据隔离、RBAC 管理生命周期不是本 Feature 的新增能力，不做全矩阵展开。

## 恢复与故障注入

该 Feature 不创建后台任务、外部对象或持久化 proof，无节点/网络/存储故障合同，因此不进入 Chaos/recovery。验证 SQL 错误后的同连接恢复、断开后新连接按当前 Catalog 与 sql_mode 重新规划即可。若补充重启用例，复用 MOTR 单 CN 环境，仅作为 metadata 持久性控制，不作为独立准入门槛。

## 性能、规模与稳定性

函数依赖在 planner 中由 schema、列和谓词数量触发，小数据即可进入完整代码路径；数据行数不参与 proof。因此：

- 不加入 big-data/Nightly，百万行不能证明比小型确定性 Oracle 更多的合同。
- 保留 FD-PF-001 planner benchmark，检查长投影/JOIN chain 的规划成本和 allocations。
- 普通功能用例 3 轮；prepared/DDL 多连接用例 10 轮 fresh database。
- 任一 panic、hang、超时、持续内存增长或连接污染均判失败。

## 兼容性

以 MySQL 8.0.45 的 `ONLY_FULL_GROUP_BY` 为参考 Oracle，覆盖 PK、`NOT NULL UNIQUE`、WHERE 单值、INNER/OUTER JOIN 和 derived relation。每个差异用例记录：SQL、schema、data、MySQL version/sql_mode、MO SHA/sql_mode、完整 ordered output 或 error。

MatrixOne 文档把 SELECT 标为 Partial，且当前 SQL Mode 页面仍保留旧的字面 GROUP BY 规则，因此验收采用更窄的合入设计合同。generated-column FD、prefix/function key、完整 MySQL error 1055/SQLSTATE 42000 兼容性在产品明确前不写成通过条件。

## 可观测性与资源清理

- `EXPLAIN` 只断言 AGG/JOIN 等关键语义节点仍存在，不锁定格式、cost 和内部 proof 文本。
- 测试日志记录 MO SHA、MySQL version、sql_mode、case ID、实际/期望结果和重复轮次。
- 日志不得包含密码、连接串 secret 或客户数据。
- 成功和失败均关闭 prepared handle/连接，DROP VIEW/TABLE/DATABASE；清理失败使 case 失败。
- 执行期间检查无 panic/fatal、CN restart、protocol desync；benchmark 报告 allocations。

## 回归分层与已有资产

### 已有资产

- Planner UT：
  - `pkg/sql/plan/mysql_full_group_by_unique_test.go`
  - `pkg/sql/plan/mysql_full_group_by_dependency_test.go`
- Binary prepared：
  - `pkg/tests/dml/group_by_unique_prepared_test.go`
  - `pkg/tests/dml/group_by_dependency_prepared_test.go`
- BVT：
  - `test/distributed/cases/dml/select/mysql_compat_only_full_group_by.sql`
  - `test/distributed/cases/dml/select/mysql_compat_only_full_group_by.result`
- Benchmark：`pkg/sql/plan/mysql_full_group_by_dependency_bench_test.go`

### 本次补充资产

1. [matrixorigin/motr#182](https://github.com/matrixorigin/motr/pull/182) 在 `script/14_issue_regression/` 增加 `issue_27983_group_by_fd_prepare.go/.sh` 及 golden，统一承载本次所有新增黑盒覆盖：原 issue 三表 SQL与显式分组 Oracle、fanout/zero-child/unmatched-owner/NULL-owner、NULL/空串/最长字符串、DECIMAL/DATE/DATETIME/VARBINARY 边界、四个独立物理连接、binary prepare、UNIQUE/VIEW DDL 失效恢复、sql_mode 隔离、显式事务、最小 SELECT 权限和拒绝后数据不变式。
2. [matrixorigin/matrixone#29041](https://github.com/matrixorigin/matrixone/pull/29041) 已关闭且未合入；按当前回归分层决定，本次不新增 BVT，相关黑盒覆盖已全部迁移到 MOTR #182。
3. Planner equality-domain、关系边界、grouping-mask 及 prepared lifecycle 的底层用例已由 #28848/#28873 随实现合入，本次不重复新建长时 UT。

### 本次执行结果

- 既有 distributed suite 的一次性本地兼容验证为 focused `105/105`、连续 3 轮及所在 `dml/select` suite `1257/1257`；该结果只作为验证证据，不新增 BVT 资产。
- MOTR 黑盒场景：连续 `3/3` 通过，共覆盖 30 个 fresh database，15.69s；包含新增数据/类型边界的精确结果校验。场景在修复前 MatrixOne `d57f99abc0` 上会在原查询处稳定失败。
- Planner focused UT：5 组用例 `-count=3` 通过；equality-domain UT `-count=3` 通过。
- Binary prepared DML UT：2 组用例 `-count=3` 通过；同两用例 `-race -count=1` 通过。
- Planner benchmark：ordinary、8/32 层 projection、4/16 表 join 各 5 轮完成，无 panic、timeout。
- 运行二进制为官方 main `370c310a994de258ee01e87c31062590a7022f34`；本地运行期间无竞态报告、CN restart 或 protocol desync。
- 日志中另有 standalone 环境周期性 `iscp transaction finish timeout`；它与本用例 SQL/plan 时序无关、未影响连接与结果，不归因为 #27983 失败。

### CI 门禁

1. Planner focused UT：3 轮。
2. `pkg/tests/dml` 两个 prepared case：3 轮。
3. MOTR scenario：至少 3 轮，每轮 10 个 fresh database，并运行 `14_issue_regression` 相关 shard。
4. PR 必须通过 SCA；suite 无关失败需单独列出，不得写成全量通过。

## 不适用项及原因

- big-data 不适用：proof 与行数无关，小型数据进入相同 planner 路径。
- Stability/Soak 不适用：无后台任务或长期状态；低概率资源风险由 benchmark allocations 和 prepared 10 轮覆盖。
- Chaos 不适用：不依赖节点、网络或外部服务故障。
- GPU 不适用：无 GPU 路径。
- Snapshot/PITR/backup/restore 不适用：proof 不持久化，不新增可恢复状态。
- CDC/branch 不适用：该 Feature 不写数据或改变复制/分支语义。
- Proxy migration 不作为准入：功能合同是 statement validation；真实 binary protocol 与跨连接 invalidation 已覆盖，Proxy 不改变 proof 来源。

## 准入、退出、风险与待确认项

### 准入条件

1. MatrixOne 运行二进制与记录的官方 main SHA 一致，目标 PR 已包含在该 SHA。
2. `SELECT VERSION()`、`@@session.sql_mode`、拓扑和客户端版本已记录。
3. 测试 database 可独占命名并可完整清理；MySQL 8.0 Oracle 可用时记录相同 fixture。
4. prepared multi-client 使用两个已验证独立 connection ID，不把连接池逻辑连接误当物理连接。

### 退出条件

1. 原 issue SQL 和全部 required Happy/Boundary/Unhappy case 达到预期；普通 case 3/3、prepared/DDL case 10/10。
2. 所有成功结果与独立 Oracle 完整一致；所有拒绝结果无部分 output 且连接可恢复。
3. focused UT、prepared test、MOTR scenario 和相关 CI 全部通过；本次不新增 BVT 门禁。
4. 无 panic、hang、OOM、CN restart、protocol desync、陈旧 plan/proof 或清理残留。
5. 每个原 issue/研发 comment 场景映射到 case ID 和可复核证据。

### 剩余风险与产品待确认项

1. MatrixOne SQL Mode 用户文档仍描述旧的严格规则；发布前应更新为当前窄合同及 `MATRIXONE_NATIVE` 边界。
2. VARCHAR/collation、CHAR、FLOAT signed zero 等 equality domain 与 MySQL 可存在差异；当前实现选择 fail closed，需要产品确认是否作为正式限制公开。
3. generated-column、prefix/function key 的函数依赖不在 #28848/#28873 范围内；不得在本 issue 中默认承诺。
4. MatrixOne 错误码/SQLSTATE 与 MySQL 1055/42000 是否需要一致，需由兼容性合同单独确认。
