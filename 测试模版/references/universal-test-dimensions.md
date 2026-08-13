# 通用测试维度

先从能力不变量选择维度，再生成用例。不要把本清单机械地全排列；不相关维度写入“不适用项及原因”。

## 1. 用户合同与结果正确性

- 原始需求和公开语法/API；成功与拒绝的精确定义。
- 行、列、顺序、重复、缺失、陈旧数据和完整数据集。
- 类型、signed/unsigned、precision/scale、NULL、charset/collation、timezone。
- affected rows、warning、error code、SQLSTATE、稳定 cause、protocol metadata。
- 优化/索引/并行/spill 路径与独立语义 oracle 的结果等价性。

## 2. Happy Path

- 原始正常场景、最常见配置和默认拓扑。
- 主要正式支持变体；不同入口（SQL/协议/Driver）只在合同相关时扩展。
- 重复执行、drop/recreate、disable/enable 和恢复后的正常控制。

## 3. Boundary Path

- 空输入、单行、多行、无匹配、全匹配。
- NULL、空字符串、零值、负值、重复、NaN/Inf（类型支持时）。
- 类型 min/max、长度、精度、scale、维度、identifier、时间/时区/闰日边界。
- 基数、倾斜、重复度和排序相等键。

Boundary 是合法边界；只有合同规定非法时才放入 Unhappy。

## 4. Unhappy Path 与失败原子性

- 非法语法、类型、参数、组合、对象状态和权限。
- duplicate/conflict/not found/already exists/unsupported/timeout/cancel/disconnect。
- 失败后立即读取全部数据、Catalog、隐藏表、task、transaction、session 和外部对象；恢复操作不得先覆盖失败状态。
- 错误后同一连接、statement、transaction 或 task 是否按合同恢复。

## 5. 生命周期与状态转换

- create → use → alter → drop → recreate。
- enable/disable、start/pause/resume/cancel/retry。
- schema change、index build/rebuild、checkpoint、compaction、GC。
- 幂等、重复提交、重复删除和中间状态可见性。

## 6. 事务与并发

- autocommit、显式 commit/rollback、支持的隔离/事务模式。
- read/read、read/write、write/write、DDL/DML、commit ordering。
- conflict、deadlock、retry、lock wait、timeout、cancel。
- disconnect before/after commit、reconnect、session migration。
- 校验可见性、原子性、affected rows、锁释放和无 stuck transaction。

## 7. 隔离与安全

- database/table/object、account/tenant、user/role、session/connection、CN。
- source/target、primary/branch、snapshot/restore 和 external resource 隔离。
- 授权前后、最小权限、越权、元数据可见性和凭据字符边界。

## 8. 恢复与耐久性

- SQL 错误、statement error、connection loss 后恢复。
- restart、rolling restart、task resume、checkpoint replay、object retry。
- 恢复前后精确数据、Catalog、transaction/task progress 和重复/丢失检查。

## 9. 可观测性

- EXPLAIN/EXPLAIN ANALYZE 的关键算子、过滤、索引和 spill 指标。
- 日志无 panic/fatal/secret/客户数据，错误 cause 可定位。
- metrics、query/statement history、task/checkpoint 状态可解释进度和资源。
- 观测本身不得改变查询或状态。

## 10. 资源与清理

- memory/mpool、goroutine、session、transaction、locks、cache、task。
- temporary/spill files、external objects、database/schema、hidden index/catalog rows。
- 成功与失败均清理；清理失败必须使测试失败。
- 专用服务、端口、data dir、cache 和临时 worktree 只清理本次创建的精确资源。

## 11. 兼容性

- MatrixOne 官方兼容矩阵定义的 MySQL-compatible、partial 和 MO-only 边界。
- text/binary protocol、JDBC/ODBC/正式 Driver、ORM/BI 工具（正式支持时）。
- SQL mode、timezone、charset/collation、metadata、warning 和 error mapping。

## 12. 性能、规模与稳定性

- 小数据是否进入相同计划/算法/资源路径。
- memory/admission threshold、实际 spill、scale-dependent plan switch。
- 高基数、倾斜、重复、NULL-heavy 和多轮 spill。
- 并发 generation、soak duration、throughput/latency、peak memory、restart/OOM。
- 性能测试必须同时验证结果，不以“查询结束”作为正确性证据。

## Traceability

每个用例至少关联：验收目标、能力 ID、不变量、数据/状态对象、环境、测试层、预期结果、清理断言。每项能力不变量必须至少由一个用例或“不适用理由”覆盖。
