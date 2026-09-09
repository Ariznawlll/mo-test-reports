# Issue #23684：Apache Arrow IPC `LOAD DATA` 测试设计

> 状态：测试设计；候选提交的阶段测试已开始，结果见
> [2026-09-09 阶段测试记录](test-results-20260909.md)。研发已确认以 Issue comment
> 的 default-on 合同为准，候选实现因此测试不通过；外部 release gate 仍待完成。
> 研发最新直接确认的 default-on 作为本轮策略 Oracle；研发随后发布的
> [补充 comment](https://github.com/matrixorigin/matrixone/issues/23684#issuecomment-5597540449)
> 用于收紧压缩、边界、对象版本、事务、连接、分布式、zero-copy、metrics 和证据要求，
> 但其中公开的 default-off 表述与直接确认仍冲突，不能代替正式发布文档。

## Feature 背景与范围

Issue #23684 需要通过 `LOAD DATA` 导入 Apache Arrow IPC File 与 IPC
Stream。研发 comment 描述了本地文件、stage、S3-compatible、File
record-batch 分片、多对象并行、字典列和事务语义；候选实现只将 Arrow
纳入 `LOAD DATA`，不包含 Arrow 外表、查询结果 Arrow 输出、inline
payload 或 Arrow Flight。

本设计覆盖候选分支 `iamlinjunhong/matrixone@m-23684` 的静态 Arrow IPC
导入合同，以及其与普通 LOAD、约束、事务、对象存储、CN 和 MySQL 协议的
交互。它不把真实 AWS/OSS/COS、生产压测或混合版本发布准入伪装成本地
回归已完成的工作。

**合同结论与实现缺陷。** 研发的 [早期 Issue comment](https://github.com/matrixorigin/matrixone/issues/23684#issuecomment-5537676762)
说省略配置时本地、S3/stage 与 distributed 都默认可用；候选实现的
[delivery decision](https://github.com/matrixorigin/matrixone/blob/f0c31cd4b830be32442cf329e0a3fb08aa9c16c3/docs/design/evidence/23684_arrow_load_delivery_decision.md)
和 `#28145` 则规定三个 admission gate 默认 `false`。二者是互斥的可观察
合同。研发最新直接确认“默认就得开启”，因此当前 `POLICY-ON` 是验收 Oracle；候选
实现及其 `POLICY-OFF` 回归测试固化了错误预期，必须修复后再执行通过性验证。补充
comment 的 default-off 文字与此冲突，作为需求记录问题保留，不能据此把失败改判通过。

## 支持证据与版本基线

- 官方 `main`：`cd04bb4c1af5bc595e2147dc645dfa754f4c395b`，于 2026-09-09
  通过 `git ls-remote` 核验。
- 候选审计对象：`iamlinjunhong/matrixone@m-23684`
  `28b22a00681bc28db32342cbb1f897c361ab1f1a`；当前实现合入提交为
  `f0c31cd4b830be32442cf329e0a3fb08aa9c16c3`（PR #28145）。
- 正式 LOAD 入口证据：[MatrixOne LOAD DATA 文档](https://docs.matrixorigin.cn/en/v26.3.0.12/MatrixOne/Reference/SQL-Reference/Data-Manipulation-Language/load-data-infile/)。
  截至本设计日期，该文档不是 Arrow 格式的正式发布声明；Arrow 的具体
  合同证据仅来自研发的[早期 comment](https://github.com/matrixorigin/matrixone/issues/23684#issuecomment-5537676762)、
  [补充 comment](https://github.com/matrixorigin/matrixone/issues/23684#issuecomment-5597540449)
  与候选分支设计，且默认策略记录互相矛盾；发布 owner 仍需补充正式文档/发布说明。
- 新鲜度审计：能力目录基线 `bdbd613fdece966769eb68481a3e58bfbc36b30c`
  已落后当前 `main`。`main` 已含 #28145 的实现与测试资产；因 Arrow
  尚无正式产品支持声明，仍需补充发布文档；测试验收按研发已确认的
  default-on comment 执行，现有 fail-closed 候选合同记为实现缺陷。

## 验收目标与非目标

验收目标：

1. 对被接受的 IPC File/Stream，精确导入承诺的行、列、NULL 与类型值；
   相同逻辑数据通过逐行 `INSERT` 的独立 oracle 得到相同表内容。
2. 对列映射、容器、类型、对象版本、约束、取消或任一 shard/object 失败，
   整条 LOAD 不发布部分结果，并在失败后立即验证数据、事务和资源状态。
3. 每个 CN 在打开 I/O 前执行其本地 admission 决策；远端/并行路径不能被
   coordinator 的旧配置绕过，老协议 peer 不能接受新增 pipeline 合同。
4. commit 后的数据经重启仍存在；未提交/失败数据不存在；`force-materialize`
   只改变所有权与资源计数，不改变 SQL 结果。

非目标：Arrow Flight/Flight SQL、`LOAD DATA LOCAL INFILE`、inline Arrow、
Arrow external table、`FIELDS`/`LINES`/`IGNORE ... LINES`/变量/`SET`、Hive
partition、外部 gzip，以及实际云厂商证书与生产容量指标。IPC 内部 LZ4/ZSTD
是必测格式能力：File/Stream 均覆盖正常读取、损坏压缩 body、decoded-size 超限和
dictionary compression，不能以普通未压缩 IPC 通过代替。

## 涉及的 MatrixOne 能力

- capability_id: `dataio.load-and-export`；主能力。Arrow 为 LOAD 的候选
  格式，验收使用普通 LOAD 的公开结果与失败原子性。
- capability_id: `sql.data-types-and-conversion`；必需。类型矩阵、精度、
  符号、时区、NULL 与拒绝行为由此归属。
- capability_id: `schema.constraints`；必需。`NOT NULL`、长度、唯一/主键
  冲突必须在 Arrow 导入中维持同一约束合同。
- capability_id: `transaction.statement-atomicity`；必需。多对象、分片、
  转换和 commit 失败的原子粒度是整条 LOAD statement。
- capability_id: `storage.object-storage-and-cache`；必需。S3/stage、条件
  读取、版本/ETag、关闭错误与缓存/lease 清理必须覆盖。
- capability_id: `security.authorization-and-isolation`；必需。对象与 stage
  权限、账户隔离、拒绝后的零泄漏。
- capability_id: `session.mysql-protocol`；常见。真实 MySQL 连接的结果、
  断连、取消与错误后连接复用。
- capability_id: `transaction.explicit-transaction`、`storage.data-durability`；
  高风险。显式 commit/rollback、重启和持久性。
- capability_id: `observability.system-status`；条件适用。只验证候选实现
  文档承诺的指标、错误分类与脱敏，不固定内部 plan 文本。

未纳入 CDC、PITR、GPU 与 data branch：研发合同没有 Arrow 专属入口或发布
承诺；若 Arrow 默认开放或进入正式版本，应在相应 Feature 的写入/恢复矩阵
中重新评估，而不是以本设计的未覆盖推断安全。

## 架构、入口、数据流与状态对象

公开入口是 `LOAD DATA INFILE {'filepath'=..., 'format'='arrow',
'arrow_container'='auto|file|stream'} INTO TABLE ... [PARALLEL 'true']`，
并包括直接 S3 option 与 `stage://` 路径。默认映射为大小写不敏感字段名；显式
目标列清单改为位置映射。

数据流为 parser/binder 形成加载计划与对象身份快照 → coordinator 建 scope →
每个执行 CN 的 `External.Prepare` 再次判断 Arrow gate → FileService 条件读取
→ IPC reader 验证 File/Stream、schema/dictionary/record batch → bridge 转换与
statement capacity/borrowed-buffer lease → 普通 LOAD 事务 publish/commit。关键
状态对象是目标表/约束、transaction、session、对象 version/ETag/size、IPC reader
与 Arrow backing、range/capacity lease、pipeline 版本和每个 CN 的配置快照。

对异步或故障用例，禁止固定 sleep。测试夹具必须提供 post-admission、pre-publish
或 blocked conditional-read 的确定边界；在该边界轮询可观察状态并设 deadline。

## 风险与关键不变量

| 风险 | 不变量与 Oracle |
| --- | --- |
| IPC 或映射错误 | 成功表与独立 `INSERT` oracle 完全相同；隐式名映射唯一、显式映射按位置。 |
| 缩窄、溢出、损失精度或坏字典 | 返回明确领域 cause；失败后立即 `SELECT` 全表、约束 metadata 和行数仍为操作前快照。 |
| multi-object/fanout 部分成功 | 一个对象、record batch 或 shard 失败时目标表绝不出现成功子集。 |
| 对象在计划/执行间变化 | 无 versioning 时，同 key/同 size 但 ETag 已变化必须失败并回滚；有 versioning 时计划锁定 v1，写入 v2 但保留 v1 必须全量读取 v1，删除计划 v1 才失败。Stream 单次 GET 已取得 v1 后 latest key 变化不能误判为失败。 |
| admission 漏检 | 无配置 profile 与产品确认的默认值一致；worker CN 的 gate 独立于 coordinator。 |
| lease/backing 泄漏 | 成功、失败、取消、重试和重启后 range/capacity/pinned bytes 回归基线；无 goroutine/session/临时文件残留。 |
| 事务/重启错误 | 未提交数据对第二会话不可见，rollback/失败为零行，commit 后重启精确保留数据。 |

## 测试环境、拓扑、配置与数据

| 环境 | 用途 | 配置与数据 |
| --- | --- | --- |
| 1-CN embedded + MySQL driver | 默认/显式 gate、File/Stream、映射、类型、事务与错误 | 分别执行 `POLICY-OFF` 与 `POLICY-ON`；最小 Arrow fixture 与独立 `INSERT` oracle。 |
| 2-CN embedded | File record-batch fanout、worker 重检、协议与取消时序 | 每个 CN 明确写 gate；一台 permissive、一台 restrictive；有界同步钩子。 |
| 本地 MinIO | direct S3 与 S3-backed stage、条件读取、对象变化和取消 | 分别启用/关闭 versioning；临时 bucket/key 与短生命周期测试凭据；报告必须给出未 SKIP 证据且不得记录 secret。 |
| exact-release Linux artifact + 旧 peer | MORPC v56/v57、升级顺序 | 真实二进制组合，不用 mocked protocol 代替。 |
| Nightly/stability | quota、range/record-batch、缓存、pressure、漏泄与多轮竞态 | 记录阈值、行数、分布、拓扑、timeout、peak memory、pinned/spill bytes。 |

Fixture 至少包含：空、单/多 record batch；File 与 Stream；LZ4/ZSTD 与 dictionary
compression；所有支持标量族；NULL bitmap；dictionary；正确与不匹配 schema；坏
magic/截断流；全部 record 合法但尾部 EOS 损坏的 Stream；多对象 glob；同一数据的
SQL `INSERT` oracle；以及可在确定读阶段之后替换/删除的对象。至少一组 File/Stream
必须由独立 PyArrow 版本生成并记录版本，避免生产者与 reader 共用 Arrow Go
实现而产生同源盲点。所有数据库、stage、bucket prefix 与用户使用 UUID 前缀并在
`t.Cleanup` 中精确删除。

## 功能测试矩阵

| 用例组 | capability_id | 不变量 | 层级 |
| --- | --- | --- | --- |
| CFG-01..06：默认值、显式 gate、重启、每 CN 重检 | `dataio.load-and-export` | policy 与 worker admission 一致，拒绝发生在 I/O 前 | UT + BVT + MOTR |
| IPC-01..12：File/Stream/auto、错误容器、损坏 IPC、尾 EOS | `dataio.load-and-export` | 正确行或零可见行 | UT + BVT |
| CMP-01..08：File/Stream × LZ4/ZSTD、损坏与 dictionary compression | `dataio.load-and-export` | 解码值精确；坏压缩体在发布前失败且 allocation 归零 | UT + BVT |
| LIM-01..18：schema field/depth/custom metadata、wire/decoded body、output batch、statement capacity | `dataio.load-and-export` | 每层 N-1/N/N+1 独立命中；拒绝后 pending/active 均为零 | UT + BVT + MOTR |
| MAP-01..08：名映射、case、显式列位置、缺失/重复 | `sql.data-types-and-conversion` | 映射唯一且值精确 | BVT |
| TYPE-01..28：数值、decimal、字符串/二进制、时态、dictionary、NULL | `sql.data-types-and-conversion` | 精确值或明确拒绝且零部分写入 | UT + BVT |
| ATOM-01..10：约束、multi-object、commit/cancel/close failure | `transaction.statement-atomicity` | 整 statement 成功或零 publish | BVT + MOTR |
| OBJ-01..12：S3/stage、ETag/version identity、替换/删除、取消 | `storage.object-storage-and-cache` | 请求携带计划 identity；只读计划版本或失败，绝不混读 | UT + MOTR |
| DIST-01..08：fanout、dict shard、worker gate、v56/v57 | `session.mysql-protocol` | worker policy 和兼容性不被绕过 | UT + MOTR + recovery |
| TXN-01..10：autocommit、statement/transaction rollback、commit ACK、断连 | `transaction.explicit-transaction` | 可见性、原子性、锁/会话清理，重试不假定幂等 | BVT + MOTR + recovery |
| CONN-01..06：server KILL QUERY、context cancel、socket disconnect、fixed connection | `session.mysql-protocol` | 精确区分物理连接复用与连接池替换，清理有界 | BVT + MOTR |
| OPS-01..12：reader 指标、restart、borrow/materialize、pressure | `observability.system-status` | reader publish 与 txn commit 分层解释，无残留 | UT + stability + big-data |

## 正常路径（Happy Path）

1. `IPC-01/02`：在确认的 admission profile 中分别加载 IPC File 与 Stream；
   `auto` 正确识别；逐行与 SQL oracle 比较 `COUNT(*)`、按主键排序的所有列和
   NULL。重复同一 statement 到干净表，结果可重复且资源归零。
2. `MAP-01..04`：字段名大小写差异、物理列顺序差异的显式列清单、多个 record
   batch 及 multi-object glob 成功。无显式列清单时仅允许一一名称映射；显式时仅
   允许等数目的位置映射。
3. `TYPE-01..15`：有符号/无符号同宽与合法 widening、Float32→Float64、exact
   Decimal128、String/LargeString、Binary/LargeBinary/FixedSizeBinary、Bool、
   Date32/64、Timestamp、Time32/64、dictionary 与 nullable Null。每项比较字面
   值、目标 metadata 和预期 padding。
4. `OBJ-01..03`：本地 stage、direct MinIO S3 与 S3-backed stage 成功加载；确认
   source 身份、结果和临时对象清理。报告仅记录 bucket alias/UUID prefix。
5. `DIST-01..03`：2-CN 下 File 按 record-batch 边界 fanout；含 dictionary 的每个
   shard 均可独立解码。Stream 在 `PARALLEL 'true'` 下保持顺序读取；当候选
   `distributed-enabled=false` 时，File 请求退化为串行且结果相同。

`DIST-01..08` 的结果证据必须记录每个 CN 的 execution/shard coverage，并按主键比较
所有列；只有总行数、distinct id 或范围正确不能证明远端 CN 实际参与。另在远端 shard
已执行后注入晚失败，整句必须回滚。Stream 的 sequential 仅描述单个对象内部读取，
不对多对象声明全局顺序。

`OPS-04..09` 的 zero-copy 生命周期必须逐点验证：retained record 在 reader Close 后
仍有效；旧 view 在下一 batch 以及 owner Reset/Free 后仍按 retain 合同有效；COW 后新
buffer 与旧 backing 分离；allocation failure 不覆盖旧 view；只有最后一个 owner
release 才把 range/capacity/pinned 全部归零。

## 边界路径（Boundary Path）

- `IPC-03..06`：schema-only 零行 File/Stream、单行、单/多 batch 临界、File closing
  magic、`auto` 与显式 `file/stream` 的合法组合；zero-byte/no-schema 必须单列为非法，
  不能和合法零行 fixture 合并。
- `MAP-05/06`：大小写不同但唯一的字段名；最大合法列名；目标表有默认列但显式
  列清单仅选择 Arrow 对应列。
- `TYPE-16..28`：每个整数族的边界和刚好合法 widening；decimal 最大 precision/
  scale；`BINARY(N)` 的零填充；空字符串/空二进制；最大合法长度；闰日；时间戳
  单位到微秒的无损边界、合法 timezone；全 NULL 与 NULL/非 NULL 混合 dictionary。
- `OPS-01/02`：同一 fixture 在 borrow 与 `force-materialize=true` 下的结果、
  affected rows 与事务可见性相同；仅 borrowed/copied/pinned 指标按政策改变。
- `LIM-01..18`：对 schema field、nesting depth、custom metadata、wire body、decoded
  body、output batch 和 statement capacity 分别使用 N-1/N/N+1；每个失败点都断言
  reader/admission 的 pending=0、active=0，避免只验证返回错误。

## 异常路径（Unhappy Path）

每个异常 case 的固定后置动作是：**先**查询目标表完整排序结果、`COUNT(*)`、
约束/表定义、当前 transaction 与相关 metric/lease；**再**执行一次独立的成功
LOAD，证明连接和资源可复用。

- `CFG-01..06`：无配置与显式 false；每个 gate 单独缺失；S3/stage 缺
  `s3-enabled`；distributed 缺 `distributed-enabled`；worker 禁用但 coordinator
  启用；重启后显式 false 保持。`POLICY-OFF` 期望 I/O 前拒绝，`POLICY-ON` 期望
  无配置成功；两 profile 只运行产品确认的一个。
- `IPC-07..12`：File 当 Stream、Stream 当 File、未知 container、坏 magic、
  zero-byte/no-schema、截断 Stream，以及全部 record 合法但最后 EOS 缺失/损坏；
  断言错误分类和零行。
- `CMP-01..08`：File/Stream × LZ4/ZSTD 的正常与 dictionary compression 对照；篡改
  compressed body、伪造 decoded-size 为 N+1、截断 codec prefix，断言在输出 batch
  发布前失败且 pending/active 回零。
- `MAP-07/08`：缺字段、未知字段、大小写折叠后重名、字段数不同、显式列数不同。
- `TYPE-29..40`：数值 narrowing、signed/unsigned family 改变、溢出、decimal
  rescale/precision loss、非法 UTF-8、string/binary 超长、日期/时区/精度损失、
  bad dictionary index/嵌套 dictionary、unsupported nested type、NULL 到 NOT NULL。
- `ATOM-01..10`：第二对象 schema 不同、后续对象损坏、唯一/NOT NULL 失败、
  workspace dump 后 commit 注入失败、close-only object-changed、context cancel。
  所有 case 验证 seed row 保留、导入行一个不出现。
- `OBJ-04..12`：使用确定 read-stage 同步点验证三种不同 Oracle：① versioning 关闭，
  计划后以同 key/同 size/不同 ETag 替换，必须 `object changed` 且整句回滚；②
  versioning 开启，计划锁定 v1 后写入 v2 且 v1 保留，必须成功且所有列都来自 v1；
  删除计划 v1 后必须失败；③ Stream 的单次 GET 已取得 v1 后 latest key 变化，允许
  完成 v1，不能套用 File 多 range 的失败 Oracle。另覆盖范围响应截断、Close 报错、
  权限拒绝、超时/网络 reset；核对请求中的 version/If-Match 与完整数据，而非只看行数。
- 明确拒绝：`LOCAL INFILE`、inline、Arrow external table、`FIELDS`/`LINES`/
  `IGNORE ... LINES`/变量/`SET`、Hive/jsondata、外部 gzip、`arrow_container='flight'`。

## 事务与并发

- `TXN-01` autocommit：成功后第二连接可见精确数据；失败时第二连接始终看不到导入行。
- `TXN-02/03` 显式 `BEGIN`：本会话可读、第二会话不可读；`ROLLBACK` 后两边零行；
  `COMMIT` 后第二会话一次性可见全部行。
- `TXN-04` multi-object / distributed：故意让一个晚到 shard 失败，轮询另一会话，
  在失败返回前后均不得看到子集。
- `TXN-05` 已知 post-admission/pre-publish 终止：同步点保持到进程/集群确认终止，
  重启后必须零新增行；这里不允许“0 或全量”的宽松判定。
- `TXN-06` commit 已确认成功后终止：重启后必须全量存在且所有列一致。
- `TXN-07` 仅 commit-ACK 不确定窗口允许最终全量或零行；LOAD retry 不是幂等操作，
  自动或人工重试都必须先按业务键查重，否则可能重复导入。
- `TXN-08` 显式事务内执行 `BEGIN → 成功 INSERT → 失败 LOAD`：分别核对本会话与观察
  会话、随后 `COMMIT` 和 `ROLLBACK` 的状态，明确失败只回滚 statement 还是整个
  transaction，不能从 autocommit 用例外推。
- `TXN-09/10` 10 次 fresh 2-CN generation：并行提交与 gate 滚动变更，只接受每个
  statement 的完整或零结果，记录失败时各 CN 的 policy snapshot。

连接恢复不能套用统一后置模板：gate-off 必须持续拒绝，直至恢复配置；permission
error 的表状态由具备权限的独立 observer 查询；client context cancel 后 driver 可能
丢弃物理连接，因此 `sql.DB` 上 `SELECT 1` 成功不能证明原连接复用。`CONN-01..06`
分别以 `connection_id()` 固定 `sql.Conn`，覆盖 server `KILL QUERY`、client context
cancel 与 socket disconnect，并为 statement、transaction、lease 和 goroutine 清理
设置确定 deadline。

## 安全与租户隔离

- `SEC-01` owner 使用其授权 local path/stage 成功；普通用户在未授予目标表 INSERT
  或 stage/对象访问时被拒绝，表与 metadata 均不变化。
- `SEC-02` 两个 account 使用同名 stage/对象别名时，账户 B 不能读取账户 A 的对象、
  表行、错误细节或系统 metadata。
- `SEC-03` 使用临时 MinIO identity；检查 query history、错误、metric labels 和
  日志不含 access secret、签名 URL 或对象内容。凭据通过运行环境注入，绝不写入 SQL
  fixture、result 或本报告。
- `SEC-04` `GRANT`/`REVOKE` 后新连接立即按当前权限执行；拒绝的 LOAD 不遗留
  object lease 或可由其他租户读取的数据。

## 恢复与故障注入

- `REC-01`：成功 commit 后重启 1-CN，按主键比较全表与 commit 前 oracle；未提交
  或转换失败的事务重启后仍为零新增行。
- `REC-02`：在确定的 post-admission/pre-publish 点保持 barrier，直到集群关闭完成；
  重启后必须零新增行。当前允许“0 或全量”的 rollout 用例只算部分覆盖，必须收紧。
- `REC-02B`：已收到 commit success 的终止场景重启后必须全量；commit-ACK 不确定
  场景单独允许全量或零行，并显式记录 retry 可能重复。关闭 gate 后新 statement
  必须持续拒绝，直至配置恢复。
- `REC-03`：exact-release artifact 的 v56/v57 组合。旧 peer 必须拒绝新增 remote
  payload；文档化且执行支持的升级顺序，在混合版本期间禁用 remote Arrow。
- `REC-04`：2-CN worker loss、FileService connection reset 和对象 read close
  failure，只在具备确定同步钩子的 chaos/recovery workflow 中执行；成功标准为错误
  可解释、零部分 publish、lease 归零和后续重试正常。

## 性能、规模与稳定性

小 fixture 先证明 File/Stream、mapping、转换与 statement 原子合同；不以“大数据
跑完”取代语义 oracle。以下仅在对应 release gate 允许时进入 Nightly：

- `PERF-01`：跨 record-batch/range、对象和 statement capacity 阈值，记录精确阈值、
  100%/NULL-heavy/high-cardinality/dictionary-heavy/long-varlen 分布、行数、计划、
  peak memory、pinned/copy bytes、结果摘要和清理。
- `PERF-02`：borrow 与 materialize 三轮 A/B；除了正确性外，依据 runbook 的部署
  基准比较 p99、吞吐和 60 秒内 pinned-byte 回归。未定义基线时报告数据，不写通过。
- `STAB-01`：10–20 个 fresh generation 的多对象/2-CN/cancel/retry；检测 goroutine、
  range/capacity lease、cache、临时对象与连接线性增长。
- `CHAOS-01`：真实对象存储、CN/网络故障和滚动升级；只有部署声明了这些故障下的
  可用性合同才作为发布 gate。它不能被 1-CN embedded mock 替代。

## 兼容性

Arrow 入口是 MatrixOne 专属的 `format='arrow'` 扩展，不能以 MySQL 自身的文件
格式行为当 Oracle。`COMP-01` 使用真实 MySQL text-protocol 连接验证 affected rows、
列 metadata、SQLSTATE/错误后 protocol 同步；`COMP-02` 验证 `SET time_zone` 的
Timestamp→TIMESTAMP/DATETIME 无损和有损拒绝；`COMP-03` 确认普通 MySQL
`LOAD DATA LOCAL INFILE` 没有被 Arrow 支持意外放开。只有 MatrixOne 正式兼容矩阵
承诺的 client/driver 才加入二进制协议或 JDBC/ODBC 环境。

## 可观测性与资源清理

- `OBS-01`：`mo_arrow_load_rows_total` 与 `batches_total` 在 External reader publish
  时递增，早于 transaction commit；晚到失败或 rollback 后允许保留增量，禁止把它们
  解释成 committed-row counter。分别定义成功、reader 后晚失败、commit 失败的观测窗。
- `OBS-02`：`errors_total` 只覆盖 reader layer 的错误分类（container、schema、
  conversion、object changed、cancel 等），不能要求 planner/gate/commit error 都增加；
  每个 case 记录生产 metric 的准确层和采样窗口。
- `OBS-03`：restart 后 process-local counter reset 与 active lease/pinned gauge 回零是
  两个独立 Oracle；counter reset 不能证明 lease 已释放。错误与 label 不含凭据或
  Arrow payload，查询诊断不改变导入结果。
- `CLEAN-01..05`：每个成功/失败/取消/重启后关闭 reader/provider response，释放
  range/capacity/borrowed vector，删除 UUID fixture、stage/table/database；清理失败
  即 test 失败。以 baseline delta 而非绝对内部计数判断资源回归。

## 可执行用例—证据表（研发 comment 补充）

状态基于 2026-09-09 最新 `main@cd04bb4c1af5bc595e2147dc645dfa754f4c395b`；
`PASS` 只表示表中精确 Oracle 已验证，`PARTIAL` 表示现有资产只能证明其中一部分，
`MISSING` 表示不得从相邻 PASS 外推。

| ID | 最小数据、拓扑/配置 | 同步点与精确 Oracle | Test/Subtest 或缺口 | 命令/状态 |
| --- | --- | --- | --- | --- |
| CFG-DEFAULT | 1-CN，无 Arrow 配置，1 行 File | I/O 前 admission；按研发最新确认应成功，显式 false 才拒绝 | `TestArrowLoadGateDisabled` 及 config defaults 固化 default-off | `C4`，**FAIL / Bug #28517** |
| CMP-FILE | 2 batch，File × LZ4/ZSTD | 解码所有列；Close 后 retained record 有效；pending/active=0 | `TestIPCFileAndStreamCompression`、`TestCompressedIPCRecordOutlivesReaderAndOwnsAllocation/file-*` | `C1`，PASS 3/3 |
| CMP-STREAM | 2 batch，Stream × LZ4/ZSTD | 同上，且合法 EOS 后停止 | 同上 `/stream-*` | `C1`，PASS 3/3 |
| CMP-CORRUPT | File/Stream，损坏 prefix/codec/decoded-size=N+1 | publish 前 typed error；无 decode allocation；pending/active=0 | `TestIPCCompressionMetadataRejectedBeforeDecodeAllocation` | `C1`，PASS 3/3 |
| CMP-DICT | File/Stream，dictionary delta + compression | 每个 batch 所有 dictionary 值精确 | 现有 compression 与 dictionary replay 分开，缺组合 fixture | MISSING |
| IPC-EOS | 所有 record 合法，仅尾 EOS 缺失；1-CN SQL | reader 在消费完 records 后报错；SQL 表仅保留 seed，随后正常 LOAD 成功 | `TestIPCStreamRequiresEOSMarker`；BVT 的 `truncated_stream` 还包含 body 截断 | `C1`/`C3`，PASS 3/3；精确尾 EOS SQL 为 PARTIAL |
| IPC-ZERO | schema-only 零行 与 zero-byte/no-schema | 前者成功 0 行，后者格式错误且 0 行 | 没有成对 public-path 资产 | MISSING |
| LIM-SCHEMA | field N/N+1、depth N/N+1、metadata N/N+1 | N 成功、N+1 在 Arrow Go 深分配前失败；pending/active=0 | `TestIPCSchemaFieldAndDepthLimits`、`TestIPCSchemaMetadataAndUnionLimits` | `C1`，PASS 3/3；N-1 为 PARTIAL |
| LIM-BODY | wire body 与 decoded body 上限 | 分别命中 N-1/N/N+1；失败后 pending/active=0 | `TestIPCBodyLimitForFileAndStream`、compression metadata test | `C1`，PARTIAL：尚非每层三点 |
| LIM-OUTPUT | output batch、statement capacity | N-1/N/N+1；拒绝不发布 batch/rows，pending/active=0 | 有 admission/capacity 单测，缺完整双边界 public-path | PARTIAL |
| OBJ-ETAG | MinIO 无 versioning，同 key/同 size/不同 ETag | 条件 range read 后 `object changed`；seed 不变 | `LocalMinIO/ObjectChangeFailsClosed` | `C2`，PASS 3/3，明确未 SKIP |
| OBJ-VERSION | MinIO versioning：计划 v1；写 v2 保留 v1；再删除 v1 | 第一段成功且所有列均为 v1；第二段失败且整句回滚；请求携带 VersionID | SDK request UT 仅验证参数；无真实 versioned MinIO public path | MISSING |
| OBJ-STREAM | Stream 单 GET 取得 v1 后替换 latest | 仍完整读取 v1；不得因 latest 改变失败 | `TestIPCConditionalIdentitySupportsSingleStreamGET` 未在 GET 后替换 latest | PARTIAL |
| TXN-PREPUBLISH | 1-CN，post-admission/pre-publish barrier，shutdown | barrier 持有至 termination；重启后必须 0 新增行 | `TestArrowLoadRolloutRollbackDrain` 提前释放并允许 0/全量 | MISSING；现有 Oracle 不合格 |
| TXN-COMMITTED | LOAD 已返回 success 后 restart | 全部行与列持久存在 | `testArrowClusterRestart` | 既有整包，PASS 3/3 |
| TXN-ACK | commit-ACK 不确定点断连 | 最终仅全量或 0；重试前查重，不能声明幂等 | 无精确 commit-ACK hook | MISSING |
| TXN-PRIOR | `BEGIN → INSERT(seed) → failed LOAD` | 检查本/他会话及随后 COMMIT/ROLLBACK，确定 statement 与 transaction rollback 边界 | `testArrowExplicitTransaction` 仅含成功 LOAD | MISSING |
| CONN-CANCEL | 固定 `sql.Conn` + `connection_id()` | context cancel 后明确原物理连接是否可用；bounded cleanup | 现有 cancel 只证明池/reader 可继续 | PARTIAL |
| CONN-KILL | observer 执行 server `KILL QUERY` | 被杀 statement 0 行；事务、连接、lease 在 deadline 内符合合同 | 无 Arrow public-path subtest | MISSING |
| DIST-CN | 2-CN、每 CN 至少一 shard、带不同 payload | 记录 per-CN execution/shard；按主键比较所有列 | `TestArrowLoadMultiCN` 只查 count/distinct/range | PARTIAL |
| DIST-LATE | 远端 shard 已执行后注入失败 | 观察会话始终看不到成功 shard，最终整句回滚 | compile UT 有 shard 逻辑，无 public-path late remote failure | MISSING |
| ZC-LIFE | retained record/view、reader Close、next batch、Reset/Free | 旧 view 有效；仅 last owner 释放容量 | record outlives reader、vector/bridge retain/reset tests | `C1`/`C5`，PARTIAL：缺完整状态序列 |
| ZC-COW | borrowed view 执行 COW 与 allocation failure | 新 backing 分离；失败保留旧 view；最终容量归零 | `TestFixedExplicitCOW`、transactional materialize/allocation tests | `C5`，PASS 3/3（组件层） |
| METRIC-PUBLISH | reader publish 后，事务 late failure/rollback | rows/batches 可增长，表可 0 行；两者不是 committed-row 指标 | 成功 publish counter UT；无 late-fail/rollback metric case | PARTIAL |
| METRIC-ERROR | reader/planner/gate/commit 各一失败 | 只要求 reader-layer 增 error；其他层不增加 | category/registration UT，无跨层 public case | PARTIAL |
| FIX-PYARROW | 独立 PyArrow 生成 File/Stream，记录版本 | 所有列与 SQL oracle 一致 | 当前 fixture 由 Arrow Go 生成 | MISSING |

本表中的执行命令：

```text
C1: mo-cgo-test -count=3 -run '<compression|limits|EOS|identity|lifetime>' ./pkg/sql/colexec/external/arrowio
C2: mo-cgo-test -v -count=3 -run 'TestArrowLoadBVT/LocalMinIO' ./pkg/tests/arrowload
C3: mo-cgo-test -v -count=3 -run 'TestArrowLoadBVT/CorruptInputRollback/truncated_stream' ./pkg/tests/arrowload
C4: mo-cgo-test -count=3 -run '^(TestArrowLoadGateDisabled|TestArrowLoadGateDistributedDisabledSoftFallback)$' ./pkg/tests/arrowload
C5: mo-cgo-test -count=3 -run '<object-SDK|borrow|COW|transactional-allocation>' ./pkg/fileservice ./pkg/container/arrowbridge ./pkg/container/vector
```

## 回归分层与已有资产

已有候选资产（提交 `f0c31cd4b830be32442cf329e0a3fb08aa9c16c3`）：

- UT：`pkg/container/arrowbridge/bridge_test.go`、`pkg/sql/colexec/external/arrowio/reader_test.go`、
  `pkg/sql/colexec/external/reader_arrow_test.go`、`pkg/sql/plan/arrow_load_gate_test.go`、
  `pkg/config/arrow_load_test.go`、lease/vector/null/metric tests；保留 focused
  `-race` 与 fuzz corpus。
- BVT：`test/distributed/cases/load_data/load_data_arrow.sql`（当前只证明 default
  gate reject，不能替代 opt-in public path）；`pkg/tests/arrowload/arrow_load_test.go`
  覆盖 File/Stream、类型、mapping、transaction、rollback、MinIO 与 restart。
- MOTR：`pkg/tests/arrowload/arrow_load_multicn_test.go`、`arrow_load_minio_test.go`、
  `arrow_load_rollout_test.go`；需要补 deterministic worker-loss/gate-skew 与真实
  client protocol case。
- big-data/stability：现有 `arrow_load_benchmark_test.go` 是本地基准，不能作为
  Nightly admission/pressure 覆盖；按 `PERF-*`、`STAB-01` 新增 workflow。
- recovery/chaos：已有重启和 deterministic shutdown 是控制用例；精确发布 artifact
  mixed-version、真实 provider、2-CN worker-loss 为未完成 release gate。

执行门禁：每个普通用例至少连续 3 轮；并发 10 轮；fresh-generation 竞态 10–20 轮。
依次运行 focused case、所属 package/suite、相关 LOAD/stage/transaction/security
suite 和 CI。任何无关 suite 失败单列名称与证据，不写“全量通过”。

## 不适用项及原因

- GPU 不适用：研发合同没有 GPU Arrow 解码/导入路径；若后续开放 GPU worker，需新增专门基准与隔离测试。
- PITR/Snapshot 不适用：当前候选合同只承诺普通事务持久性，未声明 Arrow 专属备份恢复语义；普通 committed data 的恢复由既有恢复能力负责。
- CDC 不适用：Arrow LOAD 没有独立 CDC API；若产品将 LOAD 变更暴露为 CDC 合同，应由 CDC 测试计划添加 source/sink、schema 演进和 checkpoint 覆盖。
- Arrow Flight 不适用：研发 comment 与候选设计都把 `arrow_container='flight'` 作为拒绝项，而非静态文件 LOAD 的传输方式。
- 真实 AWS/OSS/COS 不适用：本地 MinIO 只证明 S3-compatible integration；真实 provider 验证是 release-readiness 外部 blocker，需在隔离账号和 owner 环境执行。

## 准入、退出、风险与待确认项

**准入。** 指定精确 candidate/release artifact；按已确认的 `POLICY-ON` 同步实现、
设计、文档与 BVT；提供 1-CN/2-CN、MinIO、可控对象替换与
post-admission 同步钩子；测试账号最小权限且不输出凭据。

**退出。** 所有适用 UT/BVT/MOTR 三轮通过，失败路径逐项证明零部分 publish，资源
清理通过；多 CN、object identity、commit failure、restart、协议版本与已确认默认
policy 均有独立证据。Nightly/chaos/real-provider/owner 项未完成时，结果只能是
“候选实现局部验证”，不能称 release-ready。

**剩余风险与待处理。**

1. 已确认缺陷：Issue comment 为 default-on，而 PR/候选实现与回归测试为
   default-off；修复前本 Feature 的测试结论为不通过。
2. Arrow 尚缺正式发布文档与正式兼容声明；维护者 comment 不足以升级 capability
   catalog 为 `supported`。
3. S3/stage/distributed 的 aggregate admission、真实 AWS/OSS/COS、exact Linux
   artifact、mixed-version、deployment A/B、supply-chain/security 和各 owner
   批准仍为 release blocker。
4. 2-CN worker-loss 需要确定同步夹具；不能用偶发的 processlist 观察或 sleep
   得出“未部分提交”的结论。

设计校验命令：

```bash
python3 /Users/ariznawl/.codex/skills/mo-feature-test-design/scripts/validate_test_design.py \
  arrow-load-test-design/README.md
```
