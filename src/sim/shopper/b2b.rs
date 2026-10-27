//! B2B buyers: companies (accounts) with contacts and billing profiles, leads that convert,
//! opportunities and contracts (deals) with yearly renewals, net-terms invoicing with bank
//! transfers and reminders, credit notes for returns, quotes and purchase-order notes.
//!
//! Renewals are decisions, not scripts: an account renews its contract with a probability that
//! follows its buyers' satisfaction (late deliveries, bad support), and an account that does
//! not renew mostly stops ordering.

use std::collections::HashMap;

use super::{Item, ShopperChunk};
use crate::engine::DHandle;
use crate::rng::Rng;
use crate::sim::merchant::MerchantSim;
use crate::sim::people;
use crate::tables::*;
use crate::time::{self, Day, MICROS_PER_DAY, MICROS_PER_HOUR, MICROS_PER_MIN, MICROS_PER_SEC, Ts};
use crate::value::{Rid, Row, V};
use crate::world::world;

pub(super) struct Account {
    h: DHandle,
    pub billing: Rid,
    /// payment terms in days (0: pays by card at checkout)
    pub terms: i64,
    owner: Rid,
    name: String,
    buyers: Vec<u32>,
    contacts: u32,
    po_required: bool,
    /// mean days an invoice is paid late
    pay_late: f64,
    /// current contract: (deal, end, value)
    deal: Option<(Rid, Ts, i64)>,
    primary_contact: Rid,
}

