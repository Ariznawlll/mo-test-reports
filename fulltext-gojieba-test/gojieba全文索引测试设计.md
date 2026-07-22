# MatrixOne GoJieba 全文索引测试设计

> GoJieba 已完整实现，本质上是 FullText 的另一种分词器（word breaker）。测试以现有 FullText 能力为基线，使用默认/ngram 和 GoJieba 分别执行，并补充 GoJieba 分词及词典专项验证。

## 1. 测试原则

| 项目 | 说明 |
| --- | --- |
| 功能定位 | `WITH PARSER gojieba` 只改变分词方式，FullText 的 DDL、查询模式、评分、索引维护和恢复能力沿用公共实现。 |
| 覆盖方法 | 原则上复用全部 FullText 测试，在同一数据集上分别使用默认/ngram 与 GoJieba 建索引并执行查询。 |
| 确定性查询 | 对明确词项、Boolean 条件、Phrase、DML 后查询等场景，必须校验准确的文档 ID 或完整结果集合。 |
| 模糊查询 | 相关性评分和自然语言查询可能因分词不同产生合理的分数、顺序或结果差异；返回内容必须正确或合理，差异必须能由分词语义解释。 |
| GoJieba 专项 | 重点验证中文词边界、词典加载、`HMM=false`、索引侧与查询侧分词一致性、UTF-8 位置及混合中英文处理。 |
| 对照要求 | 除场景明确验证分词差异外，默认/ngram 与 GoJieba 不应出现无法解释的功能差异。 |

### 1.1 基本信息

| 项目 | 内容 |
| --- | --- |
| MatrixOne 基线 | `main`（设计依据：feature #24271 / PR #24297） |
| 功能入口 | `CREATE FULLTEXT INDEX ... WITH PARSER gojieba` |
| 分词实现 | 默认/ngram 走 SimpleTokenizer；GoJieba 使用静态中文词典分词，索引侧和查询侧均使用 `HMM=false`。 |
| 支持列类型 | CHAR、VARCHAR、TEXT、JSON、DATALINK；FullText 表必须有真实主键。 |
| 评分算法 | TF-IDF、BM25 |
| 部署依赖 | 五个 Jieba 词典文件；支持 `MO_JIEBA_DICT_DIR`、二进制同级 `dict` 和 FHS 目录。 |

### 1.2 执行矩阵

| 测试类型 | 默认/ngram | GoJieba | 通过标准 |
| --- | --- | --- | --- |
| 公共 FullText 能力 | 执行 | 使用相同数据和查询重新执行 | 确定性结果准确；模糊查询结果正确或合理，无无法解释的差异。 |
| GoJieba 分词与词典专项 | 不适用或仅作分词对照 | 执行 | token、位置、词典发现和查询语义符合 GoJieba 契约。 |
| 性能和大数据对照 | 在固定环境及数据快照上执行 | 在相同环境及数据快照上执行 | 结果正确、过程稳定，并完整记录两种分词器的指标。 |

### 1.3 覆盖范围

| 一级模块 | 用例数 | 主要覆盖内容 | 验证范围 |
| --- | ---: | --- | --- |
| 功能 | 12 | DDL、索引参数、支持类型、同步/异步索引 | 默认/ngram 与 GoJieba 对照 |
| 分词正确性 | 14 | 中文词边界、UTF-8 位置、多列边界、长 token 和空值 | GoJieba 专项 |
| 查询 | 24 | Natural Language、Boolean、Phrase、TF-IDF/BM25 及 SQL 组合 | 默认/ngram 与 GoJieba 对照 |
| 一致性 | 11 | DML、事务、并发和索引增量维护 | 默认/ngram 与 GoJieba 对照 |
| 部署 | 3 | 词典发现、容器布局和共享 tokenizer | GoJieba 专项 |
| 异常 | 5 | 词典缺失、初始化错误和故障恢复 | GoJieba 专项 |
| 恢复 | 4 | Snapshot、备份恢复、PITR 和升级切换 | 双分词器对照为主，切换场景为 GoJieba 专项 |
| 性能 | 8 | 构建耗时、索引规模、Top-K、并发和长稳 | 默认/ngram 与 GoJieba 对照 |
| **合计** | **81** |  |  |

### 1.4 参考资料

