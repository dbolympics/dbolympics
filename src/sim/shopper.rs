//! Shopper-level processes for one shopper chunk of one merchant: identities, visits and web
//! analytics, carts, orders, payments, fulfillment and shipping.

use std::collections::HashSet;

use crate::engine::{Chunk, DHandle};
use crate::rng::{Rng, Weighted, format_uuid};
use crate::sim::Params;
use crate::sim::calendar;
use crate::sim::merchant::{Captured, DayOut, MerchantSim, StockOp, emit_address, gateway_fee};
use crate::sim::people::{self, Device};
use crate::sim::reference::Refs;
use crate::tables::*;
use crate::time::{self, Day, MICROS_PER_DAY, MICROS_PER_HOUR, MICROS_PER_MIN, MICROS_PER_SEC, Ts};
use crate::value::{Rid, Row, V};
use crate::world::world;

mod journey;
mod analytics;
mod b2b;
mod fraud;
mod gifts;
mod incidents;
mod identity;
mod marketing;
mod subscriptions;
use journey::{Channel, Intent, Prefs, Visitor};
use b2b::{B2b, Buyer};
pub use b2b::{company_domain, company_name, company_slug};
use identity::Ident;
use marketing::{Click, Mkt};
use subscriptions::{Sub, SubEv};

const EU: &[&str] = &["AT", "BE", "BG", "HR", "CY", "CZ", "DK", "EE", "FI", "FR", "DE", "GR", "HU", "IE", "IT", "LV", "LT", "LU", "MT", "NL", "PL", "PT", "RO", "SK", "SI", "ES", "SE"];

pub fn is_eu(iso2: &str) -> bool {
    EU.contains(&iso2)
}

/// Purchases per active year, by vertical (before the per-shopper activity multiplier).
fn purchases_per_year(vertical: &str) -> f64 {
    match vertical {
        "apparel_footwear" => 2.2,
        "consumer_electronics" => 0.9,
        "beauty" => 2.8,
        "home_living" => 1.3,
        "sports_outdoor" => 1.4,
        "food_coffee" => 5.0,
        "pet_supplies" => 5.5,
        "b2b_industrial" | "b2b_office" => 10.0,
        "books_stationery" => 2.2,
        "jewelry_accessories" => 0.8,
        _ => 1.5,
    }
}

const VISITS_PER_PURCHASE: f64 = 10.0;

/// Products that get used up and rebought on a cycle.
fn consumable(vertical: &str) -> bool {
    matches!(vertical, "food_coffee" | "pet_supplies")
}

/// Share of visits made on a phone, by local hour (commute, lunch and evenings are mobile).
fn mobile_share(hour: i64, weekend: bool, b2b: bool) -> f64 {
    let base = match hour {
        0..=6 => 0.6,
        7..=8 => 0.7,
        9..=11 => 0.35,
        12..=13 => 0.6,
        14..=16 => 0.35,
        17..=18 => 0.6,
        _ => 0.72,
    };
    let s: f64 = base + if weekend { 0.15 } else { 0.0 };
    if b2b { (s * 0.4).min(0.4) } else { s.min(0.92) }
}

/// Probability that a purchase in this season is a gift.
fn gift_share(vertical: &str, day: Day) -> f64 {
    use chrono::Datelike;
    let d = time::date_of(day);
    let xmas = (d.month() == 11 && d.day() >= 15) || (d.month() == 12 && d.day() <= 22);
    let valentine = d.month() == 2 && d.day() <= 13;
    match vertical {
        "jewelry_accessories" => if xmas { 0.45 } else if valentine { 0.4 } else { 0.05 },
        "beauty" => if xmas { 0.35 } else if valentine { 0.25 } else { 0.03 },
        "consumer_electronics" | "books_stationery" | "home_living" => if xmas { 0.3 } else { 0.03 },
        "apparel_footwear" | "sports_outdoor" | "food_coffee" => if xmas { 0.2 } else { 0.02 },
        _ => 0.0,
    }
}
/// upper bound of the daily demand multiplier (Black Friday is ~3.6)
const DEMAND_MAX: f64 = 6.0;

