# 导入、导出、Stage 与外部数据

## dataio.load-and-export

- **Status:** supported-with-conditions
- **User entry:** LOAD DATA INFILE/LOCAL/INLINE、SELECT INTO OUTFILE、客户端/服务端文件
- **Support evidence:** [LOAD DATA](https://docs.matrixorigin.cn/en/v26.3.0.12/MatrixOne/Reference/SQL-Reference/Data-Manipulation-Language/load-data-infile/), [LOAD DATA INLINE](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/SQL-Reference/Data-Manipulation-Language/load-data-inline/)
- **Scope:** 正式文档的 CSV/文本、LOCAL、INLINE、字段/行规则、SET/IGNORE/PARALLEL/STRICT 范围
- **Limitations:** 格式、字符集、客户端参数和对象存储条件按对应文档；不推断未文档化格式
- **State and invariants:** 精确行数/值/类型/NULL；错误转换和约束遵守语句原子合同；临时/外部资源清理
- **Test routing:** load_data BVT；真实客户端/对象存储 MOTR scenario；吞吐/大文件用 big-data
- **Repository evidence:** `repo:test/distributed/cases/load_data`, `repo:pkg/frontend`
- **Interactions:** required `sql.data-types-and-conversion`, `schema.constraints`, `storage.object-storage-and-cache`; high-risk cancel、partial object read、IGNORE/STRICT
- **Coverage gaps:** 大数据只在吞吐、分片、内存或对象存储规模属于合同的时候需要

## dataio.stage-and-external-data

- **Status:** supported-with-conditions
- **User entry:** CREATE/ALTER/DROP STAGE、`stage://`、正式 External Table/对象存储入口
- **Support evidence:** MatrixOne Stage/External Table official documentation, [Compatibility Matrix](https://docs.matrixorigin.cn/en/v26.3.0.13/MatrixOne/Reference/mysql-compatibility-matrix/)
- **Scope:** 文档化的本地/S3-compatible/HDFS（对应入口支持时）对象引用、凭据和文件访问
- **Limitations:** 云厂商、URI、格式和认证条件必须引用目标文档；私有凭据不得进入测试证据
- **State and invariants:** 权限和租户隔离；对象缺失/拒绝/超时正常返回；不泄露 secret；失败无残留对象
- **Test routing:** stage/load BVT、对象存储 scenario、网络/服务 failure 专用 workflow、规模读取 big-data
- **Repository evidence:** `repo:test/distributed/cases/stage`, `repo:pkg/fileservice`, `repo:pkg/objectio`
- **Interactions:** required `security.authorization-and-isolation`, `storage.object-storage-and-cache`; high-risk credential、network、retry、cleanup
- **Coverage gaps:** 本地文件通过不能替代远端对象存储合同
