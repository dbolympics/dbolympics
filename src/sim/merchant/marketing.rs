//! Merchant side of marketing: email templates, segments, landing pages, paid media, the
//! loyalty programme, and the email calendar (newsletters, promotion announcements, win-back
//! mails, subject-line tests). The sends themselves happen in the shopper chunks, which hold
//! the recipients and decide opens, clicks and unsubscribes.
//!
//! Paid media (search and social) runs as quarterly flights whose budgets come from drivers,
//! not from a fixed number (docs/SIMULATOR.md): the merchant's recent revenue, a hidden
//! marketing intensity, its vertical's channel mix, the season it plans for and how the
//! previous flight paid back. Spend in turn sets how many visitors arrive through paid
//! channels, with diminishing returns and pricier clicks in the peak.

use std::collections::{BTreeMap, VecDeque};

use chrono::Datelike;

use super::{DayOut, MerchantSim};
use crate::engine::DHandle;
use crate::rng::Rng;
use crate::sim::{calendar, people};
use crate::tables::*;
use crate::time::{self, Day, MICROS_PER_DAY, MICROS_PER_HOUR, Ts};
use crate::value::{Rid, Row, V};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SegmentKind {
    All = 0,
    Vip = 1,
    Lapsed = 2,
    New = 3,
    /// S6: subscribers who cancelled in spring 2025
    WinBack = 4,
}