| 资料 | 地址或位置 |
| --- | --- |
| Feature | <https://github.com/matrixorigin/matrixone/issues/24271> |
| Implementation | <https://github.com/matrixorigin/matrixone/pull/24297> |
| Existing BVT | `test/distributed/cases/fulltext/gojieba.sql` |
| Source template | `fulltext测试设计.xlsx` |

## 2. 测试用例

### 2.1 功能（12 条）

| 编号 | 二级模块 | 测试场景 | 前置条件/数据 | 测试步骤 | 预期结果 | 验证范围 |
| --- | --- | --- | --- | --- | --- | --- |
| GJ-001 | DDL | 独立创建单列 gojieba 全文索引 | 开启 FullText；表含 bigint 主键和 varchar/text 列 | 执行 CREATE FULLTEXT INDEX ... WITH PARSER gojieba；执行 SHOW CREATE TABLE、DESC | 创建成功；SHOW CREATE TABLE 保留 WITH PARSER gojieba；隐藏索引表创建成功 | 默认/ngram 与 GoJieba 对照 |
| GJ-002 | DDL | 建表时定义 gojieba 全文索引 | 准备包含主键和 text 列的建表语句 | 在 CREATE TABLE 中使用 FULLTEXT(body) WITH PARSER gojieba；插入数据并查询 | 表和索引创建成功；插入数据可被 MATCH 检索 | 默认/ngram 与 GoJieba 对照 |
| GJ-003 | DDL | ALTER TABLE 增加 gojieba 全文索引 | 已存在有数据的表且尚无 FullText 索引 | ALTER TABLE ... ADD FULLTEXT INDEX ... WITH PARSER gojieba；查询历史数据 | 索引创建成功；存量数据完成分词并可检索 | 默认/ngram 与 GoJieba 对照 |
| GJ-004 | DDL | 删除 gojieba 全文索引 | 表上已存在 gojieba 全文索引 | DROP INDEX；检查 SHOW CREATE TABLE、索引元数据和隐藏表 | 索引定义和隐藏表均删除；源表数据不受影响 | 默认/ngram 与 GoJieba 对照 |
| GJ-005 | DDL | 多列 gojieba 全文索引 | 表含主键、title 和 body 两个文本列 | 创建 FULLTEXT(title,body) WITH PARSER gojieba；分别写入两列关键词并查询 | 两列内容均进入同一索引；MATCH 列集合与索引定义一致时正确命中 | 默认/ngram 与 GoJieba 对照 |
| GJ-006 | DDL | CHAR/VARCHAR/TEXT 类型覆盖 | 分别准备 char、varchar、text 列 | 逐类创建 gojieba 全文索引并执行中文、英文检索 | 三种类型均可创建索引并正确返回结果 | 默认/ngram 与 GoJieba 对照 |
| GJ-007 | DDL | JSON 列使用 gojieba parser | JSON 中包含中文 key/value、英文和数字 | 对 JSON 列创建 WITH PARSER gojieba；查询中文和英文 token | DDL 被接受；按 gojieba 文本路径产生可重复的 token；结果与 fulltext_index_tokenize 输出一致 | 默认/ngram 与 GoJieba 对照 |
| GJ-008 | DDL | DATALINK 列使用 gojieba parser | 准备本地、S3、stage 的中文 txt/docx/pdf 可解析文件 | 分别创建 DATALINK FullText 索引；检索文件中的中文词 | 提取纯文本后使用 gojieba 分词；三种存储位置检索结果一致 | 默认/ngram 与 GoJieba 对照 |
| GJ-009 | DDL | 缺少真实主键时创建索引 | 准备无主键或仅 fake primary key 的表 | 执行 CREATE FULLTEXT INDEX ... WITH PARSER gojieba | 创建失败，返回 primary key cannot be empty 类错误；不遗留隐藏表 | 默认/ngram 与 GoJieba 对照 |
| GJ-010 | DDL | 非法 parser 和 parser 大小写 | 准备合法 FullText 表 | 分别使用 GOJIEBA、GoJieBa 和不存在的 parser 名称创建索引 | 合法大小写被规范化为 gojieba；非法 parser 明确报错且不创建索引 | 默认/ngram 与 GoJieba 对照 |
| GJ-011 | DDL | 同列重复全文索引 | 同一列已存在 gojieba 全文索引 | 再次对相同列集合创建 gojieba 或 ngram 全文索引 | 拒绝相同列集合的重复 FullText 索引；原索引保持可用 | 默认/ngram 与 GoJieba 对照 |
| GJ-012 | DDL | 同步与 ASYNC gojieba 索引 | 环境支持异步 FullText/CDC | 分别创建同步和 ASYNC gojieba 索引；插入同一数据并轮询结果 | 同步索引事务内可用；异步索引在约定时间内最终可见且 token 一致 | 默认/ngram 与 GoJieba 对照 |

