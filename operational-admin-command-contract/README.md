# MatrixOne 内部管理命令支持范围

本文档记录 MatrixOne 已明确移除或不再支持的内部管理命令。它们不是普通业务 SQL，也不是 MySQL 兼容性契约的一部分；调用方不得依赖其历史可用性、参数格式或错误文本。

更新时间：2026-09-18

## 状态定义

| 状态 | 含义 |
| --- | --- |
| 不支持 / 已移除 | 命令不属于当前公开支持面；不得以历史行为作为产品承诺或回归目标。 |
| 重新引入前提 | 若未来恢复该命令，必须重新定义输入契约、错误处理与回归测试。 |

## MOCTL-001：不支持 CN `MergeObjects` 管理命令

**状态：不支持 / 已移除**

历史上可通过如下内部管理入口调用：

```sql
SELECT mo_ctl('cn', 'MergeObjects', '<parameter>');
```

其中 table/object 形式的 `targetObjSize` 解析曾对非法值走入 panic-recovery，返回内部错误和 Go stack，而不是正常参数错误。该路径对应 [matrixone#27885](https://github.com/matrixorigin/matrixone/issues/27885)。

### 当前契约

- `MERGEOBJECTS` 不再注册在 CN `mo_ctl` 的支持命令表中；因此不再提供该命令、其参数格式或历史错误文本的兼容性保证。
- 此命令原本仅面向人工运维/调试，不属于业务 SQL 接口，也不构成 MySQL 兼容功能。
- 不应以 `mo_ctl('cn', 'MergeObjects', ...)` 的执行成功、非法参数报错类型，或历史合并行为作为自动化回归、应用逻辑或运维流程的依赖。
- [#27885](https://github.com/matrixorigin/matrixone/issues/27885) 已按 `not planned` 关闭；研发的范围说明为该路径仅是手工 CN 管理操作，异常会被恢复且不影响服务可用性，优先级为低并已标记 `deferred`。

### 不被本条目豁免的问题

- 其他仍受支持的 `mo_ctl` 命令发生 panic、服务中断、资源泄漏或返回错误结果；
- 产品后来重新公开 `MERGEOBJECTS`，但未提供明确参数校验、权限边界和失败原子性；
- 普通表合并、后台 compaction 或 DML 路径受到影响。它们与该已移除的手工命令无关，应独立作为产品问题处理。

### 重新引入前提

若未来重新支持 `MERGEOBJECTS`，至少需要：

1. 定义 table 与 object 两种参数形式，以及 `targetObjSize` 的有效范围；
2. 对非法参数返回普通 invalid-argument 错误，禁止进入 panic-recovery；
3. 补充两种形式的 Go 单元测试，并在具备公开支持承诺后再设计端到端运维回归；
4. 明确权限、并发/资源影响和操作失败时的数据一致性语义。

### 证据

- 官方 `main`：`480b91764a94cf9ab49d3f2b43a60cb63ce677c6`，2026-09-18；`pkg/sql/plan/function/ctl/types.go` 的支持命令表不含 `MERGEOBJECTS`。
- 同目录回归检查 `TestMergeObjectsCommandRemoved` 明确断言 `MERGEOBJECTS` 未注册。
- [#27885 关闭说明](https://github.com/matrixorigin/matrixone/issues/27885#issuecomment-5726919061)。

除非产品明确重新发布该命令及其支持契约，否则不要将其历史 panic、参数兼容性或执行结果作为待修复的公开功能缺陷重新打开。
