//! Inventory: suppliers, stock per variant, purchase orders and receipts, lots, serial numbers,
//! cycle counts. Stock is a capacity: shoppers cannot buy what is not available, so stockouts
//! emerge when demand outruns the reorder policy (peaks) or suppliers are late.
//!
//! Shopper chunks never touch stock directly: they report stock operations through the outbox
//! (sold, shipped, released, restocked) and the merchant applies them the next day.

use std::collections::{BTreeMap, VecDeque};

use super::MerchantSim;
use crate::engine::DHandle;
use crate::rng::Rng;
use crate::sim::people;
use crate::tables::*;
use crate::time::{self, Day, MICROS_PER_DAY, MICROS_PER_HOUR, Ts};
use crate::value::{Rid, Row, V};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum StockOp {
    /// reserved by a paid order
    Sold,
    /// left the warehouse
    Shipped,
    /// reservation released (cancelled before shipping)
    Released,
    /// returned to stock
    Restocked,
}

pub struct Slot {
    pub item: DHandle,
    pub location: Rid,
    pub on_hand: i64,
    pub available: i64,
    pub reserved: i64,
    /// expected daily units (exponentially weighted)
    pub demand: f64,
    pub inbound: i64,
    pub supplier: usize,
    pub lot: Option<Rid>,
    /// the second supplier also lists this variant
    has_alt: bool,
    serials: VecDeque<DHandle>,
    last_counted: Option<Ts>,
}

pub struct Supplier {
    pub rid: Rid,
    /// quoted lead time (what the supplier promises)
    pub lead_days: f64,
    pub currency: &'static str,
    pub level: f64,
    /// 0 domestic, 1 European, 2 Asian
    region: usize,
    /// hidden: how much longer than quoted deliveries really take, and how much they vary
    bias: f64,
    spread: f64,
    /// the merchant's planning lead time (quoted, or learned from past deliveries)
    planned_lead: f64,
    /// typical order size (units), for the size effect
    typical_qty: f64,
}

struct Arrival {
    po: Rid,
    line: Rid,
    pidx: usize,
    vidx: usize,
    qty: i64,
    rejected: i64,
}

#[derive(Default)]
pub struct Inventory {
    pub slots: Vec<Vec<Slot>>,
    pub suppliers: Vec<Supplier>,
    /// per warehouse: (pick, bulk, returns) locations
    pub locations: Vec<(Rid, Rid, Rid)>,
    arrivals: BTreeMap<Day, Vec<(usize, Arrival)>>,
    po_seq: u32,
    receipt_seq: u32,
    serial_seq: u64,
    /// merchant-wide expected units per day, for initial stock
    pub units_per_day: f64,
    /// S4: the supplier whose deliveries slow down
    pub slow: Option<usize>,
    /// how quickly the merchant updates its planning lead times from actual deliveries
    /// (0: always plans with the quoted lead time)
    learn: f64,
    /// purchase order (by sequence) -> (supplier, actual lead days, arrival time)
    po_meta: BTreeMap<usize, (usize, f64, Ts)>,
    /// S5: the defective lots (of one popular stand mixer) and that product
    pub defective: Vec<Rid>,
    defect_product: Option<usize>,
}

impl Inventory {
    pub fn new(units_per_day: f64) -> Inventory {
        Inventory { units_per_day, ..Default::default() }
    }
}

/// Chinese New Year (Asian suppliers close for one to two weeks around it).
fn chinese_new_year(year: i32) -> chrono::NaiveDate {
    let (m, d) = match year {
        2022 => (2, 1),
        2023 => (1, 22),
        2024 => (2, 10),
        2025 => (1, 29),
        2026 => (2, 17),
        _ => (2, 6),
    };
    chrono::NaiveDate::from_ymd_opt(year, m, d).unwrap()
}

/// Whether the production window overlaps [event + from, event + to] (days).
fn overlaps(window: (chrono::NaiveDate, chrono::NaiveDate), event: chrono::NaiveDate, from: i64, to: i64) -> bool {
    window.0 <= event + chrono::Duration::days(to) && window.1 >= event + chrono::Duration::days(from)
}

fn lot_tracked(vertical: &str, kind: &str) -> Option<i64> {
    // shelf life in days (0 = tracked lots without expiry)
    match vertical {
        "food_coffee" => Some(365),
        "pet_supplies" => Some(540),
        "beauty" => Some(730),
        _ if kind.contains("Stand Mixer") || kind.contains("Kettle") => Some(0),
        _ => None,
    }
}

pub(super) fn cost_ratio(vertical: &str) -> f64 {
    match vertical {
        "consumer_electronics" => 0.72,
        "food_coffee" | "pet_supplies" => 0.5,
        "beauty" => 0.28,
        "apparel_footwear" | "jewelry_accessories" => 0.38,
        "b2b_industrial" | "b2b_office" => 0.62,
        _ => 0.45,
    }
}