struct Shopper {
    user: DHandle,
    rid: Rid,
    email: String,
    country: usize,
    region: usize,
    address: Rid,
    device: Device,
    ua: &'static str,
    ip: String,
    anon_id: u128,
    consent: bool,
    payment_method: Option<(Rid, &'static str, String)>,
    /// visits per day while active
    visit_rate: f64,
    satisfaction: f64,
    churn_day: Day,
    last_seen: Ts,
    reviewed: Vec<Rid>,
    prefs: Prefs,
    channel: Channel,
    /// second device (cross-device shopping): its own anonymous id and user agent
    device2: Device,
    ua2: &'static str,
    anon2: u128,
    open_cart: Option<OpenCart>,
    /// consumables: day the last purchase runs out, how long a unit lasts, what they buy
    need_day: Option<Day>,
    cycle_days: f64,
    orders: u32,
    last_basket: Vec<(usize, i64)>,
    city: String,
    postal: Option<String>,
    phone: Option<String>,
    created: Ts,
    first_name: String,
    mkt: Mkt,
    /// active subscription (index into `ShopperChunk::subs`)
    sub: Option<u32>,
    ident: Ident,
    last_name: String,
    b2b: Option<Buyer>,
    /// experiment variants: (experiment, variant)
    exps: Vec<(u8, u8)>,
    /// store credit
    wallet: Option<(DHandle, i64)>,
    /// gift cards received (indices into `ShopperChunk::cards`)
    cards: Vec<u32>,
    /// S7 influencer audience, S8 fraud-ring account, S10 app user
    influencer: bool,
    fraud: bool,
    app: bool,
    /// a subscription of this shopper ended then
    sub_ended: Option<Ts>,
    /// S14: a duplicate account from the re-import
    alias: Option<incidents::Alias>,
    /// storefront features used today
    feat: Option<(Day, Vec<(&'static str, i64, Ts)>)>,
}

/// Why a visit is planned. Only regular visits schedule the next regular visit, so each shopper
/// has exactly one chain of regular visits.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Visit {
    Regular,
    /// a consumable runs out
    Need,
    /// back for a cart left earlier
    Cart,
    /// clicked a marketing email (key into `ShopperChunk::clicks`)
    Click(u32),
    /// comes to spend a gift card
    Gift(u32),
}

/// A cart left in a session that the shopper comes back to buy on `return_day`.
struct OpenCart {
    items: Vec<Item>,
    token: String,
    created: Ts,
    return_day: Day,
}

/// A visitor who browses anonymously before signing up.
struct Prospect {
    ns: crate::sim::merchant::NewShopper,
    anon: u128,
    device: Device,
    ua: &'static str,
    ip: String,
    consent: bool,
    prefs: Prefs,
    channel: Channel,
}

pub struct ShopperChunk {
    pub merchant: usize,
    pub local: usize,
    pub chunk: Chunk,
    seed: u64,
    shoppers: Vec<Shopper>,
    /// planned visits per day: (shopper, kind)
    calendar: Vec<Vec<(u32, Visit)>>,
    prospects: Vec<Option<Prospect>>,
    /// per day: (prospect, visit time, is the signup visit)
    prospect_calendar: Vec<Vec<(u32, Ts, bool)>>,
    emails: HashSet<String>,
    /// captures (and refunds, negative) by day, read by the merchant the next day for payouts
    pub outbox: std::collections::BTreeMap<Day, DayOut>,
    /// today's congestion of each carrier network (extra days)
    carrier_delay: Vec<f64>,
    clicks: std::collections::BTreeMap<u32, Click>,
    next_click: u32,
    /// loyalty points to credit per day: (shopper, points, order)
    loyalty_queue: std::collections::BTreeMap<Day, Vec<(u32, i64, Rid)>>,
    /// referral codes created in this chunk
    codes: u32,
    subs: Vec<Sub>,
    /// subscription renewals and deliveries per day: (subscription, event, time)
    sub_queue: std::collections::BTreeMap<Day, Vec<(u32, SubEv, Ts)>>,
    b2b: B2b,
    cards: Vec<gifts::Card>,
    ring: Option<fraud::Ring>,
    s16_victims: Vec<u32>,
    /// the order being placed is a present
    gift_order: bool,
}

#[derive(Clone)]
struct Item {
    /// (number of sizes, chosen size) for size-run products
    size: Option<(usize, usize)>,
    /// index into the merchant's products, and the variant within the product
    pidx: usize,
    vidx: usize,
    product: Rid,
    product_name: String,
    variant: Rid,
    sku: String,
    name: String,
    qty: i64,
    unit_gross: i64,
    weight_g: i64,
}

fn gateway_prefix(g: &str) -> &'static str {
    match g {
        "Halyard Pay" => "hp_",
        "Pennaro" => "pn_",
        "Bluestem Pay" => "bs_",
        "Pursely" => "pu_",
        "Moravell" => "mv_",
        _ => "ch_",
    }
}

pub(crate) fn json_str(s: &str) -> String {
    let mut o = String::with_capacity(s.len() + 2);
    o.push('"');
    for c in s.chars() {
        match c {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

fn money_str(cents: i64) -> String {
    format!("{}.{:02}", cents / 100, (cents % 100).abs())
}

impl ShopperChunk {
    pub fn new(merchant: usize, local: usize, chunk_id: u32, seed: u64) -> ShopperChunk {
        ShopperChunk {
            merchant,
            local,
            chunk: Chunk::new(chunk_id),
            seed: seed ^ ((merchant as u64) << 32 | local as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15),
            shoppers: Vec::new(),
            calendar: (0..time::num_days()).map(|_| Vec::new()).collect(),
            prospects: Vec::new(),
            prospect_calendar: (0..time::num_days()).map(|_| Vec::new()).collect(),
            emails: HashSet::new(),
            outbox: std::collections::BTreeMap::new(),
            carrier_delay: Vec::new(),
            clicks: Default::default(),
            next_click: 0,
            loyalty_queue: Default::default(),
            codes: 0,
            subs: Vec::new(),
            sub_queue: Default::default(),
            b2b: Default::default(),
            cards: Vec::new(),
            ring: None,
            s16_victims: Vec::new(),
            gift_order: false,
        }
    }

    fn emit_at(&mut self, t: crate::schema::TableId, ts: Ts, row: Row) -> Option<Rid> {
        if ts > time::end_ts() {
            return None;
        }
        let day = (time::day_of_ts(ts).max(self.chunk.day as i64)) as Day;
        Some(self.chunk.emit(t, day, row))
    }

    pub fn day(&mut self, day: Day, ms: &MerchantSim, p: &Params, refs: &Refs, carrier_delay: &[f64]) {
        self.carrier_delay = carrier_delay.to_vec();
        self.chunk.day = day;
        // yesterday's entries were consumed by the merchant phase of today
        self.outbox = self.outbox.split_off(&day);
        if !ms.is_active(day) {
            return;
        }
        let mut rng = Rng::new(self.seed, &[3, day as u64]);
        let tenant = ms.tenant_rid();
        let mut mrng = Rng::new(self.seed, &[6, day as u64]);
        self.loyalty_day(&mut mrng, ms, day);
        let mut srng = Rng::new(self.seed, &[7, day as u64]);
        self.subscriptions_day(&mut srng, ms, p, day);
        self.b2b_day(&mut srng, ms, day);
        self.month_kpi(ms, day);
        if crate::sim::stories::s8_crackdown(ms.m, day) {
            self.s8_crackdown(&mut mrng, ms, day);
        }
        if crate::sim::stories::s14_import(ms.m, day) {
            self.s14_reimport(&mut mrng, ms, refs, day);
        }
        if crate::sim::stories::s16_attack(ms.m, day) {
            self.s16_attack(&mut mrng, ms, refs, day);
        }
        if crate::sim::stories::s16_response(ms.m, day) {
            self.s16_resets(&mut mrng, ms, day);
        }
        // 1) new arrivals: migrated shoppers are created directly; others start as prospects
        let news = &ms.new_shoppers[self.local];
        for ns in news {
            let mut r = Rng::new(ns.seed, &[4]);
            if ns.migrated {
                let pr = self.new_prospect(&mut r, ms, ns);
                let idx = self.create_shopper(&mut r, ms, refs, tenant, pr);
                self.schedule(&mut r, ms, idx, day, p);
                if ms.subs.is_some() && r.chance(if consumable(&ms.m.vertical) { 0.15 } else { 0.07 }) {
                    self.migrated_subscription(&mut r, ms, idx, ns.created);
                }
                continue;
            }
            let pr = self.new_prospect(&mut r, ms, ns);
            let pidx = self.prospects.len() as u32;
            // anonymous visits between first sight and sign-up, then the sign-up visit
            let span = ns.created - ns.first_seen;
            let mut visits = vec![ns.first_seen];
            if span > 0 {
                for _ in 0..r.poisson((span as f64 / MICROS_PER_DAY as f64 / 4.0).min(6.0)) {
                    visits.push(ns.first_seen + r.int(0, span));
                }
            }
            visits.sort();
            for t in visits.iter().filter(|t| **t < ns.created) {
                let d = time::day_of_ts(*t).max(day as i64) as usize;
                if d < self.prospect_calendar.len() {
                    self.prospect_calendar[d].push((pidx, *t, false));
                }
            }
            let d = time::day_of_ts(ns.created).max(day as i64) as usize;
            if d < self.prospect_calendar.len() && ns.created <= time::end_ts() {
                self.prospect_calendar[d].push((pidx, ns.created, true));
            }
            self.prospects.push(Some(pr));
        }
        // 2) prospects: anonymous browsing, or the sign-up visit (becomes a shopper)
        for (pidx, t, signup) in std::mem::take(&mut self.prospect_calendar[day as usize]) {
            let pidx = pidx as usize;
            if !signup {
                let (v, prefs) = {
                    let Some(pr) = &self.prospects[pidx] else { continue };
                    let tracked = pr.consent && rng.chance(p.anon_sample_rate);
                    let campaign = if pr.ns.influencer && t == pr.ns.first_seen { ms.mkt.influencer.as_ref().map(|c| c.1.clone()) } else { None };
                    (Visitor { user: None, anon: pr.anon, device: pr.device, ua: pr.ua, ip: pr.ip.clone(), channel: if t == pr.ns.first_seen { pr.channel.settle(ms) } else { Channel::returning(&mut rng, pr.channel, ms).settle(ms) }, tracked, sample_rate: Some(p.anon_sample_rate), campaign, landing: None, exp: None, app: false }, pr.prefs.clone())
                };
                let intent = if rng.chance(0.6) { Intent::Research } else { Intent::Browse };
                let j = self.journey(&mut rng, ms, &v, &prefs, intent, t, None);
                if !j.items.is_empty() {
                    self.emit_cart(&mut rng, ms, tenant, None, &j.cart_token, &j.items, j.first_add, None);
                }
                continue;
            }
            let Some(pr) = self.prospects[pidx].take() else { continue };
            let mut r = Rng::new(pr.ns.seed, &[5]);
            let buys = pr.ns.buys;
            let idx = self.create_shopper(&mut r, ms, refs, tenant, pr);
            self.visit(&mut r, ms, p, refs, idx, t, true, buys, false, None);
            self.schedule(&mut r, ms, idx, day, p);
        }
        // marketing emails (clicks today join today's visits)
        self.sends(&mut mrng, ms, day);
        // 3) returning shoppers with a visit planned today
        let today = std::mem::take(&mut self.calendar[day as usize]);
        let demand = calendar::demand(&ms.m.vertical, ms.vertical, ms.b2b, day) * ms.promo_boost(day);
        let hours = Weighted::new(calendar::hourly(ms.b2b));
        for (s, kind) in today {
            let s = s as usize;
            if let Visit::Gift(k) = kind {
                if day < self.shoppers[s].churn_day || rng.chance(0.5) {
                    let h = hours.sample(&mut rng) as i64;
                    let ts = ms.tz.local_to_utc(time::date_of(day), h * MICROS_PER_HOUR + rng.int(0, 3_599_999_999));
                    self.visit(&mut rng, ms, p, refs, s, ts, false, true, false, None);
                }
                self.retry_card(&mut rng, s, k as usize);
                continue;
            }
            if let Visit::Click(k) = kind {
                let Some(c) = self.clicks.remove(&k) else { continue };
                let sat = self.shoppers[s].satisfaction;
                let buys = rng.chance((if c.promo { 0.25 } else { 0.10 } * sat).min(0.9));
                self.visit(&mut rng, ms, p, refs, s, c.at, false, buys, false, Some(&c));
                continue;
            }
            let back_for_cart = kind == Visit::Cart && self.shoppers[s].open_cart.as_ref().is_some_and(|c| c.return_day == day);
            let need = kind == Visit::Need && self.shoppers[s].need_day == Some(day);
            if kind != Visit::Regular && !back_for_cart && !need {
                continue; // stale plan (e.g. replaced by a later purchase)
            }
            if need {
                self.shoppers[s].need_day = None;
            }
            // visits are scheduled at DEMAND_MAX times the base rate and thinned by today's demand
            if back_for_cart || need || rng.chance((demand / DEMAND_MAX).min(1.0)) {
                let h = hours.sample(&mut rng) as i64;
                let ts = ms.tz.local_to_utc(time::date_of(day), h * MICROS_PER_HOUR + rng.int(0, 3_599_999_999));
                // sale days also convert better; a buy-intent visit ends in an order ~75% of the time;
                // consumables are mostly bought when they run out
                let base = if consumable(&ms.m.vertical) { 0.35 } else { 1.0 };
                let buy_p = base * 1.35 / VISITS_PER_PURCHASE * self.shoppers[s].satisfaction * libm::pow(demand, 0.35);
                let buys = back_for_cart || (need && rng.chance((0.82 * self.shoppers[s].satisfaction).min(0.95))) || rng.chance(buy_p.min(0.9));
                self.visit(&mut rng, ms, p, refs, s, ts, false, buys, need, None);
            }
            if kind == Visit::Regular {
                self.schedule(&mut rng, ms, s, day, p);
            }
        }
        // 4) anonymous visitors: sampled sessions are stored; unsampled ones only leave carts
        let k = ms.shopper_chunks as f64;
        let n_anon = rng.poisson(ms.anon_sessions_today / k);
        for _ in 0..n_anon {
            let h = hours.sample(&mut rng) as i64;
            let ts = ms.tz.local_to_utc(time::date_of(day), h * MICROS_PER_HOUR + rng.int(0, 3_599_999_999));
            self.anon_visit(&mut rng, ms, p, ts, true);
        }
        let total_anon = ms.anon_sessions_today / k / (0.6 * p.anon_sample_rate);
        let n_unsampled_carts = rng.poisson((total_anon - ms.anon_sessions_today / k) * 0.05);
        for _ in 0..n_unsampled_carts {
            let h = hours.sample(&mut rng) as i64;
            let ts = ms.tz.local_to_utc(time::date_of(day), h * MICROS_PER_HOUR + rng.int(0, 3_599_999_999));
            self.anon_visit(&mut rng, ms, p, ts, false);
        }
        self.cohort_members(ms, day);
        if day + 1 == time::num_days() {
            for s in 0..self.shoppers.len() {
                self.flush_features(ms, s);
            }
            self.segment_members(ms, day);
            self.flush_sessions(ms);
            self.finish_cards();
            self.finish_erasures();
        }
    }

    fn new_prospect(&self, rng: &mut Rng, ms: &MerchantSim, ns: &crate::sim::merchant::NewShopper) -> Prospect {
        let w = world();
        let c = &w.geo.countries[ns.country];
        let device = people::device(rng, if ms.b2b { 0.25 } else { 0.62 });
        Prospect {
            ns: ns.clone(),
            anon: rng.uuid(),
            device,
            ua: people::user_agent(rng, device),
            ip: people::ip(rng),
            consent: rng.chance(if is_eu(&c.iso2) || c.iso2 == "GB" { 0.55 } else { 0.85 }),
            prefs: {
                let mut p = Prefs::new(rng, ms.product_types.len(), ns.country);
                if ns.influencer {
                    // bought for the coupon: buys several sizes, returns most of it
                    p.bracket = 4.0;
                }
                p
            },
            channel: if ns.influencer { Channel::Social } else { Channel::acquisition(rng, &ms.mkt.acq_mix).settle(ms) },
        }
    }

    fn schedule(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, day: Day, _p: &Params) {
        let sh = &self.shoppers[s];
        let gap = rng.exp(1.0 / (sh.visit_rate * DEMAND_MAX)).max(0.2);
        let next = day as f64 + gap.ceil();
        if next < sh.churn_day as f64 && next < time::num_days() as f64 {
            let _ = ms;
            self.calendar[next as usize].push((s as u32, Visit::Regular));
        }
    }

    fn create_shopper(&mut self, rng: &mut Rng, ms: &MerchantSim, refs: &Refs, tenant: Rid, pr: Prospect) -> usize {
        let w = world();
        let mut pr = pr;
        let mut ring_addr = None;
        if pr.ns.fraud {
            // S8: the ring reuses addresses, devices and IP addresses
            let ring = self.ring(rng, ms);
            let d = &ring.devices[rng.below(ring.devices.len())];
            (pr.anon, pr.device, pr.ua) = (d.0, d.1, d.2);
            pr.ip = ring.ips[rng.below(ring.ips.len())].clone();
            pr.consent = true;
            pr.prefs.budget *= 3.0;
            ring_addr = Some(ring.addresses[rng.below(ring.addresses.len())].clone());
        }
        let ns = &pr.ns;
        let day = self.chunk.day;
        let c = &w.geo.countries[ns.country];
        // unique email within the tenant: all name/domain collisions are routed to this chunk
        let mut n = 0;
        let mut email;
        loop {
            email = if n == 0 { format!("{}@{}", ns.email_base, ns.domain) } else { format!("{}{n}@{}", ns.email_base, ns.domain) };
            if self.emails.insert(email.clone()) {
                break;
            }
            n = if n == 0 { rng.int(1, 99) as u32 } else { n * 10 + rng.below(10) as u32 };
        }
        let created = ns.created;
        let first_seen = ns.first_seen;
        if !ns.migrated {
            self.outbox.entry(day).or_default().signups += 1;
        }
        let oauth: Option<&'static str> = if rng.chance(0.12) { Some(if rng.chance(0.65) { "google" } else { "apple" }) } else { None };
        // imported customers: older systems knew less (no locale, time zone or coordinates)
        let imported = ns.migrated;
        let mut u = Row::new(users::NCOLS);
        u.set(users::PUBLIC_ID, V::Uuid(rng.uuid()))
            .set(users::TENANT_ID, tenant)
            .set(users::EMAIL, email.clone())
            .set(users::FULL_NAME, people::dirty_name(rng, &format!("{} {}", ns.person.first, ns.person.last), ms.mess * if imported { 2.0 } else { 1.0 }))
            .set(users::STATUS, "active")
            .set(users::IS_STAFF, false)
            .set(users::LOCALE, if rng.chance(if imported { 0.2 } else { 0.7 }) { V::Str(ms.m.locale.clone()) } else { V::Null })
            .set(users::TIMEZONE, if !imported && rng.chance(0.4) { V::Str(c.timezone.clone()) } else { V::Null })
            .set(users::PASSWORD_HASH, if oauth.is_none() && rng.chance(0.9) { V::Str(people::password_hash(rng)) } else { V::Null })
            .set(users::LAST_LOGIN_AT, V::Ts(created))
            .set(users::CREATED_AT, V::Ts(created))
            .set(users::UPDATED_AT, V::Ts(created));
        let uh = self.chunk.emit_deferred(users::T, day, u);
        let mut a = ring_addr.unwrap_or_else(|| people::address(rng, ns.country));
        people::dirty_address(rng, &mut a, ms.mess * if imported { 2.0 } else { 1.0 });
        if imported && rng.chance(0.7) {
            a.geocoded = false;
        }
        let addr = emit_address(&mut self.chunk, tenant, day, created, Some(uh.rid), &a, refs, "Home", true);
        let phone = if rng.chance(if imported { 0.15 } else { 0.25 }) { Some(people::phone(rng, &c.iso2)) } else { None };
        let phone = phone.map(|ph| if rng.chance(ms.mess * 2.0) { people::phone_variant(rng, &ph, &c.phone_code) } else { ph });
        if phone.is_some() || rng.chance(0.1) {
            let mut pr = Row::new(user_profiles::NCOLS);
            pr.set(user_profiles::TENANT_ID, tenant)
                .set(user_profiles::USER_ID, uh.rid)
                .set(user_profiles::PHONE, phone.clone())
                .set(user_profiles::CREATED_AT, V::Ts(created))
                .set(user_profiles::UPDATED_AT, V::Ts(created));
            self.chunk.emit(user_profiles::T, day, pr);
        }
        let device = pr.device;
        let device2 = if device == Device::Mobile { Device::Desktop } else { Device::Mobile };
        // power-law activity: a few very loyal customers, a long tail of one-time buyers
        let activity = rng.lognormal(-0.35, 0.9) * if ns.influencer { 0.35 } else if ns.fraud { 0.05 } else { 1.0 };
        let rate = purchases_per_year(&ms.m.vertical) * VISITS_PER_PURCHASE / 365.0 * activity;
        let life_years = if ns.fraud { 40.0 / 365.0 } else { rng.exp(if ms.b2b { 4.0 } else { 1.8 }) };
        let created_day = time::day_of_ts(created).max(0) as f64;
        let churn_day = (created_day + life_years * 365.0).min(u32::MAX as f64) as Day;
        let consent = pr.consent;
        self.shoppers.push(Shopper {
            user: uh,
            rid: uh.rid,
            email,
            country: ns.country,
            region: a.region,
            address: addr,
            device,
            ua: pr.ua,
            ip: pr.ip.clone(),
            anon_id: pr.anon,
            consent,
            payment_method: None,
            visit_rate: rate,
            satisfaction: 1.0,
            churn_day,
            last_seen: created,
            reviewed: Vec::new(),
            prefs: pr.prefs.clone(),
            channel: pr.channel,
            device2,
            ua2: people::user_agent(rng, device2),
            anon2: rng.uuid(),
            open_cart: None,
            need_day: None,
            orders: 0,
            cycle_days: rng.lognormal(libm::log(if ms.m.vertical == "pet_supplies" { 30.0 } else { 24.0 }), 0.3),
            last_basket: Vec::new(),
            city: a.city_name.clone(),
            postal: a.postal.clone(),
            phone,
            created,
            first_name: ns.person.first.clone(),
            mkt: Mkt::default(),
            sub: None,
            ident: Ident::default(),
            last_name: ns.person.last.clone(),
            b2b: None,
            exps: Vec::new(),
            wallet: None,
            cards: Vec::new(),
            influencer: ns.influencer,
            fraud: ns.fraud,
            app: false,
            sub_ended: None,
            alias: None,
            feat: None,
        });
        let idx = self.shoppers.len() - 1;
        self.signup_profile(rng, ms, idx, first_seen);
        if oauth.is_some() {
            let mut r = Row::new(oauth_accounts::NCOLS);
            r.set(oauth_accounts::TENANT_ID, tenant).set(oauth_accounts::USER_ID, uh.rid).set(oauth_accounts::PROVIDER, oauth.unwrap()).set(oauth_accounts::PROVIDER_ACCOUNT_ID, if oauth == Some("google") { rng.digits(21) } else { format!("{:06}.{}.{:04}", rng.int(0, 999_999), rng.hex(32), rng.int(0, 9999)) }).set(oauth_accounts::ACCESS_TOKEN_HASH, rng.hex(64)).set(oauth_accounts::CREATED_AT, V::Ts(created));
            self.chunk.emit(oauth_accounts::T, day, r);
            self.shoppers[idx].ident.oauth = oauth;
        }
        self.validate_address(rng, ms, addr, &a, created);
        if let Some(company) = pr.ns.company.clone() {
            self.b2b_signup(rng, ms, idx, &company, first_seen);
        }
        self.plan_privacy(rng, ms, idx);
        idx
    }

    // -----------------------------------------------------------------------------------
    // web analytics
    // -----------------------------------------------------------------------------------

    fn context_json(&self, ms: &MerchantSim, device: Device, path: &str, sampled: Option<f64>) -> String {
        let (dev, os) = match device {
            Device::Desktop => ("desktop", "Windows"),
            Device::Mobile => ("mobile", "iOS"),
            Device::Tablet => ("tablet", "iPadOS"),
        };
        let mut s = format!(
            r#""context":{{"device":{{"type":"{dev}","os":"{os}"}},"locale":"{}","library":{{"name":"tidewick-analytics.js","version":"{}"}},"page":{{"path":{}}}}}"#,
            ms.m.locale,
            crate::sim::stories::sdk_version(self.chunk.day, device != Device::Desktop).0,
            json_str(path)
        );
        if let Some(r) = sampled {
            s.push_str(&format!(r#","sample_rate":{r}"#));
        }
        s
    }

    fn event(&mut self, tenant: Rid, user: Option<Rid>, session: Rid, name: &'static str, props: String, at: Ts) {
        let mut r = Row::new(events::NCOLS);
        r.set(events::TENANT_ID, tenant)
            .set(events::USER_ID, V::opt_ref(user))
            .set(events::WEB_SESSION_ID, session)
            .set(events::EVENT_NAME, name)
            .set(events::PROPERTIES, V::Json(props))
            .set(events::OCCURRED_AT, V::Ts(at))
            .set(events::CREATED_AT, V::Ts(at + 200_000));
        self.chunk.emit(events::T, self.chunk.day, r);
        self.outbox.entry(self.chunk.day).or_default().events += 1;
    }

    /// Anonymous traffic: a sampled, stored session, or (unsampled) only a server-side cart.
    fn anon_visit(&mut self, rng: &mut Rng, ms: &MerchantSim, p: &Params, ts: Ts, sampled: bool) {
        let tenant = ms.tenant_rid();
        let prefs = Prefs::new(rng, ms.product_types.len(), ms.country);
        if !sampled {
            let ty = rng.below(ms.product_types.len());
            if let Some(pi) = ms.product_of_type(rng, ty) {
                let items = vec![self.item_for(rng, ms, pi, &prefs)];
                let token = rng.alnum(32);
                self.emit_cart(rng, ms, tenant, None, &token, &items, ts, None);
            }
            return;
        }
        let local = ms.tz.utc_to_local(ts);
        let weekend = { use chrono::Datelike; time::date_of(time::day_of_ts(local).max(0) as Day).weekday().num_days_from_monday() >= 5 };
        let device = people::device(rng, mobile_share(local.rem_euclid(MICROS_PER_DAY) / MICROS_PER_HOUR, weekend, ms.b2b));
        let anon = rng.uuid();
        let exp = self.experiment(rng, ms, None, anon, ts);
        let v = Visitor { user: None, anon, device, ua: people::user_agent(rng, device), ip: people::ip(rng), channel: Channel::anonymous(rng, &ms.mkt.acq_mix).settle(ms), tracked: true, sample_rate: Some(p.anon_sample_rate), campaign: None, landing: None, exp, app: false };
        let intent = if rng.chance(0.3) { Intent::Research } else { Intent::Browse };
        let j = self.journey(rng, ms, &v, &prefs, intent, ts, None);
        if !j.items.is_empty() {
            self.emit_cart(rng, ms, tenant, None, &j.cart_token, &j.items, j.first_add, None);
        }
    }

    /// A known shopper's visit: a journey, then checkout, a cart left for later, or nothing.
    #[allow(clippy::too_many_arguments)]
    fn visit(&mut self, rng: &mut Rng, ms: &MerchantSim, p: &Params, refs: &Refs, s: usize, ts: Ts, first: bool, buys: bool, need: bool, click: Option<&Click>) {
        let tenant = ms.tenant_rid();
        let day = self.chunk.day;
        let local = ms.tz.utc_to_local(ts);
        let hour = local.rem_euclid(MICROS_PER_DAY) / MICROS_PER_HOUR;
        let weekend = { use chrono::Datelike; time::date_of(time::day_of_ts(local).max(0) as Day).weekday().num_days_from_monday() >= 5 };
        // coming back for a cart left earlier?
        let open = match &self.shoppers[s].open_cart {
            Some(c) if c.return_day == day => self.shoppers[s].open_cart.take(),
            _ => None,
        };
        let (v, other) = {
            let sh = &self.shoppers[s];
            // phone or computer depends on the time of day (commute, office, evening)
            let share = mobile_share(hour, weekend, ms.b2b);
            let p_primary = if sh.device == Device::Mobile { (share + 0.3).min(0.97) } else { (1.3 - share).min(0.97) };
            let other = !first && !rng.chance(p_primary);
            let (device, ua, anon) = if other { (sh.device2, sh.ua2, sh.anon2) } else { (sh.device, sh.ua, sh.anon_id) };
            let channel = if click.is_some() { Channel::Email } else if first { sh.channel.settle(ms) } else { Channel::returning(rng, sh.channel, ms).settle(ms) };
            let tracked = sh.consent && rng.chance(p.anon_sample_rate);
            let campaign = click.map(|c| c.utm.clone()).or(if first && sh.influencer { ms.mkt.influencer.as_ref().map(|c| c.1.clone()) } else { None });
            let landing = click.map(|c| format!("/pages/{}", crate::sim::merchant::LANDING[c.landing].0));
            (Visitor { user: Some(sh.rid), anon, device, ua, ip: sh.ip.clone(), channel, tracked, sample_rate: Some(p.anon_sample_rate), campaign, landing, exp: None, app: false }, other)
        };
        let mut v = v;
        v.exp = self.experiment(rng, ms, Some(s), v.anon, ts);
        // S10: after the app launch, phone users install it and come back more often
        if crate::sim::stories::s10_launch(ms.m).is_some_and(|l| ts >= l) && v.device == Device::Mobile {
            if !self.shoppers[s].app && rng.chance(0.2) {
                self.install_app(rng, ms, s, ts);
            }
            if self.shoppers[s].app {
                v.app = true;
                v.ua = if v.ua.contains("Android") { "CinderPeak/2.1.0 (Android 14; Mobile)" } else { "CinderPeak/2.1.0 (iPhone; iOS 17.5; Scale/3.00)" };
                if rng.chance(0.15) {
                    self.use_feature(ms, s, "app_barcode_scan", ts);
                }
            }
        }
        let mut prefs = self.shoppers[s].prefs.clone();
        // running out: rebuy (mostly) the same products
        let mut preset: Option<Vec<Item>> = open.as_ref().map(|c| c.items.clone());
        if preset.is_none() && need && buys && !self.shoppers[s].last_basket.is_empty() {
            let basket = self.shoppers[s].last_basket.clone();
            let mut items = Vec::new();
            for (pi, q) in basket {
                let live = ms.products[pi].archive_day.is_none_or(|a| a > day);
                let pi = if live && rng.chance(0.85) { Some(pi) } else { ms.product_of_type(rng, ms.products[pi].ty) };
                if let Some(pi) = pi {
                    if !items.iter().any(|it: &Item| it.pidx == pi) {
                        let mut it = self.item_for(rng, ms, pi, &prefs);
                        it.qty = q;
                        if ms.in_stock(it.pidx, it.vidx) {
                            items.push(it);
                        }
                    }
                }
            }
            if !items.is_empty() {
                preset = Some(items);
            }
        }
        // a gift: someone else's size, sometimes shipped to them
        let s18 = crate::sim::stories::s18_gift_season(ms.m, day);
        let gift = buys && preset.is_none() && rng.chance((gift_share(&ms.m.vertical, day) * if s18 { 2.0 } else { 1.0 }).min(0.8));
        if gift {
            prefs.size_pos = rng.f64();
            if rng.chance(if s18 { 0.4 } else { 0.2 }) {
                preset = self.gift_card_item(rng, ms).map(|it| vec![it]);
            }
        }
        let intent = if buys { Intent::Buy } else if rng.chance(0.35) { Intent::Research } else { Intent::Browse };
        let j = self.journey(rng, ms, &v, &prefs, intent, ts, preset.as_deref());
        let login = self.touch_session(rng, ms, s, other as usize, ts, j.end);
        for (feature, p_use) in [("wishlist", 0.04), ("size_guide", if ms.m.vertical == "apparel_footwear" { 0.15 } else { 0.0 }), ("product_compare", if ms.m.vertical == "consumer_electronics" { 0.08 } else { 0.0 }), ("quick_reorder", if need { 0.6 } else { 0.0 }), ("saved_cart", if open.is_some() { 0.5 } else { 0.0 }), ("order_tracking", 0.03)] {
            if p_use > 0.0 && rng.chance(p_use) {
                self.use_feature(ms, s, feature, j.end);
            }
        }
        if let Some(sid) = j.session {
            let path = if first { "/account/register" } else { "/account/login" };
            let ctx = self.context_json(ms, v.device, path, Some(p.anon_sample_rate));
            if first {
                let tpl = ms.templates.as_ref().unwrap().welcome;
                self.email(rng, ms, s, tpl, format!("Welcome to {}", ms.m.name), "hello", ts + 60 * MICROS_PER_SEC);
                self.event(tenant, v.user, sid, "signup", format!(r#"{{"method":"email","newsletter":{},"anonymous_id":"{}",{ctx}}}"#, self.shoppers[s].mkt.opt_in, format_uuid(v.anon)), ts + 50 * MICROS_PER_SEC);
            } else if let Some(method) = login {
                self.event(tenant, v.user, sid, "login", format!(r#"{{"method":"{method}",{ctx}}}"#), ts + 5 * MICROS_PER_SEC);
            }
        } else if first {
            let tpl = ms.templates.as_ref().unwrap().welcome;
            self.email(rng, ms, s, tpl, format!("Welcome to {}", ms.m.name), "hello", ts + 60 * MICROS_PER_SEC);
        }
        let end = j.end;
        self.touch_device(rng, ms, s, other as usize, ts, end);
        if let Some(c) = click {
            self.shoppers[s].mkt.last_click = Some((c.campaign, c.at, c.ab));
            self.outbox.entry(day).or_default().landing_views.push(c.landing);
        }
        {
            let sh = &mut self.shoppers[s];
            sh.last_seen = sh.last_seen.max(end);
            let (last, h) = (sh.last_seen, sh.user);
            self.chunk.deferred_mut(h).set(users::LAST_LOGIN_AT, V::Ts(last)).set(users::UPDATED_AT, V::Ts(last));
        }
        let user = Some(self.shoppers[s].rid);
        let (token, created) = match &open {
            Some(c) => (c.token.clone(), c.created),
            None => (j.cart_token.clone(), j.first_add),
        };
        let subscribe = j.checkout && ms.subs.is_some() && self.shoppers[s].sub.is_none() && rng.chance(if click.is_some_and(|c| c.winback) { 0.5 } else if need { 0.3 } else if consumable(&ms.m.vertical) { 0.12 } else { 0.06 });
        if subscribe {
            self.emit_cart(rng, ms, tenant, user, &token, &j.items, created, Some(end));
            self.start_subscription(rng, ms, p, s, end, &j.items);
        } else if j.checkout {
            let cart = self.emit_cart(rng, ms, tenant, user, &token, &j.items, created, Some(end));
            let ship_to = if gift && rng.chance(0.4) {
                let country = self.shoppers[s].country;
                let a = people::address(rng, country);
                let rid = emit_address(&mut self.chunk, tenant, day, end, user, &a, refs, "Gift", false);
                self.validate_address(rng, ms, rid, &a, end);
                Some((rid, country, a.region))
            } else {
                None
            };
            let mut items = j.items;
            // S18: the gift guide's bundles and recommendations fill gift baskets
            if gift && crate::sim::stories::s18_gift_season(ms.m, day) {
                for _ in 0..1 + rng.below(2) {
                    let ty = items.first().map(|it| ms.products[it.pidx].ty).unwrap_or(0);
                    let comps = &ms.complements[ty];
                    let t2 = if comps.is_empty() { rng.below(ms.product_types.len()) } else { comps[rng.below(comps.len())] };
                    if let Some(pi) = ms.product_of_type(rng, t2) {
                        let it = self.item_for(rng, ms, pi, &prefs);
                        if ms.in_stock(pi, it.vidx) && !items.iter().any(|x| x.pidx == pi) {
                            items.push(it);
                        }
                    }
                }
            }
            self.gift_order = gift;
            self.order(rng, ms, p, s, j.session, end, items, cart, token, v.device, ship_to, v.channel, None);
            self.gift_order = false;
        } else if !j.items.is_empty() {
            // some come back within a week to buy the cart; the rest abandon it
            let back = 1 + rng.below(7) as Day;
            let return_day = day + back;
            let ok = rng.chance(0.3) && (return_day as usize) < self.calendar.len() && ms.is_active(return_day) && return_day < self.shoppers[s].churn_day;
            if ok && open.is_none() {
                self.shoppers[s].open_cart = Some(OpenCart { items: j.items, token, created, return_day });
                self.calendar[return_day as usize].push((s as u32, Visit::Cart));
            } else {
                self.emit_cart(rng, ms, tenant, user, &token, &j.items, created, None);
            }
        } else if j.oos > 0 && intent == Intent::Buy && rng.chance(0.05) {
            self.ticket(rng, ms, s, Cause::OutOfStock, end);
        } else if rng.chance(0.004) {
            self.ticket(rng, ms, s, Cause::ProductQuestion, end);
        } else if intent == Intent::Research && rng.chance(0.003) {
            let cat = if rng.chance(0.5) { 0 } else { 4 };
            self.article_feedback(rng, ms, s, cat, true, end);
        } else if intent == Intent::Research && rng.chance(0.01) {
            let ty = self.shoppers[s].prefs.pick_type(rng, ms.product_types.len());
            if let Some(pi) = ms.product_of_type(rng, ty) {
                let name = ms.products[pi].name.clone();
                let at = end - rng.int(10, 120) * MICROS_PER_SEC;
                self.message_thread(rng, ms, s, at, &name);
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn emit_cart(&mut self, rng: &mut Rng, ms: &MerchantSim, tenant: Rid, user: Option<Rid>, token: &str, items: &[Item], at: Ts, converted: Option<Ts>) -> Option<Rid> {
        let created = at - rng.int(1, 600) * MICROS_PER_SEC;
        let subtotal: i64 = items.iter().map(|i| i.unit_gross * i.qty).sum();
        let qty: i64 = items.iter().map(|i| i.qty).sum();
        let end = time::end_ts();
        let (status, abandoned) = match converted {
            Some(_) => ("converted", None),
            None if created + 3 * MICROS_PER_DAY > end => ("active", None),
            None => ("abandoned", Some(created + rng.int(1, 48) * MICROS_PER_HOUR)),
        };
        let mut r = Row::new(carts::NCOLS);
        r.set(carts::TENANT_ID, tenant)
            .set(carts::USER_ID, V::opt_ref(user))
            .set(carts::SESSION_TOKEN, token.to_string())
            .set(carts::STATUS, status)
            .set(carts::CURRENCY_CODE, ms.m.currency.clone())
            .set(carts::ITEM_COUNT, V::Int(qty))
            .set(carts::SUBTOTAL, V::Money(subtotal))
            .set(carts::ABANDONED_AT, V::opt_ts(abandoned))
            .set(carts::CONVERTED_AT, V::opt_ts(converted))
            .set(carts::EXPIRES_AT, V::Ts(created + 30 * MICROS_PER_DAY))
            .set(carts::CREATED_AT, V::Ts(created))
            .set(carts::UPDATED_AT, V::Ts(converted.or(abandoned).unwrap_or(at).max(created)));
        let cart = self.emit_at(carts::T, created, r)?;
        for it in items {
            let mut r = Row::new(cart_items::NCOLS);
            r.set(cart_items::TENANT_ID, tenant)
                .set(cart_items::CART_ID, cart)
                .set(cart_items::PRODUCT_VARIANT_ID, it.variant)
                .set(cart_items::QUANTITY, V::Int(it.qty))
                .set(cart_items::UNIT_PRICE, V::Money(it.unit_gross))
                .set(cart_items::CURRENCY_CODE, ms.m.currency.clone())
                .set(cart_items::CREATED_AT, V::Ts(created))
                .set(cart_items::UPDATED_AT, V::Ts(created));
            self.emit_at(cart_items::T, created, r);
        }
        Some(cart)
    }

    /// (tax rate, prices include tax) for an order shipped from the merchant to `dest`.
    fn tax(&self, ms: &MerchantSim, dest: usize, region: usize, date: &str) -> (f64, bool) {
        let w = world();
        let home = &ms.m.country;
        let d = &w.geo.countries[dest];
        if home == "US" {
            if d.iso2 == "US" {
                let code = &d.regions[region].code;
                return (w.geo.us_sales_tax.get(code).copied().unwrap_or(7.0) / 100.0, false);
            }
            return (0.0, false);
        }
        let home_rate = w.vat_rate(w.country(home), date) / 100.0;
        if is_eu(home) {
            if is_eu(&d.iso2) {
                // S17: Austrian orders mapped to the German tax zone
                if crate::sim::stories::has(ms.m, "S17") && d.iso2 == "AT" && ("2024-07-01".."2024-10-01").contains(&date) {
                    return (w.vat_rate(w.country("DE"), date) / 100.0, true);
                }
                return (w.vat_rate(d, date) / 100.0, true); // OSS: destination rate
            }
            // S17: Swiss orders went through the same faulty tax zone in Q3 2024
            if crate::sim::stories::has(ms.m, "S17") && d.iso2 == "CH" && ("2024-07-01".."2024-10-01").contains(&date) {
                return (w.vat_rate(w.country("DE"), date) / 100.0, true);
            }
            return (0.0, true); // export: gross price, VAT removed
        }
        // GB / NO: domestic VAT, exports zero-rated
        if &d.iso2 == home { (home_rate, true) } else { (0.0, true) }
    }

    #[allow(clippy::too_many_arguments)]
    fn order(&mut self, rng: &mut Rng, ms: &MerchantSim, p: &Params, s: usize, session: Option<Rid>, at: Ts, items: Vec<Item>, cart: Option<Rid>, token: String, device: Device, ship_to: Option<(Rid, usize, usize)>, channel: Channel, sub: Option<Rid>) {
        // `sub`: a prepaid subscription delivery (the subscription invoice was the payment)
        let delivery = sub.is_some();
        let w = world();
        let tenant = ms.tenant_rid();
        // the snapshot ends at 2025-12-31 23:59:59: no checkout that would spill past it
        if at + 10 * MICROS_PER_MIN > time::end_ts() {
            return;
        }
        if items.is_empty() {
            return;
        }
        let (user, billing, email) = {
            let sh = &self.shoppers[s];
            match &sh.alias {
                // S14: some orders land on the duplicate account
                Some((u, e, a)) if rng.chance(0.5) => (*u, *a, e.clone()),
                _ => (sh.rid, sh.address, sh.email.clone()),
            }
        };
        let (address, dest, region) = ship_to.unwrap_or((billing, self.shoppers[s].country, self.shoppers[s].region));
        let date = time::date_of(time::day_of_ts(at).max(0) as Day).format("%Y-%m-%d").to_string();
        let (rate, inclusive) = self.tax(ms, dest, region, &date);
        let rate = if delivery { 0.0 } else { rate };
        let home_rate = if ms.m.country == "US" { 0.0 } else { w.vat_rate(w.country(&ms.m.country), &date) / 100.0 };
        let cur = ms.m.currency.clone();
        // lines: net unit price, tax per line
        // discounts: the best of a running promotion, a coupon (welcome offer on the first
        // order, Black Friday code), or B2B volume tiers; not stackable
        let first_order = self.shoppers[s].orders == 0;
        let promo_sitewide = ms.pricing.promos.iter().find(|o| o.products.is_none() && o.start <= at && at < o.end).cloned();
        let coupon_offer: Option<crate::sim::merchant::Offer> = if delivery {
            None
        } else if let Some(o) = promo_sitewide.filter(|_| rng.chance(0.8)) {
            Some(o)
        } else if first_order && rng.chance(if self.shoppers[s].fraud { 1.0 } else { 0.35 }) {
            ms.pricing.welcome.clone()
        } else {
            None
        };
        let mut applied: Option<(Rid, Option<(Rid, String)>, String)> = None;
        let mut lines = Vec::with_capacity(items.len());
        let mut discs = Vec::with_capacity(items.len());
        let (mut subtotal, mut tax_total, mut gross, mut discount_total) = (0i64, 0i64, 0i64, 0i64);
        let mut voucher_total = 0i64;
        for it in &items {
            // gift cards are vouchers: no VAT until redeemed, no discounts
            let voucher = ms.products[it.pidx].voucher;
            let unit_net = if inclusive && !voucher { (it.unit_gross as f64 / (1.0 + home_rate)).round() as i64 } else { it.unit_gross };
            let line_net = unit_net * it.qty;
            let auto = ms.promo_for(it.pidx, at).filter(|o| o.products.is_some());
            let tier = ms.pricing.tiers.iter().filter(|(min, _, _)| it.qty >= *min).map(|(_, pct, d)| (*pct, *d)).fold(None, |acc: Option<(f64, Rid)>, x| if acc.is_none_or(|a| x.0 > a.0) { Some(x) } else { acc });
            let mut pct = 0.0;
            if let Some(d) = sub {
                pct = 1.0;
                applied = Some((d, None, "Subscription delivery (prepaid)".into()));
            }
            if let Some(o) = &coupon_offer {
                pct = o.pct;
                applied = Some((o.discount, o.coupon.clone(), o.name.clone()));
            }
            if let Some(o) = auto.filter(|o| o.pct > pct && !delivery) {
                pct = o.pct;
                applied = applied.or(Some((o.discount, None, o.name.clone())));
            }
            if let Some((tp, d)) = tier.filter(|t| t.0 > pct && !delivery) {
                pct = tp;
                applied = applied.or(Some((d, None, "Volume discount".into())));
            }
            let pct = if voucher { 0.0 } else { pct };
            let disc = (line_net as f64 * pct).round() as i64;
            let line_total = line_net - disc;
            let tax = if voucher { 0 } else { (line_total as f64 * rate).round() as i64 };
            if voucher {
                voucher_total += line_total;
            }
            subtotal += line_net;
            discount_total += disc;
            tax_total += tax;
            gross += (it.unit_gross as f64 * it.qty as f64 * (1.0 - pct)).round() as i64;
            lines.push((unit_net, line_total, tax));
            discs.push(disc);
        }
        let domestic = dest == ms.country;
        let near = is_eu(&w.geo.countries[dest].iso2) == is_eu(&ms.m.country) || ["GB", "IE", "CH", "NO"].contains(&w.geo.countries[dest].iso2.as_str());
        let shipping = if delivery || (gross >= ms.free_shipping_threshold() && domestic) { 0 } else { ms.shipping_fee(if domestic { 0 } else if near { 1 } else { 2 }) };
        let grand = subtotal - discount_total + tax_total + shipping;
        // payment fate
        // B2B accounts on payment terms are invoiced and pay by bank transfer
        let terms = if delivery { None } else { self.b2b_terms(s) };
        let pm = match (delivery, self.shoppers[s].payment_method.clone()) {
            (true, Some(pm)) => pm,
            _ if terms.is_some() => self.transfer_method(rng, ms, s, at),
            _ => self.payment_method(rng, ms, s, at),
        };
        let (pm_rid, kind, gateway) = pm.clone();
        // a gift card in hand pays first
        let gc = if delivery || terms.is_some() { None } else { self.take_card(s, grand, at) };
        let gc_amt = gc.map_or(0, |g| g.1);
        let card_amt = grand - gc_amt;
        // S18: presents bought in the gift guide season are refunded as store credit
        let gift_credit = self.gift_order && crate::sim::stories::has(ms.m, "S18") && at >= crate::time::ts_of_date(chrono::NaiveDate::from_ymd_opt(2024, 11, 1).unwrap()) && at < crate::time::ts_of_date(chrono::NaiveDate::from_ymd_opt(2025, 1, 31).unwrap());
        let decline_p = if kind == "card" { 0.079 } else { 0.03 };
        // S2: a gateway outage; merchants with a second gateway route around it
        let down = !delivery && terms.is_none() && crate::sim::stories::gateway_down(&gateway, at);
        let failover = down && ms.m.gateways.len() > 1;
        let gateway = if failover { ms.m.gateways.iter().find(|g| g.name != gateway).map(|g| g.name.clone()).unwrap() } else { gateway };
        let mut attempts = vec![];
        let first_ok = delivery || terms.is_some() || card_amt == 0 || (!down && !rng.chance(decline_p));
        attempts.push(first_ok);
        if !first_ok && failover {
            // the retry is routed to the other gateway
            if rng.chance(0.9) {
                attempts.push(rng.chance(0.95));
            }
        } else if !first_ok && rng.chance(0.65) {
            attempts.push(rng.chance(if down { 0.12 } else { 0.85 }));
        }
        let paid = *attempts.last().unwrap();
        let public_id = rng.uuid();
        let note = if rng.chance(0.03) { V::Static(*rng.pick(&["Please leave with a neighbour if not home.", "It's a gift - please don't include the invoice.", "Ring the bell twice please.", "Deliver to the back door.", "Call before delivery."])) } else { V::Null };
        // the order's future: cancellation, fulfillment, delivery, return, refund
        let end = time::end_ts();
        let cancel_by_customer = paid && !delivery && terms.is_none() && gc.is_none() && rng.chance(0.015);
        let cancelled_at = if !paid { Some(at + 5 * MICROS_PER_MIN) } else if cancel_by_customer { Some(at + rng.int(1, 18) * MICROS_PER_HOUR) } else { None };
        let plan = if paid && !cancel_by_customer { Some(self.plan_fulfillment(rng, ms, dest, at)) } else { None };
        let exp = plan.as_ref().map(|pl| self.experience(rng, ms, s, &items, pl));
        let ret = if delivery { None } else { plan.as_ref().and_then(|pl| self.plan_return(rng, ms, s, &items, pl, exp.as_ref().unwrap())) };
        // S8: ring accounts claim the parcel never arrived and get refunded (some charge back)
        let ret = match (&plan, self.shoppers[s].fraud && rng.chance(0.7)) {
            (Some(pl), true) => {
                let requested = pl.delivered + rng.int(3, 10) * MICROS_PER_DAY;
                let approved = requested + rng.int(2, 30) * MICROS_PER_HOUR;
                Some(ReturnPlan { lines: items.iter().enumerate().map(|(i, it)| (i, it.qty, "Item not received")).collect(), reason: "Item not received", rejected: false, requested, approved, received: i64::MAX / 4, refunded: approved + rng.int(1, 3) * MICROS_PER_DAY, refund_reason: if rng.chance(0.4) { "chargeback" } else { "not_received" } })
            }
            _ => ret,
        };
        let refund_amount: i64 = ret.as_ref().map_or(0, |r| r.lines.iter().map(|(i, q, _)| (lines[*i].1 + lines[*i].2) / items[*i].qty * q).sum());
        let refunded_by_end = ret.as_ref().is_some_and(|r| !r.rejected && r.refunded <= end);
        let cancel_refund = cancel_by_customer && cancelled_at.is_some_and(|c| c <= end);
        let amount_refunded = if cancel_refund { grand } else if refunded_by_end { refund_amount } else { 0 };
        let shipped_by_end = plan.as_ref().is_some_and(|pl| pl.shipped <= end);
        let status = if !paid || cancel_by_customer {
            "cancelled"
        } else if refunded_by_end && amount_refunded >= grand - shipping {
            "refunded"
        } else if shipped_by_end {
            "fulfilled"
        } else {
            "paid"
        };
        let pay_status = if !paid {
            "failed"
        } else if amount_refunded >= grand {
            "refunded"
        } else if amount_refunded > 0 {
            "partially_refunded"
        } else {
            "captured"
        };
        let last_change = [cancelled_at, plan.as_ref().map(|p| p.shipped), ret.as_ref().map(|r| r.refunded)].into_iter().flatten().filter(|t| *t <= end).max().unwrap_or(at);
        let mut r = Row::new(orders::NCOLS);
        r.set(orders::PUBLIC_ID, V::Uuid(public_id))
            .set(orders::TENANT_ID, tenant)
            .set(orders::USER_ID, user)
            .set(orders::CART_ID, V::opt_ref(cart))
            .set(orders::ORDER_NUMBER, ms.order_prefix.clone())
            .set(orders::STATUS, status)
            .set(orders::BILLING_ADDRESS_ID, billing)
            .set(orders::SHIPPING_ADDRESS_ID, address)
            .set(orders::CURRENCY_CODE, cur.clone())
            .set(orders::SUBTOTAL, V::Money(subtotal))
            .set(orders::DISCOUNT_TOTAL, V::Money(discount_total))
            .set(orders::TAX_TOTAL, V::Money(tax_total))
            .set(orders::SHIPPING_TOTAL, V::Money(shipping))
            .set(orders::GRAND_TOTAL, V::Money(grand))
            .set(orders::CUSTOMER_EMAIL, if self.shoppers[s].ident.erased.is_some() { None } else { Some(email) })
            .set(orders::CUSTOMER_NOTE, note)
            .set(orders::PLACED_AT, V::Ts(at))
            .set(orders::CANCELLED_AT, V::opt_ts(cancelled_at.filter(|t| *t <= end)))
            .set(orders::CREATED_AT, V::Ts(at))
            .set(orders::UPDATED_AT, V::Ts(last_change.max(at)));
        // S13: orders synced from the ERP; from late October 2024 their time is off by the UTC offset
        let (placed, via_erp) = self.erp_time(rng, ms, at);
        r.set(orders::PLACED_AT, V::Ts(placed)).set(orders::CREATED_AT, V::Ts(placed));
        let Some(order) = self.emit_at(orders::T, at, r) else { return };
        if via_erp {
            let mut r2 = Rng::new(rng.u64(), &[10]);
            let meta = format!(r#"{{"source":"erp_connector","external_id":"SO-{}"}}"#, r2.digits(8));
            crate::sim::merchant::audit(&mut self.chunk, &mut r2, tenant, crate::sim::merchant::Audit { at: placed, action: "create", actor: None, actor_type: "integration", entity: Some((orders::T, order)), summary: "Order imported from ERP".into(), metadata: meta, ip: None, ua: None });
        }
        let mut item_rids = Vec::new();
        for ((it, (unit_net, line_net, tax)), disc) in items.iter().zip(&lines).zip(&discs) {
            let mut r = Row::new(order_items::NCOLS);
            r.set(order_items::TENANT_ID, tenant)
                .set(order_items::ORDER_ID, order)
                .set(order_items::PRODUCT_VARIANT_ID, it.variant)
                .set(order_items::SKU, it.sku.clone())
                .set(order_items::NAME, it.name.clone())
                .set(order_items::QUANTITY, V::Int(it.qty))
                .set(order_items::QUANTITY_FULFILLED, V::Int(if shipped_by_end { it.qty } else { 0 }))
                .set(order_items::UNIT_PRICE, V::Money(*unit_net))
                .set(order_items::DISCOUNT_TOTAL, V::Money(*disc))
                .set(order_items::TAX_TOTAL, V::Money(*tax))
                .set(order_items::LINE_TOTAL, V::Money(*line_net))
                .set(order_items::CURRENCY_CODE, cur.clone())
                .set(order_items::CREATED_AT, V::Ts(at))
                .set(order_items::UPDATED_AT, V::Ts(at));
            item_rids.push(self.emit_at(order_items::T, at, r).unwrap());
        }
        self.status_change(tenant, order, None, "pending", at);
        if let Some((discount, coupon, name)) = applied.filter(|_| discount_total > 0) {
            let mut r = Row::new(order_discounts::NCOLS);
            r.set(order_discounts::TENANT_ID, tenant)
                .set(order_discounts::ORDER_ID, order)
                .set(order_discounts::DISCOUNT_ID, discount)
                .set(order_discounts::COUPON_ID, V::opt_ref(coupon.as_ref().map(|c| c.0)))
                .set(order_discounts::CODE, coupon.as_ref().map(|c| c.1.clone()))
                .set(order_discounts::DESCRIPTION, name)
                .set(order_discounts::AMOUNT, V::Money(discount_total))
                .set(order_discounts::CURRENCY_CODE, cur.clone())
                .set(order_discounts::CREATED_AT, V::Ts(at))
                .set(order_discounts::UPDATED_AT, V::Ts(at));
            self.emit_at(order_discounts::T, at, r);
            if let Some((c, _)) = coupon.as_ref().filter(|_| paid) {
                let mut r = Row::new(coupon_redemptions::NCOLS);
                r.set(coupon_redemptions::TENANT_ID, tenant)
                    .set(coupon_redemptions::COUPON_ID, *c)
                    .set(coupon_redemptions::USER_ID, user)
                    .set(coupon_redemptions::ORDER_ID, order)
                    .set(coupon_redemptions::DISCOUNT_AMOUNT, V::Money(discount_total))
                    .set(coupon_redemptions::CURRENCY_CODE, cur.clone())
                    .set(coupon_redemptions::REDEEMED_AT, V::Ts(at))
                    .set(coupon_redemptions::CREATED_AT, V::Ts(at));
                self.emit_at(coupon_redemptions::T, at, r);
                self.outbox.entry(self.chunk.day).or_default().coupons.push(*c);
            }
        }
        if paid {
            self.shoppers[s].orders += 1;
            self.on_paid_order(rng, ms, s, order, at, grand, channel, delivery);
        }
        // payment and attempts (none for prepaid deliveries)
        let payment = if delivery || terms.is_some() || card_amt == 0 { None } else {
        let mut t = at + rng.int(2, 15) * MICROS_PER_SEC;
        let mut pr = Row::new(payments::NCOLS);
        let charge = format!("{}{}", gateway_prefix(&gateway), rng.alnum(24));
        let risk = rng.int(1, 99);
        pr.set(payments::TENANT_ID, tenant)
            .set(payments::ORDER_ID, order)
            .set(payments::PAYMENT_METHOD_ID, pm_rid)
            .set(payments::STATUS, pay_status)
            .set(payments::AMOUNT, V::Money(card_amt))
            .set(payments::AMOUNT_REFUNDED, V::Money(if gc.is_some() || gift_credit { 0 } else { amount_refunded }))
            .set(payments::CURRENCY_CODE, cur.clone())
            .set(payments::GATEWAY, gateway.clone())
            .set(payments::GATEWAY_CHARGE_ID, if paid { V::Str(charge.clone()) } else { V::Null })
            .set(payments::AUTHORIZED_AT, if paid { V::Ts(t + (attempts.len() as i64 - 1) * 90 * MICROS_PER_SEC) } else { V::Null })
            .set(payments::CAPTURED_AT, if paid { V::Ts(t + (attempts.len() as i64 - 1) * 90 * MICROS_PER_SEC + 2 * MICROS_PER_SEC) } else { V::Null })
            .set(payments::FAILURE_CODE, if paid { V::Null } else { V::Static("card_declined") })
            .set(
                payments::METADATA,
                V::Json(format!(
                    r#"{{"risk":{{"score":{risk},"level":"{}"}},"three_ds":{{"version":"2.2","result":"{}"}},"device":{{"type":"{}","ip_country":"{}"}},"checkout":{{"channel":"web","cart_token":"{token}"}}}}"#,
                    if risk > 80 { "elevated" } else { "normal" },
                    if kind == "card" { "authenticated" } else { "not_applicable" },
                    match device { Device::Mobile => "mobile", Device::Tablet => "tablet", Device::Desktop => "desktop" },
                    w.geo.countries[dest].iso2
                )),
            )
            .set(payments::CREATED_AT, V::Ts(t))
            .set(payments::UPDATED_AT, V::Ts(t));
        let payment = self.emit_at(payments::T, t, pr).unwrap();
        for (i, ok) in attempts.iter().enumerate() {
            let reason = if down && (i == 0 || !failover) { "gateway_timeout" } else { ["do_not_honor", "insufficient_funds", "expired_card", "authentication_required", "card_declined"][rng.below(5)] };
            let mut r = Row::new(payment_attempts::NCOLS);
            r.set(payment_attempts::TENANT_ID, tenant)
                .set(payment_attempts::PAYMENT_ID, payment)
                .set(payment_attempts::ATTEMPT_NUMBER, i + 1)
                .set(payment_attempts::STATUS, if *ok { "captured" } else { "failed" })
                .set(payment_attempts::AMOUNT, V::Money(card_amt))
                .set(payment_attempts::CURRENCY_CODE, cur.clone())
                .set(
                    payment_attempts::GATEWAY_RESPONSE,
                    V::Json(if *ok {
                        format!(r#"{{"status":"approved","code":"00","avs":"Y","cvc":"M","latency_ms":{}}}"#, rng.int(120, 900))
                    } else {
                        format!(r#"{{"status":"declined","code":"05","decline_reason":"{reason}","latency_ms":{}}}"#, rng.int(120, 900))
                    }),
                )
                .set(payment_attempts::ERROR_CODE, if *ok { V::Null } else { V::Static(reason) })
                .set(payment_attempts::ERROR_MESSAGE, if *ok { V::Null } else { V::Str(format!("Payment declined by issuer ({reason})")) })
                .set(payment_attempts::ATTEMPTED_AT, V::Ts(t))
                .set(payment_attempts::CREATED_AT, V::Ts(t))
                .set(payment_attempts::UPDATED_AT, V::Ts(t));
            self.emit_at(payment_attempts::T, t, r);
            t += 90 * MICROS_PER_SEC;
        }
        if paid && crate::sim::stories::gateway_recovering(&gateway, at) && rng.chance(0.06) {
            // S2: captured twice while the gateway recovered; the duplicate is refunded
            let refunded = at + rng.int(20, 72) * MICROS_PER_HOUR;
            let mut r = Row::new(payments::NCOLS);
            r.set(payments::TENANT_ID, tenant)
                .set(payments::ORDER_ID, order)
                .set(payments::PAYMENT_METHOD_ID, pm_rid)
                .set(payments::STATUS, if refunded <= end { "refunded" } else { "captured" })
                .set(payments::AMOUNT, V::Money(card_amt))
                .set(payments::AMOUNT_REFUNDED, V::Money(if refunded <= end { card_amt } else { 0 }))
                .set(payments::CURRENCY_CODE, cur.clone())
                .set(payments::GATEWAY, gateway.clone())
                .set(payments::GATEWAY_CHARGE_ID, format!("{}{}", gateway_prefix(&gateway), rng.alnum(24)))
                .set(payments::AUTHORIZED_AT, V::Ts(t + 40 * MICROS_PER_SEC))
                .set(payments::CAPTURED_AT, V::Ts(t + 42 * MICROS_PER_SEC))
                .set(payments::METADATA, V::Json(r#"{"retry_of_timeout":true}"#.to_string()))
                .set(payments::CREATED_AT, V::Ts(t + 40 * MICROS_PER_SEC))
                .set(payments::UPDATED_AT, V::Ts(refunded.min(end)));
            let dup = self.emit_at(payments::T, t, r).unwrap();
            if refunded <= end {
                let mut r = Row::new(payment_refunds::NCOLS);
                r.set(payment_refunds::TENANT_ID, tenant).set(payment_refunds::PAYMENT_ID, dup).set(payment_refunds::STATUS, "succeeded").set(payment_refunds::AMOUNT, V::Money(card_amt)).set(payment_refunds::CURRENCY_CODE, cur.clone()).set(payment_refunds::REASON, V::Static("duplicate")).set(payment_refunds::GATEWAY_REFUND_ID, format!("re_{}", rng.alnum(24))).set(payment_refunds::PROCESSED_AT, V::Ts(refunded + 10 * MICROS_PER_MIN)).set(payment_refunds::CREATED_AT, V::Ts(refunded)).set(payment_refunds::UPDATED_AT, V::Ts(refunded + 10 * MICROS_PER_MIN));
                self.emit_at(payment_refunds::T, refunded, r);
            }
        }
        Some(payment)
        };
        if paid {
            // reserve stock for the order
            for (it, oi) in items.iter().zip(&item_rids) {
                let slot = ms.stock_slot(it.pidx, it.vidx);
                let released = if cancel_by_customer { cancelled_at } else { plan.as_ref().map(|p| p.shipped) };
                if let Some(slot) = slot {
                    let mut r = Row::new(stock_reservations::NCOLS);
                    r.set(stock_reservations::TENANT_ID, tenant)
                        .set(stock_reservations::VARIANT_ID, it.variant)
                        .set(stock_reservations::STOCK_LOCATION_ID, slot.location)
                        .set(stock_reservations::ORDER_ID, order)
                        .set(stock_reservations::QUANTITY, V::Int(it.qty))
                        .set(stock_reservations::EXPIRES_AT, V::Ts(at + 7 * MICROS_PER_DAY))
                        .set(stock_reservations::RELEASED_AT, V::opt_ts(released.filter(|t| *t <= time::end_ts())))
                        .set(stock_reservations::CREATED_AT, V::Ts(at))
                        .set(stock_reservations::UPDATED_AT, V::Ts(released.filter(|t| *t <= time::end_ts()).unwrap_or(at)));
                    self.emit_at(stock_reservations::T, at, r);
                }
                let _ = oi;
                self.outbox.entry(self.chunk.day).or_default().stock.push((it.pidx, it.vidx, StockOp::Sold, it.qty));
                if let Some(c) = cancelled_at.filter(|_| cancel_by_customer) {
                    let d = time::day_of_ts(c).max(self.chunk.day as i64) as Day;
                    self.outbox.entry(d).or_default().stock.push((it.pidx, it.vidx, StockOp::Released, it.qty));
                }
            }
        }
        let lg = ms.ledger.as_ref().unwrap();
        if paid && !delivery && terms.is_none() {
            let captured_at = at + 30 * MICROS_PER_SEC;
            let gc_payment = gc.and_then(|(k, a)| self.redeem_card(rng, ms, k, order, a, at + 25 * MICROS_PER_SEC));
            // gift cards sold are a liability; a redeemed card settles part of the order
            self.ledger_p(ms, rng, payment.or(gc_payment), captured_at, &[(lg.clearing, "debit", card_amt), (lg.gift_cards, "debit", gc_amt), (lg.revenue, "credit", subtotal - discount_total - voucher_total), (lg.gift_cards, "credit", voucher_total), (lg.vat, "credit", tax_total), (lg.shipping_income, "credit", shipping)], "Order payment captured");
            let out = self.outbox.entry(self.chunk.day).or_default();
            if let Some(pay) = payment {
                out.captured.push(Captured { payment: pay, gateway: gateway.clone(), amount: card_amt, fee: gateway_fee(&gateway, card_amt) });
            }
            out.orders += 1;
            out.revenue += grand;
            if voucher_total > 0 {
                self.issue_cards(rng, ms, s, order, &items, at + 40 * MICROS_PER_SEC);
            }
        }
        if cancel_refund {
            let c = cancelled_at.unwrap();
            self.ledger(ms, rng, payment.unwrap(), c + 30 * MICROS_PER_MIN, &[(lg.refunds, "debit", grand - tax_total), (lg.vat, "debit", tax_total), (lg.clearing, "credit", grand)], "Order cancelled: refund");
            let d = (time::day_of_ts(c + 30 * MICROS_PER_MIN).max(self.chunk.day as i64)) as Day;
            self.outbox.entry(d).or_default().captured.push(Captured { payment: payment.unwrap(), gateway: gateway.clone(), amount: -grand, fee: 0 });
        }
        let tpl = ms.templates.as_ref().unwrap();
        let order_json = {
            let lines_json: Vec<String> = items.iter().zip(&lines).map(|(i, l)| format!(r#"{{"sku":{},"name":{},"quantity":{},"unit_price":"{}","tax":"{}"}}"#, json_str(&i.sku), json_str(&i.name), i.qty, money_str(l.0), money_str(l.2))).collect();
            let (city, postal) = (self.shoppers[s].city.clone(), self.shoppers[s].postal.clone());
            format!(
                r#"{{"order":{{"id":"{}","status":"{}","currency":"{cur}","subtotal":"{}","tax":"{}","shipping":"{}","total":"{}","customer":{{"email":{}}},"line_items":[{}],"shipping_address":{{"city":{},"postal_code":{},"country":"{}"}}}}}}"#,
                format_uuid(public_id),
                if paid { "paid" } else { "pending" },
                money_str(subtotal),
                money_str(tax_total),
                money_str(shipping),
                money_str(grand),
                json_str(&self.shoppers[s].email),
                lines_json.join(","),
                json_str(&city),
                postal.map_or("null".to_string(), |p| json_str(&p)),
                w.geo.countries[dest].iso2
            )
        };
        if paid {
            self.email(rng, ms, s, tpl.order_confirmation, format!("Your {} order is confirmed", ms.m.name), "orders", at + 25 * MICROS_PER_SEC);
            self.webhook(rng, ms, "order.created", &order_json, at + 22 * MICROS_PER_SEC);
            if terms.is_none() { self.webhook(rng, ms, "payment.captured", &format!(r#"{{"payment":{{"gateway":{},"amount":"{}","currency":"{cur}","order_id":"{}"}}}}"#, json_str(&gateway), money_str(grand), format_uuid(public_id)), at + 21 * MICROS_PER_SEC); }
        }
        if let Some(c) = cancelled_at {
            self.webhook(rng, ms, "order.cancelled", &order_json, c);
        }
        if let Some(sess) = session {
            let ctx = self.context_json(ms, device, "/checkout/thank-you", Some(p.anon_sample_rate));
            let skus: Vec<String> = items.iter().map(|i| format!(r#"{{"sku":{},"quantity":{},"price":{}}}"#, json_str(&i.sku), i.qty, money_str(i.unit_gross))).collect();
            if paid {
                self.event(
                    tenant,
                    Some(user),
                    sess,
                    "order_completed",
                    format!(
                        r#"{{"order":{{"id":"{}","revenue":{},"tax":{},"shipping":{},"currency":"{cur}"}},"items":[{}],"payment":{{"gateway":{}}},{ctx}}}"#,
                        format_uuid(public_id),
                        money_str(grand),
                        money_str(tax_total),
                        money_str(shipping),
                        skus.join(","),
                        json_str(&gateway)
                    ),
                    at + 20 * MICROS_PER_SEC,
                );
            }
        }
        if !paid {
            self.status_change(tenant, order, Some("pending"), "cancelled", at + 5 * MICROS_PER_MIN);
            if rng.chance(0.04) {
                let t = at + rng.int(5, 120) * MICROS_PER_MIN;
                self.ticket(rng, ms, s, Cause::PaymentFailed, t);
            }
            return;
        }
        self.status_change(tenant, order, Some("pending"), "paid", at + 20 * MICROS_PER_SEC);
        if cancel_by_customer {
            let c = cancelled_at.unwrap();
            self.status_change(tenant, order, Some("paid"), "cancelled", c);
            if c <= end {
                let mut r = Row::new(payment_refunds::NCOLS);
                r.set(payment_refunds::TENANT_ID, tenant)
                    .set(payment_refunds::PAYMENT_ID, payment.unwrap())
                    .set(payment_refunds::STATUS, "succeeded")
                    .set(payment_refunds::AMOUNT, V::Money(grand))
                    .set(payment_refunds::CURRENCY_CODE, cur.clone())
                    .set(payment_refunds::REASON, V::Static("requested_by_customer"))
                    .set(payment_refunds::GATEWAY_REFUND_ID, format!("re_{}", rng.alnum(24)))
                    .set(payment_refunds::PROCESSED_AT, V::Ts(c + 30 * MICROS_PER_MIN))
                    .set(payment_refunds::CREATED_AT, V::Ts(c))
                    .set(payment_refunds::UPDATED_AT, V::Ts(c + 30 * MICROS_PER_MIN));
                self.emit_at(payment_refunds::T, c, r);
            }
            return;
        }
        let plan = plan.unwrap();
        if self.gift_order && crate::sim::stories::has(ms.m, "S18") && rng.chance(0.6) {
            if let Some((by, _, _)) = ms.staff_actor(&["warehouse", "admin"]) {
                let t = plan.packed - rng.int(5, 60) * MICROS_PER_MIN;
                let mut r = Row::new(order_notes::NCOLS);
                r.set(order_notes::TENANT_ID, tenant).set(order_notes::ORDER_ID, order).set(order_notes::AUTHOR_USER_ID, by).set(order_notes::BODY, *rng.pick(&["Gift wrapped, gift receipt enclosed, no prices on the packing slip.", "Customer asked for delivery before 23 Dec - flagged as priority.", "Gift message card added as requested."])).set(order_notes::IS_PINNED, rng.chance(0.3)).set(order_notes::CREATED_AT, V::Ts(t)).set(order_notes::UPDATED_AT, V::Ts(t));
                self.emit_at(order_notes::T, t, r);
            }
        }
        let kept = grand - shipping - ret.as_ref().filter(|r| !r.rejected).map_or(0, |_| refund_amount);
        self.queue_points(ms, s, order, plan.delivered + 30 * MICROS_PER_DAY, kept);
        self.fulfill(rng, ms, p, order, &items, &item_rids, dest, &plan);
        if self.shoppers[s].b2b.is_some() && grand >= (1500.0 * ms.price_level * 100.0) as i64 {
            self.quote(rng, ms, s, order, &items, subtotal, grand, at);
        }
        let invoice = if terms.is_some() {
            let credit = ret.as_ref().filter(|r| !r.rejected).map(|r| (r.refunded, refund_amount));
            self.terms_invoice(rng, ms, s, order, &items, &lines, &discs, shipping, plan.shipped, credit, pm.clone())
        } else {
            None
        };
        let order_ref = format_uuid(public_id);
        let data = format!(r#"{{"order":{{"id":"{order_ref}"}},"carrier":{}}}"#, json_str(&plan.carrier));
        self.email(rng, ms, s, tpl.shipping, "Your order is on its way".into(), "orders", plan.shipped + 2 * MICROS_PER_MIN);
        self.notify(rng, ms, s, Some(tpl.shipping), "Your order has shipped".into(), data.clone(), plan.shipped + 2 * MICROS_PER_MIN);
        if let Some(t) = tpl.shipping_sms {
            self.sms(rng, ms, s, t, format!("{}: your order is on its way with {}.", ms.m.name, plan.carrier), plan.shipped + 3 * MICROS_PER_MIN);
        }
        self.webhook(rng, ms, "fulfillment.shipped", &format!(r#"{{"fulfillment":{{"order_id":"{order_ref}","carrier":{}}}}}"#, json_str(&plan.carrier)), plan.shipped);
        self.email(rng, ms, s, tpl.delivered, "Your order has been delivered".into(), "orders", plan.delivered + 10 * MICROS_PER_MIN);
        self.notify(rng, ms, s, Some(tpl.delivered), "Delivered!".into(), data, plan.delivered + 10 * MICROS_PER_MIN);
        let exp = exp.unwrap();
        let patience = self.shoppers[s].prefs.patience;
        // late: the less patient, the sooner they write "where is my order?"
        if exp.late_days > 0.5 && rng.chance(1.0 / (1.0 + libm::exp(3.5 - exp.late_days / patience * 2.0))) {
            let t = plan.promised + rng.int(4, 30) * MICROS_PER_HOUR;
            self.ticket(rng, ms, s, Cause::Wismo, t);
            if let Some(agent) = ms.agents.first().filter(|_| rng.chance(0.5)) {
                let at = t + rng.int(1, 24) * MICROS_PER_HOUR;
                let mut r = Row::new(order_notes::NCOLS);
                r.set(order_notes::TENANT_ID, tenant).set(order_notes::ORDER_ID, order).set(order_notes::AUTHOR_USER_ID, agent.user).set(order_notes::BODY, format!("Customer chased delivery. Parcel with {} is delayed in their network; asked carrier for an update.", plan.carrier)).set(order_notes::IS_PINNED, false).set(order_notes::CREATED_AT, V::Ts(at)).set(order_notes::UPDATED_AT, V::Ts(at));
                self.emit_at(order_notes::T, at, r);
            }
        }
        if exp.items.iter().any(|e| e.damaged) && rng.chance(0.6) {
            let t = plan.delivered + rng.int(1, 30) * MICROS_PER_HOUR;
            self.ticket(rng, ms, s, Cause::Damaged, t);
        } else if exp.items.iter().any(|e| e.defect) && rng.chance(0.4) {
            let t = plan.delivered + rng.int(3, 25) * MICROS_PER_DAY;
            self.ticket(rng, ms, s, Cause::QualityComplaint, t);
        } else if exp.items.iter().any(|e| e.q_gap < -2.2) && rng.chance(0.25) {
            let t = plan.delivered + rng.int(1, 6) * MICROS_PER_DAY;
            self.ticket(rng, ms, s, Cause::QualityComplaint, t);
        }
        if plan.failed_attempt && rng.chance(0.15) {
            self.ticket(rng, ms, s, Cause::FailedDelivery, plan.delivered - MICROS_PER_DAY + 2 * MICROS_PER_HOUR);
        }
        if let Some(r) = &ret {
            self.emit_return(rng, ms, order, if gc.is_some() || gift_credit { None } else { payment }, &items, &item_rids, &lines, r, refund_amount, grand - shipping);
            if let Some(inv) = invoice.clone().filter(|_| !r.rejected) {
                self.credit_note(rng, ms, s, inv, &items, &lines, &r.lines, r.refunded);
            }
            if !r.rejected && r.refunded <= time::end_ts() && (gc.is_some() || gift_credit) {
                // paid (partly) with a gift card: refunded as store credit
                let tax_share = (refund_amount as f64 * tax_total as f64 / (subtotal + tax_total).max(1) as f64).round() as i64;
                self.ledger_p(ms, rng, None, r.refunded, &[(lg.refunds, "debit", refund_amount - tax_share), (lg.vat, "debit", tax_share), (lg.gift_cards, "credit", refund_amount)], "Return refunded as store credit");
                self.credit_wallet(ms, s, refund_amount, r.refunded);
            } else if !r.rejected && r.refunded <= time::end_ts() && terms.is_none() {
                let tax_share = (refund_amount as f64 * tax_total as f64 / (subtotal + tax_total).max(1) as f64).round() as i64;
                self.ledger(ms, rng, payment.unwrap(), r.refunded, &[(lg.refunds, "debit", refund_amount - tax_share), (lg.vat, "debit", tax_share), (lg.clearing, "credit", refund_amount)], "Return refund");
                let d = time::day_of_ts(r.refunded) as Day;
                self.outbox.entry(d).or_default().captured.push(Captured { payment: payment.unwrap(), gateway: gateway.clone(), amount: -refund_amount, fee: 0 });
            }
            if !r.rejected {
                self.email(rng, ms, s, tpl.refund, "We've refunded your order".into(), "returns", r.refunded + 5 * MICROS_PER_MIN);
                self.webhook(rng, ms, "refund.created", &format!(r#"{{"refund":{{"order_id":"{}","amount":"{}","currency":"{cur}"}}}}"#, format_uuid(public_id), money_str(refund_amount)), r.refunded);
            }
            if r.reason == "Item not received" {
                let t = r.requested - rng.int(1, 20) * MICROS_PER_HOUR;
                self.ticket(rng, ms, s, Cause::NotReceived, t);
            } else if r.rejected && rng.chance(0.5) {
                self.ticket(rng, ms, s, Cause::RefundRejected, r.approved + MICROS_PER_HOUR);
            } else if rng.chance(0.12) {
                self.ticket(rng, ms, s, Cause::ReturnQuestion, r.approved + 2 * MICROS_PER_DAY);
            }
        }
        let scores: Vec<f64> = (0..items.len()).map(|i| exp.score(i, patience) + rng.gauss(0.0, 0.35)).collect();
        self.reviews(rng, ms, s, &items, &plan, ret.as_ref(), &scores, exp.late_days);
        // loyalty follows experience; a really bad one can end the relationship
        let e = scores.iter().sum::<f64>() / scores.len() as f64 - if ret.as_ref().is_some_and(|r| r.rejected) { 1.0 } else { 0.0 };
        let day = self.chunk.day;
        self.maybe_referral(rng, ms, s, plan.delivered, e);
        let sh = &mut self.shoppers[s];
        sh.satisfaction = (sh.satisfaction * libm::exp(0.15 * e)).clamp(0.3, 1.4);
        if rng.chance(0.4 / (1.0 + libm::exp((e + 2.0) * 2.0))) {
            sh.churn_day = sh.churn_day.min(day + 1);
        }
        if consumable(&ms.m.vertical) {
            let units: i64 = items.iter().map(|i| i.qty).sum::<i64>().max(1);
            let lasts = sh.cycle_days * (1.0 + 0.7 * (units as f64 - 1.0).min(4.0)) + rng.gauss(0.0, 3.0);
            let nd = day + lasts.max(5.0) as Day;
            if nd < sh.churn_day && (nd as usize) < self.calendar.len() {
                sh.need_day = Some(nd);
                sh.last_basket = items.iter().map(|i| (i.pidx, i.qty)).collect();
                self.calendar[nd as usize].push((s as u32, Visit::Need));
            }
        }
    }


    fn plan_fulfillment(&self, rng: &mut Rng, ms: &MerchantSim, dest: usize, at: Ts) -> Plan {
        let w = world();
        // a warehouse backlog pushes packing out
        let backlog = (ms.pack_delay_days * rng.lognormal(0.0, 0.3) * MICROS_PER_DAY as f64) as i64;
        let packed = self.next_working_time(ms, at + rng.int(1, 20) * MICROS_PER_HOUR + backlog, rng);
        let shipped = packed + rng.int(1, 6) * MICROS_PER_HOUR;
        let domestic = dest == ms.country;
        let carriers = if domestic { &ms.m.carriers } else { &ms.m.international_carriers };
        let carrier = carriers[Weighted::new(carriers.iter().map(|c| c.share)).sample(rng)].name.clone();
        let carrier = crate::sim::stories::carrier_override(ms.m, &carrier, at).map(String::from).unwrap_or(carrier);
        let express = rng.chance(0.12);
        let iso = w.geo.countries[dest].iso2.as_str();
        let near = is_eu(iso) == is_eu(&ms.m.country) || ["GB", "IE", "CH", "NO"].contains(&iso);
        let base_days = if domestic { if express { 1.0 } else { rng.uniform(1.0, 2.6) } } else if near { rng.uniform(2.0, 5.5) } else { rng.uniform(5.0, 12.0) };
        // congestion of the carrier's network (peak season, strikes) adds days
        let congestion = self.carrier_delay.get(crate::world::carrier_index(&carrier)).copied().unwrap_or(0.0) * rng.lognormal(0.0, 0.3);
        let transit_days = base_days + congestion;
        let mut delivered = shipped + (transit_days * MICROS_PER_DAY as f64) as i64;
        {
            use chrono::Datelike;
            // deliveries happen 08:00-20:00 local, not on Sundays
            let tz = time::tz_by_name(&w.geo.countries[dest].timezone);
            let local = tz.utc_to_local(delivered);
            let date = chrono::DateTime::from_timestamp_micros(local).unwrap().date_naive();
            let date = if date.weekday() == chrono::Weekday::Sun { date.succ_opt().unwrap() } else { date };
            delivered = tz.local_to_utc(date, 8 * MICROS_PER_HOUR + rng.int(0, 12 * 60) * MICROS_PER_MIN);
            if delivered < shipped + 6 * MICROS_PER_HOUR {
                delivered = shipped + 6 * MICROS_PER_HOUR + rng.int(0, 120) * MICROS_PER_MIN;
            }
        }
        let failed_attempt = rng.chance(0.04);
        if failed_attempt {
            delivered += MICROS_PER_DAY;
        }
        // "dispatched within 1-2 working days, delivered in 2-3" (express: next day)
        let promised_days = if domestic { if express { 2 } else { 4 } } else if near { 7 } else { 14 };
        Plan { promised: at + promised_days * MICROS_PER_DAY, packed, shipped, delivered, carrier, express, failed_attempt, domestic, congestion }
    }

    /// What actually happens to an order compared with expectations.
    fn experience(&self, rng: &mut Rng, ms: &MerchantSim, s: usize, items: &[Item], plan: &Plan) -> Experience {
        let prefs = &self.shoppers[s].prefs;
        let late_days = ((plan.delivered - plan.promised) as f64 / MICROS_PER_DAY as f64).max(0.0);
        let regret = regret_rate(&ms.m.vertical) * if self.shoppers[s].influencer { 2.5 } else { 1.0 };
        let items = items
            .iter()
            .map(|it| {
                let p = &ms.products[it.pidx];
                let realised = p.quality + rng.gauss(0.0, 0.6);
                let expected = 0.5 * p.price_rel;
                let fit_err = it.size.map(|(n, si)| si as f64 + p.fit_bias - prefs.size_pos * (n - 1) as f64 + rng.gauss(0.0, 0.15));
                // S5: units from the defective lot often fail
                let from_bad_lot = !ms.inv.defective.is_empty() && ms.stock_slot(it.pidx, it.vidx).and_then(|s| s.lot).is_some_and(|l| ms.inv.defective.contains(&l));
                ItemExp {
                    q_gap: realised - expected,
                    fit_err,
                    defect: from_bad_lot && rng.chance(0.33),
                    damaged: rng.chance(0.008 * p.fragility),
                    wrong_item: rng.chance(0.002),
                    regret: rng.chance(regret * libm::exp(0.5 * p.price_rel)),
                }
            })
            .collect();
        Experience { late_days, items }
    }

    /// Lines returned because of the experience, with the reason that dominated.
    fn plan_return(&self, rng: &mut Rng, ms: &MerchantSim, s: usize, items: &[Item], plan: &Plan, exp: &Experience) -> Option<ReturnPlan> {
        let ret = returnability(&ms.m.vertical);
        let patience = self.shoppers[s].prefs.patience;
        let mut lines = Vec::new();
        for (i, (it, e)) in items.iter().zip(&exp.items).enumerate() {
            let reason: Option<&'static str> = if ms.products[it.pidx].voucher {
                None
            } else if e.defect && rng.chance(0.9) {
                Some("Defective - stopped working")
            } else if e.damaged && rng.chance(0.9) {
                Some("Arrived damaged")
            } else if e.wrong_item && rng.chance(0.95) {
                Some("Wrong item received")
            } else if e.fit_err.is_some_and(|f| f.abs() > 0.65) && rng.chance(0.85 * ret.max(0.3)) {
                Some(if e.fit_err.unwrap() < 0.0 { "Size too small" } else { "Size too large" })
            } else if e.q_gap < -0.8 && rng.chance(ret * 0.3 / (1.0 + libm::exp((e.q_gap + 1.4) * 2.5))) {
                Some(if rng.chance(0.5) { "Quality not as expected" } else { "Not as described" })
            } else if exp.late_days > 3.0 * patience && rng.chance(0.2 * ret) {
                Some("Arrived too late")
            } else if e.regret && rng.chance(ret) {
                Some("Changed my mind")
            } else {
                None
            };
            if let Some(r) = reason {
                let q = if it.qty > 1 && r == "Changed my mind" { 1 } else { it.qty };
                lines.push((i, q, r));
            }
        }
        if lines.is_empty() {
            return None;
        }
        let requested = plan.delivered + rng.int(1, 20) * MICROS_PER_DAY + rng.int(0, MICROS_PER_DAY - 1);
        let approved = requested + rng.int(1, 60) * MICROS_PER_HOUR;
        let received = approved + rng.int(2, 8) * MICROS_PER_DAY;
        let refunded = received + rng.int(4, 72) * MICROS_PER_HOUR;
        Some(ReturnPlan { reason: lines[0].2, lines, rejected: rng.chance(0.04), requested, approved, received, refunded, refund_reason: "return" })
    }

    #[allow(clippy::too_many_arguments)]
    fn emit_return(&mut self, rng: &mut Rng, ms: &MerchantSim, order: Rid, payment: Option<Rid>, items: &[Item], item_rids: &[Rid], lines: &[(i64, i64, i64)], r: &ReturnPlan, refund: i64, refundable: i64) {
        let tenant = ms.tenant_rid();
        let end = time::end_ts();
        let cur = ms.m.currency.clone();
        let upto = |t: Ts| if t <= end { V::Ts(t) } else { V::Null };
        let (status, last) = if r.rejected {
            if r.approved <= end { ("rejected", r.approved) } else { ("requested", r.requested) }
        } else if r.refunded <= end {
            ("refunded", r.refunded)
        } else if r.received <= end {
            ("received", r.received)
        } else if r.approved <= end {
            ("approved", r.approved)
        } else {
            ("requested", r.requested)
        };
        let mut row = Row::new(order_returns::NCOLS);
        row.set(order_returns::TENANT_ID, tenant)
            .set(order_returns::ORDER_ID, order)
            .set(order_returns::RMA_NUMBER, "RMA-")
            .set(order_returns::STATUS, status)
            .set(order_returns::REASON, r.reason)
            .set(order_returns::REFUND_TOTAL, V::Money(if r.rejected { 0 } else { refund }))
            .set(order_returns::CURRENCY_CODE, cur.clone())
            .set(order_returns::REQUESTED_AT, V::Ts(r.requested))
            .set(order_returns::APPROVED_AT, if r.rejected { V::Null } else { upto(r.approved) })
            .set(order_returns::RECEIVED_AT, if r.rejected { V::Null } else { upto(r.received) })
            .set(order_returns::REFUNDED_AT, if r.rejected { V::Null } else { upto(r.refunded) })
            .set(order_returns::CREATED_AT, V::Ts(r.requested))
            .set(order_returns::UPDATED_AT, V::Ts(last));
        let Some(ret) = self.emit_at(order_returns::T, r.requested, row) else { return };
        if !ms.agents.is_empty() && (r.approved <= end) {
            let agent = ms.agents[rng.below(ms.agents.len())].user;
            let ip = ms.admin.office_ip.clone();
            let to = if r.rejected { "rejected" } else { "approved" };
            let a = crate::sim::merchant::audit(&mut self.chunk, rng, tenant, crate::sim::merchant::Audit { at: r.approved, action: "update", actor: Some(agent), actor_type: "staff", entity: Some((order_returns::T, ret)), summary: format!("Return {to}"), metadata: format!(r#"{{"reason":{}}}"#, json_str(r.reason)), ip: Some(&ip), ua: None });
            crate::sim::merchant::change(&mut self.chunk, tenant, a, Some(agent), (order_returns::T, ret), &["status", "approved_at"], r#"{"status":"requested","approved_at":null}"#.into(), format!(r#"{{"status":"{to}"}}"#), r.approved);
        }
        if !r.rejected && r.received <= end {
            let d = time::day_of_ts(r.received) as Day;
            for (i, q, reason) in &r.lines {
                if *reason == "Arrived damaged" {
                    continue;
                }
                let it = &items[*i];
                self.outbox.entry(d).or_default().stock.push((it.pidx, it.vidx, StockOp::Restocked, *q));
                if let Some(slot) = ms.stock_slot(it.pidx, it.vidx) {
                    let mut row = Row::new(stock_movements::NCOLS);
                    row.set(stock_movements::TENANT_ID, tenant)
                        .set(stock_movements::VARIANT_ID, it.variant)
                        .set(stock_movements::STOCK_LOCATION_ID, slot.location)
                        .set(stock_movements::LOT_ID, V::opt_ref(slot.lot))
                        .set(stock_movements::KIND, "return")
                        .set(stock_movements::QUANTITY, V::Int(*q))
                        .set(stock_movements::REFERENCE_TYPE, "return")
                        .set(stock_movements::REFERENCE_ID, ret)
                        .set(stock_movements::OCCURRED_AT, V::Ts(r.received))
                        .set(stock_movements::CREATED_AT, V::Ts(r.received + rng.int(1, 3600) * MICROS_PER_SEC));
                    self.emit_at(stock_movements::T, r.received, row);
                }
            }
        }
        for (i, q, reason) in &r.lines {
            let amount = (lines[*i].1 + lines[*i].2) / items[*i].qty * q;
            let mut row = Row::new(return_items::NCOLS);
            row.set(return_items::TENANT_ID, tenant)
                .set(return_items::RETURN_ID, ret)
                .set(return_items::ORDER_ITEM_ID, item_rids[*i])
                .set(return_items::QUANTITY, V::Int(*q))
                .set(return_items::REASON, if rng.chance(0.7) { V::Static(reason) } else { V::Null })
                .set(return_items::RESTOCK, *reason != "Arrived damaged")
                .set(return_items::REFUND_AMOUNT, V::Money(if r.rejected { 0 } else { amount }))
                .set(return_items::CURRENCY_CODE, cur.clone())
                .set(return_items::CREATED_AT, V::Ts(r.requested))
                .set(return_items::UPDATED_AT, V::Ts(r.requested));
            self.emit_at(return_items::T, r.requested, row);
        }
        if let Some(payment) = payment.filter(|_| !r.rejected && r.refunded <= end && refund > 0) {
            let mut row = Row::new(payment_refunds::NCOLS);
            row.set(payment_refunds::TENANT_ID, tenant)
                .set(payment_refunds::PAYMENT_ID, payment)
                .set(payment_refunds::STATUS, "succeeded")
                .set(payment_refunds::AMOUNT, V::Money(refund))
                .set(payment_refunds::CURRENCY_CODE, cur)
                .set(payment_refunds::REASON, V::Static(r.refund_reason))
                .set(payment_refunds::GATEWAY_REFUND_ID, format!("re_{}", rng.alnum(24)))
                .set(payment_refunds::PROCESSED_AT, V::Ts(r.refunded + rng.int(1, 120) * MICROS_PER_MIN))
                .set(payment_refunds::CREATED_AT, V::Ts(r.refunded))
                .set(payment_refunds::UPDATED_AT, V::Ts(r.refunded));
            self.emit_at(payment_refunds::T, r.refunded, row);
            if refund >= refundable {
                self.status_change(tenant, order, Some("fulfilled"), "refunded", r.refunded);
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn reviews(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, items: &[Item], plan: &Plan, ret: Option<&ReturnPlan>, scores: &[f64], late_days: f64) {
        let end = time::end_ts();
        if plan.delivered > end {
            return;
        }
        let tenant = ms.tenant_rid();
        let late = late_days > 1.0;
        for (i, it) in items.iter().enumerate() {
            if self.shoppers[s].reviewed.contains(&it.product) || ms.products[it.pidx].voucher {
                continue;
            }
            let returned = ret.is_some_and(|r| r.lines.iter().any(|(j, _, _)| *j == i));
            // strong experiences, good or bad, get reviewed more (J-shaped ratings)
            let e = scores[i];
            // unhappy customers are quicker to write
            let k = if e < 0.0 { 0.11 } else { 0.07 };
            if !rng.chance((0.02 + k * libm::pow(e.abs(), 1.5)).min(0.35)) {
                continue;
            }
            let rating = ((4.4 + 1.5 * e + rng.gauss(0.0, 0.4)).round() as i64).clamp(1, 5);
            let created = plan.delivered + rng.int(2, 30) * MICROS_PER_DAY + rng.int(0, MICROS_PER_DAY - 1);
            if created > end {
                continue;
            }
            let (title, body) = review_text(rng, rating, &it.product_name, &ms.m.vertical, late, returned);
            // helpful votes from other shoppers of this chunk
            let n_votes = rng.poisson(0.9) as usize;
            let mut voters: Vec<usize> = Vec::new();
            for _ in 0..n_votes {
                let v = rng.below(self.shoppers.len());
                if v != s && !voters.contains(&v) {
                    voters.push(v);
                }
            }
            let votes: Vec<(usize, bool, Ts)> = voters.iter().map(|&v| (v, rng.chance(0.8), created + rng.int(1, 120) * MICROS_PER_DAY)).filter(|x| x.2 <= end).collect();
            let helpful = votes.iter().filter(|v| v.1).count();
            let mut row = Row::new(product_reviews::NCOLS);
            row.set(product_reviews::TENANT_ID, tenant)
                .set(product_reviews::PRODUCT_ID, it.product)
                .set(product_reviews::USER_ID, self.shoppers[s].rid)
                .set(product_reviews::RATING, V::Int(rating))
                .set(product_reviews::TITLE, title)
                .set(product_reviews::BODY, body)
                .set(product_reviews::IS_VERIFIED_PURCHASE, true)
                .set(product_reviews::IS_APPROVED, rng.chance(if rating == 1 { 0.85 } else { 0.96 }))
                .set(product_reviews::HELPFUL_COUNT, helpful)
                .set(product_reviews::CREATED_AT, V::Ts(created))
                .set(product_reviews::UPDATED_AT, V::Ts(created));
            let Some(rev) = self.emit_at(product_reviews::T, created, row) else { continue };
            self.shoppers[s].reviewed.push(it.product);
            for (v, helpful, at) in votes {
                let mut row = Row::new(review_votes::NCOLS);
                row.set(review_votes::TENANT_ID, tenant)
                    .set(review_votes::REVIEW_ID, rev)
                    .set(review_votes::USER_ID, self.shoppers[v].rid)
                    .set(review_votes::IS_HELPFUL, helpful)
                    .set(review_votes::CREATED_AT, V::Ts(at));
                self.emit_at(review_votes::T, at, row);
            }
        }
    }


    /// A support ticket with its conversation, events, SLA breaches and CSAT.
    fn ticket(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, cause: Cause, at: Ts) {
        let end = time::end_ts();
        if ms.agents.is_empty() || at > end {
            return;
        }
        let tenant = ms.tenant_rid();
        let user = self.shoppers[s].rid;
        let (subject, tags, prio, customer_text, agent_text): (&str, &[&str], usize, &str, &str) = match cause {
            Cause::Wismo => ("Where is my order?", &["delivery", "where-is-my-order"], 1, "Hi, my order still hasn't arrived and the tracking hasn't updated for days. Can you check?", "Thanks for your patience - I've checked with the carrier and your parcel is delayed in their network. It should arrive within the next few days."),
            Cause::FailedDelivery => ("Missed delivery", &["delivery"], 1, "The courier says they tried to deliver but nobody came to the door. I was home all day.", "Sorry about that. I've asked the carrier to re-attempt delivery tomorrow."),
            Cause::Damaged => ("Item arrived damaged", &["damaged", "complaint"], 3, "My order arrived damaged, the box was crushed. Photos attached.", "I'm very sorry. We'll send a replacement right away, no need to return the damaged item."),
            Cause::ReturnQuestion => ("Question about my return", &["return"], 1, "I sent my return last week - has it arrived? When will I get my money back?", "Your return has been received and the refund is on its way. It can take 3-5 business days to appear."),
            Cause::RefundRejected => ("Return rejected?!", &["refund", "complaint"], 2, "Why was my return rejected? The item was unused.", "I've reviewed your return again. Unfortunately the item was returned outside our return policy."),
            Cause::PaymentFailed => ("Payment keeps failing", &["payment"], 1, "My card is declined every time I try to check out, but it works everywhere else.", "Sorry for the trouble. Your bank declined the payment - please try another card or contact your bank."),
            Cause::QualityComplaint => ("Really disappointed with the quality", &["complaint"], 2, "The product I received is nothing like the photos and the quality is poor for the price.", "I'm sorry to hear that. I've arranged a free return and a full refund for you."),
            Cause::AccountAccess => ("Someone logged into my account", &["account", "complaint"], 3, "I got an email about a login I didn't make and there's a new address on my account!", "Thanks for alerting us. We've signed out all sessions, removed the address and sent you a password reset link."),
            Cause::NotReceived => ("My order never arrived", &["delivery", "complaint"], 2, "The tracking says delivered but I never received my parcel. I want a refund.", "Sorry to hear that. I've opened a claim with the carrier and issued a refund."),
            Cause::OutOfStock => ("When will this be back in stock?", &["product-question"], 0, "Hi, the item I want has been out of stock for a while. When will you get it back?", "Thanks for asking! We're waiting for a delayed delivery from our supplier and hope to have it back soon."),
            Cause::ProductQuestion => ("Question about a product", &["product-question"], 0, "Hi, could you tell me more about the sizing / materials of this product?", "Happy to help! Please see the size guide on the product page, and let me know if you have any other questions."),
        };
        let prio = if rng.chance(0.08) { (prio + 1).min(3) } else { prio };
        if rng.chance(0.15) {
            let cat = match cause { Cause::Wismo | Cause::FailedDelivery => 0, Cause::Damaged | Cause::ReturnQuestion | Cause::RefundRejected => 1, Cause::PaymentFailed => 2, _ => 4 };
            let t = at - rng.int(1, 30) * MICROS_PER_MIN;
            self.article_feedback(rng, ms, s, cat, false, t);
        }
        let sla = &ms.slas[prio];
        let avail = ms.agents_at(at);
        let agent = avail[rng.below(avail.len())];
        let channel = ["email", "email", "email", "chat", "chat", "web", "phone", "social"][rng.below(8)];
        let base_fr = [600.0, 230.0, 75.0, 28.0][prio];
        // queued work ahead of this ticket (in business minutes) plus the agent's own pace
        let fr_min = (base_fr * rng.lognormal(0.0, 0.8) + ms.support_delay * 540.0).max(2.0);
        let bh = ms.m.size_rank > 20; // matches sla_policies.business_hours_only
        let first_response = if bh { business_add(ms, at, fr_min as i64) } else { at + (fr_min * MICROS_PER_MIN as f64) as i64 };
        let rounds = rng.poisson(0.8) as i64;
        let mut t = first_response;
        let mut convo: Vec<(bool, Ts, String)> = vec![(true, at, customer_text.to_string()), (false, first_response, agent_text.to_string())];
        for _ in 0..rounds {
            t += (rng.exp(6.0 * (1.0 + ms.support_delay)) * MICROS_PER_HOUR as f64) as i64 + 10 * MICROS_PER_MIN;
            convo.push((true, t, rng.pick(&["Thanks, but that doesn't solve my problem.", "Any update on this?", "OK, thank you. One more question though.", "Still waiting..."]).to_string()));
            t += (rng.exp(4.0 * (1.0 + ms.support_delay)) * MICROS_PER_HOUR as f64) as i64 + 10 * MICROS_PER_MIN;
            convo.push((false, t, rng.pick(&["I've escalated this to our logistics team and will update you shortly.", "Thanks for the details - I've sorted this for you now.", "Apologies for the wait. This is now resolved."]).to_string()));
        }
        let solved = t + rng.int(1, 30) * MICROS_PER_MIN;
        let closed = solved + 4 * MICROS_PER_DAY;
        let last_msg = convo.iter().map(|c| c.1).filter(|x| *x <= end).max().unwrap_or(at);
        let status = if closed <= end { "closed" } else if solved <= end { "solved" } else if first_response <= end { if rng.chance(0.5) { "pending" } else { "open" } } else { "new" };
        let mut r = Row::new(tickets::NCOLS);
        r.set(tickets::PUBLIC_ID, V::Uuid(rng.uuid()))
            .set(tickets::TENANT_ID, tenant)
            .set(tickets::REQUESTER_USER_ID, user)
            .set(tickets::ASSIGNEE_AGENT_ID, if first_response <= end { V::Ref(agent.rid) } else { V::Null })
            .set(tickets::AGENT_GROUP_ID, agent.group)
            .set(tickets::SLA_POLICY_ID, sla.rid)
            .set(tickets::SUBJECT, subject)
            .set(tickets::STATUS, status)
            .set(tickets::PRIORITY, ["low", "normal", "high", "urgent"][prio])
            .set(tickets::CHANNEL, channel)
            .set(tickets::FIRST_RESPONSE_AT, if first_response <= end { V::Ts(first_response) } else { V::Null })
            .set(tickets::RESOLVED_AT, if solved <= end { V::Ts(solved) } else { V::Null })
            .set(tickets::CLOSED_AT, if closed <= end { V::Ts(closed) } else { V::Null })
            .set(tickets::LAST_MESSAGE_AT, V::Ts(last_msg))
            .set(tickets::CREATED_AT, V::Ts(at))
            .set(tickets::UPDATED_AT, V::Ts([closed, solved, last_msg].into_iter().filter(|x| *x <= end).max().unwrap_or(at)));
        let Some(tk) = self.emit_at(tickets::T, at, r) else { return };
        let t = first_response - rng.int(30, 300) * MICROS_PER_SEC;
        self.access_customer(rng, ms, s, agent.user, t, "support");
        let d = time::day_of_ts(at).max(self.chunk.day as i64) as Day;
        self.outbox.entry(d).or_default().tickets += 1;
        for (from_customer, ts, body) in convo {
            let mut r = Row::new(ticket_messages::NCOLS);
            r.set(ticket_messages::TENANT_ID, tenant)
                .set(ticket_messages::TICKET_ID, tk)
                .set(ticket_messages::AUTHOR_USER_ID, if from_customer { V::Ref(user) } else { V::Ref(agent.user) })
                .set(ticket_messages::AUTHOR_AGENT_ID, if from_customer { V::Null } else { V::Ref(agent.rid) })
                .set(ticket_messages::BODY, body)
                .set(ticket_messages::IS_PUBLIC, true)
                .set(ticket_messages::CHANNEL, channel)
                .set(ticket_messages::CREATED_AT, V::Ts(ts))
                .set(ticket_messages::UPDATED_AT, V::Ts(ts));
            self.emit_at(ticket_messages::T, ts, r);
        }
        let fr_target = if bh { business_add(ms, at, sla.first_response_min) } else { at + sla.first_response_min * MICROS_PER_MIN };
        let res_target = if bh { business_add(ms, at, sla.resolution_min) } else { at + sla.resolution_min * MICROS_PER_MIN };
        let fr_breach = first_response > fr_target;
        let res_breach = solved > res_target;
        let events: Vec<(&str, Option<&str>, Option<&str>, Ts, bool)> = vec![
            ("created", None, Some("new"), at, false),
            ("assigned", None, None, first_response - 60 * MICROS_PER_SEC, true),
            ("status_changed", Some("new"), Some("open"), first_response, true),
            ("status_changed", Some("open"), Some("solved"), solved, true),
            ("status_changed", Some("solved"), Some("closed"), closed, false),
        ];
        for (kind, old, new, ts, by_agent) in events {
            let mut r = Row::new(ticket_events::NCOLS);
            r.set(ticket_events::TENANT_ID, tenant)
                .set(ticket_events::TICKET_ID, tk)
                .set(ticket_events::ACTOR_USER_ID, if by_agent { V::Ref(agent.user) } else if kind == "created" { V::Ref(user) } else { V::Null })
                .set(ticket_events::ACTOR_AGENT_ID, if by_agent { V::Ref(agent.rid) } else { V::Null })
                .set(ticket_events::EVENT_TYPE, kind)
                .set(ticket_events::OLD_VALUE, old.map(String::from))
                .set(ticket_events::NEW_VALUE, new.map(String::from))
                .set(ticket_events::METADATA, V::Json(format!(r#"{{"via":"{}","sla":{{"priority":"{}","breached":{}}}}}"#, if kind == "status_changed" && new == Some("closed") { "automation" } else { channel }, ["low", "normal", "high", "urgent"][prio], fr_breach || res_breach)))
                .set(ticket_events::OCCURRED_AT, V::Ts(ts))
                .set(ticket_events::CREATED_AT, V::Ts(ts));
            self.emit_at(ticket_events::T, ts, r);
        }
        for (kind, target_min, actual) in [("first_response", sla.first_response_min, first_response), ("resolution", sla.resolution_min, solved)] {
            let target = if bh { business_add(ms, at, target_min) } else { at + target_min * MICROS_PER_MIN };
            if actual > target && target <= end {
                let mut r = Row::new(sla_breaches::NCOLS);
                r.set(sla_breaches::TENANT_ID, tenant)
                    .set(sla_breaches::TICKET_ID, tk)
                    .set(sla_breaches::SLA_POLICY_ID, sla.rid)
                    .set(sla_breaches::BREACH_KIND, kind)
                    .set(sla_breaches::TARGET_AT, V::Ts(target))
                    .set(sla_breaches::BREACHED_AT, V::Ts(target))
                    .set(sla_breaches::MINUTES_OVER, if actual <= end { V::Int((actual - target) / MICROS_PER_MIN) } else { V::Null })
                    .set(sla_breaches::CREATED_AT, V::Ts(target))
                    .set(sla_breaches::UPDATED_AT, V::Ts(actual.min(end)));
                self.emit_at(sla_breaches::T, target, r);
            }
        }
        for tag in tags {
            if let Some((_, tag_rid)) = ms.support_tags.iter().find(|(n, _)| n == tag) {
                let mut r = Row::new(ticket_tags_map::NCOLS);
                r.set(ticket_tags_map::TENANT_ID, tenant).set(ticket_tags_map::TICKET_ID, tk).set(ticket_tags_map::SUPPORT_TAG_ID, *tag_rid).set(ticket_tags_map::CREATED_AT, V::Ts(at));
                self.emit_at(ticket_tags_map::T, at, r);
            }
        }
        // satisfaction: fast, clean resolutions are rated well
        let hours = (solved - at) as f64 / MICROS_PER_HOUR as f64;
        let mut score = 4.6 - 0.04 * hours.min(60.0) - if fr_breach { 0.7 } else { 0.0 } - if matches!(cause, Cause::RefundRejected) { 1.5 } else { 0.0 };
        score += rng.gauss(0.0, 0.8);
        let score = (score.round() as i64).clamp(1, 5);
        let submitted = solved + rng.int(1, 48) * MICROS_PER_HOUR;
        if submitted <= end && rng.chance(0.3) {
            let mut r = Row::new(csat_responses::NCOLS);
            r.set(csat_responses::TENANT_ID, tenant)
                .set(csat_responses::TICKET_ID, tk)
                .set(csat_responses::RESPONDENT_USER_ID, user)
                .set(csat_responses::RATED_AGENT_ID, agent.rid)
                .set(csat_responses::SCORE, V::Int(score))
                .set(csat_responses::COMMENT, if rng.chance(0.3) { V::Static(match score { 5 => "Super quick and friendly, thanks!", 4 => "Good help.", 3 => "Took a while but got there.", 2 => "Slow response.", _ => "Very unhelpful." }) } else { V::Null })
                .set(csat_responses::SUBMITTED_AT, V::Ts(submitted))
                .set(csat_responses::CREATED_AT, V::Ts(submitted))
                .set(csat_responses::UPDATED_AT, V::Ts(submitted));
            self.emit_at(csat_responses::T, submitted, r);
        }
        let sh = &mut self.shoppers[s];
        sh.satisfaction = (sh.satisfaction * if score <= 2 { 0.75 } else if score >= 4 { 1.03 } else { 0.95 }).clamp(0.3, 1.3);
    }


    fn email(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, template: Rid, subject: String, from: &str, at: Ts) {
        let end = time::end_ts();
        if at > end {
            return;
        }
        let (status, err) = match rng.below(1000) {
            0..=9 => ("failed", Some("550 5.1.1 Recipient address rejected: User unknown")),
            10..=12 => ("failed", Some("552 5.2.2 Mailbox full")),
            13..=14 => ("retrying", Some("421 4.7.0 Temporary deferral, try again later")),
            _ => ("success", None),
        };
        let us = ms.m.country == "US";
        let mut r = Row::new(email_log::NCOLS);
        r.set(email_log::TENANT_ID, ms.tenant_rid())
            .set(email_log::USER_ID, self.shoppers[s].rid)
            .set(email_log::TEMPLATE_ID, template)
            .set(email_log::RECIPIENT_EMAIL, self.shoppers[s].email.clone())
            .set(email_log::FROM_EMAIL, format!("{from}@{}", ms.domain))
            .set(email_log::SUBJECT, subject)
            .set(email_log::PROVIDER, if us { "twmail-us-1" } else { "twmail-eu-1" })
            .set(email_log::PROVIDER_MESSAGE_ID, format!("<{}@mail.tidewick.app>", format_uuid(rng.uuid())))
            .set(email_log::STATUS, status)
            .set(email_log::ERROR_MESSAGE, err.map(String::from))
            .set(email_log::SENT_AT, if status == "retrying" { V::Null } else { V::Ts(at + rng.int(1, 20) * MICROS_PER_SEC) })
            .set(email_log::CREATED_AT, V::Ts(at));
        self.emit_at(email_log::T, at, r);
    }

    fn notify(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, template: Option<Rid>, title: String, data: String, at: Ts) {
        let end = time::end_ts();
        if at > end {
            return;
        }
        let delivered = at + rng.int(1, 30) * MICROS_PER_SEC;
        let read = if rng.chance(0.45) { Some(delivered + (rng.exp(20.0) * MICROS_PER_HOUR as f64) as i64) } else { None };
        let status = if read.is_some_and(|t| t <= end) { "read" } else { "delivered" };
        let channel = if self.shoppers[s].app { "push" } else { "in_app" };
        let mut r = Row::new(notifications::NCOLS);
        r.set(notifications::TENANT_ID, ms.tenant_rid())
            .set(notifications::USER_ID, self.shoppers[s].rid)
            .set(notifications::TEMPLATE_ID, V::opt_ref(template))
            .set(notifications::CHANNEL, channel)
            .set(notifications::STATUS, status)
            .set(notifications::TITLE, title)
            .set(notifications::DATA, V::Json(data))
            .set(notifications::SENT_AT, V::Ts(at))
            .set(notifications::DELIVERED_AT, V::Ts(delivered.min(end)))
            .set(notifications::READ_AT, V::opt_ts(read.filter(|t| *t <= end)))
            .set(notifications::CREATED_AT, V::Ts(at))
            .set(notifications::UPDATED_AT, V::Ts(read.filter(|t| *t <= end).unwrap_or(delivered.min(end))));
        self.emit_at(notifications::T, at, r);
    }

    fn sms(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, template: Rid, body: String, at: Ts) {
        let Some(phone) = self.shoppers[s].phone.clone() else { return };
        if at > time::end_ts() {
            return;
        }
        let ok = rng.chance(0.97);
        let segments = 1 + body.chars().count() / 160;
        let mut r = Row::new(sms_log::NCOLS);
        r.set(sms_log::TENANT_ID, ms.tenant_rid())
            .set(sms_log::USER_ID, self.shoppers[s].rid)
            .set(sms_log::TEMPLATE_ID, template)
            .set(sms_log::RECIPIENT_PHONE, phone)
            .set(sms_log::FROM_NUMBER, people::phone(rng, &ms.m.country))
            .set(sms_log::BODY, body)
            .set(sms_log::PROVIDER, "twsms-1")
            .set(sms_log::PROVIDER_MESSAGE_ID, format!("SM{}", rng.hex(32)))
            .set(sms_log::STATUS, if ok { "success" } else { "failed" })
            .set(sms_log::ERROR_MESSAGE, if ok { V::Null } else { V::Static("30003: Unreachable destination handset") })
            .set(sms_log::SEGMENTS, segments)
            .set(sms_log::SENT_AT, V::Ts(at + rng.int(1, 10) * MICROS_PER_SEC))
            .set(sms_log::CREATED_AT, V::Ts(at));
        self.emit_at(sms_log::T, at, r);
    }

    /// Deliver an event to every merchant webhook subscribed to it, with retries.
    fn webhook(&mut self, rng: &mut Rng, ms: &MerchantSim, event: &'static str, payload: &str, at: Ts) {
        let end = time::end_ts();
        for wh in &ms.webhooks {
            if !wh.events.contains(&event) {
                continue;
            }
            let body = format!(r#"{{"id":"evt_{}","type":"{event}","created_at":"{}","data":{payload}}}"#, rng.alnum(24), iso(at));
            let mut t = at + rng.int(1, 5) * MICROS_PER_SEC;
            for attempt in 1..=5 {
                if t > end {
                    break;
                }
                let fail = rng.chance(wh.failure_rate) || crate::sim::stories::platform_down(t);
                let (code, resp, ms_) = if fail {
                    *rng.pick(&[(500, r#"{"error":"internal server error"}"#, 30000), (502, "Bad Gateway", 120), (504, "Gateway Timeout", 30000), (429, r#"{"error":"rate limited"}"#, 40)])
                } else {
                    (200, r#"{"received":true}"#, 0)
                };
                let duration = if fail { ms_ } else { rng.int(40, 900) };
                let last = !fail || attempt == 5;
                let mut r = Row::new(webhook_deliveries::NCOLS);
                r.set(webhook_deliveries::TENANT_ID, ms.tenant_rid())
                    .set(webhook_deliveries::WEBHOOK_ID, wh.rid)
                    .set(webhook_deliveries::EVENT_TYPE, event)
                    .set(webhook_deliveries::STATUS, if !fail { "success" } else if last { "failed" } else { "retrying" })
                    .set(webhook_deliveries::ATTEMPT, attempt)
                    .set(webhook_deliveries::RESPONSE_CODE, code)
                    .set(webhook_deliveries::REQUEST_BODY, V::Json(body.clone()))
                    .set(webhook_deliveries::RESPONSE_BODY, resp)
                    .set(webhook_deliveries::DURATION_MS, V::Int(duration))
                    .set(webhook_deliveries::DELIVERED_AT, if fail { V::Null } else { V::Ts(t + duration * 1000) })
                    .set(webhook_deliveries::CREATED_AT, V::Ts(t));
                self.emit_at(webhook_deliveries::T, t, r);
                if last {
                    break;
                }
                t += [60, 300, 1800, 7200][attempt - 1] * MICROS_PER_SEC;
            }
        }
    }


    #[allow(clippy::too_many_arguments)]
    fn ledger(&mut self, ms: &MerchantSim, rng: &mut Rng, payment: Rid, at: Ts, lines: &[(Rid, &'static str, i64)], desc: &str) {
        self.ledger_p(ms, rng, Some(payment), at, lines, desc)
    }

    #[allow(clippy::too_many_arguments)]
    fn ledger_p(&mut self, ms: &MerchantSim, rng: &mut Rng, payment: Option<Rid>, at: Ts, lines: &[(Rid, &'static str, i64)], desc: &str) {
        if at > time::end_ts() {
            return;
        }
        let group = rng.uuid();
        for (acct, dir, amount) in lines {
            if *amount <= 0 {
                continue;
            }
            let mut r = Row::new(ledger_entries::NCOLS);
            r.set(ledger_entries::TENANT_ID, ms.tenant_rid())
                .set(ledger_entries::LEDGER_ACCOUNT_ID, *acct)
                .set(ledger_entries::ENTRY_GROUP, V::Uuid(group))
                .set(ledger_entries::DIRECTION, *dir)
                .set(ledger_entries::AMOUNT, V::Money(*amount))
                .set(ledger_entries::CURRENCY_CODE, ms.m.currency.clone())
                .set(ledger_entries::PAYMENT_ID, V::opt_ref(payment))
                .set(ledger_entries::DESCRIPTION, desc.to_string())
                .set(ledger_entries::OCCURRED_AT, V::Ts(at))
                .set(ledger_entries::CREATED_AT, V::Ts(at + rng.int(1, 30) * MICROS_PER_SEC));
            self.emit_at(ledger_entries::T, at, r);
        }
    }

    fn status_change(&mut self, tenant: Rid, order: Rid, from: Option<&'static str>, to: &'static str, at: Ts) {
        let mut r = Row::new(order_status_history::NCOLS);
        r.set(order_status_history::TENANT_ID, tenant)
            .set(order_status_history::ORDER_ID, order)
            .set(order_status_history::FROM_STATUS, V::from(from))
            .set(order_status_history::TO_STATUS, to)
            .set(order_status_history::CREATED_AT, V::Ts(at));
        self.emit_at(order_status_history::T, at, r);
    }

    /// Next merchant working time (Mon-Fri 08:00-17:00 local; big merchants also Saturday).
    fn next_working_time(&self, ms: &MerchantSim, t: Ts, rng: &mut Rng) -> Ts {
        use chrono::Datelike;
        let mut local = ms.tz.utc_to_local(t);
        for _ in 0..10 {
            let day = local.div_euclid(MICROS_PER_DAY);
            let into = local.rem_euclid(MICROS_PER_DAY);
            let date = chrono::DateTime::from_timestamp_micros(day * MICROS_PER_DAY).unwrap().date_naive();
            let wd = date.weekday().num_days_from_monday();
            let works = wd < 5 || (wd == 5 && ms.m.size_rank <= 10);
            if works && into < 17 * MICROS_PER_HOUR {
                let start = into.max(8 * MICROS_PER_HOUR + rng.int(0, 90) * MICROS_PER_MIN);
                return ms.tz.local_to_utc(date, start);
            }
            local = (day + 1) * MICROS_PER_DAY;
        }
        t
    }

    #[allow(clippy::too_many_arguments)]
    fn fulfill(&mut self, rng: &mut Rng, ms: &MerchantSim, _p: &Params, order: Rid, items: &[Item], item_rids: &[Rid], dest: usize, plan: &Plan) {
        let w = world();
        let tenant = ms.tenant_rid();
        let end = time::end_ts();
        let (packed, shipped, delivered) = (plan.packed, plan.shipped, plan.delivered);
        let (domestic, express, failed_attempt) = (plan.domestic, plan.express, plan.failed_attempt);
        let carrier = plan.carrier.clone();
        let wh = &ms.warehouses[0];
        let fstatus = if delivered <= end { "delivered" } else if shipped <= end { "shipped" } else { "packed" };
        let mut r = Row::new(fulfillments::NCOLS);
        r.set(fulfillments::TENANT_ID, tenant)
            .set(fulfillments::ORDER_ID, order)
            .set(fulfillments::WAREHOUSE_ID, wh.rid)
            .set(fulfillments::STATUS, fstatus)
            .set(fulfillments::REFERENCE, format!("FUL-{}", rng.digits(8)))
            .set(fulfillments::PACKED_AT, V::Ts(packed))
            .set(fulfillments::SHIPPED_AT, if shipped <= end { V::Ts(shipped) } else { V::Null })
            .set(fulfillments::DELIVERED_AT, if delivered <= end { V::Ts(delivered) } else { V::Null })
            .set(fulfillments::CREATED_AT, V::Ts(packed - 30 * MICROS_PER_MIN))
            .set(fulfillments::UPDATED_AT, V::Ts(delivered.min(end).max(packed)));
        let Some(ful) = self.emit_at(fulfillments::T, packed - 30 * MICROS_PER_MIN, r) else { return };
        for (it, oi) in items.iter().zip(item_rids) {
            let mut r = Row::new(fulfillment_items::NCOLS);
            r.set(fulfillment_items::TENANT_ID, tenant)
                .set(fulfillment_items::FULFILLMENT_ID, ful)
                .set(fulfillment_items::ORDER_ITEM_ID, *oi)
                .set(fulfillment_items::QUANTITY, V::Int(it.qty))
                .set(fulfillment_items::CREATED_AT, V::Ts(packed - 30 * MICROS_PER_MIN))
                .set(fulfillment_items::UPDATED_AT, V::Ts(packed - 30 * MICROS_PER_MIN));
            self.emit_at(fulfillment_items::T, packed - 30 * MICROS_PER_MIN, r);
        }
        if shipped > end {
            return;
        }
        let d = time::day_of_ts(shipped) as Day;
        *self.outbox.entry(d).or_default().shipments.entry(crate::world::carrier_index(&carrier)).or_default() += 1;
        for it in items {
            self.outbox.entry(d).or_default().stock.push((it.pidx, it.vidx, StockOp::Shipped, it.qty));
            if let Some(slot) = ms.stock_slot(it.pidx, it.vidx) {
                let mut r = Row::new(stock_movements::NCOLS);
                r.set(stock_movements::TENANT_ID, tenant)
                    .set(stock_movements::VARIANT_ID, it.variant)
                    .set(stock_movements::STOCK_LOCATION_ID, slot.location)
                    .set(stock_movements::LOT_ID, V::opt_ref(slot.lot))
                    .set(stock_movements::KIND, "shipment")
                    .set(stock_movements::QUANTITY, V::Int(-it.qty))
                    .set(stock_movements::REFERENCE_TYPE, "order")
                    .set(stock_movements::REFERENCE_ID, order)
                    .set(stock_movements::OCCURRED_AT, V::Ts(shipped))
                    .set(stock_movements::CREATED_AT, V::Ts(shipped + rng.int(1, 60) * MICROS_PER_SEC));
                self.emit_at(stock_movements::T, shipped, r);
            }
        }
        let weight: i64 = items.iter().map(|i| i.weight_g * i.qty).sum::<i64>() + 150;
        let cost = 350 + weight / 40 + if domestic { 0 } else { 800 } + if express { 600 } else { 0 };
        let carrier_slug = people::slugify(&carrier).replace('-', "");
        let tracking = format!("{}{}{}", people::ascii_fold(&carrier).split(' ').filter(|x| !x.is_empty()).map(|x| x[..1].to_uppercase()).collect::<String>(), rng.digits(11), w.geo.countries[ms.country].iso2);
        let mut r = Row::new(shipments::NCOLS);
        r.set(shipments::TENANT_ID, tenant)
            .set(shipments::FULFILLMENT_ID, ful)
            .set(shipments::CARRIER, carrier.clone())
            .set(shipments::SERVICE_LEVEL, if express { "express" } else if rng.chance(0.04) { "economy" } else { "standard" })
            .set(shipments::TRACKING_NUMBER, tracking.clone())
            .set(shipments::TRACKING_URL, format!("https://track.{carrier_slug}.com/{tracking}"))
            .set(shipments::SHIPPING_COST, V::Money(cost))
            .set(shipments::CURRENCY_CODE, ms.m.currency.clone())
            .set(shipments::WEIGHT_GRAMS, V::Int(weight))
            .set(shipments::SHIPPED_AT, V::Ts(shipped))
            .set(shipments::DELIVERED_AT, if delivered <= end { V::Ts(delivered) } else { V::Null })
            .set(shipments::CREATED_AT, V::Ts(packed))
            .set(shipments::UPDATED_AT, V::Ts(delivered.min(end)));
        let ship = self.emit_at(shipments::T, packed, r).unwrap();
        let dest_city = &w.geo.countries[dest].regions[0].cities[0].name;
        let mut ev: Vec<(&'static str, &'static str, String, Ts)> = vec![
            ("label_created", "Shipping label created", wh.city.clone(), packed),
            ("picked_up", "Parcel picked up by carrier", wh.city.clone(), shipped),
            ("in_transit", "In transit", format!("{} hub", wh.city), shipped + (delivered - shipped) / 3),
        ];
        if plan.congestion > 1.5 {
            ev.push(("exception", "Delayed: exceptionally high volumes in our network", format!("{} hub", wh.city), shipped + (delivered - shipped) / 2));
        }
        if !domestic {
            ev.push(("arrived_at_destination", "Arrived in destination country", dest_city.clone(), shipped + (delivered - shipped) * 2 / 3));
        }
        if failed_attempt {
            ev.push(("delivery_attempted", "Delivery attempted - recipient not available", dest_city.clone(), delivered - MICROS_PER_DAY));
        }
        ev.push(("out_for_delivery", "Out for delivery", dest_city.clone(), delivered - rng.int(2, 5) * MICROS_PER_HOUR));
        ev.push(("delivered", "Delivered", dest_city.clone(), delivered));
        for (st, desc, loc, at) in ev {
            if at > end {
                break;
            }
            let mut r = Row::new(shipment_tracking::NCOLS);
            r.set(shipment_tracking::TENANT_ID, tenant)
                .set(shipment_tracking::SHIPMENT_ID, ship)
                .set(shipment_tracking::STATUS, st)
                .set(shipment_tracking::DESCRIPTION, desc)
                .set(shipment_tracking::LOCATION, loc)
                .set(shipment_tracking::OCCURRED_AT, V::Ts(at))
                .set(shipment_tracking::CREATED_AT, V::Ts(at + rng.int(1, 300) * MICROS_PER_SEC));
            self.emit_at(shipment_tracking::T, at, r);
        }
        self.status_change(tenant, order, Some("paid"), "fulfilled", shipped);
    }

    fn payment_method(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, at: Ts) -> (Rid, &'static str, String) {
        if let Some(pm) = &self.shoppers[s].payment_method {
            if rng.chance(0.9) {
                return pm.clone();
            }
        }
        let w = world();
        let tenant = ms.tenant_rid();
        let g = &ms.m.gateways[Weighted::new(ms.m.gateways.iter().map(|g| g.share)).sample(rng)].name;
        let iso = &w.geo.countries[self.shoppers[s].country].iso2;
        let kind: &'static str = match g.as_str() {
            "Moravell" => "credit",
            "Pursely" => "wallet",
            _ if ["NL", "BE", "DE"].contains(&iso.as_str()) && rng.chance(0.35) => "bank_transfer",
            _ => "card",
        };
        let mut brand = if kind == "card" { Some(["visa", "mastercard", "amex", "maestro"][Weighted::new([0.55, 0.35, 0.06, 0.04]).sample(rng)]) } else { None };
        let mut last4 = rng.digits(4);
        let kind = if self.shoppers[s].fraud { "card" } else { kind };
        if self.shoppers[s].fraud {
            // the ring cycles through a few cards
            let ring = self.ring(rng, ms);
            let c = ring.cards[rng.below(ring.cards.len())].clone();
            brand = Some(c.0);
            last4 = c.1;
        }
        let mut r = Row::new(payment_methods::NCOLS);
        r.set(payment_methods::TENANT_ID, tenant)
            .set(payment_methods::USER_ID, self.shoppers[s].rid)
            .set(payment_methods::KIND, kind)
            .set(payment_methods::GATEWAY, g.clone())
            .set(payment_methods::GATEWAY_TOKEN, format!("tok_{}", rng.alnum(28)))
            .set(payment_methods::BRAND, brand.map(String::from))
            .set(payment_methods::LAST4, if kind == "card" { V::Str(last4) } else { V::Null })
            .set(payment_methods::EXP_MONTH, if kind == "card" { V::Int(rng.int(1, 12)) } else { V::Null })
            .set(payment_methods::EXP_YEAR, if kind == "card" { V::Int(rng.int(2026, 2031)) } else { V::Null })
            .set(payment_methods::IS_DEFAULT, self.shoppers[s].payment_method.is_none())
            .set(payment_methods::BILLING_ADDRESS_ID, self.shoppers[s].address)
            .set(payment_methods::CREATED_AT, V::Ts(at - 30 * MICROS_PER_SEC))
            .set(payment_methods::UPDATED_AT, V::Ts(at - 30 * MICROS_PER_SEC));
        // long-lived shopper state: id from today, so any later visit can reference it
        let rid = self.chunk.emit(payment_methods::T, self.chunk.day, r);
        let pm = (rid, kind, g.clone());
        if self.shoppers[s].payment_method.is_none() {
            self.shoppers[s].payment_method = Some(pm.clone());
        }
        pm
    }
}

#[derive(Clone, Copy)]
enum Cause {
    Wismo,
    FailedDelivery,
    Damaged,
    ReturnQuestion,
    RefundRejected,
    PaymentFailed,
    ProductQuestion,
    QualityComplaint,
    OutOfStock,
    NotReceived,
    AccountAccess,
}

/// The planned life of a paid order after checkout.
struct Plan {
    /// delivery date promised at checkout
    promised: Ts,
    packed: Ts,
    shipped: Ts,
    delivered: Ts,
    carrier: String,
    express: bool,
    failed_attempt: bool,
    domestic: bool,
    /// days of delay in the carrier's network (peaks, S1)
    congestion: f64,
}

/// A planned return: which order lines (index, quantity) and when each step happens.
struct ReturnPlan {
    /// (order line, quantity returned, reason)
    lines: Vec<(usize, i64, &'static str)>,
    reason: &'static str,
    rejected: bool,
    requested: Ts,
    approved: Ts,
    received: Ts,
    refunded: Ts,
    /// payment_refunds.reason
    refund_reason: &'static str,
}

/// What happened to one order line, compared with what the shopper expected.
struct ItemExp {
    /// realised quality minus the quality the price led them to expect
    q_gap: f64,
    /// chosen size + product sizing bias - own size (in sizes); None if not sized
    fit_err: Option<f64>,
    /// stopped working (S5)
    defect: bool,
    damaged: bool,
    wrong_item: bool,
    regret: bool,
}

struct Experience {
    late_days: f64,
    items: Vec<ItemExp>,
}

impl Experience {
    /// Overall experience of one line on a logit-ish scale (0 = as expected).
    fn score(&self, i: usize, patience: f64) -> f64 {
        let e = &self.items[i];
        let misfit = e.fit_err.is_some_and(|f| f.abs() > 0.65);
        0.25 + 0.6 * e.q_gap - 0.45 * (self.late_days / patience).min(4.0) - if e.damaged || e.defect { 2.0 } else { 0.0 } - if misfit { 1.0 } else { 0.0 } - if e.wrong_item { 1.5 } else { 0.0 }
    }
}

/// How readily a vertical's products are returned at all (hygiene, consumables, B2B processes).
fn returnability(vertical: &str) -> f64 {
    match vertical {
        "food_coffee" => 0.1,
        "pet_supplies" => 0.25,
        "beauty" | "books_stationery" => 0.5,
        "b2b_industrial" | "b2b_office" => 0.4,
        _ => 1.0,
    }
}

/// Buyer's remorse base rate by vertical.
fn regret_rate(vertical: &str) -> f64 {
    match vertical {
        "apparel_footwear" => 0.04,
        "consumer_electronics" | "sports_outdoor" | "jewelry_accessories" => 0.035,
        "home_living" => 0.025,
        _ => 0.01,
    }
}


fn review_text(rng: &mut Rng, rating: i64, product: &str, vertical: &str, late: bool, returned: bool) -> (V, V) {
    let titles: &[&str] = match rating {
        5 => &["Love it!", "Perfect", "Excellent quality", "Exactly as described", "Highly recommend", "Best purchase this year"],
        4 => &["Very good", "Really nice", "Great, with one small issue", "Happy with it", "Good value"],
        3 => &["It's okay", "Average", "Mixed feelings", "Does the job"],
        2 => &["Disappointed", "Not great", "Expected more"],
        _ => &["Terrible", "Do not buy", "Waste of money", "Very poor quality"],
    };
    let title = if rng.chance(0.85) { V::Static(*rng.pick(titles)) } else { V::Null };
    if rng.chance(0.25) {
        return (title, V::Null);
    }
    let kind = product.rsplit(' ').next().unwrap_or(product).to_lowercase();
    let mut parts: Vec<String> = Vec::new();
    parts.push(match rating {
        5 => format!("Really happy with this {kind}."),
        4 => format!("Nice {kind}, does what it promises."),
        3 => format!("The {kind} is fine but nothing special."),
        2 => format!("Not convinced by this {kind}."),
        _ => format!("Very disappointed with this {kind}."),
    });
    if vertical == "apparel_footwear" && rng.chance(0.5) {
        parts.push(rng.pick(&["Fits true to size.", "Runs a bit small, size up.", "Runs large.", "Lovely fabric.", "Colour is slightly different from the photos."]).to_string());
    }
    if late {
        parts.push(rng.pick(&["Delivery took much longer than promised.", "Arrived over a week late.", "Shipping was really slow."]).to_string());
    } else if rng.chance(0.3) {
        parts.push(rng.pick(&["Fast delivery.", "Arrived quickly and well packaged.", "Delivery was on time."]).to_string());
    }
    if returned {
        parts.push(rng.pick(&["Sent it back.", "Returned it, refund was quick.", "Had to return it."]).to_string());
    }
    (title, V::Str(parts.join(" ")))
}

/// `t` plus `minutes` of merchant business time (Mon-Fri 08:00-17:00 local).
fn business_add(ms: &MerchantSim, t: Ts, minutes: i64) -> Ts {
    use chrono::Datelike;
    let mut left = minutes * MICROS_PER_MIN;
    let mut local = ms.tz.utc_to_local(t);
    for _ in 0..400 {
        let day = local.div_euclid(MICROS_PER_DAY);
        let into = local.rem_euclid(MICROS_PER_DAY);
        let date = chrono::DateTime::from_timestamp_micros(day * MICROS_PER_DAY).unwrap().date_naive();
        let (open, close) = (8 * MICROS_PER_HOUR, 17 * MICROS_PER_HOUR);
        if date.weekday().num_days_from_monday() < 5 && into < close {
            let start = into.max(open);
            let avail = close - start;
            if left <= avail {
                return ms.tz.local_to_utc(date, start + left);
            }
            left -= avail;
        }
        local = (day + 1) * MICROS_PER_DAY;
    }
    t + minutes * MICROS_PER_MIN
}

pub(crate) fn iso_date(ts: Ts) -> String {
    chrono::DateTime::from_timestamp_micros(ts).unwrap().format("%Y-%m-%d").to_string()
}

fn iso(ts: Ts) -> String {
    chrono::DateTime::from_timestamp_micros(ts).unwrap().format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string()
}
