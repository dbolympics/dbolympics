//! One run: a system in one configuration, from a fresh pod to its removal. See
//! docs/RUNNER.md for the procedure.

use std::collections::{BTreeMap, BTreeSet};
use std::fs::File;
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use parquet::file::reader::{FileReader, SerializedFileReader};

use crate::check;
use crate::config::{Benchmark, Config, Keys, periods, sf_name};
use crate::ddl;
use crate::dialect::Dialect;
use crate::client::{Answer, Client, Gone};
use crate::podman::{Limits, Mounts, Pod, Podman};
use crate::results::{Row, write_csv};
use crate::system::{Arrays, Category, System, subst};

/// Why a run failed as a whole. Its measurements up to that point are kept, but the run does
/// not count.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Failure {
    /// the kernel killed a process of the system for memory
    Oom,
    /// the system stopped answering (its query program closed the connection, or `SELECT 1`
    /// fails)
    Crash,
    /// a query did not return within its timeout and the grace period
    Stuck,
    /// a load statement failed
    Load,
    /// a load took longer than the configuration's load_timeout
    LoadTimeout,
    /// the system could not be set up (image, start, schema)
    Setup,
}

impl Failure {
    pub fn status(self) -> &'static str {
        match self {
            Failure::Oom => "failed_oom",
            Failure::Crash => "failed_crash",
            Failure::Stuck => "failed_stuck",
            Failure::Load => "failed_load",
            Failure::LoadTimeout => "failed_load_timeout",
            Failure::Setup => "failed_setup",
        }
    }
}

#[derive(Clone)]
pub struct Failed {
    pub kind: Failure,
    pub detail: String,
}

fn setup<T>(r: Result<T>) -> Result<T, Failed> {
    r.map_err(|e| Failed { kind: Failure::Setup, detail: format!("{e:#}") })
}

/// What the runner needs besides the benchmark file.
pub struct Ctx {
    /// the repository
    pub repo: PathBuf,
    pub podman: Podman,
    /// the date of the campaign (names the result directories)
    pub date: String,
    /// where the campaign comes from (the benchmark file, the commit, the host), kept with every
    /// result
    pub provenance: serde_json::Map<String, serde_json::Value>,
    /// only start the system and check its timeout (no schema, data or queries)
    pub checks_only: bool,
    /// run the system's image as it is (built or loaded before), not built again
    pub no_build: bool,
}

impl Ctx {
    pub fn bench(&self) -> PathBuf {
        self.repo.join("bench")
    }

    /// The directory of a run's raw measurements, results and logs.
    pub fn out_dir(&self, config: &str, system: &str) -> PathBuf {
        self.bench().join("out").join(&self.date).join(config).join(system)
    }
}

/// The outcome of a run.
pub struct Outcome {
    pub rows: Vec<Row>,
    pub failure: Option<Failed>,
}

/// The dataset of a scale factor, generated if it is missing; with `arrays`, also the copy of
/// the tables with array columns as text.
fn dataset(repo: &Path, sf: f64, arrays: bool) -> Result<Mounts> {
    let generator = repo.join("target/release/dbolympics");
    let run = |args: &[&str]| -> Result<()> {
        if !generator.exists() {
            bail!("generator {} not found (cargo build --release --workspace)", generator.display());
        }
        eprintln!("running {} {}", generator.display(), args.join(" "));
        if !std::process::Command::new(&generator).args(args).status()?.success() {
            bail!("{} {} failed", generator.display(), args.join(" "));
        }
        Ok(())
    };
    let data = repo.join("data").join(format!("sf{}", sf_name(sf)));
    if !data.join("orders").is_dir() {
        run(&["generate", "--sf", &sf.to_string(), "--out", &data.to_string_lossy()])?;
    } else if !periods().iter().all(|p| data.join("orders").join(format!("{p}.parquet")).is_file()) {
        bail!("{} does not have one file per period (an older layout): remove it, it is generated again", data.display());
    }
    let mut m = Mounts { data: std::fs::canonicalize(&data)?, arrays: None };
    if arrays {
        let copy = repo.join("data").join(format!("sf{}-arrays", sf_name(sf)));
        if !copy.join(".complete").is_file() {
            run(&["pgarrays", "--arrays-only", &data.to_string_lossy(), &copy.to_string_lossy()])?;
            std::fs::write(copy.join(".complete"), "")?;
        }
        m.arrays = Some(std::fs::canonicalize(&copy)?);
    }
    Ok(m)
}

