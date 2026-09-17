# MatrixOne MySQL 兼容性契约

本文档登记 MatrixOne 与 MySQL 之间已经明确的兼容性边界，重点记录 **MO 当前明确不支持的行为**，以及少量已确认的结果差异。

这不是“所有还没测过的 MySQL 语法”的列表。只有形成了产品契约、研发明确结论，或有稳定代码/回归证据的行为，才能登记为“不支持”。单次测试失败、环境问题和仍待产品决策的行为不得直接写入该分类。

更新时间：2026-09-17

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
