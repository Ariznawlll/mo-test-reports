# Checkpoint CSV Dump 工具使用文档

## 概述

`mo-tool ckp` 是从 MatrixOne checkpoint 数据离线导出 CSV 的命令行工具。支持以表、database、租户（account）为单位导出，mo-data 可以是本地目录或远程 S3/MinIO，可指定时间戳导出历史快照数据。

---

## 一、构建

```bash
make mo-tool
```

构建产物为 `./mo-tool`。

---

## 二、以表为单位 dump

### 2.1 命令

```bash
./mo-tool ckp dump --table-id=<TABLE_ID> [选项] <mo-data路径>
```

### 2.2 参数说明

| 参数 | 必需 | 说明 |
|------|------|------|
| `--table-id` | 是 | MatrixOne 内部 table_id，可从 `mo_tables` 系统表或交互式 viewer 中获取 |
| `--ts` | 否 | 快照时间戳。不指定则使用最新的 checkpoint 时间戳 |
| `-o` / `--output` | 否 | 输出路径。纯 CSV 模式指定文件路径，`--load-script` 模式指定目录（工具自动生成文件名）。不指定则输出到 stdout |
| `--header` | 否 | 在 CSV 第一行输出列名头行 |
| `--meta-comments` | 否 | 在 CSV 文件头部输出 DDL 和行数统计注释（以 `--` 开头） |
| `--row-order` | 否 | 行排序方式：`storage`（默认，流式按存储顺序）或 `lexical`（按可见列字典序排序） |
| `--load-script` | 否 | 切换为 LOAD 脚本输出模式：生成包含 CREATE DATABASE + CREATE TABLE + LOAD DATA 的 SQL 文件 |
| `--no-load` | 否 | 配合 `--load-script` 使用，跳过 LOAD DATA 语句，只输出 DDL |

### 2.3 示例

**导出到文件**：

```bash
./mo-tool ckp dump --table-id=272535 --header -o /tmp/employees.csv /path/to/mo-data
```

**导出到 stdout**：

```bash
./mo-tool ckp dump --table-id=272535 --header /path/to/mo-data
```

**指定时间戳导出**：

```bash
./mo-tool ckp dump --table-id=272535 --ts=1781084792256166694:1 --header -o /tmp/employees.csv /path/to/mo-data
```

**生成 LOAD 脚本（含建库建表 + LOAD DATA）**：

```bash
./mo-tool ckp dump --table-id=272535 --load-script -o /tmp/ /path/to/mo-data
```

**带 DDL 元数据注释导出**：

```bash
./mo-tool ckp dump --table-id=272535 --header --meta-comments -o /tmp/employees.csv /path/to/mo-data
```

此时输出文件头部会包含：

```text
-- CREATE TABLE employees (id INT PRIMARY KEY, name VARCHAR(100), ...)
-- Database: test_ckp
-- Table: employees
-- Visible rows: 103 (deleted: 0, physical: 103)
id,name,age,salary,department,hire_date,is_active
...
```

### 2.4 输出位置

| 模式 | `-o` 含义 | 输出文件 |
|------|----------|---------|
| 纯 CSV（默认） | 文件路径 | `-o /tmp/employees.csv` → `/tmp/employees.csv` |
| `--load-script` | 目录路径 | `-o /tmp/` → `/tmp/restore.sql` |

未指定 `-o` 时输出到 stdout。

---

## 三、以 database 为单位 dump

### 3.1 命令

```bash
./mo-tool ckp dump --database-id=<DB_ID> --output-dir=<DIR> [选项] <mo-data路径>
```

### 3.2 参数说明

| 参数 | 必需 | 说明 |
|------|------|------|
| `--database-id` | 是 | Database ID（uint64），可从 `mo_database` 系统表或 `ckp list --type=databases` 获取 |
| `--output-dir` | 是 | 输出根目录。该目录会自动创建 |
| `--ts` | 否 | 快照时间戳，不指定则用最新 |
| `--header` | 否 | 在每个 CSV 文件第一行输出列名头行 |
| `--meta-comments` | 否 | 在每个 CSV 文件头部输出 DDL 和行数统计注释 |
| `--row-order` | 否 | 行排序方式 |
| `--load-script` | 否 | 切换为 LOAD 脚本输出模式：生成单个 SQL 文件，包含 CREATE DATABASE + 所有表的 CREATE TABLE + LOAD DATA |
| `--no-load` | 否 | 配合 `--load-script` 使用，跳过 LOAD DATA 语句，只输出 DDL |

