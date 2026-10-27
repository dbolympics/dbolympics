//! The simulation: world setup and the day loop (docs/SIMULATOR.md).

use std::collections::BTreeMap;
use std::path::Path;
use std::time::Instant;

use anyhow::Result;
use rayon::prelude::*;

use crate::engine::{self, Chunk, Engine, Hook};
use crate::schema::{TableId, schema};
use crate::tables;
use crate::time;
use crate::value::{Row, V};
use crate::world::world;

pub mod calendar;
pub mod capacity;
pub mod merchant;
pub mod people;
pub mod reference;
pub mod shopper;
pub mod stories;

pub struct Config {
    pub sf: f64,
    pub seed: u64,
}

/// Calibration knobs (volumes at SF1; everything scales from here).
pub struct Params {
    /// sum over merchants of 1/size_rank (Zipf normalisation)
    pub zipf_norm: f64,
    /// platform-wide new shoppers per day at the end-of-window level, at SF1
    pub new_customers_end: f64,
    /// stored (sampled, consented) anonymous sessions per new shopper
    pub anon_sessions_per_new_customer: f64,
    /// share of consented sessions stored by web analytics (recorded as sample_rate in events)
    pub anon_sample_rate: f64,
    pub shoppers_per_chunk: f64,
    /// share of pre-2023 shoppers still present at the migration
    pub migrated_survival: f64,
}

impl Params {
    fn new() -> Params {
        let n = world().merchants.len();
        Params {
            zipf_norm: (1..=n).map(|r| 1.0 / r as f64).sum(),
            new_customers_end: 11.5,
            // ~78 anonymous visits per new customer x 60% consent x 15% sampling
            anon_sessions_per_new_customer: 7.0,
            anon_sample_rate: 0.15,
            shoppers_per_chunk: 15_000.0,
            migrated_survival: 0.35,
        }
    }
}

/// Tables written at the end (rows that describe end state).
/// Tables written at the end of the simulation (rows are updated until then).
pub fn deferred_tables() -> Vec<TableId> {
    vec![tables::tenants::T, tables::users::T, tables::stock_items::T, tables::serial_numbers::T, tables::coupons::T,
        tables::segments::T, tables::landing_pages::T, tables::utm_links::T, tables::ab_tests::T, tables::ab_assignments::T,
        tables::referrals::T, tables::loyalty_accounts::T, tables::user_preferences::T, tables::device_profiles::T,
        tables::plans::T, tables::subscriptions::T, tables::subscription_items::T, tables::accounts::T, tables::wallets::T, tables::cohorts::T, tables::gift_cards::T,
        tables::categories::T, tables::category_closure::T]
}

/// Appends a per-tenant sequence number to the prefix the simulator put in `col`.
struct TenantSequence {
    col: usize,
    tenant_col: usize,
    next: BTreeMap<i64, i64>,
}

impl Hook for TenantSequence {
    fn row(&mut self, row: &mut Row) {
        let V::Int(tenant) = row.vals[self.tenant_col] else { panic!("tenant_id not resolved") };
        let prefix = match &row.vals[self.col] {
            V::Str(s) => s.clone(),
            V::Static(s) => s.to_string(),
            _ => String::new(),
        };
        let n = self.next.entry(tenant).or_insert(0);
        *n += 1;
        row.vals[self.col] = V::Str(if prefix == "#" { format!("#{}", 1000 + *n) } else { format!("{prefix}{:06}", 100_000 + *n) });
    }
}

