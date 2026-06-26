# MatrixOne 内核升级测试流程说明

## 背景

本测试流程用于覆盖 MatrixOne 内核升级中 binary 升级与 metadata/schema 升级分离带来的风险。相关问题见 matrixorigin/matrixone#25077：在升级二进制后，如果没有完成 metadata/schema upgrade，`mo_catalog.mo_branch_metadata` 等新版本依赖的系统表可能不存在，导致分支、快照等相关功能报错。

需要特别说明的是，发布版本和 metadata schema version 不是同一套版本号。例如测试输入可能是 `3.0.14 -> 3.0.16`，但系统表 `mo_catalog.mo_version` / `mo_catalog.mo_upgrade` 中记录的内部 schema 升级可能是 `3.0.2 -> 3.0.3`。

## 测试目标

1. 验证只升级 binary、未执行 schema upgrade 时，测试能识别 metadata 未完成。
2. 验证显式执行 `UPGRADE ACCOUNT ALL` 后，metadata/schema upgrade 能完成。
3. 验证 `auto-upgrade=true` 时，CN 启动后能自动触发 metadata/schema upgrade。
4. 验证多租户升级参数 `upgrade-tenant-batch` 不影响升级完成性。
5. 验证升级前创建的数据和租户在升级后仍可读取。

## Workflow

使用 GitHub Actions workflow：

```text
.github/workflows/kernel-upgrade-path-test-on-tke.yaml
```

主要输入参数：

| 参数 | 说明 |
| --- | --- |
| `base_ref` | 升级前 MatrixOne 分支、tag 或 commit |
| `target_ref` | 升级后 MatrixOne 分支、tag 或 commit |
| `auto_upgrade` | CN 配置 `[cn] auto-upgrade` |
| `upgrade_tenant_batch` | CN 配置 `[cn] upgrade-tenant-batch` |
| `run_upgrade_account_all` | 是否显式执行 `UPGRADE ACCOUNT ALL` |
| `expect_upgrade_complete` | 本次测试是否预期 metadata/schema upgrade 完成 |
| `expected_metadata_tables` | 预期存在的系统表，默认 `auto` |

`expected_metadata_tables=auto` 时，workflow 会根据 `mo_catalog.mo_upgrade.final_version` 或 `mo_catalog.mo_version.version` 判断需要校验的系统表。3.x 路径不会强制要求 `mo_feature_registry`，4.0+ 路径会额外校验 `mo_feature_limit` 和 `mo_feature_registry`。

## 测试步骤

1. 触发 `MO Kernel Upgrade Test On TKE` workflow。
2. 配置 `base_ref` 和 `target_ref`。
3. 根据测试场景设置 `auto_upgrade`、`run_upgrade_account_all`、`expect_upgrade_complete`。
4. workflow 构建 base/target 两个 MatrixOne 镜像。
5. 使用 base 镜像部署集群。
6. 在升级前创建系统租户数据和多个普通租户数据。
7. 替换为 target 镜像，执行滚动升级。
8. 根据参数决定是否执行 `UPGRADE ACCOUNT ALL`。
9. 校验升级结果。
10. 清理测试 namespace。

## 校验内容

升级校验包含以下几类：

1. 基础连通性：
   - `select version();`
   - `select git_version();`
   - `select build_version();`
   - `select @@version_comment;`

2. 升级前数据保留：
   - 系统租户 `upgrade_path_test.before_upgrade` 可读
   - 普通租户 `upgrade_path_test.before_upgrade` 可读

3. metadata/schema upgrade 状态：
   - `mo_catalog.mo_version` 最新记录 `state = 2`
   - `mo_catalog.mo_upgrade` 最新记录 `state = 2`
   - `mo_catalog.mo_upgrade_tenant` 无未完成租户

4. 新版本系统表：
   - `mo_branch_metadata`
   - 4.0+ 额外校验 `mo_feature_limit`
   - 4.0+ 额外校验 `mo_feature_registry`

## 推荐测试矩阵

### Case 1：复现 metadata 未升级问题

目的：验证只升级 binary，不执行 schema upgrade 时，测试能识别系统表缺失。

| 参数 | 值 |
| --- | --- |
| `auto_upgrade` | `false` |
| `run_upgrade_account_all` | `false` |
| `expect_upgrade_complete` | `false` |
| `expected_metadata_tables` | `auto` |

预期结果：

```text
metadata upgrade is not complete, as expected
```

### Case 2：显式执行 UPGRADE ACCOUNT ALL

目的：验证 MO Cloud 常见路径，即 `auto-upgrade=false`，由发版流程执行 `UPGRADE ACCOUNT ALL`。

| 参数 | 值 |
| --- | --- |
| `auto_upgrade` | `false` |
| `run_upgrade_account_all` | `true` |
| `expect_upgrade_complete` | `true` |
| `expected_metadata_tables` | `auto` |

预期结果：

```text
metadata upgrade completed
```

### Case 3：自动执行 schema upgrade

目的：验证 `auto-upgrade=true` 时 CN 自动完成 metadata/schema upgrade。

| 参数 | 值 |
| --- | --- |
| `auto_upgrade` | `true` |
| `run_upgrade_account_all` | `false` |
| `expect_upgrade_complete` | `true` |
| `expected_metadata_tables` | `auto` |

预期结果：

```text
metadata upgrade completed
```

### Case 4：3.x 小版本兼容性

目的：验证类似 `3.0.14 -> 3.0.16` 的升级不会错误要求 4.0 才引入的系统表。

| 参数 | 值 |
| --- | --- |
| `auto_upgrade` | `false` |
| `run_upgrade_account_all` | `true` |
| `expect_upgrade_complete` | `true` |
| `expected_metadata_tables` | `auto` |

预期结果：

```text
metadata upgrade completed
```

同时不应因为 `mo_feature_registry` 不存在而失败。

## 判断标准

测试通过需要满足：

1. 预期升级完成的 case 中，workflow 输出 `metadata upgrade completed`。
2. `mo_version.state = 2`。
3. `mo_upgrade.state = 2`。
4. 租户升级无未完成项。
5. 升级前写入的系统租户和普通租户数据均可读。
6. 当前目标版本要求的系统表存在。
7. 预期未完成的 case 中，workflow 能明确识别缺失的 metadata table，并以预期方式结束。

## 注意事项

1. 发布版本和 metadata schema version 可能不同，判断升级完成以 `mo_catalog.mo_version` 和 `mo_catalog.mo_upgrade` 为准。
2. `show account upgrade;` 不是 MatrixOne 支持的语法，测试不依赖该命令。
3. `mo_upgrade_tenant` 的字段在不同版本可能不同，测试通过 `show columns` 和兼容查询判断租户升级状态。
4. 每次 workflow run 都会使用独立 shared storage path，格式为：

```text
mo-nightly-gz-1308875761/mo-upgrade-path-${{ github.run_id }}/
```

