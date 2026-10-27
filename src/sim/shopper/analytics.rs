//! Shopper-side analytics: experiment assignments, feature usage counters, the monthly KPI
//! inputs and cohort membership reported to the merchant.

use super::ShopperChunk;
use crate::rng::Rng;
use crate::sim::merchant::{MerchantSim, MonthKpi};
use crate::tables::*;
use crate::time::{self, Day, MICROS_PER_DAY, MICROS_PER_HOUR, Ts};
use crate::value::{Row, V};

impl ShopperChunk {
    /// The running experiment a visit falls into, and the visitor's variant (assigned on the
    /// first exposure).
    pub(super) fn experiment(&mut self, rng: &mut Rng, ms: &MerchantSim, s: Option<usize>, anon: u128, at: Ts) -> Option<(usize, usize)> {
        let e = ms.analytics.experiments.iter().position(|e| e.start <= at && at < e.end)?;
        if let Some(s) = s {
            if let Some(&(_, v)) = self.shoppers[s].exps.iter().find(|(x, _)| *x as usize == e) {
                return Some((e, v as usize));
            }
        }
        // S11: an assignment bug sends returning customers to the treatment more often
        let v = if crate::sim::stories::s11_biased(ms.m, &ms.analytics.experiments[e].key) {
            let returning = s.is_some_and(|s| self.shoppers[s].orders > 0);
            usize::from(rng.chance(if returning { 0.68 } else { 0.5 }))
        } else {
            rng.below(ms.analytics.experiments[e].variants.len())
        };
        let ex = &ms.analytics.experiments[e];
        let mut r = Row::new(experiment_assignments::NCOLS);
        r.set(experiment_assignments::TENANT_ID, ms.tenant_rid())
            .set(experiment_assignments::EXPERIMENT_ID, ex.rid)
            .set(experiment_assignments::VARIANT_ID, ex.variants[v].0)
            .set(experiment_assignments::USER_ID, V::opt_ref(s.map(|s| self.shoppers[s].rid)))
            .set(experiment_assignments::ANONYMOUS_ID, V::Uuid(anon))
            .set(experiment_assignments::ASSIGNED_AT, V::Ts(at))
            .set(experiment_assignments::CREATED_AT, V::Ts(at))
            .set(experiment_assignments::UPDATED_AT, V::Ts(at));
        self.emit_at(experiment_assignments::T, at, r);
        if let Some(s) = s {
            self.shoppers[s].exps.push((e as u8, v as u8));
        }
        Some((e, v))
    }

    /// Count a storefront feature used by a shopper today (one row per user, feature and day).
    pub(super) fn use_feature(&mut self, ms: &MerchantSim, s: usize, feature: &'static str, at: Ts) {
        let day = self.chunk.day;
        if self.shoppers[s].feat.as_deref().is_some_and(|(d, _)| *d != day) {
            self.flush_features(ms, s);
        }
        let f = self.shoppers[s].feat.get_or_insert_with(|| Box::new((day, Vec::new())));
        match f.1.iter_mut().find(|x| x.0 == feature) {
            Some(x) => {
                x.1 += 1;
                x.2 = x.2.max(at);
            }
            None => f.1.push((feature, 1, at)),
        }
    }

    pub(super) fn flush_features(&mut self, ms: &MerchantSim, s: usize) {
        let Some(f) = self.shoppers[s].feat.take() else { return };
        let (d, list) = *f;
        for (feature, n, last) in list {
            if last > time::end_ts() {
                continue;
            }
            let mut r = Row::new(feature_usage::NCOLS);
            r.set(feature_usage::TENANT_ID, ms.tenant_rid())
                .set(feature_usage::USER_ID, self.shoppers[s].rid)
                .set(feature_usage::FEATURE_KEY, feature)
                .set(feature_usage::USAGE_COUNT, V::Int(n))
                .set(feature_usage::USAGE_DAY, V::Date(time::epoch_days(time::date_of(d))))
                .set(feature_usage::LAST_USED_AT, V::Ts(last))
                .set(feature_usage::OCCURRED_AT, V::Ts(time::ts_of_day(d)))
                .set(feature_usage::CREATED_AT, V::Ts((time::ts_of_day(d + 1) + 3 * MICROS_PER_HOUR).min(time::end_ts())));
            self.chunk.emit(feature_usage::T, self.chunk.day, r);
        }
    }