/// Size and modification time of every file below the data directories.
fn fingerprint(m: &Mounts) -> Result<BTreeMap<PathBuf, (u64, std::time::SystemTime)>> {
    let mut out = BTreeMap::new();
    let mut dirs: Vec<PathBuf> = std::iter::once(m.data.clone()).chain(m.arrays.clone()).collect();
    while let Some(d) = dirs.pop() {
        for e in std::fs::read_dir(&d).with_context(|| d.display().to_string())? {
            let e = e?;
            let md = e.metadata()?;
            if md.is_dir() {
                dirs.push(e.path());
            } else {
                out.insert(e.path(), (md.len(), md.modified()?));
            }
        }
    }
    Ok(out)
}

fn rows_of(file: &Path) -> Result<i64> {
    let r = SerializedFileReader::new(File::open(file).with_context(|| file.display().to_string())?).with_context(|| file.display().to_string())?;
    Ok(r.metadata().file_metadata().num_rows())
}

/// The result of a statement that the system answered.
enum Stmt {
    Ok { seconds: f64, out: Vec<u8> },
    Timeout,
    Error(String),
}

/// A started system: the runner's connection to its query program.
struct Session<'a> {
    pod: &'a Pod,
    client: Client,
    log: File,
    out: &'a Path,
    /// seconds past a timeout before the run fails as stuck
    grace: u64,
}

impl Session<'_> {
    fn note(&mut self, what: &str, text: &str) {
        use std::io::Write;
        let _ = writeln!(self.log, "=== {what}\n{text}\n");
    }

    /// What the query program and the containers wrote last, into errors.log.
    fn note_logs(&mut self) {
        let query = self.pod.query_log();
        let tail: Vec<&str> = query.lines().rev().take(50).collect();
        let logs = self.pod.logs();
        self.note("query program log", &tail.into_iter().rev().collect::<Vec<_>>().join("\n"));
        self.note("container logs", &logs);
    }

    /// Run one statement. With `timeout` in seconds the system cancels it at the timeout, and the
    /// runner gives up after the grace period on top; without, it runs as long as it takes.
    fn statement(&mut self, what: &str, sql: &str, timeout: Option<u64>) -> Result<Stmt, Failed> {
        let limit = timeout.map(|t| Duration::from_secs(t + self.grace));
        let stuck = Failed { kind: Failure::Stuck, detail: format!("{what}: no answer within {} s", limit.map_or(0, |l| l.as_secs())) };
        self.send(what, sql, timeout.map(Duration::from_secs), limit, stuck)
    }

    /// A statement of a load with the rest of the load's budget, as its timeout and as the deadline
    /// for its answer: at the deadline the run fails at once (the system's cancel is not waited for).
    fn load_statement(&mut self, what: &str, sql: &str, budget: Option<Duration>, load_timeout: u64) -> Result<Stmt, Failed> {
        let over = Failed { kind: Failure::LoadTimeout, detail: format!("{what}: the load took longer than its timeout of {load_timeout} s") };
        match budget {
            Some(b) if b.is_zero() => Err(over),
            _ => match self.send(what, sql, budget, budget, over.clone())? {
                Stmt::Timeout => {
                    self.pod.remove();
                    Err(over)
                }
                s => Ok(s),
            },
        }
    }

    /// Send a statement with its timeout and wait for the answer at most `limit`; past it, the
    /// containers are removed and the run fails with `stuck`.
    fn send(&mut self, what: &str, sql: &str, timeout: Option<Duration>, limit: Option<Duration>, stuck: Failed) -> Result<Stmt, Failed> {
        let pod = self.pod;
        // a query program that ends closes the connection; one killed for memory may not
        let r = self.client.request(sql, timeout, limit, &mut || pod.oom_kills() == 0);
        if pod.oom_kills() > 0 {
            return Err(Failed { kind: Failure::Oom, detail: format!("{what}: out of memory") });
        }
        match r {
            Ok((Answer::Ok(out), seconds)) => Ok(Stmt::Ok { seconds, out }),
            Ok((Answer::Timeout, _)) => Ok(Stmt::Timeout),
            Ok((Answer::Error(text), _)) => {
                self.note(&format!("{what}: error"), &text);
                // an error is the statement's; a system that no longer answers has crashed
                let alive = self.client.request("SELECT 1", Some(Duration::from_secs(60)), Some(Duration::from_secs(120)), &mut || true);
                if !matches!(alive, Ok((Answer::Ok(_), _))) || pod.oom_kills() > 0 {
                    self.note_logs();
                    return Err(Failed { kind: Failure::Crash, detail: format!("{what}: the system does not answer any more ({})", last_line(&text)) });
                }
                Ok(Stmt::Error(text))
            }
            Err(Gone::Stuck) => {
                self.pod.remove();
                Err(stuck)
            }
            Err(Gone::Closed) => {
                self.note_logs();
                Err(Failed { kind: Failure::Crash, detail: format!("{what}: the system closed the connection") })
            }
        }
    }
}

