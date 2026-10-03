# MatrixOne MySQL 兼容性契约

本文档登记 MatrixOne 与 MySQL 之间已经明确的兼容性边界，重点记录 **MO 当前明确不支持的行为**，以及少量已确认的结果差异。

这不是“所有还没测过的 MySQL 语法”的列表。只有形成了产品契约、研发明确结论，或有稳定代码/回归证据的行为，才能登记为“不支持”。单次测试失败、环境问题和仍待产品决策的行为不得直接写入该分类。

更新时间：2026-10-03

## 状态定义

| 状态 | 含义 |
| --- | --- |
| 契约限制 | 当前产品明确不支持，调用方不应依赖 MySQL 对应语义 |
| 窄范围支持 | 只有条目明确列出的条件支持，不能外推到相邻场景 |
| 行为差异 | 两边都能执行，但返回值、结果或错误语义不同 |
| 待产品决策 | 已发现差异，但尚未形成“不支持”的正式契约，不归入不支持清单 |

## 目录

- [函数与随机数](#函数与随机数)
- [聚合函数与结果元数据](#聚合函数与结果元数据)
- [索引与最终一致性](#索引与最终一致性)
- [向量索引数值边界](#向量索引数值边界)
- [客户端与协议兼容性](#客户端与协议兼容性)
- [全文索引谓词](#全文索引谓词)
- [DML / Upsert](#dml--upsert)
- [视图写入](#视图写入)
- [类型转换与非严格语义](#类型转换与非严格语义)
- [新增条目的证据要求](#新增条目的证据要求)

---

## 函数与随机数

### RAND-001：不支持 `RAND(seed)`，且不提供随机序列可复现性契约

**状态：契约限制**

最小 SQL：

```sql
SELECT RAND();
SELECT RAND(7);
```

**MySQL 对照：** MySQL 接受 `RAND(seed)`，seed 可用于初始化其伪随机数序列。

**MatrixOne 行为：**

- 无参 `RAND()` 保持可用，现有行为不变；
- `RAND(seed)` 当前被拒绝，返回 `ERROR 20203 (HY000): invalid argument function rand, bad value [BIGINT]`；
- 这表示 MySQL seeded-RAND 语法在 MO 中不受支持，而不是已支持能力的数据正确性回归。

**契约边界：**

- MatrixOne 不承诺生成与 MySQL 相同的随机数序列；
- MatrixOne 不承诺自身随机数算法在不同版本之间保持不变；
- 即使存在 seed，不同执行计划或并行调度也不能据此承诺稳定的“行到随机值”映射；
- 因此，MO 不会仅为 MySQL 语法兼容实现 `RAND(seed)`，不会替换生成器以匹配 MySQL，也不为该函数提供跨版本或跨执行计划的确定性/可复现性契约。

**使用建议：** 需要稳定、可重放的随机值时，应在应用侧生成并将值持久化；不要把 `RAND()` 或假设存在的 `RAND(seed)` 用作可复现业务结果的依据。

**关联记录：**

- [#28577：RAND(seed) is unavailable for deterministic random sequences](https://github.com/matrixorigin/matrixone/issues/28577)
- [#28577 产品决策评论：not planned](https://github.com/matrixorigin/matrixone/issues/28577#issuecomment-5661781879)

**证据：**

- 官方 `main`：`a72a224ce85fd13aa919fb56dab58b8c60b366dc`，2026-09-14，本地单节点 CN/TN/LogService；同一 SQL 连续 3 轮结果一致；
- 代码注册仅保留无参 RAND overload：[`pkg/sql/plan/function/list_builtIn.go`](https://github.com/matrixorigin/matrixone/blob/a72a224ce85fd13aa919fb56dab58b8c60b366dc/pkg/sql/plan/function/list_builtIn.go#L9204-L9233)。

除非产品决策明确变化，否则不要将 `RAND(seed)` 重新作为待修复兼容性缺陷处理，也不要基于该语法要求增加 MySQL 序列一致性或可复现性保证。

---

## 聚合函数与结果元数据

### GROUP_CONCAT-001：不承诺 `group_concat_max_len=512` 的 MySQL 协议类型切换

**状态：契约限制**

最小 SQL：

```sql
SET SESSION group_concat_max_len = 4;
SELECT GROUP_CONCAT(v ORDER BY id) FROM t;

SET SESSION group_concat_max_len = 512;
SELECT GROUP_CONCAT(v ORDER BY id) FROM t;

SET SESSION group_concat_max_len = 513;
SELECT GROUP_CONCAT(v ORDER BY id) FROM t;
```

**MySQL 对照：** 对文本输入，MySQL 会在 `group_concat_max_len <= 512` 时公开 `VAR_STRING`，并在超过该阈值后切换到长文本/BLOB 协议类型；二进制输入有对应的 `VARBINARY`/BLOB 型切换。

**MatrixOne 契约边界：**

- MatrixOne 保留当前 `GROUP_CONCAT` 的文本 LOB 返回类型规则，不承诺根据 `group_concat_max_len` 在 MySQL 的 512-byte 边界切换普通查询结果集的协议类型；
- 不应要求 MatrixOne 仅为字段 `Type`、`Length` 或预编译语句跨阈值的元数据变化而实现 MySQL 的阈值选择规则；
- `BLOB` 家族协议类型码不能单独证明结果是二进制：必须结合 collation、charset 和 flags 判断文本/二进制语义；文本 collation 下的该类型可被驱动映射为 TEXT/LONGVARCHAR/String；
- 因此，应用不得依赖 `group_concat_max_len=512` 前后必然得到 MySQL 风格的 VARCHAR/VARBINARY 与 TEXT/BLOB 元数据切换。

**不被本条目豁免的正确性问题：**

- 文本结果的 charset、collation 或 flags 错误；
- 二进制 `GROUP_CONCAT` 结果中的 NUL 或非 UTF-8 字节被转换、截断或损坏；
- 返回值与配置的最大长度、截断语义相矛盾；
- 同一输入被错误地按文本或二进制解释。

以上任一情况仍是独立的产品正确性缺陷，不能以本条“阈值不承诺”为由关闭或拒绝处理。

**关联记录：**

- [#28663：GROUP_CONCAT reports BLOB metadata below MySQL 512-byte VARCHAR threshold](https://github.com/matrixorigin/matrixone/issues/28663)
- [#28663 研发决策评论](https://github.com/matrixorigin/matrixone/issues/28663)：保留当前返回类型规则，不仅为 MySQL 的 512-byte 元数据切换增加实现与 prepared-statement 复杂度。

**证据与后续：**

- 该条目记录的是明确的产品范围决策，而不是“BLOB 等同于二进制”的推论；
- 验证文本/二进制语义时，应同时检查 `VARCHAR`、`VARBINARY`、`group_concat_max_len=4/512/513`、prepared 跨阈值执行、完整协议元数据及 NUL/非 UTF-8 字节保真；
- 除非产品决策变化，或上述语义检查发现独立正确性问题，否则不要仅因未对齐 MySQL 的 512-byte 类型阈值而重新打开 #28663。

---

## 索引与最终一致性

### FULLTEXT2-001：COPY ALTER 后的 FULLTEXT2 查询不提供立即一致性

**状态：契约限制**

适用操作：对带有未受影响 FULLTEXT2 索引的表执行 COPY ALTER，例如：

```sql
SET experimental_fulltext2_index = 1;
ALTER TABLE docs ADD COLUMN extra INT;
SELECT id FROM docs WHERE MATCH(body) AGAINST('quantum');
```

**MatrixOne 契约边界：**

- FULLTEXT2 是异步、最终一致索引，不提供同步索引或 DDL 完成即 `MATCH` 可见的保证；
- COPY ALTER 成功返回后，替换表的 FULLTEXT2 索引可能仍在异步重建/刷新；此时 `MATCH ... AGAINST` 可以短暂返回空集或旧索引结果，即使底表 `LIKE` 等扫描结果已包含目标行；
- 调用方不得把 `ALTER TABLE` 的成功返回当作 FULLTEXT2 搜索结果已就绪的信号。需要依赖索引结果的流程必须设计等待、重试或其他应用侧最终一致性处理；
- MatrixOne 不承诺该窗口为零，也不为该场景提供同步化语义。

**不被本条目豁免的正确性问题：**

- 索引在应用已满足其明确的就绪/重试条件后仍永久不能收敛；
- 基表与 FULLTEXT2 结果在已收敛状态下持续不一致，或存在数据丢失、损坏；
- 产品后来提供公开的就绪接口，却在该接口已确认就绪后仍返回错误结果。

以上情况仍应作为独立 bug 跟踪；本条仅排除“DDL 返回后立即查询尚未收敛”的兼容性或同步性要求。

**使用建议：**

- 对强一致读取要求，不能把刚完成 COPY ALTER 的 FULLTEXT2 `MATCH` 作为唯一判断依据；
- 业务应在可接受的最终一致性窗口内重试，或在需要立即精确结果时采用不依赖该异步索引的查询/流程；
- 不要将内部隐藏索引表、CDC `tag` 等实现细节当作应用兼容接口；它们仅可用于内部测试或诊断。

**关联记录：**

- [#28837：COPY ALTER leaves an unaffected FULLTEXT2 index empty](https://github.com/matrixorigin/matrixone/issues/28837)
- [#28837 产品决策评论：FULLTEXT2 is eventually-consistent / WON'T FIX](https://github.com/matrixorigin/matrixone/issues/28837#issuecomment-5711671000)
- [#28879：首次重建与缓存刷新修复](https://github.com/matrixorigin/matrixone/pull/28879)
- [#29028：避免保留空索引 generation 的后续修复](https://github.com/matrixorigin/matrixone/pull/29028)

**证据与后续：**

- 官方 main `0370bb4d6b118da29e164c54aa34ee010ed897bc`，2026-09-17，本地单 CN 验证：三个独立 COPY ALTER 场景中，ALTER 后首次 `MATCH` 为空，随后替换索引恢复并返回原有命中；这只说明当前观测到最终收敛，不构成窗口时长 SLA；
- 现有回归 [`fulltext2_copy_alter.sql`](https://github.com/matrixorigin/matrixone/blob/main/test/distributed/cases/pessimistic_transaction/fulltext2/fulltext2_copy_alter.sql) 在替换索引 durable base 就绪后验证搜索结果；多 CN 路径目前因 #28985 被 skip；
- 除非产品决策改变为同步索引语义，或发现上述独立正确性问题，否则不要仅依据 ALTER 后短暂空结果重新打开 #28837。

### FULLTEXT2-002：`FORCE_SYNC` 重建不保证远端 CN 缓存立即失效

**状态：契约限制**

`ALTER TABLE ... ALTER REINDEX ... FULLTEXT2 FORCE_SYNC` 的同步范围是重建任务本身及执行该语句的 CN，
不构成所有 CN 的缓存失效屏障。另一个已经缓存旧 generation 的 CN 可能继续返回旧结果，直到其缓存按
最终一致机制刷新，或通过公开的缓存控制能力显式处理。

**契约边界：**

- `FORCE_SYNC` 返回后，不承诺所有 CN 立即观察到同一 generation；
- 调用方不得把该语句当作跨 CN 的同步读屏障；
- 需要立即一致结果时，应避免从可能持有旧缓存的任意 CN 读取，或使用产品提供的缓存控制接口；
- 缓存最终无法收敛、底表数据错误、重建失败或查询 panic 不属于本条豁免范围。

**关联记录：**

- [#29080：FULLTEXT2 FORCE_SYNC rebuild leaves warm remote CN on the old generation](https://github.com/matrixorigin/matrixone/issues/29080)
- [#29080 研发决策：多 CN 索引缓存采用最终一致性，WON'T FIX](https://github.com/matrixorigin/matrixone/issues/29080#issuecomment-5809996874)
- [#29024：缓存控制能力](https://github.com/matrixorigin/matrixone/pull/29024)

**当前验证：** 官方 main `5be6cd90b501da225be591ffffe6000bf01f515e` 的本地 2 CN / 1 TN /
1 LogService 环境中，连续 3 轮在 CN2 预热旧 generation、CN1 执行 `FORCE_SYNC` 后，两端均立即从
`(alpha,beta,gamma)=(3,0,3)` 切换为 `(0,3,3)`。该结果说明当前实现可及时收敛，但不升级为跨 CN
立即一致性保证，也不能作为依赖该时序的 MOTR 契约。

除非产品明确增加跨 CN 同步失效语义，否则不要仅因远端 CN 在 `FORCE_SYNC` 返回后短暂读取旧 generation
而重新作为 Bug 跟踪。

---

## 向量索引数值边界

### HNSW-001：HNSW cosine 不支持零或 float32 次正规查询向量

**状态：契约限制**

适用范围：使用 `cosine_distance` 的 HNSW 索引查询。

**MatrixOne 契约边界：**

- HNSW cosine 依赖 float32 归一化向量。当查询向量为零向量，或其 float32 平方范数下溢时，索引路径会明确拒绝查询，不保证自动回退到精确扫描；
- 该拒绝是为了避免返回负 cosine distance、`-Inf`、`NaN` 或错误 Top-K 成员，属于受支持范围限制，不是新的稳定性回归；
- 正常可归一化的查询向量仍应使用 HNSW ANN，且不得产生负距离、非有限 score、虚构 row id，或因 score 导致派生表过滤、聚合、分页和等值连接结果异常。

**已知存储向量限制：**

- 对已存储向量，如果其 norm 超出 float32 可表示范围，底层 usearch 可能返回 `1` 或 `NaN`，与标量 `cosine_distance` 不一致；
- 研发已评估在 HNSW 异步 CDC 维护阶段拒绝这类向量，但该做法可导致 watermark 无法推进、后续 DML 永久不再应用，或在 update 的 `Remove` 成功而 `Add` 失败后造成索引缺行；
- 因此该存储侧极端数值差异当前明确保留，不应通过拒绝合法 DML 或中断异步索引维护来规避。调用方不应将 norm 超出 float32 范围的向量用于 HNSW cosine 检索。

**不被本条目豁免的正确性问题：**

- 普通已归一化查询被错误拒绝，或未使用已建好的 HNSW 索引；
- 受支持向量产生负距离、`Inf`/`NaN`、错误 Top-K 成员或不稳定行集；
- 拒绝路径导致 panic、会话中断、数据修改或索引维护停滞。

**使用建议：** 使用 HNSW cosine 前，应确保查询和入库向量可在 float32 域内稳定归一化。需要零向量、次正规向量或极端数值的精确 SQL 语义时，不应依赖 HNSW cosine 路径。

**关联记录：**

- [#29082：HNSW cosine search returns wrong or -Inf scores for zero and tiny vectors](https://github.com/matrixorigin/matrixone/issues/29082)
- [#29100：统一 float32 distance domain 并定义 HNSW 边界](https://github.com/matrixorigin/matrixone/pull/29100)
- [#29100 研发决策：零/次正规查询 fail-fast，存储向量极端 norm 限制保留](https://github.com/matrixorigin/matrixone/pull/29100#issuecomment-5782272538)

**回归要求：**

- 零/次正规查询应稳定 fail-fast，不得返回伪造 score 或部分行；
- 正常归一化查询应验证 `LIMIT 1`、`K>1`、派生表过滤、聚合、分页和等值连接，并确认 score 有限且结果集稳定；
- 回归不得把极端存储向量错误 score 设为“正确期望值”；该项是已知限制，不是可固化的正确结果。

### VECTOR-002：向量参数来自标量子查询或自连接时不保证使用 HNSW / IVFFLAT

**状态：契约限制**

适用范围：距离函数的查询向量不是 literal、参数或规划阶段可直接识别的常量，而是来自标量子查询、
派生表、CTE 或同表自连接，例如：

```sql
SELECT a.md5_id
FROM ca_comprehensive_dataset AS a
JOIN (
  SELECT question_vector
  FROM ca_comprehensive_dataset
  WHERE md5_id = 'reference-id'
) AS ref_vec ON 1 = 1
ORDER BY l2_distance(a.question_vector, ref_vec.question_vector)
LIMIT 10;
```

**MatrixOne 契约边界：**

- 当前 HNSW / IVFFLAT Top-K 改写要求查询向量在索引扫描规划时可作为稳定的查询参数使用；
- 来自标量子查询、派生表、CTE 或另一侧 Join 的向量需要先执行关系运算才能得到，当前不会改写为向量索引
  probe，允许采用表扫描、Join 和 Sort；
- SQL 本身仍可执行并返回关系语义结果。“查询没有使用向量索引”是本条记录的能力限制，不等同于 SQL
  不支持或结果错误；
- 对同一个采样集合进行向量自连接并计算 pairwise distance，同样不属于单查询向量 Top-K 索引支持面；
- 研发确认当前使用方式需要拆成两个查询：先取得 reference vector，再把该向量作为第二条 Top-K 查询的参数。

**使用建议：**

1. 第一条查询按主键或其他条件读取 reference vector；
2. 第二条查询使用已取得的 vector literal / prepared parameter 执行
   `ORDER BY l2_distance(indexed_column, ?) LIMIT K`；
3. 需要 pairwise、自连接或 CTE 内向量比较时，不应依赖 HNSW / IVFFLAT 自动改写，应按扫描型工作负载评估资源。

**不被本条目豁免的正确性问题：**

- 拆成两条查询后，满足已支持 Top-K 形态却仍未使用已就绪的向量索引；
- 扫描回退与精确 SQL oracle 返回不同的行集、距离或排序；
- 查询引发 panic、会话中断、数据修改、资源泄漏或错误的部分结果；
- 产品以后公开支持 scalar-subquery / Join vector probe，但实现仍不能生成对应索引计划。

**关联记录：**

- [#23158：vector index didn't take effect](https://github.com/matrixorigin/matrixone/issues/23158)
- [#23158 研发结论：当前需拆成两条查询](https://github.com/matrixorigin/matrixone/issues/23158#issuecomment-3653626620)
- [#23158 补充验证：PostgreSQL 18.3 + pgvector 0.8.2 的相同 SQL2/SQL3 也未命中 HNSW/IVFFLAT](https://github.com/matrixorigin/matrixone/issues/23158#issuecomment-5883514940)

除非产品扩展向量索引改写能力，或出现上述独立正确性问题，否则不要仅因 reference vector 来自子查询、
派生表、CTE 或 Join 而重新把“未命中向量索引”作为 Bug 跟踪。

---

## 客户端与协议兼容性

### JDBC-001：Connector/J server-side prepared `SELECT *` 不保证跨 DDL 刷新结果元数据

**状态：契约限制（Connector/J 兼容性）**

适用范围：MySQL Connector/J 开启 `useServerPrepStmts=true`，复用已经执行过的
`PreparedStatement("SELECT * ...")`，同时由另一连接执行会改变结果列集合的 DDL，包括：

- `ALTER TABLE ... ADD/DROP COLUMN`；
- DROP 后重建同名表；
- DROP 后重建同名 view。

**已确认行为：**

- Connector/J 8.3.0 会保留 prepared statement 首次执行时的结果列定义；
- DDL 后服务端返回新的列集合时，驱动可能尝试把三列结果与缓存的两列定义合并，并抛出
  `ArrayIndexOutOfBoundsException`；
- 该现象在 MatrixOne 的 same-CN、cross-CN 和 Proxy 路径均可出现；
- MySQL 8.4.11 使用相同 Connector/J 8.3.0 复现同样的 add-column、table recreation 和 view recreation
  异常。MySQL 对应 [Bug #97924](https://bugs.mysql.com/bug.php?id=97924) 已被判定为 `Not a Bug`，原因同样是
  Connector/J 缓存 prepared result metadata；
- 因此该行为不作为 MatrixOne 服务端缺陷修复，也不承诺旧 server-side prepared handle 在任意 DDL 后自动
  刷新 `SELECT *` 元数据。

**使用建议：**

- 不要在可能发生结果 schema 变化的生命周期中长期复用 `SELECT *` 的 server-side prepared handle；
- DDL 后关闭并重新 prepare statement，必要时重建连接；
- 可设置 `useServerPrepStmts=false` 使用 client-side prepared statement。已验证该模式能够在上述 DDL 生命周期
  中重新读取列定义；
- 对需要长期稳定复用的 statement 显式列出字段，并把 schema 变更与 statement 生命周期协调起来。

**不被本条目豁免的正确性问题：**

- 未发生 DDL 或结果 schema 没有变化时，server-side prepared metadata 仍然错误；
- 新建的 prepared statement、重建连接或 client-side prepared statement 仍返回旧列定义；
- DDL 后出现服务端 panic、连接协议损坏、数据错误或与 Connector/J metadata cache 无关的异常；
- MatrixOne 返回的列定义包本身与实际结果列不一致。

**关联记录：**

- [#29180：server prepared SELECT star keeps stale result metadata after ALTER ADD COLUMN](https://github.com/matrixorigin/matrixone/issues/29180)
- [#29180 研发结论：MySQL + Connector/J 同样复现，按客户端兼容性限制处理](https://github.com/matrixorigin/matrixone/issues/29180#issuecomment-5885370219)

除非能够证明异常来自 MatrixOne 返回错误的协议元数据，而不是 Connector/J 对旧 prepared handle 的缓存，
否则不要将该场景重新作为 MatrixOne 服务端 Bug 跟踪。

---

## 全文索引谓词

### FULLTEXT-001：`WHERE` 中不支持以算术包装的 `MATCH` 作为全文索引驱动条件

**状态：契约限制**

适用范围：classic `FULLTEXT` 与 `FULLTEXT2` 的全文检索谓词。

```sql
-- 支持：直接写出成员谓词
SELECT id FROM docs
WHERE MATCH(body) AGAINST('alpha') > 0;

-- 不支持：在 WHERE 中以算术表达式包装 MATCH
SELECT id FROM docs
WHERE MATCH(body) AGAINST('alpha') + 0 > 0;
```

**MatrixOne 契约边界：**

- 只有规划器能够证明“命中集合”语义的 `MATCH` 形态，才会被收集为全文索引驱动条件。当前支持裸 `MATCH(...) AGAINST(...) > c`，以及 `CAST`、`ROUND`、`FLOOR`、`CEIL` 等不依赖操作数值且保序的包装；
- 算术包装 `+`、`-`、`*`、`/` 在 `WHERE` 中均不属于该支持面，包括看似恒等的 `MATCH + 0`、`0 + MATCH`、`MATCH - 0`、`MATCH * 1`、`1 * MATCH` 和 `MATCH / 1`；
- 同样不要依赖 `COALESCE`、`GREATEST`、`ABS`、`POWER`，或带预编译参数的算术表达式作为 `WHERE` 中的全文索引驱动条件；
- 此类写法当前会被安全拒绝（该问题中为 `ERROR 20105`），而非退化为错误的索引过滤或错误结果；
- 在投影列或 `ORDER BY` 中计算全文分数，与在 `WHERE` 中把表达式识别为索引驱动条件，是两条独立的规划路径。前者可用不代表后者受支持。

**设计原因：**

算术包装是否保持成员语义取决于运算值和符号：例如 `* -1`、`* 0`、`+ 5` 会改变比较含义，而预编译除数的符号在规划时也可能未知。MatrixOne 当前不承诺完整的单调性、常量或符号分析，也不为恒等算术 AST 提供兼容性特例。

**使用建议：**

- 将过滤条件改写为裸成员谓词，例如 `MATCH(body) AGAINST(?) > 0`；
- 如需展示或排序分数，可在 `SELECT` / `ORDER BY` 中单独计算分数；
- 不要把算术包装的 `MATCH` 在 `WHERE` 中的可接受性当作 MySQL 兼容性承诺。

**不被本条目豁免的正确性问题：**

- 已支持的裸 `MATCH` 谓词或上述明确支持的包装被拒绝、返回遗漏/额外结果，或未走应有的全文索引路径；
- 全文检索引发 panic、会话中断、资源泄漏，或投影/排序中的分数计算本身错误；
- 产品以后公开承诺支持某个算术包装形态，却仍然拒绝该形态。

**关联记录：**

- [#29064：arithmetic wrappers around MATCH score prevent FULLTEXT predicate rewrite](https://github.com/matrixorigin/matrixone/issues/29064)
- [#29064 产品决策评论：算术包装不作为全文索引驱动条件](https://github.com/matrixorigin/matrixone/issues/29064#issuecomment-5718907319)
- [#29064 覆盖矩阵与复现记录](https://github.com/matrixorigin/matrixone/issues/29064#issuecomment-5713256878)

**证据与后续：**

- 研发已明确将 `20105` 定义为安全拒绝，而不是错误结果；该决策同时不承诺为 `+0`、`*1`、`/1` 等恒等形式提供例外；
- 除非产品决定扩展全文索引谓词的单调性/常量分析，或发现上述独立正确性问题，否则不要仅因算术包装的 `MATCH` 在 `WHERE` 中被拒绝而重新打开 #29064。

---

### FULLTEXT-002：JSON parser 不承诺将普通 `json_extract*` 当前读改写为 FULLTEXT2 probe

**状态：契约限制**

适用范围：在 JSON 列上创建 `FULLTEXT2 ... WITH PARSER json` 后，以普通 JSON 函数作为
当前读过滤条件的查询。

```sql
SET experimental_fulltext2_index = 1;
CREATE TABLE docs(id INT PRIMARY KEY, doc JSON);
CREATE FULLTEXT2 INDEX ft_json ON docs(doc) WITH PARSER json;

SELECT id FROM docs
WHERE json_extract_string(doc, '$.foo') = 'needle';
```

**MatrixOne 契约边界：**

- `json_extract`、`json_extract_string` 和 `json_extract_float64` 是普通 SQL 谓词；无论表上
  是否存在 JSON FULLTEXT2 索引，查询都必须保持精确的关系语义，并与无索引 SQL oracle 返回相同的行集；
- 当前不承诺把这些谓词自动改写为 `fulltext2_search`，也不承诺 `EXPLAIN` 中出现任何特定的全文索引节点；
  `Table Scan + Filter` 是允许且正确的执行计划；
- JSON FULLTEXT2 的异步维护不能证明覆盖当前读快照时，优化器必须保留原始 JSON 谓词并回退扫描，不能为了
  索引加速而返回不完整结果；
- JSON current-read probe 加速属于独立 Feature，不是现有 JSON parser 的兼容性或性能承诺。不要仅因某个
  当前读没有走 probe 计划而作为 Bug 提交或重新打开 #27926。

**不被本条目豁免的正确性问题：**

- 带 JSON FULLTEXT2 索引的普通 `json_extract*` 查询与无索引 SQL oracle 返回不同的行集；
- 产品实际选择 JSON probe 后出现漏行、额外行、事务可见性错误或 DML 后结果不一致；
- 查询导致 panic、会话中断、资源泄漏，或异步索引在其已明确满足就绪条件后永久无法收敛；
- 产品以后公开承诺 JSON current-read probe 加速，却仍不执行或不满足该新承诺。

**使用建议：**

- 需要验证普通 JSON 谓词时，以无索引表或扫描路径为 SQL oracle，比对精确行集；
- 不要把 `EXPLAIN` 是否出现 `fulltext2_search` 当作现有 JSON parser 的验收条件；
- 若业务需要对 JSON 当前读提供公开的索引加速 SLA，应单独立项并定义快照完整性、异步就绪和多 CN 一致性合同。

**关联记录：**

- [#27926：JSON predicate index probe for current reads](https://github.com/matrixorigin/matrixone/issues/27926)
- [#27926 研发范围说明：该 probe 功能尚未提供，并非 Bug](https://github.com/matrixorigin/matrixone/issues/27926#issuecomment-5506759750)

**证据与后续：**

- 3 CN / 1 DN 环境中，跨连接完成 insert、update、delete 后，索引表与无索引 oracle 的两轮结果分别一致为
  `1,4` 和 `4,5`；
- [MOTR #185](https://github.com/matrixorigin/motr/pull/185) 增加跨连接 current-read 行集一致性覆盖；
- 除非出现本条列出的独立正确性问题，或产品明确发布 JSON current-read probe 加速合同，否则不要仅依据
  `EXPLAIN` 缺少全文索引节点重新打开 #27926。

---

### FULLTEXT-003：classic FULLTEXT 的投影 `MATCH` 只返回相关行，不补齐零分行

**状态：契约限制**

适用范围：表上存在 classic `FULLTEXT` 索引，并在投影列表中直接计算
`MATCH(...) AGAINST(...)` 分数。

```sql
CREATE TABLE docs(id INT PRIMARY KEY, body VARCHAR(100));
CREATE FULLTEXT INDEX ft ON docs(body);
INSERT INTO docs VALUES
  (1, 'hello world'),
  (2, 'hello there'),
  (3, 'world');

SELECT id, MATCH(body) AGAINST('world') AS score
FROM docs
ORDER BY id;
```

**MySQL 对照：** MySQL 将投影中的 `MATCH` 作为逐行分数表达式；未命中 `world` 的
`id=2` 仍保留在结果中，分数为 `0`。

**MatrixOne 契约边界：**

- classic FULLTEXT 会把可使用索引的投影 `MATCH` 改写为全文索引扫描；该扫描只产生与投影检索词相关的行，
  不会为其余底表行补齐 `score=0`；
- 因此，上述查询只返回 `id=1,3`。即使外层存在 `WHERE id=2` 或
  `WHERE id IN (1,2,3)`，不匹配投影检索词的行仍不会出现在结果中；
- 当 `WHERE MATCH(body) AGAINST('hello')` 与投影
  `MATCH(body) AGAINST('world')` 使用不同检索词时，当前执行路径相当于取两个全文索引扫描的交集，
  因而只保留同时命中两者的行；
- 普通模式与 `IN BOOLEAN MODE` 都适用本条边界；对投影分数再使用 `ROUND` 等包装，
  不会改变其行集语义；
- MatrixOne 不承诺为了兼容 MySQL 而扫描并补齐所有未命中行。该行为是出于避免在超大表上为少量命中结果
  生成大量零分行的产品取舍，不作为待修复 Bug。

**使用建议：**

- 需要全文相关行及其分数时，应把检索条件明确写入 `WHERE MATCH(...) AGAINST(...)`，并让投影使用相同的
  `MATCH` 表达式；
- 需要保留全部底表行并展示未命中行的零分时，不要依赖 MatrixOne 当前的投影 `MATCH` 语义；应拆分底表读取
  与全文检索结果，并在应用侧或经验证的关系查询中完成补齐；
- 不要假设仅将 `MATCH` 放入 SELECT 列表就一定保持输入行数。

**不被本条目豁免的正确性问题：**

- 已命中投影检索词的行仍被遗漏，或幸存行的分数计算错误；
- 过滤条件中的裸 `WHERE MATCH` 返回额外行、遗漏相关行，或与同一表达式的投影结果不一致；
- 相同的 `MATCH` 同时用于过滤和投影时，被错误地重复改写并改变行集；
- 全文索引已经满足其公开的就绪条件后仍永久不收敛，或查询引发 panic、会话中断、资源泄漏；
- 产品以后公开承诺支持 MySQL 风格的“保留全部底表行并补零分”，但实际结果仍不满足该承诺。

**关联记录：**

- [#29299：classic fulltext MATCH in the SELECT list inner-joins the index scan and drops rows with score 0](https://github.com/matrixorigin/matrixone/issues/29299)
- [#29299 研发决策评论：只返回相关行，不修复零分行补齐](https://github.com/matrixorigin/matrixone/issues/29299#issuecomment-5809939130)

**证据与后续：**

- 官方 `main` `66da3877e9e77f01083c4aac0cb9f94ab6e11fe6`，本地 classic FULLTEXT 表验证；
  裸投影、主键过滤、`IN` 过滤、派生表计数、不同检索词的过滤/投影组合及 boolean mode 均表现为只保留
  投影检索词相关行；
- 计划中的投影全文扫描和底表扫描使用 INNER JOIN；不同过滤词会形成多个全文扫描的 INNER JOIN 链；
- 除非出现本条列出的独立正确性问题，或产品决策改变，否则不要仅因投影 `MATCH` 未返回零分行而重新提交
  兼容性 Bug。

---

### FULLTEXT-004：classic FULLTEXT 保留内部 `__DocLen` posting 的前缀可见性

**状态：契约限制**

classic FULLTEXT 将 `__DocLen` 作为内部 posting 存储在词索引中，且不对 `_`、`__` 等前缀查询隐藏它。
因此 `_`、`__`、`+_` 或 `__*` 可能命中所有具有 posting 的非空文档，即使原文不包含这些字符。

该行为仅描述 classic FULLTEXT 的既有实现；需要避免内部 sentinel 暴露时应使用 FULLTEXT2。普通用户词查询
出现漏行、额外行或错误分数，以及 FULLTEXT2 出现相同行为，仍应独立作为正确性问题处理。

**关联记录：**

- [#29298：classic fulltext prefix matches the `__DocLen` sentinel](https://github.com/matrixorigin/matrixone/issues/29298)
- [#29298 研发决策：classic sentinel 设计保留，WON'T FIX](https://github.com/matrixorigin/matrixone/issues/29298#issuecomment-5813040225)

### FULLTEXT-005：classic BOOLEAN 引号只在整个搜索串被包裹时形成短语

**状态：契约限制**

classic FULLTEXT BOOLEAN mode 不支持把表达式内部的引号片段作为短语操作数。例如
`+"matrix origin"`、`"matrix origin" database`、`+"matrix origin" +database` 不具备 MySQL 风格的
“内嵌 quoted phrase”语义；只有整个搜索串被引号包裹时，才按当前 classic phrase 路径处理。

调用方需要组合短语与其他 BOOLEAN 条件时，不应依赖该 classic 语法。整个搜索串的短语查询返回错误结果、
普通未加引号 BOOLEAN 条件错误，或 FULLTEXT2 已承诺语法出现回归，均不属于本条豁免范围。

**关联记录：**

- [#29289：classic BOOLEAN quotes only form a phrase around the entire search string](https://github.com/matrixorigin/matrixone/issues/29289)
- [#29289 研发决策：BOOLEAN mode 不支持该内嵌 quoted phrase 组合](https://github.com/matrixorigin/matrixone/issues/29289#issuecomment-5812936366)

### FULLTEXT-006：classic JSON parser 的单个 value token 上限为 127 bytes

**状态：契约限制**

classic FULLTEXT 的 JSON value token 按短 keyword/tag 处理，单个 value 的索引输入最多保留 127 bytes。
位于该边界之后或跨越边界的词可能不被索引，`MATCH` 因此不会命中；调用方不得用 classic JSON parser
索引依赖超过该上限的长文本 value。

127 bytes 以内的短 value 必须正常索引；截断不得引起 panic、数据修改或索引结构损坏。需要对长 JSON 文本
执行全文检索时，应使用适合长文本的索引方案，而不是依赖该 classic value-token 路径。

**关联记录：**

- [#29281：classic JSON parser drops tokens past byte 127](https://github.com/matrixorigin/matrixone/issues/29281)
- [#29281 研发决策：JSON value 作为短 keyword/tag，127-byte cap 按设计保留](https://github.com/matrixorigin/matrixone/issues/29281#issuecomment-5813593994)

### FULLTEXT-007：classic BOOLEAN bare `*` 表示 match-all

**状态：行为差异**

在 MatrixOne classic FULLTEXT 的 BOOLEAN mode 中，bare `*` 被定义为 match-all，而不是无效或无意义的
truncation operator：

- `AGAINST('*' IN BOOLEAN MODE)` 匹配所有具有全文索引 posting 的文档；
- BOOLEAN mode 中没有 `+` / `-` 的项按 OR-of-optional-terms 组合，因此
  `AGAINST('* apple' IN BOOLEAN MODE)` 等价于 `match-all OR apple`，同样返回所有已索引文档；
- 返回不包含 `apple` 的文档是 bare `*` 自身命中的结果，不应按 `apple` 的 false positive 处理。

该语义是 MatrixOne 明确保留的 classic FULLTEXT 产品契约，调用方不得按“bare `*` 必须被忽略或拒绝”设计
断言。需要只匹配 `apple` 时，应移除 bare `*`；需要前缀查询时，应将 `*` 附着在非空词干之后。

**不被本条目豁免的正确性问题：**

- bare `*` 没有按上述 match-all 契约执行，而是返回类型错误、执行错误或部分行；
- 查询引发 panic、会话中断或索引损坏；
- 带非空词干的正常前缀查询返回错误结果。

**关联记录：**

- [#29287：classic BOOLEAN bare `*` searches the empty prefix](https://github.com/matrixorigin/matrixone/issues/29287)
- [#29287 研发决策：bare `*` 定义为 match-all，`* apple` 为 OR(all, apple)](https://github.com/matrixorigin/matrixone/issues/29287#issuecomment-5813467251)

**当前实现备注：** 官方 main `5be6cd90b501da225be591ffffe6000bf01f515e` 上，bare `*` 和
`* apple` 连续 3 轮均返回 `ERROR 20203`，没有满足上述产品契约。该现象应作为独立实现回归处理，不能以此
将 #29287 原先“match-all 是错误结果”的预期重新成立。

### FULLTEXT-008：`MATCH ... AGAINST` 不支持位于 `OR` / `NOT` 谓词分支

**状态：契约限制**

适用范围：classic `FULLTEXT` 与 `FULLTEXT2` 的全文索引驱动谓词；这里的 `OR` / `NOT` 是 SQL 谓词组合，不是 `AGAINST(... IN BOOLEAN MODE)` 搜索串内部的操作符。

最小 SQL（`docs.body` 已建全文索引）：

```sql
-- 支持：MATCH 是必须成立的合取条件
SELECT id FROM docs
WHERE MATCH(body) AGAINST('alpha') AND id > 0;

-- 当前不支持：MATCH 位于析取或否定分支
SELECT id FROM docs
WHERE MATCH(body) AGAINST('alpha') OR id = 2;

SELECT id FROM docs
WHERE NOT MATCH(body) AGAINST('alpha');
```

**MySQL 对照：** MySQL 可按布尔表达式语义组合全文匹配与 `OR` / `NOT` 条件；例如第一条 `OR` 查询需要保留全文命中行和 `id=2` 行的并集，而否定查询需要保留不命中的底表行。MatrixOne 当前不提供这一组合能力。

**MatrixOne 契约边界：**

- 裸 `MATCH`、与普通条件的 `AND`、两个 `MATCH` 的 `AND`，以及已支持的 JOIN 场景可以由全文索引结果驱动；
- `MATCH OR MATCH`、`MATCH OR <普通谓词>`、`MATCH AND NOT MATCH`、外层 `NOT MATCH` 和 `NOT (MATCH OR MATCH)` 当前均不支持，规划/执行路径会安全返回 `ERROR 20105`，而不是扫描底表求值；
- 当前全文索引驱动流通过 `INNER JOIN` 与底表合并，只适用于每个返回行都必须满足 `MATCH` 的合取条件。`OR` 需要并集合并检索流，`NOT` 需要反连接或可计算全文谓词的全表扫描回退；这些能力目前未提供。强行把 `OR/NOT` 中的 `MATCH` 当作合取条件会丢失应返回的行，因此拒绝优于错误结果；
- `NOT` / 顶层否定属于当前设计上不可驱动的限制。`OR` 组合若未来需要支持，应作为单独 Feature 定义并集驱动及非命中分支的分数语义，不把本条当前的 `20105` 当作原 JOIN bug 未修复。

**使用建议：** 需要全文结果与其他条件的并集时，拆成独立的、各自受支持的查询，在应用侧按业务键去重合并，并单独定义分数和排序规则；需要补集时，不要假设 `NOT MATCH` 会自动回退为全表扫描，应使用经验证的业务侧处理方案。

**不被本条目豁免的正确性问题：**

- 单个 `MATCH` 或明确支持的 `AND` / JOIN 路径被拒绝、漏行、额外返回行或得到错误分数；
- 拒绝路径产生部分结果、panic、会话中断、底表或索引修改；
- 产品以后公开支持 `OR` 或 `NOT` 全文谓词组合，但实现仍拒绝或返回错误结果。

**关联记录：**

- [#20687：原始 JOIN 场景与后续 OR/NOT 讨论](https://github.com/matrixorigin/matrixone/issues/20687)
- [#29069：修复原始单 MATCH / JOIN 路径](https://github.com/matrixorigin/matrixone/pull/29069)
- [#20687 研发结论：OR/NOT 的 20105 是有意保留的安全拒绝](https://github.com/matrixorigin/matrixone/issues/20687#issuecomment-5810397837)
- [#20687 多 MATCH 布尔组合验证](https://github.com/matrixorigin/matrixone/issues/20687#issuecomment-5724939849)

**证据与后续：** 官方 `main` `529ee099e32ed8c38d2806043bf1516ab0345e45`，2026-10-03，本地单 CN 和双 CN 验证：原 issue 两个单 MATCH / JOIN 场景各连续 3 轮返回正确结果，计划包含 `fulltext_index_scan`；`MATCH OR <普通谓词>` 与 `NOT MATCH` 返回 `ERROR 20105`。此前 classic FULLTEXT / FULLTEXT2 的多 MATCH `OR/NOT` 在双 CN 上也复现同一限制。上述查询只读，拒绝路径未修改底表或索引。除非产品扩展全文谓词驱动能力，或发现独立正确性问题，否则不因这些 `OR/NOT` 写法的 20105 重新打开 #20687。

---

## DML / Upsert

### ODKU-001：不支持通过 ODKU 更新主键或唯一键列

**状态：契约限制**

语句形式：

```sql
INSERT INTO t VALUES (...)
ON DUPLICATE KEY UPDATE <assignment-list>;
```

当前不支持在 `<assignment-list>` 中对 PRIMARY KEY 或 UNIQUE KEY 列赋值，包括：

- `id = id`；
- `id = VALUES(id)`；
- `id = 2`；
- `k = k`；
- `k = VALUES(k)`；
- `k = 10`。

其中，no-op 赋值也不能默认视为支持；真正修改键值还涉及唯一性重检查、索引维护和语句原子性，目前同样不在支持范围内。

**MatrixOne 行为：**

- 规划阶段返回 `ERROR 20313 (HY000): unsupported DML: update primary key on duplicate`，或 `unsupported DML: update unique key on duplicate`；
- 语句原子失败，底表和索引不写入；
- 该行为属于当前产品边界，不按数据损坏或已支持能力回归处理。

**MySQL 对照矩阵：**

每个场景都从独立表 `(id,k,a) = (1,9,10)` 开始，待插入行是 `(1,9,100)`：

| ODKU 赋值 | MatrixOne | MySQL |
| --- | --- | --- |
| `k=k,a=VALUES(a)` | 拒绝更新唯一键 | 更新为 `(1,9,100)` |
| `k=VALUES(k),a=VALUES(a)` | 拒绝更新唯一键 | 更新为 `(1,9,100)` |
| `k=10,a=VALUES(a)` | 拒绝更新唯一键 | 更新为 `(1,10,100)` |
| `id=VALUES(id),a=VALUES(a)` | 仅窄条件放行 | 更新为 `(1,9,100)` |
| `id=2,a=VALUES(a)` | 拒绝更新主键 | 更新为 `(2,9,100)` |

**窄范围支持例外：**

[#27931](https://github.com/matrixorigin/matrixone/pull/27931)（提交 `335946ab`，Lundomn）仅放行以下组合：

- PRIMARY KEY 是唯一冲突裁决键；
- 没有可用的二级 UNIQUE 冲突裁决键；
- 赋值是 incoming row 的同列 `VALUES(pk)`；
- 该赋值不会改变主键值。

这个例外不能外推到 `id=id`、常量赋值、二级 UNIQUE 列赋值、存在二级 UNIQUE 时的主键赋值，或任何真正的 PK/UK 变更。

**关联记录：**

- [#28179：ODKU 主键/唯一键赋值兼容性需求](https://github.com/matrixorigin/matrixone/issues/28179)
- [#28179 triage comment：当前产品契约](https://github.com/matrixorigin/matrixone/issues/28179#issuecomment-5551728779)
- [#25393：ODKU 修改 PK/UK 的既有设计限制](https://github.com/matrixorigin/matrixone/issues/25393)
- [#27911：Flink JDBC no-op 主键赋值](https://github.com/matrixorigin/matrixone/issues/27911)

**回归证据：**

- MatrixOne BVT：[`test/distributed/cases/dml/insert/insert_duplicate.sql`](https://github.com/matrixorigin/matrixone/blob/main/test/distributed/cases/dml/insert/insert_duplicate.sql)

除非产品边界或实现明确变更，否则不要把该条目重新当作待验证 bug，也不要重复触发相关验证。

### ODKU-002：仅二级唯一键冲突、主键不冲突的 ODKU 不纳入当前支持范围

**状态：契约限制**

当待插入行只命中 UNIQUE KEY、没有命中 PRIMARY KEY 时，MatrixOne 当前不承诺按 MySQL 的 ODKU 更新语义执行。现有回归用例将该场景标记为预期报错，并检查唯一索引和底表没有被错误修改。

该条目与 ODKU-001 不同：

- ODKU-001 关注 UPDATE 列表是否给 PK/UK 赋值；
- ODKU-002 关注冲突裁决键只有二级 UNIQUE 的场景。

**回归证据：**

- MatrixOne BVT：[`test/distributed/cases/dml/insert/insert_duplicate.sql`](https://github.com/matrixorigin/matrixone/blob/main/test/distributed/cases/dml/insert/insert_duplicate.sql) 中“唯一键冲突但主键不冲突”场景。

---

## 视图写入

### VIEW-001：不支持通过视图执行 INSERT / UPDATE / DELETE

**状态：契约限制**

当前 MatrixOne 不支持将普通视图作为可写目标执行 INSERT、UPDATE 或 DELETE；不要按 MySQL 的简单可更新视图语义推断 MO 一定可以写入底表。

**关联记录：**

- [#25390：updatable views](https://github.com/matrixorigin/matrixone/issues/25390)

---

## 类型转换与非严格语义

### ARITH-001：有符号整数除法使用 `DOUBLE`，不承诺 MySQL 的 `DECIMAL` 精确结果

**状态：契约限制**

当 `/` 的两个操作数均为有符号整数时，MatrixOne 当前将表达式解析为 `DOUBLE`。这与 MySQL 将相应精确数值除法解析为 `DECIMAL` 的类型契约不同。

```sql
CREATE TABLE src(id INT PRIMARY KEY, s BIGINT);
INSERT INTO src VALUES
  (1, 9007199254740992),
  (2, 9007199254740993);

-- MatrixOne：表达式为 DOUBLE；两个值超过 2^53 后可能折叠为同一值
SELECT id, s / 1 FROM src ORDER BY id;
```

**MatrixOne 契约边界：**

- `TINYINT`、`SMALLINT`、`INT`、`BIGINT` 的 signed/signed `/` 结果采用 `DOUBLE` 数值域；
- 因 IEEE 754 `DOUBLE` 只有 53 位整数精度，绝对值大于 `2^53` 的相邻整数可能转换为同一浮点值；
- 因此，基于该表达式的过滤、分组、排序、Join、窗口 peer 分组、VIEW 与 CTAS 会一致地使用已解析的 `DOUBLE` 值。该现象不是按 MySQL `DECIMAL` 域执行的兼容性承诺；
- 显式近似数值操作数同样选择近似数值域；其他操作数类型（例如 `DECIMAL` 或部分 unsigned 组合）可能选择不同的类型规则，不能据此反推 signed/signed `/` 必须使用 `DECIMAL`。

**使用建议：**

- 业务需要保留大整数除法的可区分精度时，应在除法前显式转换为适当的 `DECIMAL(p,s)`，而不是依赖有符号整数 `/` 的隐式类型推导；
- 对 `WHERE`、`GROUP BY`、Join、CTAS 等关系操作，不要将大于 `2^53` 的有符号整数除法结果当作精确键；
- 需要整数截断语义或特定舍入规则时，应显式表达该规则，不要将其他数据库的 `/` 类型契约外推到 MatrixOne。

**不被本条目豁免的正确性问题：**

- 同一已解析为 `DOUBLE` 的表达式在字面量、PreparedStatement、优化、执行、过滤、分组、Join、VIEW 或 CTAS 路径中得到不一致的值或类型；
- 显式 `DECIMAL` / unsigned 组合没有按其自身已解析类型一致执行；
- 除法导致 panic、会话异常、原子性破坏或其他与数值域选择无关的正确性问题。

**关联记录：**

- [#28580：signed integer division uses DOUBLE and corrupts exact relational results](https://github.com/matrixorigin/matrixone/issues/28580)
- [#28580 产品决策评论：保留 signed-integer `/` 的 DOUBLE 类型规则](https://github.com/matrixorigin/matrixone/issues/28580#issuecomment-5678396568)

**证据与后续：**

- 研发确认：MySQL 的 `DECIMAL` 路径不是 MatrixOne 的正确性规范；在 `DOUBLE` 域内由舍入造成的值折叠，以及由此带来的关系运算结果，是已选择类型契约的一致后果；
- 除非产品改变 signed/signed 除法的类型规则，或发现上述跨路径不一致/独立正确性问题，否则不要仅因它与 MySQL 的精确结果不同而重新打开 #28580。

### CONVERT-001：部分非法字符串的隐式数值转换存在明确行为差异

**状态：行为差异，不等同于“不支持”**

对于 `'abc'`、`'123abc'` 等字符串转数值场景，MySQL 可能完成转换并产生 warning，而 MatrixOne 当前可能直接报错。该差异已被记录，但在产品决策明确前，不把它登记为“MO 明确不支持”，也不据此自动关闭或重复验证相关 issue。

**关联记录：** [#25309](https://github.com/matrixorigin/matrixone/issues/25309)、[#25343](https://github.com/matrixorigin/matrixone/issues/25343)、[#25364](https://github.com/matrixorigin/matrixone/issues/25364)

### CONVERT-002：`IGNORE` / 非严格模式 / `LOAD DATA` 的调整值语义仍待产品决策

**状态：待产品决策**

字符串截断、非法数值、十进制饱和、非法日期以及 warning/error 语义的组合行为，不能在产品决策前统一标记为“不支持”。相关 issue 保持独立跟踪，后续应先确定 SQL mode 和 warning 语义，再补充兼容性矩阵。

---

## 已确认的结果差异

### FUNC-001：`TIMEDIFF()` 混合 TIME 与 DATETIME

**状态：行为差异**

当 `TIMEDIFF()` 的两个参数一个是 TIME、另一个是 DATETIME 时：

- MySQL 返回 `NULL`；
- MatrixOne 会将 TIME 按当前日期转换后参与计算。

**关联 issue：** [#23464](https://github.com/matrixorigin/matrixone/issues/23464)

---

## 新增条目的证据要求

新增“不支持”条目时，必须同时记录：

1. 最小 SQL 和前置数据；
2. MySQL 对照结果；
3. MatrixOne 的返回值、错误码或错误消息；
4. 底表、索引、事务原子性和资源状态；
5. 官方 `main` 的 commit、环境拓扑和日期；
6. issue/comment、代码路径或 BVT/回归用例链接；
7. 明确这是产品契约、窄范围支持、行为差异还是待产品决策。

以下情况不得直接写入“契约限制”：

- 只有一次失败，尚未排除 fixture、环境、资源或测试脚本问题；
- 只有单机结果，但原场景要求多 CN、Proxy、升级或 Chaos；
- 只是在旧版本失败，当前官方 `main` 尚未确认；
- 代码中出现 `not supported`，但该路径是内部 API、测试桩或不对用户开放的接口。
