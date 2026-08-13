# 正式产品能力判定策略

## 当前基线

- 官方分支：MatrixOne `main`
- 验证 SHA：`bdbd613fdece966769eb68481a3e58bfbc36b30c`
- 验证日期：2026-08-13
- 口径：只收录用户可直接使用、已经正式宣布支持的能力。

生成测试设计前必须重新读取远端 `main` 完整 SHA。若 SHA 已变化，检查目标能力相关文档、入口、代码和测试路径；相关路径发生变化时，先刷新能力条目再设计测试。

## 准入门禁

一项能力只有同时满足以下条件，才能进入当前支持索引：

1. 存在公开用户入口：SQL、MySQL 协议、正式 Driver/CLI/API 或公开配置。
2. 当前官方 `main` 存在实现。
3. 至少存在一项正式支持证据，且实现/测试证据可交叉验证。
4. 未标为 Experimental、Preview、Internal、Debug-only、Deprecated 或 Removed。

目录只使用两种状态：

- `supported`：默认部署或文档规定的常规环境可用。
- `supported-with-conditions`：正式支持，但受版本、部署、配置、许可证、CPU/GPU、对象存储或租户范围限制；能力条目必须写明条件。

其他状态可记录在维护审计中，但不得出现在当前正式能力目录。

## 证据优先级

1. [MatrixOne 官方 Feature List](https://docs.matrixorigin.cn/en/v25.3.0.2/MatrixOne/Overview/matrixone-feature-list/) 和当前版本官方产品文档。
2. [MySQL Compatibility Matrix](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)、正式 Release Notes、已接受 RFC/设计文档。
3. 官方 `main` 的公开 SQL、协议、CLI/API 和配置入口。
4. MatrixOne BVT、MOTR、兼容性测试、Nightly/Chaos/恢复工作流。
5. Maintainer 在 Issue/PR 中明确说明的支持合同。
6. 代码实现和内部 UT，仅作辅助证据。

代码存在、Parser 可解析、隐藏变量可打开、开发 PR 已合入或内部 UT 通过，都不能单独证明正式支持。

## 冲突处理

- 文档声明支持、main 实测失败：仍是正式能力，记录产品 Bug 和覆盖缺口。
- main 有实现、无正式宣布：不进入目录，列入待审核清单。
- 文档标记 Experimental/Preview：不进入当前目录，即使 BVT 存在。
- 文档与 main 支持边界不同：采用更窄边界，记录冲突并请求产品确认。
- 不同版本文档冲突：使用最新正式文档，并保留版本条件。
- 企业工具或特定部署：使用 `supported-with-conditions`，明确获取方式和环境门槛。

## 能力与内部组件的边界

产品能力描述用户可观察合同；内部组件只出现在架构依赖中。例如：

- “显式事务、回滚、锁定读”是能力；TxnClient、LockService、TN 是依赖。
- “连接路由和会话迁移”是能力；Proxy、QueryService 是依赖。
- “数据持久性、Checkpoint 和恢复”是能力；TAE、LogService、FileService 是依赖。

测试设计不得把内部实现名称直接当作用户验收目标，除非用户明确要求白盒设计。

## 更新流程

1. 发现官方 main 或文档新增用户入口。
2. 收集正式支持证据和 main 实现/测试证据。
3. 判定状态、条件、限制和兼容差异。
4. 创建或修改能力条目，更新验证 SHA/日期。
5. 更新跨能力关系和现有测试资产。
6. 运行能力目录审计和测试设计校验器。
7. 对受影响的示例 Feature 重新生成测试矩阵。
