# Dialects

The canonical queries (on the website: the benchmark queries) are one text for every system:
standard SQL with `{{...}}` placeholders where systems differ. Each placeholder is a
customization point with a standard-SQL default; a system overrides what differs with a text
template in its `system.toml` ([RUNNER.md](RUNNER.md#dialects)). `dbo-bench points` prints the
points as JSON; `dbo-bench render` writes the queries as a system gets them.

## Customization points

| Point | Default |
|---|---|
| `date_diff_days(a, b)` | `(CAST({b} AS DATE) - CAST({a} AS DATE))` |
| `year_month(x)` | `to_char({x}, 'YYYY-MM')` |
| `fetch_first(n)` | `FETCH FIRST {n} ROWS ONLY` (standard; for a system that rejects it, `LIMIT {n}`) |
| `count_distinct_over(x, window)` | `COUNT(DISTINCT {x}) OVER ({window})`, without a window ORDER BY or frame; `{window}` is the specification without its parentheses. Systems without DISTINCT window aggregates use two dense ranks (`bench/src/dialect.rs`) |
| `bool_or(x)` | `BOOL_OR({x})` (PostgreSQL's; the standard's `SOME` and `ANY` aggregates are hardly implemented) |
| `percentile_cont(p, x)` | `PERCENTILE_CONT({p}) WITHIN GROUP (ORDER BY {x})` |
| `percentile_cont_filter(p, x, condition)` | the same with `FILTER (WHERE {condition})` |
| `string_agg_sorted(x, sep)` | `STRING_AGG({x}, {sep} ORDER BY {x})` (not standard; the standard has `LISTAGG`) |
| `string_agg_distinct_sorted(x, sep)` | `STRING_AGG(DISTINCT {x}, {sep} ORDER BY {x})` |
| `seconds_between(a, b)` | `CAST(EXTRACT(EPOCH FROM ({b} - {a})) AS NUMERIC(18,6))` (`EPOCH` is PostgreSQL's) |
| `equals_any(x, arr)` | `{x} IN (SELECT dbo_unnest.dbo_element FROM UNNEST({arr}) AS dbo_unnest(dbo_element))`, the standard's membership test |
| `count_distinct_pair(a, b)` | `COUNT(DISTINCT ({a}, {b}))` |
| `add_minutes(ts, n)` | `{ts} + {n} * INTERVAL '1' MINUTE` (standard; MySQL, T-SQL and SQLite have no interval type) |
| `whole_days_between(a, b)` | `EXTRACT(DAY FROM {b} - {a})`, the day field of the difference (PostgreSQL's; the standard needs an interval qualifier no reference dialect supports) |
| `timestamp_midpoint(a, b)` | `{a} + ({b} - {a}) * 0.5` (the same) |

## Where a difference goes

"The standard" is SQL:2023, Part 2 (ISO/IEC 9075-2:2023). "The reference dialects" are the four
most used relational databases in the Stack Overflow Developer Survey 2026: PostgreSQL, SQLite,
MySQL and T-SQL (SQL Server), so that the small systems in the benchmark do not decide what is
usual. A dialect **supports** a construct when it accepts it and returns the standard's result
(SQLite accepts `CAST(x AS DATE)` but returns a number, so it does not support it).

A change is **simple** when a fixed pattern over the construct's own operands gives the
standard's result on every input and can be applied without semantic analysis (types, schema
or data):
- local: it replaces one construct (an expression, a predicate, an aggregate call) where it
  stands, and nothing else in the query changes;
- textual: finding and rewriting the construct needs only the text of the query;
- fixed shape: the operands go into a fixed pattern, maybe more than once, but nothing is
  repeated per element of a list;
- exact: the standard's result on every input, NULLs, empty groups and ties included.

Renaming an alias at all its uses is simple too.

1. **The standard says X, and the system runs the query but does something else.** A runtime
   error counts as something else, unless the standard allows it there (division by zero,
   numeric overflow).
   - At least two of the four reference dialects do X (the standard breaks a tie): the system
     is wrong, and its result stays. Big systems can be wrong this way too.
   - Otherwise the reference dialects mostly disagree with the standard as well: the canonical
     query says explicitly what it means (numeric types and scales, [NUMERICS.md](NUMERICS.md)).
2. **The standard says X, and the system rejects the query before it reads any data** (an error
   on the empty schema).
   - A simple equivalent exists in the system's dialect: the construct becomes a placeholder
     with the standard construct as its default, and the system overrides it. Examples:
     Firebolt's sorted `string_agg` from a sorted array; the dense ranks for
     `COUNT(DISTINCT x) OVER (...)`; ClickHouse's `addMinutes`. If the change costs nothing on
     any system, it goes into the canonical query instead: an output alias that reuses the name
     of an input column the same block still uses is renamed, and so is a subquery alias
     `final` (non-reserved in the standard, ClickHouse's `FINAL` modifier).
   - Otherwise the system's error stays. Examples: correlated subqueries a system cannot
     decorrelate; Hyper's `(a, b) IN (VALUES ...)` (its equivalent repeats a pattern per list
     element); ClickHouse's decimal division by a larger scale and its CASE over decimals of
     different scales (finding them needs types); `COUNT(DISTINCT (a, b))` on Hyper, CedarDB
     and Firebolt (combining the two values into one is exact only within a range of values).
3. **The query uses X, and the standard has no X** (implementation-defined or unspecified).
   - Enough reference dialects support another way to write it, two of the four for a standard
     equivalent (the standard breaks a tie) and three for any other: the canonical query uses
     that. Examples: `DATE(x)` to `CAST(x AS DATE)`, `DISTINCT ON` to `ROW_NUMBER() ... = 1`,
     `NULLS LAST` and `NULLS FIRST` on every sort key (as in the reference results),
     `unnest(ARRAY[...])` in a select list to a `VALUES` list, `x->>'key'` to
     `JSON_VALUE(x, '$.key')`, `(t - x) > interval '30 days'` to `x < t - INTERVAL '30 days'`.
   - Otherwise a placeholder. Its default is the standard's Y where the standard has one that a
     reference dialect supports, else X. With X: `STRING_AGG`, `BOOL_OR`,
     `EXTRACT(EPOCH FROM ...)`, `date - date`, `to_char`, the day field and the midpoint of a
     difference of timestamps. With Y: `add_minutes` and `equals_any`, both supported only by
     PostgreSQL among the four.

**Settings:** a system may apply its own settings at startup to follow the standard more
closely: DuckDB's `integer_division` (an exact division of integers gives an exact result, not
a double), ClickHouse's `cast_keep_nullable`. A setting that trades one deviation for another
is not used: ClickHouse's `prefer_column_name_to_alias` resolves an ORDER BY name to an input
column, where the standard takes the output column.
