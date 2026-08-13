# 导入、导出、Stage 与外部数据

## dataio.load-and-export

- **支持状态:** supported-with-conditions
- **用户入口:** LOAD DATA INFILE/LOCAL/INLINE、SELECT INTO OUTFILE、客户端/服务端文件
- **支持证据:** [LOAD DATA](https://docs.matrixorigin.cn/en/v26.3.0.12/MatrixOne/Reference/SQL-Reference/Data-Manipulation-Language/load-data-infile/), [LOAD DATA INLINE](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/SQL-Reference/Data-Manipulation-Language/load-data-inline/)
- **支持范围:** 正式文档的 CSV/文本、LOCAL、INLINE、字段/行规则、SET/IGNORE/PARALLEL/STRICT 范围
- **限制条件:** 格式、字符集、客户端参数和对象存储条件按对应文档；不推断未文档化格式
- **状态与不变量:** 精确行数/值/类型/NULL；错误转换和约束遵守语句原子合同；临时/外部资源清理
- **测试分层:** load_data BVT；真实客户端/对象存储 MOTR scenario；吞吐/大文件用 big-data
- **仓库证据:** `repo:test/distributed/cases/load_data`, `repo:pkg/frontend`
- **关联能力:** 必需 `sql.data-types-and-conversion`、`schema.constraints`、`storage.object-storage-and-cache`；高风险取消、对象部分读取、IGNORE/STRICT
- **覆盖缺口:** 大数据只在吞吐、分片、内存或对象存储规模属于合同的时候需要

## dataio.stage-and-external-data

- **支持状态:** supported-with-conditions
- **用户入口:** CREATE/ALTER/DROP STAGE、`stage://`、正式 External Table/对象存储入口
- **支持证据:** MatrixOne Stage/External Table 官方文档、[兼容性矩阵](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)
- **支持范围:** 文档化的本地/S3-compatible/HDFS（对应入口支持时）对象引用、凭据和文件访问
- **限制条件:** 云厂商、URI、格式和认证条件必须引用目标文档；私有凭据不得进入测试证据
- **状态与不变量:** 权限和租户隔离；对象缺失/拒绝/超时正常返回；不泄露 secret；失败无残留对象
- **测试分层:** stage/load BVT、对象存储 scenario、网络/服务 failure 专用 workflow、规模读取 big-data
- **仓库证据:** `repo:test/distributed/cases/stage`, `repo:pkg/fileservice`, `repo:pkg/objectio`
- **关联能力:** 必需 `security.authorization-and-isolation`, `storage.object-storage-and-cache`; 高风险 credential、network、retry、cleanup
- **覆盖缺口:** 本地文件通过不能替代远端对象存储合同
