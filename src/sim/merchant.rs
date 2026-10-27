//! Merchant-level processes: onboarding, staff, warehouses, catalog lifecycle, and the daily
//! stream of new shopper identities (routed to the merchant's shopper chunks).

use std::collections::{BTreeMap, BTreeSet};

use crate::engine::{Chunk, DHandle};
use crate::rng::{Rng, Weighted, hash_str};
use crate::sim::calendar;
use crate::sim::people::{self, Person};
use crate::sim::reference::Refs;
use crate::sim::{Config, Params};
use crate::tables::*;
use crate::time::{self, Day, MICROS_PER_DAY, MICROS_PER_HOUR, Ts, Tz};
use crate::value::{Rid, Row, V};
use crate::world::{Merchant, ProductType, Vertical, world};

mod admin;
mod analytics;
mod catalog;
mod crm;
mod inventory;
mod marketing;
mod pricing;
mod subscriptions;
pub use marketing::{BASE_MIX, LANDING, SegmentKind};
pub use subscriptions::PlanDef;
pub use admin::{Audit, audit, change};
pub use crm::tax_id;
pub use analytics::MonthKpi;
pub use pricing::Offer;
pub use inventory::StockOp;

pub struct Variant {
    pub rid: Rid,
    pub sku: String,
    pub name: String,
    pub price_cents: i64,
    pub weight_g: i64,
}

pub struct Product {
    pub rid: Rid,
    pub public_id: u128,
    pub name: String,
    pub slug: String,
    /// index into `MerchantSim::product_types`
    pub ty: usize,
    pub launch_day: Day,
    pub archive_day: Option<Day>,
    /// latent traits (see docs/SIMULATOR.md): appeal drives visibility; quality, relative
    /// price and season drive the decision on the product page
    pub appeal: f64,
    pub quality: f64,
    /// reference price in EUR and log(price / typical price of the product type)
    pub price_eur: f64,
    pub price_rel: f64,
    /// sizing runs small (<0) or large (>0), in sizes; and how uncertain the size info is
    pub fit_bias: f64,
    pub fit_uncert: f64,
    pub fragility: f64,
    /// 0 = year-round, 1 = winter, 2 = summer
    pub season: i8,
    /// cross-sell / upsell recommendations (indices into `products`)
    pub related: Vec<usize>,
    /// price changes: (day, factor vs launch price), sorted
    pub price_steps: Vec<(Day, f64)>,
    pub variants: Vec<Variant>,
    /// number of sizes if the first variant axis is a size run (variants are size-major)
    pub sizes: usize,
    /// a gift card (stored value; not listed, no stock, no VAT at sale)
    pub voucher: bool,
    /// S19: onboarded sloppily (no images or size data, sometimes the wrong category)
    pub sloppy: bool,
}

/// Live products of one product type with their sampling weights.
pub struct TypeIndex {
    pub products: Vec<usize>,
    pub weights: Option<Weighted>,
}

pub struct Warehouse {
    pub rid: Rid,
    #[allow(dead_code)] // part of the data model, not used by the simulator yet
    pub country: usize,
    pub city: String,
}

pub struct Staff {
    pub user: DHandle,
    pub role: &'static str,
}

pub struct Templates {
    pub order_confirmation: Rid,
    pub shipping: Rid,
    pub delivered: Rid,
    pub refund: Rid,
    pub welcome: Rid,
    pub password_reset: Rid,
    pub shipping_sms: Option<Rid>,
}

pub struct Webhook {
    pub rid: Rid,
    pub events: Vec<&'static str>,
    /// probability that a delivery attempt fails (flaky endpoints exist)
    pub failure_rate: f64,
}

/// Ledger accounts of a merchant (chart of accounts).
pub struct Ledger {
    pub bank: Rid,
    pub clearing: Rid,
    pub revenue: Rid,
    pub shipping_income: Rid,
    pub vat: Rid,
    pub refunds: Rid,
    pub fees: Rid,
    /// outstanding gift cards and store credit
    pub gift_cards: Rid,
}

/// Processing fee of a gateway in cents for a payment of `amount` cents.
pub fn gateway_fee(gateway: &str, amount: i64) -> i64 {
    let (pct, fixed) = match gateway {
        "Halyard Pay" => (0.014, 25),
        "Pennaro" => (0.015, 25),
        "Bluestem Pay" => (0.029, 30),
        "Pursely" => (0.034, 35),
        "Moravell" => (0.049, 0),
        _ => (0.02, 25),
    };
    (amount as f64 * pct).round() as i64 + fixed
}

pub struct Agent {
    pub rid: Rid,
    pub user: Rid,
    pub group: Rid,
    /// left the company (S9)
    pub left: Option<Ts>,
}

impl MerchantSim {
    /// Support agents still working at `at`.
    pub fn agents_at(&self, at: Ts) -> Vec<&Agent> {
        let v: Vec<&Agent> = self.agents.iter().filter(|a| a.left.is_none_or(|l| at < l)).collect();
        if v.is_empty() { self.agents.iter().collect() } else { v }
    }
}

/// Per-priority SLA policy: (policy, first response target, resolution target) in minutes.
pub struct Sla {
    pub rid: Rid,
    pub first_response_min: i64,
    pub resolution_min: i64,
}

/// What a shopper chunk hands to its merchant (and the platform) about one day.
#[derive(Default)]
pub struct DayOut {
    pub captured: Vec<Captured>,
    /// paid orders (warehouse load) and their revenue (minor units)
    pub orders: u32,
    pub revenue: i64,
    /// last-click revenue of orders from paid search and paid social visits (minor units)
    pub paid_revenue: [i64; 2],
    /// new support tickets (support load)
    pub tickets: u32,
    /// parcels handed to each carrier (by carrier index)
    pub shipments: BTreeMap<usize, u32>,
    /// stock operations: (product, variant, operation, quantity)
    pub stock: Vec<(usize, usize, StockOp, i64)>,
    /// coupons redeemed
    pub coupons: Vec<Rid>,
    /// marketing email clicks (by campaign) and landing page views (index into LANDING)
    pub clicks: Vec<Rid>,
    pub landing_views: Vec<usize>,
    /// segment sizes (only reported on the last day, by SegmentKind)
    pub segments: [i64; 5],
    /// stored (sampled) sessions and events, and new sign-ups
    pub sessions: u32,
    pub events: u32,
    pub signups: u32,
    /// on the 1st of a month: the previous month's KPI inputs; cohort members added
    pub kpi: Option<MonthKpi>,
}

/// A captured payment handed from a shopper chunk to its merchant for the payout.
#[derive(Clone)]
pub struct Captured {
    pub payment: Rid,
    pub gateway: String,
    pub amount: i64,
    pub fee: i64,
}

/// Identity of a shopper who first shows up today; created by the shopper chunk it is routed to.
/// They may browse anonymously for a while (`first_seen`) before signing up (`created`).
#[derive(Clone)]
pub struct NewShopper {
    pub person: Person,
    pub country: usize,
    pub domain: String,
    pub first_seen: Ts,
    pub created: Ts,
    /// false: only signs up (newsletter, wishlist), does not buy on the first visit
    pub buys: bool,
    /// B2B: the buyer's company (buyers of one company are routed to one shopper chunk)
    pub company: Option<String>,
    /// S7: came through the influencer campaign; S8: a fraud-ring account
    pub influencer: bool,
    pub fraud: bool,
    /// brought over from the merchant's previous platform (2023 migration or when joining)
    pub migrated: bool,
    /// local part of the email address (shoppers are routed by it, so that every possible
    /// duplicate meets in one chunk and gets a number appended there)
    pub email_base: String,
    pub seed: u64,
}

pub struct MerchantSim {
    pub idx: usize,
    pub m: &'static Merchant,
    pub vertical: &'static Vertical,
    pub chunk: Chunk,
    pub share: f64,
    pub growth: f64,
    pub b2b: bool,
    pub country: usize,
    pub tz: Tz,
    pub domain: String,
    pub sku_prefix: String,
    pub order_prefix: String,
    pub tenant: Option<DHandle>,
    pub staff: Vec<Staff>,
    pub warehouses: Vec<Warehouse>,
    pub agents: Vec<Agent>,
    /// indexed by priority: low, normal, high, urgent
    pub slas: Vec<Sla>,
    pub support_tags: Vec<(&'static str, Rid)>,
    /// help-centre articles by category (0 orders & delivery, 1 returns, 2 payments, 3 account, 4 products)
    pub articles: Vec<(usize, Rid)>,
    pub templates: Option<Templates>,
    pub ledger: Option<Ledger>,
    /// negative payout balances (refunds exceeding captures) carried per gateway
    payout_carry: BTreeMap<String, i64>,
    pub webhooks: Vec<Webhook>,
    pub sends_sms: bool,
    /// today's support backlog (days of work) and fulfilment backlog (days)
    pub support_delay: f64,
    pub pack_delay_days: f64,
    support_q: crate::sim::capacity::Queue,
    warehouse_q: crate::sim::capacity::Queue,
    pub products: Vec<Product>,
    /// live products (indices into `products`) and their sampling weights, refreshed weekly
    pub live: Vec<usize>,
    /// the size of the initial catalog while it is created, before `live` knows it: its products' opening stock is
    /// their share of the demand
    initial_catalog: usize,
    pub live_w: Option<Weighted>,
    /// live products per product type, and the product types each type is bought with
    pub by_type: Vec<TypeIndex>,
    pub complements: Vec<Vec<usize>>,
    pub product_types: Vec<&'static ProductType>,
    /// typical price (EUR) of the merchant's vertical, for budget comparisons
    pub vertical_mid_eur: f64,
    /// EUR -> merchant currency price level
    pub price_level: f64,
    pub shopper_chunks: usize,
    /// today's new shoppers, per local shopper chunk
    pub new_shoppers: Vec<Vec<NewShopper>>,
    /// expected anonymous (sampled) sessions today, platform-calibrated
    pub anon_sessions_today: f64,
    seed: u64,
    categories: BTreeMap<String, Rid>,
    /// category rows and closure rows (deferred: the tree can be restructured, S19)
    category_rows: BTreeMap<String, DHandle>,
    closure_rows: BTreeMap<(String, String), DHandle>,
    meta: catalog::CatalogMeta,
    pub inv: inventory::Inventory,
    pub pricing: pricing::Pricing,
    pub mkt: marketing::Marketing,
    pub subs: Option<subscriptions::Subs>,
    pub admin: admin::Admin,
    pub crm: crm::Crm,
    pub analytics: analytics::Analytics,
    /// how often customer data typed into this shop is messy (data hygiene, hidden trait)
    pub mess: f64,
    /// the gift card product (index into `products`)
    pub gift_card: Option<usize>,
    /// B2B: companies that already buy here (new buyers sometimes join a colleague's account)
    companies: Vec<(String, usize)>,
    brands: Vec<Rid>,
    slugs: BTreeSet<String>,
    product_seq: u32,
    launch_rate: f64,
    join_day: Day,
    churn_day: Option<Day>,
    domains: people::EmailDomains,
    cross_border: Weighted,
    cross_border_countries: Vec<usize>,
}

fn tld(iso2: &str) -> &'static str {
    match iso2 {
        "GB" => "co.uk",
        "DE" => "de",
        "NL" => "nl",
        "FR" => "fr",
        "SE" => "se",
        "DK" => "dk",
        "NO" => "no",
        "FI" => "fi",
        "IE" => "ie",
        "AT" => "at",
        "BE" => "be",
        _ => "com",
    }
}

