//! Chunks, row buffers, id assignment, reference resolution and the per-day finalize step.
//! See docs/SIMULATOR.md.

use std::collections::BTreeMap;
use std::path::Path;

use anyhow::{Context, Result, bail};
use rayon::prelude::*;

use crate::packed;
use crate::schema::{Table, TableId, schema, table};
use crate::time::{self, Day};
use crate::value::{Rid, Row, V};
use crate::writer::TableWriter;

/// A unit of work with its own row buffers. Only the owning simulation code mutates it.
pub struct Chunk {
    pub id: u32,
    /// the day currently being simulated
    pub day: Day,
    days: BTreeMap<Day, DayBuf>,
    /// deferred rows, packed: they are kept until the end
    deferred: Vec<Vec<(Rid, Box<[u8]>)>>,
}

struct DayBuf {
    rows: Vec<Vec<Row>>,
    deferred_counts: Vec<u32>,
}

impl DayBuf {
    fn new(n: usize) -> DayBuf {
        DayBuf { rows: (0..n).map(|_| Vec::new()).collect(), deferred_counts: vec![0; n] }
    }
}

/// Handle to a deferred row inside its chunk (its table is in the pending `rid`).
#[derive(Clone, Copy, Debug)]
pub struct DHandle {
    pub pos: u32,
    pub rid: Rid,
}

impl DHandle {
    fn table(self) -> TableId {
        self.rid.parts().0
    }
}

impl Chunk {
    pub fn new(id: u32) -> Chunk {
        let n = schema().tables.len();
        Chunk { id, day: 0, days: BTreeMap::new(), deferred: (0..n).map(|_| Vec::new()).collect() }
    }

    fn buf(&mut self, day: Day) -> &mut DayBuf {
        assert!(day >= self.day, "rows cannot be emitted into the past (day {day} < {})", self.day);
        let n = schema().tables.len();
        self.days.entry(day).or_insert_with(|| DayBuf::new(n))
    }

    /// Emit a row into a streaming table on `day` (>= the current day).
    #[track_caller]
    pub fn emit(&mut self, t: TableId, day: Day, row: Row) -> Rid {
        assert!(day < time::num_days(), "{}: row planned after the last day (day {day}, now {})", table(t).name, self.day);
        assert!(!is_deferred(t), "{} is deferred: use emit_deferred", table(t).name);
        debug_assert_eq!(row.vals.len(), table(t).columns.len());
        let chunk = self.id;
        let rows = &mut self.buf(day).rows[t.0];
        let rid = Rid::pending(t, day, chunk, rows.len() as u32);
        rows.push(row);
        rid
    }

    /// Emit a row into a deferred table: it gets its id from `day` but is written at the end
    /// and can be updated until then.
    #[track_caller]
    pub fn emit_deferred(&mut self, t: TableId, day: Day, row: Row) -> DHandle {
        assert!(day < time::num_days(), "{}: row planned after the last day (day {day}, now {})", table(t).name, self.day);
        assert!(is_deferred(t), "{} is not deferred: register it in deferred_tables()", table(t).name);
        let chunk = self.id;
        let cnt = &mut self.buf(day).deferred_counts[t.0];
        let rid = Rid::pending(t, day, chunk, *cnt);
        *cnt += 1;
        let v = &mut self.deferred[t.0];
        v.push((rid, packed::pack(&row)));
        DHandle { pos: (v.len() - 1) as u32, rid }
    }

    /// The deferred row, to change: it is packed again when the returned guard is dropped.
    pub fn deferred_mut(&mut self, h: DHandle) -> DeferredMut<'_> {
        let packed = &mut self.deferred[h.table().0][h.pos as usize].1;
        DeferredMut { row: packed::unpack(packed), packed }
    }

    /// A copy of the deferred row.
    pub fn deferred_ref(&self, h: DHandle) -> Row {
        packed::unpack(&self.deferred[h.table().0][h.pos as usize].1)
    }
}

/// A deferred row being changed (see `Chunk::deferred_mut`).
pub struct DeferredMut<'a> {
    row: Row,
    packed: &'a mut Box<[u8]>,
}

impl std::ops::Deref for DeferredMut<'_> {
    type Target = Row;
    fn deref(&self) -> &Row {
        &self.row
    }
}

impl std::ops::DerefMut for DeferredMut<'_> {
    fn deref_mut(&mut self) -> &mut Row {
        &mut self.row
    }
}

impl Drop for DeferredMut<'_> {
    fn drop(&mut self) {
        *self.packed = packed::pack(&self.row);
    }
}

// --------------------------------------------------------------------------------------
// table configuration
// --------------------------------------------------------------------------------------

static DEFERRED: std::sync::OnceLock<Vec<bool>> = std::sync::OnceLock::new();

pub fn set_deferred(tables: &[TableId]) {
    let mut v = vec![false; schema().tables.len()];
    for t in tables {
        v[t.0] = true;
    }
    DEFERRED.set(v).expect("set_deferred called twice");
}