impl Drop for Session<'_> {
    /// The query program's log goes with the run's output (the pod's directory goes with the pod).
    fn drop(&mut self) {
        let _ = std::fs::write(self.out.join("query.log"), self.pod.query_log());
    }
}

/// The line of an error text that says what went wrong: the first that looks like an error,
/// else the last.
fn last_line(text: &str) -> String {
    let lines: Vec<&str> = text.lines().filter(|l| !l.trim().is_empty()).collect();
    let hit = lines.iter().find(|l| ["error", "exception", "fatal", "panic"].iter().any(|w| l.to_ascii_lowercase().contains(w)));
    hit.or(lines.last()).copied().unwrap_or("").chars().take(300).collect()
}

fn median(times: &mut [f64]) -> f64 {
    times.sort_by(|a, b| a.total_cmp(b));
    let n = times.len();
    if n % 2 == 1 { times[n / 2] } else { (times[n / 2 - 1] + times[n / 2]) / 2.0 }
}

/// Everything that decides a run of `sys` in configuration `cfg`, and where it comes from: the
/// start of `run.json`, which is kept with the results.
pub fn describe(ctx: &Ctx, bench: &Benchmark, sys: &System, cfg: &Config) -> serde_json::Value {
    let mut v = serde_json::json!({"system": sys.name, "version": sys.version, "category": sys.category.name(), "config": cfg.name, "date": ctx.date, "sf": cfg.sf, "threads": cfg.threads, "cpuset": cfg.cpuset(),
        "memory": cfg.memory, "query_timeout": cfg.query_timeout(), "load_timeout": cfg.load_timeout, "grace_period": cfg.grace_period(), "repetitions": bench.repetitions,
        "keys": cfg.keys.unwrap_or(bench.keys).name(), "queries": bench.queries});
    if let Some(o) = v.as_object_mut() {
        o.extend(ctx.provenance.clone());
    }
    v
}

