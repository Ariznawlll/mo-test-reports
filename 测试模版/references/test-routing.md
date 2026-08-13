# 测试分层与路由

目标是选择能够证明合同的最低成本层，而不是把每个 Feature 放进所有测试集。

## 路由表

| 可观察合同 | 主要测试层 | 补充层 |
|---|---|---|
| 纯函数、编码、内部 ownership/injection | MatrixOne Go UT | focused `-race` |
| 快速确定性公开 SQL | MatrixOne BVT 或领域 MOTR | Go UT（内部边界） |
| 跨 Feature 历史回归 | `motr/suites/14_issue_regression` | 相关产品 UT/BVT |
| 多连接、协议、Driver、并发、进程 | MOTR scenario | lifecycle UT/`-race` |
| 内存阈值、实际 spill、百万行算法路径 | Nightly big-data | 小型语义回归 |
| 长时间资源增长、吞吐、低概率 generation | Stability/soak | focused correctness case |
| 节点 kill/restart、网络分区、外部服务失败 | Chaos/专用恢复流 | lifecycle UT |
| GPU 专属算法/参数 | GPU workflow | CPU 参数/语义控制 |
| Snapshot/PITR/backup/restore 生命周期 | Recovery workflow + BVT | Chaos/长稳（合同相关时） |
| MySQL/JDBC/ODBC/生态兼容 | 对应真实客户端环境 | SQL/BVT 元数据控制 |

## Big-data 决策

```text
小数据能进入相同代码路径并证明相同合同？
├─ 是 → 使用小而确定的 BVT/MOTR
└─ 否
   ├─ 必须跨内存/admission 阈值 → big-data
   ├─ 必须发生实际 spill/临时文件生命周期 → big-data
   ├─ 计划/算法只在规模或统计信息下切换 → big-data
   ├─ 低概率并发竞态需要真实规模 → nightly generation
   ├─ 合同是性能/长稳 → performance/stability
   ├─ 依赖节点/网络故障 → chaos
   └─ 依赖 GPU → GPU workflow
```

大数据报告必须包含：行数、数据分布/基数/重复度、拓扑、配置和阈值、timeout、关键计划、peak memory、spill files/bytes、精确结果摘要、OOM/restart、成功/失败清理。

## 异步测试

- 用有界条件轮询，不用固定 sleep 作为 readiness 证据。
- deadline 到达时输出最后一次状态。
- “task running”不等于进度；检查 checkpoint/index visibility/结果。
- 完成后验证精确结果、计划、增量变化和清理。
- 异步完成但结果不可见仍是失败。

## 回归准入

1. 先确认正式预期行为，不能 baseline 当前产品失败。
2. 能取得 pre-fix 时验证 RED 是原缺陷，而非连接/脚本/baseline 错误。
3. 普通用例至少 3 轮；并发 10 轮；低概率竞态 10–20 fresh generations。
4. 运行 focused case、所在 suite、相关产品测试和 CI。
5. 保证排序、时间、ID 和错误断言稳定。
6. 清理失败必须让测试失败；script 资源使用 PID/time/UUID 避免碰撞。
7. 通用错误码同时断言领域 cause；计划断言只固定关键算子/语义。

## Exclusive execution

只有测试必然修改共享外部状态（集群配置/restart、全租户恢复、CDC 基础设施、全局资源）才能独占。命名碰撞、缺 cleanup、弱隔离、非确定输出或产品 race 必须修复，不能靠 `exclusive_tests` 隐藏。

## 全量 Suite 的无关失败

- 新 case 通过但 suite 有失败时，不得写“全量通过”。
- 核对失败文件和改动路径；保存 actual/expected 和失败名称。
- 与改动相关则停止发布并调查。
- 已确认无关则在 PR/设计风险中如实列出，禁止改 baseline、skip 或删除用例来变绿。
