# MySQL Compatibility Case Exploration Plan

## Background

MatrixOne sometimes discovers MySQL compatibility gaps passively from MOI reports or user feedback. This plan proposes a more active, iterative way to explore MySQL-compatible behavior, generate focused SQL cases, compare MatrixOne with MySQL, and add only stable, non-duplicated cases into regression.

The core principle is:

```text
AI generates candidates -> MySQL provides oracle behavior -> MatrixOne is compared -> humans classify and curate -> stable cases enter BVT/regression
```

This should not become blind case accumulation. New cases must be checked against existing MatrixOne cases, and existing cases should be reorganized or simplified when they overlap.

## Candidate Sources

Use multiple sources, but keep MySQL as the behavioral oracle.

| Source | Usage | Notes |
| --- | --- | --- |
| MySQL official manual | Primary semantic reference | Best for documented behavior, examples, edge rules, SQL modes, function definitions |
| MySQL test suite | Edge-case mining | Good for subtle parser/expression/function behavior; filter out storage-engine/internal-only cases |
| TiDB tests | Compatibility inspiration | Useful for MySQL-compatible expression/function cases, but TiDB behavior is not always the oracle |
| Existing MatrixOne BVT | Deduplication and alignment | New cases must be orthogonal to existing coverage |
| Existing MO issues / MOI reports | Regression seeds | Minimize each issue into stable SQL before adding to regression |

Useful reference entry points:

- MySQL Reference Manual, Functions and Operators: https://dev.mysql.com/doc/refman/8.0/en/functions.html
- MySQL Type Conversion in Expression Evaluation: https://dev.mysql.com/doc/en/type-conversion.html
- MySQL Cast Functions and Operators: https://dev.mysql.com/doc/refman/8.3/en/cast-functions.html
- MySQL Server source and mysql-test suite: https://github.com/mysql/mysql-server
- TiDB repository: https://github.com/pingcap/tidb

## Topic List

### 1. Type System and Type Conversion

High priority. This is one of the most common compatibility risk areas.

- `CAST` and `CONVERT`
- implicit conversion in expression evaluation
- string to integer / decimal / float
- number to string
- string to date / datetime / timestamp / time
- date and datetime to number/string
- decimal precision, scale, rounding, truncation
- signed and unsigned integer boundaries
- float/double precision and special edge behavior
- `NULL` in type inference
- return type merging in `UNION`, `CASE`, `IF`, `IFNULL`, `COALESCE`
- function return type inference

Initial focus:

```text
string -> number
string -> date/time
decimal scale and overflow
signed/unsigned boundary behavior
conditional expression return type
```

### 2. Expressions and Operators

- arithmetic: `+`, `-`, `*`, `/`, `DIV`, `MOD`
- comparison: `=`, `<=>`, `!=`, `<`, `>`, `<=`, `>=`
- string/number mixed comparison
- date/string mixed comparison
- `BETWEEN`
- `IN` and `NOT IN`
- `LIKE` and `REGEXP`
- logical operators: `AND`, `OR`, `NOT`, `XOR`
- bit operators: `&`, `|`, `^`, `<<`, `>>`, `~`
- operator precedence
- constant folding
- overflow and underflow behavior

### 3. NULL and Three-Valued Logic

- `NULL = NULL` vs `NULL <=> NULL`
- `NULL` in comparison operators
- `NULL` with `IN` / `NOT IN`
- `NULL` with `BETWEEN`
- `NULL` in aggregate functions
- `NULL` in string/date/numeric functions
- `NULL` in `GROUP BY`
- `NULL` in `DISTINCT`
- ordering behavior involving `NULL`

### 4. String, Charset, and Collation

- case-sensitive and case-insensitive comparison
- `BINARY` strings
- trailing spaces in `CHAR` / `VARCHAR`
- empty string behavior
- string truncation
- `CHAR`, `VARCHAR`, `TEXT`, `BLOB`
- `LENGTH` vs `CHAR_LENGTH`
- `CONCAT`, `CONCAT_WS`
- `SUBSTR`, `SUBSTRING`
- `TRIM`, `LPAD`, `RPAD`
- `REPLACE`, regexp-related functions
- collation effects on comparison and ordering

### 5. Date and Time

- `DATE`, `DATETIME`, `TIMESTAMP`, `TIME`
- invalid dates
- zero date: `0000-00-00`
- date string parsing
- date/number conversion
- `NOW`, `CURRENT_TIMESTAMP`
- time zone effects
- `DATE_ADD`, `DATE_SUB`
- `DATEDIFF`, `TIMESTAMPDIFF`
- microsecond precision
- `EXTRACT`
- `STR_TO_DATE`, `DATE_FORMAT`
- SQL mode effects on invalid/zero dates