fn initials(name: &str) -> String {
    let s: String = name
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty() && *w != "and" && *w != "Co")
        .map(|w| w.chars().next().unwrap().to_ascii_uppercase())
        .collect();
    if s.len() >= 2 { s.chars().take(3).collect() } else { name.chars().take(3).collect::<String>().to_uppercase() }
}

fn ean13(rng: &mut Rng, iso2: &str) -> String {
    let prefix = match iso2 {
        "GB" => "50",
        "DE" | "AT" => "40",
        "NL" => "87",
        "FR" => "30",
        "SE" => "73",
        "DK" => "57",
        "NO" => "70",
        "FI" => "64",
        "IE" => "53",
        "BE" => "54",
        _ => "08",
    };
    let mut d = format!("{prefix}{}", rng.digits(10));
    let sum: u32 = d.chars().enumerate().map(|(i, c)| c.to_digit(10).unwrap() * if i % 2 == 0 { 1 } else { 3 }).sum();
    d.push(char::from_digit((10 - sum % 10) % 10, 10).unwrap());
    d
}

/// Convert a EUR reference price to the merchant's currency with a local price ending.
fn local_price(rng: &mut Rng, eur: f64, currency: &str) -> i64 {
    let c = &world().catalog;
    let level = c.price_levels.get(currency).copied().unwrap_or(1.0);
    let x = eur * level;
    let ends = c.price_endings.get(currency).cloned().unwrap_or(vec![0.99]);
    let end = *rng.pick(&ends);
    let whole = if x >= 100.0 { (x / 5.0).round() * 5.0 } else { x.floor() };
    let p = if end == 0.0 { whole.max(1.0) } else { (whole - 1.0).max(0.0) + end };
    (p * 100.0).round() as i64
}

impl MerchantSim {
    pub fn new(idx: usize, m: &'static Merchant, chunk_id: u32, cfg: &Config, p: &Params) -> MerchantSim {
        let w = world();
        let seed = cfg.seed ^ hash_str(&m.slug);
        let mut rng = Rng::new(seed, &[1]);
        let vertical = w.vertical(&m.vertical);
        let b2b = m.has_model("b2b");
        let share = 1.0 / (m.size_rank as f64 * p.zipf_norm);
        let mut growth = rng.gauss(0.18, 0.15).clamp(-0.1, 0.8);
        if m.stories.iter().any(|s| s == "S19") {
            growth = 1.4; // fast-growing apparel merchant
        }
        let country = w.country_index(&m.country);
        let domain = if rng.chance(0.3) { format!("{}.com", m.slug.replace('-', "")) } else { format!("{}.{}", m.slug.replace("-and-", "and").replace('-', ""), tld(&m.country)) };
        let order_prefix = if b2b { "SO-".to_string() } else if rng.chance(0.6) { "#".to_string() } else { format!("{}-", initials(&m.name)) };
        let expected_shoppers = p.new_customers_end * cfg.sf * share * 1096.0 * 0.75;
        let shopper_chunks = ((expected_shoppers / p.shoppers_per_chunk).ceil() as usize).max(1);
        // which product types this merchant sells
        let mut product_types: Vec<&ProductType> = vertical.products.iter().collect();
        if m.size_rank > 10 {
            rng.shuffle(&mut product_types);
            let keep = ((product_types.len() as f64) * rng.uniform(0.5, 1.0)).ceil() as usize;
            product_types.truncate(keep.max(2));
        }
        // cross-border shoppers: neighbours and big markets
        let cb: &[(&str, f64)] = match m.country.as_str() {
            "US" => &[("CA", 5.0), ("GB", 1.0), ("AU", 1.0), ("MX", 0.5), ("DE", 0.5)],
            "GB" => &[("IE", 4.0), ("US", 2.0), ("FR", 1.0), ("DE", 1.0), ("NL", 1.0), ("AU", 0.5)],
            "IE" => &[("GB", 5.0), ("US", 1.0), ("DE", 0.5)],
            "DE" | "AT" => &[("AT", 4.0), ("CH", 3.0), ("NL", 1.5), ("BE", 1.0), ("FR", 1.0), ("PL", 1.0), ("LU", 0.5), ("DE", 3.0), ("CZ", 0.5)],
            "NL" | "BE" => &[("BE", 4.0), ("DE", 3.0), ("NL", 3.0), ("FR", 1.0), ("LU", 0.5), ("GB", 0.5)],
            "FR" => &[("BE", 3.0), ("CH", 2.0), ("LU", 1.0), ("DE", 1.0), ("ES", 1.0), ("IT", 1.0)],
            _ => &[("SE", 2.0), ("NO", 2.0), ("DK", 2.0), ("FI", 2.0), ("DE", 1.0), ("EE", 0.3)],
        };
        let cross_border_countries: Vec<usize> = cb.iter().filter(|(c, _)| *c != m.country).map(|(c, _)| w.country_index(c)).collect();
        let cross_border = Weighted::new(cb.iter().filter(|(c, _)| *c != m.country).map(|(_, x)| *x));
        let complements: Vec<Vec<usize>> = product_types
            .iter()
            .map(|pt| pt.complements.iter().filter_map(|c| product_types.iter().position(|x| &x.kind == c)).collect())
            .collect();
        let vertical_mid_eur = libm::exp(product_types.iter().map(|pt| libm::log((pt.price_eur[0] * pt.price_eur[1]).sqrt())).sum::<f64>() / product_types.len() as f64);
        let price_level = w.catalog.price_levels.get(&m.currency).copied().unwrap_or(1.0);
        let join = time::day_of(time::parse_date(&m.joined_on)).max(0) as Day;
        let churn_day = m.churned_on.as_ref().map(|c| time::day_of(time::parse_date(c)) as Day);
        let n_end = 25.0 + 1400.0 * libm::pow(share / 0.186, 0.6) * cfg.sf.sqrt();
        MerchantSim {
            idx,
            m,
            vertical,
            chunk: Chunk::new(chunk_id),
            share,
            growth,
            b2b,
            country,
            tz: time::tz_by_name(&m.timezone),
            domain,
            sku_prefix: initials(&m.name),
            order_prefix,
            tenant: None,
            staff: Vec::new(),
            warehouses: Vec::new(),
            agents: Vec::new(),
            slas: Vec::new(),
            support_tags: Vec::new(),
            articles: Vec::new(),
            templates: None,
            ledger: None,
            payout_carry: BTreeMap::new(),
            webhooks: Vec::new(),
            sends_sms: false,
            support_delay: 0.0,
            pack_delay_days: 0.0,
            support_q: Default::default(),
            warehouse_q: Default::default(),
            products: Vec::new(),
            live: Vec::new(),
            initial_catalog: 0,
            live_w: None,
            by_type: Vec::new(),
            complements,
            vertical_mid_eur,
            price_level,
            shopper_chunks,
            new_shoppers: (0..shopper_chunks).map(|_| Vec::new()).collect(),
            anon_sessions_today: 0.0,
            seed,
            product_types,
            categories: BTreeMap::new(),
            category_rows: BTreeMap::new(),
            closure_rows: BTreeMap::new(),
            meta: Default::default(),
            pricing: Default::default(),
            // a rough first guess of daily revenue, until the merchant sees its own
            mkt: marketing::Marketing::new(p.new_customers_end * cfg.sf * share * 2.5 * vertical_mid_eur * vertical.items_per_order * price_level),
            subs: None,
            admin: Default::default(),
            crm: Default::default(),
            analytics: Default::default(),
            mess: 0.01 + 0.12 * ((hash_str(&format!("{}|hygiene", m.slug)) % 1000) as f64 / 1000.0).powi(2),
            gift_card: None,
            companies: Vec::new(),
            inv: inventory::Inventory::new(p.new_customers_end * cfg.sf * share * 2.2 * vertical.items_per_order),
            brands: Vec::new(),
            slugs: BTreeSet::new(),
            product_seq: 10000,
            launch_rate: n_end * 0.35 / 1096.0,
            join_day: join,
            churn_day,
            domains: people::EmailDomains::new(),
            cross_border,
            cross_border_countries,
        }
    }

    pub fn tenant_rid(&self) -> Rid {
        self.tenant.expect("tenant not created yet").rid
    }

    pub fn is_active(&self, day: Day) -> bool {
        day >= self.join_day && self.churn_day.is_none_or(|c| day < c) && self.tenant.is_some()
    }

    pub fn joined_ts(&self) -> Ts {
        self.tz.local_to_utc(time::parse_date(&self.m.joined_on), 10 * MICROS_PER_HOUR)
    }