const SEGMENTS: [(SegmentKind, &str, &str); 4] = [
    (SegmentKind::All, "All subscribers", r#"{"all":[{"field":"marketing_opt_in","op":"eq","value":true}]}"#),
    (SegmentKind::Vip, "VIP customers", r#"{"all":[{"field":"orders_count","op":"gte","value":3},{"field":"marketing_opt_in","op":"eq","value":true}]}"#),
    (SegmentKind::Lapsed, "Lapsed 90 days", r#"{"all":[{"field":"last_order_days_ago","op":"gt","value":90},{"field":"marketing_opt_in","op":"eq","value":true}]}"#),
    (SegmentKind::New, "New customers (30 days)", r#"{"all":[{"field":"first_order_days_ago","op":"lte","value":30}]}"#),
];

pub const LANDING: [(&str, &str); 3] = [("sale", "Sale"), ("new-in", "New in"), ("gift-guide", "Gift guide")];

/// A marketing email going out today, as seen by the shopper chunks.
#[derive(Clone)]
pub struct Send {
    pub campaign: Rid,
    pub template: Rid,
    pub segment: SegmentKind,
    pub utm: String,
    pub at: Ts,
    /// announces a running promotion (clicks convert better)
    pub promo: bool,
    /// subject-line test: (test, [control, variant], open-rate multipliers)
    pub ab: Option<(Rid, [Rid; 2], [f64; 2])>,
    /// index into LANDING
    pub landing: usize,
    /// S6: the win-back offer (clicks often restart the subscription)
    pub winback: bool,
}

#[derive(Default)]
pub struct Marketing {
    pub templates: Vec<Rid>,
    pub segments: Vec<DHandle>,
    pub landing: Vec<DHandle>,
    /// loyalty programme and points per unit of currency
    pub loyalty: Option<(Rid, f64)>,
    pub sends_today: Vec<Send>,
    /// the running paid flights: (campaign, utm_campaign) for [paid search, paid social]
    pub paid: [Option<(Rid, String)>; 2],
    /// today's acquisition channel weights [organic, paid search, social, paid social,
    /// referral, direct], and the volume effect of paid spend on new customers
    pub acq_mix: [f64; 6],
    pub paid_volume: f64,
    /// hidden drivers of paid media
    drivers: PaidDrivers,
    flights: [Option<Flight>; 2],
    planned: [Option<Flight>; 2],
    /// per channel: budget scale learned from past return on ad spend
    scale: [f64; 2],
    /// daily revenue (major units) of the last 91 days, as the merchant sees it
    revenue: VecDeque<f64>,
    /// expected daily revenue at the end-of-window level, before there is a history
    est_daily_revenue: f64,
    /// S7: the influencer campaign
    pub influencer: Option<(Rid, String)>,
    cadence_days: usize,
    seq: u32,
    segment_counts: [i64; 5],
    landing_views: Vec<i64>,
    /// campaign -> its utm link (click_count is counted from clicks)
    utm: BTreeMap<Rid, (DHandle, i64)>,
}

impl Marketing {
    pub fn new(est_daily_revenue: f64) -> Marketing {
        Marketing { est_daily_revenue, ..Default::default() }
    }
}

/// What sets a merchant's paid media (hidden, never stored).
#[derive(Default, Clone, Copy)]
struct PaidDrivers {
    /// paid spend as a share of revenue
    intensity: f64,
    /// share of the paid budget going to social (the rest goes to search)
    social: f64,
    /// return on ad spend the merchant aims for (thin margins need more)
    target: f64,
    /// naming and rounding habits
    style: usize,
}

/// One paid flight (a quarter, or the rest of the quarter after joining).
struct Flight {
    campaign: Rid,
    slug: String,
    budget: f64,
    start: Day,
    /// exclusive
    end: Day,
    /// last-click revenue observed so far
    revenue: f64,
}

/// Base acquisition weights [organic, paid search, social, paid social, referral, direct].
pub const BASE_MIX: [f64; 6] = [28.0, 22.0, 14.0, 10.0, 8.0, 18.0];
/// typical spend per channel as a share of revenue (where paid traffic is at its base weight)
const REF_SPEND: [f64; 2] = [0.035, 0.025];

fn quarter_start(d: chrono::NaiveDate) -> chrono::NaiveDate {
    chrono::NaiveDate::from_ymd_opt(d.year(), (d.month0() / 3) * 3 + 1, 1).unwrap()
}

fn next_quarter(d: chrono::NaiveDate) -> chrono::NaiveDate {
    let q = quarter_start(d);
    if q.month() == 10 { chrono::NaiveDate::from_ymd_opt(q.year() + 1, 1, 1).unwrap() } else { chrono::NaiveDate::from_ymd_opt(q.year(), q.month() + 3, 1).unwrap() }
}

/// How people round a budget in their own currency: to a tenth, a quarter or a half of its
/// order of magnitude, depending on habit (style).
fn nice(x: f64, style: usize) -> f64 {
    let magnitude = libm::pow(10.0, libm::floor(libm::log10(x.max(1.0))));
    let step = magnitude * [0.1, 0.25, 0.5][style.min(2)];
    (x / step).round().max(1.0) * step
}

/// Price of a click relative to the base: auctions are dearer in the peak and every year.
fn cpc_index(d: chrono::NaiveDate) -> f64 {
    let season = match d.month() {
        11 | 12 => 1.35,
        10 => 1.1,
        _ => 1.0,
    };
    season * libm::pow(1.06, (d.year() - 2023) as f64 + d.ordinal0() as f64 / 365.0)
}

impl MerchantSim {
    fn marketer(&self) -> Option<Rid> {
        self.staff.iter().find(|s| s.role == "marketing").or(self.staff.first()).map(|s| s.user.rid)
    }

    #[allow(clippy::too_many_arguments)]
    fn utm_link(&mut self, day: Day, ts: Ts, campaign: Rid, landing: Option<usize>, slug: &str, source: &str, medium: &str) {
        let path = landing.map_or("/".to_string(), |l| format!("/pages/{}", LANDING[l].0));
        let mut r = Row::new(utm_links::NCOLS);
        r.set(utm_links::TENANT_ID, self.tenant_rid())
            .set(utm_links::CAMPAIGN_ID, campaign)
            .set(utm_links::LANDING_PAGE_ID, V::opt_ref(landing.map(|l| self.mkt.landing[l].rid)))
            .set(utm_links::SLUG, slug.to_string())
            .set(utm_links::TARGET_URL, format!("https://{}{path}?utm_source={source}&utm_medium={medium}&utm_campaign={slug}", self.domain))
            .set(utm_links::UTM_SOURCE, source.to_string())
            .set(utm_links::UTM_MEDIUM, medium.to_string())
            .set(utm_links::UTM_CAMPAIGN, slug.to_string())
            .set(utm_links::CLICK_COUNT, V::Int(0))
            .set(utm_links::CREATED_AT, V::Ts(ts))
            .set(utm_links::UPDATED_AT, V::Ts(ts));
        let h = self.chunk.emit_deferred(utm_links::T, day, r);
        self.mkt.utm.insert(campaign, (h, 0));
    }

    pub(super) fn setup_marketing(&mut self, day: Day, ts: Ts, rng: &mut Rng) {
        let tenant = self.tenant_rid();
        for (i, name) in ["Weekly newsletter", "New arrivals", "Sale announcement", "Back in stock", "Win-back", "Seasonal edit"].iter().enumerate() {
            if i > 4 && self.m.size_rank > 60 {
                break;
            }
            let mut r = Row::new(email_templates::NCOLS);
            r.set(email_templates::TENANT_ID, tenant)
                .set(email_templates::NAME, *name)
                .set(email_templates::SUBJECT, format!("{name} | {}", self.m.name))
                .set(email_templates::BODY_HTML, format!("<html><body><h1>{{{{headline}}}}</h1><p>{{{{intro}}}}</p><a href=\"{{{{cta_url}}}}\">Shop now</a><p>{}</p><p><a href=\"{{{{unsubscribe_url}}}}\">Unsubscribe</a></p></body></html>", self.m.name))
                .set(email_templates::BODY_TEXT, if rng.chance(0.7) { V::Static("{{headline}}\n\n{{intro}}\n\nShop now: {{cta_url}}\n\nUnsubscribe: {{unsubscribe_url}}") } else { V::Null })
                .set(email_templates::FROM_NAME, self.m.name.clone())
                .set(email_templates::FROM_EMAIL, format!("news@{}", self.domain))
                .set(email_templates::IS_ACTIVE, true)
                .set(email_templates::CREATED_AT, V::Ts(ts))
                .set(email_templates::UPDATED_AT, V::Ts(ts));
            self.mkt.templates.push(self.chunk.emit(email_templates::T, day, r));
        }
        for (_, name, rules) in SEGMENTS {
            let mut r = Row::new(segments::NCOLS);
            r.set(segments::TENANT_ID, tenant)
                .set(segments::NAME, name)
                .set(segments::DESCRIPTION, if rng.chance(0.5) { V::Str(format!("{name} (refreshed nightly)")) } else { V::Null })
                .set(segments::RULES, V::Json(rules.to_string()))
                .set(segments::IS_DYNAMIC, true)
                .set(segments::MEMBER_COUNT, V::Int(0))
                .set(segments::CREATED_AT, V::Ts(ts))
                .set(segments::UPDATED_AT, V::Ts(ts));
            self.mkt.segments.push(self.chunk.emit_deferred(segments::T, day, r));
        }
        if crate::sim::stories::has(self.m, "S6") {
            let at = time::ts_of_date(chrono::NaiveDate::from_ymd_opt(2025, 6, 9).unwrap()) + 10 * MICROS_PER_HOUR;
            let mut r = Row::new(segments::NCOLS);
            r.set(segments::TENANT_ID, tenant)
                .set(segments::NAME, "Cancelled subscribers (spring 2025)")
                .set(segments::DESCRIPTION, "Subscriptions cancelled since March 2025, for the win-back")
                .set(segments::RULES, V::Json(r#"{"all":[{"field":"subscription.canceled_at","op":"gte","value":"2025-03-01"},{"field":"marketing_opt_in","op":"eq","value":true}]}"#.to_string()))
                .set(segments::IS_DYNAMIC, false)
                .set(segments::MEMBER_COUNT, V::Int(0))
                .set(segments::CREATED_AT, V::Ts(at))
                .set(segments::UPDATED_AT, V::Ts(at));
            let d = time::day_of_ts(at).max(day as i64) as Day;
            self.mkt.segments.push(self.chunk.emit_deferred(segments::T, d, r));
        }
        for (slug, title) in LANDING {
            let mut r = Row::new(landing_pages::NCOLS);
            r.set(landing_pages::TENANT_ID, tenant)
                .set(landing_pages::SLUG, slug)
                .set(landing_pages::TITLE, format!("{title} | {}", self.m.name))
                .set(landing_pages::URL, format!("https://{}/pages/{slug}", self.domain))
                .set(landing_pages::CONTENT_HTML, format!("<section class=\"hero\"><h1>{title}</h1></section>"))
                .set(landing_pages::IS_PUBLISHED, true)
                .set(landing_pages::PUBLISHED_AT, V::Ts(ts))
                .set(landing_pages::VIEW_COUNT, V::Int(0))
                .set(landing_pages::CREATED_AT, V::Ts(ts))
                .set(landing_pages::UPDATED_AT, V::Ts(ts));
            self.mkt.landing.push(self.chunk.emit_deferred(landing_pages::T, day, r));
            self.mkt.landing_views.push(0);
        }
        // paid media: hidden drivers, then the first flights for the rest of this quarter
        let (social, intensity) = match self.m.vertical.as_str() {
            "beauty" => (0.6, 0.075),
            "apparel_footwear" | "jewelry_accessories" => (0.5, 0.065),
            "food_coffee" => (0.45, 0.06),
            "sports_outdoor" | "pet_supplies" => (0.4, 0.055),
            "home_living" => (0.35, 0.05),
            "consumer_electronics" => (0.25, 0.04),
            "b2b_industrial" | "b2b_office" => (0.05, 0.012),
            _ => (0.35, 0.05),
        };
        let margin = 1.0 - super::inventory::cost_ratio(&self.m.vertical);
        self.mkt.drivers = PaidDrivers {
            intensity: intensity * rng.lognormal(0.0, 0.45),
            social: (social + 0.08 * rng.normal()).clamp(0.02, 0.85),
            target: 1.3 / margin * rng.lognormal(0.0, 0.15),
            style: rng.below(3),
        };
        self.mkt.scale = [1.0, 1.0];
        let date = time::date_of(day);
        // merchants already here when the history starts planned Q1 2023 in December
        let plan_ts = if date == time::start_date() && time::parse_date(&self.m.joined_on) < date {
            self.tz.local_to_utc(date - chrono::Duration::days(14), rng.int(9, 17) * MICROS_PER_HOUR + rng.int(0, 59) * 60_000_000)
        } else {
            ts
        };
        self.plan_flights(day, plan_ts, day, time::day_of(next_quarter(date)) as Day, rng);
        self.mkt.flights = [self.mkt.planned[0].take(), self.mkt.planned[1].take()];
        self.mkt.paid = [0, 1].map(|c| self.mkt.flights[c].as_ref().map(|f| (f.campaign, f.slug.clone())));
        // a third of the consumer merchants run a points programme
        if !self.b2b && (crate::rng::hash_str(&format!("{}|loyalty", self.m.slug)) % 3) == 0 {
            let ppc = if self.price_level > 5.0 { 0.1 } else { 1.0 };
            let mut r = Row::new(loyalty_programs::NCOLS);
            r.set(loyalty_programs::TENANT_ID, tenant)
                .set(loyalty_programs::NAME, format!("{} Rewards", self.m.name))
                .set(loyalty_programs::DESCRIPTION, V::Static("Earn points on every order (credited 30 days after delivery) and redeem 500 points for a reward voucher."))
                .set(loyalty_programs::POINTS_PER_CURRENCY, V::Dec((ppc * 10000.0) as i128, 4))
                .set(loyalty_programs::CURRENCY_CODE, self.m.currency.clone())
                .set(loyalty_programs::IS_ACTIVE, true)
                .set(loyalty_programs::STARTS_AT, V::Ts(ts))
                .set(loyalty_programs::CREATED_AT, V::Ts(ts))
                .set(loyalty_programs::UPDATED_AT, V::Ts(ts));
            self.mkt.loyalty = Some((self.chunk.emit(loyalty_programs::T, day, r), ppc));
        }
        self.mkt.cadence_days = if self.m.size_rank <= 15 { 7 } else if self.m.size_rank <= 50 { 14 } else { 28 };
    }

    /// The revenue expected per day of `a..b` before there is a history: the end-of-window guess at the merchant's
    /// level and season of those days (a merchant that joins mid-window starts far below its end level).
    fn est_revenue(&self, a: Day, b: Day) -> f64 {
        let n = time::num_days();
        let days = (a..b.max(a + 1)).map(|x| x.min(n - 1));
        let sum: f64 = days.map(|x| calendar::merchant_level(self.m, self.growth, x) * calendar::demand(&self.m.vertical, self.vertical, self.b2b, x)).sum();
        self.mkt.est_daily_revenue * sum / (b - a).max(1) as f64
    }

    /// Plan the paid flights for `start..end` on `day` (a quarter, two weeks ahead; or the rest
    /// of the quarter when the merchant joins). Judges the running flights first.
    fn plan_flights(&mut self, day: Day, ts: Ts, start: Day, end: Day, rng: &mut Rng) {
        let d = self.mkt.drivers;
        let n = time::num_days();
        let cut = self.churn_day.filter(|c| *c < end);
        let end = cut.unwrap_or(end);
        self.mkt.planned = [None, None];
        if end <= start {
            return;
        }
        // the revenue the merchant expects: its recent revenue, adjusted for the season ahead
        let have = self.mkt.revenue.len();
        let daily = if have >= 28 { self.mkt.revenue.iter().sum::<f64>() / have as f64 } else { self.est_revenue(start, end) };
        let season = |a: Day, b: Day| (a..b).map(|x| calendar::demand(&self.m.vertical, self.vertical, self.b2b, x.min(n - 1))).sum::<f64>() / (b - a).max(1) as f64;
        let ratio = if have >= 28 { season(start, end) / season(day.saturating_sub(have as Day), day).max(1e-9) } else { 1.0 };
        let plan = daily * ratio * (end - start) as f64;
        let date = time::date_of(start);
        let push = if !self.b2b && date.month() == 10 { 1.15 } else { 1.0 };
        let (y, q) = (date.year(), date.month0() / 3 + 1);
        let label = match d.style {
            0 => format!("Q{q} {y}"),
            1 => format!("{y}-Q{q}"),
            _ => format!("Q{q}/{:02}", y % 100),
        };
        let launch = date != quarter_start(date);
        let creator = self.marketer();
        for c in 0..2 {
            // how the running flight pays back so far: scale up what works, cut what does not
            if let Some(f) = &self.mkt.flights[c] {
                let elapsed = day.saturating_sub(f.start) as f64;
                if elapsed >= 28.0 {
                    let spent = f.budget * (elapsed / (f.end - f.start) as f64).min(1.0);
                    let roas = f.revenue / spent.max(1.0);
                    self.mkt.scale[c] = (self.mkt.scale[c] * libm::pow(roas / d.target, 0.5).clamp(0.6, 1.5)).clamp(0.3, 2.5);
                }
            }
            let share = if c == 1 { d.social } else { 1.0 - d.social };
            // channels the merchant hardly uses, or has written off
            if share * d.intensity < 0.004 || self.mkt.scale[c] <= 0.3 {
                continue;
            }
            let budget = nice(plan * d.intensity * share * self.mkt.scale[c] * push, d.style);
            let name = match (d.style, c) {
                (0, 0) => format!("Always-on search - {label}"),
                (0, _) => format!("Prospecting (social) - {label}"),
                (1, 0) => format!("{label} | Google Search"),
                (1, _) => format!("{label} | Meta Prospecting"),
                (_, 0) => format!("Search {label}"),
                _ => format!("Social {label}"),
            };
            let name = if launch { format!("{name} (launch)") } else { name };
            let slug = match d.style {
                0 => format!("{}_{y}q{q}", ["search", "social"][c]),
                1 => format!("{}_{}_{y}_q{q}", self.m.slug.replace('-', "_"), ["search", "prospecting"][c]),
                _ => format!("q{q}{:02}-{}", y % 100, ["search", "social"][c]),
            };
            let start_ts = if launch { ts } else { self.tz.local_to_utc(date, 0) };
            let end_ts = self.tz.local_to_utc(time::date_of(end), 0);
            let (status, started, ended) = if end <= n {
                (if cut.is_some() { "paused" } else { "sent" }, Some(start_ts), Some(end_ts))
            } else if start < n {
                ("sending", Some(start_ts), None)
            } else {
                ("scheduled", None, None)
            };
            let mut r = Row::new(campaigns::NCOLS);
            r.set(campaigns::TENANT_ID, self.tenant_rid())
                .set(campaigns::NAME, name)
                .set(campaigns::DESCRIPTION, V::Null)
                .set(campaigns::CHANNEL, ["paid_search", "paid_social"][c])
                .set(campaigns::STATUS, status)
                .set(campaigns::BUDGET, V::Dec((budget * 10000.0) as i128, 4))
                .set(campaigns::CURRENCY_CODE, self.m.currency.clone())
                .set(campaigns::SCHEDULED_AT, V::Ts(start_ts))
                .set(campaigns::STARTED_AT, V::opt_ts(started))
                .set(campaigns::ENDED_AT, V::opt_ts(ended))
                .set(campaigns::CREATED_BY_USER_ID, V::opt_ref(creator))
                .set(campaigns::CREATED_AT, V::Ts(ts))
                .set(campaigns::UPDATED_AT, V::Ts(ended.or(started).unwrap_or(ts).max(ts)));
            let campaign = self.chunk.emit(campaigns::T, day, r);
            let (source, medium) = [("google", "cpc"), ("facebook", "paid_social")][c];
            self.utm_link(day, ts, campaign, None, &slug, source, medium);
            let _ = rng;
            self.mkt.planned[c] = Some(Flight { campaign, slug, budget, start, end, revenue: 0.0 });
        }
    }

    /// Paid media of the day: observe revenue, switch and plan flights, set today's channel mix.
    pub(super) fn paid_day(&mut self, day: Day, rng: &mut Rng, outs: &[&DayOut]) {
        let rev: i64 = outs.iter().map(|o| o.revenue).sum();
        self.mkt.revenue.push_back(rev as f64 / 100.0);
        if self.mkt.revenue.len() > 91 {
            self.mkt.revenue.pop_front();
        }
        for c in 0..2 {
            let paid: i64 = outs.iter().map(|o| o.paid_revenue[c]).sum();
            if let Some(f) = self.mkt.flights[c].as_mut() {
                f.revenue += paid as f64 / 100.0;
            }
        }
        let date = time::date_of(day);
        if date == quarter_start(date) && day > self.join_day {
            self.mkt.flights = [self.mkt.planned[0].take(), self.mkt.planned[1].take()];
            self.mkt.paid = [0, 1].map(|c| self.mkt.flights[c].as_ref().map(|f| (f.campaign, f.slug.clone())));
        }
        let next = next_quarter(date);
        if (next - date).num_days() == 14 {
            let ts = self.tz.local_to_utc(date, rng.int(9, 17) * MICROS_PER_HOUR + rng.int(0, 59) * 60_000_000);
            self.plan_flights(day, ts, time::day_of(next) as Day, time::day_of(next_quarter(next)) as Day, rng);
        }
        // today's channel mix: paid traffic follows spend (diminishing returns, dearer clicks
        // in the peak); established shops get more organic and direct visits
        let d = self.mkt.drivers;
        let have = self.mkt.revenue.len();
        let daily = if have >= 7 { self.mkt.revenue.iter().sum::<f64>() / have as f64 } else { self.est_revenue(day, day + 1) };
        let cpc = cpc_index(date);
        let mut w = BASE_MIX;
        for c in 0..2 {
            let spend = self.mkt.flights[c].as_ref().map_or(0.0, |f| f.budget / (f.end - f.start).max(1) as f64);
            let x = spend / daily.max(1e-6) / REF_SPEND[c] / cpc;
            w[1 + 2 * c] = BASE_MIX[1 + 2 * c] * libm::pow(x, 0.6).min(3.0);
        }
        let age = (date - time::parse_date(&self.m.joined_on)).num_days().max(0) as f64 / 365.0;
        let brand = libm::pow((age + 0.5) / 3.0, 0.3).clamp(0.6, 1.5);
        w[0] *= brand;
        w[5] *= brand;
        w[2] *= (d.social / 0.4).clamp(0.3, 1.8);
        self.mkt.acq_mix = w;
        // paid spend brings customers on top of the unpaid demand
        self.mkt.paid_volume = (BASE_MIX[0] + BASE_MIX[2] + BASE_MIX[4] + BASE_MIX[5] + w[1] + w[3]) / BASE_MIX.iter().sum::<f64>();
    }

    /// Today's emails: the regular newsletter, and an announcement when a promotion starts.
    pub(super) fn campaigns_day(&mut self, day: Day, rng: &mut Rng) {
        if self.mkt.templates.is_empty() {
            return;
        }
        if crate::sim::stories::has(self.m, "S7") && self.mkt.influencer.is_none() && crate::sim::stories::s7_window(self.m, day) {
            let at = time::ts_of_day(day) + 8 * MICROS_PER_HOUR;
            let mut r = Row::new(campaigns::NCOLS);
            r.set(campaigns::TENANT_ID, self.tenant_rid())
                .set(campaigns::NAME, "Creator partnership - Spring Mega Sale")
                .set(campaigns::DESCRIPTION, "Instagram creator posts with the MEGA40 code")
                .set(campaigns::CHANNEL, "influencer")
                .set(campaigns::STATUS, "sent")
                .set(campaigns::BUDGET, V::Dec(25_000 * 10_000, 4))
                .set(campaigns::CURRENCY_CODE, self.m.currency.clone())
                .set(campaigns::STARTED_AT, V::Ts(at))
                .set(campaigns::ENDED_AT, V::Ts(at + 21 * MICROS_PER_DAY))
                .set(campaigns::CREATED_BY_USER_ID, V::opt_ref(self.marketer()))
                .set(campaigns::CREATED_AT, V::Ts(at - 10 * MICROS_PER_DAY))
                .set(campaigns::UPDATED_AT, V::Ts(at));
            let c = self.chunk.emit(campaigns::T, day, r);
            self.utm_link(day, at, c, Some(0), "creator_mega40", "instagram", "influencer");
            self.mkt.influencer = Some((c, "creator_mega40".to_string()));
        }
        let newsletter = (day as usize + self.idx * 3) % self.mkt.cadence_days == 0;
        let promo = self.pricing.promos.iter().find(|o| time::day_of_ts(o.start) == day as i64).map(|o| (o.name.clone(), o.promotion));
        // (subject, segment, promotion, template, landing page)
        let mut plans: Vec<(String, SegmentKind, Option<Option<Rid>>, usize, usize)> = Vec::new();
        if let Some((name, promotion)) = promo {
            plans.push((format!("{name} starts now"), SegmentKind::All, Some(promotion), 2, 0));
        }
        let winback = crate::sim::stories::s6_winback(self.m, day);
        if winback {
            plans.push(("Your coffee misses you - come back for 30% off".to_string(), SegmentKind::WinBack, None, 4, 0));
        }
        if newsletter && !winback {
            let (subject, seg, tpl) = match rng.below(20) {
                0..=2 => ("We miss you - here's what's new".to_string(), SegmentKind::Lapsed, 4),
                3..=4 => ("Early access for our best customers".to_string(), SegmentKind::Vip, 0),
                _ => (format!("New this week at {}", self.m.name), SegmentKind::All, 0),
            };
            plans.push((subject, seg, None, tpl, 1));
        }
        let tenant = self.tenant_rid();
        let creator = self.marketer();
        for (subject, seg, promotion, tpl, lp) in plans {
            self.mkt.seq += 1;
            let at = self.tz.local_to_utc(time::date_of(day), rng.int(7, 10) * MICROS_PER_HOUR + rng.int(0, 59) * 60_000_000);
            let name = format!("{} #{}", if promotion.is_some() { "Promo" } else if seg == SegmentKind::Lapsed || seg == SegmentKind::WinBack { "Win-back" } else { "Newsletter" }, self.mkt.seq);
            let utm = format!("{}_{}", people::slugify(&name).replace('-', "_"), time::date_of(day).format("%Y%m%d"));
            let template = self.mkt.templates[tpl.min(self.mkt.templates.len() - 1)];
            let mut r = Row::new(campaigns::NCOLS);
            r.set(campaigns::TENANT_ID, tenant)
                .set(campaigns::NAME, name.clone())
                .set(campaigns::DESCRIPTION, subject.clone())
                .set(campaigns::CHANNEL, "email")
                .set(campaigns::STATUS, "sent")
                .set(campaigns::SEGMENT_ID, self.mkt.segments[seg as usize].rid)
                .set(campaigns::EMAIL_TEMPLATE_ID, template)
                .set(campaigns::LANDING_PAGE_ID, self.mkt.landing[lp].rid)
                .set(campaigns::PROMOTION_ID, V::opt_ref(promotion.flatten()))
                .set(campaigns::SCHEDULED_AT, V::Ts(at))
                .set(campaigns::STARTED_AT, V::Ts(at))
                .set(campaigns::ENDED_AT, V::Ts(at + rng.int(20, 90) * 60_000_000))
                .set(campaigns::CREATED_BY_USER_ID, V::opt_ref(creator))
                .set(campaigns::CREATED_AT, V::Ts(at - rng.int(1, 3) * MICROS_PER_DAY))
                .set(campaigns::UPDATED_AT, V::Ts(at + 2 * MICROS_PER_HOUR));
            let campaign = self.chunk.emit(campaigns::T, day, r);
            if let Some((actor, ip, ua)) = self.staff_actor(&["marketing", "admin", "owner"]) {
                let at0 = (at - 2 * MICROS_PER_DAY).max(time::ts_of_day(day));
                self.audit(rng, super::Audit { at: at0, action: "create", actor: Some(actor), actor_type: "staff", entity: Some((campaigns::T, campaign)), summary: format!("Scheduled campaign \"{name}\""), metadata: format!(r#"{{"channel":"email","segment":"{:?}"}}"#, seg), ip: Some(&ip), ua: Some(ua) });
            }
            self.utm_link(day, at - MICROS_PER_DAY, campaign, Some(lp), &utm, "newsletter", "email");
            // some sends test two subject lines (50/50)
            let ab = if rng.chance(0.15) || seg == SegmentKind::WinBack {
                let lift = rng.lognormal(0.0, 0.12).clamp(0.7, 1.4);
                let done = at + 3 * MICROS_PER_DAY <= time::end_ts();
                let mut r = Row::new(ab_tests::NCOLS);
                r.set(ab_tests::TENANT_ID, tenant)
                    .set(ab_tests::CAMPAIGN_ID, campaign)
                    .set(ab_tests::NAME, format!("{name} subject line"))
                    .set(ab_tests::HYPOTHESIS, if rng.chance(0.6) { V::Static("A shorter, more personal subject line increases opens.") } else { V::Null })
                    .set(ab_tests::STATUS, if done { "completed" } else { "running" })
                    .set(ab_tests::GOAL_METRIC, "open_rate")
                    .set(ab_tests::STARTED_AT, V::Ts(at))
                    .set(ab_tests::ENDED_AT, if done { V::Ts(at + 3 * MICROS_PER_DAY) } else { V::Null })
                    .set(ab_tests::CREATED_AT, V::Ts(at - MICROS_PER_DAY))
                    .set(ab_tests::UPDATED_AT, V::Ts((at + 3 * MICROS_PER_DAY).min(time::end_ts())));
                let th = self.chunk.emit_deferred(ab_tests::T, day, r);
                let test = th.rid;
                let mut vars = [test; 2];
                for (k, label) in ["A (control)", "B"].iter().enumerate() {
                    let subj = if k == 0 { subject.clone() } else { format!("{} \u{2728}", subject.split(" - ").next().unwrap_or(&subject)) };
                    let mut r = Row::new(ab_variants::NCOLS);
                    r.set(ab_variants::TENANT_ID, tenant)
                        .set(ab_variants::AB_TEST_ID, test)
                        .set(ab_variants::NAME, *label)
                        .set(ab_variants::IS_CONTROL, k == 0)
                        .set(ab_variants::TRAFFIC_WEIGHT, V::Dec(5000, 4))
                        .set(ab_variants::CONFIG, V::Json(format!(r#"{{"subject":{}}}"#, crate::sim::shopper::json_str(&subj))))
                        .set(ab_variants::CREATED_AT, V::Ts(at - MICROS_PER_DAY))
                        .set(ab_variants::UPDATED_AT, V::Ts(at - MICROS_PER_DAY));
                    vars[k] = self.chunk.emit(ab_variants::T, day, r);
                }
                if let Some(w) = Self::ab_winner(lift).filter(|_| done) {
                    self.chunk.deferred_mut(th).set(ab_tests::WINNER_VARIANT_ID, vars[w]);
                }
                Some((test, vars, [1.0, lift]))
            } else {
                None
            };
            self.mkt.sends_today.push(Send { campaign, template, segment: seg, utm, at, promo: promotion.is_some() || seg == SegmentKind::WinBack, ab, landing: lp, winback: seg == SegmentKind::WinBack });
        }
    }

    /// Winner of a subject-line test, decided when the test ends: only when the effect is clear.
    fn ab_winner(lift: f64) -> Option<usize> {
        if lift > 1.06 { Some(1) } else if lift < 0.94 { Some(0) } else { None }
    }

    /// Clicks, landing page views and segment sizes reported by the shopper chunks.
    pub(super) fn count_marketing(&mut self, outs: &[&DayOut]) {
        for o in outs {
            for c in &o.clicks {
                if let Some(u) = self.mkt.utm.get_mut(c) {
                    u.1 += 1;
                }
            }
            for &l in &o.landing_views {
                self.mkt.landing_views[l] += 1;
            }
            for k in 0..5 {
                self.mkt.segment_counts[k] += o.segments[k];
            }
        }
    }

    pub fn finish_marketing(&mut self, outs: &[&DayOut]) {
        if self.tenant.is_none() {
            return;
        }
        self.count_marketing(outs);
        let segs: Vec<(DHandle, i64)> = self.mkt.segments.iter().copied().zip(self.mkt.segment_counts).collect();
        for (h, c) in segs {
            let refreshed = if self.churn_day.is_some() { V::Null } else { V::Ts(time::ts_of_day(time::num_days() - 1) + 2 * MICROS_PER_HOUR + 17 * 60_000_000) };
            self.chunk.deferred_mut(h).set(segments::MEMBER_COUNT, V::Int(c)).set(segments::LAST_REFRESHED_AT, refreshed);
        }
        let lps: Vec<(DHandle, i64)> = self.mkt.landing.iter().copied().zip(self.mkt.landing_views.iter().copied()).collect();
        for (h, c) in lps {
            self.chunk.deferred_mut(h).set(landing_pages::VIEW_COUNT, V::Int(c));
        }
        let utms: Vec<(DHandle, i64)> = self.mkt.utm.values().copied().collect();
        for (h, c) in utms {
            self.chunk.deferred_mut(h).set(utm_links::CLICK_COUNT, V::Int(c));
        }
    }
}