### 6. Numeric Functions

- `ABS`
- `ROUND`, `TRUNCATE`
- `CEIL`, `FLOOR`
- `MOD`
- `POW`
- `SQRT`
- `LOG`
- `RAND`
- decimal input return types
- unsigned input return types
- overflow, warning, and error behavior

### 7. Conditional and Flow-Control Functions

Very important because MySQL has many non-obvious return type rules.

- `IF`
- `IFNULL`
- `NULLIF`
- `COALESCE`
- `CASE WHEN`
- `GREATEST`
- `LEAST`
- mixed string/int/decimal/date parameters
- mixed `NULL` parameters
- return type and collation inference

### 8. Aggregate and Grouping

- `COUNT(*)` vs `COUNT(expr)`
- `SUM`, `AVG` return types
- `MIN`, `MAX` for string/date/numeric values
- `GROUP_CONCAT`
- distinct aggregate
- `GROUP BY` expression
- `HAVING`
- `ROLLUP`
- `ONLY_FULL_GROUP_BY`
- empty table aggregate result
- all-`NULL` aggregate result

### 9. Ordering, LIMIT, and DISTINCT

- `ORDER BY` strings/numbers/dates
- `ORDER BY` expression
- `ORDER BY` ordinal
- `NULL` ordering
- `LIMIT` and `OFFSET`
- `DISTINCT`
- `DISTINCT` with `ORDER BY`
- non-deterministic ordering detection and normalization

Cases with unstable order must either add deterministic `ORDER BY` or be excluded from oracle comparison.

### 10. JOIN and Subquery Semantics

- inner/left/right join
- join conditions with implicit type conversion
- `NULL` join keys
- `EXISTS`
- `NOT EXISTS`
- `IN` subquery
- `NOT IN` subquery with `NULL`
- correlated subquery
- scalar subquery
- derived table
- subquery returning more than one row

### 11. DDL, Defaults, and Metadata

- `CREATE TABLE` type definitions
- default values and expressions
- nullable / not null
- auto-increment
- primary key / unique key
- index definitions
- generated columns
- `SHOW CREATE TABLE`
- `DESC`
- `INFORMATION_SCHEMA`
- `lower_case_table_names`
- quoted identifiers
- reserved keywords

### 12. DML Behavior

- `INSERT`
- `INSERT IGNORE`
- `REPLACE`
- `ON DUPLICATE KEY UPDATE`
- update expression evaluation order
- `DELETE`
- multi-row insert partial failure
- implicit conversion warning/error behavior
- default values
- affected rows

### 13. SQL Mode, Warnings, and Errors

This topic should be tracked separately because the same SQL can behave differently under different SQL modes.

- strict mode
- non-strict mode
- `NO_ZERO_DATE`
- `ONLY_FULL_GROUP_BY`
- division by zero
- truncation warning
- invalid date warning/error
- overflow warning/error
- error code and error message category
- `SHOW WARNINGS`
- warning count

### 14. JSON

- JSON path
- `JSON_EXTRACT`
- `JSON_UNQUOTE`
- `JSON_CONTAINS`
- JSON null vs SQL `NULL`
- numeric/string comparison inside JSON
- invalid JSON
- missing path
- array/object behavior
- return type differences

### 15. Window Functions

- `ROW_NUMBER`
- `RANK`, `DENSE_RANK`
- `LAG`, `LEAD`
- `FIRST_VALUE`, `LAST_VALUE`
- `ROWS` frame
- `RANGE` frame
- `PARTITION BY` expression and type conversion
- `ORDER BY` with `NULL`
- aggregate window functions
- boundary frames

### 16. Privilege, Account, and System Variables

- role / grant / revoke
- database privilege
- table privilege
- `SHOW` privilege
- `USE database`
- global/session system variables
- protected database
- accountadmin vs normal user behavior
- privilege cache behavior

### 17. Transaction and Locking

Use this after expression/function compatibility has a stable workflow, because transaction cases are harder to make deterministic.

- autocommit
- begin / commit / rollback
- savepoint
- isolation levels if supported
- DDL in transaction
- duplicate key conflict
- update conflict
- `SELECT FOR UPDATE`
- lock wait / deadlock
- MySQL behavior differences that should be documented as known incompatibility