### 3.3 示例

**导出指定 database ID 下的所有表**：

```bash
./mo-tool ckp dump --database-id=9001 --output-dir=./dump_out --header /path/to/mo-data
```

**生成该 database 的 LOAD 恢复脚本**：

```bash
./mo-tool ckp dump --database-id=9001 --load-script -o /tmp/ /path/to/mo-data
```

### 3.4 输出目录结构

以 database 为单位 dump 时，CSV 文件按以下目录结构组织：

```text
<output-dir>/
├── restore.sql                          # 如果指定了 --load-script，生成恢复脚本
└── account_<account_id>/
    └── db_<database_id>/
        ├── <table_name>_<table_id>.csv
        ├── <table_name_2>_<table_id_2>.csv
        └── ...
```

具体示例：

**dump CSV + LOAD 脚本**：

```bash
./mo-tool ckp dump --database-id=9001 --output-dir=./dump_out --header \
  --load-script -o ./dump_out/ /path/to/mo-data
```

```text
dump_out/
├── restore.sql
└── account_7/
    └── db_9001/
        ├── employees_272535.csv
        ├── departments_272536.csv
        └── alter_compat_272538.csv
```

其中 `restore.sql` 的内容：

```sql
CREATE DATABASE IF NOT EXISTS test_ckp;
USE test_ckp;

CREATE TABLE employees (
    id INT PRIMARY KEY,
    name VARCHAR(100),
    ...
);

LOAD DATA INFILE 'dump_out/account_7/db_9001/employees_272535.csv'
INTO TABLE employees
FIELDS TERMINATED BY ','
ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

CREATE TABLE departments (...);

LOAD DATA INFILE 'dump_out/account_7/db_9001/departments_272536.csv'
INTO TABLE departments
FIELDS TERMINATED BY ','
ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;
```

**只 dump CSV（不含 LOAD 脚本）**：

```bash
./mo-tool ckp dump --database-id=9001 --output-dir=./dump_out --header /path/to/mo-data
```

```text
dump_out/
└── account_7/
    └── db_9001/
        ├── employees_272535.csv
        ├── departments_272536.csv
        └── alter_compat_272538.csv
```

目录命名规则：

- **account 目录**：`account_<account_id>`，其中 `account_id` 为十进制数字。系统租户的 account_id 为 `0`
- **database 目录**：`db_<database_id>`，其中 `database_id` 为十进制数字
- **CSV 文件名**：`<table_name>_<table_id>.csv`，其中 `table_name` 为表名，`table_id` 为内部数字 ID。表名中的特殊字符会被替换为下划线

> **注意**：`relkind='v'` 的视图不会被导出。

### 3.5 命令输出

执行过程中，每成功导出一个表会打印一行信息：

```text
Table 272535 test_ckp.employees dumped to dump_out/account_7/db_9001/employees_272535.csv
Table 272536 test_ckp.departments dumped to dump_out/account_7/db_9001/departments_272536.csv
Dumped 2 tables to dump_out
```

---

## 四、以租户（account）为单位 dump

### 4.1 命令

```bash
./mo-tool ckp dump --account-id=<ACCOUNT_ID> --output-dir=<DIR> [选项] <mo-data路径>
```

### 4.2 参数说明

| 参数 | 必需 | 说明 |
|------|------|------|
| `--account-id` | 是 | 租户 ID（uint32） |
| `--output-dir` | 是 | 输出根目录 |
| `--ts` | 否 | 快照时间戳 |
| `--header` | 否 | CSV 列名头行 |
| `--meta-comments` | 否 | DDL 和行数统计注释 |
| `--row-order` | 否 | 行排序方式 |
| `--load-script` | 否 | 切换为 LOAD 脚本输出模式：生成单个 SQL 文件，包含所有 database 的 CREATE DATABASE + CREATE TABLE + LOAD DATA |
| `--no-load` | 否 | 配合 `--load-script` 使用，跳过 LOAD DATA 语句，只输出 DDL |

### 4.3 示例

**导出某个租户的所有表**：

```bash
./mo-tool ckp dump --account-id=7 --output-dir=./dump_out --header /path/to/mo-data
```

**生成该租户的 LOAD 恢复脚本**：

```bash
./mo-tool ckp dump --account-id=7 --load-script -o /tmp/ /path/to/mo-data
```