### 2.2 分词正确性（14 条）

| 编号 | 二级模块 | 测试场景 | 前置条件/数据 | 测试步骤 | 预期结果 | 验证范围 |
| --- | --- | --- | --- | --- | --- | --- |
| GJ-013 | 中文词典 | 标准中文句子精确分词 | 输入：我来到北京清华大学 | 调用 fulltext_index_tokenize({parser:gojieba}) 并按 pos 排序 | token 依次为 我、来到、北京、清华大学，另有 __DocLen；无 ngram 重叠片段 | GoJieba 专项 |
| GJ-014 | 中文词典 | 索引侧与查询侧均关闭 HMM | 准备词典已知词和 HMM 才可能合并的新词 | 比较 fulltext_index_tokenize 输出与 MATCH 查询解析结果 | 索引和查询均按 dictionary-only 规则切分；不存在仅查询侧生成的新词 | GoJieba 专项 |
| GJ-015 | UTF-8 位置 | 中文 token BytePos | 输入：我来到北京 | 读取每个 token 的 pos；执行无空格中文 phrase 查询 | 我、来到、北京位置分别为 0、3、9；phrase 使用相同位置差正确匹配 | GoJieba 专项 |
| GJ-016 | ASCII | 英文单词与大小写归一 | 输入：Hello, WORLD! | 调用 tokenizer 和 FullText 查询 | ASCII 段按 SimpleTokenizer 处理；token 为 hello、world；查询大小写不影响命中 | GoJieba 专项 |
| GJ-017 | 混合文本 | 中文、英文、数字和型号混排 | 输入：SGB11型号支持AI 2026版 | 检查 token、位置并分别搜索型号、中文词和 AI | ASCII token 保持完整并转小写；中文按词典分词；位置均落在正确 UTF-8 边界 | GoJieba 专项 |
| GJ-018 | 标点 | 中英文标点和多空格 | 输入含 ，。！？、,.!?、制表符、换行和连续空格 | 直接分词并建索引查询 | 分隔符不形成可搜索 token；前后有效词正确保留；无空 token | GoJieba 专项 |
| GJ-019 | 空值 | NULL、空串、仅空白和仅标点 | 分别插入 NULL、''、空白串和标点串 | 构建索引并查询；检查 fulltext_index_tokenize 行数 | 不产生普通词条、不 panic；文档长度标记行为稳定；其他文档结果不受污染 | GoJieba 专项 |
| GJ-020 | 重复词 | 同一文档重复中文词 | 输入：北京北京 北京 | 检查 token 位置、DocLen 和关键词得分 | 三个北京均有独立位置；DocLen 与 token 数一致；词频计分可重复 | GoJieba 专项 |
| GJ-021 | 长 token | 超过 MAX_TOKEN_SIZE 的 ASCII token | 准备超过 23 字节的连续英文/型号字符串 | 索引并读取 token；搜索截断值和原长值 | token 最多 23 字节且不越界；索引侧与查询侧使用相同截断规则；无 panic | GoJieba 专项 |
| GJ-022 | 长 token | 长中文词 UTF-8 安全截断 | 通过用户词典准备超过 23 字节的中文词 | 分词并检查 token 字节和 UTF-8 合法性 | 截断不切断 UTF-8 字符；索引与查询 token 一致 | GoJieba 专项 |
| GJ-023 | 多列边界 | 多列内容不形成跨列中文 phrase | title='我来到'，body='北京'；另有单列完整句对照行 | 创建 (title,body) 索引；查询 phrase "我来到北京" | 跨列行不匹配完整 phrase；单列连续文本行匹配 | GoJieba 专项 |
| GJ-024 | 多列边界 | 多列词条均可独立命中 | title 和 body 分别包含不同中文词 | 分别用 MATCH(title,body) 查询两个词 | 两个词均可命中同一文档；DocLen 覆盖两列 token 总量 | GoJieba 专项 |
| GJ-025 | 语言 | 简体中文、繁体中文和日韩字符 | 准备等义简繁体文本及日文、韩文文本 | 分别建索引并查询原文 token | 原文检索稳定；不隐式进行简繁转换；记录日/韩字符的实际切分契约 | GoJieba 专项 |
| GJ-026 | 对照 | gojieba 与 ngram token 对照 | 同一文本：我来到北京清华大学 | 先建 ngram 索引记录 token，再 drop index 创建 gojieba 索引记录 token | ngram 产生重叠 3 字符片段；gojieba 产生词典词；两者差异符合设计 | GoJieba 专项 |

