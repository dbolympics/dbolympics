//! DuckDB-based validation of the schema and of generated data.

use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::{Context, Result, bail};
use duckdb::Connection;

/// Statements of a SQL file without `--` comment lines.
fn statements(sql: &str) -> Vec<String> {
    let code: String = sql.lines().filter(|l| !l.trim_start().starts_with("--")).collect::<Vec<_>>().join("\n");
    code.split(';').map(str::trim).filter(|s| !s.is_empty()).map(String::from).collect()
}

fn run_rules(conn: &Connection) -> Result<usize> {
    let rules = fs::read_to_string("schema/ddl/rules.sql").context("reading rules.sql")?;
    let mut n = 0;
    for stmt in statements(&rules) {
        let mut q = conn.prepare(&stmt).with_context(|| format!("preparing rule:\n{stmt}"))?;
        let violations = q.query_map([], |_| Ok(()))?.count();
        if violations != 0 {
            bail!("rule violated by {violations} rows:\n{stmt}");
        }
        n += 1;
    }
    Ok(n)
}

pub fn check_schema() -> Result<()> {
    let conn = Connection::open_in_memory()?;
    for path in ["schema/ddl/duckdb.sql", "schema/ddl/lookup_data.sql"] {
        let sql = fs::read_to_string(path).with_context(|| format!("reading {path}"))?;
        conn.execute_batch(&sql).with_context(|| format!("executing {path}"))?;
    }
    let tables: i64 = conn.query_row("SELECT count(*) FROM duckdb_tables()", [], |r| r.get(0))?;
    let columns: i64 = conn.query_row("SELECT count(*) FROM duckdb_columns() WHERE NOT internal", [], |r| r.get(0))?;
    println!("loaded {tables} tables, {columns} columns");
    println!("ran {} rule queries: all clean", run_rules(&conn)?);
    Ok(())
}

/// Load a generated dataset into DuckDB with every FK, unique and check constraint enabled, in a
/// database file next to the dataset (removed afterwards), so DuckDB can spill to disk.
pub fn validate(dir: &Path) -> Result<()> {
    let t0 = Instant::now();
    let db = PathBuf::from(format!("{}.validate.duckdb", dir.display()));
    let wal = PathBuf::from(format!("{}.wal", db.display()));
    let remove = || {
        let _ = fs::remove_file(&db);
        let _ = fs::remove_file(&wal);
    };
    remove();
    let conn = Connection::open(&db)?;
    let result = validate_into(&conn, dir, t0);
    drop(conn);
    remove();
    result
}

fn validate_into(conn: &Connection, dir: &Path, t0: Instant) -> Result<()> {
    let ddl = fs::read_to_string("schema/ddl/duckdb_constraints.sql").context("reading duckdb_constraints.sql")?;
    let mut order = Vec::new();
    for stmt in statements(&ddl) {
        if let Some(rest) = stmt.strip_prefix("CREATE TABLE ") {
            order.push(rest.split_whitespace().next().unwrap().to_string());
        }
        conn.execute_batch(&stmt).with_context(|| format!("DDL:\n{stmt}"))?;
    }
    let mut total = 0i64;
    let mut empty = Vec::new();
    for t in &order {
        let glob = dir.join(t).join("*.parquet");
        if fs::read_dir(dir.join(t)).is_err() {
            bail!("missing table directory {}", dir.join(t).display());
        }
        let src = format!("read_parquet('{}')", glob.display());
        let tab = crate::schema::schema().tables.iter().find(|x| &x.name == t).unwrap();
        let self_fks: Vec<&str> = tab
            .foreign_keys
            .iter()
            .filter(|fk| fk.table == tab.id)
            .map(|fk| tab.columns[fk.column].name.as_str())
            .collect();
        let n = if self_fks.is_empty() {
            conn.execute(&format!("INSERT INTO {t} SELECT * FROM {src}"), []).with_context(|| format!("loading {t}"))?
        } else {
            // self-referencing FKs are checked against rows already present: load level by level
            let mut n = 0;
            loop {
                let ready = self_fks.iter().map(|c| format!("(s.{c} IS NULL OR s.{c} IN (SELECT id FROM {t}))")).collect::<Vec<_>>().join(" AND ");
                let sql = format!("INSERT INTO {t} SELECT s.* FROM {src} s WHERE s.id NOT IN (SELECT id FROM {t}) AND {ready}");
                let k = conn.execute(&sql, []).with_context(|| format!("loading {t}"))?;
                n += k;
                if k == 0 {
                    break;
                }
            }
            let total: i64 = conn.query_row(&format!("SELECT count(*) FROM {src}"), [], |r| r.get(0))?;
            if total as usize != n {
                bail!("{t}: {} rows reference missing rows of the same table", total as usize - n);
            }
            n
        };
        total += n as i64;
        if n == 0 {
            empty.push(t.clone());
        }
    }
    println!("loaded {total} rows into {} tables with all constraints ({} empty)", order.len(), empty.len());
    println!("ran {} rule queries: all clean", run_rules(conn)?);
    println!("validated in {:.1}s", t0.elapsed().as_secs_f64());
    Ok(())
}

