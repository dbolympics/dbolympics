//! dbolympics: a realistic multi-tenant commerce simulator and data generator for database
//! benchmarking. See docs/SIMULATOR.md.

use std::path::PathBuf;

use anyhow::Result;
use clap::{Parser, Subcommand};

mod engine;
mod packed;
mod pgarrays;
mod rng;
mod schema;
mod sim;
mod time;
mod validate;
mod value;
mod warehouse;
mod world;
mod writer;

#[allow(dead_code, non_upper_case_globals)]
pub mod tables {
    include!(concat!(env!("OUT_DIR"), "/tables.rs"));
}

#[derive(Parser)]
#[command(version, about)]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Generate the dataset as Parquet files (one directory per table).
    Generate {
        /// scale factor (~GB of CSV-equivalent data)
        #[arg(long, default_value_t = 1.0)]
        sf: f64,
        #[arg(long, default_value_t = 42)]
        seed: u64,
        /// output directory
        #[arg(long, short)]
        out: PathBuf,
        /// worker threads (default: all cores); does not change the output
        #[arg(long)]
        threads: Option<usize>,
    },
    /// Load generated Parquet into DuckDB with all constraints and run the rule queries.
    Validate {
        /// directory written by `generate`
        dir: PathBuf,
    },
    /// Check the period files: rows and bytes per period, every prefix of periods referentially
    /// complete.
    CheckPeriods {
        /// directory written by `generate`
        dir: PathBuf,
    },
    /// Write a Parquet copy of a generated dataset (same layout) with array columns as
    /// PostgreSQL array literals in text, for systems that do not read nested Parquet types.
    Pgarrays {
        /// directory written by `generate`
        input: PathBuf,
        /// output directory
        output: PathBuf,
        /// only the tables that have array columns
        #[arg(long)]
        arrays_only: bool,
    },
    /// Report rows, Parquet bytes and CSV-equivalent bytes per table.
    Measure {
        /// directory written by `generate`
        dir: PathBuf,
    },
    /// Load the empty schema into DuckDB (smoke test of the generated DDL).
    CheckSchema,
    /// Build a DuckDB database file from a generated dataset (for the query role play).
    Load {
        /// directory written by `generate`
        dir: PathBuf,
        /// DuckDB database file to create
        db: PathBuf,
    },
    /// Profile queries (JSON lines `{key, sql}`): plan, result size and fingerprint, timing.
    Profile {
        #[arg(long)]
        db: PathBuf,
        #[arg(long)]
        input: PathBuf,
        #[arg(long)]
        output: PathBuf,
    },
    /// Review and run one report request against a loaded database; print the report.
    Query {
        #[arg(long)]
        db: PathBuf,
        /// file with the SQL (one SELECT statement); `-` reads stdin
        #[arg(long)]
        sql: PathBuf,
        #[arg(long, default_value = "")]
        title: String,
        #[arg(long, default_value = "")]
        question: String,
        /// only check that it compiles (free in the role play)
        #[arg(long)]
        dry_run: bool,
        /// append a lineage record (JSON lines)
        #[arg(long)]
        log: Option<PathBuf>,
        /// JSON with role-play context for the lineage (manager, analyst, round, ...)
        #[arg(long)]
        tags: Option<String>,
    },
}

fn main() -> Result<()> {
    match Cli::parse().cmd {
        Cmd::Generate { sf, seed, out, threads } => {
            if let Some(n) = threads {
                rayon::ThreadPoolBuilder::new().num_threads(n).build_global()?;
            }
            sim::generate(&sim::Config { sf, seed }, &out)
        }
        Cmd::Validate { dir } => validate::validate(&dir),
        Cmd::Measure { dir } => validate::measure(&dir),
        Cmd::CheckPeriods { dir } => validate::check_periods(&dir),
        Cmd::Pgarrays { input, output, arrays_only } => pgarrays::convert(&input, &output, arrays_only),
        Cmd::CheckSchema => validate::check_schema(),
        Cmd::Load { dir, db } => warehouse::load(&dir, &db),
        Cmd::Profile { db, input, output } => warehouse::profile(&db, &input, &output),
        Cmd::Query { db, sql, title, question, dry_run, log, tags } => {
            let text = if sql.as_os_str() == "-" {
                let mut s = String::new();
                std::io::Read::read_to_string(&mut std::io::stdin(), &mut s)?;
                s
            } else {
                std::fs::read_to_string(&sql)?
            };
            let req = warehouse::Request { title: &title, question: &question, sql: text.trim().trim_end_matches(';'), dry_run, log: log.as_deref(), tags: tags.as_deref() };
            print!("{}", warehouse::query(&db, &req)?);
            Ok(())
        }
    }
}
