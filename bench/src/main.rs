//! dbo-bench: the dbolympics benchmark runner. See docs/RUNNER.md.

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};

mod check;
mod client;
mod config;
mod ddl;
mod dialect;
mod exact;
mod podman;
mod results;
mod run;
mod system;

#[derive(Parser)]
#[command(version, about)]
struct Cli {
    /// the repository (default: found from the current directory)
    #[arg(long, global = true)]
    repo: Option<PathBuf>,
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Run the benchmark: every system in every configuration.
    Run {
        /// the benchmark file, e.g. bench/benchmark_sf1.toml
        #[arg(long)]
        benchmark: PathBuf,
        /// only these systems (default: the benchmark's)
        #[arg(long)]
        system: Vec<String>,
        /// only these configurations (default: all)
        #[arg(long)]
        config: Vec<String>,
        /// only start every system and check that it cancels a query at its timeout; no results
        #[arg(long)]
        checks_only: bool,
        /// run every system's image as it is in the storage (built before, or loaded from another
        /// machine), without building it again
        #[arg(long)]
        no_build: bool,
        /// keep every run's directory (bench/out/<date>/<config>/<system>), not only those of runs
        /// that failed: for its errors.log, or to make reference results from it
        #[arg(long)]
        keep: bool,
    },
    /// Build the images of a benchmark's systems (with their install run) and pull the images of
    /// their other containers, so that a run starts without building.
    Images {
        /// the benchmark file whose systems to build (default: every system)
        #[arg(long)]
        benchmark: Option<PathBuf>,
        /// only these systems (default: the benchmark's)
        #[arg(long)]
        system: Vec<String>,
    },
    /// Make the results of a finished run the reference results of its scale factor.
    References {
        /// the run's directory (bench/out/<date>/<config>/<system>, kept with run --keep)
        run: PathBuf,
    },
    /// Write the schema and the queries as a system gets them.
    Render {
        #[arg(long)]
        system: String,
        #[arg(long)]
        out: PathBuf,
        /// a directory of canonical queries (default: workload/queries)
        #[arg(long)]
        queries: Option<PathBuf>,
        /// with primary keys
        #[arg(long)]
        keys: bool,
        /// mark every replaced placeholder with comments, /*{name*/ ... /*}*/
        #[arg(long)]
        mark: bool,
    },
    /// Print the dialect customization points (name, parameters, default) as JSON.
    Points,
    /// Compare two results (files, or directories of q*.csv) by value.
    Check { expected: PathBuf, actual: PathBuf },
}

/// The repository: `--repo`, or the directory above the current one that has the schema.
fn repo(given: Option<PathBuf>) -> Result<PathBuf> {
    if let Some(r) = given {
        return Ok(r);
    }
    let mut d = std::env::current_dir()?;
    loop {
        if d.join("schema/schema.json").is_file() && d.join("systems").is_dir() {
            return Ok(d);
        }
        if !d.pop() {
            bail!("not inside the dbolympics repository (use --repo)");
        }
    }
}

/// Containers get no limit on locked memory (io_uring, buffer pools), which needs this process
/// to have none. bench/host-setup.sh sets that for new logins; a session from before gets it
/// here through sudo.
fn unlimited_memlock() -> Result<()> {
    let mut l = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    unsafe { libc::getrlimit(libc::RLIMIT_MEMLOCK, &mut l) };
    if l.rlim_max != libc::RLIM_INFINITY {
        let pid = std::process::id().to_string();
        let ok = std::process::Command::new("sudo").args(["-n", "prlimit", "--pid", &pid, "--memlock=unlimited:unlimited"]).status().is_ok_and(|s| s.success());
        if !ok {
            bail!("the limit on locked memory is not unlimited: run bench/host-setup.sh and log in again");
        }
    }
    let l = libc::rlimit { rlim_cur: libc::RLIM_INFINITY, rlim_max: libc::RLIM_INFINITY };
    if unsafe { libc::setrlimit(libc::RLIMIT_MEMLOCK, &l) } != 0 {
        bail!("cannot lift the limit on locked memory: run bench/host-setup.sh and log in again");
    }
    Ok(())
}