    /// Merchant phase of one day.
    pub fn day(&mut self, day: Day, cfg: &Config, p: &Params, refs: &Refs, outs: &[&DayOut]) {
        let captured: Vec<&Captured> = outs.iter().flat_map(|o| o.captured.iter()).collect();
        // yesterday's load on the warehouse and the support desk (seasonal staff in the peak)
        let orders: u32 = outs.iter().map(|o| o.orders).sum();
        let tickets: u32 = outs.iter().map(|o| o.tickets).sum();
        self.pack_delay_days = self.warehouse_q.step(orders as f64, 1.4, 1.2 * calendar::peak_capacity(day));
        self.support_delay = self.support_q.step(tickets as f64, 1.35, crate::sim::stories::support_capacity(self.m, day));
        self.chunk.day = day;
        for v in self.new_shoppers.iter_mut() {
            v.clear();
        }
        self.anon_sessions_today = 0.0;
        self.mkt.sends_today.clear();
        let mut rng = Rng::new(self.seed, &[2, day as u64]);
        if day == self.join_day && self.tenant.is_none() {
            self.onboard(day, cfg, &mut rng, refs);
        }
        if self.tenant.is_none() {
            return;
        }
        // payouts keep running for payments captured before churn
        self.payouts(day, &mut rng, &captured);
        let ops: Vec<&(usize, usize, StockOp, i64)> = outs.iter().flat_map(|o| o.stock.iter()).collect();
        self.inventory_day(&mut rng, day, &ops);
        let used: Vec<Rid> = outs.iter().flat_map(|o| o.coupons.iter().copied()).collect();
        self.count_redemptions(&used);
        self.count_marketing(outs);
        if let Some(c) = self.churn_day {
            if day >= c {
                return;
            }
        }
        self.analytics_day(day, outs);
        if day == 0 {
            self.migrated_cohort(0);
        }
        self.seasonal_collections(day);
        if crate::sim::stories::s19_restructure(self.m, day) {
            self.restructure_categories(day);
        }
        self.promotions_day(day, &mut rng);
        self.campaigns_day(day, &mut rng);
        self.subscriptions_day(day, &mut rng);
        self.admin_day(day, &mut rng, orders);
        self.crm_day(day, &mut rng, cfg.sf);
        // catalog: new launches, weekly refresh of live products and their weights
        let launches = rng.poisson(self.launch_rate * calendar::merchant_level(self.m, self.growth, day).max(0.2));
        for _ in 0..launches {
            let ts = self.tz.local_to_utc(time::date_of(day), rng.int(8, 17) * MICROS_PER_HOUR + rng.int(0, 3_599_000_000));
            self.create_product(&mut rng, day, ts);
        }
        if launches > 0 || day % 7 == 0 || self.live_w.is_none() {
            self.refresh_live(day);
        }
        // demand
        self.paid_day(day, &mut rng, outs);
        let level = calendar::merchant_level(self.m, self.growth, day);
        let demand = level * calendar::demand(&self.m.vertical, self.vertical, self.b2b, day) * self.promo_boost(day);
        let new_customers = p.new_customers_end * cfg.sf * self.share * demand * self.mkt.paid_volume * if crate::sim::stories::s20_slump(self.m, day) { 0.6 } else { 1.0 };
        let _ = cfg;
        self.anon_sessions_today = new_customers * p.anon_sessions_per_new_customer;
        let n = rng.poisson(new_customers);
        for _ in 0..n {
            let ns = self.new_shopper(&mut rng, day, None);
            let k = self.route(&ns);
            self.new_shoppers[k].push(ns);
        }
        // S7: the influencer's audience floods in during the sale
        if crate::sim::stories::s7_window(self.m, day) {
            for _ in 0..rng.poisson(new_customers * 2.0) {
                let mut ns = self.new_shopper(&mut rng, day, None);
                ns.influencer = true;
                ns.buys = rng.chance(0.9);
                ns.created = ns.first_seen + rng.int(0, 3 * 3600) * 1_000_000;
                let k = self.route(&ns);
                self.new_shoppers[k].push(ns);
            }
        }
        // S8: a ring of fake accounts abuses the welcome coupon
        if crate::sim::stories::s8_window(self.m, day) {
            let total = (30.0 * cfg.sf).max(25.0);
            for _ in 0..rng.poisson(total / 82.0) {
                let mut ns = self.new_shopper(&mut rng, day, None);
                ns.fraud = true;
                // throwaway addresses: never collide with real customers in other chunks
                ns.email_base = format!("{}{}", ns.email_base, rng.digits(6));
                ns.buys = true;
                ns.created = ns.first_seen;
                self.new_shoppers[0].push(ns);
            }
        }
        // shoppers that existed before the 2023 migration, or on the platform a merchant moves
        // over from when it joins later (half of them have such a history; S14 does)
        let joined = time::parse_date(&self.m.joined_on);
        let history = joined >= time::start_date() && (crate::sim::stories::has(self.m, "S14") || hash_str(&format!("{}|history", self.m.slug)) % 2 == 0);
        if day == self.join_day && (joined < time::start_date() || history) {
            let (first, until) = if joined < time::start_date() {
                (joined.max(chrono::NaiveDate::from_ymd_opt(2019, 1, 1).unwrap()), time::start_date())
            } else {
                (joined - chrono::Duration::days(365 + (hash_str(&self.m.slug) % 730) as i64), joined)
            };
            let years = ((until - first).num_days() as f64 / 365.25).min(2.5);
            // the established business's level (past the onboarding ramp-up)
            let level = calendar::merchant_level(self.m, self.growth, if day == 0 { 0 } else { (day + 150).min(time::num_days() - 1) });
            let base = p.new_customers_end * cfg.sf * self.share * level;
            let n = rng.poisson(base * 365.0 * years * p.migrated_survival);
            let span = (until - first).num_days().max(1);
            for _ in 0..n {
                let d = first + chrono::Duration::days(rng.int(0, span - 1));
                let created = self.tz.local_to_utc(d, rng.int(7, 22) * MICROS_PER_HOUR + rng.int(0, 3_599_000_000));
                let mut ns = self.new_shopper(&mut rng, day, Some(created));
                ns.migrated = true;
                let k = self.route(&ns);
                self.new_shoppers[k].push(ns);
            }
            if joined >= time::start_date() && n > 0 {
                let at = self.joined_ts() + 26 * MICROS_PER_HOUR;
                self.import_customers(&mut rng, day, at, n as i64);
            }
        }
    }

    fn route(&self, ns: &NewShopper) -> usize {
        if ns.fraud {
            return 0; // the ring's accounts share addresses and devices
        }
        let key = match &ns.company { Some(c) => c.clone(), None => format!("{}@{}", ns.email_base, ns.domain) };
        (hash_str(&key) % self.shopper_chunks as u64) as usize
    }

    fn new_shopper(&mut self, rng: &mut Rng, day: Day, created: Option<Ts>) -> NewShopper {
        let imported = created.is_some();
        let w = world();
        let country = if rng.chance(if self.m.country == "US" { 0.94 } else { 0.82 }) {
            self.country
        } else {
            self.cross_border_countries[self.cross_border.sample(rng)]
        };
        let c = &w.geo.countries[country];
        let person = people::person(rng, c);
        let mut domain = self.domains.pick(rng, &c.iso2);
        let mut country = country;
        let company = if self.b2b {
            // a colleague of an existing customer, or a new company
            if !self.companies.is_empty() && rng.chance(0.25) {
                let (name, ci) = self.companies[rng.below(self.companies.len())].clone();
                country = ci;
                domain = crate::sim::shopper::company_domain(&name, &w.geo.countries[ci].iso2);
                Some(name)
            } else {
                let name = crate::sim::shopper::company_name(rng, c, &self.m.vertical);
                domain = crate::sim::shopper::company_domain(&name, &c.iso2);
                self.companies.push((name.clone(), country));
                Some(name)
            }
        } else {
            None
        };
        let created = created.unwrap_or_else(|| {
            let hours = calendar::hourly(self.b2b);
            let h = Weighted::new(hours.iter().copied()).sample(rng) as i64;
            self.tz.local_to_utc(time::date_of(day), h * MICROS_PER_HOUR + rng.int(0, 3_599_999_999))
        });
        // many visitors browse anonymously for days before they sign up (not migrated ones)
        let lag = if imported || rng.chance(0.45) { 0 } else { ((1.0 + rng.exp(5.0)).min(60.0) * MICROS_PER_DAY as f64) as i64 };
        let email_base = people::email_local(rng, &person, 0);
        NewShopper { person, country, domain, first_seen: created, created: created + lag, buys: rng.chance(0.78), seed: rng.u64(), company, influencer: false, fraud: false, migrated: false, email_base }
    }

    fn refresh_live(&mut self, day: Day) {
        self.live.clear();
        let mut ws = Vec::new();
        for (i, p) in self.products.iter().enumerate() {
            if p.launch_day <= day && p.archive_day.is_none_or(|a| day < a) && !p.voucher {
                let age = (day - p.launch_day) as f64;
                // lifecycle: ramp up over ~3 weeks, slow decline after a year; merchandising
                // follows the season
                let life = (0.3 + age / 30.0).min(1.0) * if age > 365.0 { libm::exp(-(age - 365.0) / 500.0) } else { 1.0 };
                self.live.push(i);
                ws.push(libm::exp(p.appeal + 0.7 * calendar::season_factor(p.season, day)) * life);
            }
        }
        let mut by_type: Vec<(Vec<usize>, Vec<f64>)> = (0..self.product_types.len()).map(|_| (Vec::new(), Vec::new())).collect();
        for (k, &i) in self.live.iter().enumerate() {
            let p = &self.products[i];
            by_type[p.ty].0.push(i);
            by_type[p.ty].1.push(ws[k]);
        }
        self.by_type = by_type
            .into_iter()
            .map(|(products, w)| TypeIndex { weights: if w.is_empty() { None } else { Some(Weighted::new(w)) }, products })
            .collect();
        self.live_w = if ws.is_empty() { None } else { Some(Weighted::new(ws)) };
    }

    /// A live product of a product type, by popularity.
    pub fn product_of_type(&self, rng: &mut Rng, ty: usize) -> Option<usize> {
        let ti = self.by_type.get(ty)?;
        ti.weights.as_ref().map(|w| ti.products[w.sample(rng)])
    }

    // ---------------------------------------------------------------------------------
    // onboarding
    // ---------------------------------------------------------------------------------