/// Rows, Parquet size and CSV-equivalent size per table (the SF definition is CSV bytes).
pub fn measure(dir: &Path) -> Result<()> {
    let conn = Connection::open_in_memory()?;
    let scratch = Path::new("tmp").join("measure.csv");
    fs::create_dir_all("tmp")?;
    let mut rows = Vec::new();
    for t in &crate::schema::schema().tables {
        let tdir = dir.join(&t.name);
        let mut pq = 0u64;
        for e in fs::read_dir(&tdir).with_context(|| format!("reading {}", tdir.display()))? {
            pq += e?.metadata()?.len();
        }
        let src = format!("read_parquet('{}')", tdir.join("*.parquet").display());
        let n: i64 = conn.query_row(&format!("SELECT count(*) FROM {src}"), [], |r| r.get(0))?;
        let csv = if n > 0 {
            conn.execute_batch(&format!("COPY (SELECT * FROM {src}) TO '{}' (HEADER false)", scratch.display()))?;
            fs::metadata(&scratch)?.len()
        } else {
            0
        };
        rows.push((t.name.clone(), n, pq, csv));
    }
    let _ = fs::remove_file(&scratch);
    rows.sort_by_key(|r| std::cmp::Reverse(r.3));
    let (tr, tp, tc) = rows.iter().fold((0i64, 0u64, 0u64), |a, r| (a.0 + r.1, a.1 + r.2, a.2 + r.3));
    println!("{:<28} {:>12} {:>10} {:>10} {:>6}", "table", "rows", "parquet", "csv", "csv%");
    for (t, n, p, c) in rows.iter().filter(|r| r.1 > 0) {
        println!("{t:<28} {n:>12} {:>9.1}M {:>9.1}M {:>5.1}%", *p as f64 / 1e6, *c as f64 / 1e6, 100.0 * *c as f64 / tc as f64);
    }
    println!("{:<28} {tr:>12} {:>9.1}M {:>9.1}M", "TOTAL", tp as f64 / 1e6, tc as f64 / 1e6);
    Ok(())
}

/// Check the period files of a dataset: every table has exactly one file per period, and no
/// row of a table written in creation order references a row of a later period, so every
/// prefix of periods that ends with a quarter is referentially complete. Reported, not errors:
/// - Rows of deferred tables carry their final values, so they may point to rows created later
///   (e.g. a subscription moved to a newer plan).
///
/// Prints rows and Parquet bytes per period.
pub fn check_periods(dir: &Path) -> Result<()> {
    let t0 = Instant::now();
    let periods = crate::time::periods();
    let conn = Connection::open_in_memory()?;
    let schema = crate::schema::schema();
    let mut rows_per_period = vec![0i64; periods.len()];
    let mut bytes_per_period = vec![0u64; periods.len()];
    // the position of a row's file in the list of periods
    let cases = periods.iter().enumerate().map(|(k, p)| format!("WHEN file__ LIKE '%/{p}.parquet' THEN {k}")).collect::<Vec<_>>().join(" ");
    for t in &schema.tables {
        let n = &t.name;
        let mut files: Vec<String> = fs::read_dir(dir.join(n))
            .with_context(|| format!("reading {}", dir.join(n).display()))?
            .filter_map(|e| e.ok().map(|e| e.file_name().to_string_lossy().into_owned()))
            .collect();
        files.sort();
        if files != periods.iter().map(|p| format!("{p}.parquet")).collect::<Vec<_>>() {
            bail!("{n}: expected one file per period ({}.parquet ... {}.parquet), found {}", periods[0], periods[periods.len() - 1], files.join(" "));
        }
        conn.execute_batch(&format!(
            "CREATE VIEW p_{n} AS SELECT * EXCLUDE (file__), CASE {cases} END AS period__ FROM read_parquet('{}', filename = 'file__');",
            dir.join(n).join("*.parquet").display()
        ))?;
        let mut q = conn.prepare(&format!("SELECT period__, count(*) FROM p_{n} GROUP BY ALL"))?;
        for r in q.query_map([], |r| Ok((r.get::<_, i32>(0)?, r.get::<_, i64>(1)?)))? {
            let (k, c) = r?;
            rows_per_period[k as usize] += c;
        }
        for (k, p) in periods.iter().enumerate() {
            bytes_per_period[k] += fs::metadata(dir.join(n).join(format!("{p}.parquet")))?.len();
        }
    }
    // references into later periods
    let deferred = crate::sim::deferred_tables();
    let (mut bad, mut late) = (Vec::new(), Vec::new());
    let mut nfk = 0;
    for t in &schema.tables {
        for fk in &t.foreign_keys {
            nfk += 1;
            let (c, p, col) = (&t.name, &schema.tables[fk.table.0].name, &t.columns[fk.column].name);
            let n: i64 = conn.query_row(&format!("SELECT count(*) FROM p_{c} c JOIN p_{p} p ON c.\"{col}\" = p.id WHERE p.period__ > c.period__"), [], |r| r.get(0))?;
            if n > 0 {
                let line = format!("{c}.{col} -> {p}: {n} rows");
                if deferred.contains(&t.id) { late.push(line) } else { bad.push(line) }
            }
        }
    }
    let total: i64 = rows_per_period.iter().sum();
    println!("{:<17} {:>12} {:>7} {:>10}", "period", "rows", "rows%", "parquet");
    for (k, p) in periods.iter().enumerate() {
        println!("{p:<17} {:>12} {:>6.1}% {:>9.1}M", rows_per_period[k], 100.0 * rows_per_period[k] as f64 / total as f64, bytes_per_period[k] as f64 / 1e6);
    }
    println!("{:<17} {total:>12}", "TOTAL");
    println!("{} of {nfk} foreign keys point into later periods from tables written in creation order", bad.len());
    for b in &bad {
        println!("  {b}");
    }
    println!("{} foreign keys of deferred tables (final values) point into later periods:", late.len());
    for b in &late {
        println!("  {b}");
    }
    println!("checked in {:.1}s", t0.elapsed().as_secs_f64());
    if !bad.is_empty() {
        bail!("rows reference rows of later periods");
    }
    Ok(())
}