### 2.3 查询（24 条）

| 编号 | 二级模块 | 测试场景 | 前置条件/数据 | 测试步骤 | 预期结果 | 验证范围 |
| --- | --- | --- | --- | --- | --- | --- |
| GJ-027 | Natural Language | 单个中文词检索 | 多文档中部分包含清华大学 | MATCH(body) AGAINST('清华大学' IN NATURAL LANGUAGE MODE) | 只返回包含 gojieba token 清华大学的文档；无 false positive | 默认/ngram 与 GoJieba 对照 |
| GJ-028 | Natural Language | 多个中文词检索和相关度 | 文档分别包含 0/1/2 个查询词 | 查询 北京 清华大学 并输出 score、排序 | 命中文档集合符合 NL 语义；包含更多/更高频关键词的文档得分合理且稳定 | 默认/ngram 与 GoJieba 对照 |
| GJ-029 | Natural Language | 词内子串与 ngram 对照 | 索引词为清华大学，查询词为华大 | 分别使用 ngram 和 gojieba 索引执行同一查询 | 记录并确认 gojieba 不保证词内子串召回；ngram 可按前缀/片段规则命中 | 默认/ngram 与 GoJieba 对照 |
| GJ-030 | Natural Language | 未登录词查询 | 准备词典中不存在的业务名称和设备型号 | 索引后查询完整词、拆分词和前缀 | 结果与 dictionary-only 实际切分一致；索引侧和查询侧无分词漂移 | 默认/ngram 与 GoJieba 对照 |
| GJ-031 | Natural Language | MATCH 用于 WHERE 与投影 | 已有 gojieba 索引和多条中文文档 | 分别在 WHERE、SELECT 投影中使用 MATCH，并组合普通列 | 结果集合一致；投影返回正确 score；不重复执行产生不同结果 | 默认/ngram 与 GoJieba 对照 |
| GJ-032 | Natural Language | 普通过滤条件与 LIMIT | 数据含 category、时间和大量命中文档 | MATCH 与普通谓词、ORDER BY、LIMIT 组合 | 过滤和 LIMIT 结果正确；执行计划使用 FullText 路径；无遗漏 | 默认/ngram 与 GoJieba 对照 |
| GJ-033 | Boolean | 必选词和可选词 | 准备只含一个词及同时含两个词的文档 | 执行 '+北京 清华大学' 和 '+北京 +清华大学' | 单加号要求北京；双加号要求两个词均存在；结果与预期集合一致 | 默认/ngram 与 GoJieba 对照 |
| GJ-034 | Boolean | 排除词 | 准备同时含正向词和排除词的文档 | 执行 '+北京 -上海' | 只返回包含北京且不包含上海的文档 | 默认/ngram 与 GoJieba 对照 |
| GJ-035 | Boolean | 降低相关度操作符 | 准备包含主词以及包含/不包含降权词的文档 | 执行 '+北京 ~大学' 并比较 score | 所有必须命中文档保留；包含降权词的文档排名降低 | 默认/ngram 与 GoJieba 对照 |
| GJ-036 | Boolean | 权重操作符和分组 | 准备覆盖 >、<、括号组合的数据 | 执行 '+北京 +(>清华 <上海)' | 布尔集合正确；清华相关文档得分高于上海相关文档 | 默认/ngram 与 GoJieba 对照 |
| GJ-037 | Boolean | 前缀查询 | 准备词典词：清华、清华大学、清华园 | 执行 '清华*' IN BOOLEAN MODE | 返回具有对应 token 前缀的文档；不误匹配无关词 | 默认/ngram 与 GoJieba 对照 |
| GJ-038 | Phrase | 两词无空格中文 phrase | 文档含 我来到北京、我很快来到北京 | 查询 "我来到" | 仅 token 位置连续的文档匹配；中间插词的文档不匹配 | 默认/ngram 与 GoJieba 对照 |
| GJ-039 | Phrase | 三词中文 phrase | 文档含 我来到北京 和词序变化对照 | 查询 "我来到北京" | 只匹配 token 顺序和 byte-position 差一致的文档 | 默认/ngram 与 GoJieba 对照 |
| GJ-040 | Phrase | 单词 phrase | 多文档含清华大学 | 查询 "清华大学" | 行为与单 token 精确检索一致 | 默认/ngram 与 GoJieba 对照 |
| GJ-041 | Phrase | 不存在或词序错误的 phrase | 准备上海清华大学、清华大学上海等对照文本 | 查询 "上海北京" 和逆序 phrase | 不返回仅包含全部词但位置不连续/顺序错误的文档 | 默认/ngram 与 GoJieba 对照 |
| GJ-042 | Phrase | 英文 phrase 回归 | 文档含 is not red 及 is very not red | 在 gojieba 索引上查询 "is not red" | ASCII phrase 仍按空格和位置匹配；不受中文 parser 改动影响 | 默认/ngram 与 GoJieba 对照 |
| GJ-043 | 评分 | TF-IDF 中文结果与排序 | 设置 ft_relevancy_algorithm=TF-IDF，准备词频/文档频率不同的数据 | 执行中文单词和多词查询并记录 score | score 非负且排序符合 TF-IDF 预期；重复执行稳定 | 默认/ngram 与 GoJieba 对照 |
| GJ-044 | 评分 | BM25 中文结果与排序 | 设置 ft_relevancy_algorithm=BM25，准备不同文档长度和词频 | 执行相同查询并记录 score | BM25 能在 gojieba 索引上工作；短文/词频影响符合算法预期 | 默认/ngram 与 GoJieba 对照 |
| GJ-045 | 评分 | TF-IDF 与 BM25 切换 | 同一数据和 gojieba 索引 | 切换 session 变量后重复核心查询 | 结果集合一致；允许排序/score 不同；无须重建索引 | 默认/ngram 与 GoJieba 对照 |
| GJ-046 | SQL 组合 | GROUP BY、HAVING 和聚合 | 文档带分类列且多行命中 | MATCH 与 COUNT、GROUP BY、HAVING 组合 | 分组和聚合结果正确；无重复 doc_id 或漏行 | 默认/ngram 与 GoJieba 对照 |
| GJ-047 | SQL 组合 | JOIN 与派生表 | FullText 表与维表通过主键关联 | MATCH 结果与维表 JOIN，并在 derived table 外过滤 | JOIN 结果正确；FullText 条件不丢失；执行计划无异常全表放大 | 默认/ngram 与 GoJieba 对照 |
| GJ-048 | SQL 组合 | CTE 与 UNION ALL | 准备两个查询分支 | 在 CTE 中使用 MATCH；两个 MATCH 分支 UNION ALL | 各分支结果正确且可重复；连接/receiver 正常释放 | 默认/ngram 与 GoJieba 对照 |
| GJ-049 | SQL 组合 | DISTINCT、ORDER BY 与 MATCH | 准备重复投影值和不同 score | 执行 DISTINCT + ORDER BY + MATCH 组合 | 修复前按 #25890 标识预期失败；修复后应使用 FullText 索引且结果正确 | 默认/ngram 与 GoJieba 对照 |
| GJ-050 | SQL 组合 | IN 子查询中的 MATCH | 外表通过 IN 引用含 MATCH 的子查询 | 执行 WHERE id IN (SELECT ... WHERE MATCH(...)) | 修复前按 #25891 标识预期失败；修复后 MATCH 被重写为 fulltext_index_scan | 默认/ngram 与 GoJieba 对照 |

