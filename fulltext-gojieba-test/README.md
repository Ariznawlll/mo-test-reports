# MatrixOne GoJieba 全文索引测试设计

本目录包含基于现有 `fulltext测试设计.xlsx` 扩展整理的 GoJieba 全文索引专项测试设计。

## 文件

- [`gojieba全文索引测试设计.md`](./gojieba全文索引测试设计.md)

测试设计以纯 Markdown 展示，不使用表格，内容分为三个部分：

- `说明与覆盖`：功能背景、覆盖模块、优先级和回归层级统计。
- `测试用例`：81 条详细用例，包含前置条件、步骤、预期结果、优先级和自动化建议。
- `ngram 与 gojieba 对照基线`：相同数据下两种 parser 的语义及性能对照方法。

## 覆盖范围

覆盖 DDL、中文分词契约、Natural Language/Boolean/Phrase 查询、TF-IDF/BM25、DML 与事务一致性、词典部署与异常处理、Snapshot/PITR/备份恢复、单机与 TKE 性能及大数据稳定性。

设计依据：

- MatrixOne GoJieba feature：<https://github.com/matrixorigin/matrixone/issues/24271>
- MatrixOne GoJieba implementation：<https://github.com/matrixorigin/matrixone/pull/24297>

所有用例状态默认为“未执行”；已知未修复查询形态以 `Issue Skip` 标注，不作为当前功能通过结论。