fn run_cmd(repo: &Path, benchmark: &Path, only_systems: &[String], only_configs: &[String], checks_only: bool, keep: bool, no_build: bool) -> Result<bool> {
    let file = if benchmark.is_absolute() || benchmark.exists() { benchmark.to_path_buf() } else { repo.join(benchmark) };
    let bench = config::Benchmark::read(&file)?;
    for c in only_configs {
        if !bench.configs.iter().any(|d| d.name == *c) {
            bail!("no configuration {c} in {}", file.display());
        }
    }
    let names = system_names(repo, bench.systems.as_ref(), only_systems)?;
    let systems: Vec<system::System> = names.iter().map(|n| system::System::read(&repo.join("systems").join(n))).collect::<Result<_>>()?;
    unlimited_memlock()?;
    let ctx = run::Ctx { repo: repo.to_path_buf(), podman: podman::Podman::new(&repo.join("bench"))?, date: chrono::Local::now().format("%Y-%m-%d").to_string(), provenance: provenance(repo, &file), checks_only, no_build };
    let mut all_ok = true;
    for cfg in bench.configs.iter().filter(|c| only_configs.is_empty() || only_configs.contains(&c.name)) {
        for sys in &systems {
            let result_file = repo.join("systems").join(&sys.name).join("results").join(&ctx.date).join(format!("{}.csv", cfg.name));
            let keys = cfg.keys.unwrap_or(bench.keys);
            if !sys.keys.contains(&keys) {
                eprintln!("{} / {}: keys = {} is not supported by the system, skipped", sys.name, cfg.name, keys.name());
                results::write(&result_file, &[results::Row { run: 0, loaded: String::new(), query: String::new(), median: None, status: "not_supported".into(), message: format!("keys = {} is not supported by the system", keys.name()) }])?;
                std::fs::write(result_file.with_extension("json"), serde_json::to_string_pretty(&run::describe(&ctx, &bench, sys, cfg))? + "\n")?;
                continue;
            }
            if let Some(limit) = sys.scale_limit.filter(|&l| cfg.sf >= l) {
                eprintln!("{} / {}: disabled from sf {} on (scale_limit), skipped: {}", sys.name, cfg.name, config::sf_name(limit),
                          sys.scale_limit_message.as_deref().unwrap_or_default());
                continue;
            }
            let o = run::run(&ctx, &bench, sys, cfg);
            // the run's directory (logs, every execution, the results) is kept for a run that failed,
            // and with --keep
            let out = ctx.out_dir(&cfg.name, &sys.name);
            let clean = |ok: bool| {
                if ok && !keep {
                    let _ = std::fs::remove_dir_all(&out);
                    // and the configuration's and the date's directories, when nothing else is in them
                    out.ancestors().skip(1).take(2).for_each(|d| { let _ = std::fs::remove_dir(d); });
                }
            };
            if checks_only {
                let rec: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(out.join("run.json"))?)?;
                let outcome = o.failure.as_ref().map_or_else(|| rec["timeout_check"].as_str().unwrap_or("?").to_string(), |f| format!("{}: {}", f.kind.status(), f.detail));
                println!("{}: {outcome}", sys.name);
                all_ok &= o.failure.is_none();
                clean(o.failure.is_none());
                ctx.podman.clear()?;
                continue;
            }
            results::write(&result_file, &o.rows)?;
            // what ran: the configuration, the commit, the host, the images, the system's version
            std::fs::copy(out.join("run.json"), result_file.with_extension("json")).context("run.json")?;
            all_ok &= o.failure.is_none();
            clean(o.failure.is_none());
            eprintln!("{} / {}: results in {}", sys.name, cfg.name, result_file.display());
            // the configuration's databases go before the next configuration starts
            ctx.podman.clear()?;
        }
    }
    Ok(all_ok)
}