    /// Start of a month: active and repeat customers and MRR of the month before.
    pub(super) fn month_kpi(&mut self, ms: &MerchantSim, day: Day) {
        use chrono::Datelike;
        let date = time::date_of(day);
        if date.day() != 1 || day == 0 {
            return;
        }
        let from = time::ts_of_date(date.checked_sub_months(chrono::Months::new(1)).unwrap());
        let to = time::ts_of_day(day);
        let mut k = MonthKpi::default();
        for sh in &self.shoppers {
            if sh.mkt.last_order.is_some_and(|t| t >= from && t < to) {
                k.active += 1;
                if sh.orders >= 2 {
                    k.repeat += 1;
                }
            }
        }
        if let Some(subs) = ms.subs.as_ref() {
            for sh in &self.shoppers {
                if let Some(i) = sh.sub {
                    let (p, v) = self.sub_plan(i as usize);
                    let plan = &subs.plans[p];
                    let months = if plan.weeks > 0 { plan.weeks as f64 / 4.345 } else { plan.months as f64 };
                    k.mrr += (plan.versions[v].amount as f64 / months).round() as i64;
                }
            }
        }
        self.outbox.entry(day).or_default().kpi = Some(k);
    }

    /// Members of the cohort the merchant created today.
    pub(super) fn cohort_members(&mut self, ms: &MerchantSim, day: Day) {
        let Some((cohort, from, to, influencer)) = ms.analytics.cohort_today else { return };
        let tenant = ms.tenant_rid();
        let at = time::ts_of_day(day) + 4 * MICROS_PER_HOUR + 5 * 60_000_000;
        let mut n = 0;
        for s in 0..self.shoppers.len() {
            let c = self.shoppers[s].created;
            if c >= from && c < to && (!influencer || self.shoppers[s].influencer) {
                let mut r = Row::new(cohort_members::NCOLS);
                r.set(cohort_members::TENANT_ID, tenant).set(cohort_members::COHORT_ID, cohort).set(cohort_members::USER_ID, self.shoppers[s].rid).set(cohort_members::ADDED_AT, V::Ts(at)).set(cohort_members::CREATED_AT, V::Ts(at)).set(cohort_members::UPDATED_AT, V::Ts(at));
                self.chunk.emit(cohort_members::T, day, r);
                n += 1;
            }
        }
        self.outbox.entry(day).or_default().kpi.get_or_insert_with(MonthKpi::default).cohort = n;
        let _ = MICROS_PER_DAY;
    }
}

impl ShopperChunk {
    /// S10: the shopper installs the merchant's app (a push token; visits more often).
    pub(super) fn install_app(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, at: Ts) {
        let ios = !self.shoppers[s].ua.contains("Android");
        self.shoppers[s].app = true;
        self.shoppers[s].visit_rate *= 1.6;
        let mut r = Row::new(push_tokens::NCOLS);
        r.set(push_tokens::TENANT_ID, ms.tenant_rid())
            .set(push_tokens::USER_ID, self.shoppers[s].rid)
            .set(push_tokens::PLATFORM, if ios { "ios" } else { "android" })
            .set(push_tokens::TOKEN, if ios { rng.hex(64) } else { format!("{}:APA91b{}", rng.alnum(11), rng.alnum(134)) })
            .set(push_tokens::DEVICE_NAME, if ios { V::Static("iPhone") } else { V::Static("Android phone") })
            .set(push_tokens::IS_ACTIVE, true)
            .set(push_tokens::LAST_USED_AT, V::Ts(at))
            .set(push_tokens::CREATED_AT, V::Ts(at))
            .set(push_tokens::UPDATED_AT, V::Ts(at));
        self.emit_at(push_tokens::T, at, r);
        self.use_feature(ms, s, "app_install", at);
    }
}