/// Run `sys` in configuration `cfg`.
pub fn run(ctx: &Ctx, bench: &Benchmark, sys: &System, cfg: &Config) -> Outcome {
    let mut rows = Vec::new();
    let mut summary = describe(ctx, bench, sys, cfg);
    let out = ctx.out_dir(&cfg.name, &sys.name);
    let failure = (|| {
        setup(std::fs::remove_dir_all(&out).or_else(|e| if e.kind() == std::io::ErrorKind::NotFound { Ok(()) } else { Err(e) }).context("clearing the output directory"))?;
        setup(std::fs::create_dir_all(out.join("results")).context("creating the output directory"))?;
        procedure(ctx, bench, sys, cfg, &out, &mut rows, &mut summary)
    })()
    .err();
    if let Some(f) = &failure {
        eprintln!("{} / {}: {}: {}", sys.name, cfg.name, f.kind.status(), f.detail);
        summary["failure"] = serde_json::json!({"status": f.kind.status(), "detail": f.detail});
        let (run, loaded, query) = rows.last().map_or((0, String::new(), String::new()), |r: &Row| (r.run, r.loaded.clone(), r.query.clone()));
        let at = summary["at"].as_object().cloned().unwrap_or_default();
        rows.push(Row {
            run: at.get("run").and_then(|v| v.as_u64()).map_or(run, |v| v as usize),
            loaded: at.get("loaded").and_then(|v| v.as_str()).map_or(loaded, String::from),
            query: at.get("query").and_then(|v| v.as_str()).map_or(query, String::from),
            median: None,
            status: f.kind.status().to_string(),
            message: f.detail.clone(),
        });
    }
    summary["complete"] = serde_json::json!(failure.is_none());
    if let Some(o) = summary.as_object_mut() {
        o.remove("at");
    }
    let _ = std::fs::write(out.join("run.json"), serde_json::to_string_pretty(&summary).unwrap_or_default() + "\n");
    Outcome { rows, failure }
}