### 2.4 一致性（11 条）

| 编号 | 二级模块 | 测试场景 | 前置条件/数据 | 测试步骤 | 预期结果 | 验证范围 |
| --- | --- | --- | --- | --- | --- | --- |
| GJ-051 | INSERT | 索引创建后新增中文文档 | 已存在同步 gojieba 索引 | INSERT 新文档后立即查询新词 | 新文档可见且 token/DocLen 正确；旧文档不受影响 | 默认/ngram 与 GoJieba 对照 |
| GJ-052 | UPDATE | 更新被索引列 | 已有可命中的旧关键词 | 将正文从旧词更新为新词；分别查询旧词和新词 | 旧词不再命中；新词命中；无重复倒排记录 | 默认/ngram 与 GoJieba 对照 |
| GJ-053 | UPDATE | 更新非索引列 | 表含未参与索引的状态列 | 只更新状态列并重复 FullText 查询 | 索引结果和 score 不变；不产生无意义重建或重复记录 | 默认/ngram 与 GoJieba 对照 |
| GJ-054 | UPDATE | 更新主键 | 普通/联合主键表均有 gojieba 索引 | 更新主键后查询关键词并检查 doc_id | 仅新主键返回；旧主键对应倒排记录清除 | 默认/ngram 与 GoJieba 对照 |
| GJ-055 | DELETE | 删除命中文档 | 多文档命中相同中文词 | DELETE 其中一行后查询并检查 count/score | 删除文档不再返回；其余文档正常；统计不包含残留记录 | 默认/ngram 与 GoJieba 对照 |
| GJ-056 | TRUNCATE | 清空并重新插入 | 表含 gojieba 索引和数据 | TRUNCATE TABLE；确认空结果；重新插入并查询 | 清空后无残留命中；重新插入后索引恢复工作 | 默认/ngram 与 GoJieba 对照 |
| GJ-057 | 事务 | 事务提交后的索引可见性 | 同步 gojieba 索引；两个独立 session | 事务内 INSERT/UPDATE；提交前后分别从两个 session 查询 | 遵循 MO 隔离级别；提交后源表与全文索引原子一致 | 默认/ngram 与 GoJieba 对照 |
| GJ-058 | 事务 | 事务回滚不污染索引 | 同步 gojieba 索引 | 事务内 INSERT/UPDATE/DELETE 后 ROLLBACK；查询新旧关键词 | 回滚操作不残留倒排记录；结果恢复到事务前 | 默认/ngram 与 GoJieba 对照 |
| GJ-059 | 事务 | 建索引事务提交与回滚 | 有存量中文数据 | 在事务中 CREATE FULLTEXT INDEX，分别 COMMIT/ROLLBACK | 行为符合 MO DDL 事务语义；失败/回滚路径不遗留半成品隐藏表 | 默认/ngram 与 GoJieba 对照 |
| GJ-060 | 并发 | 并发 DML 与查询 | 10 个写 session、20 个读 session，共享 gojieba 索引 | 持续 INSERT/UPDATE/DELETE，同时执行中文 MATCH 和一致性校验 | 无 panic、死锁或重复/丢失结果；收敛后索引与源表一致 | 默认/ngram 与 GoJieba 对照 |
| GJ-061 | 并发 | 并发创建/删除索引与查询 | 准备可重复初始化的数据集 | 索引创建或删除期间发起 MATCH，并重复 20 轮 | 返回成功结果或明确的索引状态错误；无 CN panic、元数据残留和连接卡死 | 默认/ngram 与 GoJieba 对照 |

