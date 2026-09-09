# Apache Arrow IPC `LOAD DATA` 阶段测试记录（2026-09-09）

## 结论

候选提交在本地可执行范围内的 Arrow IPC `LOAD DATA` 功能、异常原子性、
S3-compatible、分布式、资源生命周期和竞态测试通过。本轮没有发现可稳定复现的
产品缺陷。

当前结果仅为**候选实现局部验证通过，不是 release-ready**。Issue 研发 comment
描述的 default-on 与候选实现/测试证明的 fail-closed 仍冲突；真实云厂商、精确
Linux 发布物、混合版本、权限与租户隔离、规模/稳定性、Chaos 和确定性 worker-loss
也尚未完成。

## 基线与环境

| 项目 | 值 |
|---|---|
| MatrixOne 提交 | `f0c31cd4b830be32442cf329e0a3fb08aa9c16c3` |
| 提交说明 | `feat(load): add bounded Arrow IPC ingestion path (#28145)` |
| 工作树 | 独立、干净的 detached worktree；未使用主工作树未提交改动 |
| 平台 | macOS Darwin 23.5.0, arm64 |
| Go | 1.26.5；仓库声明 1.26.4，因此本轮不是 exact-release toolchain 证明 |
| Native 依赖 | 在同一提交执行 CGo/native dependency 构建后运行测试 |
| 集群夹具 | 1-CN/2-CN embedded cluster、真实 MySQL text protocol、本地 MinIO |

## 执行结果

| 分层 | 范围与轮次 | 结果 | 主要证据 |
|---|---|---|---|
| Component/UT | `arrowbridge`、`arrowipc`、`bufferlease`、`external/arrowio` 全包，3 轮 | PASS | File/Stream、类型/字典/NULL、压缩、limits、borrow/materialize、lease、对象 identity、畸形输入 |
| Focused UT | config、mpool、fileservice、external、compile、plan、metric 等 Arrow 相关用例，3 轮 | PASS | fail-closed 配置、planner option、worker gate、serial fallback、fanout、schema drift、条件读、关闭错误、指标注册 |
| Public-path BVT/MOTR | `pkg/tests/arrowload` 整包，3 轮 | PASS，414.376 秒 | 真实 MySQL 协议、类型矩阵、mapping、File/Stream、stage、MinIO、事务/回滚、多 CN、rollout、restart |
| 并发门禁 | 7 个 reservation/lease/account/terminal 并发用例，各 10 轮 | PASS | 并发 retain/release、commit/abort、owner attribution、terminal one-shot |
| generation 门禁 | 失败 generation、旧 record 存活、terminal owner 禁止复活，各 20 轮 | PASS | fresh-generation 与生命周期边界 |
| Race | 上述核心竞态用例，`-race` 1 轮 | PASS | 未报告 data race |
| Fuzz | `FuzzArrowIPCPlanningAndOpenNeverPanicOrLeak`，15 秒 | PASS | 9 个基线种子，21,542 次执行，新增 4 个 interesting inputs，无 panic/leak |

`-race` 首次把两个大型包并行链接时因测试机临时磁盘峰值不足而 build failed
（`errno=28`），这不是产品断言失败。保留小包通过结果后，将 `external` 与
`compile` 串行重跑，二者均通过且未报告 race；没有删除用户文件或清理全局缓存。

## 已验证的设计矩阵

### 正常与边界路径

- File 与 Stream container；LZ4/ZSTD IPC body；多 record batch、EOS、dictionary
  replay/delta、切片 offset、NULL bitmap、长 binary。
- 数值、decimal、bool、timestamp/time、字符串/binary、dictionary index 宽度及非法
  index；按名称和显式列顺序 mapping。
- 本地文件、local stage、direct MinIO File/Stream、S3-backed stage、多对象成功导入。
- 2-CN record-batch fanout，校验总行数、去重行数和完整值域；distributed gate 关闭时
  验证安全串行 fallback。

