### 测试版本

- 分支：`main`
- commit：`269d59addd032d20897cc4d86f58de3e387a6d76`
- 部署方式：独立 embedded 1-CN / 2-CN；Arrow 与 S3 gate 均由用例显式开启；对象存储为本地 MinIO。
- 测试日期：2026-09-10

### 原问题验证

默认配置下三个 Arrow gate 保持关闭；显式开启后执行 Arrow IPC File/Stream LOAD。测试未使用共享 Docker 或外部 TKE 环境。

### Happy Path 覆盖

1. 新增 VersionID MinIO UT：File v1 在 latest 写入 v2 后仍读 v1、精确删除 v1 后 fail-closed、Stream v1 在 latest 更新后仍读 v1；重复 3 次通过。
2. 新增事务与连接恢复：`BEGIN → INSERT → 损坏 LOAD → COMMIT` 仅保留前序 INSERT；`KILL QUERY` 取消真实条件 GET、零部分写入、同一连接可重试；物理客户端断连后 connection ID 消失、表仅保留 seed、重连重试成功。三类用例合并重复 3 次通过。
3. 新增指标口径：显式事务中成功 LOAD 后 ROLLBACK，表为 0 行，而 Arrow reader records/batches/rows 各增加一次；重复 3 次通过。

### Unhappy Path 覆盖

1. 无 INSERT 权限用户的 Arrow S3 LOAD 最终被拒绝且表保持 seed-only，但拒绝前已访问对象存储；latest main 稳定复现 3/3。该缺陷已提交为 [#28618](https://github.com/matrixorigin/matrixone/issues/28618)，指派给 iaml...
2. gate 拒绝、损坏 Arrow 输入、约束失败、对象变化、KILL QUERY、客户端 context cancel、客户端断连均检查失败后的表状态及成功重试控制。

### 白盒验证

`go test ./pkg/sql/colexec/external -count=1` 通过（39.213s），包含 reader、VersionID、lease/ownership 与指标相关 UT。未以白盒 fault 代替 KILL QUERY/断连的协议层验证。

### 回归测试

- 源码测试 PR：[matrixorigin/matrixone#28619](https://github.com/matrixorigin/matrixone/pull/28619)
- 测试设计与执行记录：[Ariznawlll/mo-test-reports#28](https://github.com/Ariznawlll/mo-test-reports/pull/28)
- 完整本地回归：`go test ./pkg/tests/arrowload -count=1` 通过（132.832s）。

### 测试证据

[#28619](https://github.com/matrixorigin/matrixone/pull/28619) 包含 VersionID、生命周期和指标测试；[#28618](https://github.com/matrixorigin/matrixone/issues/28618) 包含权限顺序复现步骤、3/3 结果、原子性及 owner 对照；[#28](https://github.com/Ariznawlll/mo-test-reports/pull/28) 记录完整执行矩阵。

### 测试结论

测试不通过。