    fn onboard(&mut self, day: Day, cfg: &Config, rng: &mut Rng, refs: &Refs) {
        let w = world();
        let m = self.m;
        let joined = self.joined_ts();
        let end = time::end_ts();
        // tenant (deferred: status and timestamps describe the end state)
        let mut t = Row::new(tenants::NCOLS);
        let status = m.status.as_str();
        let trial_end = joined + 14 * MICROS_PER_DAY;
        t.set(tenants::PUBLIC_ID, V::Uuid(rng.uuid()))
            .set(tenants::NAME, m.name.clone())
            .set(tenants::SLUG, m.slug.clone())
            .set(tenants::STATUS, V::Str(status.to_string()))
            .set(tenants::DEFAULT_CURRENCY_CODE, m.currency.clone())
            .set(tenants::DEFAULT_LOCALE, m.locale.clone())
            .set(tenants::INDUSTRY, self.vertical.label.clone())
            .set(tenants::EMPLOYEE_COUNT, m.employee_count)
            .set(tenants::TRIAL_ENDS_AT, if status == "trial" || rng.chance(0.6) { V::Ts(trial_end) } else { V::Null })
            .set(tenants::SIGNUP_SOURCE, m.signup_source.clone())
            .set(tenants::CREATED_AT, V::Ts(joined))
            .set(tenants::UPDATED_AT, V::Ts((joined + rng.int(1, 300) * MICROS_PER_DAY).min(end)))
            .set(
                tenants::DELETED_AT,
                m.churned_on.as_ref().map_or(V::Null, |c| V::Ts(time::ts_of_date(time::parse_date(c)) + 9 * MICROS_PER_HOUR)),
            );
        let th = self.chunk.emit_deferred(tenants::T, day, t);
        self.tenant = Some(th);
        let tenant = th.rid;

        // staff
        let n_staff = 2 + (3.0 * libm::sqrt(m.employee_count as f64 / 100.0) * libm::pow(cfg.sf, 0.25)).round() as usize;
        let roles = ["owner", "admin", "support", "support", "warehouse", "marketing", "support", "merchandiser", "finance", "warehouse", "sales"];
        let c = w.country(&m.country);
        let mut used = BTreeSet::new();
        for i in 0..n_staff {
            let role = roles[i % roles.len()];
            let p = people::person(rng, c);
            let mut local = format!("{}.{}", people::ascii_fold(&p.first).replace(' ', ""), people::ascii_fold(&p.last).replace(' ', ""));
            while !used.insert(local.clone()) {
                local.push_str(&rng.digits(1));
            }
            let created = joined + rng.int(0, 90) * MICROS_PER_DAY + rng.int(0, MICROS_PER_DAY - 1);
            let created = if i == 0 { joined } else { created };
            let mut u = Row::new(users::NCOLS);
            u.set(users::PUBLIC_ID, V::Uuid(rng.uuid()))
                .set(users::TENANT_ID, tenant)
                .set(users::EMAIL, format!("{local}@{}", self.domain))
                .set(users::FULL_NAME, format!("{} {}", p.first, p.last))
                .set(users::STATUS, "active")
                .set(users::IS_STAFF, true)
                .set(users::LOCALE, m.locale.clone())
                .set(users::TIMEZONE, m.timezone.clone())
                .set(users::PASSWORD_HASH, people::password_hash(rng))
                .set(users::LAST_LOGIN_AT, V::Ts(end - rng.int(0, 20) * MICROS_PER_DAY - rng.int(0, MICROS_PER_DAY - 1)))
                .set(users::CREATED_AT, V::Ts(created))
                .set(users::UPDATED_AT, V::Ts(created + rng.int(0, 200) * MICROS_PER_DAY));
            let h = self.chunk.emit_deferred(users::T, day, u);
            let mut pr = Row::new(user_profiles::NCOLS);
            pr.set(user_profiles::TENANT_ID, tenant)
                .set(user_profiles::USER_ID, h.rid)
                .set(user_profiles::PHONE, if rng.chance(0.6) { V::Str(people::phone(rng, &m.country)) } else { V::Null })
                .set(user_profiles::JOB_TITLE, V::Str(job_title(role).to_string()))
                .set(user_profiles::CREATED_AT, V::Ts(created))
                .set(user_profiles::UPDATED_AT, V::Ts(created));
            self.chunk.emit(user_profiles::T, day, pr);
            self.staff.push(Staff { user: h, role });
        }

        self.setup_support(day, joined, rng);
        self.setup_comms(day, joined, rng);
        self.setup_ledger(day, joined);

        // warehouses
        let n_wh = if m.size_rank <= 7 { 3 } else if m.size_rank <= 30 { 2 } else { 1 };
        for i in 0..n_wh {
            let country = if i == 2 && !self.cross_border_countries.is_empty() { self.cross_border_countries[0] } else { self.country };
            let a = people::address(rng, country);
            let addr = self.emit_address(day, joined, None, &a, refs, "Warehouse", false);
            let code = format!("WH-{}-{:02}", people::ascii_fold(&a.city_name).replace(' ', "").chars().take(3).collect::<String>().to_uppercase(), i + 1);
            let mut r = Row::new(warehouses::NCOLS);
            r.set(warehouses::TENANT_ID, tenant)
                .set(warehouses::ADDRESS_ID, addr)
                .set(warehouses::CODE, code)
                .set(warehouses::NAME, format!("{} {}", a.city_name, if i == 0 { "Fulfilment Centre" } else { "Warehouse" }))
                .set(warehouses::IS_DEFAULT, i == 0)
                .set(warehouses::IS_ACTIVE, true)
                .set(warehouses::CREATED_AT, V::Ts(joined))
                .set(warehouses::UPDATED_AT, V::Ts(joined));
            let rid = self.chunk.emit(warehouses::T, day, r);
            self.warehouses.push(Warehouse { rid, country, city: a.city_name.clone() });
        }
        self.setup_inventory(day, joined, rng, cfg.sf);
        self.setup_pricing(day, joined, rng, refs);
        self.setup_marketing(day, joined + 3 * MICROS_PER_HOUR, rng);
        self.setup_subscriptions(day, joined + 4 * MICROS_PER_HOUR, rng);
        self.setup_admin(day, joined, rng, refs);
        self.setup_crm(day, joined + 5 * MICROS_PER_HOUR, rng);
        self.tax_registrations(day, joined, rng);
        self.setup_analytics(day, joined + 6 * MICROS_PER_HOUR, rng);

        // brands
        let brand_names: Vec<String> = match self.vertical.brand_style.as_str() {
            "own" => vec![m.name.clone()],
            "mixed" => {
                let mut v = vec![m.name.clone()];
                let mut pool = self.vertical.brand_names.clone();
                rng.shuffle(&mut pool);
                v.extend(pool.into_iter().take(3 + rng.below(6)));
                v
            }
            _ => {
                let mut pool = self.vertical.brand_names.clone();
                rng.shuffle(&mut pool);
                let k = (6.0 + 20.0 * libm::pow(self.share / 0.186, 0.4) * cfg.sf.powf(0.25)).round() as usize;
                pool.into_iter().take(k.max(4)).collect()
            }
        };
        let mut bslugs = BTreeSet::new();
        for b in brand_names {
            let slug = people::slugify(&b);
            if !bslugs.insert(slug.clone()) {
                continue;
            }
            let mut r = Row::new(brands::NCOLS);
            r.set(brands::TENANT_ID, tenant)
                .set(brands::NAME, b.clone())
                .set(brands::SLUG, slug.clone())
                .set(brands::DESCRIPTION, if rng.chance(0.5) { V::Str(format!("Products by {b}.")) } else { V::Null })
                .set(brands::LOGO_URL, if rng.chance(0.7) { V::Str(format!("https://cdn.{}/brands/{slug}.svg", self.domain)) } else { V::Null })
                .set(brands::IS_ACTIVE, true)
                .set(brands::CREATED_AT, V::Ts(joined))
                .set(brands::UPDATED_AT, V::Ts(joined));
            self.brands.push(self.chunk.emit(brands::T, day, r));
        }

        // categories: tops, then leaves, from the product types sold
        let mut paths = BTreeSet::new();
        for pt in &self.product_types {
            for c in &pt.categories {
                paths.insert(c.clone());
            }
        }
        let mut pos = 0;
        for path in &paths {
            let parts: Vec<&str> = path.split(" > ").collect();
            let mut parent: Option<Rid> = None;
            let mut acc = String::new();
            for part in parts {
                if !acc.is_empty() {
                    acc.push_str(" > ");
                }
                acc.push_str(part);
                if let Some(r) = self.categories.get(&acc) {
                    parent = Some(*r);
                    continue;
                }
                let mut r = Row::new(categories::NCOLS);
                r.set(categories::TENANT_ID, tenant)
                    .set(categories::PARENT_ID, V::opt_ref(parent))
                    .set(categories::NAME, part.to_string())
                    .set(categories::SLUG, people::slugify(&acc))
                    .set(categories::SORT_POSITION, pos)
                    .set(categories::IS_ACTIVE, true)
                    .set(categories::CREATED_AT, V::Ts(joined))
                    .set(categories::UPDATED_AT, V::Ts(joined));
                pos += 1;
                let h = self.chunk.emit_deferred(categories::T, day, r);
                let rid = h.rid;
                self.categories.insert(acc.clone(), rid);
                self.category_rows.insert(acc.clone(), h);
                parent = Some(rid);
            }
        }
        self.setup_catalog_meta(day, joined, rng);

        // initial catalog (for migrated merchants: products created before 2023)
        let n_init = (self.launch_rate * 1096.0 / 0.35 * 0.65).round().max(8.0) as usize;
        let before = joined < time::ts_of_day(0);
        self.initial_catalog = n_init;
        let first = self.products.len();
        let mut created = Vec::with_capacity(n_init);
        for _ in 0..n_init {
            let ts = if before {
                joined + rng.int(0, (time::ts_of_day(0) - joined) / MICROS_PER_DAY - 1).max(0) * MICROS_PER_DAY + rng.int(0, MICROS_PER_DAY - 1)
            } else {
                joined + rng.int(0, 6 * MICROS_PER_HOUR)
            };
            self.create_product(rng, day, ts);
            created.push(ts);
        }
        self.refresh_live(day);
        // recommendations need the live catalog: a recommendation exists once both products do
        for (i, &ts) in created.iter().enumerate() {
            self.relate(rng, day, first + i, |rp| if rp >= first && rp - first < created.len() { ts.max(created[rp - first]) } else { ts });
        }
        if !self.b2b && matches!(self.m.vertical.as_str(), "beauty" | "home_living" | "apparel_footwear" | "books_stationery" | "jewelry_accessories" | "sports_outdoor") {
            self.create_gift_card(rng, day, joined + 2 * MICROS_PER_DAY);
        }
        if matches!(self.m.vertical.as_str(), "beauty" | "home_living" | "food_coffee" | "consumer_electronics" | "jewelry_accessories" | "books_stationery") {
            let n = 1 + rng.below(4);
            self.bundles(rng, day, joined + MICROS_PER_DAY, n);
        }
    }