impl MerchantSim {
    pub(super) fn setup_inventory(&mut self, day: Day, ts: Ts, rng: &mut Rng, sf: f64) {
        let tenant = self.tenant_rid();
        for (wi, wh) in self.warehouses.iter().enumerate() {
            let mut locs = Vec::new();
            for (code, name, kind, pickable) in [("A-PICK", "Pick face", "pick", true), ("B-BULK", "Bulk storage", "bulk", false), ("R-RET", "Returns", "returns", false)] {
                let mut r = Row::new(stock_locations::NCOLS);
                r.set(stock_locations::TENANT_ID, tenant)
                    .set(stock_locations::WAREHOUSE_ID, wh.rid)
                    .set(stock_locations::CODE, format!("{code}-{:02}", wi + 1))
                    .set(stock_locations::NAME, name)
                    .set(stock_locations::KIND, kind)
                    .set(stock_locations::IS_PICKABLE, pickable)
                    .set(stock_locations::IS_ACTIVE, true)
                    .set(stock_locations::CREATED_AT, V::Ts(ts))
                    .set(stock_locations::UPDATED_AT, V::Ts(ts));
                locs.push(self.chunk.emit(stock_locations::T, day, r));
            }
            self.inv.locations.push((locs[0], locs[1], locs[2]));
        }
        // suppliers: domestic, European and Asian manufacturers
        let n = 2 + (4.0 * libm::pow(self.share / 0.186, 0.4) * libm::pow(sf, 0.25)).round() as usize;
        const PLACES: &[&str] = &["Norvik", "Castelo", "Hanbury", "Tessaro", "Kuntai", "Weiyang", "Dalsgaard", "Vireo", "Oakmere", "Brenholt", "Lucerna", "Haizhou", "Montval", "Arvika", "Selwyn", "Tanaka-Ri"];
        let trade = match self.m.vertical.as_str() {
            "apparel_footwear" => "Textiles",
            "consumer_electronics" => "Electronics",
            "beauty" => "Cosmetics",
            "home_living" => "Homeware",
            "sports_outdoor" => "Outdoor Gear",
            "food_coffee" => "Roasters",
            "pet_supplies" => "Pet Foods",
            "b2b_industrial" => "Industrial",
            "b2b_office" => "Office Products",
            "books_stationery" => "Paper & Print",
            _ => "Manufacturing",
        };
        for k in 0..n {
            let region = k % 3;
            let (suffix, lead, currency) = match region {
                0 => (match self.m.country.as_str() { "DE" | "AT" => "GmbH", "NL" | "BE" => "B.V.", "US" => "Inc.", "SE" => "AB", "FR" => "SAS", _ => "Ltd" }, rng.uniform(4.0, 10.0), self.m.currency.as_str()),
                1 => (["GmbH", "S.p.A.", "B.V.", "Sp. z o.o.", "Lda."][rng.below(5)], rng.uniform(7.0, 16.0), "EUR"),
                _ => ("Co., Ltd.", rng.uniform(28.0, 45.0), "USD"),
            };
            let currency: &'static str = match currency {
                "EUR" => "EUR",
                "USD" => "USD",
                "GBP" => "GBP",
                "SEK" => "SEK",
                "DKK" => "DKK",
                "NOK" => "NOK",
                _ => "EUR",
            };
            let name = format!("{} {} {}", PLACES[(k + self.idx * 3) % PLACES.len()], trade, suffix);
            let mut r = Row::new(suppliers::NCOLS);
            r.set(suppliers::TENANT_ID, tenant)
                .set(suppliers::CODE, format!("SUP-{:03}", k + 1))
                .set(suppliers::NAME, name.clone())
                .set(suppliers::CONTACT_EMAIL, format!("orders@{}.example", people::slugify(&name).replace('-', "")))
                .set(suppliers::CONTACT_PHONE, if rng.chance(0.7) { V::Str(people::phone(rng, if region == 0 { self.m.country.as_str() } else { "*" })) } else { V::Null })
                .set(suppliers::LEAD_TIME_DAYS, V::Int(lead.round() as i64))
                .set(suppliers::IS_ACTIVE, true)
                .set(suppliers::CREATED_AT, V::Ts(ts))
                .set(suppliers::UPDATED_AT, V::Ts(ts));
            let rid = self.chunk.emit(suppliers::T, day, r);
            let level = crate::world::world().catalog.price_levels.get(currency).copied().unwrap_or(1.0);
            // hidden reliability: farther suppliers quote more optimistically and vary more,
            // and some are simply sloppier than others
            let (bias_mu, spread0) = [(1.02, 0.08), (1.06, 0.14), (1.12, 0.22)][region];
            let bias = rng.lognormal(libm::log(bias_mu), 0.06);
            let spread = (spread0 * rng.lognormal(0.0, 0.35)).clamp(0.04, 0.6);
            self.inv.suppliers.push(Supplier { rid, lead_days: lead, currency, level, region, bias, spread, planned_lead: lead, typical_qty: 0.0 });
        }
        // larger merchants run tighter operations and learn real lead times from deliveries
        let p_learn = 0.3 + 0.5 * (1.0 - (self.m.size_rank as f64 / 120.0).min(1.0));
        self.inv.learn = if rng.chance(p_learn) { rng.uniform(0.15, 0.35) } else { 0.0 };
    }

    /// Stock items and supplier products for a new product's variants, with opening stock.
    pub(super) fn stock_new_product(&mut self, rng: &mut Rng, day: Day, ts: Ts, pidx: usize) {
        let tenant = self.tenant_rid();
        let p = &self.products[pidx];
        let nv = p.variants.len();
        let pop = libm::exp(p.appeal);
        let price_eur = p.price_eur;
        let ty = p.ty;
        let kind = self.product_types[ty].kind.clone();
        let supplier = (ty * 7 + self.idx) % self.inv.suppliers.len();
        let alt = (supplier + 1) % self.inv.suppliers.len();
        let (pick, _, _) = self.inv.locations[0];
        let migrated = ts < time::ts_of_day(0);
        let mut slots = Vec::with_capacity(nv);
        // the products live now; while the initial catalog is created, before they are, the whole initial catalog
        let live = (if self.live.is_empty() { self.initial_catalog } else { self.live.len() }).max(20) as f64;
        for vi in 0..nv {
            let v = &self.products[pidx].variants[vi];
            let (vrid, sku) = (v.rid, v.sku.clone());
            let demand = (self.inv.units_per_day * pop / live / nv as f64 * 1.2).max(0.02);
            let opening = ((demand * 42.0 * rng.lognormal(0.0, 0.3)).ceil() as i64).max(3);
            let mut has_alt = false;
            for (si, pref) in [(supplier, true), (alt, false)] {
                if !pref && !rng.chance(0.3) {
                    continue;
                }
                has_alt |= !pref && si != supplier;
                let s = &self.inv.suppliers[si];
                let cost = (price_eur * cost_ratio(&self.m.vertical) * rng.lognormal(0.0, 0.08) * s.level * 100.0).round() as i64;
                let mut r = Row::new(supplier_products::NCOLS);
                r.set(supplier_products::TENANT_ID, tenant)
                    .set(supplier_products::SUPPLIER_ID, s.rid)
                    .set(supplier_products::VARIANT_ID, vrid)
                    .set(supplier_products::SUPPLIER_SKU, format!("{}-{}", &sku[..sku.len().min(10)], rng.digits(4)))
                    .set(supplier_products::UNIT_COST, V::Money(cost.max(1)))
                    .set(supplier_products::CURRENCY_CODE, s.currency)
                    .set(supplier_products::MIN_ORDER_QTY, V::Int(*rng.pick(&[1, 6, 12, 24, 50])))
                    .set(supplier_products::LEAD_TIME_DAYS, V::Int((s.lead_days * rng.uniform(0.9, 1.2)).round() as i64))
                    .set(supplier_products::IS_PREFERRED, pref)
                    .set(supplier_products::CREATED_AT, V::Ts(ts))
                    .set(supplier_products::UPDATED_AT, V::Ts(ts));
                self.chunk.emit(supplier_products::T, day, r);
            }
            let mut r = Row::new(stock_items::NCOLS);
            r.set(stock_items::TENANT_ID, tenant)
                .set(stock_items::VARIANT_ID, vrid)
                .set(stock_items::STOCK_LOCATION_ID, pick)
                .set(stock_items::QUANTITY, V::Int(opening))
                .set(stock_items::RESERVED_QUANTITY, V::Int(0))
                .set(stock_items::CREATED_AT, V::Ts(ts))
                .set(stock_items::UPDATED_AT, V::Ts(ts));
            let item = self.chunk.emit_deferred(stock_items::T, day, r);
            let mut slot = Slot { item, location: pick, on_hand: opening, available: opening, reserved: 0, demand, inbound: 0, supplier, lot: None, has_alt, serials: VecDeque::new(), last_counted: None };
            if let Some(life) = lot_tracked(&self.m.vertical, &kind) {
                slot.lot = Some(self.new_lot(rng, day, ts, vrid, si_supplier(&self.inv, supplier), life));
            }
            let mut r = Row::new(stock_movements::NCOLS);
            r.set(stock_movements::TENANT_ID, tenant)
                .set(stock_movements::VARIANT_ID, vrid)
                .set(stock_movements::STOCK_LOCATION_ID, pick)
                .set(stock_movements::LOT_ID, V::opt_ref(slot.lot))
                .set(stock_movements::KIND, if migrated { "adjustment" } else { "receipt" })
                .set(stock_movements::QUANTITY, V::Int(opening))
                .set(stock_movements::REFERENCE_TYPE, if migrated { "migration" } else { "opening_stock" })
                .set(stock_movements::NOTE, if migrated { V::Static("Opening balance (platform migration)") } else { V::Null })
                .set(stock_movements::OCCURRED_AT, V::Ts(ts.max(time::ts_of_day(day))))
                .set(stock_movements::CREATED_AT, V::Ts(ts.max(time::ts_of_day(day))));
            self.chunk.emit(stock_movements::T, day, r);
            if self.m.vertical == "consumer_electronics" && price_eur > 150.0 {
                for _ in 0..opening {
                    let h = self.new_serial(day, ts, vrid, slot.lot, pick);
                    slot.serials.push_back(h);
                }
            }
            slots.push(slot);
        }
        while self.inv.slots.len() <= pidx {
            self.inv.slots.push(Vec::new());
        }
        self.inv.slots[pidx] = slots;
    }

    fn new_lot(&mut self, rng: &mut Rng, day: Day, ts: Ts, variant: Rid, supplier: Option<Rid>, life: i64) -> Rid {
        let d = time::date_of(day);
        let made = d - chrono::Duration::days(rng.int(5, 40));
        let mut r = Row::new(lots::NCOLS);
        r.set(lots::TENANT_ID, self.tenant_rid())
            .set(lots::VARIANT_ID, variant)
            .set(lots::SUPPLIER_ID, V::opt_ref(supplier))
            .set(lots::LOT_CODE, format!("L{}-{}", made.format("%y%W"), rng.alnum(5).to_uppercase()))
            .set(lots::MANUFACTURED_AT, V::Date(time::epoch_days(made)))
            .set(lots::EXPIRES_AT, if life > 0 { V::Date(time::epoch_days(made + chrono::Duration::days(life))) } else { V::Null })
            .set(lots::CREATED_AT, V::Ts(ts.max(time::ts_of_day(day))))
            .set(lots::UPDATED_AT, V::Ts(ts.max(time::ts_of_day(day))));
        self.chunk.emit(lots::T, day, r)
    }

    fn new_serial(&mut self, day: Day, ts: Ts, variant: Rid, lot: Option<Rid>, loc: Rid) -> DHandle {
        self.inv.serial_seq += 1;
        let mut r = Row::new(serial_numbers::NCOLS);
        r.set(serial_numbers::TENANT_ID, self.tenant_rid())
            .set(serial_numbers::VARIANT_ID, variant)
            .set(serial_numbers::LOT_ID, V::opt_ref(lot))
            .set(serial_numbers::STOCK_LOCATION_ID, loc)
            .set(serial_numbers::SERIAL, format!("{}{:010}", self.sku_prefix, self.inv.serial_seq * 7919 % 10_000_000_000))
            .set(serial_numbers::STATUS, "in_stock")
            .set(serial_numbers::RECEIVED_AT, V::Ts(ts.max(time::ts_of_day(day))))
            .set(serial_numbers::CREATED_AT, V::Ts(ts.max(time::ts_of_day(day))))
            .set(serial_numbers::UPDATED_AT, V::Ts(ts.max(time::ts_of_day(day))));
        self.chunk.emit_deferred(serial_numbers::T, day, r)
    }

    fn apply_ops(&mut self, ts: Ts, ops: &[&(usize, usize, StockOp, i64)]) -> BTreeMap<(usize, usize), i64> {
        let mut sold_today: BTreeMap<(usize, usize), i64> = BTreeMap::new();
        for &&(pi, vi, op, q) in ops {
            let Some(slot) = self.inv.slots.get_mut(pi).and_then(|v| v.get_mut(vi)) else { continue };
            match op {
                StockOp::Sold => {
                    slot.available -= q;
                    slot.reserved += q;
                    *sold_today.entry((pi, vi)).or_default() += q;
                }
                StockOp::Shipped => {
                    slot.on_hand -= q;
                    slot.reserved -= q;
                    for _ in 0..q {
                        if let Some(h) = slot.serials.pop_front() {
                            self.chunk.deferred_mut(h).set(serial_numbers::STATUS, "sold").set(serial_numbers::UPDATED_AT, V::Ts(ts));
                        }
                    }
                }
                StockOp::Released => {
                    slot.available += q;
                    slot.reserved -= q;
                }
                StockOp::Restocked => {
                    slot.on_hand += q;
                    slot.available += q;
                }
            }
        }
        sold_today
    }

    /// Daily inventory: apply yesterday's stock operations, receive arrivals, reorder, count.
    pub(super) fn inventory_day(&mut self, rng: &mut Rng, day: Day, ops: &[&(usize, usize, StockOp, i64)]) {
        let tenant = self.tenant_rid();
        let ts = time::ts_of_day(day);
        let sold_today = self.apply_ops(ts, ops);
        // demand estimate per variant (exponential smoothing over ~4 weeks)
        for (pi, slots) in self.inv.slots.iter_mut().enumerate() {
            for (vi, s) in slots.iter_mut().enumerate() {
                let q = sold_today.get(&(pi, vi)).copied().unwrap_or(0) as f64;
                s.demand = 0.965 * s.demand + 0.035 * q;
            }
        }
        // arrivals
        if let Some(arr) = self.inv.arrivals.remove(&day) {
            let mut by_po: BTreeMap<usize, Vec<Arrival>> = BTreeMap::new();
            for (k, a) in arr {
                by_po.entry(k).or_default().push(a);
            }
            for (k, lines) in by_po {
                let po = lines[0].po;
                let (si, actual_days, arrives) = self.inv.po_meta.remove(&k).expect("arrival of an unknown purchase order");
                let received_at = arrives;
                // merchants with tight operations update their planning lead time
                if self.inv.learn > 0.0 {
                    let s = &mut self.inv.suppliers[si];
                    s.planned_lead = (1.0 - self.inv.learn) * s.planned_lead + self.inv.learn * actual_days;
                }
                let _ = ts;
                self.inv.receipt_seq += 1;
                let receiver = self.staff.iter().find(|s| s.role == "warehouse").map(|s| s.user.rid);
                let (pick, _, _) = self.inv.locations[0];
                let mut r = Row::new(inbound_receipts::NCOLS);
                r.set(inbound_receipts::TENANT_ID, tenant)
                    .set(inbound_receipts::PURCHASE_ORDER_ID, po)
                    .set(inbound_receipts::WAREHOUSE_ID, self.warehouses[0].rid)
                    .set(inbound_receipts::RECEIPT_NUMBER, format!("GR-{:06}", self.inv.receipt_seq))
                    .set(inbound_receipts::CARRIER, if rng.chance(0.6) { V::Static("Landfall Freight") } else { V::Null })
                    .set(inbound_receipts::TRACKING_NUMBER, if rng.chance(0.5) { V::Str(format!("LF{}", rng.digits(10))) } else { V::Null })
                    .set(inbound_receipts::RECEIVED_BY_USER_ID, V::opt_ref(receiver))
                    .set(inbound_receipts::RECEIVED_AT, V::Ts(received_at))
                    .set(inbound_receipts::CREATED_AT, V::Ts(received_at))
                    .set(inbound_receipts::UPDATED_AT, V::Ts(received_at));
                let receipt = self.chunk.emit(inbound_receipts::T, day, r);
                for a in lines {
                    let vrid = self.products[a.pidx].variants[a.vidx].rid;
                    let kind = self.product_types[self.products[a.pidx].ty].kind.clone();
                    let supplier_rid = self.inv.suppliers[self.inv.slots[a.pidx][a.vidx].supplier].rid;
                    let lot = match lot_tracked(&self.m.vertical, &kind) {
                        Some(life) => Some(self.new_lot(rng, day, received_at, vrid, Some(supplier_rid), life)),
                        None => None,
                    };
                    if crate::sim::stories::s5_defect_window(self.m, day) && self.inv.defect_product == Some(a.pidx) {
                        self.inv.defective.extend(lot);
                    }
                    let good = a.qty - a.rejected;
                    let mut r = Row::new(receipt_lines::NCOLS);
                    r.set(receipt_lines::TENANT_ID, tenant)
                        .set(receipt_lines::INBOUND_RECEIPT_ID, receipt)
                        .set(receipt_lines::PURCHASE_ORDER_LINE_ID, a.line)
                        .set(receipt_lines::VARIANT_ID, vrid)
                        .set(receipt_lines::STOCK_LOCATION_ID, pick)
                        .set(receipt_lines::LOT_ID, V::opt_ref(lot))
                        .set(receipt_lines::QUANTITY_RECEIVED, V::Int(a.qty))
                        .set(receipt_lines::QUANTITY_REJECTED, V::Int(a.rejected))
                        .set(receipt_lines::CREATED_AT, V::Ts(received_at))
                        .set(receipt_lines::UPDATED_AT, V::Ts(received_at));
                    self.chunk.emit(receipt_lines::T, day, r);
                    let mut r = Row::new(stock_movements::NCOLS);
                    r.set(stock_movements::TENANT_ID, tenant)
                        .set(stock_movements::VARIANT_ID, vrid)
                        .set(stock_movements::STOCK_LOCATION_ID, pick)
                        .set(stock_movements::LOT_ID, V::opt_ref(lot))
                        .set(stock_movements::KIND, "receipt")
                        .set(stock_movements::QUANTITY, V::Int(good))
                        .set(stock_movements::REFERENCE_TYPE, "purchase_order")
                        .set(stock_movements::REFERENCE_ID, po)
                        .set(stock_movements::CREATED_BY_USER_ID, V::opt_ref(receiver))
                        .set(stock_movements::OCCURRED_AT, V::Ts(received_at))
                        .set(stock_movements::CREATED_AT, V::Ts(received_at));
                    self.chunk.emit(stock_movements::T, day, r);
                    let serialized = self.m.vertical == "consumer_electronics" && self.products[a.pidx].price_eur > 150.0;
                    let mut serials = Vec::new();
                    if serialized {
                        for _ in 0..good {
                            serials.push(self.new_serial(day, received_at, vrid, lot, pick));
                        }
                    }
                    let slot = &mut self.inv.slots[a.pidx][a.vidx];
                    slot.on_hand += good;
                    slot.available += good;
                    slot.inbound -= a.qty;
                    if lot.is_some() {
                        slot.lot = lot;
                    }
                    slot.serials.extend(serials);
                }
            }
        }
        self.inventory_stories(rng, day);
        // weekly reorder run per supplier
        if (day as usize + self.idx) % 7 == 0 {
            self.reorder(rng, day);
        }
        // cycle counts: a few locations a day; shrinkage and found stock
        let n_slots: usize = self.inv.slots.iter().map(|v| v.len()).sum();
        if n_slots > 0 {
            for _ in 0..rng.poisson((n_slots as f64 / 180.0).max(0.2)) {
                let pi = rng.below(self.inv.slots.len());
                if self.inv.slots[pi].is_empty() {
                    continue;
                }
                let vi = rng.below(self.inv.slots[pi].len());
                let counted = ts + rng.int(7, 16) * MICROS_PER_HOUR;
                let delta = if rng.chance(0.95) { 0 } else if rng.chance(0.7) { -1 } else { 1 };
                let (vrid, loc) = (self.products[pi].variants[vi].rid, self.inv.slots[pi][vi].location);
                let slot = &mut self.inv.slots[pi][vi];
                slot.last_counted = Some(counted);
                if delta == 0 || slot.on_hand + delta < 0 {
                    continue;
                }
                slot.on_hand += delta;
                slot.available += delta;
                let lot = slot.lot;
                let who = self.staff.iter().find(|s| s.role == "warehouse").map(|s| s.user.rid);
                let reason = if delta < 0 { *rng.pick(&["Damaged in warehouse", "Cycle count variance", "Missing - suspected theft", "Expired"]) } else { "Cycle count variance" };
                let mut r = Row::new(stock_adjustments::NCOLS);
                r.set(stock_adjustments::TENANT_ID, tenant)
                    .set(stock_adjustments::VARIANT_ID, vrid)
                    .set(stock_adjustments::STOCK_LOCATION_ID, loc)
                    .set(stock_adjustments::LOT_ID, V::opt_ref(lot))
                    .set(stock_adjustments::QUANTITY_DELTA, V::Int(delta))
                    .set(stock_adjustments::REASON, reason)
                    .set(stock_adjustments::ADJUSTED_BY_USER_ID, V::opt_ref(who))
                    .set(stock_adjustments::CREATED_AT, V::Ts(counted))
                    .set(stock_adjustments::UPDATED_AT, V::Ts(counted));
                self.chunk.emit(stock_adjustments::T, day, r);
                let mut r = Row::new(stock_movements::NCOLS);
                r.set(stock_movements::TENANT_ID, tenant)
                    .set(stock_movements::VARIANT_ID, vrid)
                    .set(stock_movements::STOCK_LOCATION_ID, loc)
                    .set(stock_movements::LOT_ID, V::opt_ref(lot))
                    .set(stock_movements::KIND, "cycle_count")
                    .set(stock_movements::QUANTITY, V::Int(delta))
                    .set(stock_movements::REFERENCE_TYPE, "stock_adjustment")
                    .set(stock_movements::NOTE, reason)
                    .set(stock_movements::CREATED_BY_USER_ID, V::opt_ref(who))
                    .set(stock_movements::OCCURRED_AT, V::Ts(counted))
                    .set(stock_movements::CREATED_AT, V::Ts(counted));
                self.chunk.emit(stock_movements::T, day, r);
            }
        }
    }

    fn reorder(&mut self, rng: &mut Rng, day: Day) {
        let tenant = self.tenant_rid();
        let end = time::end_ts();
        let mut by_supplier: BTreeMap<usize, Vec<(usize, usize, i64)>> = BTreeMap::new();
        for (pi, slots) in self.inv.slots.iter().enumerate() {
            let p = &self.products[pi];
            if p.archive_day.is_some_and(|a| a <= day + 21) {
                continue; // being phased out: no restock
            }
            for (vi, s) in slots.iter().enumerate() {
                // the reorder point uses the merchant's planning lead time
                let lead = self.inv.suppliers[s.supplier].planned_lead;
                let point = (s.demand * (lead + 7.0) * 1.3).ceil() as i64;
                if s.available + s.inbound < point.max(1) {
                    let qty = ((s.demand * 28.0).ceil() as i64).max(point - s.available - s.inbound).max(2);
                    by_supplier.entry(s.supplier).or_default().push((pi, vi, qty));
                }
            }
        }
        for (si, lines) in by_supplier {
            let (srid, quoted, currency, level, region, bias, spread, planned, typical) = {
                let s = &self.inv.suppliers[si];
                (s.rid, s.lead_days, s.currency, s.level, s.region, s.bias, s.spread, s.planned_lead, s.typical_qty)
            };
            let lead = if self.inv.slow == Some(si) { crate::sim::stories::s4_lead_days(self.m, day).unwrap_or(quoted) } else { quoted };
            self.inv.po_seq += 1;
            let ordered = time::ts_of_day(day) + rng.int(9, 16) * MICROS_PER_HOUR;
            // the merchant expects the goods after its planning lead time
            let expected = ordered + (planned * MICROS_PER_DAY as f64) as i64;
            // the real delivery: supplier bias and noise, big orders take longer, and seasonal
            // congestion (peak season, Chinese New Year, European summer holidays)
            let units: i64 = lines.iter().map(|l| l.2).sum();
            let size = if typical > 0.0 { libm::pow(units as f64 / typical, 0.08) } else { 1.0 };
            self.inv.suppliers[si].typical_qty = if typical > 0.0 { 0.9 * typical + 0.1 * units as f64 } else { units as f64 };
            let date = time::date_of(day);
            let window = (date, date + chrono::Duration::days(quoted.ceil() as i64));
            let mut extra = 0.0;
            use chrono::Datelike;
            let peak = matches!(date.month(), 10 | 11) || (date.month() == 12 && date.day() <= 10);
            let season = if peak { [1.04, 1.08, 1.12][region] } else { 1.0 };
            if region == 2 && overlaps(window, chinese_new_year(date.year()), -7, 14) || region == 2 && overlaps(window, chinese_new_year(date.year() + 1), -7, 14) {
                extra += rng.uniform(8.0, 16.0); // factories close around the holiday
            }
            if region == 1 && overlaps(window, chrono::NaiveDate::from_ymd_opt(date.year(), 8, 1).unwrap(), 0, 24) {
                extra += rng.uniform(3.0, 8.0); // August shutdowns
            }
            let actual_days = (lead * bias * size * season * rng.lognormal(0.0, spread) + extra).max(1.0);
            let raw = ordered + (actual_days * MICROS_PER_DAY as f64) as i64;
            // goods are received during the warehouse's working hours
            let arrive_day = (time::day_of_ts(raw).max(day as i64 + 1)) as f64;
            let arrives = time::ts_of_day(arrive_day.min(u32::MAX as f64) as Day) + rng.int(8, 15) * MICROS_PER_HOUR + rng.int(0, 59) * 60_000_000;
            let received = arrives <= end;
            if received {
                self.inv.po_meta.insert(self.inv.po_seq as usize, (si, actual_days, arrives));
            }
            let cost = |pi: usize| (self.products[pi].price_eur * cost_ratio(&self.m.vertical) * level * 100.0).round() as i64;
            let total: i64 = lines.iter().map(|(pi, _, q)| cost(*pi) * q).sum();
            let buyer = self.staff.iter().find(|s| s.role == "merchandiser" || s.role == "admin").map(|s| s.user.rid);
            let mut r = Row::new(purchase_orders::NCOLS);
            r.set(purchase_orders::PUBLIC_ID, V::Uuid(rng.uuid()))
                .set(purchase_orders::TENANT_ID, tenant)
                .set(purchase_orders::SUPPLIER_ID, srid)
                .set(purchase_orders::WAREHOUSE_ID, self.warehouses[0].rid)
                .set(purchase_orders::PO_NUMBER, format!("PO-{:06}", self.inv.po_seq))
                .set(purchase_orders::STATUS, if received { "received" } else { "submitted" })
                .set(purchase_orders::CURRENCY_CODE, currency)
                .set(purchase_orders::EXPECTED_TOTAL, V::Money(total))
                .set(purchase_orders::NOTES, if rng.chance(0.1) { V::Static("Please confirm delivery date.") } else { V::Null })
                .set(purchase_orders::ORDERED_AT, V::Ts(ordered))
                .set(purchase_orders::EXPECTED_AT, V::Ts(expected))
                .set(purchase_orders::RECEIVED_AT, if received { V::Ts(arrives) } else { V::Null })
                .set(purchase_orders::CREATED_BY_USER_ID, V::opt_ref(buyer))
                .set(purchase_orders::CREATED_AT, V::Ts(ordered))
                .set(purchase_orders::UPDATED_AT, V::Ts(if received { arrives } else { ordered }));
            let po = self.chunk.emit(purchase_orders::T, day, r);
            for (pi, vi, qty) in lines {
                let rejected = if rng.chance(0.03) { (qty as f64 * rng.uniform(0.05, 0.3)).ceil() as i64 } else { 0 };
                let mut r = Row::new(purchase_order_lines::NCOLS);
                r.set(purchase_order_lines::TENANT_ID, tenant)
                    .set(purchase_order_lines::PURCHASE_ORDER_ID, po)
                    .set(purchase_order_lines::VARIANT_ID, self.products[pi].variants[vi].rid)
                    .set(purchase_order_lines::QUANTITY_ORDERED, V::Int(qty))
                    .set(purchase_order_lines::QUANTITY_RECEIVED, V::Int(if received { qty - rejected } else { 0 }))
                    .set(purchase_order_lines::UNIT_COST, V::Money(cost(pi)))
                    .set(purchase_order_lines::CURRENCY_CODE, currency)
                    .set(purchase_order_lines::CREATED_AT, V::Ts(ordered))
                    .set(purchase_order_lines::UPDATED_AT, V::Ts(ordered));
                let line = self.chunk.emit(purchase_order_lines::T, day, r);
                self.inv.slots[pi][vi].inbound += qty;
                if received {
                    self.inv.arrivals.entry(arrive_day as Day).or_default().push((self.inv.po_seq as usize, Arrival { po, line, pidx: pi, vidx: vi, qty, rejected }));
                }
            }
        }
    }

    /// S4 (slow supplier, later moving the best sellers away) and S5 (recall of a lot).
    fn inventory_stories(&mut self, rng: &mut Rng, day: Day) {
        use crate::sim::stories;
        let tenant = self.tenant_rid();
        if stories::has(self.m, "S4") && stories::s4_start(day) {
            // the European supplier behind most of the volume (~2 weeks lead time)
            let mut vol = vec![0.0; self.inv.suppliers.len()];
            for slots in &self.inv.slots {
                for s in slots {
                    vol[s.supplier] += s.demand;
                }
            }
            let eu: Vec<usize> = (0..vol.len()).filter(|i| i % 3 == 1).collect();
            self.inv.slow = eu.into_iter().max_by(|a, b| vol[*a].partial_cmp(&vol[*b]).unwrap()).or(Some(0));
        }
        if stories::s4_switch(self.m, day) {
            let Some(slow) = self.inv.slow else { return };
            let alt = (slow + 1) % self.inv.suppliers.len();
            let mut demands: Vec<f64> = self.inv.slots.iter().flatten().filter(|s| s.supplier == slow).map(|s| s.demand).collect();
            demands.sort_by(|a, b| b.partial_cmp(a).unwrap());
            let cut = demands.get(demands.len() / 3).copied().unwrap_or(f64::MAX);
            let at = time::ts_of_day(day) + 10 * MICROS_PER_HOUR;
            let (alt_rid, alt_lead, alt_cur, alt_level) = { let s = &self.inv.suppliers[alt]; (s.rid, s.lead_days, s.currency, s.level) };
            for pi in 0..self.inv.slots.len() {
                for vi in 0..self.inv.slots[pi].len() {
                    let s = &self.inv.slots[pi][vi];
                    if s.supplier != slow || s.demand < cut || s.demand <= 0.0 {
                        continue;
                    }
                    self.inv.slots[pi][vi].supplier = alt;
                    if std::mem::replace(&mut self.inv.slots[pi][vi].has_alt, true) {
                        continue;
                    }
                    let (vrid, sku, price) = { let v = &self.products[pi].variants[vi]; (v.rid, v.sku.clone(), self.products[pi].price_eur) };
                    let mut r = Row::new(supplier_products::NCOLS);
                    r.set(supplier_products::TENANT_ID, tenant)
                        .set(supplier_products::SUPPLIER_ID, alt_rid)
                        .set(supplier_products::VARIANT_ID, vrid)
                        .set(supplier_products::SUPPLIER_SKU, format!("{}-{}", &sku[..sku.len().min(10)], rng.digits(4)))
                        .set(supplier_products::UNIT_COST, V::Money(((price * cost_ratio(&self.m.vertical) * 1.08 * alt_level * 100.0).round() as i64).max(1)))
                        .set(supplier_products::CURRENCY_CODE, alt_cur)
                        .set(supplier_products::MIN_ORDER_QTY, V::Int(12))
                        .set(supplier_products::LEAD_TIME_DAYS, V::Int(alt_lead.round() as i64))
                        .set(supplier_products::IS_PREFERRED, false)
                        .set(supplier_products::CREATED_AT, V::Ts(at))
                        .set(supplier_products::UPDATED_AT, V::Ts(at));
                    self.chunk.emit(supplier_products::T, day, r);
                }
            }
        }
        if stories::s5_start(self.m, day) {
            // the lot in stock of the most popular stand mixer (and lots received until May)
            self.inv.defect_product = (0..self.products.len()).filter(|&i| self.product_types[self.products[i].ty].kind.contains("Stand Mixer") && self.products[i].archive_day.is_none_or(|a| a > day) && !self.products[i].voucher).max_by(|a, b| self.products[*a].appeal.partial_cmp(&self.products[*b].appeal).unwrap());
            if let Some(pi) = self.inv.defect_product {
                // featured in a spring campaign, it becomes the bestseller
                self.products[pi].appeal += 3.0;
                let lots: Vec<Rid> = self.inv.slots.get(pi).map(|v| v.iter().filter_map(|s| s.lot).collect()).unwrap_or_default();
                self.inv.defective.extend(lots);
            }
        }
        if stories::s5_recall(self.m, day) {
            let bad = self.inv.defective.clone();
            let at = time::ts_of_day(day) + 9 * MICROS_PER_HOUR;
            let who = self.staff.iter().find(|s| s.role == "warehouse" || s.role == "admin").map(|s| s.user.rid);
            for pi in 0..self.inv.slots.len() {
                for vi in 0..self.inv.slots[pi].len() {
                    let s = &self.inv.slots[pi][vi];
                    let Some(lot) = s.lot.filter(|l| bad.contains(l)) else { continue };
                    if s.on_hand <= 0 {
                        continue;
                    }
                    let (q, loc, vrid) = (s.on_hand, s.location, self.products[pi].variants[vi].rid);
                    let slot = &mut self.inv.slots[pi][vi];
                    slot.on_hand -= q;
                    slot.available -= q;
                    let mut r = Row::new(stock_adjustments::NCOLS);
                    r.set(stock_adjustments::TENANT_ID, tenant).set(stock_adjustments::VARIANT_ID, vrid).set(stock_adjustments::STOCK_LOCATION_ID, loc).set(stock_adjustments::LOT_ID, lot).set(stock_adjustments::QUANTITY_DELTA, V::Int(-q)).set(stock_adjustments::REASON, "Recall: defective lot returned to supplier").set(stock_adjustments::ADJUSTED_BY_USER_ID, V::opt_ref(who)).set(stock_adjustments::CREATED_AT, V::Ts(at)).set(stock_adjustments::UPDATED_AT, V::Ts(at));
                    self.chunk.emit(stock_adjustments::T, day, r);
                    let mut r = Row::new(stock_movements::NCOLS);
                    r.set(stock_movements::TENANT_ID, tenant).set(stock_movements::VARIANT_ID, vrid).set(stock_movements::STOCK_LOCATION_ID, loc).set(stock_movements::LOT_ID, lot).set(stock_movements::KIND, "adjustment").set(stock_movements::QUANTITY, V::Int(-q)).set(stock_movements::REFERENCE_TYPE, "stock_adjustment").set(stock_movements::NOTE, "Recall").set(stock_movements::CREATED_BY_USER_ID, V::opt_ref(who)).set(stock_movements::OCCURRED_AT, V::Ts(at)).set(stock_movements::CREATED_AT, V::Ts(at));
                    self.chunk.emit(stock_movements::T, day, r);
                }
            }
        }
    }

    /// Final stock levels into the (deferred) stock_items rows. `last_ops` are the stock
    /// operations of the last day (normally applied the next morning).
    pub fn finish_inventory(&mut self, last_ops: &[&(usize, usize, StockOp, i64)]) {
        let end = time::end_ts();
        if self.tenant.is_none() {
            return;
        }
        self.apply_ops(end, last_ops);
        // oversold (sales outran the one-day stock sync): booked as a correction, as real systems do
        let day = time::num_days() - 1;
        let tenant = self.tenant_rid();
        let mut fixes = Vec::new();
        for (pi, slots) in self.inv.slots.iter().enumerate() {
            for (vi, s) in slots.iter().enumerate() {
                if s.on_hand < 0 {
                    fixes.push((pi, vi, -s.on_hand, s.location, s.lot));
                }
            }
        }
        for (pi, vi, q, loc, lot) in fixes {
            let mut r = Row::new(stock_movements::NCOLS);
            r.set(stock_movements::TENANT_ID, tenant)
                .set(stock_movements::VARIANT_ID, self.products[pi].variants[vi].rid)
                .set(stock_movements::STOCK_LOCATION_ID, loc)
                .set(stock_movements::LOT_ID, V::opt_ref(lot))
                .set(stock_movements::KIND, "adjustment")
                .set(stock_movements::QUANTITY, V::Int(q))
                .set(stock_movements::REFERENCE_TYPE, "correction")
                .set(stock_movements::NOTE, V::Static("Negative on-hand corrected (oversold before stock sync)"))
                .set(stock_movements::OCCURRED_AT, V::Ts(end - MICROS_PER_HOUR))
                .set(stock_movements::CREATED_AT, V::Ts(end - MICROS_PER_HOUR));
            self.chunk.emit(stock_movements::T, day, r);
            self.inv.slots[pi][vi].on_hand = 0;
        }
        let mut updates = Vec::new();
        for slots in &self.inv.slots {
            for s in slots {
                let qty = s.on_hand.max(0);
                let reserved = s.reserved.clamp(0, qty);
                let point = (s.demand * 21.0).ceil() as i64;
                updates.push((s.item, qty, reserved, point, ((s.demand * 28.0).ceil() as i64).max(1), s.last_counted));
            }
        }
        for (h, q, r, point, rq, counted) in updates {
            self.chunk
                .deferred_mut(h)
                .set(stock_items::QUANTITY, V::Int(q))
                .set(stock_items::RESERVED_QUANTITY, V::Int(r))
                .set(stock_items::REORDER_POINT, V::Int(point))
                .set(stock_items::REORDER_QUANTITY, V::Int(rq))
                .set(stock_items::LAST_COUNTED_AT, V::opt_ts(counted))
                .set(stock_items::UPDATED_AT, V::Ts(end - MICROS_PER_HOUR));
        }
    }

    /// Can this variant be bought right now?
    pub fn in_stock(&self, pidx: usize, vidx: usize) -> bool {
        self.inv.slots.get(pidx).and_then(|v| v.get(vidx)).is_none_or(|s| s.available > 0)
    }

    pub fn stock_slot(&self, pidx: usize, vidx: usize) -> Option<&Slot> {
        self.inv.slots.get(pidx).and_then(|v| v.get(vidx))
    }
}

fn si_supplier(inv: &Inventory, si: usize) -> Option<Rid> {
    inv.suppliers.get(si).map(|s| s.rid)
}