/// Where the results of a campaign come from, kept with each of them: the benchmark file, the
/// commit of the repository (dirty if a tracked file outside the results differs from it), the
/// host.
fn provenance(repo: &Path, benchmark: &Path) -> serde_json::Map<String, serde_json::Value> {
    let git = |args: &[&str]| std::process::Command::new("git").arg("-C").arg(repo).args(args).output().ok().filter(|o| o.status.success()).map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());
    let commit = git(&["rev-parse", "HEAD"]);
    let dirty = git(&["status", "--porcelain", "--untracked-files=no", "--", ".", ":(exclude)systems/*/results/*"]).map(|s| !s.is_empty());
    let cpuinfo = std::fs::read_to_string("/proc/cpuinfo").unwrap_or_default();
    let cpu = cpuinfo.lines().find_map(|l| l.strip_prefix("model name").map(|r| r.trim_start_matches([' ', '\t', ':']).to_string()));
    let cpus = cpuinfo.lines().filter(|l| l.starts_with("processor")).count();
    let memory = std::fs::read_to_string("/proc/meminfo").ok().and_then(|t| t.lines().find_map(|l| l.strip_prefix("MemTotal:")?.trim().strip_suffix(" kB")?.parse::<u64>().ok()));
    let kernel = std::fs::read_to_string("/proc/sys/kernel/osrelease").ok().map(|s| s.trim().to_string());
    let file = benchmark.canonicalize().ok().and_then(|f| Some(f.strip_prefix(repo.canonicalize().ok()?).ok()?.display().to_string())).unwrap_or_else(|| benchmark.display().to_string());
    let v = serde_json::json!({"benchmark": file, "commit": commit, "dirty": dirty, "host": {"cpu": cpu, "cpus": cpus, "memory_bytes": memory.map(|k| k << 10), "kernel": kernel}});
    v.as_object().cloned().unwrap_or_default()
}

/// The systems to run: those named on the command line, else the benchmark's, else every
/// directory of `systems/` with a system.toml, by name.
fn system_names(repo: &Path, listed: Option<&Vec<String>>, only_systems: &[String]) -> Result<Vec<String>> {
    if !only_systems.is_empty() {
        return Ok(only_systems.to_vec());
    }
    if let Some(s) = listed {
        return Ok(s.clone());
    }
    let mut names = Vec::new();
    for e in std::fs::read_dir(repo.join("systems"))? {
        let e = e?;
        if e.path().join("system.toml").is_file() {
            names.push(e.file_name().to_string_lossy().into_owned());
        }
    }
    names.sort();
    Ok(names)
}

fn images_cmd(repo: &Path, benchmark: Option<&Path>, only_systems: &[String]) -> Result<()> {
    let bench = match benchmark {
        Some(b) => Some(config::Benchmark::read(&if b.is_absolute() || b.exists() { b.to_path_buf() } else { repo.join(b) })?),
        None => None,
    };
    let names = system_names(repo, bench.as_ref().and_then(|b| b.systems.as_ref()), only_systems)?;
    let podman = podman::Podman::new(&repo.join("bench"))?;
    for n in &names {
        let sys = system::System::read(&repo.join("systems").join(n))?;
        let work = repo.join("bench/out/images").join(n);
        std::fs::create_dir_all(&work)?;
        podman.system_image(&repo.join("bench"), &sys, &work)?;
        for c in &sys.containers {
            podman.pull(&c.image)?;
        }
        eprintln!("{n}: ready");
    }
    Ok(())
}

fn references_cmd(repo: &Path, dir: &Path) -> Result<()> {
    let text = std::fs::read_to_string(dir.join("run.json")).with_context(|| format!("reading {}", dir.join("run.json").display()))?;
    let info: serde_json::Value = serde_json::from_str(&text)?;
    if info["complete"] != true {
        bail!("{} is not a finished run", dir.display());
    }
    let sf = config::sf_name(info["sf"].as_f64().context("run.json: sf")?);
    let last = config::periods().pop().unwrap();
    let out = repo.join("workload/results").join(format!("sf{sf}")).join(format!("through-{last}"));
    std::fs::create_dir_all(&out)?;
    let mut n = 0;
    for e in std::fs::read_dir(dir.join("results"))?.flatten() {
        let name = e.file_name();
        if name.to_string_lossy().ends_with(".csv") {
            std::fs::write(out.join(&name), exact::convert_csv(&std::fs::read(e.path())?))?;
            n += 1;
        }
    }
    let manifest = serde_json::json!({"scale_factor": sf, "seed": 42, "queries": n, "loaded": last, "engine": info["system"], "config": info["config"], "date": info["date"],
        "format": "CSV, no header, rows in query order, NULL as an empty field; compare with dbo-bench check"});
    std::fs::write(out.join("MANIFEST.json"), serde_json::to_string_pretty(&manifest)? + "\n")?;
    println!("wrote {n} reference results to {}", out.display());
    Ok(())
}

