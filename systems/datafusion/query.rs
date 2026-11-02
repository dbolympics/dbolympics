//! DataFusion's query program: DataFusion embedded, for the whole run. It serves the runner's
//! protocol (../dbo).
//!
//! DataFusion has no storage of its own: it queries the Parquet files where they are, every table
//! an external table over its files (system.toml). Everything is DataFusion's SQL. A result is
//! written by Arrow's CSV writer; a timeout drops the running query, which stops it.
//!
//!   query <memory pool bytes>
//!
//! Its threads (Tokio's, and DataFusion's partitions) are as many as the container's cores, by
//! default. Its memory is not: DataFusion's default pool has no limit.

use std::sync::Arc;

use datafusion::arrow::csv::WriterBuilder;
use datafusion::execution::disk_manager::DiskManagerBuilder;
use datafusion::execution::memory_pool::FairSpillPool;
use datafusion::execution::runtime_env::RuntimeEnvBuilder;
use datafusion::prelude::{SessionConfig, SessionContext};
use tokio::runtime::Runtime;
use tokio::sync::Notify;

// --- The system ----------------------------------------------------------------------------------

struct System {
    rt: Runtime,
    ctx: SessionContext,
    stop: Arc<Notify>,
}
struct Cancel(Arc<Notify>);

impl System {
    fn connect() -> (System, Cancel) {
        let args: Vec<String> = std::env::args().collect();
        let memory = args[1].parse::<usize>().unwrap();
        let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
        let runtime = RuntimeEnvBuilder::new().with_memory_pool(Arc::new(FairSpillPool::new(memory))).with_disk_manager_builder(DiskManagerBuilder::default()).build_arc().expect("DataFusion's runtime");
        let ctx = SessionContext::new_with_config_rt(SessionConfig::new(), runtime);
        let stop = Arc::new(Notify::new());
        (System { rt, ctx, stop: stop.clone() }, Cancel(stop))
    }

    fn run(&mut self, sql: &str, _timeout: u32) -> Result<Vec<u8>, String> {
        self.rt.block_on(async {
            tokio::select! {
                r = run(&self.ctx, sql) => r,
                _ = self.stop.notified() => Err("cancelled".into()),
            }
        })
    }
}

impl Cancel {
    /// notify_waiters keeps nothing for later: a cancel after the end cannot reach the next statement
    fn cancel(&self) {
        self.0.notify_waiters();
    }
}

async fn run(ctx: &SessionContext, sql: &str) -> Result<Vec<u8>, String> {
    let e = |e: datafusion::error::DataFusionError| e.to_string();
    let batches = ctx.sql(sql).await.map_err(e)?.collect().await.map_err(e)?;
    let mut out = Vec::new();
    let mut w = WriterBuilder::new().with_header(false).build(&mut out);
    for b in &batches {
        w.write(b).map_err(|e| e.to_string())?;
    }
    drop(w);
    Ok(out)
}

// --- The runner's protocol (../dbo) -------------------------------------------------------------

fn main() {
    let (mut system, cancel) = System::connect();
    dbo::serve(|sql, timeout| system.run(sql, timeout), || cancel.cancel());
}