    fn setup_ledger(&mut self, day: Day, joined: Ts) {
        let tenant = self.tenant_rid();
        let cur = self.m.currency.clone();
        let acct = |c: &mut Chunk, code: &str, name: &str, kind: &str| -> Rid {
            let mut r = Row::new(ledger_accounts::NCOLS);
            r.set(ledger_accounts::TENANT_ID, tenant)
                .set(ledger_accounts::CODE, code.to_string())
                .set(ledger_accounts::NAME, name.to_string())
                .set(ledger_accounts::ACCOUNT_TYPE, kind.to_string())
                .set(ledger_accounts::CURRENCY_CODE, cur.clone())
                .set(ledger_accounts::IS_ACTIVE, true)
                .set(ledger_accounts::CREATED_AT, V::Ts(joined))
                .set(ledger_accounts::UPDATED_AT, V::Ts(joined));
            c.emit(ledger_accounts::T, day, r)
        };
        let c = &mut self.chunk;
        self.ledger = Some(Ledger {
            bank: acct(c, "1000", "Bank", "asset"),
            clearing: acct(c, "1010", "Payment gateway clearing", "asset"),
            vat: acct(c, "2200", "VAT / sales tax payable", "liability"),
            revenue: acct(c, "4000", "Sales revenue", "revenue"),
            shipping_income: acct(c, "4100", "Shipping income", "revenue"),
            refunds: acct(c, "4900", "Refunds and returns", "contra_revenue"),
            fees: acct(c, "6100", "Payment processing fees", "expense"),
            gift_cards: acct(c, "2300", "Gift cards and store credit", "liability"),
        });
    }

    /// Daily payouts per gateway for the payments captured yesterday (from the shopper chunks).
    fn payouts(&mut self, day: Day, rng: &mut Rng, captured: &[&Captured]) {
        if captured.is_empty() {
            return;
        }
        let tenant = self.tenant_rid();
        let ledger = self.ledger.as_ref().unwrap();
        let (bank, clearing, fees_acct) = (ledger.bank, ledger.clearing, ledger.fees);
        let mut by_gateway: BTreeMap<&str, Vec<&Captured>> = BTreeMap::new();
        for c in captured {
            by_gateway.entry(c.gateway.as_str()).or_default().push(c);
        }
        let end = time::end_ts();
        for (gw, items) in by_gateway {
            let gross: i64 = items.iter().filter(|c| c.amount > 0).map(|c| c.amount).sum();
            let refunds: i64 = -items.iter().filter(|c| c.amount < 0).map(|c| c.amount).sum::<i64>();
            let fee: i64 = items.iter().map(|c| c.fee).sum();
            let carry = self.payout_carry.get(gw).copied().unwrap_or(0);
            let mut net = gross - fee - refunds + carry;
            let new_carry = if net < 0 { net } else { 0 };
            self.payout_carry.insert(gw.to_string(), new_carry);
            if gross == 0 {
                continue;
            }
            net = net.max(0);
            let created = time::ts_of_day(day) + 23 * MICROS_PER_HOUR + rng.int(0, 1200) * 1_000_000;
            let arrival = time::date_of(day) + chrono::Duration::days(if gw == "Moravell" { 3 } else { 1 });
            let paid_at = time::ts_of_date(arrival) + 9 * MICROS_PER_HOUR;
            let items: Vec<&&Captured> = items.iter().filter(|c| c.amount > 0).collect();
            let mut r = Row::new(payouts::NCOLS);
            r.set(payouts::TENANT_ID, tenant)
                .set(payouts::CURRENCY_CODE, self.m.currency.clone())
                .set(payouts::GROSS_AMOUNT, V::Money(gross))
                .set(payouts::FEE_AMOUNT, V::Money(fee))
                .set(payouts::NET_AMOUNT, V::Money(net))
                .set(payouts::STATUS, if paid_at <= end { "paid" } else { "in_transit" })
                .set(payouts::GATEWAY_PAYOUT_ID, format!("po_{}", rng.alnum(24)))
                .set(payouts::ARRIVAL_DATE, V::Date(time::epoch_days(arrival)))
                .set(payouts::PAID_AT, if paid_at <= end { V::Ts(paid_at) } else { V::Null })
                .set(payouts::CREATED_AT, V::Ts(created))
                .set(payouts::UPDATED_AT, V::Ts(paid_at.min(end)));
            let payout = self.chunk.emit(payouts::T, day, r);
            for c in &items {
                let mut r = Row::new(payout_items::NCOLS);
                r.set(payout_items::TENANT_ID, tenant)
                    .set(payout_items::PAYOUT_ID, payout)
                    .set(payout_items::PAYMENT_ID, c.payment)
                    .set(payout_items::AMOUNT, V::Money(c.amount))
                    .set(payout_items::FEE_AMOUNT, V::Money(c.fee))
                    .set(payout_items::CURRENCY_CODE, self.m.currency.clone())
                    .set(payout_items::CREATED_AT, V::Ts(created))
                    .set(payout_items::UPDATED_AT, V::Ts(created));
                self.chunk.emit(payout_items::T, day, r);
            }
            let group = rng.uuid();
            for (acct, dir, amount, desc) in [(bank, "debit", net, "Payout to bank"), (fees_acct, "debit", fee, "Processing fees"), (clearing, "credit", net + fee, "Payout from gateway clearing")] {
                if amount <= 0 {
                    continue;
                }
                let mut r = Row::new(ledger_entries::NCOLS);
                r.set(ledger_entries::TENANT_ID, tenant)
                    .set(ledger_entries::LEDGER_ACCOUNT_ID, acct)
                    .set(ledger_entries::ENTRY_GROUP, V::Uuid(group))
                    .set(ledger_entries::DIRECTION, dir)
                    .set(ledger_entries::AMOUNT, V::Money(amount))
                    .set(ledger_entries::CURRENCY_CODE, self.m.currency.clone())
                    .set(ledger_entries::DESCRIPTION, format!("{desc} ({gw})"))
                    .set(ledger_entries::OCCURRED_AT, V::Ts(created))
                    .set(ledger_entries::CREATED_AT, V::Ts(created));
                self.chunk.emit(ledger_entries::T, day, r);
            }
        }
    }

    fn setup_comms(&mut self, day: Day, joined: Ts, rng: &mut Rng) {
        let tenant = self.tenant_rid();
        let ts = joined + 2 * MICROS_PER_HOUR;
        let name = self.m.name.clone();
        let tpl = |c: &mut Chunk, code: &str, title: &str, channel: &str, subject: Option<String>, body: String| -> Rid {
            let mut r = Row::new(notification_templates::NCOLS);
            r.set(notification_templates::TENANT_ID, tenant)
                .set(notification_templates::CODE, code.to_string())
                .set(notification_templates::NAME, title.to_string())
                .set(notification_templates::CHANNEL, channel.to_string())
                .set(notification_templates::SUBJECT, subject)
                .set(notification_templates::BODY, body)
                .set(notification_templates::LOCALE, self.m.locale.clone())
                .set(notification_templates::IS_ACTIVE, true)
                .set(notification_templates::CREATED_AT, V::Ts(ts))
                .set(notification_templates::UPDATED_AT, V::Ts(ts));
            c.emit(notification_templates::T, day, r)
        };
        let c = &mut self.chunk;
        let order_confirmation = tpl(c, "order_confirmation", "Order confirmation", "email", Some(format!("Your {name} order is confirmed")), "Hi {{first_name}}, thanks for your order {{order_number}}. We'll let you know when it ships.".into());
        let shipping = tpl(c, "shipping_confirmation", "Shipping confirmation", "email", Some("Your order is on its way".into()), "Good news {{first_name}}! Order {{order_number}} has shipped with {{carrier}}. Track it here: {{tracking_url}}".into());
        let delivered = tpl(c, "delivered", "Delivery confirmation", "email", Some("Your order has been delivered".into()), "Your order {{order_number}} was delivered. Enjoy! Tell us what you think: {{review_url}}".into());
        let refund = tpl(c, "refund_issued", "Refund issued", "email", Some("We've refunded your order".into()), "We've refunded {{amount}} to your original payment method.".into());
        let welcome = tpl(c, "welcome", "Welcome", "email", Some(format!("Welcome to {name}")), "Welcome {{first_name}}! Here is 10% off your first order: {{code}}".into());
        let password_reset = tpl(c, "password_reset", "Password reset", "email", Some("Reset your password".into()), "Click here to reset your password: {{reset_url}}".into());
        self.sends_sms = rng.chance(0.3);
        let shipping_sms = if self.sends_sms { Some(tpl(&mut self.chunk, "shipping_sms", "Shipping SMS", "sms", None, format!("{name}: your order {{{{order_number}}}} is on its way. Track: {{{{tracking_url}}}}"))) } else { None };
        self.templates = Some(Templates { order_confirmation, shipping, delivered, refund, welcome, password_reset, shipping_sms });
        // webhooks to the merchant's own systems (ERP, warehouse, accounting)
        let creator = self.staff.iter().find(|s| s.role == "admin" || s.role == "owner").map(|s| s.user.rid);
        let n = if self.m.size_rank <= 5 { 3 } else if self.m.size_rank <= 20 { 1 + rng.below(2) } else if rng.chance(0.35) { 1 } else { 0 };
        let systems = [("erp", vec!["order.created", "order.cancelled", "refund.created"]), ("wms", vec!["fulfillment.shipped"]), ("accounting", vec!["payment.captured", "refund.created"])];
        for (sys, events) in systems.iter().take(n) {
            let mut r = Row::new(webhooks::NCOLS);
            r.set(webhooks::TENANT_ID, tenant)
                .set(webhooks::CREATED_BY_USER_ID, V::opt_ref(creator))
                .set(webhooks::NAME, format!("{} sync", sys.to_uppercase()))
                .set(webhooks::TARGET_URL, format!("https://{sys}.{}/hooks/tidewick", self.domain))
                .set(webhooks::SECRET_HASH, format!("whsec_{}", rng.alnum(40)))
                .set(webhooks::EVENT_TYPES, V::Arr(events.iter().map(|e| e.to_string()).collect()))
                .set(webhooks::IS_ACTIVE, true)
                .set(webhooks::LAST_DELIVERED_AT, V::Null)
                .set(webhooks::CREATED_AT, V::Ts(ts))
                .set(webhooks::UPDATED_AT, V::Ts(ts));
            let rid = self.chunk.emit(webhooks::T, day, r);
            self.webhooks.push(Webhook { rid, events: events.clone(), failure_rate: if rng.chance(0.2) { 0.15 } else { 0.01 } });
        }
    }