### 2.5 部署（3 条）

| 编号 | 二级模块 | 测试场景 | 前置条件/数据 | 测试步骤 | 预期结果 | 验证范围 |
| --- | --- | --- | --- | --- | --- | --- |
| GJ-062 | 词典 | MO_JIEBA_DICT_DIR 显式路径 | 五个词典文件完整，环境变量指向该目录 | 启动 mo-service；首次创建/查询 gojieba 索引 | 词典从环境变量目录加载；分词结果符合该词典；无模块缓存绝对路径依赖 | GoJieba 专项 |
| GJ-063 | 词典 | 二进制同级 dict 目录 | 取消环境变量；将 dict 放在 mo-service 同级 | 启动服务并执行 gojieba 分词 | 自动发现同级 dict；功能正常 | GoJieba 专项 |
| GJ-064 | 词典 | 容器镜像词典布局 | 使用官方 CPU/GPU 镜像 | 检查 /usr/local/share/jieba 和 MO_JIEBA_DICT_DIR；执行查询 | 镜像包含全部词典；CPU/GPU 镜像行为一致 | GoJieba 专项 |

### 2.6 异常（5 条）

| 编号 | 二级模块 | 测试场景 | 前置条件/数据 | 测试步骤 | 预期结果 | 验证范围 |
| --- | --- | --- | --- | --- | --- | --- |
| GJ-065 | 词典 | 词典文件缺失 | 删除或隐藏五个文件中的任意一个 | 首次调用 gojieba tokenizer 或创建索引 | 返回 jieba dictionary not available 类错误；不发生 cgo 路径 panic；不遗留索引 | GoJieba 专项 |
| GJ-066 | 词典 | 无效环境变量回退 | MO_JIEBA_DICT_DIR 指向不含 jieba.dict.utf8 的目录，同时存在有效同级 dict | 启动服务并分词 | 忽略无效环境变量并回退到有效目录；功能正常 | GoJieba 专项 |
| GJ-067 | 资源 | 共享 tokenizer 并发初始化 | 进程首次使用 gojieba，尚未加载词典 | 100 并发请求同时触发 HMM=false tokenizer | 只初始化一个共享实例；全部请求成功；无 data race、重复 Free 或内存异常 | GoJieba 专项 |
| GJ-068 | 资源 | 词典初始化错误缓存 | 首次加载时词典缺失，随后运行期间补回文件 | 连续两次获取 shared tokenizer | 同一 useHmm 模式返回缓存错误且不在进程内静默重试；重启后使用完整词典恢复 | GoJieba 专项 |
| GJ-069 | 故障 | 索引构建期间 CN/TN/LogService 故障 | 大表创建同步或异步 gojieba 索引 | 构建过程中分别重启 CN、TN、LogService；恢复后检查任务和元数据 | 无数据错误或半成品索引；按设计重试或失败并可清理重建；无 panic | GoJieba 专项 |