static POLY_TARGETS: std::sync::OnceLock<Vec<TableId>> = std::sync::OnceLock::new();

/// Tables that are referenced without a foreign key (polymorphic `entity_id` columns).
pub fn set_poly_targets(tables: &[TableId]) {
    POLY_TARGETS.set(tables.to_vec()).expect("set_poly_targets called twice");
}

pub fn is_deferred(t: TableId) -> bool {
    DEFERRED.get().expect("set_deferred not called")[t.0]
}

/// Called for every row of a table at write time, in id order, after references are
/// resolved: per-tenant sequences and similar.
pub trait Hook: Send {
    fn row(&mut self, row: &mut Row);
}

// --------------------------------------------------------------------------------------
// the engine: ids, offsets, writers
// --------------------------------------------------------------------------------------

/// The data files of one table, one per period (`time::periods()`): the rows that existed
/// before the 2023 migration and those of 2023 and 2024, then one file per quarter of 2025 by the
/// day the engine created the row.
struct PeriodFiles {
    /// the files before this one are closed
    cur: usize,
    writers: Vec<TableWriter>,
}

impl PeriodFiles {
    fn new(t: &'static Table, out: &Path) -> PeriodFiles {
        PeriodFiles { cur: 0, writers: time::periods().iter().map(|p| TableWriter::new(t, out, p)).collect() }
    }

    /// Rows arrive in creation order, so a file is closed as soon as a row of a later quarter
    /// arrives.
    fn push(&mut self, day: Day, row: &Row) -> Result<()> {
        let p = time::period_of_day(day);
        if p < self.cur {
            bail!("rows of {} arrive out of creation order ({} after {})", self.writers[0].table_name(), time::periods()[p], time::periods()[self.cur]);
        }
        while self.cur < p {
            self.writers[self.cur].finish()?;
            self.cur += 1;
        }
        self.writers[p].push(row)
    }

    fn finish(&mut self) -> Result<()> {
        for w in &mut self.writers[self.cur..] {
            w.finish()?;
        }
        self.cur = self.writers.len();
        Ok(())
    }

    fn total_rows(&self) -> u64 {
        self.writers.iter().map(|w| w.total_rows).sum()
    }
}

pub struct Engine {
    nchunks: usize,
    next_id: Vec<i64>,
    /// first id per (table, day, chunk) for tables that can be referenced or are deferred
    starts: Vec<Vec<Option<Box<[i64]>>>>,
    writers: Vec<PeriodFiles>,
    hooks: Vec<Option<Box<dyn Hook>>>,
    finalized: Option<Day>,
}

impl Engine {
    /// Writes `out/<table>/<period>.parquet` for every table and period.
    pub fn new(out: &Path, nchunks: usize, ndays: Day) -> Engine {
        let s = schema();
        Engine {
            nchunks,
            next_id: vec![1; s.tables.len()],
            starts: s.tables.iter().map(|_| vec![None; ndays as usize]).collect(),
            writers: s.tables.iter().map(|t| PeriodFiles::new(t, out)).collect(),
            hooks: s.tables.iter().map(|_| None).collect(),
            finalized: None,
        }
    }

    pub fn set_hook(&mut self, t: TableId, h: Box<dyn Hook>) {
        self.hooks[t.0] = Some(h);
    }

    fn keep_starts(t: TableId) -> bool {
        schema().is_fk_target[t.0] || is_deferred(t) || POLY_TARGETS.get().is_some_and(|v| v.contains(&t))
    }