pub fn generate(cfg: &Config, out: &Path) -> Result<()> {
    let t0 = Instant::now();
    engine::set_deferred(&deferred_tables());
    // referenced through polymorphic entity_id / reference_id columns only
    engine::set_poly_targets(&[tables::data_subject_requests::T, tables::tenant_settings::T, tables::rate_limits::T]);
    std::fs::create_dir_all(out)?;
    let p = Params::new();
    let w = world();
    let ndays = time::num_days();

    // chunk layout: 0 = global, then one per merchant, then the shopper chunks
    let mut global = Chunk::new(0);
    let mut merchants: Vec<merchant::MerchantSim> =
        w.merchants.iter().enumerate().map(|(i, m)| merchant::MerchantSim::new(i, m, 1 + i as u32, cfg, &p)).collect();
    let mut shoppers = Vec::new();
    let mut next_chunk = 1 + merchants.len() as u32;
    let mut ranges = Vec::new();
    for ms in &merchants {
        ranges.push(shoppers.len()..shoppers.len() + ms.shopper_chunks);
        for k in 0..ms.shopper_chunks {
            shoppers.push(shopper::ShopperChunk::new(ms.idx, k, next_chunk, cfg.seed));
            next_chunk += 1;
        }
    }
    let nchunks = next_chunk as usize;
    eprintln!("sf={} seed={}: {} merchants, {} shopper chunks", cfg.sf, cfg.seed, merchants.len(), shoppers.len());
    let mut eng = Engine::new(out, nchunks, ndays);
    eng.set_hook(tables::orders::T, Box::new(TenantSequence { col: tables::orders::ORDER_NUMBER, tenant_col: tables::orders::TENANT_ID, next: BTreeMap::new() }));
    eng.set_hook(tables::invoices::T, Box::new(TenantSequence { col: tables::invoices::INVOICE_NUMBER, tenant_col: tables::invoices::TENANT_ID, next: BTreeMap::new() }));
    eng.set_hook(tables::credit_notes::T, Box::new(TenantSequence { col: tables::credit_notes::CREDIT_NOTE_NUMBER, tenant_col: tables::credit_notes::TENANT_ID, next: BTreeMap::new() }));
    eng.set_hook(tables::order_returns::T, Box::new(TenantSequence { col: tables::order_returns::RMA_NUMBER, tenant_col: tables::order_returns::TENANT_ID, next: BTreeMap::new() }));

    let ncarriers = crate::world::carriers().len();
    let mut carrier_q: Vec<capacity::Queue> = (0..ncarriers).map(|_| capacity::Queue::default()).collect();
    let mut carrier_delay = vec![0.0f64; ncarriers];
    global.day = 0;
    emit_lookups(&mut global);
    let refs = reference::emit(&mut global, cfg.seed);

    for day in 0..ndays {
        global.day = day;
        {
            let shoppers_ref = &shoppers;
            merchants.par_iter_mut().for_each(|m| {
                let outs: Vec<&merchant::DayOut> = if day == 0 { vec![] } else { shoppers_ref[ranges[m.idx].clone()].iter().filter_map(|s| s.outbox.get(&(day - 1))).collect() };
                m.day(day, cfg, &p, &refs, &outs)
            });
            // carrier networks are shared by all merchants
            let mut volume = vec![0u32; carrier_q.len()];
            if day > 0 {
                for s in shoppers_ref {
                    if let Some(o) = s.outbox.get(&(day - 1)) {
                        for (c, n) in &o.shipments {
                            volume[*c] += n;
                        }
                    }
                }
            }
            for (c, q) in carrier_q.iter_mut().enumerate() {
                carrier_delay[c] = q.step(volume[c] as f64, 1.35, stories::carrier_capacity(&crate::world::carriers()[c], day));
            }
        }
        let net = &carrier_delay;
        shoppers.par_iter_mut().for_each(|s| s.day(day, &merchants[s.merchant], &p, &refs, net));
        if day + 1 == ndays {
            // end of the window: final stock levels (incl. today's operations)
            for m in merchants.iter_mut() {
                let ops: Vec<&(usize, usize, merchant::StockOp, i64)> = shoppers[ranges[m.idx].clone()].iter().filter_map(|s| s.outbox.get(&day)).flat_map(|o| o.stock.iter()).collect();
                m.finish_inventory(&ops);
                let used: Vec<crate::value::Rid> = shoppers[ranges[m.idx].clone()].iter().filter_map(|s| s.outbox.get(&day)).flat_map(|o| o.coupons.iter().copied()).collect();
                m.count_redemptions(&used);
                m.finish_pricing();
                let outs: Vec<&merchant::DayOut> = shoppers[ranges[m.idx].clone()].iter().filter_map(|s| s.outbox.get(&day)).collect();
                m.finish_marketing(&outs);
                m.finish_analytics(&outs);
            }
        }
        let mut all: Vec<&mut Chunk> = Vec::with_capacity(nchunks);
        all.push(&mut global);
        all.extend(merchants.iter_mut().map(|m| &mut m.chunk));
        all.extend(shoppers.iter_mut().map(|s| &mut s.chunk));
        eng.finalize_day(day, &mut all)?;
        if day % 100 == 0 || day + 1 == ndays {
            eprintln!("  day {day:>4} {}  {:.1}s", time::date_of(day), t0.elapsed().as_secs_f64());
        }
    }
    // only the chunks are needed to write the deferred rows: free the rest of the simulation first
    let mut chunks: Vec<Chunk> = Vec::with_capacity(nchunks);
    chunks.push(global);
    chunks.extend(merchants.into_iter().map(|m| m.chunk));
    chunks.extend(shoppers.into_iter().map(|s| s.chunk));
    let mut all: Vec<&mut Chunk> = chunks.iter_mut().collect();
    let counts = eng.finish(&mut all)?;
    let total: u64 = counts.iter().map(|(_, n)| n).sum();
    let nonempty = counts.iter().filter(|(_, n)| *n > 0).count();
    let mut top: Vec<_> = counts.iter().filter(|(_, n)| *n > 0).collect();
    top.sort_by_key(|(_, n)| std::cmp::Reverse(*n));
    for (t, n) in top.iter().take(20) {
        eprintln!("  {t:<28} {n:>12}");
    }
    eprintln!("wrote {total} rows in {nonempty}/{} tables to {} in {:.1}s", counts.len(), out.display(), t0.elapsed().as_secs_f64());
    Ok(())
}

/// Static rows of the lookup tables (former ENUMs), straight from schema.json.
fn emit_lookups(c: &mut Chunk) {
    for t in &schema().tables {
        for r in &t.lookup_rows {
            let mut row = Row::new(t.columns.len());
            for (i, v) in r.iter().enumerate() {
                row.vals[i] = match v {
                    serde_json::Value::String(s) => V::Str(s.clone()),
                    serde_json::Value::Number(n) => V::Int(n.as_i64().unwrap()),
                    other => panic!("unsupported lookup value {other}"),
                };
            }
            c.emit(t.id, 0, row);
        }
    }
}