### 2.7 恢复（4 条）

| 编号 | 二级模块 | 测试场景 | 前置条件/数据 | 测试步骤 | 预期结果 | 验证范围 |
| --- | --- | --- | --- | --- | --- | --- |
| GJ-070 | Snapshot | Snapshot restore 保留 gojieba 分词索引 | 创建 gojieba 索引并写入中文 phrase 数据后创建 snapshot | 修改/删除数据，再恢复 snapshot；查询恢复前关键词和 phrase | 恢复后的源数据和 gojieba 查询结果均与 snapshot 时刻一致 | 默认/ngram 与 GoJieba 对照 |
| GJ-071 | 备份恢复 | 数据库/表级备份恢复 | 数据库含同步 gojieba 索引和词典中文数据 | 执行备份、删除原对象、恢复；执行核心查询 | 索引定义、parser 参数、隐藏表数据和查询结果完整恢复 | 默认/ngram 与 GoJieba 对照 |
| GJ-072 | PITR | PITR 到 DML 前后时间点 | gojieba 索引表执行 INSERT/UPDATE/DELETE 并记录时间点 | 恢复到各时间点并执行 MATCH | 每个恢复点的源表与全文索引一致；无新旧 token 混杂 | 默认/ngram 与 GoJieba 对照 |
| GJ-073 | 升级 | 旧版本 ngram 索引升级后切换 gojieba | 旧版本创建 ngram FullText 并升级到包含 gojieba 的版本 | 验证旧索引可查；drop index 后创建 gojieba；复跑同一查询 | 旧索引兼容；切换 gojieba 后结果符合新分词语义；无元数据冲突 | GoJieba 专项 |

### 2.8 性能（8 条）

| 编号 | 二级模块 | 测试场景 | 前置条件/数据 | 测试步骤 | 预期结果 | 验证范围 |
| --- | --- | --- | --- | --- | --- | --- |
| GJ-074 | 索引构建 | 同数据 ngram/gojieba 构建耗时对照 | 固定中文语料，10 万、100 万、1000 万行 | 普通索引测完后 drop index；创建 gojieba；记录各规模构建耗时 | 两轮均成功且结果正确；输出耗时和增幅，不设置未经评审的硬阈值 | 默认/ngram 与 GoJieba 对照 |
| GJ-075 | 索引规模 | 隐藏索引行数和存储量对照 | 与构建耗时用例使用相同快照数据 | 分别统计 ngram/gojieba token 行数、对象存储量和压缩后大小 | gojieba token 构成符合词典分词；输出行数/存储比值并可复现 | 默认/ngram 与 GoJieba 对照 |
| GJ-076 | 查询 | 高频中文词 Top-K | 1000 万行，控制命中率 1%、10%、50% | 两种 parser 分别执行单词 Top-K，预热后各 10 轮 | 结果语义按各 parser 基线正确；记录 p50/p95、扫描量、内存和 profile | 默认/ngram 与 GoJieba 对照 |
| GJ-077 | 查询 | 低频词与未登录词查询 | 准备低频词、业务型号和未登录词 | 分别执行 ngram/gojieba 查询并记录结果和耗时 | 解释召回差异；无 gojieba 查询侧/索引侧 token 不一致；输出性能对照 | 默认/ngram 与 GoJieba 对照 |
| GJ-078 | 查询 | Boolean 多关键词和中文 phrase | 准备 2、5、10 个关键词及 2/3/5 token phrase | 预热后循环执行并记录 p50/p95 | 结果稳定；耗时和内存无随轮次持续增长；phrase 无组合爆炸 | 默认/ngram 与 GoJieba 对照 |
| GJ-079 | 并发 | 10/50/100 并发查询 | 固定大数据快照和查询集 | 对 ngram/gojieba 分别运行阶梯并发，记录 QPS、p95、错误率、CN 内存 | 无错误、OOM 或 panic；输出两种 parser 并发能力对照 | 默认/ngram 与 GoJieba 对照 |
| GJ-080 | 稳定性 | 长时间混合查询内存稳定性 | 多 CN 环境；NL/Boolean/phrase 混合负载 | 持续 2 小时运行，监控 RSS、mpool、goroutine、重启和错误日志 | 无持续内存增长、OOM、panic、CN 重启或 tokenizer 资源泄漏 | 默认/ngram 与 GoJieba 对照 |
| GJ-081 | DML | 大数据增量维护 | 1000 万行 gojieba 索引；持续批量插入/更新/删除 | 记录写入吞吐、索引可见延迟和查询正确性 | 同步/异步模式符合可见性约定；最终索引与源表一致；无积压失控 | 默认/ngram 与 GoJieba 对照 |