fn render_cmd(repo: &Path, name: &str, out: &Path, queries: Option<&Path>, keys: bool, mark: bool) -> Result<()> {
    let sys = system::System::read(&repo.join("systems").join(name))?;
    let d = dialect::Dialect::new(&sys.dialect)?;
    std::fs::create_dir_all(out)?;
    let k = if keys { config::Keys::Primary } else { config::Keys::None };
    let tables = ddl::render(repo, &ddl::Types::new(&sys.dialect.types)?, keys, sys.ddl_suffix(k))?;
    std::fs::write(out.join("schema.sql"), tables.iter().map(|(_, s)| format!("{s};\n\n")).collect::<String>())?;
    std::fs::write(out.join("settings.sql"), d.settings.iter().map(|s| format!("{s};\n")).collect::<String>())?;
    let mut n = 0;
    for e in std::fs::read_dir(queries.map_or(repo.join("workload/queries"), Path::to_path_buf))?.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        if name.ends_with(".sql") {
            let sql = std::fs::read_to_string(e.path())?;
            let text = if mark { d.render_marked(&sql) } else { d.render(&sql) };
            std::fs::write(out.join(&name), text.with_context(|| name.clone())?)?;
            n += 1;
        }
    }
    println!("wrote the schema, the settings and {n} queries to {}", out.display());
    Ok(())
}

fn check_cmd(expected: &Path, actual: &Path) -> Result<bool> {
    let read = |p: &Path| -> Result<Vec<check::Row>> { Ok(check::parse_csv(&std::fs::read_to_string(p).with_context(|| format!("reading {}", p.display()))?)) };
    if expected.is_file() {
        let diffs = check::compare(&read(expected)?, &read(actual)?, 5);
        diffs.iter().for_each(|d| println!("{d}"));
        return Ok(diffs.is_empty());
    }
    let mut files: Vec<PathBuf> = std::fs::read_dir(expected)?.flatten().map(|e| e.path()).filter(|p| p.extension().is_some_and(|x| x == "csv")).collect();
    files.sort();
    let (mut same, mut differ, mut missing) = (0, 0, 0);
    for f in &files {
        let g = actual.join(f.file_name().unwrap());
        if !g.is_file() {
            missing += 1;
            continue;
        }
        let diffs = check::compare(&read(f)?, &read(&g)?, 5);
        if diffs.is_empty() {
            same += 1;
        } else {
            differ += 1;
            println!("{}: {}", f.file_stem().unwrap().to_string_lossy(), diffs.join(" | "));
        }
    }
    println!("{same} equal, {differ} different, {missing} missing");
    Ok(differ == 0 && missing == 0)
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    let repo = repo(cli.repo)?;
    let ok = match cli.cmd {
        Cmd::Run { benchmark, system, config, checks_only, keep, no_build } => run_cmd(&repo, &benchmark, &system, &config, checks_only, keep, no_build)?,
        Cmd::Images { benchmark, system } => images_cmd(&repo, benchmark.as_deref(), &system).map(|_| true)?,
        Cmd::References { run } => references_cmd(&repo, &run).map(|_| true)?,
        Cmd::Render { system, out, queries, keys, mark } => render_cmd(&repo, &system, &out, queries.as_deref(), keys, mark).map(|_| true)?,
        Cmd::Points => {
            let points: Vec<_> = dialect::points().into_iter().map(|(name, params, default)| serde_json::json!({"name": name, "params": params, "default": default})).collect();
            println!("{}", serde_json::to_string_pretty(&points)?);
            true
        }
        Cmd::Check { expected, actual } => check_cmd(&expected, &actual)?,
    };
    std::process::exit(if ok { 0 } else { 1 });
}
