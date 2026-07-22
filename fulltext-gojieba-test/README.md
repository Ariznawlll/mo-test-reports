# MatrixOne GoJieba 全文索引测试设计

本目录包含基于现有 `fulltext测试设计.xlsx` 扩展整理的 GoJieba 全文索引测试设计。

## 文件

- [`gojieba全文索引测试设计.md`](./gojieba全文索引测试设计.md)

测试设计采用 Markdown 表格展示，内容分为四部分：

- `测试原则`：明确 GoJieba 的功能定位、双分词器执行原则和结果判定标准。
- `测试用例`：按功能、分词、查询、一致性、部署、异常、恢复和性能拆分的 81 条用例。
- `默认/ngram 与 GoJieba 对照基线`：相同数据下两种分词器的语义、索引和性能对照方法。
- `结果判定与记录要求`：区分确定性结果、模糊查询、分词结果和性能结果的通过标准。

## 覆盖范围

公共 FullText 能力使用默认/ngram 和 GoJieba 在同一数据集上分别执行；GoJieba 专项重点验证中文分词边界、词典发现、索引与查询分词一致性、混合中英文处理及异常恢复。

设计依据：

- MatrixOne GoJieba feature：<https://github.com/matrixorigin/matrixone/issues/24271>
- MatrixOne GoJieba implementation：<https://github.com/matrixorigin/matrixone/pull/24297>