## 3. 默认/ngram 与 GoJieba 对照基线

| 对比项 | 默认/ngram | GoJieba | 验证方法 | 数据规模 | 记录指标 | 通过标准 |
| --- | --- | --- | --- | --- | --- | --- |
| 分词规则 | 连续 3 个中文字符的重叠窗口 | 静态词典分词，HMM=false | 对同一文本执行 fulltext_index_tokenize 并按 pos 排序 | 固定短文本 | token、pos、DocLen | 输出符合各自契约；必须保留结果证据 |
| 示例：我来到北京清华大学 | 我来到、来到北、到北京、北京清、京清华、清华大、华大学 | 我、来到、北京、清华大学 | 分别建索引并读取隐藏索引词条 | 1 行 | token 数和内容 | 与左侧预期一致；gojieba 不应产生 ngram 片段 |
| 索引构建 | 先创建并完成查询后 DROP INDEX | 在同一数据快照上重新创建 | 单机/TKE 分别运行 | 10 万/100 万/1000 万行 | 耗时、CPU、峰值内存 | 无失败；输出对照数据；不预设未经评审的性能门槛 |
| 索引规模 | 统计隐藏表 token 行数和存储 | 统计隐藏表 token 行数和存储 | 相同数据、相同压缩和副本配置 | 同上 | 行数、对象大小、压缩后大小 | 结果可复现且无数据错误；记录 gojieba/ngram 比值 |
| 高频词 Top-K | 字符片段召回 | 词典词召回 | 命中率 1%/10%/50%，预热后各 10 轮 | 1000 万行 | p50/p95、扫描量、RSS | 各自语义结果正确；无 OOM/panic；保留 profile |
| 词内子串 | 短查询可能转前缀匹配 | 不保证匹配完整词内部子串 | 以清华大学/华大为对照 | 固定功能集 | 结果集合 | 差异与 parser 语义一致；不能将差异误判为 bug |
| 未登录词 | 不依赖词典 | 按 dictionary-only 实际切分 | 业务型号和专有名词集 | 1 万词 | 召回率、token 一致性 | 索引侧与查询侧无漂移；开发确认词典策略 |

## 4. 结果判定与记录要求

| 结果类型 | 记录内容 | 判定要求 |
| --- | --- | --- |
| 确定性功能结果 | SQL、预期文档 ID/结果集合、实际结果 | 实际结果必须与预期完全一致。 |
| 模糊或相关性结果 | 查询词、两种分词器 token、文档 ID、score 和排序 | 结果应正确或合理；差异必须能由 token、评分或分词边界解释。 |
| 分词结果 | token、token position、byte position、DocLen | 索引侧与查询侧结果一致，并符合对应分词器契约。 |
| 性能结果 | 数据版本、环境配置、耗时、吞吐、p50/p95、CPU、内存和索引规模 | 两种分词器必须使用同一数据快照和配置，结果可复现且无 OOM、panic 或数据错误。 |