    fn setup_support(&mut self, day: Day, joined: Ts, rng: &mut Rng) {
        let tenant = self.tenant_rid();
        let ts = joined + MICROS_PER_DAY;
        let mut groups = Vec::new();
        let names: &[&str] = if self.b2b { &["Customer Service", "Key Accounts", "Returns & Claims"] } else { &["Customer Care", "Returns & Refunds", "Delivery Issues"] };
        for (i, n) in names.iter().enumerate() {
            if i > 0 && self.m.size_rank > 40 {
                break;
            }
            let mut r = Row::new(agent_groups::NCOLS);
            r.set(agent_groups::TENANT_ID, tenant)
                .set(agent_groups::NAME, *n)
                .set(agent_groups::DESCRIPTION, if rng.chance(0.5) { V::Str(format!("{n} queue")) } else { V::Null })
                .set(agent_groups::IS_ACTIVE, true)
                .set(agent_groups::CREATED_AT, V::Ts(ts))
                .set(agent_groups::UPDATED_AT, V::Ts(ts));
            groups.push(self.chunk.emit(agent_groups::T, day, r));
        }
        let support_staff: Vec<DHandle> = self.staff.iter().filter(|s| s.role == "support" || s.role == "owner").map(|s| s.user).collect();
        // S9: the last two agents hired leave in August 2025
        let leaving = crate::sim::stories::s9_leave(self.m).map(|t| (t, support_staff.len().saturating_sub(2).max(1)));
        for (i, u) in support_staff.iter().enumerate() {
            let left = leaving.filter(|(_, from)| i >= *from).map(|(t, _)| t);
            if let Some(t) = left {
                self.chunk.deferred_mut(*u).set(users::STATUS, "deactivated").set(users::UPDATED_AT, V::Ts(t)).set(users::LAST_LOGIN_AT, V::Ts(t - 3 * MICROS_PER_HOUR));
            }
            let name = match self.chunk.deferred_ref(*u).vals[users::FULL_NAME].clone() {
                V::Str(s) => s,
                _ => String::new(),
            };
            let first = name.split(' ').next().unwrap_or("").to_string();
            let mut r = Row::new(support_agents::NCOLS);
            r.set(support_agents::TENANT_ID, tenant)
                .set(support_agents::USER_ID, u.rid)
                .set(support_agents::DISPLAY_NAME, first.clone())
                .set(support_agents::SIGNATURE, format!("{first} | {} Customer Care", self.m.name))
                .set(support_agents::IS_AVAILABLE, left.is_none())
                .set(support_agents::MAX_OPEN_TICKETS, rng.int(15, 40))
                .set(support_agents::CREATED_AT, V::Ts(ts))
                .set(support_agents::UPDATED_AT, V::Ts(ts));
            let rid = self.chunk.emit(support_agents::T, day, r);
            let group = groups[i % groups.len()];
            let mut r = Row::new(agent_group_members::NCOLS);
            r.set(agent_group_members::TENANT_ID, tenant)
                .set(agent_group_members::AGENT_GROUP_ID, group)
                .set(agent_group_members::SUPPORT_AGENT_ID, rid)
                .set(agent_group_members::IS_LEAD, i < groups.len())
                .set(agent_group_members::CREATED_AT, V::Ts(ts));
            self.chunk.emit(agent_group_members::T, day, r);
            self.agents.push(Agent { rid, user: u.rid, group, left });
        }
        let bh = self.m.size_rank > 20;
        for (prio, fr, res) in [("low", 1440, 7200), ("normal", 480, 2880), ("high", 120, 1440), ("urgent", 60, 480)] {
            let mut r = Row::new(sla_policies::NCOLS);
            r.set(sla_policies::TENANT_ID, tenant)
                .set(sla_policies::NAME, format!("{} priority", prio[..1].to_uppercase() + &prio[1..]))
                .set(sla_policies::PRIORITY, prio)
                .set(sla_policies::FIRST_RESPONSE_TARGET_MINUTES, fr)
                .set(sla_policies::RESOLUTION_TARGET_MINUTES, res)
                .set(sla_policies::BUSINESS_HOURS_ONLY, bh)
                .set(sla_policies::IS_ACTIVE, true)
                .set(sla_policies::CREATED_AT, V::Ts(ts))
                .set(sla_policies::UPDATED_AT, V::Ts(ts));
            let rid = self.chunk.emit(sla_policies::T, day, r);
            self.slas.push(Sla { rid, first_response_min: fr, resolution_min: res });
        }
        let colors = ["#e74c3c", "#3498db", "#2ecc71", "#f1c40f", "#9b59b6", "#e67e22", "#1abc9c", "#34495e"];
        for (i, tag) in ["delivery", "where-is-my-order", "return", "refund", "damaged", "payment", "account", "product-question", "complaint", "wholesale"].iter().enumerate() {
            if *tag == "wholesale" && !self.b2b {
                continue;
            }
            let mut r = Row::new(support_tags::NCOLS);
            r.set(support_tags::TENANT_ID, tenant)
                .set(support_tags::NAME, *tag)
                .set(support_tags::COLOR, if rng.chance(0.7) { V::Static(colors[i % colors.len()]) } else { V::Null })
                .set(support_tags::CREATED_AT, V::Ts(ts))
                .set(support_tags::UPDATED_AT, V::Ts(ts));
            self.support_tags.push((tag, self.chunk.emit(support_tags::T, day, r)));
        }
        // help centre
        let author = support_staff.first().map(|h| h.rid);
        let mut cats = Vec::new();
        for (i, c) in ["Orders & Delivery", "Returns & Refunds", "Payments", "Account", "Products"].iter().enumerate() {
            let mut r = Row::new(knowledge_categories::NCOLS);
            r.set(knowledge_categories::TENANT_ID, tenant)
                .set(knowledge_categories::NAME, *c)
                .set(knowledge_categories::SLUG, people::slugify(c))
                .set(knowledge_categories::SORT_POSITION, i)
                .set(knowledge_categories::CREATED_AT, V::Ts(ts))
                .set(knowledge_categories::UPDATED_AT, V::Ts(ts));
            cats.push(self.chunk.emit(knowledge_categories::T, day, r));
        }
        let articles: &[(usize, &str)] = &[
            (0, "How long does delivery take?"), (0, "How can I track my order?"), (0, "Do you ship internationally?"), (0, "My parcel is late - what now?"),
            (1, "How do I return an item?"), (1, "When will I get my refund?"), (1, "Can I exchange for a different size?"), (1, "My item arrived damaged"),
            (2, "Which payment methods do you accept?"), (2, "Why was my payment declined?"), (2, "Is it safe to pay online?"),
            (3, "How do I reset my password?"), (3, "How do I delete my account?"), (3, "Managing email preferences"),
            (4, "Size guide"), (4, "Product care instructions"),
        ];
        let reach = libm::sqrt(self.share / 0.186);
        for (c, title) in articles {
            let published = rng.chance(0.9);
            let views = if published { (rng.lognormal(7.0, 1.0) * reach * 3.0) as i64 } else { 0 };
            let helpful = (views as f64 * rng.uniform(0.01, 0.04)) as i64;
            let mut r = Row::new(knowledge_articles::NCOLS);
            r.set(knowledge_articles::TENANT_ID, tenant)
                .set(knowledge_articles::KNOWLEDGE_CATEGORY_ID, cats[*c])
                .set(knowledge_articles::AUTHOR_USER_ID, V::opt_ref(author))
                .set(knowledge_articles::TITLE, *title)
                .set(knowledge_articles::SLUG, people::slugify(title))
                .set(knowledge_articles::BODY, format!("{title} This article explains everything you need to know. If you still need help, contact our customer care team."))
                .set(knowledge_articles::IS_PUBLISHED, published)
                .set(knowledge_articles::VIEW_COUNT, V::Int(views))
                .set(knowledge_articles::HELPFUL_COUNT, V::Int(helpful))
                .set(knowledge_articles::NOT_HELPFUL_COUNT, V::Int((helpful as f64 * rng.uniform(0.1, 0.6)) as i64))
                .set(knowledge_articles::PUBLISHED_AT, if published { V::Ts(ts + rng.int(0, 30) * MICROS_PER_DAY) } else { V::Null })
                .set(knowledge_articles::CREATED_AT, V::Ts(ts))
                .set(knowledge_articles::UPDATED_AT, V::Ts(ts + rng.int(0, 400) * MICROS_PER_DAY));
            let rid = self.chunk.emit(knowledge_articles::T, day, r);
            if published {
                self.articles.push((*c, rid));
            }
        }
        let agent0 = self.agents.first().map(|a| a.rid);
        for (title, body) in [
            ("Where is my order", "Hi {name}, thanks for getting in touch. Your parcel is on its way with {carrier}; you can follow it with the tracking link in your shipping email."),
            ("Return instructions", "Hi {name}, you can return your items within 30 days. Please use the prepaid label in your account and we will refund you once the parcel arrives."),
            ("Refund processed", "Hi {name}, good news: your refund has been processed and should appear on your statement within 3-5 business days."),
            ("Damaged item apology", "Hi {name}, we are very sorry your item arrived damaged. We have arranged a replacement at no cost."),
            ("Payment declined", "Hi {name}, your bank declined the payment. Please try another card or contact your bank."),
        ] {
            let mut r = Row::new(macros::NCOLS);
            r.set(macros::TENANT_ID, tenant)
                .set(macros::CREATED_BY_AGENT_ID, V::opt_ref(agent0))
                .set(macros::TITLE, title)
                .set(macros::BODY, body)
                .set(macros::IS_SHARED, true)
                .set(macros::USAGE_COUNT, V::Int((rng.lognormal(4.0, 1.0) * reach * 4.0) as i64))
                .set(macros::CREATED_AT, V::Ts(ts))
                .set(macros::UPDATED_AT, V::Ts(ts));
            self.chunk.emit(macros::T, day, r);
        }
    }

    pub fn emit_address(&mut self, day: Day, created: Ts, user: Option<Rid>, a: &people::Address, refs: &Refs, label: &str, default: bool) -> Rid {
        let tenant = self.tenant_rid();
        emit_address(&mut self.chunk, tenant, day, created, user, a, refs, label, default)
    }