### 异常、事务与恢复路径

- 未知/冲突 option、unsupported container/DDL surface、格式错误、schema mismatch、
  NOT NULL/约束失败、损坏 IPC、超限 metadata/body/schema。
- 多对象中后续对象损坏、对象在条件读取前被替换、读取取消；均验证 statement 不发布
  部分 Arrow rows，并用后续成功语句证明连接/reader 可复用。
- 显式事务可见性、两会话隔离、commit 前故障注入回滚、与逐行 `INSERT` 对账。
- 集群关闭时已 admission 的 LOAD 只允许全成或全败；随后以全 gate 关闭配置重启，
  再 roll forward 到 distributed 关闭的串行模式。
- commit 后重启读取持久数据；默认 local/S3 gate 均在 I/O 前 fail closed。

### 资源与可观测性

- buffer/range/capacity lease 的 retain/release、强制释放、晚到释放、failed-generation
  生命周期和 allocation terminal one-shot。
- 读取/转换/commit/cancel 错误路径的 Close 与 allocation account 清理；Arrow 指标注册。
- 畸形 IPC 的 fuzz 路径没有 panic 或测试可见泄漏。

## 未完成项与 blocker

| 项目 | 状态与原因 |
|---|---|
| Default policy | BLOCKED：Issue comment 是 default-on，候选实现及当前回归资产是 fail-closed；需产品 owner 书面裁决后才能冻结相应 baseline |
| `mo-tester` SQL BVT | 本轮未跑共享 compose 脚本；其现有资产只覆盖 default gate reject，不能替代已通过的 opt-in public-path Go suite，也仍应进入正式 CI |
| 权限/租户隔离 | 未执行 `SEC-01..04` 的 GRANT/REVOKE、跨租户 stage/object、审计脱敏 |
| 真实 provider | 未执行 AWS S3、OSS、COS；MinIO 仅证明 S3-compatible integration |
| 混合版本/发布物 | 未执行 exact-release Linux artifact、MORPC v56/v57 混部及升级顺序 |
| 故障注入 | 缺少 2-CN post-admission deterministic worker-loss；不能用 sleep/processlist 猜测替代 |
| 规模/稳定性/Chaos | 未执行 1/10/100 GiB、宽表、小 batch、压力、长稳、网络/节点故障和 Nightly workflow |
| Owner/CI | capability owner、security、release owner 审批和正式 CI 结果尚缺 |

## 阶段判定

- 本轮实际执行的本地 UT 与 Go public-path BVT/MOTR：通过。
- 普通用例 3 轮、并发 10 轮、generation 20 轮：达到测试设计中的本地重复门禁。
- Release gate：未达到；上述 blocker 关闭前不得写“全量通过”或“可发布”。

## 核心复现命令

以下命令均在候选提交的独立 worktree 中执行；本机遗留的错误 `GOROOT` 通过单命令
环境覆盖排除，没有修改用户配置。

```bash
env -u GOROOT make -j8 cgo

env -u GOROOT .agents/skills/mo-dev/scripts/mo-cgo-test \
  -count=3 -timeout=600s \
  ./pkg/container/arrowbridge ./pkg/container/arrowipc \
  ./pkg/container/bufferlease ./pkg/sql/colexec/external/arrowio

env -u GOROOT .agents/skills/mo-dev/scripts/mo-cgo-test \
  -count=3 -timeout=1800s ./pkg/tests/arrowload

env -u GOROOT .agents/skills/mo-dev/scripts/mo-cgo-test \
  -run '^$' -fuzz '^FuzzArrowIPCPlanningAndOpenNeverPanicOrLeak$' \
  -fuzztime=15s -timeout=120s ./pkg/sql/colexec/external/arrowio
```

Focused、并发和 race 命令通过 `-run` 选择本报告执行结果表中列明的 Arrow、
capacity lease、generation、object identity、planner/compile 和 metric 用例；完整选择
表达式可从测试执行终端记录追溯。
