//! Subscriptions of the shoppers of one chunk: sign-up, billing with dunning, prepaid
//! deliveries (orders that go through the normal fulfilment), skips, price-version
//! migrations, and cancellations.
//!
//! Churn is not scripted: each renewal is a decision driven by the subscriber's satisfaction
//! (which late or damaged deliveries lower, see `order`), their price sensitivity when the
//! price goes up, and whether they still shop here at all. Failed payments that dunning cannot
//! recover end a subscription involuntarily.

use super::journey::Channel;
use super::{Item, ShopperChunk};
use crate::engine::DHandle;
use crate::rng::{Rng, format_uuid};
use crate::sim::Params;
use crate::sim::merchant::{Captured, MerchantSim, PlanDef};
use crate::tables::*;
use crate::time::{self, Day, MICROS_PER_DAY, MICROS_PER_HOUR, MICROS_PER_MIN, MICROS_PER_SEC, Ts};
use crate::value::{Rid, Row, V};
use crate::world::world;

pub(super) struct Sub {
    pub shopper: u32,
    h: DHandle,
    item: DHandle,
    addon: Option<DHandle>,
    plan: usize,
    version: usize,
    /// current billing period
    start: Ts,
    end: Ts,
    /// product type the box is filled from
    ty: usize,
    /// remaining periods with a price shock, and log(price factor)
    shock: (u32, f64),
    skips: u32,
    /// extra bags ordered during the current period (billed with the next invoice)
    usage: i64,
    public_id: u128,
    pm: Option<(Rid, &'static str, String)>,
}

#[derive(Clone, Copy)]
pub(super) enum SubEv {
    Renew,
    Deliver,
}

fn base_churn(vertical: &str) -> f64 {
    match vertical {
        "food_coffee" => 0.055,
        "pet_supplies" => 0.04,
        "beauty" => 0.075,
        _ => 0.065,
    }
}

fn plan_months(p: &PlanDef) -> f64 {
    if p.weeks > 0 { p.weeks as f64 / 4.345 } else { p.months as f64 }
}

impl ShopperChunk {
    /// (plan, price version) of a subscription.
    pub(super) fn sub_plan(&self, k: usize) -> (usize, usize) {
        (self.subs[k].plan, self.subs[k].version)
    }

    fn queue_sub(&mut self, k: usize, ev: SubEv, at: Ts) {
        if at > time::end_ts() {
            return;
        }
        let d = time::day_of_ts(at).max(self.chunk.day as i64) as Day;
        self.sub_queue.entry(d).or_default().push((k as u32, ev, at));
    }