pub(super) struct Buyer {
    pub account: u32,
    #[allow(dead_code)] // part of the data model, not used by the simulator yet
    pub contact: Rid,
    transfer_pm: Option<(Rid, &'static str, String)>,
}

#[derive(Default)]
pub(super) struct B2b {
    pub accounts: Vec<Account>,
    by_name: HashMap<String, u32>,
    /// renewal decisions per day (account)
    queue: std::collections::BTreeMap<Day, Vec<u32>>,
}

const ACTIVITY_SUBJECTS: &[(&str, &str)] = &[
    ("call", "Intro call"),
    ("email", "Sent price list and catalogue"),
    ("meeting", "Site visit"),
    ("call", "Discussed volumes and delivery schedule"),
    ("email", "Quote follow-up"),
    ("meeting", "Contract negotiation"),
    ("note", "Customer compares with incumbent supplier"),
];

fn date(t: Ts) -> V {
    V::Date(time::epoch_days(chrono::DateTime::from_timestamp_micros(t).unwrap().date_naive()))
}

/// The close date the rep expects, set when the deal is created: around the actual close, or,
/// for a stalled deal (which never closes, `close` is far in the future), a planned sales cycle of
/// about a month that has long passed.
fn expected_close(start: Ts, close: Ts, jitter_days: i64) -> Ts {
    if close >= i64::MAX / 8 { start + (30 + jitter_days) * MICROS_PER_DAY } else { close + jitter_days * MICROS_PER_DAY }
}

fn add_months(t: Ts, n: u32) -> Ts {
    let d = chrono::DateTime::from_timestamp_micros(t).unwrap().naive_utc();
    d.checked_add_months(chrono::Months::new(n)).unwrap().and_utc().timestamp_micros()
}

impl ShopperChunk {
    /// A new B2B buyer: joins their company's account or opens a new one (lead -> opportunity
    /// -> contract).
    pub(super) fn b2b_signup(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, company: &str, first_seen: Ts) {
        let tenant = ms.tenant_rid();
        let day = self.chunk.day;
        let end = time::end_ts();
        let created = self.shoppers[s].created;
        let migrated = created < time::ts_of_day(day);
        let w = world();
        let iso = w.geo.countries[self.shoppers[s].country].iso2.clone();
        let (first, last) = { let n = self.shoppers[s].first_name.clone(); (n, self.shoppers[s].last_name.clone()) };
        let email = self.shoppers[s].email.clone();
        let phone = self.shoppers[s].phone.clone();
        let existing = self.b2b.by_name.get(company).copied();
        let a = match existing {
            Some(a) => a as usize,
            None => {
                let reps = &ms.crm.reps;
                let owner = reps[(crate::rng::hash_str(company) % reps.len() as u64) as usize];
                let domain = email.split('@').nth(1).unwrap_or("example.com").to_string();
                let employees = (rng.lognormal(libm::log(40.0), 1.2)).max(2.0) as i64;
                let opened = if migrated { created } else { (first_seen - rng.int(0, 20) * MICROS_PER_DAY).min(created) };
                let industry = if ms.m.vertical == "b2b_industrial" { *rng.pick(&["Construction", "Manufacturing", "Facility services", "Logistics", "Utilities", "Automotive"]) } else { *rng.pick(&["Professional services", "Healthcare", "Education", "Public sector", "Hospitality", "Technology"]) };
                let mut r = Row::new(accounts::NCOLS);
                r.set(accounts::TENANT_ID, tenant)
                    .set(accounts::NAME, company.to_string())
                    .set(accounts::LEGAL_NAME, if rng.chance(0.6) { V::Str(company.to_string()) } else { V::Null })
                    .set(accounts::DOMAIN, domain.clone())
                    .set(accounts::INDUSTRY, industry)
                    .set(accounts::EMPLOYEE_COUNT, V::Int(employees))
                    .set(accounts::ANNUAL_REVENUE, if rng.chance(0.4) { V::Money(((employees as f64 * rng.lognormal(libm::log(120_000.0), 0.5)) / 1000.0).round() as i64 * 100_000) } else { V::Null })
                    .set(accounts::CURRENCY_CODE, ms.m.currency.clone())
                    .set(accounts::OWNER_USER_ID, owner)
                    .set(accounts::PHONE, if rng.chance(0.7) { V::Str(people::phone(rng, &iso)) } else { V::Null })
                    .set(accounts::WEBSITE, format!("https://www.{domain}"))
                    .set(accounts::IS_ACTIVE, true)
                    .set(accounts::CREATED_AT, V::Ts(opened))
                    .set(accounts::UPDATED_AT, V::Ts(created));
                let h = self.chunk.emit_deferred(accounts::T, day, r);
                let terms = if rng.chance(0.3) { 0 } else { *rng.pick(&[30, 30, 30, 14, 60]) };
                let po_required = rng.chance(0.35);
                let mut r = Row::new(billing_profiles::NCOLS);
                r.set(billing_profiles::TENANT_ID, tenant)
                    .set(billing_profiles::USER_ID, self.shoppers[s].rid)
                    .set(billing_profiles::LEGAL_NAME, company.to_string())
                    .set(billing_profiles::BILLING_EMAIL, format!("{}@{domain}", rng.pick(&["invoices", "accounts", "ap", "billing"])))
                    .set(billing_profiles::TAX_ID, if iso == "US" && rng.chance(0.5) { V::Null } else { V::Str(crate::sim::merchant::tax_id(rng, &iso)) })
                    .set(billing_profiles::NET_TERMS_DAYS, terms)
                    .set(billing_profiles::DEFAULT_CURRENCY_CODE, ms.m.currency.clone())
                    .set(billing_profiles::IS_DEFAULT, false)
                    .set(billing_profiles::METADATA, V::Json(format!(r#"{{"po_required":{po_required},"invoice_delivery":"{}"}}"#, if rng.chance(0.8) { "email" } else { "portal" })))
                    .set(billing_profiles::CREATED_AT, V::Ts(created))
                    .set(billing_profiles::UPDATED_AT, V::Ts(created));
                let billing = self.chunk.emit(billing_profiles::T, day, r);
                let pay_late = if rng.chance(0.2) { rng.lognormal(libm::log(15.0), 0.4) } else { rng.lognormal(libm::log(1.5), 0.6) };
                let k = self.b2b.accounts.len();
                self.b2b.accounts.push(Account { h, billing, terms, owner, name: company.to_string(), buyers: Vec::new(), contacts: 0, po_required, pay_late, deal: None, primary_contact: Rid::final_id(0) });
                self.b2b.by_name.insert(company.to_string(), k as u32);
                // part of a group?
                if k > 3 && rng.chance(0.05) {
                    let parent = self.b2b.accounts[rng.below(k)].h.rid;
                    let mut r = Row::new(account_relationships::NCOLS);
                    r.set(account_relationships::TENANT_ID, tenant).set(account_relationships::PARENT_ACCOUNT_ID, parent).set(account_relationships::CHILD_ACCOUNT_ID, h.rid).set(account_relationships::RELATIONSHIP_TYPE, *rng.pick(&["subsidiary", "subsidiary", "franchise", "buying_group"])).set(account_relationships::CREATED_AT, V::Ts(created)).set(account_relationships::UPDATED_AT, V::Ts(created));
                    self.chunk.emit(account_relationships::T, day, r);
                }
                k
            }
        };
        // the buyer as a CRM contact
        let primary = self.b2b.accounts[a].contacts == 0;
        self.b2b.accounts[a].contacts += 1;
        self.b2b.accounts[a].buyers.push(s as u32);
        let account_rid = self.b2b.accounts[a].h.rid;
        let owner = self.b2b.accounts[a].owner;
        let mut r = Row::new(contacts::NCOLS);
        r.set(contacts::TENANT_ID, tenant)
            .set(contacts::ACCOUNT_ID, account_rid)
            .set(contacts::OWNER_USER_ID, owner)
            .set(contacts::FIRST_NAME, first.clone())
            .set(contacts::LAST_NAME, last.clone())
            .set(contacts::PRIMARY_EMAIL, email.clone())
            .set(contacts::PHONE, phone)
            .set(contacts::JOB_TITLE, *rng.pick(&["Purchasing Manager", "Buyer", "Office Manager", "Procurement Lead", "Facility Manager", "Operations Manager"]))
            .set(contacts::DEPARTMENT, if rng.chance(0.6) { V::Static(*rng.pick(&["Purchasing", "Operations", "Administration", "Facilities"])) } else { V::Null })
            .set(contacts::IS_PRIMARY, primary)
            .set(contacts::DO_NOT_CONTACT, rng.chance(0.04))
            .set(contacts::CREATED_AT, V::Ts(created))
            .set(contacts::UPDATED_AT, V::Ts(created));
        let contact = self.chunk.emit(contacts::T, day, r);
        if primary {
            self.b2b.accounts[a].primary_contact = contact;
        }
        let mut emails = vec![(email.clone(), "work", true)];
        if rng.chance(0.15) {
            emails.push((format!("{}.{}{}@gmail.com", people::ascii_fold(&first).to_lowercase().replace(' ', ""), people::ascii_fold(&last).to_lowercase().replace(' ', ""), rng.digits(2)), "personal", false));
        }
        for (e, label, prim) in emails {
            let mut r = Row::new(contact_emails::NCOLS);
            r.set(contact_emails::TENANT_ID, tenant).set(contact_emails::CONTACT_ID, contact).set(contact_emails::EMAIL, e).set(contact_emails::LABEL, label).set(contact_emails::IS_PRIMARY, prim).set(contact_emails::VERIFIED_AT, if prim && rng.chance(0.7) { V::Ts(created + 10 * MICROS_PER_MIN) } else { V::Null }).set(contact_emails::CREATED_AT, V::Ts(created)).set(contact_emails::UPDATED_AT, V::Ts(created));
            self.chunk.emit(contact_emails::T, day, r);
        }
        for (i, list) in ms.crm.lists.iter().enumerate() {
            if (i == 0 && primary && rng.chance(0.15)) || (i == 1 && rng.chance(0.4)) {
                let mut r = Row::new(contact_list_members::NCOLS);
                r.set(contact_list_members::TENANT_ID, tenant).set(contact_list_members::CONTACT_LIST_ID, *list).set(contact_list_members::CONTACT_ID, contact).set(contact_list_members::ADDED_BY_USER_ID, owner).set(contact_list_members::CREATED_AT, V::Ts(created + MICROS_PER_HOUR));
                self.chunk.emit(contact_list_members::T, day, r);
            }
        }
        self.shoppers[s].b2b = Some(Box::new(Buyer { account: a as u32, contact, transfer_pm: None }));
        if !primary {
            return;
        }
        // a new account: the lead it came from and the first contract
        let opened = match &self.chunk.deferred_ref(self.b2b.accounts[a].h).vals[accounts::CREATED_AT] { V::Ts(t) => *t, _ => created };
        if !migrated && rng.chance(0.6) {
            let mut r = Row::new(leads::NCOLS);
            r.set(leads::TENANT_ID, tenant)
                .set(leads::OWNER_USER_ID, owner)
                .set(leads::FIRST_NAME, first.clone())
                .set(leads::LAST_NAME, last.clone())
                .set(leads::EMAIL, email.clone())
                .set(leads::COMPANY, company.to_string())
                .set(leads::STATUS, "converted")
                .set(leads::SOURCE, *rng.pick(&["website_form", "website_form", "referral", "trade_fair", "outbound"]))
                .set(leads::SCORE, V::Int(rng.int(50, 98)))
                .set(leads::CONVERTED_ACCOUNT_ID, account_rid)
                .set(leads::CONVERTED_CONTACT_ID, contact)
                .set(leads::CONVERTED_AT, V::Ts(created))
                .set(leads::CREATED_AT, V::Ts(opened))
                .set(leads::UPDATED_AT, V::Ts(created));
            self.chunk.emit(leads::T, day, r);
        }
        let amount = (ms.vertical_mid_eur * ms.price_level * ms.vertical.quantity_scale * 14.0 * rng.lognormal(0.0, 0.6) / 100.0).round().max(5.0) as i64 * 10_000;
        // S20: in H1 2025 the competitor wins most new business; deals stall in late stages
        let slump = crate::sim::stories::s20_slump(ms.m, day);
        let won = migrated || rng.chance(if slump { 0.35 } else { 0.75 });
        let stalled = slump && !won && rng.chance(0.4);
        let start = if migrated { created } else { opened };
        let close = if won { created } else if stalled { i64::MAX / 4 } else { created + rng.int(5, 40) * MICROS_PER_DAY };
        let opp = self.opportunity(rng, ms, a, contact, false, &format!("{company} - trade account"), amount, start, close, won);
        if won {
            let mut signed = close;
            let mut end_ = add_months(signed, 12);
            while end_ < time::ts_of_day(0) {
                signed = end_;
                end_ = add_months(signed, 12);
            }
            if let Some(opp) = opp {
                self.deal(rng, ms, a, opp, amount, signed, end_);
            }
        }
        let _ = end;
    }

    #[allow(clippy::too_many_arguments)]
    fn opportunity(&mut self, rng: &mut Rng, ms: &MerchantSim, a: usize, contact: Rid, renewal: bool, name: &str, amount: i64, start: Ts, close: Ts, won: bool) -> Option<Rid> {
        let end = time::end_ts();
        let tenant = ms.tenant_rid();
        let (pipe, stages) = if renewal { ms.crm.renewals.clone()? } else { ms.crm.new_business.clone()? };
        let owner = self.b2b.accounts[a].owner;
        let account = self.b2b.accounts[a].h.rid;
        let closed = close <= end;
        let stage = if closed { if won { stages[stages.len() - 2] } else { stages[stages.len() - 1] } } else { stages[(rng.below(stages.len() - 2)).min(stages.len() - 3)] };
        let mut r = Row::new(opportunities::NCOLS);
        r.set(opportunities::TENANT_ID, tenant)
            .set(opportunities::ACCOUNT_ID, account)
            .set(opportunities::PIPELINE_ID, pipe)
            .set(opportunities::STAGE_ID, stage)
            .set(opportunities::PRIMARY_CONTACT_ID, contact)
            .set(opportunities::OWNER_USER_ID, owner)
            .set(opportunities::NAME, name.to_string())
            .set(opportunities::AMOUNT, V::Money(amount))
            .set(opportunities::CURRENCY_CODE, ms.m.currency.clone())
            .set(opportunities::PROBABILITY, if closed { V::Dec(if won { 10000 } else { 0 }, 4) } else { V::Dec(rng.int(2, 8) as i128 * 1000, 4) })
            .set(opportunities::SOURCE, if renewal { "renewal" } else { "inbound" })
            .set(opportunities::IS_CLOSED, closed)
            .set(opportunities::IS_WON, closed && won)
            .set(opportunities::EXPECTED_CLOSE_DATE, date(expected_close(start, close, rng.int(-10, 10))))
            .set(opportunities::CLOSED_AT, if closed { V::Ts(close) } else { V::Null })
            .set(opportunities::CREATED_AT, V::Ts(start))
            .set(opportunities::UPDATED_AT, V::Ts(close.min(end)));
        let opp = self.emit_at(opportunities::T, start.max(time::ts_of_day(self.chunk.day)), r)?;
        // the sales conversation
        let n = 2 + rng.below(4);
        for i in 0..n {
            let at = start + (close - start).max(MICROS_PER_DAY) * (i as i64 + 1) / (n as i64 + 1) + rng.int(0, 8) * MICROS_PER_HOUR;
            if at > end {
                break;
            }
            let (kind, subj) = ACTIVITY_SUBJECTS[if renewal { 3 + rng.below(3) } else { rng.below(ACTIVITY_SUBJECTS.len()) }];
            let mut r = Row::new(activities::NCOLS);
            r.set(activities::TENANT_ID, tenant)
                .set(activities::KIND, kind)
                .set(activities::ACCOUNT_ID, account)
                .set(activities::CONTACT_ID, contact)
                .set(activities::OPPORTUNITY_ID, opp)
                .set(activities::OWNER_USER_ID, owner)
                .set(activities::SUBJECT, subj)
                .set(activities::BODY, if rng.chance(0.4) { V::Str(format!("{subj}. Next step agreed.")) } else { V::Null })
                .set(activities::OCCURRED_AT, V::Ts(at))
                .set(activities::DURATION_MINUTES, if kind == "call" || kind == "meeting" { V::Int(rng.int(10, 90)) } else { V::Null })
                .set(activities::CREATED_AT, V::Ts(at))
                .set(activities::UPDATED_AT, V::Ts(at));
            self.emit_at(activities::T, at.max(time::ts_of_day(self.chunk.day)), r);
        }
        if rng.chance(0.5) {
            let at = start + rng.int(1, 5) * MICROS_PER_HOUR;
            let body = if renewal { "Account reviewed before renewal: check open tickets and delivery performance." } else { "Interested in a framework agreement; wants volume pricing and 30-day terms." };
            let mut r = Row::new(crm_notes::NCOLS);
            r.set(crm_notes::TENANT_ID, tenant).set(crm_notes::ACCOUNT_ID, account).set(crm_notes::OPPORTUNITY_ID, opp).set(crm_notes::AUTHOR_USER_ID, owner).set(crm_notes::BODY, body).set(crm_notes::IS_PINNED, rng.chance(0.2)).set(crm_notes::CREATED_AT, V::Ts(at)).set(crm_notes::UPDATED_AT, V::Ts(at));
            self.emit_at(crm_notes::T, at.max(time::ts_of_day(self.chunk.day)), r);
        }
        for (title, prio) in [(if renewal { "Prepare renewal offer" } else { "Send quote" }, "high"), ("Follow up", "normal")] {
            let due = start + rng.int(2, 14) * MICROS_PER_DAY;
            let done_at = due - rng.int(0, 2) * MICROS_PER_DAY + rng.int(1, 8) * MICROS_PER_HOUR;
            let done = done_at <= end && rng.chance(0.9);
            let mut r = Row::new(tasks::NCOLS);
            r.set(tasks::TENANT_ID, tenant)
                .set(tasks::ASSIGNEE_USER_ID, owner)
                .set(tasks::ACCOUNT_ID, account)
                .set(tasks::OPPORTUNITY_ID, opp)
                .set(tasks::TITLE, title)
                .set(tasks::PRIORITY, prio)
                .set(tasks::IS_DONE, done)
                .set(tasks::DUE_AT, V::Ts(due))
                .set(tasks::COMPLETED_AT, if done { V::Ts(done_at) } else { V::Null })
                .set(tasks::CREATED_AT, V::Ts(start))
                .set(tasks::UPDATED_AT, V::Ts(if done { done_at } else { start }));
            self.emit_at(tasks::T, start.max(time::ts_of_day(self.chunk.day)), r);
        }
        Some(opp)
    }

    fn deal(&mut self, rng: &mut Rng, ms: &MerchantSim, a: usize, opp: Rid, value: i64, signed: Ts, ends: Ts) {
        let tenant = ms.tenant_rid();
        let owner = self.b2b.accounts[a].owner;
        let account = self.b2b.accounts[a].h.rid;
        let name = format!("{} - framework agreement {}", self.b2b.accounts[a].name, chrono::DateTime::from_timestamp_micros(signed).unwrap().format("%Y"));
        let mut r = Row::new(deals::NCOLS);
        r.set(deals::TENANT_ID, tenant)
            .set(deals::ACCOUNT_ID, account)
            .set(deals::OPPORTUNITY_ID, opp)
            .set(deals::OWNER_USER_ID, owner)
            .set(deals::NAME, name)
            .set(deals::CONTRACT_VALUE, V::Money(value))
            .set(deals::CURRENCY_CODE, ms.m.currency.clone())
            .set(deals::SIGNED_AT, date(signed))
            .set(deals::STARTS_AT, date(signed))
            .set(deals::ENDS_AT, date(ends))
            .set(deals::CREATED_AT, V::Ts(signed))
            .set(deals::UPDATED_AT, V::Ts(signed));
        let Some(deal) = self.emit_at(deals::T, signed.max(time::ts_of_day(self.chunk.day)), r) else { return };
        let day = self.chunk.day;
        for _ in 0..2 + rng.below(3) {
            let Some(pi) = ms.live_w.as_ref().map(|w| ms.live[w.sample(rng)]) else { break };
            let p = &ms.products[pi];
            let mut r = Row::new(deal_line_items::NCOLS);
            r.set(deal_line_items::TENANT_ID, tenant)
                .set(deal_line_items::DEAL_ID, deal)
                .set(deal_line_items::PRODUCT_ID, p.rid)
                .set(deal_line_items::DESCRIPTION, p.name.clone())
                .set(deal_line_items::QUANTITY, V::Int(rng.int(1, 40) * 10))
                .set(deal_line_items::UNIT_PRICE, V::Money(ms.price_now(pi, 0, day)))
                .set(deal_line_items::DISCOUNT_PCT, V::Dec(rng.int(5, 15) as i128 * 100, 4))
                .set(deal_line_items::CURRENCY_CODE, ms.m.currency.clone())
                .set(deal_line_items::CREATED_AT, V::Ts(signed))
                .set(deal_line_items::UPDATED_AT, V::Ts(signed));
            self.emit_at(deal_line_items::T, signed.max(time::ts_of_day(day)), r);
        }
        self.b2b.accounts[a].deal = Some((deal, ends, value));
        // the renewal is negotiated six weeks before the contract ends
        let decide = ends - 45 * MICROS_PER_DAY;
        let d = time::day_of_ts(decide).max(self.chunk.day as i64 + 1);
        if d < time::num_days() as i64 {
            self.b2b.queue.entry(d as Day).or_default().push(a as u32);
        }
    }

    /// S20: a parent company consolidates purchasing, the win-back list is worked, and one
    /// large former account comes back.
    fn s20_day(&mut self, rng: &mut Rng, ms: &MerchantSim, day: Day) {
        let tenant = ms.tenant_rid();
        let d = time::date_of(day);
        let at = time::ts_of_day(day) + 11 * MICROS_PER_HOUR;
        let value = |a: &Account| a.deal.map_or(0, |d| d.2);
        if d == chrono::NaiveDate::from_ymd_opt(2025, 7, 1).unwrap() {
            let mut active: Vec<usize> = (0..self.b2b.accounts.len()).filter(|&a| self.b2b.accounts[a].deal.is_some()).collect();
            active.sort_by_key(|&a| std::cmp::Reverse(value(&self.b2b.accounts[a])));
            if active.len() >= 4 {
                let parent = self.b2b.accounts[active[0]].h.rid;
                for &c in &active[1..4] {
                    let mut r = Row::new(account_relationships::NCOLS);
                    r.set(account_relationships::TENANT_ID, tenant).set(account_relationships::PARENT_ACCOUNT_ID, parent).set(account_relationships::CHILD_ACCOUNT_ID, self.b2b.accounts[c].h.rid).set(account_relationships::RELATIONSHIP_TYPE, "consolidated_purchasing").set(account_relationships::CREATED_AT, V::Ts(at)).set(account_relationships::UPDATED_AT, V::Ts(at));
                    self.chunk.emit(account_relationships::T, day, r);
                }
            }
        }
        if let (Some(list), true) = (ms.crm.winback, d == chrono::NaiveDate::from_ymd_opt(2025, 9, 2).unwrap()) {
            for a in 0..self.b2b.accounts.len() {
                if self.b2b.accounts[a].deal.is_none() && self.b2b.accounts[a].contacts > 0 {
                    let mut r = Row::new(contact_list_members::NCOLS);
                    r.set(contact_list_members::TENANT_ID, tenant).set(contact_list_members::CONTACT_LIST_ID, list).set(contact_list_members::CONTACT_ID, self.b2b.accounts[a].primary_contact).set(contact_list_members::ADDED_BY_USER_ID, self.b2b.accounts[a].owner).set(contact_list_members::CREATED_AT, V::Ts(at));
                    self.chunk.emit(contact_list_members::T, day, r);
                }
            }
        }
        if crate::sim::stories::s20_winback(ms.m, day) {
            // the biggest former account signs again at the new prices
            let back = (0..self.b2b.accounts.len()).filter(|&a| self.b2b.accounts[a].deal.is_none() && !self.b2b.accounts[a].buyers.is_empty()).max_by_key(|&a| self.b2b.accounts[a].buyers.len());
            if let Some(a) = back {
                let h = self.b2b.accounts[a].h;
                self.chunk.deferred_mut(h).set(accounts::IS_ACTIVE, true).set(accounts::UPDATED_AT, V::Ts(at));
                let contact = self.b2b.accounts[a].primary_contact;
                let name = format!("{} - win-back 2025", self.b2b.accounts[a].name);
                let amount = (ms.vertical_mid_eur * ms.price_level * ms.vertical.quantity_scale * 30.0 / 100.0).round() as i64 * 10_000;
                if let Some(opp) = self.opportunity(rng, ms, a, contact, false, &name, amount, at - 25 * MICROS_PER_DAY, at, true) {
                    self.deal(rng, ms, a, opp, amount, at, add_months(at, 12));
                }
                let buyers = self.b2b.accounts[a].buyers.clone();
                for b in buyers {
                    let b = b as usize;
                    let churned = self.shoppers[b].churn_day <= day;
                    self.shoppers[b].churn_day = self.shoppers[b].churn_day.max(day + 500);
                    self.shoppers[b].satisfaction = self.shoppers[b].satisfaction.max(1.0);
                    let next = day as usize + 1 + rng.below(7);
                    if churned && next < self.calendar.len() {
                        self.calendar[next].push((b as u32, super::Visit::Regular));
                    }
                }
            }
        }
    }

    /// Renewal decisions due today.
    pub(super) fn b2b_day(&mut self, rng: &mut Rng, ms: &MerchantSim, day: Day) {
        if crate::sim::stories::has(ms.m, "S20") {
            self.s20_day(rng, ms, day);
        }
        let Some(due) = self.b2b.queue.remove(&day) else { return };
        let end = time::end_ts();
        for a in due {
            let a = a as usize;
            let Some((_, ends, value)) = self.b2b.accounts[a].deal else { continue };
            let buyers: Vec<usize> = self.b2b.accounts[a].buyers.iter().map(|b| *b as usize).collect();
            if buyers.is_empty() {
                continue;
            }
            let sat = buyers.iter().map(|b| self.shoppers[*b].satisfaction).sum::<f64>() / buyers.len() as f64;
            let p = 1.0 / (1.0 + libm::exp(-7.0 * (sat - 0.82))) * if crate::sim::stories::s20_slump(ms.m, day) { 0.7 } else { 1.0 };
            let renew = rng.chance(p);
            let start = time::ts_of_day(day) + rng.int(8, 16) * MICROS_PER_HOUR;
            let close = (ends - rng.int(3, 30) * MICROS_PER_DAY).max(start + MICROS_PER_DAY);
            let amount = (value as f64 * rng.lognormal(0.05, 0.15) / 10_000.0).round() as i64 * 10_000;
            let contact = self.b2b.accounts[a].primary_contact;
            let name = format!("{} - renewal {}", self.b2b.accounts[a].name, chrono::DateTime::from_timestamp_micros(ends).unwrap().format("%Y"));
            let opp = self.opportunity(rng, ms, a, contact, true, &name, amount, start, close, renew);
            if close > end {
                // still being negotiated at the end of the window
                continue;
            }
            if renew {
                if let Some(opp) = opp {
                    self.deal(rng, ms, a, opp, amount, ends, add_months(ends, 12));
                }
            } else {
                // the account leaves when the contract runs out; most buyers stop ordering
                self.b2b.accounts[a].deal = None;
                if ends <= end {
                    let h = self.b2b.accounts[a].h;
                    self.chunk.deferred_mut(h).set(accounts::IS_ACTIVE, false).set(accounts::UPDATED_AT, V::Ts(ends));
                }
                let stop = time::day_of_ts(ends).max(day as i64) as Day;
                for b in buyers {
                    if rng.chance(0.75) {
                        self.shoppers[b].churn_day = self.shoppers[b].churn_day.min(stop);
                    }
                }
            }
        }
    }

    /// Payment terms of a buyer's account: (billing profile, days).
    pub(super) fn b2b_terms(&self, s: usize) -> Option<(Rid, i64, usize)> {
        let b = self.shoppers[s].b2b.as_ref()?;
        let a = &self.b2b.accounts[b.account as usize];
        (a.terms > 0).then_some((a.billing, a.terms, b.account as usize))
    }

    pub(super) fn transfer_method(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, at: Ts) -> (Rid, &'static str, String) {
        if let Some(pm) = self.shoppers[s].b2b.as_ref().and_then(|b| b.transfer_pm.clone()) {
            return pm;
        }
        let mut r = Row::new(payment_methods::NCOLS);
        r.set(payment_methods::TENANT_ID, ms.tenant_rid())
            .set(payment_methods::USER_ID, self.shoppers[s].rid)
            .set(payment_methods::KIND, "bank_transfer")
            .set(payment_methods::GATEWAY, "Bank transfer")
            .set(payment_methods::GATEWAY_TOKEN, format!("iban_{}", rng.alnum(22)))
            .set(payment_methods::IS_DEFAULT, true)
            .set(payment_methods::BILLING_ADDRESS_ID, self.shoppers[s].address)
            .set(payment_methods::CREATED_AT, V::Ts(at - 30 * MICROS_PER_SEC))
            .set(payment_methods::UPDATED_AT, V::Ts(at - 30 * MICROS_PER_SEC));
        let rid = self.chunk.emit(payment_methods::T, self.chunk.day, r);
        let pm = (rid, "bank_transfer", "Bank transfer".to_string());
        if let Some(b) = self.shoppers[s].b2b.as_mut() {
            b.transfer_pm = Some(pm.clone());
        }
        pm
    }

    /// Invoice an order on payment terms when it ships; the bank transfer arrives around the
    /// due date (some accounts always pay late, a few never). Returns (invoice, lines).
    #[allow(clippy::too_many_arguments)]
    pub(super) fn terms_invoice(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, order: Rid, items: &[Item], lines: &[(i64, i64, i64)], discs: &[i64], shipping: i64, issued: Ts, credit: Option<(Ts, i64)>, pm: (Rid, &'static str, String)) -> Option<(Rid, Vec<Rid>)> {
        let end = time::end_ts();
        if issued > end {
            return None;
        }
        let (billing, terms, a) = self.b2b_terms(s)?;
        let tenant = ms.tenant_rid();
        let cur = ms.m.currency.clone();
        let subtotal: i64 = lines.iter().map(|l| l.1).sum::<i64>() + shipping;
        let discount: i64 = discs.iter().sum();
        let tax: i64 = lines.iter().map(|l| l.2).sum();
        let total = subtotal + tax;
        let due = issued + terms * MICROS_PER_DAY;
        let bad_debt = rng.chance(0.004);
        let late = self.b2b.accounts[a].pay_late * rng.lognormal(0.0, 0.5) - rng.uniform(0.0, 3.0);
        let paid_at = if bad_debt { None } else { Some(due + (late * MICROS_PER_DAY as f64) as i64 + rng.int(8, 16) * MICROS_PER_HOUR) };
        // a credit note before payment is deducted; after payment it becomes store credit
        let deduct = credit.filter(|(t, _)| paid_at.is_none_or(|p| *t < p)).map_or(0, |c| c.1);
        let paid = paid_at.filter(|t| *t <= end);
        let pay_amount = total - deduct;
        let status = if paid.is_some() { "paid" } else if bad_debt && due + 120 * MICROS_PER_DAY <= end { "uncollectible" } else if due <= end { "past_due" } else { "open" };
        let po = if self.b2b.accounts[a].po_required || rng.chance(0.3) { Some(format!("PO {}{}", rng.pick(&["4500", "PO-", "", "BS"]), rng.digits(6))) } else { None };
        let mut r = Row::new(invoices::NCOLS);
        r.set(invoices::PUBLIC_ID, V::Uuid(rng.uuid()))
            .set(invoices::TENANT_ID, tenant)
            .set(invoices::BILLING_PROFILE_ID, billing)
            .set(invoices::USER_ID, self.shoppers[s].rid)
            .set(invoices::ORDER_ID, order)
            .set(invoices::INVOICE_NUMBER, "INV-")
            .set(invoices::STATUS, status)
            .set(invoices::CURRENCY_CODE, cur.clone())
            .set(invoices::SUBTOTAL, V::Money(subtotal))
            .set(invoices::TAX_TOTAL, V::Money(tax))
            .set(invoices::DISCOUNT_TOTAL, V::Money(discount))
            .set(invoices::TOTAL, V::Money(total))
            .set(invoices::AMOUNT_PAID, V::Money(if paid.is_some() { pay_amount } else { 0 }))
            .set(invoices::AMOUNT_DUE, V::Money(if paid.is_some() { 0 } else { pay_amount }))
            .set(invoices::ISSUED_AT, V::Ts(issued))
            .set(invoices::DUE_AT, V::Ts(due))
            .set(invoices::PAID_AT, V::opt_ts(paid))
            .set(invoices::NOTES, po.clone())
            .set(invoices::CREATED_AT, V::Ts(issued))
            .set(invoices::UPDATED_AT, V::Ts(paid.unwrap_or(issued.max(due.min(end)))));
        let invoice = self.emit_at(invoices::T, issued, r)?;
        let mut line_rids = Vec::new();
        for (it, (unit, line, tx)) in items.iter().zip(lines) {
            let mut r = Row::new(invoice_lines::NCOLS);
            r.set(invoice_lines::TENANT_ID, tenant)
                .set(invoice_lines::INVOICE_ID, invoice)
                .set(invoice_lines::DESCRIPTION, format!("{} ({})", it.name, it.sku))
                .set(invoice_lines::QUANTITY, V::Dec(it.qty as i128 * 10000, 4))
                .set(invoice_lines::UNIT_PRICE, V::Money(*unit))
                .set(invoice_lines::LINE_TOTAL, V::Money(*line))
                .set(invoice_lines::TAX_AMOUNT, V::Money(*tx))
                .set(invoice_lines::CURRENCY_CODE, cur.clone())
                .set(invoice_lines::CREATED_AT, V::Ts(issued))
                .set(invoice_lines::UPDATED_AT, V::Ts(issued));
            line_rids.push(self.emit_at(invoice_lines::T, issued, r).unwrap());
        }
        if shipping > 0 {
            let mut r = Row::new(invoice_lines::NCOLS);
            r.set(invoice_lines::TENANT_ID, tenant).set(invoice_lines::INVOICE_ID, invoice).set(invoice_lines::DESCRIPTION, "Shipping").set(invoice_lines::QUANTITY, V::Dec(10000, 4)).set(invoice_lines::UNIT_PRICE, V::Money(shipping)).set(invoice_lines::LINE_TOTAL, V::Money(shipping)).set(invoice_lines::TAX_AMOUNT, V::Money(0)).set(invoice_lines::CURRENCY_CODE, cur.clone()).set(invoice_lines::CREATED_AT, V::Ts(issued)).set(invoice_lines::UPDATED_AT, V::Ts(issued));
            self.emit_at(invoice_lines::T, issued, r);
        }
        if let Some(po) = po {
            let mut r = Row::new(order_notes::NCOLS);
            r.set(order_notes::TENANT_ID, tenant).set(order_notes::ORDER_ID, order).set(order_notes::AUTHOR_USER_ID, self.b2b.accounts[a].owner).set(order_notes::BODY, format!("Customer reference: {po}")).set(order_notes::IS_PINNED, true).set(order_notes::CREATED_AT, V::Ts(issued - MICROS_PER_HOUR)).set(order_notes::UPDATED_AT, V::Ts(issued - MICROS_PER_HOUR));
            self.emit_at(order_notes::T, issued, r);
        }
        // reminders for overdue invoices
        let mut n = 0;
        for off in [7i64, 21, 45] {
            let at = due + off * MICROS_PER_DAY + rng.int(8, 10) * MICROS_PER_HOUR;
            if at > end || paid_at.is_some_and(|p| p <= at) {
                break;
            }
            n += 1;
            let mut r = Row::new(dunning_attempts::NCOLS);
            r.set(dunning_attempts::TENANT_ID, tenant)
                .set(dunning_attempts::INVOICE_ID, invoice)
                .set(dunning_attempts::ATTEMPT_NUMBER, n)
                .set(dunning_attempts::OUTCOME, if off == 45 { "escalated" } else { "reminder_sent" })
                .set(dunning_attempts::NEXT_ATTEMPT_AT, if off < 45 { V::Ts(due + [21, 45][n - 1] * MICROS_PER_DAY) } else { V::Null })
                .set(dunning_attempts::ATTEMPTED_AT, V::Ts(at))
                .set(dunning_attempts::CREATED_AT, V::Ts(at))
                .set(dunning_attempts::UPDATED_AT, V::Ts(at));
            self.emit_at(dunning_attempts::T, at, r);
        }
        if let Some(p) = paid {
            let (pm_rid, _, gw) = pm;
            let mut r = Row::new(payments::NCOLS);
            r.set(payments::TENANT_ID, tenant)
                .set(payments::ORDER_ID, order)
                .set(payments::INVOICE_ID, invoice)
                .set(payments::PAYMENT_METHOD_ID, pm_rid)
                .set(payments::STATUS, "captured")
                .set(payments::AMOUNT, V::Money(pay_amount))
                .set(payments::AMOUNT_REFUNDED, V::Money(0))
                .set(payments::CURRENCY_CODE, cur.clone())
                .set(payments::GATEWAY, gw)
                .set(payments::GATEWAY_CHARGE_ID, format!("bt_{}", rng.alnum(16)))
                .set(payments::CAPTURED_AT, V::Ts(p))
                .set(payments::METADATA, V::Json(format!(r#"{{"remittance":"{}","days_late":{}}}"#, rng.digits(10), ((p - due) / MICROS_PER_DAY).max(0))))
                .set(payments::CREATED_AT, V::Ts(p))
                .set(payments::UPDATED_AT, V::Ts(p));
            let payment = self.emit_at(payments::T, p, r).unwrap();
            let mut r = Row::new(payment_attempts::NCOLS);
            r.set(payment_attempts::TENANT_ID, tenant).set(payment_attempts::PAYMENT_ID, payment).set(payment_attempts::ATTEMPT_NUMBER, 1).set(payment_attempts::STATUS, "captured").set(payment_attempts::AMOUNT, V::Money(pay_amount)).set(payment_attempts::CURRENCY_CODE, cur.clone()).set(payment_attempts::GATEWAY_RESPONSE, V::Json(r#"{"status":"matched","method":"bank_statement"}"#.to_string())).set(payment_attempts::ATTEMPTED_AT, V::Ts(p)).set(payment_attempts::CREATED_AT, V::Ts(p)).set(payment_attempts::UPDATED_AT, V::Ts(p));
            self.emit_at(payment_attempts::T, p, r);
            let lg = ms.ledger.as_ref().unwrap();
            let goods: i64 = lines.iter().map(|l| l.1).sum();
            // a credit note issued before payment reduced what the customer transferred
            self.ledger(ms, rng, payment, p + MICROS_PER_HOUR, &[(lg.bank, "debit", pay_amount), (lg.refunds, "debit", deduct), (lg.revenue, "credit", goods), (lg.vat, "credit", tax), (lg.shipping_income, "credit", shipping)], "Invoice paid by bank transfer");
        }
        // a credit after payment is kept as store credit
        if let Some((t, amount)) = credit.filter(|_| deduct == 0) {
            if t <= end && amount > 0 {
                self.credit_wallet(ms, s, amount, t);
            }
        }
        Some((invoice, line_rids))
    }

    /// A credit note for returned items on an invoiced order.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn credit_note(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, invoice: (Rid, Vec<Rid>), items: &[Item], lines: &[(i64, i64, i64)], returned: &[(usize, i64, &'static str)], at: Ts) {
        if at > time::end_ts() {
            return;
        }
        let Some((billing, _, _)) = self.b2b_terms(s) else { return };
        let tenant = ms.tenant_rid();
        let cur = ms.m.currency.clone();
        let mut sub = 0;
        let mut tax = 0;
        let mut out = Vec::new();
        for (i, q, reason) in returned {
            let net = lines[*i].1 / items[*i].qty * q;
            let t = lines[*i].2 / items[*i].qty * q;
            sub += net;
            tax += t;
            out.push((*i, *q, net, t, *reason));
        }
        let mut r = Row::new(credit_notes::NCOLS);
        r.set(credit_notes::TENANT_ID, tenant)
            .set(credit_notes::INVOICE_ID, invoice.0)
            .set(credit_notes::BILLING_PROFILE_ID, billing)
            .set(credit_notes::CREDIT_NOTE_NUMBER, "CN-")
            .set(credit_notes::CURRENCY_CODE, cur.clone())
            .set(credit_notes::SUBTOTAL, V::Money(sub))
            .set(credit_notes::TAX_TOTAL, V::Money(tax))
            .set(credit_notes::TOTAL, V::Money(sub + tax))
            .set(credit_notes::REASON, out.first().map(|o| o.4.to_string()))
            .set(credit_notes::ISSUED_AT, V::Ts(at))
            .set(credit_notes::CREATED_AT, V::Ts(at - rng.int(1, 60) * MICROS_PER_MIN))
            .set(credit_notes::UPDATED_AT, V::Ts(at));
        let Some(cn) = self.emit_at(credit_notes::T, at, r) else { return };
        for (i, q, net, t, _) in out {
            let mut r = Row::new(credit_note_lines::NCOLS);
            r.set(credit_note_lines::TENANT_ID, tenant)
                .set(credit_note_lines::CREDIT_NOTE_ID, cn)
                .set(credit_note_lines::INVOICE_LINE_ID, invoice.1[i])
                .set(credit_note_lines::DESCRIPTION, format!("Return: {}", items[i].name))
                .set(credit_note_lines::QUANTITY, V::Dec(q as i128 * 10000, 4))
                .set(credit_note_lines::UNIT_PRICE, V::Money(lines[i].0))
                .set(credit_note_lines::LINE_TOTAL, V::Money(net))
                .set(credit_note_lines::TAX_AMOUNT, V::Money(t))
                .set(credit_note_lines::CURRENCY_CODE, cur.clone())
                .set(credit_note_lines::CREATED_AT, V::Ts(at))
                .set(credit_note_lines::UPDATED_AT, V::Ts(at));
            self.emit_at(credit_note_lines::T, at, r);
        }
    }

    /// Large B2B orders are quoted by the sales rep first (sometimes a quote expires and is
    /// redone).
    #[allow(clippy::too_many_arguments)]
    pub(super) fn quote(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, order: Rid, items: &[Item], subtotal: i64, grand: i64, at: Ts) {
        let Some(b) = self.shoppers[s].b2b.as_ref() else { return };
        let owner = self.b2b.accounts[b.account as usize].owner;
        let tenant = ms.tenant_rid();
        let lines: Vec<String> = items.iter().map(|i| format!(r#"{{"sku":{},"quantity":{},"unit_price":"{}.{:02}"}}"#, super::json_str(&i.sku), i.qty, i.unit_gross / 100, i.unit_gross % 100)).collect();
        let payload = format!(r#"{{"line_items":[{}],"source":"sales_rep","terms":"net"}}"#, lines.join(","));
        let created = at - rng.int(1, 8) * MICROS_PER_DAY - rng.int(0, 8) * MICROS_PER_HOUR;
        let versions = if rng.chance(0.15) { 2 } else { 1 };
        for v in 0..versions {
            let last = v + 1 == versions;
            let c = created - (versions - 1 - v) as i64 * 16 * MICROS_PER_DAY;
            let mut r = Row::new(draft_orders::NCOLS);
            r.set(draft_orders::TENANT_ID, tenant)
                .set(draft_orders::USER_ID, self.shoppers[s].rid)
                .set(draft_orders::CREATED_BY_USER_ID, owner)
                .set(draft_orders::CONVERTED_ORDER_ID, if last { V::Ref(order) } else { V::Null })
                .set(draft_orders::NAME, format!("Quote {}", rng.digits(6)))
                .set(draft_orders::STATUS, if last { "completed" } else { "expired" })
                .set(draft_orders::CURRENCY_CODE, ms.m.currency.clone())
                .set(draft_orders::SUBTOTAL, V::Money(subtotal))
                .set(draft_orders::GRAND_TOTAL, V::Money(grand))
                .set(draft_orders::PAYLOAD, V::Json(payload.clone()))
                .set(draft_orders::EXPIRES_AT, V::Ts(c + 14 * MICROS_PER_DAY))
                .set(draft_orders::CREATED_AT, V::Ts(c))
                .set(draft_orders::UPDATED_AT, V::Ts(if last { at } else { c + 14 * MICROS_PER_DAY }));
            self.emit_at(draft_orders::T, at, r);
        }
    }
}

/// A company name for a new B2B buyer in a country (for the merchant's routing).
pub fn company_name(rng: &mut Rng, country: &crate::world::Country, vertical: &str) -> String {
    let p = people::person(rng, country);
    let word = if vertical == "b2b_industrial" {
        *rng.pick(match country.iso2.as_str() { "DE" | "AT" | "CH" => &["Bau", "Metallbau", "Haustechnik", "Elektro", "Logistik", "Industrieservice"][..], "NL" | "BE" => &["Bouw", "Techniek", "Installatie", "Logistiek", "Metaal"][..], _ => &["Construction", "Engineering", "Maintenance", "Electrical", "Logistics", "Fabrication"][..] })
    } else {
        *rng.pick(match country.iso2.as_str() { "DE" | "AT" | "CH" => &["Steuerberatung", "Architekten", "Praxis", "Consulting", "Immobilien"][..], "FR" => &["Conseil", "Architectes", "Cabinet", "Services"][..], _ => &["Consulting", "Legal", "Architects", "Accountants", "Clinic", "Agency"][..] })
    };
    let suffix = match country.iso2.as_str() {
        "DE" | "AT" => "GmbH",
        "CH" => "AG",
        "GB" | "IE" => "Ltd",
        "NL" => "B.V.",
        "BE" => "BV",
        "FR" => "SAS",
        "NO" => "AS",
        "SE" => "AB",
        "DK" => "ApS",
        "FI" => "Oy",
        _ => if rng.chance(0.5) { "Inc." } else { "LLC" },
    };
    if rng.chance(0.3) {
        let q = people::person(rng, country);
        format!("{} & {} {word} {suffix}", p.last, q.last)
    } else {
        format!("{} {word} {suffix}", p.last)
    }
}

/// Email domain of a company.
pub fn company_domain(name: &str, iso2: &str) -> String {
    let tld: String = match iso2 { "GB" => "co.uk".into(), "US" => "com".into(), x => x.to_lowercase() };
    format!("{}.{}", company_slug(name), tld)
}

/// The company's name without its legal form: "Chen Electrical LLC" and "Chen Electrical Inc."
/// share it, and with it their email domain.
pub fn company_slug(name: &str) -> String {
    let base: String = name.split(' ').filter(|w| !["GmbH", "AG", "Ltd", "B.V.", "BV", "SAS", "AS", "AB", "ApS", "Oy", "Inc.", "LLC", "&"].contains(w)).collect::<Vec<_>>().join("-");
    people::slugify(&base)
}
