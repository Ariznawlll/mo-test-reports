# PostgreSQL 全文索引对比测试当前进度

记录时间：2026-07-24
测试服务器：`mo-srv-129`
当前状态：PostgreSQL 数据导入、全文索引构建和单用户查询基线已完成；MatrixOne 对照结果待采集。

## 1. 测试口径

本轮目标是固定中文 Jieba 类全文检索路径，对比 PostgreSQL 和 MatrixOne 的数据库性能，不比较 `ngram` 与 `jieba` 两种分词器。

需要准确记录实现差异：

- PostgreSQL：`pg_jieba` 的 `jiebacfg` 配置，底层为 `cppjieba`；
- MatrixOne：被测版本的 `gojieba` 实现；
- 两者不是同一个库，不能宣称分词实现逐字节等价；本轮属于端到端中文全文检索性能对比。

后续 PG 与 MatrixOne 应使用相同原始数据、相同查询集合、相同 CPU/内存资源和相同磁盘等级，并分开运行，避免相互争抢资源。

## 2. 测试服务器资源

| 项目 | 规格 |
|---|---|
| CPU | 2 × Intel Xeon Silver 4314 @ 2.40GHz |
| CPU 拓扑 | 32 个物理核、64 个逻辑 CPU |
| NUMA | 2 个 NUMA 节点 |
| 内存 | 251 GiB |
| Swap | 无 |
| 数据盘 | `/data4`，约 3.5T NVMe，测试时约 1.6T 可用 |
| 测试目录 | `/data4/weilu/fulltext-benchmark` |

## 3. 数据集

使用公开的 THUIR/T2Ranking 中文 passage ranking 数据集：

```text
/data4/weilu/fulltext-benchmark/dataset/T2Ranking
```

本轮使用：

- `data/collection.tsv`：2,303,643 条文档段落；
- `data/queries.dev.tsv`：开发查询集合；
- `data/qrels.dev.tsv`；
- `data/qrels.retrieval.dev.tsv`。

当前性能基线使用 `queries.dev.tsv` 的前 1000 条查询。Recall、MRR、NDCG 等质量指标尚未采集。

## 4. PostgreSQL 测试实例

| 项目 | 当前值 |
|---|---|
| 版本 | PostgreSQL 14.4 |
| 实例 | Docker `pg-fulltext-benchmark` |
| 端口 | `127.0.0.1:55432` |
| 数据目录 | `/data4/weilu/fulltext-benchmark/pg-docker/data` |
| Docker CPU 上限 | 64 个逻辑 CPU |
| Docker 内存上限 | 240 GiB |
| Docker Swap | 0 |
| 中文扩展 | `pg_jieba` |

PG 内部参数：

```text
shared_buffers=16GB
effective_cache_size=48GB
work_mem=32MB
maintenance_work_mem=4GB
max_connections=100
max_worker_processes=16
max_parallel_workers=16
max_parallel_workers_per_gather=4
max_parallel_maintenance_workers=4
```

说明：`64 CPU / 240 GiB` 是 Docker 资源上限，不代表测试过程中会立即占满这些资源；PG 内部并行参数也会影响实际 CPU 使用。

## 5. 数据导入结果

```text
COPY 2303643
导入耗时：1:34.01
退出状态：0
```

导入核对：

```text
doc_count：2303643
min_id：0
max_id：2303642
```

存储占用：

| 项目 | 大小 |
|---|---:|
| `documents` 表 | 3051 MB |
| 主键索引 | 49 MB |
| 总大小 | 3101 MB |
| `ANALYZE documents` | 2.77 秒 |

## 6. 全文索引构建结果

创建语句：

```sql
CREATE INDEX documents_fts_gin
ON documents
USING GIN (to_tsvector('jiebacfg', body));
```

结果：

| 指标 | 结果 |
|---|---:|
| 索引名称 | `documents_fts_gin` |
| 索引类型 | GIN |
| 分词配置 | `jiebacfg` |
| 创建耗时 | 36 分 04.82 秒 |
| 索引大小 | 1221 MB |
| `indisvalid` | `true` |
| `indisready` | `true` |

索引已经有效并可用于查询。

## 7. PG 单用户查询性能基线

测试脚本：

```text
/data4/weilu/fulltext-benchmark/scripts/pg_query_benchmark_seq.sh
```

测试内容：

- 1000 条中文查询；
- `plainto_tsquery('jiebacfg', query)`；
- GIN 全文过滤；
- `ts_rank_cd` 相关性排序；
- 取 Top 100；
- 单用户顺序执行。

结果：

| 指标 | 结果 |
|---|---:|
| 查询数量 | 1000 |
| 总耗时 | 78.020 秒 |
| QPS | 12.82 |
| 平均延迟 | 78.010 ms |
| P50 | 3.259 ms |
| P95 | 326.998 ms |
| P99 | 1361.235 ms |
| 最少命中数 | 0 |
| 最多命中数 | 100 |

资源监控为 PG 容器专属监控：

| 指标 | 结果 |
|---|---:|
| CPU 峰值 | 400.44%（约 4 个逻辑 CPU） |
| 内存峰值 | 5.221 GiB |
| 内存占容器上限 | 约 2.18% |

结果解读：

- 12.82 QPS 是单用户顺序执行基线，不是最大并发吞吐；
- P50 为 3.259 ms，但 P99 为 1.361 秒，存在明显长尾查询；
- 本次查询并未使用满 16 个并行 worker，后续需要做 4/8/16/32/64 并发测试；
- `min_hits=0` 表示部分查询没有匹配文档，不表示 SQL 执行失败。

日志位置：

```text
/data4/weilu/fulltext-benchmark/results/pg/query_seq_1000.log
/data4/weilu/fulltext-benchmark/results/pg/query_seq_1000_resource.log
```

## 8. 当前已完成与未完成项

已完成：

- 129 服务器资源确认；
- T2Ranking 数据下载和校验；
- PostgreSQL 14.4 独立 Docker 实例；
- 2,303,643 条数据导入；
- `ANALYZE`；
- `pg_jieba` GIN 全文索引构建；
- 索引大小和有效性确认；
- 1000 条查询单用户 QPS、平均延迟、P50/P95/P99；
- PG 容器 CPU 和内存峰值采集。

待完成：

1. 单用户基线重复 3 次并取中位数；
2. 4、8、16、32、64 并发查询 QPS 和 P95/P99；
3. INSERT、UPDATE、DELETE 和索引维护性能；
4. 读写混合负载；
5. 长时间稳定性；
6. MatrixOne 使用同一数据和查询集的对照测试；
7. 如需要检索质量，再计算 Recall@K、MRR@K、NDCG@K。

## 9. 当前结论

PG 端已经具备可复现的中文全文索引性能基线：

```text
2,303,643 条数据
GIN + pg_jieba
索引构建：36 分 04.82 秒
索引大小：1221 MB
单用户查询：12.82 QPS
P50：3.259 ms
P95：326.998 ms
P99：1361.235 ms
```

这组结果只能作为 PostgreSQL 单用户基线。完成并发测试和 MatrixOne 同口径测试后，才能形成最终的数据库性能对比结论。