    fn sub_row(&self, ms: &MerchantSim, s: usize, plan: usize, version: usize, start: Ts, end: Ts, started: Ts, public_id: u128, pm: Option<Rid>, source: &str) -> Row {
        let subs = ms.subs.as_ref().unwrap();
        let mut r = Row::new(subscriptions::NCOLS);
        r.set(subscriptions::PUBLIC_ID, V::Uuid(public_id))
            .set(subscriptions::TENANT_ID, ms.tenant_rid())
            .set(subscriptions::USER_ID, self.shoppers[s].rid)
            .set(subscriptions::PLAN_ID, subs.plans[plan].versions[version].plan.rid)
            .set(subscriptions::PAYMENT_METHOD_ID, V::opt_ref(pm))
            .set(subscriptions::STATUS, "active")
            .set(subscriptions::CURRENCY_CODE, ms.m.currency.clone())
            .set(subscriptions::QUANTITY, 1)
            .set(subscriptions::CURRENT_PERIOD_START, V::Ts(start))
            .set(subscriptions::CURRENT_PERIOD_END, V::Ts(end))
            .set(subscriptions::CANCEL_AT_PERIOD_END, false)
            .set(subscriptions::STARTED_AT, V::Ts(started))
            .set(subscriptions::METADATA, V::Json(format!(r#"{{"source":"{source}","skipped_deliveries":0}}"#)))
            .set(subscriptions::CREATED_AT, V::Ts(started))
            .set(subscriptions::UPDATED_AT, V::Ts(started));
        r
    }

    fn sub_items(&mut self, ms: &MerchantSim, sub_rid: Rid, plan: usize, version: usize, at: Ts) -> (DHandle, Option<DHandle>) {
        let subs = ms.subs.as_ref().unwrap();
        let p = &subs.plans[plan];
        let v = &p.versions[version];
        let day = self.chunk.day;
        let mut r = Row::new(subscription_items::NCOLS);
        r.set(subscription_items::TENANT_ID, ms.tenant_rid())
            .set(subscription_items::SUBSCRIPTION_ID, sub_rid)
            .set(subscription_items::PLAN_PRICE_ID, v.price)
            .set(subscription_items::DESCRIPTION, p.name.clone())
            .set(subscription_items::QUANTITY, 1)
            .set(subscription_items::UNIT_AMOUNT, V::Money(v.amount))
            .set(subscription_items::CURRENCY_CODE, ms.m.currency.clone())
            .set(subscription_items::IS_METERED, false)
            .set(subscription_items::CREATED_AT, V::Ts(at))
            .set(subscription_items::UPDATED_AT, V::Ts(at));
        let item = self.chunk.emit_deferred(subscription_items::T, day, r);
        let addon = subs.addon.map(|(price, amount)| {
            let mut r = Row::new(subscription_items::NCOLS);
            r.set(subscription_items::TENANT_ID, ms.tenant_rid())
                .set(subscription_items::SUBSCRIPTION_ID, sub_rid)
                .set(subscription_items::PLAN_PRICE_ID, price)
                .set(subscription_items::DESCRIPTION, if ms.m.vertical == "food_coffee" { "Extra bag" } else { "Extra pack" })
                .set(subscription_items::QUANTITY, 1)
                .set(subscription_items::UNIT_AMOUNT, V::Money(amount))
                .set(subscription_items::CURRENCY_CODE, ms.m.currency.clone())
                .set(subscription_items::IS_METERED, true)
                .set(subscription_items::CREATED_AT, V::Ts(at))
                .set(subscription_items::UPDATED_AT, V::Ts(at));
            self.chunk.emit_deferred(subscription_items::T, day, r)
        });
        (item, addon)
    }

    fn pick_plan(&self, rng: &mut Rng, ms: &MerchantSim, s: usize) -> usize {
        let subs = ms.subs.as_ref().unwrap();
        let sens = self.shoppers[s].prefs.price_sens;
        // long commitments appeal to the less price-sensitive and the loyal
        let w: Vec<f64> = subs.plans.iter().map(|p| p.weight * if p.deliveries > 1 { self.shoppers[s].satisfaction / sens } else { 1.0 }).collect();
        crate::rng::Weighted::new(w).sample(rng)
    }

    /// A shopper starts a subscription at checkout (the first period is billed right away).
    pub(super) fn start_subscription(&mut self, rng: &mut Rng, ms: &MerchantSim, p: &Params, s: usize, at: Ts, items: &[Item]) {
        let plan = self.pick_plan(rng, ms, s);
        let subs = ms.subs.as_ref().unwrap();
        let version = subs.plans[plan].version_at(at);
        let end = subs.plans[plan].period_end(at);
        let pm = self.payment_method(rng, ms, s, at);
        let public_id = rng.uuid();
        let r = self.sub_row(ms, s, plan, version, at, end, at, public_id, Some(pm.0), "checkout");
        let h = self.chunk.emit_deferred(subscriptions::T, self.chunk.day, r);
        let (item, addon) = self.sub_items(ms, h.rid, plan, version, at);
        let ty = items.first().map_or(0, |i| ms.products[i.pidx].ty);
        let k = self.subs.len();
        self.subs.push(Sub { shopper: s as u32, h, item, addon, plan, version, start: at, end, ty, shock: (0, 0.0), skips: 0, usage: 0, public_id, pm: Some(pm) });
        self.shoppers[s].sub = Some(k as u32);
        self.shoppers[s].need_day = None;
        let t = at + rng.int(5, 60) * MICROS_PER_SEC;
        self.bill(rng, ms, p, k, t, true);
    }

    /// A subscription that existed before the 2023 migration (its earlier invoices are not in
    /// this database).
    pub(super) fn migrated_subscription(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, created: Ts) {
        let day0 = time::ts_of_day(self.chunk.day);
        let plan = self.pick_plan(rng, ms, s);
        let started = created + rng.int(0, ((day0 - created) / MICROS_PER_DAY).max(1)) * MICROS_PER_DAY;
        let (mut start, mut end) = (started, ms.subs.as_ref().unwrap().plans[plan].period_end(started));
        while end <= day0 {
            start = end;
            end = ms.subs.as_ref().unwrap().plans[plan].period_end(start);
        }
        let public_id = rng.uuid();
        let pm = self.payment_method(rng, ms, s, created + MICROS_PER_HOUR);
        let r = self.sub_row(ms, s, plan, 0, start, end, started, public_id, Some(pm.0), "migration");
        let h = self.chunk.emit_deferred(subscriptions::T, self.chunk.day, r);
        let (item, addon) = self.sub_items(ms, h.rid, plan, 0, started);
        let ty = self.shoppers[s].prefs.types.first().map_or(0, |t| t.0);
        let k = self.subs.len();
        self.subs.push(Sub { shopper: s as u32, h, item, addon, plan, version: 0, start, end, ty, shock: (0, 0.0), skips: 0, usage: 0, public_id, pm: Some(pm) });
        self.shoppers[s].sub = Some(k as u32);
        self.queue_sub(k, SubEv::Renew, end);
    }

    /// Today's renewals and deliveries.
    pub(super) fn subscriptions_day(&mut self, rng: &mut Rng, ms: &MerchantSim, p: &Params, day: Day) {
        let Some(evs) = self.sub_queue.remove(&day) else { return };
        for (k, ev, at) in evs {
            match ev {
                SubEv::Renew => self.renew(rng, ms, p, k as usize, at),
                SubEv::Deliver => self.deliver(rng, ms, p, k as usize, at),
            }
        }
    }

    fn renew(&mut self, rng: &mut Rng, ms: &MerchantSim, p: &Params, k: usize, t: Ts) {
        let subs = ms.subs.as_ref().unwrap();
        let s = self.subs[k].shopper as usize;
        let plan = &subs.plans[self.subs[k].plan];
        // a new price version applies from this renewal on
        let v = plan.version_at(t);
        if v > self.subs[k].version {
            let f = plan.versions[v].amount as f64 / plan.versions[self.subs[k].version].amount as f64;
            self.subs[k].version = v;
            self.subs[k].shock = (if plan.deliveries > 1 { 1 } else { 3 }, libm::log(f));
            let (h, item) = (self.subs[k].h, self.subs[k].item);
            self.chunk.deferred_mut(h).set(subscriptions::PLAN_ID, plan.versions[v].plan.rid).set(subscriptions::UPDATED_AT, V::Ts(t));
            self.chunk.deferred_mut(item).set(subscription_items::PLAN_PRICE_ID, plan.versions[v].price).set(subscription_items::UNIT_AMOUNT, V::Money(plan.versions[v].amount)).set(subscription_items::UPDATED_AT, V::Ts(t));
        }
        // keep or cancel: satisfaction, price shocks, and whether they still shop here
        let months = plan_months(plan);
        let sat = self.shoppers[s].satisfaction;
        let mut m = base_churn(&ms.m.vertical) * libm::pow(1.0 / sat, 2.0) * if plan.deliveries > 1 { 0.6 } else { 1.0 };
        if self.chunk.day >= self.shoppers[s].churn_day {
            m += 0.03;
        }
        let mut h = 1.0 - libm::pow(1.0 - m.min(0.9), months);
        let shocked = self.subs[k].shock.0 > 0;
        if shocked {
            let per = if plan.deliveries > 1 { 2.0 } else { 0.6 };
            h += per * self.shoppers[s].prefs.price_sens * self.subs[k].shock.1;
            self.subs[k].shock.0 -= 1;
        }
        let (start, end) = (self.subs[k].start, self.subs[k].end);
        if rng.chance(h.min(0.95)) {
            let span = ((end - start) / MICROS_PER_DAY - 1).clamp(1, 20);
            let canceled = end - rng.int(1, span) * MICROS_PER_DAY - rng.int(0, MICROS_PER_DAY - 1);
            let reason = if shocked && rng.chance(0.8) { "too_expensive" } else if sat < 0.8 { "unhappy_with_service" } else { *rng.pick(&["too_much_product", "switching_brand", "moving", "other", "too_expensive"]) };
            self.end_subscription(ms, k, canceled.max(start), end, reason, true);
            return;
        }
        // skip a delivery now and then (flexible plans only)
        let next_end = plan.period_end(end);
        let sk = plan.deliveries == 1 && months <= 1.0 && rng.chance(0.04);
        self.subs[k].start = end;
        self.subs[k].end = next_end;
        let h = self.subs[k].h;
        self.chunk.deferred_mut(h).set(subscriptions::CURRENT_PERIOD_START, V::Ts(end)).set(subscriptions::CURRENT_PERIOD_END, V::Ts(next_end)).set(subscriptions::UPDATED_AT, V::Ts(end));
        if sk {
            self.subs[k].skips += 1;
            let n = self.subs[k].skips;
            let src = match &self.chunk.deferred_ref(h).vals[subscriptions::METADATA] { V::Json(j) => j.split(',').next().unwrap_or("{").to_string(), _ => "{".to_string() };
            self.chunk.deferred_mut(h).set(subscriptions::METADATA, V::Json(format!("{src},\"skipped_deliveries\":{n}}}")));
            self.queue_sub(k, SubEv::Renew, next_end);
            return;
        }
        let t = end + rng.int(0, 3600) * MICROS_PER_SEC;
        self.bill(rng, ms, p, k, t, false);
    }

    fn end_subscription(&mut self, ms: &MerchantSim, k: usize, canceled: Ts, ended: Ts, reason: &str, at_period_end: bool) {
        let end = time::end_ts();
        let s = self.subs[k].shopper as usize;
        let h = self.subs[k].h;
        let src = match &self.chunk.deferred_ref(h).vals[subscriptions::METADATA] { V::Json(j) => j.trim_end_matches('}').to_string(), _ => "{".to_string() };
        let mut r = self.chunk.deferred_mut(h);
        r.set(subscriptions::CANCEL_AT_PERIOD_END, at_period_end)
            .set(subscriptions::CANCELED_AT, V::Ts(canceled))
            .set(subscriptions::METADATA, V::Json(format!("{src},\"cancellation_reason\":\"{reason}\"}}")))
            .set(subscriptions::UPDATED_AT, V::Ts(ended.min(end).max(canceled)));
        if ended <= end {
            r.set(subscriptions::STATUS, "canceled").set(subscriptions::ENDED_AT, V::Ts(ended));
        }
        self.shoppers[s].sub = None;
        self.shoppers[s].sub_ended = Some(ended);
        let _ = ms;
    }

    /// Invoice one billing period: charge, dunning retries, receipt; deliveries on success.
    fn bill(&mut self, rng: &mut Rng, ms: &MerchantSim, p: &Params, k: usize, t: Ts, first: bool) {
        let w = world();
        let end = time::end_ts();
        let tenant = ms.tenant_rid();
        let subs = ms.subs.as_ref().unwrap();
        let s = self.subs[k].shopper as usize;
        let plan = &subs.plans[self.subs[k].plan];
        let version = &plan.versions[self.subs[k].version];
        let (pstart, pend) = (self.subs[k].start, self.subs[k].end);
        let cur = ms.m.currency.clone();
        let (dest, region) = (self.shoppers[s].country, self.shoppers[s].region);
        let date = time::date_of(time::day_of_ts(t).max(0) as Day).format("%Y-%m-%d").to_string();
        let (rate, inclusive) = self.tax(ms, dest, region, &date);
        let home_rate = if ms.m.country == "US" { 0.0 } else { w.vat_rate(w.country(&ms.m.country), &date) / 100.0 };
        let net_of = |gross: i64| if inclusive { (gross as f64 / (1.0 + home_rate)).round() as i64 } else { gross };
        // lines: the plan, and extra bags added during the last period (metered)
        let mut lines: Vec<(Option<DHandle>, String, i64, i64, Option<(Ts, Ts)>)> = vec![(Some(self.subs[k].item), format!("{} ({} - {})", plan.name, fmt_date(pstart), fmt_date(pend)), 1, net_of(version.amount), Some((pstart, pend)))];
        // extra bags ordered during the last period are billed in arrears; new ones for this
        // period are recorded as they happen
        let mut usage: Vec<(Ts, i64)> = Vec::new();
        if let (Some(addon), Some((_, unit))) = (self.subs[k].addon, subs.addon) {
            let n = std::mem::take(&mut self.subs[k].usage);
            if n > 0 {
                lines.push((Some(addon), if ms.m.vertical == "food_coffee" { "Extra bag".into() } else { "Extra pack".into() }, n, net_of(unit), None));
            }
            if rng.chance(0.12) {
                let n = 1 + rng.below(2) as i64;
                for _ in 0..n {
                    usage.push((pstart + rng.int(MICROS_PER_HOUR, (pend - pstart - MICROS_PER_HOUR).max(2 * MICROS_PER_HOUR)), 1));
                }
                self.subs[k].usage = n;
            }
        }
        let subtotal: i64 = lines.iter().map(|l| l.2 * l.3).sum();
        let tax: i64 = lines.iter().map(|l| ((l.2 * l.3) as f64 * rate).round() as i64).sum();
        let total = subtotal + tax;
        // the charge and the dunning schedule (retries after 3, 5 and 7 days)
        let pm = match self.subs[k].pm.clone() { Some(pm) => pm, None => self.payment_method(rng, ms, s, t) };
        let (pm_rid, kind, gateway) = pm;
        let mut attempts: Vec<(Ts, bool)> = Vec::new();
        for (i, off) in [0i64, 3, 5, 7].iter().enumerate() {
            let at = if i == 0 { t + rng.int(2, 30) * MICROS_PER_SEC } else { t + off * MICROS_PER_DAY + rng.int(0, 4 * 3600) * MICROS_PER_SEC };
            let ok = rng.chance(if i == 0 { if kind == "card" { 0.93 } else { 0.97 } } else { 0.42 });
            attempts.push((at, ok));
            if ok {
                break;
            }
        }
        let attempts: Vec<(Ts, bool)> = attempts.into_iter().filter(|a| a.0 <= end).collect();
        let paid_at = attempts.iter().find(|a| a.1).map(|a| a.0 + 2 * MICROS_PER_SEC);
        let gave_up = paid_at.is_none() && attempts.len() == 4;
        let status = if paid_at.is_some() { "paid" } else if gave_up { "uncollectible" } else if attempts.iter().any(|a| !a.1) { "past_due" } else { "open" };
        let last = attempts.last().map_or(t, |a| a.0);
        let mut r = Row::new(invoices::NCOLS);
        r.set(invoices::PUBLIC_ID, V::Uuid(rng.uuid()))
            .set(invoices::TENANT_ID, tenant)
            .set(invoices::USER_ID, self.shoppers[s].rid)
            .set(invoices::SUBSCRIPTION_ID, self.subs[k].h.rid)
            .set(invoices::INVOICE_NUMBER, "INV-")
            .set(invoices::STATUS, status)
            .set(invoices::CURRENCY_CODE, cur.clone())
            .set(invoices::SUBTOTAL, V::Money(subtotal))
            .set(invoices::TAX_TOTAL, V::Money(tax))
            .set(invoices::DISCOUNT_TOTAL, V::Money(0))
            .set(invoices::TOTAL, V::Money(total))
            .set(invoices::AMOUNT_PAID, V::Money(if paid_at.is_some() { total } else { 0 }))
            .set(invoices::AMOUNT_DUE, V::Money(if paid_at.is_some() { 0 } else { total }))
            .set(invoices::ISSUED_AT, V::Ts(t))
            .set(invoices::DUE_AT, V::Ts(t))
            .set(invoices::PAID_AT, V::opt_ts(paid_at))
            .set(invoices::CREATED_AT, V::Ts(t - rng.int(60, 3600) * MICROS_PER_SEC))
            .set(invoices::UPDATED_AT, V::Ts(paid_at.unwrap_or(last).min(end)));
        let Some(invoice) = self.emit_at(invoices::T, t, r) else { return };
        for (item, desc, qty, unit, period) in &lines {
            let mut r = Row::new(invoice_lines::NCOLS);
            r.set(invoice_lines::TENANT_ID, tenant)
                .set(invoice_lines::INVOICE_ID, invoice)
                .set(invoice_lines::SUBSCRIPTION_ITEM_ID, V::opt_ref(item.map(|h| h.rid)))
                .set(invoice_lines::DESCRIPTION, desc.clone())
                .set(invoice_lines::QUANTITY, V::Dec(*qty as i128 * 10000, 4))
                .set(invoice_lines::UNIT_PRICE, V::Money(*unit))
                .set(invoice_lines::LINE_TOTAL, V::Money(qty * unit))
                .set(invoice_lines::TAX_AMOUNT, V::Money(((qty * unit) as f64 * rate).round() as i64))
                .set(invoice_lines::CURRENCY_CODE, cur.clone())
                .set(invoice_lines::PERIOD_START, V::opt_ts(period.map(|p| p.0)))
                .set(invoice_lines::PERIOD_END, V::opt_ts(period.map(|p| p.1)))
                .set(invoice_lines::CREATED_AT, V::Ts(t))
                .set(invoice_lines::UPDATED_AT, V::Ts(t));
            self.emit_at(invoice_lines::T, t, r);
        }
        if let Some(addon) = self.subs[k].addon {
            for (at, q) in &usage {
                let mut r = Row::new(usage_records::NCOLS);
                r.set(usage_records::TENANT_ID, tenant)
                    .set(usage_records::SUBSCRIPTION_ITEM_ID, addon.rid)
                    .set(usage_records::QUANTITY, V::Dec(*q as i128 * 10000, 4))
                    .set(usage_records::UNIT, if ms.m.vertical == "food_coffee" { "bag" } else { "pack" })
                    .set(usage_records::ACTION, "increment")
                    .set(usage_records::OCCURRED_AT, V::Ts(*at))
                    .set(usage_records::CREATED_AT, V::Ts(*at + rng.int(1, 30) * MICROS_PER_SEC))
                    .set(usage_records::UPDATED_AT, V::Ts(*at + rng.int(1, 30) * MICROS_PER_SEC));
                self.emit_at(usage_records::T, *at, r);
            }
        }
        let charge = format!("ch_{}", rng.alnum(24));
        let mut r = Row::new(payments::NCOLS);
        r.set(payments::TENANT_ID, tenant)
            .set(payments::INVOICE_ID, invoice)
            .set(payments::PAYMENT_METHOD_ID, pm_rid)
            .set(payments::STATUS, if paid_at.is_some() { "captured" } else { "failed" })
            .set(payments::AMOUNT, V::Money(total))
            .set(payments::AMOUNT_REFUNDED, V::Money(0))
            .set(payments::CURRENCY_CODE, cur.clone())
            .set(payments::GATEWAY, gateway.clone())
            .set(payments::GATEWAY_CHARGE_ID, if paid_at.is_some() { V::Str(charge) } else { V::Null })
            .set(payments::AUTHORIZED_AT, V::opt_ts(paid_at.map(|x| x - 2 * MICROS_PER_SEC)))
            .set(payments::CAPTURED_AT, V::opt_ts(paid_at))
            .set(payments::FAILURE_CODE, if paid_at.is_some() { V::Null } else { V::Static("card_declined") })
            .set(payments::METADATA, V::Json(format!(r#"{{"subscription":{{"id":"{}","billing_reason":"{}"}},"off_session":{}}}"#, format_uuid(self.subs[k].public_id), if first { "subscription_create" } else { "subscription_cycle" }, !first)))
            .set(payments::CREATED_AT, V::Ts(t))
            .set(payments::UPDATED_AT, V::Ts(paid_at.unwrap_or(last).min(end)));
        let payment = self.emit_at(payments::T, t, r).unwrap();
        let first_failed = attempts.first().is_some_and(|a| !a.1);
        let reasons = ["insufficient_funds", "expired_card", "do_not_honor", "card_declined"];
        for (i, (at, ok)) in attempts.iter().enumerate() {
            let reason = reasons[rng.below(reasons.len())];
            let mut r = Row::new(payment_attempts::NCOLS);
            r.set(payment_attempts::TENANT_ID, tenant)
                .set(payment_attempts::PAYMENT_ID, payment)
                .set(payment_attempts::ATTEMPT_NUMBER, i + 1)
                .set(payment_attempts::STATUS, if *ok { "captured" } else { "failed" })
                .set(payment_attempts::AMOUNT, V::Money(total))
                .set(payment_attempts::CURRENCY_CODE, cur.clone())
                .set(payment_attempts::GATEWAY_RESPONSE, V::Json(if *ok { format!(r#"{{"status":"approved","code":"00","latency_ms":{}}}"#, rng.int(120, 900)) } else { format!(r#"{{"status":"declined","code":"51","decline_reason":"{reason}","latency_ms":{}}}"#, rng.int(120, 900)) }))
                .set(payment_attempts::ERROR_CODE, if *ok { V::Null } else { V::Static(reason) })
                .set(payment_attempts::ERROR_MESSAGE, if *ok { V::Null } else { V::Str(format!("Payment declined by issuer ({reason})")) })
                .set(payment_attempts::ATTEMPTED_AT, V::Ts(*at))
                .set(payment_attempts::CREATED_AT, V::Ts(*at))
                .set(payment_attempts::UPDATED_AT, V::Ts(*at));
            self.emit_at(payment_attempts::T, *at, r);
            if first_failed {
                let next = attempts.get(i + 1).map(|a| a.0).or(if !ok && i < 3 { Some(t + [3, 5, 7][i] * MICROS_PER_DAY) } else { None });
                let mut r = Row::new(dunning_attempts::NCOLS);
                r.set(dunning_attempts::TENANT_ID, tenant)
                    .set(dunning_attempts::INVOICE_ID, invoice)
                    .set(dunning_attempts::SUBSCRIPTION_ID, self.subs[k].h.rid)
                    .set(dunning_attempts::PAYMENT_ID, payment)
                    .set(dunning_attempts::ATTEMPT_NUMBER, i + 1)
                    .set(dunning_attempts::OUTCOME, if *ok { "succeeded" } else if i == 3 { "exhausted" } else { "failed" })
                    .set(dunning_attempts::NEXT_ATTEMPT_AT, V::opt_ts(if *ok { None } else { next }))
                    .set(dunning_attempts::ATTEMPTED_AT, V::Ts(*at))
                    .set(dunning_attempts::CREATED_AT, V::Ts(*at))
                    .set(dunning_attempts::UPDATED_AT, V::Ts(*at));
                self.emit_at(dunning_attempts::T, *at, r);
            }
            if !ok {
                let tpl = subs.failed_tpl;
                self.email(rng, ms, s, tpl, "Action needed: your payment failed".into(), "billing", *at + 5 * MICROS_PER_MIN);
            }
        }
        let h = self.subs[k].h;
        if let Some(paid) = paid_at {
            let lg = ms.ledger.as_ref().unwrap();
            self.ledger(ms, rng, payment, paid + 30 * MICROS_PER_SEC, &[(lg.clearing, "debit", total), (lg.revenue, "credit", subtotal), (lg.vat, "credit", tax)], "Subscription invoice paid");
            let d = time::day_of_ts(paid).max(self.chunk.day as i64) as Day;
            self.outbox.entry(d).or_default().captured.push(Captured { payment, gateway: gateway.clone(), amount: total, fee: crate::sim::merchant::gateway_fee(&gateway, total) });
            let tpl = subs.receipt_tpl;
            self.email(rng, ms, s, tpl, "Your subscription receipt".into(), "billing", paid + MICROS_PER_MIN);
            // deliveries of this period (an annual plan ships monthly)
            for i in 0..plan.deliveries {
                let at = if i == 0 { paid + rng.int(5, 120) * MICROS_PER_MIN } else { add_months(pstart, i) + rng.int(6, 12) * MICROS_PER_HOUR };
                if i == 0 && time::day_of_ts(at) == self.chunk.day as i64 {
                    self.deliver(rng, ms, p, k, at);
                } else {
                    self.queue_sub(k, SubEv::Deliver, at);
                }
            }
            if first_failed {
                self.chunk.deferred_mut(h).set(subscriptions::UPDATED_AT, V::Ts(paid));
            }
            self.queue_sub(k, SubEv::Renew, pend);
        } else if gave_up {
            let at = last + MICROS_PER_HOUR;
            self.end_subscription(ms, k, at, at, "payment_failed", false);
        } else {
            // still in dunning at the end of the window
            self.chunk.deferred_mut(h).set(subscriptions::STATUS, "past_due").set(subscriptions::UPDATED_AT, V::Ts(last));
        }
    }

    /// One prepaid delivery: an order with a 100% discount that is fulfilled like any other.
    fn deliver(&mut self, rng: &mut Rng, ms: &MerchantSim, p: &Params, k: usize, at: Ts) {
        let s = self.subs[k].shopper as usize;
        if self.shoppers[s].sub != Some(k as u32) && time::day_of_ts(at) > time::day_of_ts(self.subs[k].end) {
            return;
        }
        let subs = ms.subs.as_ref().unwrap();
        let plan = &subs.plans[self.subs[k].plan];
        let ty = self.subs[k].ty;
        let prefs = self.shoppers[s].prefs.clone();
        let mut items: Vec<Item> = Vec::new();
        for _ in 0..plan.items * 3 {
            if items.len() >= plan.items {
                break;
            }
            let t = if rng.chance(0.8) { ty } else { prefs.pick_type(rng, ms.product_types.len()) };
            let pi = ms.product_of_type(rng, t);
            if let Some(pi) = pi {
                let mut it = self.item_for(rng, ms, pi, &prefs);
                it.qty = 1;
                if ms.in_stock(pi, it.vidx) && !items.iter().any(|x| x.pidx == pi) {
                    items.push(it);
                }
            }
        }
        if items.is_empty() {
            return;
        }
        let device = self.shoppers[s].device;
        self.order(rng, ms, p, s, None, at, items, None, String::new(), device, None, Channel::Direct, Some(subs.delivery_discount));
    }
}

fn fmt_date(t: Ts) -> String {
    chrono::DateTime::from_timestamp_micros(t).unwrap().format("%Y-%m-%d").to_string()
}

fn add_months(t: Ts, n: u32) -> Ts {
    let d = chrono::DateTime::from_timestamp_micros(t).unwrap().naive_utc();
    d.checked_add_months(chrono::Months::new(n)).unwrap().and_utc().timestamp_micros()
}