    /// Finalize `day`: assign ids for all rows created that day and write the streaming ones.
    /// `chunks` must contain every chunk, ordered by id.
    pub fn finalize_day(&mut self, day: Day, chunks: &mut [&mut Chunk]) -> Result<()> {
        if let Some(f) = self.finalized {
            assert_eq!(day, f + 1, "days must be finalized in order");
        }
        let ntables = schema().tables.len();
        let mut bufs: Vec<Option<DayBuf>> = Vec::with_capacity(chunks.len());
        for (i, c) in chunks.iter_mut().enumerate() {
            assert_eq!(c.id as usize, i, "chunks must be ordered by id without gaps");
            if let Some((&d, _)) = c.days.iter().next() {
                assert!(d >= day, "chunk {} still has rows for finalized day {d}", c.id);
            }
            bufs.push(c.days.remove(&day));
        }
        // 1) ids: per table, chunks in order
        for t in 0..ntables {
            let mut starts = vec![0i64; self.nchunks];
            let mut any = false;
            for (c, b) in bufs.iter().enumerate() {
                starts[c] = self.next_id[t];
                if let Some(b) = b {
                    let n = b.rows[t].len() as i64 + b.deferred_counts[t] as i64;
                    any |= n > 0;
                    self.next_id[t] += n;
                }
            }
            if any {
                self.starts[t][day as usize] = Some(starts.into_boxed_slice());
            }
        }
        // 2) write streaming rows, in parallel over tables
        let mut per_table: Vec<Vec<(usize, Vec<Row>)>> = (0..ntables).map(|_| Vec::new()).collect();
        for (c, b) in bufs.into_iter().enumerate() {
            if let Some(b) = b {
                for (t, rows) in b.rows.into_iter().enumerate() {
                    if !rows.is_empty() {
                        per_table[t].push((c, rows));
                    }
                }
            }
        }
        let starts = &self.starts;
        self.writers
            .par_iter_mut()
            .zip(self.hooks.par_iter_mut())
            .zip(per_table.into_par_iter())
            .enumerate()
            .try_for_each(|(t, ((w, hook), chunks))| -> Result<()> {
                for (c, rows) in chunks {
                    let first = starts[t][day as usize].as_ref().map(|s| s[c]);
                    for (i, mut row) in rows.into_iter().enumerate() {
                        let tab = table(TableId(t));
                        if tab.has_id {
                            let start = match first {
                                Some(s) => s,
                                None => bail!("internal: no id start for {}", tab.name),
                            };
                            row.vals[0] = V::Int(start + i as i64);
                        }
                        resolve(&mut row, starts, day).with_context(|| format!("table {}", tab.name))?;
                        if let Some(h) = hook {
                            h.row(&mut row);
                        }
                        if !row.skip {
                            w.push(day, &row)?;
                        }
                    }
                }
                Ok(())
            })?;
        // only referenced or deferred tables need their id starts later
        for t in 0..ntables {
            if !Self::keep_starts(TableId(t)) {
                self.starts[t][day as usize] = None;
            }
        }
        self.finalized = Some(day);
        Ok(())
    }

    /// Write all deferred tables and close every file.
    pub fn finish(&mut self, chunks: &mut [&mut Chunk]) -> Result<Vec<(String, u64)>> {
        let last = self.finalized.expect("no day finalized");
        let ntables = schema().tables.len();
        // per table, the deferred rows of each chunk
        let mut per_table: Vec<Vec<Vec<(Rid, Box<[u8]>)>>> = (0..ntables).map(|_| Vec::new()).collect();
        for c in chunks.iter_mut() {
            if !c.days.is_empty() {
                let d = *c.days.keys().next().unwrap();
                bail!("chunk {} has rows planned after the last day (day {d})", c.id);
            }
            for (t, rows) in c.deferred.iter_mut().enumerate() {
                if !rows.is_empty() {
                    per_table[t].push(std::mem::take(rows));
                }
            }
        }
        let starts = &self.starts;
        self.writers
            .par_iter_mut()
            .zip(self.hooks.par_iter_mut())
            .zip(per_table.into_par_iter())
            .enumerate()
            .try_for_each(|(t, ((w, hook), mut parts))| -> Result<()> {
                let tab = table(TableId(t));
                // in id order: (id, part, position), a row is unpacked when it is written and freed then
                let mut order: Vec<(i64, u32, u32)> = Vec::with_capacity(parts.iter().map(Vec::len).sum());
                for (p, rows) in parts.iter().enumerate() {
                    for (i, (rid, _)) in rows.iter().enumerate() {
                        order.push((resolve_rid(*rid, starts, last)?, p as u32, i as u32));
                    }
                }
                order.sort_unstable_by_key(|(id, _, _)| *id);
                for (id, p, i) in order {
                    let (rid, packed) = &mut parts[p as usize][i as usize];
                    // deferred rows go into the period of the day they were created
                    let day = rid.parts().1;
                    let mut row = packed::unpack(&std::mem::take(packed));
                    if tab.has_id {
                        row.vals[0] = V::Int(id);
                    }
                    resolve(&mut row, starts, last).with_context(|| format!("table {}", tab.name))?;
                    if let Some(h) = hook {
                        h.row(&mut row);
                    }
                    w.push(day, &row)?;
                }
                w.finish()
            })?;
        Ok(self.writers.iter().map(|w| w.total_rows()).zip(schema().tables.iter()).map(|(n, t)| (t.name.clone(), n)).collect())
    }
}

fn resolve_rid(rid: Rid, starts: &[Vec<Option<Box<[i64]>>>], max_day: Day) -> Result<i64> {
    if !rid.is_pending() {
        return Ok(rid.raw_id());
    }
    let (t, day, chunk, idx) = rid.parts();
    if day > max_day {
        bail!("reference to a row of {} created on a later day ({day} > {max_day})", table(t).name);
    }
    match &starts[t.0][day as usize] {
        Some(s) => Ok(s[chunk as usize] + idx as i64),
        None => bail!("internal: no ids recorded for {} on day {day}", table(t).name),
    }
}

fn resolve(row: &mut Row, starts: &[Vec<Option<Box<[i64]>>>], max_day: Day) -> Result<()> {
    for v in row.vals.iter_mut() {
        if let V::Ref(r) = v {
            if r.is_pending() {
                *v = V::Int(resolve_rid(*r, starts, max_day)?);
            }
        }
    }
    Ok(())
}