fn procedure(ctx: &Ctx, bench: &Benchmark, sys: &System, cfg: &Config, out: &Path, rows: &mut Vec<Row>, summary: &mut serde_json::Value) -> Result<(), Failed> {
    let keys = cfg.keys.unwrap_or(bench.keys);
    let memory = setup(cfg.memory_bytes())?;
    let vars: BTreeMap<String, String> = [("threads", cfg.threads.to_string()), ("memory_bytes", memory.to_string()), ("memory_mb", (memory >> 20).to_string()), ("memory_gb", (memory >> 30).to_string())]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();

    // what to run: the schema, the queries in the system's dialect, the references
    let dialect = setup(Dialect::new(&sys.dialect))?;
    let settings: Vec<String> = setup(dialect.settings.iter().map(|s| subst(s, &vars)).collect())?;
    let tables = setup(ddl::render(&ctx.repo, &setup(ddl::Types::new(&sys.dialect.types))?, keys == Keys::Primary, sys.ddl_suffix(keys)))?;
    let qdir = ctx.repo.join("workload/queries");
    let mut ids: Vec<String> = setup(std::fs::read_dir(&qdir).with_context(|| qdir.display().to_string()))?
        .flatten()
        .filter_map(|e| e.file_name().to_str().and_then(|n| n.strip_suffix(".sql")).map(String::from))
        .collect();
    ids.sort();
    let mut queries = Vec::new();
    for id in setup(bench.select_queries(&ids))? {
        let sql = setup(std::fs::read_to_string(qdir.join(format!("{id}.sql"))).with_context(|| id.clone()))?;
        queries.push((id.clone(), setup(dialect.render(&sql).with_context(|| id.clone()))?));
    }
    let all = periods();
    let references = ctx.repo.join("workload/results").join(format!("sf{}", sf_name(cfg.sf))).join(format!("through-{}", all[all.len() - 1]));
    let checked = references.is_dir();
    if !checked {
        eprintln!("no reference results for sf {} ({}): the results of the last run are saved, not checked", sf_name(cfg.sf), references.display());
    }

    // the data, and which files have rows
    let mounts = setup(dataset(&ctx.repo, cfg.sf, sys.arrays == Arrays::Text))?;
    let array_tables: BTreeSet<String> = match &mounts.arrays {
        Some(dir) => setup(std::fs::read_dir(dir).context("the array tables"))?.flatten().filter(|e| e.path().is_dir()).filter_map(|e| e.file_name().into_string().ok()).collect(),
        None => BTreeSet::new(),
    };

    // a system that gets the data writable must leave it as it is
    let before = if sys.containers.iter().any(|c| c.data_writable) { Some(setup(fingerprint(&mounts))?) } else { None };

    // the system: its image, a fresh pod, start, its query program answers
    let image = if ctx.no_build { setup(ctx.podman.existing_image(sys))? } else { setup(ctx.podman.system_image(&ctx.bench(), sys, out))? };
    let mut env = BTreeMap::new();
    env.insert("DBO_THREADS".to_string(), cfg.threads.to_string());
    env.insert("DBO_MEMORY_BYTES".to_string(), memory.to_string());
    env.insert("DBO_MEMORY_MB".to_string(), (memory >> 20).to_string());
    let name = format!("dbo-{}-{}", sys.name, cfg.name).to_lowercase().replace('.', "-");
    let limits = Limits { cpuset: cfg.cpuset(), memory };
    eprintln!("{} / {}: sf {}, {} threads (cores {}), {} memory, keys {}", sys.name, cfg.name, sf_name(cfg.sf), cfg.threads, limits.cpuset, cfg.memory, keys.name());
    let pod = setup(Pod::start(&ctx.podman, &name, &image, sys, &limits, &mounts, &env, &vars))?;
    // which images ran: a tag like umbradb/umbra:experimental moves, and the systems' images are rebuilt
    summary["images"] = sys.containers.iter().map(|c| (c.name.clone(), c.image.as_str())).chain([("system".to_string(), image.as_str())])
        .map(|(n, i)| Ok((n, setup(ctx.podman.identity(i))?.into())))
        .collect::<Result<serde_json::Map<_, _>, Failed>>()?
        .into();
    // start: the system's servers, if it has any, and its query program, which makes its socket
    // once the system takes connections
    match setup(pod.script("start", Duration::from_secs(600), &out.join("start.log")))? {
        Some((0, _)) => {}
        Some((code, text)) => return Err(Failed { kind: Failure::Setup, detail: format!("start failed (exit {code}): {}", last_line(&text)) }),
        None => return Err(Failed { kind: Failure::Setup, detail: "start did not return within 600 s".into() }),
    }
    let t0 = std::time::Instant::now();
    let mut answer = String::new();
    let client = loop {
        if let Ok(mut c) = Client::connect(&pod.socket()) {
            match c.request("SELECT 1", Some(Duration::from_secs(60)), Some(Duration::from_secs(120)), &mut || true) {
                Ok((Answer::Ok(_), _)) => break c,
                Ok((Answer::Error(e), _)) => answer = format!("SELECT 1: {}", last_line(&e)),
                _ => {}
            }
        }
        if t0.elapsed() > Duration::from_secs(600) || !pod.alive() {
            let log = pod.query_log();
            let _ = std::fs::write(out.join("query.log"), &log);
            let why = if answer.is_empty() { last_line(&log) } else { answer };
            return Err(Failed { kind: Failure::Setup, detail: format!("the query program does not answer: {why}") });
        }
        std::thread::sleep(Duration::from_millis(100));
    };
    let log = setup(File::create(out.join("errors.log")).context("errors.log"))?;
    let mut s = Session { pod: &pod, client, log, out, grace: cfg.grace_period() };
    // the session settings of the system file
    for q in &settings {
        if let Stmt::Error(e) = s.statement("setting", q, None)? {
            return Err(Failed { kind: Failure::Setup, detail: format!("{q}: {}", last_line(&e)) });
        }
    }
    // the system cancels a query at its timeout and answers the next one: a recursion that would
    // take hours, with a timeout of a second
    let slow = "WITH RECURSIVE r AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM r WHERE n < 1000000000000) SELECT count(*) FROM r";
    summary["timeout_check"] = match s.statement("timeout check", slow, Some(1))? {
        Stmt::Timeout => match s.statement("timeout check", "SELECT 1", Some(5))? {
            Stmt::Ok { .. } => "cancelled".into(),
            _ => return Err(Failed { kind: Failure::Setup, detail: "the system does not answer after a cancelled query".into() }),
        },
        Stmt::Ok { .. } => "not tested: the query finished within the timeout".into(),
        Stmt::Error(e) => format!("not tested: {}", last_line(&e)).into(),
    };
    if ctx.checks_only {
        return Ok(());
    }
    // the schema: one CREATE TABLE after the other, timed apart from the loads; a system on the
    // Parquet files has none (its loads make the tables)
    let mut schema_seconds = 0.0;
    for (table, sql) in tables.iter().filter(|_| sys.category == Category::Native) {
        match s.statement(&format!("create table {table}"), sql, None)? {
            Stmt::Ok { seconds, .. } => schema_seconds += seconds,
            Stmt::Error(e) => return Err(Failed { kind: Failure::Setup, detail: format!("create table {table}: {}", last_line(&e)) }),
            Stmt::Timeout => unreachable!(),
        }
    }
    summary["schema_seconds"] = schema_seconds.into();

    // every execution and every load, as they happen
    let mut times: Vec<[String; 6]> = Vec::new();
    let mut loads: Vec<[String; 5]> = Vec::new();
    // every table's periods loaded so far, for a system that reads the files in place: {files} (a
    // list), {glob} (one glob, `{a,b}` for alternatives), {dir} (/run/dbo/tables/<table>, with a
    // link to each file)
    let mut loaded: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for (k, period) in all.iter().enumerate() {
        let (run, through) = (k + 1, period.clone());
        summary["at"] = serde_json::json!({"run": run, "loaded": through, "query": "load"});
        // load: the period's file of every table that has rows in it, one after the other; on the
        // Parquet files every table's, so that every table is there from the first load on
        let (mut ntables, mut nrows, mut total) = (0, 0, 0.0);
        for (table, _) in &tables {
            let (host, root) = if array_tables.contains(table) { (mounts.arrays.as_ref().unwrap(), "/data-arrays") } else { (&mounts.data, "/data") };
            let n = setup(rows_of(&host.join(table).join(format!("{period}.parquet"))))?;
            if n == 0 && sys.category == Category::Native {
                continue;
            }
            let file = format!("{root}/{table}/{period}.parquet");
            let files = loaded.entry(table.clone()).or_default();
            files.push(period.clone());
            let links = pod.sockets.join("tables").join(table);
            setup(std::fs::create_dir_all(&links).and_then(|_| std::os::unix::fs::symlink(&file, links.join(format!("{period}.parquet")))).context("linking the file"))?;
            let v = BTreeMap::from([
                ("table".to_string(), table.clone()),
                ("file".to_string(), file),
                ("files".to_string(), files.iter().map(|p| format!("'{root}/{table}/{p}.parquet'")).collect::<Vec<_>>().join(", ")),
                ("dir".to_string(), format!("/run/dbo/tables/{table}")),
                ("glob".to_string(), if files.len() == 1 { format!("{root}/{table}/{period}.parquet") } else { format!("{root}/{table}/{{{}}}.parquet", files.join(",")) }),
            ]);
            for statement in &sys.load.statement {
                // the load's limit, less what its statements before took
                let budget = cfg.load_timeout.map(|l| Duration::from_secs(l).saturating_sub(Duration::from_secs_f64(total)));
                let sql = setup(subst(statement, &v))?;
                match s.load_statement(&format!("load {through} {table}"), &sql, budget, cfg.load_timeout.unwrap_or(0))? {
                    Stmt::Ok { seconds, .. } => total += seconds,
                    Stmt::Error(e) => return Err(Failed { kind: Failure::Load, detail: format!("load {through} {table}: {}", last_line(&e)) }),
                    Stmt::Timeout => unreachable!(),
                }
            }
            ntables += (n > 0) as usize;
            nrows += n;
        }
        loads.push([run.to_string(), through.clone(), ntables.to_string(), nrows.to_string(), format!("{total:.6}")]);
        setup(write_csv(&out.join("load.csv"), &["run", "loaded", "tables", "rows", "seconds"], &loads))?;
        rows.push(Row { run, loaded: through.clone(), query: "load".into(), median: Some(total), status: "ok".into(), message: String::new() });
        eprintln!("{} / {}: run {run}: loaded {through} in {total:.1} s", sys.name, cfg.name);

        // the queries, `repetitions` times; a query that fails is left out for the rest of the run
        let last_run = k + 1 == all.len();
        let mut ok: Vec<Vec<f64>> = vec![Vec::new(); queries.len()];
        let mut bad: Vec<Option<String>> = vec![None; queries.len()];
        // why a query has no correct result, in the system's words (the website shows it)
        let mut why: Vec<String> = vec![String::new(); queries.len()];
        for rep in 1..=bench.repetitions {
            for (i, (id, sql)) in queries.iter().enumerate() {
                if bad[i].is_some() {
                    continue;
                }
                summary["at"] = serde_json::json!({"run": run, "loaded": through, "query": id});
                match s.statement(id, sql, Some(cfg.query_timeout()))? {
                    Stmt::Ok { seconds, out: result } => {
                        ok[i].push(seconds);
                        let mut status = "ok";
                        if last_run && rep == bench.repetitions {
                            // the result of the last execution is kept and checked
                            setup(std::fs::write(out.join("results").join(format!("{id}.csv")), &result).context("writing a result"))?;
                            status = "unchecked";
                            if checked {
                                status = "ok";
                                let diffs = match std::fs::read_to_string(references.join(format!("{id}.csv"))) {
                                    Ok(e) => check::compare(&check::parse_csv(&e), &check::parse_csv(&String::from_utf8_lossy(&result)), 3),
                                    Err(e) => vec![format!("no reference result: {e}")],
                                };
                                if !diffs.is_empty() {
                                    status = "wrong_result";
                                    why[i] = diffs[0].clone();
                                    s.note(&format!("{id}: wrong result"), &diffs.join("\n"));
                                }
                            }
                            if status != "ok" {
                                bad[i] = Some(status.to_string());
                            }
                        }
                        times.push([run.to_string(), through.clone(), rep.to_string(), id.clone(), format!("{seconds:.6}"), status.to_string()]);
                    }
                    Stmt::Timeout => {
                        bad[i] = Some("timeout".into());
                        why[i] = format!("no result within {} s", cfg.query_timeout());
                        times.push([run.to_string(), through.clone(), rep.to_string(), id.clone(), String::new(), "timeout".into()]);
                    }
                    Stmt::Error(e) => {
                        bad[i] = Some("error".into());
                        why[i] = last_line(&e);
                        times.push([run.to_string(), through.clone(), rep.to_string(), id.clone(), String::new(), "error".into()]);
                    }
                }
            }
            setup(write_csv(&out.join("times.csv"), &["run", "loaded", "repetition", "query", "seconds", "status"], &times))?;
        }
        for (i, (id, _)) in queries.iter().enumerate() {
            // a wrong or unchecked result still has its times
            let timed = matches!(bad[i].as_deref(), None | Some("wrong_result") | Some("unchecked")) && !ok[i].is_empty();
            rows.push(Row { run, loaded: through.clone(), query: id.clone(), median: timed.then(|| median(&mut ok[i])), status: bad[i].clone().unwrap_or_else(|| "ok".into()), message: std::mem::take(&mut why[i]) });
        }
        let count = |st: &str| bad.iter().filter(|b| b.as_deref() == Some(st)).count();
        let sum: f64 = rows.iter().filter(|r| r.run == run && r.query != "load").filter_map(|r| r.median).sum();
        eprintln!(
            "{} / {}: run {run}: {} queries ran ({sum:.1} s in total), {} timeouts, {} errors{}",
            sys.name,
            cfg.name,
            bad.iter().filter(|b| !matches!(b.as_deref(), Some("timeout") | Some("error"))).count(),
            count("timeout"),
            count("error"),
            if last_run { format!(", {} wrong results, {} unchecked", count("wrong_result"), count("unchecked")) } else { String::new() }
        );
    }
    if let Some(o) = summary.as_object_mut() {
        o.remove("at");
    }
    summary["storage_bytes"] = serde_json::json!(pod.storage_bytes().ok());
    summary["memory_peak_bytes"] = serde_json::json!(pod.memory_peak());
    drop(s);
    if sys.dir.join("stop").is_file() {
        let _ = pod.script("stop", Duration::from_secs(600), &out.join("stop.log"));
    }
    if let Some(before) = before {
        if setup(fingerprint(&mounts))? != before {
            return Err(Failed { kind: Failure::Setup, detail: "the system changed the data files: generate the dataset again".into() });
        }
    }
    Ok(())
}