### 18. LOAD, OUTFILE, and External Data

- `LOAD DATA`
- CSV `NULL` representation
- escape / quote behavior
- charset handling
- date/time import
- decimal import
- invalid row behavior
- column default behavior
- field count mismatch
- `SELECT INTO OUTFILE`

## Recommended First Batch

Start small. Do not try to cover every topic in one pass.

Recommended first five topics:

1. Type conversion and `CAST`
2. Conditional return type: `IF`, `CASE`, `IFNULL`, `COALESCE`
3. `NULL`, comparison, `IN`, and `NOT IN`
4. Date/time parsing and conversion
5. Decimal, signed, and unsigned boundary behavior

These areas have high MySQL compatibility risk, are easy to validate with MySQL as oracle, and are likely to produce valuable regression cases.

## Case Generation Workflow

Each iteration should focus on one topic.

```text
1. Pick one topic and define the exact behavior surface.
2. Collect examples from MySQL docs, MySQL tests, TiDB tests, existing MO cases, and known issues.
3. Ask AI to expand edge cases within the topic.
4. Deduplicate against existing MatrixOne cases.
5. Run candidates on MySQL and save oracle results.
6. Run the same candidates on MatrixOne.
7. Normalize output and diff results.
8. Classify each case.
9. Add only stable, useful, non-duplicated cases to regression.
10. File issues or known-incompatibility records for meaningful differences.
```

## Case Classification

| Class | Meaning | Action |
| --- | --- | --- |
| Compatible and valuable | MO matches MySQL and the case covers a useful edge | Add to regression |
| Duplicate | Existing BVT already covers it | Do not add; maybe link to existing case |
| Unstable | Depends on order, time, randomness, environment | Stabilize or discard |
| Known incompatibility | Difference is accepted for now | Record in known list; do not fail BVT |
| Suspected bug | Difference is unexpected and reproducible | Minimize SQL and file issue |
| Unsupported feature | MySQL supports it but MO does not | Track separately from compatibility bugs |

## Keeping New Cases Orthogonal

Before adding cases, search existing MatrixOne tests.

Example commands:

```bash
rg -n "cast\\(|convert\\(" test/distributed/cases
rg -n "ifnull|coalesce|case when|greatest|least" test/distributed/cases
rg -n "lower_case_table_names|protected_databases" test/distributed/cases
rg -n "str_to_date|date_format|timestampdiff|datediff" test/distributed/cases
```

Deduplication rules:

- Do not add cases that only change literal values without adding coverage.
- Prefer one compact case group that covers several boundaries.
- If an existing case is scattered or unclear, improve/organize it instead of adding another copy.
- Keep each case explainable: what behavior does it protect?

## Suggested Directory Layout in MatrixOne

The final location depends on MatrixOne test conventions, but a topic-oriented layout is easier to maintain.

```text
test/distributed/cases/mysql_compat/
  type_conversion/
    cast.sql
    cast.result
  builtin_function/
    conditional.sql
    numeric.sql
    string.sql
    datetime.sql
  operator/
    comparison.sql
    arithmetic.sql
  null_semantics/
    null_logic.sql
  sql_mode/
    strict_mode.sql
```

If the project prefers existing directories, keep the same topic names in comments or file names.

## Suggested Metadata Format

Use lightweight comments so cases remain understandable.

```sql
-- topic: type_conversion/cast
-- source: mysql-doc:type-conversion
-- oracle: mysql-8.0
-- intent: string with trailing junk cast to signed integer
select cast('123abc' as signed);
```

For generated cases, record provenance:

```sql
-- generated-by: ai-assisted
-- reviewed-by: human
-- status: regression
```

## Execution and Diff Requirements

To avoid noisy diffs:

- pin MySQL version used as oracle
- set `sql_mode`, `time_zone`, charset, and collation explicitly
- use isolated databases per run
- clean up after each case group
- normalize warning text and error categories
- add deterministic `ORDER BY`
- avoid functions like `RAND()` unless seeded or explicitly tested
- separate result mismatch from warning/error mismatch

Recommended report fields:

```text
case_id
topic
source
sql
mysql_result
mo_result
diff_type
classification
next_action
linked_issue
```

## Iteration Output

Each topic iteration should produce:

- candidate SQL file
- MySQL oracle result
- MatrixOne result
- diff report
- selected regression cases
- known incompatibility list
- newly filed issues if needed

This keeps the work active and systematic without turning regression into an uncontrolled pile of generated SQL.