    fn create_product(&mut self, rng: &mut Rng, day: Day, created: Ts) {
        let w = world();
        let tenant = self.tenant_rid();
        let ty = rng.below(self.product_types.len());
        let pt = self.product_types[ty];
        let modifier = if pt.modifiers.is_empty() { None } else { Some(rng.pick(&pt.modifiers).clone()) };
        let material = if pt.materials.is_empty() || rng.chance(0.3) { None } else { Some(rng.pick(&pt.materials).clone()) };
        let brand = if self.brands.is_empty() { None } else { Some(*rng.pick(&self.brands)) };
        let name = [modifier.clone(), material.clone(), Some(pt.kind.clone())].into_iter().flatten().collect::<Vec<_>>().join(" ");
        let mut slug = people::slugify(&name);
        let mut k = 2;
        while self.slugs.contains(&slug) {
            slug = format!("{}-{k}", people::slugify(&name));
            k += 1;
        }
        self.slugs.insert(slug.clone());
        let sloppy = crate::sim::stories::s19_sloppy(self.m, day) && rng.chance(0.45);
        let cat = if sloppy && rng.chance(0.3) {
            // filed under a category of another product type
            let other = self.product_types[rng.below(self.product_types.len())];
            self.categories[rng.pick(&other.categories)]
        } else {
            self.categories[rng.pick(&pt.categories)]
        };
        let created_day = time::day_of_ts(created);
        let launch = created_day.max(day as i64) as Day;
        let life_days = rng.lognormal(libm::log(700.0), 0.6);
        // lifetime counts from the real creation date (migrated products may predate 2023)
        let archive_at = created_day + life_days as i64;
        let archive_day = if archive_at < time::num_days() as i64 { Some(archive_at.max(day as i64 + 1) as Day) } else { None };
        let draft = rng.chance(0.03);
        let status = if draft { "draft" } else if archive_day.is_some() { "archived" } else { "active" };
        let end = time::end_ts();
        let updated = archive_day.map_or(created + rng.int(0, 120) * MICROS_PER_DAY, |a| time::ts_of_day(a) + 10 * MICROS_PER_HOUR).min(end);
        let description = if rng.chance(0.3) {
            V::Null
        } else {
            let mut d = format!("Our {} {}", modifier.as_deref().unwrap_or("signature").to_lowercase(), pt.kind.to_lowercase());
            if let Some(mat) = &material {
                d.push_str(&format!(" in {}", mat.to_lowercase()));
            }
            d.push_str(rng.pick(&[". Designed to last.", ", made for everyday use.", ". A customer favourite.", ". Responsibly sourced.", "."]));
            V::Str(d)
        };
        let public_id = rng.uuid();
        let product_slug = slug.clone();
        let slug_for_meta = slug.clone();
        let mut r = Row::new(products::NCOLS);
        r.set(products::PUBLIC_ID, V::Uuid(public_id))
            .set(products::TENANT_ID, tenant)
            .set(products::BRAND_ID, V::opt_ref(brand))
            .set(products::PRIMARY_CATEGORY_ID, cat)
            .set(products::NAME, name.clone())
            .set(products::SLUG, slug)
            .set(products::DESCRIPTION, description)
            .set(products::STATUS, status)
            .set(products::IS_VISIBLE, status == "active")
            .set(products::PUBLISHED_AT, if draft { V::Null } else { V::Ts(created) })
            .set(products::SEO_TITLE, if rng.chance(0.6) { V::Str(format!("{name} | {}", self.m.name)) } else { V::Null })
            .set(products::CREATED_AT, V::Ts(created))
            .set(products::UPDATED_AT, V::Ts(updated.max(created)))
            .set(products::DELETED_AT, if status == "archived" && rng.chance(0.05) { V::Ts(updated.max(created)) } else { V::Null });
        let prid = self.chunk.emit(products::T, day, r);

        // variants: cartesian product of the axes, with a sampled subset of colours etc.
        let mut combos: Vec<Vec<(String, usize, usize)>> = vec![vec![]];
        let mut sizes = 0;
        for (ai, ax) in pt.axes.iter().enumerate() {
            let vals = &w.catalog.axes[ax];
            let take: Vec<usize> = match ax.as_str() {
                a if a.starts_with("size") || a == "ring_size" || a == "frame_size" => (0..vals.len()).collect(),
                a if a.starts_with("color") || a == "metal" || a == "shade" => {
                    let mut idx: Vec<usize> = (0..vals.len()).collect();
                    rng.shuffle(&mut idx);
                    idx.truncate(1 + rng.below(if a == "shade" { 6 } else { 3 }));
                    idx.sort();
                    idx
                }
                _ => {
                    let n = 1 + rng.below(vals.len().min(3));
                    let start = rng.below(vals.len() - n + 1);
                    (start..start + n).collect()
                }
            };
            if ai == 0 && (ax.starts_with("size") || ax == "ring_size" || ax == "frame_size") {
                sizes = take.len();
            }
            let mut next = Vec::new();
            for c in &combos {
                for &i in &take {
                    let mut c2 = c.clone();
                    c2.push((vals[i].clone(), i, vals.len()));
                    next.push(c2);
                }
            }
            combos = next;
            if combos.len() > 48 {
                combos.truncate(48);
            }
        }
        let mut variant_axes: Vec<(Rid, Vec<(String, usize)>)> = Vec::new();
        let base_eur = libm::exp(rng.uniform(libm::log(pt.price_eur[0]), libm::log(pt.price_eur[1])));
        let base_w = rng.uniform(pt.weight_g[0], pt.weight_g[1]);
        let mut variants = Vec::new();
        self.product_seq += 1;
        for (vi, combo) in combos.iter().enumerate() {
            // ordered, quantity-like axes (storage, volume, weight, pack) scale the price
            let mut mult = 1.0;
            for (_, i, n) in combo {
                if *n > 1 && combo.len() <= 2 {
                    let is_qty = pt.axes.iter().any(|a| matches!(a.as_str(), "storage" | "volume_ml" | "coffee_weight" | "pet_weight" | "pack" | "paper_pack"));
                    if is_qty {
                        mult *= 1.0 + 0.6 * *i as f64;
                    }
                }
            }
            let price = local_price(rng, base_eur * mult, &self.m.currency);
            let codes: Vec<String> = combo.iter().zip(&pt.axes).map(|((_, i, _), ax)| axis_codes(&w.catalog.axes[ax])[*i].clone()).collect();
            let sku = if codes.is_empty() { format!("{}-{}", self.sku_prefix, self.product_seq) } else { format!("{}-{}-{}", self.sku_prefix, self.product_seq, codes.join("-")) };
            let vname = combo.iter().map(|(v, _, _)| v.clone()).collect::<Vec<_>>().join(" / ");
            let weight = (base_w * mult.sqrt()).round() as i64;
            let mut r = Row::new(product_variants::NCOLS);
            r.set(product_variants::PUBLIC_ID, V::Uuid(rng.uuid()))
                .set(product_variants::TENANT_ID, tenant)
                .set(product_variants::PRODUCT_ID, prid)
                .set(product_variants::SKU, sku.clone())
                .set(product_variants::BARCODE, if rng.chance(0.85) { V::Str(ean13(rng, &self.m.country)) } else { V::Null })
                .set(product_variants::NAME, if vname.is_empty() { V::Null } else { V::Str(vname.clone()) })
                .set(product_variants::SORT_POSITION, vi)
                .set(product_variants::PRICE_AMOUNT, V::Money(price))
                .set(product_variants::CURRENCY_CODE, self.m.currency.clone())
                .set(product_variants::WEIGHT_GRAMS, V::Int(weight))
                .set(product_variants::IS_DEFAULT, vi == 0)
                .set(product_variants::IS_ACTIVE, status == "active")
                .set(product_variants::CREATED_AT, V::Ts(created))
                .set(product_variants::UPDATED_AT, V::Ts(updated.max(created)));
            let vrid = self.chunk.emit(product_variants::T, day, r);
            variant_axes.push((vrid, combo.iter().zip(&pt.axes).map(|((_, i, _), ax)| (ax.clone(), *i)).collect()));
            let full = if vname.is_empty() { name.clone() } else { format!("{name} - {vname}") };
            variants.push(Variant { rid: vrid, sku, name: full, price_cents: price, weight_g: weight });
        }
        let category_path = self.categories.iter().find(|(_, r)| **r == cat).map(|(k, _)| k.clone()).unwrap();
        let images = 1 + rng.poisson(2.5) as usize;
        let images = if sloppy { if rng.chance(0.6) { 0 } else { 1 } } else { images };
        if sloppy {
            // no size attribute values
            for (_, axes) in variant_axes.iter_mut() {
                axes.retain(|(ax, _)| !(ax.starts_with("size") || ax == "ring_size" || ax == "frame_size"));
            }
        }
        let season_code = match pt.season.as_deref() { Some("winter") => 1, Some("summer") => 2, _ => 0 };
        self.product_meta(rng, day, created, prid, &slug_for_meta, &name, &category_path, material.as_deref(), season_code, &variant_axes, images);
        self.products.push(Product {
            rid: prid,
            public_id,
            name,
            slug: product_slug,
            ty,
            launch_day: launch,
            archive_day,
            appeal: rng.gauss(0.0, 1.0),
            quality: rng.gauss(0.0, 1.0),
            price_eur: base_eur,
            price_rel: libm::log(base_eur / (pt.price_eur[0] * pt.price_eur[1]).sqrt()),
            fit_bias: rng.gauss(0.0, if sloppy { 0.5 } else { 0.2 }),
            fit_uncert: if sloppy { 1.0 } else { rng.uniform(0.1, 1.0) },
            fragility: fragility(&pt.kind) * rng.lognormal(0.0, 0.3),
            season: match pt.season.as_deref() { Some("winter") => 1, Some("summer") => 2, _ => 0 },
            related: Vec::new(),
            price_steps: Vec::new(),
            sizes: if sizes > 0 && variants.len() % sizes == 0 { sizes } else { 0 },
            voucher: false,
            sloppy,
            variants,
        });
        let pidx = self.products.len() - 1;
        let season = self.products[pidx].season;
        self.products[pidx].price_steps = self.price_schedule(rng, launch, archive_day, season);
        if let Some((actor, ip, ua)) = self.staff_actor(&["merchandiser", "admin", "owner"]) {
            let nv = self.products[pidx].variants.len();
            self.audit(rng, Audit { at: created, action: "create", actor: Some(actor), actor_type: "staff", entity: Some((products::T, prid)), summary: format!("Created product \"{}\"", self.products[pidx].name), metadata: format!(r#"{{"status":"{status}","variants":{nv}}}"#), ip: Some(&ip), ua: Some(ua) });
            // price changes: increases by staff, markdowns by the pricing rules
            let base = self.products[pidx].variants[0].price_cents;
            let vrid = self.products[pidx].variants[0].rid;
            let mut prev = base;
            for (d, f) in self.products[pidx].price_steps.clone() {
                let at = time::ts_of_day(d) + 6 * MICROS_PER_HOUR;
                let now = if f == 1.0 { base } else { pricing::round_price(base as f64 * f, &self.m.currency) };
                let up = now > prev;
                let (who, kind) = if up { (Some(actor), "staff") } else { (None, "system") };
                let meta = format!(r#"{{"source":"{}","variants":{nv}}}"#, if up { "bulk_price_update" } else { "pricing_rule" });
                let a = self.audit(rng, Audit { at, action: "update", actor: who, actor_type: kind, entity: Some((product_variants::T, vrid)), summary: format!("Price {} {} -> {}", if up { "increased" } else { "changed" }, prev as f64 / 100.0, now as f64 / 100.0), metadata: meta, ip: if up { Some(&ip) } else { None }, ua: if up { Some(ua) } else { None } });
                let tenant = self.tenant_rid();
                change(&mut self.chunk, tenant, a, who, (product_variants::T, vrid), &["price_amount"], format!(r#"{{"price_amount":"{}.{:02}"}}"#, prev / 100, prev % 100), format!(r#"{{"price_amount":"{}.{:02}"}}"#, now / 100, now % 100), at);
                prev = now;
            }
        }
        self.emit_prices(day, created, pidx);
        self.stock_new_product(rng, day, created, pidx);
        // the initial catalog gets its recommendations once it is live
        if !self.by_type.is_empty() {
            self.relate(rng, day, pidx, |_| created);
        }
    }

    /// Recommendations of a product: complements (cross-sell) and a pricier product of the same type (upsell), among
    /// the live products. `created` gives when a recommendation is made, from the recommended product.
    fn relate(&mut self, rng: &mut Rng, day: Day, pidx: usize, created: impl Fn(usize) -> Ts) {
        let tenant = self.tenant_rid();
        let (ty, prid) = (self.products[pidx].ty, self.products[pidx].rid);
        let mut related = Vec::new();
        let comps = self.complements[ty].clone();
        for k in 0..3usize {
            let target = if k < 2 && !comps.is_empty() { Some(comps[rng.below(comps.len())]) } else if k == 2 { Some(ty) } else { None };
            if let Some(t) = target {
                if let Some(rp) = self.product_of_type(rng, t) {
                    if rp != pidx && !related.contains(&rp) {
                        related.push(rp);
                    }
                }
            }
        }
        for (pos, &rp) in related.iter().enumerate() {
            let at = created(rp);
            let mut r = Row::new(product_relations::NCOLS);
            r.set(product_relations::TENANT_ID, tenant)
                .set(product_relations::PRODUCT_ID, prid)
                .set(product_relations::RELATED_PRODUCT_ID, self.products[rp].rid)
                .set(product_relations::RELATION_KIND, if self.products[rp].ty == ty { "upsell" } else { "cross_sell" })
                .set(product_relations::SORT_POSITION, pos)
                .set(product_relations::CREATED_AT, V::Ts(at))
                .set(product_relations::UPDATED_AT, V::Ts(at));
            self.chunk.emit(product_relations::T, day, r);
        }
        self.products[pidx].related = related;
    }
}

impl MerchantSim {
    /// Physical gift cards in three denominations.
    fn create_gift_card(&mut self, rng: &mut Rng, day: Day, created: Ts) {
        let tenant = self.tenant_rid();
        let Some(cat) = self.categories.values().next().copied() else { return };
        let name = format!("{} Gift Card", self.m.name);
        let mut r = Row::new(products::NCOLS);
        let public_id = rng.uuid();
        r.set(products::PUBLIC_ID, V::Uuid(public_id))
            .set(products::TENANT_ID, tenant)
            .set(products::PRIMARY_CATEGORY_ID, cat)
            .set(products::NAME, name.clone())
            .set(products::SLUG, "gift-card")
            .set(products::DESCRIPTION, V::Static("The perfect present: a gift card delivered in a gift box, valid for three years."))
            .set(products::STATUS, "active")
            .set(products::IS_VISIBLE, true)
            .set(products::PUBLISHED_AT, V::Ts(created))
            .set(products::CREATED_AT, V::Ts(created))
            .set(products::UPDATED_AT, V::Ts(created));
        let prid = self.chunk.emit(products::T, day, r);
        let mut variants = Vec::new();
        for (i, eur) in [25.0, 50.0, 100.0].iter().enumerate() {
            let amount = ((eur * self.price_level / 5.0).round() * 5.0 * 100.0) as i64;
            let sku = format!("{}-GC-{}", self.sku_prefix, amount / 100);
            let vname = format!("{} {}", amount / 100, self.m.currency);
            let mut r = Row::new(product_variants::NCOLS);
            r.set(product_variants::PUBLIC_ID, V::Uuid(rng.uuid()))
                .set(product_variants::TENANT_ID, tenant)
                .set(product_variants::PRODUCT_ID, prid)
                .set(product_variants::SKU, sku.clone())
                .set(product_variants::NAME, vname.clone())
                .set(product_variants::SORT_POSITION, i)
                .set(product_variants::PRICE_AMOUNT, V::Money(amount))
                .set(product_variants::CURRENCY_CODE, self.m.currency.clone())
                .set(product_variants::WEIGHT_GRAMS, V::Int(60))
                .set(product_variants::IS_DEFAULT, i == 1)
                .set(product_variants::IS_ACTIVE, true)
                .set(product_variants::CREATED_AT, V::Ts(created))
                .set(product_variants::UPDATED_AT, V::Ts(created));
            let vrid = self.chunk.emit(product_variants::T, day, r);
            variants.push(Variant { rid: vrid, sku, name: format!("{name} - {vname}"), price_cents: amount, weight_g: 60 });
        }
        self.products.push(Product {
            rid: prid,
            public_id,
            name,
            slug: "gift-card".into(),
            ty: 0,
            launch_day: day,
            archive_day: None,
            appeal: 0.0,
            quality: 0.5,
            price_eur: 50.0,
            price_rel: 0.0,
            fit_bias: 0.0,
            fit_uncert: 0.0,
            fragility: 0.1,
            season: 0,
            related: Vec::new(),
            price_steps: Vec::new(),
            variants,
            sizes: 0,
            voucher: true,
            sloppy: false,
        });
        let pidx = self.products.len() - 1;
        self.emit_prices(day, created, pidx);
        self.gift_card = Some(pidx);
    }
}

/// Short unique SKU codes for the values of one variant axis ("Light Medium" -> "LIGHTM").
fn axis_codes(vals: &[String]) -> Vec<String> {
    let full: Vec<String> = vals.iter().map(|v| people::ascii_fold(v).replace(' ', "").to_uppercase()).collect();
    for len in [4, 6, 8, 12] {
        let c: Vec<String> = full.iter().map(|f| f.chars().take(len).collect()).collect();
        let uniq: BTreeSet<&String> = c.iter().collect();
        if uniq.len() == c.len() {
            return c;
        }
    }
    full.iter().enumerate().map(|(i, f)| format!("{}{i}", f.chars().take(6).collect::<String>())).collect()
}

/// How easily a product type breaks in transit (1 = average parcel).
fn fragility(kind: &str) -> f64 {
    const FRAGILE: &[&str] = &["Glassware", "Vase", "Plate", "Monitor", "Laptop", "Tablet", "Smartphone", "Table Lamp", "Casserole", "Candle", "Eau de Parfum", "Robot Vacuum"];
    if FRAGILE.iter().any(|f| kind.contains(f)) { 2.5 } else { 1.0 }
}

impl MerchantSim {
    /// Free-shipping threshold (gross, cents) in the merchant's currency.
    pub fn free_shipping_threshold(&self) -> i64 {
        (if self.b2b { 150.0 } else { 50.0 } * self.price_level * 100.0).round() as i64
    }

    /// Shipping fee charged to the shopper (cents) by zone: domestic, near (EU etc.), far.
    pub fn shipping_fee(&self, zone: u8) -> i64 {
        ([4.95, 9.95, 19.95][zone as usize] * self.price_level * 100.0).round() as i64
    }
}

fn job_title(role: &str) -> &'static str {
    match role {
        "owner" => "Founder & CEO",
        "admin" => "E-commerce Manager",
        "support" => "Customer Service Agent",
        "warehouse" => "Warehouse Lead",
        "marketing" => "Marketing Manager",
        "merchandiser" => "Merchandiser",
        "finance" => "Finance Manager",
        _ => "Account Manager",
    }
}

/// An `addresses` row; shared by merchant and shopper code.
#[allow(clippy::too_many_arguments)]
pub fn emit_address(c: &mut Chunk, tenant: Rid, day: Day, created: Ts, user: Option<Rid>, a: &people::Address, refs: &Refs, label: &str, default: bool) -> Rid {
    let mut r = Row::new(addresses::NCOLS);
    r.set(addresses::TENANT_ID, tenant)
        .set(addresses::USER_ID, V::opt_ref(user))
        .set(addresses::LABEL, label.to_string())
        .set(addresses::LINE1, a.line1.clone())
        .set(addresses::LINE2, a.line2.clone())
        .set(addresses::CITY, a.city_name.clone())
        .set(addresses::REGION_ID, refs.regions[a.country][a.region])
        .set(addresses::COUNTRY_ID, refs.country[a.country])
        .set(addresses::POSTAL_CODE, a.postal.clone())
        .set(addresses::LATITUDE, if a.geocoded { V::Dec((a.lat * 1e6).round() as i128, 6) } else { V::Null })
        .set(addresses::LONGITUDE, if a.geocoded { V::Dec((a.lon * 1e6).round() as i128, 6) } else { V::Null })
        .set(addresses::IS_DEFAULT, default)
        .set(addresses::CREATED_AT, V::Ts(created))
        .set(addresses::UPDATED_AT, V::Ts(created));
    c.emit(addresses::T, day, r)
}
