//! Shopper side of marketing and profiles: consent and preferences at signup, devices,
//! marketing emails (delivery, opens, clicks, unsubscribes), attribution of orders, loyalty
//! points, referrals, pre-sales chat threads and segment membership.
//!
//! Email engagement is a latent trait: engaged subscribers open and click, clicks bring them
//! to the shop (an email-channel visit), and frequent mail to disengaged subscribers ends in
//! unsubscribes. Apple Mail Privacy Protection "opens" every mail for some iPhone users.

use super::journey::Channel;
use super::{ShopperChunk, Visit};
use crate::engine::DHandle;
use crate::rng::{Rng, format_uuid};
use crate::sim::merchant::{MerchantSim, SegmentKind};
use crate::sim::people::Device;
use crate::tables::*;
use crate::time::{self, Day, MICROS_PER_DAY, MICROS_PER_HOUR, MICROS_PER_MIN, MICROS_PER_SEC, Ts};
use crate::value::{Rid, Row, V};
use crate::world::world;

/// Marketing state of one shopper.
#[derive(Default)]
pub(super) struct Mkt {
    pub opt_in: bool,
    /// false after a hard bounce
    pub email_ok: bool,
    /// probability of reading a marketing email
    pub engagement: f64,
    /// Apple Mail Privacy Protection: every email is "opened" by the mail client
    pub mpp: bool,
    pub prefs_row: Option<DHandle>,
    /// device profiles of the primary and the second device
    pub devices: [Option<DHandle>; 2],
    pub loyalty: Option<Box<Loyalty>>,
    /// own referral code: (row, created, redemptions)
    pub referral: Option<Box<(DHandle, Ts, i64)>>,
    /// referred by this shopper of the same chunk
    pub referred_by: Option<u32>,
    pub last_click: Option<Box<(Rid, Ts, Option<DHandle>)>>,
    pub first_order: Option<Ts>,
    pub third_order: Option<Ts>,
    pub last_order: Option<Ts>,
}

pub(super) struct Loyalty {
    h: DHandle,
    balance: i64,
    lifetime: i64,
}

/// A click in a marketing email; becomes an email-channel visit.
#[derive(Clone)]
pub(super) struct Click {
    pub at: Ts,
    pub campaign: Rid,
    pub utm: String,
    pub landing: usize,
    pub promo: bool,
    pub ab: Option<DHandle>,
    pub winback: bool,
}

const REDEEM_POINTS: i64 = 500;
const MAX_REFERRALS: i64 = 10;

fn policy_version(at: Ts) -> &'static str {
    if at < time::ts_of_date(chrono::NaiveDate::from_ymd_opt(2024, 5, 21).unwrap()) { "2022-11" } else { "2024-05" }
}

fn channel_name(c: Channel) -> &'static str {
    match c {
        Channel::Direct => "direct",
        Channel::Organic => "organic_search",
        Channel::PaidSearch => "paid_search",
        Channel::Social => "social",
        Channel::PaidSocial => "paid_social",
        Channel::Email => "email",
        Channel::Referral => "referral",
    }
}

/// (os, os version, browser, browser version) from one of our user agents.
fn parse_ua(ua: &str) -> (&'static str, String, &'static str, String) {
    let after = |key: &str, stop: &[char]| -> String {
        ua.split(key).nth(1).map(|r| r.split(|c| stop.contains(&c)).next().unwrap_or("").to_string()).unwrap_or_default()
    };
    let (os, osv) = if ua.contains("iPhone") || ua.contains("iPad") {
        ("iOS", after("OS ", &[' ']).replace('_', "."))
    } else if ua.contains("Android") {
        ("Android", after("Android ", &[';', ')']))
    } else if ua.contains("Mac OS X") {
        ("macOS", after("Mac OS X ", &[';', ')']).replace('_', "."))
    } else if ua.contains("Windows") {
        ("Windows", "10".to_string())
    } else {
        ("Linux", String::new())
    };
    let (br, brv) = if ua.contains("Edg/") {
        ("Edge", after("Edg/", &[' ']))
    } else if ua.contains("SamsungBrowser/") {
        ("Samsung Internet", after("SamsungBrowser/", &[' ']))
    } else if ua.contains("CriOS/") {
        ("Chrome", after("CriOS/", &[' ']))
    } else if ua.contains("Firefox/") {
        ("Firefox", after("Firefox/", &[' ']))
    } else if ua.contains("Chrome/") {
        ("Chrome", after("Chrome/", &[' ']))
    } else {
        ("Safari", after("Version/", &[' ']))
    };
    (os, osv, br, brv)
}

impl ShopperChunk {
    /// Preferences, consents, contact channels, device, loyalty enrolment at signup.
    pub(super) fn signup_profile(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, first_seen: Ts) {
        let tenant = ms.tenant_rid();
        let day = self.chunk.day;
        let w = world();
        let (user, created, consent, ip, iso) = {
            let sh = &self.shoppers[s];
            (sh.rid, sh.created, sh.consent, sh.ip.clone(), w.geo.countries[sh.country].iso2.clone())
        };
        let gdpr = super::is_eu(&iso) || iso == "GB" || iso == "NO" || iso == "CH";
        let opt_in = rng.chance(if gdpr { 0.38 } else { 0.5 });
        let mpp = self.shoppers[s].ua.contains("iPhone") && rng.chance(0.55);
        let fickle = self.shoppers[s].influencer;
        {
            let m = &mut self.shoppers[s].mkt;
            m.opt_in = opt_in;
            m.email_ok = true;
            m.engagement = rng.lognormal(libm::log(0.18), 0.75).min(0.9) * if fickle { 0.4 } else { 1.0 };
            m.mpp = mpp;
        }
        let mut r = Row::new(user_preferences::NCOLS);
        r.set(user_preferences::TENANT_ID, tenant)
            .set(user_preferences::USER_ID, user)
            .set(user_preferences::THEME, if rng.chance(0.85) { "system" } else if rng.chance(0.7) { "dark" } else { "light" })
            .set(user_preferences::EMAIL_OPT_IN, true)
            .set(user_preferences::MARKETING_OPT_IN, opt_in)
            .set(user_preferences::LOCALE_OVERRIDE, if rng.chance(0.04) { V::Static(*rng.pick(&["en-GB", "en-US", "de-DE", "fr-FR", "nl-NL"])) } else { V::Null })
            .set(user_preferences::CREATED_AT, V::Ts(created))
            .set(user_preferences::UPDATED_AT, V::Ts(created));
        self.shoppers[s].mkt.prefs_row = Some(self.chunk.emit_deferred(user_preferences::T, day, r));
        // consents: the cookie banner (only consented visitors are tracked) and marketing email
        let mut consents: Vec<(&str, &str, Ts)> = Vec::new();
        if consent {
            consents.push(("analytics_cookies", "cookie_banner", first_seen));
        }
        if opt_in {
            consents.push(("marketing_email", "signup_form", created));
        }
        for (purpose, source, at) in consents {
            let mut r = Row::new(consent_records::NCOLS);
            r.set(consent_records::TENANT_ID, tenant)
                .set(consent_records::USER_ID, user)
                .set(consent_records::PURPOSE, purpose)
                .set(consent_records::STATUS, "granted")
                .set(consent_records::SOURCE, source)
                .set(consent_records::POLICY_VERSION, policy_version(at))
                .set(consent_records::IP_ADDRESS, ip.clone())
                .set(consent_records::GRANTED_AT, V::Ts(at))
                .set(consent_records::EXPIRES_AT, if purpose == "analytics_cookies" && gdpr { V::Ts(at + 395 * MICROS_PER_DAY) } else { V::Null })
                .set(consent_records::OCCURRED_AT, V::Ts(at))
                .set(consent_records::CREATED_AT, V::Ts(created));
            self.chunk.emit(consent_records::T, day, r);
        }
        // contact channels
        let (email, phone) = (self.shoppers[s].email.clone(), self.shoppers[s].phone.clone());
        let verified = rng.chance(0.82);
        let vt = created + (rng.exp(40.0) * MICROS_PER_MIN as f64) as i64 + 30 * MICROS_PER_SEC;
        let mut chans = vec![("email", email, verified, vt)];
        if let Some(ph) = phone {
            let pv = rng.chance(0.5);
            chans.push(("phone", ph, pv, created + rng.int(1, 600) * MICROS_PER_SEC));
        }
        for (kind, addr, ver, at) in chans {
            let mut r = Row::new(contact_channels::NCOLS);
            r.set(contact_channels::TENANT_ID, tenant)
                .set(contact_channels::USER_ID, user)
                .set(contact_channels::KIND, kind)
                .set(contact_channels::CHANNEL_ADDRESS, addr)
                .set(contact_channels::IS_PRIMARY, true)
                .set(contact_channels::IS_VERIFIED, ver)
                .set(contact_channels::VERIFIED_AT, if ver { V::Ts(at) } else { V::Null })
                .set(contact_channels::CREATED_AT, V::Ts(created))
                .set(contact_channels::UPDATED_AT, V::Ts(if ver { at } else { created }));
            self.chunk.emit(contact_channels::T, day, r);
        }
        if self.shoppers[s].fraud {
            self.ring_device(rng, ms, s, first_seen);
        } else {
            self.device_profile(rng, ms, s, 0, first_seen);
        }
        // loyalty programme
        if let Some((program, _)) = ms.mkt.loyalty {
            if rng.chance(0.55) {
                let mut r = Row::new(loyalty_accounts::NCOLS);
                r.set(loyalty_accounts::TENANT_ID, tenant)
                    .set(loyalty_accounts::LOYALTY_PROGRAM_ID, program)
                    .set(loyalty_accounts::USER_ID, user)
                    .set(loyalty_accounts::POINTS_BALANCE, V::Int(0))
                    .set(loyalty_accounts::LIFETIME_POINTS, V::Int(0))
                    .set(loyalty_accounts::TIER, "Bronze")
                    .set(loyalty_accounts::ENROLLED_AT, V::Ts(created))
                    .set(loyalty_accounts::CREATED_AT, V::Ts(created))
                    .set(loyalty_accounts::UPDATED_AT, V::Ts(created));
                let h = self.chunk.emit_deferred(loyalty_accounts::T, day, r);
                self.shoppers[s].mkt.loyalty = Some(Box::new(Loyalty { h, balance: 0, lifetime: 0 }));
            }
        }
        // the big merchants have an app: push tokens
        if ms.m.size_rank <= 15 && !crate::sim::stories::has(ms.m, "S10") && self.shoppers[s].device == Device::Mobile && rng.chance(0.18) {
            let ios = self.shoppers[s].ua.contains("iPhone");
            let at = created + rng.int(1, 30) * MICROS_PER_DAY;
            let end = time::end_ts();
            if at <= end {
                let last = (at + (rng.exp(250.0) * MICROS_PER_DAY as f64) as i64).min(end);
                let mut r = Row::new(push_tokens::NCOLS);
                r.set(push_tokens::TENANT_ID, tenant)
                    .set(push_tokens::USER_ID, user)
                    .set(push_tokens::PLATFORM, if ios { "ios" } else { "android" })
                    .set(push_tokens::TOKEN, if ios { rng.hex(64) } else { format!("{}:APA91b{}", rng.alnum(11), rng.alnum(134)) })
                    .set(push_tokens::DEVICE_NAME, if ios { V::Static(*rng.pick(&["iPhone", "iPhone 14", "iPhone 15 Pro", "iPhone 13"])) } else { V::Static(*rng.pick(&["Galaxy S23", "Pixel 7", "Galaxy A54"])) })
                    .set(push_tokens::IS_ACTIVE, last > end - 120 * MICROS_PER_DAY)
                    .set(push_tokens::LAST_USED_AT, V::Ts(last))
                    .set(push_tokens::CREATED_AT, V::Ts(at))
                    .set(push_tokens::UPDATED_AT, V::Ts(last));
                let d = (time::day_of_ts(at).max(day as i64)) as Day;
                self.chunk.emit(push_tokens::T, d, r);
            }
        }
        // came through a friend's referral link (the friend shops here too)
        if self.shoppers[s].channel == Channel::Referral && s > 0 && rng.chance(0.5) {
            for _ in 0..8 {
                let f = rng.below(s);
                if self.shoppers[f].mkt.referral.as_deref().is_some_and(|&(_, t, n)| t < created && n < MAX_REFERRALS) {
                    self.shoppers[s].mkt.referred_by = Some(f as u32);
                    break;
                }
            }
        }
    }

    /// Device profile for the primary (0) or second (1) device, first seen at `at`.
    pub(super) fn device_profile(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, which: usize, at: Ts) {
        let (device, ua, user) = {
            let sh = &self.shoppers[s];
            if which == 0 { (sh.device, sh.ua, sh.rid) } else { (sh.device2, sh.ua2, sh.rid) }
        };
        let (os, osv, br, brv) = parse_ua(ua);
        let (w, h) = *rng.pick(match device {
            Device::Mobile => &[(390, 844), (393, 852), (412, 915), (375, 812), (360, 800), (430, 932)][..],
            Device::Tablet => &[(820, 1180), (768, 1024), (800, 1280)][..],
            Device::Desktop => &[(1920, 1080), (1536, 864), (1440, 900), (2560, 1440), (1366, 768), (1280, 800)][..],
        });
        let mut r = Row::new(device_profiles::NCOLS);
        r.set(device_profiles::TENANT_ID, ms.tenant_rid())
            .set(device_profiles::USER_ID, user)
            .set(device_profiles::FINGERPRINT, rng.hex(32))
            .set(device_profiles::DEVICE_TYPE, match device { Device::Mobile => "mobile", Device::Tablet => "tablet", Device::Desktop => "desktop" })
            .set(device_profiles::OS, os)
            .set(device_profiles::OS_VERSION, if osv.is_empty() { V::Null } else { V::Str(osv) })
            .set(device_profiles::BROWSER, br)
            .set(device_profiles::BROWSER_VERSION, if brv.is_empty() { V::Null } else { V::Str(brv) })
            .set(device_profiles::SCREEN_WIDTH, if rng.chance(0.95) { V::Int(w) } else { V::Null })
            .set(device_profiles::SCREEN_HEIGHT, if rng.chance(0.95) { V::Int(h) } else { V::Null })
            .set(device_profiles::FIRST_SEEN_AT, V::Ts(at))
            .set(device_profiles::LAST_SEEN_AT, V::Ts(at))
            .set(device_profiles::CREATED_AT, V::Ts(at))
            .set(device_profiles::UPDATED_AT, V::Ts(at));
        self.shoppers[s].mkt.devices[which] = Some(self.chunk.emit_deferred(device_profiles::T, self.chunk.day, r));
    }

    /// A visit from a device: create its profile on first use, update last seen.
    pub(super) fn touch_device(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, which: usize, start: Ts, end: Ts) {
        if self.shoppers[s].mkt.devices[which].is_none() {
            self.device_profile(rng, ms, s, which, start);
        }
        let h = self.shoppers[s].mkt.devices[which].unwrap();
        let end = end.min(time::end_ts());
        self.chunk.deferred_mut(h).set(device_profiles::LAST_SEEN_AT, V::Ts(end)).set(device_profiles::UPDATED_AT, V::Ts(end));
    }

    /// Today's marketing emails to this chunk's subscribers.
    pub(super) fn sends(&mut self, rng: &mut Rng, ms: &MerchantSim, day: Day) {
        let end = time::end_ts();
        let tenant = ms.tenant_rid();
        let ndays = self.calendar.len();
        for send in &ms.mkt.sends_today {
            for s in 0..self.shoppers.len() {
                let (eligible, churned) = {
                    let sh = &self.shoppers[s];
                    let m = &sh.mkt;
                    let base = m.opt_in && m.email_ok && sh.created < send.at && !(sh.ident.erased.is_some() && day >= sh.churn_day);
                    let seg = match send.segment {
                        SegmentKind::All | SegmentKind::New => true,
                        SegmentKind::Vip => m.third_order.is_some(),
                        SegmentKind::Lapsed => m.last_order.is_some_and(|t| send.at - t > 90 * MICROS_PER_DAY),
                        SegmentKind::WinBack => sh.sub.is_none() && sh.sub_ended.is_some_and(|t| t >= crate::time::ts_of_day(crate::time::day_of(chrono::NaiveDate::from_ymd_opt(2025, 3, 1).unwrap()) as Day) && t < send.at),
                    };
                    (base && seg, day >= sh.churn_day)
                };
                if !eligible {
                    continue;
                }
                let sent = send.at + rng.int(0, 1800) * MICROS_PER_SEC;
                let (email, user, sat) = (self.shoppers[s].email.clone(), self.shoppers[s].rid, self.shoppers[s].satisfaction);
                let (engagement, mpp) = (self.shoppers[s].mkt.engagement, self.shoppers[s].mkt.mpp);
                let variant = send.ab.map(|_| rng.below(2));
                let ab_mult = send.ab.map_or(1.0, |(_, _, m)| m[variant.unwrap()]);
                let mut r = Row::new(campaign_messages::NCOLS);
                r.set(campaign_messages::TENANT_ID, tenant)
                    .set(campaign_messages::CAMPAIGN_ID, send.campaign)
                    .set(campaign_messages::USER_ID, user)
                    .set(campaign_messages::EMAIL_TEMPLATE_ID, send.template)
                    .set(campaign_messages::RECIPIENT_EMAIL, email.clone())
                    .set(campaign_messages::SENT_AT, V::Ts(sent))
                    .set(campaign_messages::CREATED_AT, V::Ts(send.at - 10 * MICROS_PER_MIN));
                let x = rng.f64();
                if x < 0.0035 {
                    // hard bounce: the address is suppressed from now on
                    let b = sent + rng.int(1, 30) * MICROS_PER_SEC;
                    r.set(campaign_messages::STATUS, "bounced")
                        .set(campaign_messages::BOUNCED_AT, V::Ts(b))
                        .set(campaign_messages::ERROR_MESSAGE, *rng.pick(&["550 5.1.1 The email account that you tried to reach does not exist", "550 5.1.1 Recipient address rejected: User unknown", "554 5.7.1 Recipient address rejected: Access denied"]))
                        .set(campaign_messages::UPDATED_AT, V::Ts(b));
                    self.emit_at(campaign_messages::T, sent, r);
                    self.shoppers[s].mkt.email_ok = false;
                    continue;
                }
                if x < 0.005 {
                    r.set(campaign_messages::STATUS, "failed")
                        .set(campaign_messages::ERROR_MESSAGE, "452 4.2.2 Mailbox full; retries exhausted")
                        .set(campaign_messages::UPDATED_AT, V::Ts((sent + 72 * MICROS_PER_HOUR).min(end)));
                    self.emit_at(campaign_messages::T, sent, r);
                    continue;
                }
                let delivered = sent + rng.int(1, 40) * MICROS_PER_SEC;
                let eng = engagement * if churned { 0.35 } else { 1.0 } * ab_mult;
                let human_open = rng.chance(eng.min(0.95));
                let open_t = delivered + ((rng.lognormal(libm::log(2.5), 1.3)).min(24.0 * 6.0) * MICROS_PER_HOUR as f64) as i64;
                let opened = if mpp { Some(delivered + rng.int(1, 25) * MICROS_PER_MIN) } else if human_open { Some(open_t) } else { None };
                let p_click = 0.18 * if send.promo { 1.5 } else { 1.0 } * sat.min(1.0) * if churned { 0.6 } else { 1.0 };
                let clicked = if human_open && rng.chance(p_click) { Some(open_t + rng.int(5, 300) * MICROS_PER_SEC) } else { None };
                let complained = rng.chance(0.0002);
                let fickle = if self.shoppers[s].influencer { 3.0 } else { 1.0 };
                let unsub = complained || if human_open { rng.chance(0.012 * fickle * (1.0 - engagement).max(0.1)) } else { rng.chance(0.0006 * fickle) };
                let unsub_t = if human_open { open_t + rng.int(10, 120) * MICROS_PER_SEC } else { delivered + rng.int(1, 72) * MICROS_PER_HOUR };
                let upto = |t: Option<Ts>| t.filter(|x| *x <= end);
                let status = if complained && unsub_t <= end {
                    "complained"
                } else if unsub && unsub_t <= end {
                    "unsubscribed"
                } else if upto(clicked).is_some() {
                    "clicked"
                } else if upto(opened).is_some() {
                    "opened"
                } else if delivered <= end {
                    "delivered"
                } else {
                    "sent"
                };
                let last = [Some(delivered), opened, clicked, if unsub { Some(unsub_t) } else { None }].into_iter().flatten().filter(|t| *t <= end).max().unwrap_or(sent);
                r.set(campaign_messages::STATUS, status)
                    .set(campaign_messages::DELIVERED_AT, V::opt_ts(upto(Some(delivered))))
                    .set(campaign_messages::OPENED_AT, V::opt_ts(upto(opened)))
                    .set(campaign_messages::CLICKED_AT, V::opt_ts(upto(clicked)))
                    .set(campaign_messages::UNSUBSCRIBED_AT, if unsub { V::opt_ts(upto(Some(unsub_t))) } else { V::Null })
                    .set(campaign_messages::UPDATED_AT, V::Ts(last));
                self.emit_at(campaign_messages::T, sent, r);
                let ab = match (send.ab, variant) {
                    (Some((test, vars, _)), Some(k)) => {
                        let mut r = Row::new(ab_assignments::NCOLS);
                        r.set(ab_assignments::TENANT_ID, tenant)
                            .set(ab_assignments::AB_TEST_ID, test)
                            .set(ab_assignments::AB_VARIANT_ID, vars[k])
                            .set(ab_assignments::USER_ID, user)
                            .set(ab_assignments::ASSIGNED_AT, V::Ts(send.at))
                            .set(ab_assignments::CREATED_AT, V::Ts(send.at))
                            .set(ab_assignments::UPDATED_AT, V::Ts(send.at));
                        Some(self.chunk.emit_deferred(ab_assignments::T, day, r))
                    }
                    _ => None,
                };
                if let Some(c) = upto(clicked) {
                    let cd = time::day_of_ts(c).max(day as i64) as usize;
                    if cd < ndays {
                        let k = self.next_click;
                        self.next_click += 1;
                        self.clicks.insert(k, super::marketing::Click { at: c, campaign: send.campaign, utm: send.utm.clone(), landing: send.landing, promo: send.promo, ab, winback: send.winback });
                        self.calendar[cd].push((s as u32, Visit::Click(k)));
                        self.outbox.entry(cd as Day).or_default().clicks.push(send.campaign);
                    }
                }
                if unsub && unsub_t <= end {
                    self.unsubscribe(rng, ms, s, unsub_t, complained);
                }
            }
        }
    }

    fn unsubscribe(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, at: Ts, complained: bool) {
        let tenant = ms.tenant_rid();
        let (user, email, ip) = (self.shoppers[s].rid, self.shoppers[s].email.clone(), self.shoppers[s].ip.clone());
        self.shoppers[s].mkt.opt_in = false;
        let h = self.shoppers[s].mkt.prefs_row.unwrap();
        self.chunk.deferred_mut(h).set(user_preferences::MARKETING_OPT_IN, false).set(user_preferences::UPDATED_AT, V::Ts(at));
        let reason = if complained {
            V::Static("Marked as spam")
        } else if rng.chance(0.4) {
            V::Static(*rng.pick(&["I receive too many emails", "The content is not relevant to me", "I never signed up for this", "I no longer want to receive these emails"]))
        } else {
            V::Null
        };
        let mut r = Row::new(unsubscribes::NCOLS);
        r.set(unsubscribes::TENANT_ID, tenant)
            .set(unsubscribes::USER_ID, user)
            .set(unsubscribes::CHANNEL, "email")
            .set(unsubscribes::ADDRESS, email)
            .set(unsubscribes::CATEGORY, "marketing")
            .set(unsubscribes::REASON, reason)
            .set(unsubscribes::UNSUBSCRIBED_AT, V::Ts(at))
            .set(unsubscribes::CREATED_AT, V::Ts(at))
            .set(unsubscribes::UPDATED_AT, V::Ts(at));
        self.emit_at(unsubscribes::T, at, r);
        let mut r = Row::new(consent_records::NCOLS);
        r.set(consent_records::TENANT_ID, tenant)
            .set(consent_records::USER_ID, user)
            .set(consent_records::PURPOSE, "marketing_email")
            .set(consent_records::STATUS, "withdrawn")
            .set(consent_records::SOURCE, if complained { "spam_complaint" } else { "unsubscribe_link" })
            .set(consent_records::POLICY_VERSION, policy_version(at))
            .set(consent_records::IP_ADDRESS, if complained { V::Null } else { V::Str(ip) })
            .set(consent_records::WITHDRAWN_AT, V::Ts(at))
            .set(consent_records::OCCURRED_AT, V::Ts(at))
            .set(consent_records::CREATED_AT, V::Ts(at));
        self.emit_at(consent_records::T, at, r);
        let mut r = Row::new(notification_preferences::NCOLS);
        r.set(notification_preferences::TENANT_ID, tenant)
            .set(notification_preferences::USER_ID, user)
            .set(notification_preferences::CHANNEL, "email")
            .set(notification_preferences::CATEGORY, "marketing")
            .set(notification_preferences::IS_ENABLED, false)
            .set(notification_preferences::CREATED_AT, V::Ts(at))
            .set(notification_preferences::UPDATED_AT, V::Ts(at));
        self.emit_at(notification_preferences::T, at, r);
    }

    /// Attribution, referral reward and order history of a paid order.
    #[allow(clippy::too_many_arguments)]
    pub(super) fn on_paid_order(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, order: Rid, at: Ts, grand: i64, channel: Channel, delivery: bool) {
        let tenant = ms.tenant_rid();
        if delivery {
            let m = &mut self.shoppers[s].mkt;
            m.first_order = m.first_order.or(Some(at));
            m.last_order = Some(at);
            return;
        }
        let user = self.shoppers[s].rid;
        let first = self.shoppers[s].mkt.first_order.is_none();
        let paid_campaign = |c: Channel| match c {
            Channel::PaidSearch => ms.mkt.paid[0].as_ref().map(|p| p.0),
            Channel::PaidSocial => ms.mkt.paid[1].as_ref().map(|p| p.0),
            _ => None,
        };
        // last click: an email clicked in the last 7 days wins, else the visit's own channel
        let recent = self.shoppers[s].mkt.last_click.as_deref().copied().filter(|(_, t, _)| at - *t <= 7 * MICROS_PER_DAY && *t <= at);
        let (campaign, touch) = match recent {
            Some((c, _, _)) => (Some(c), "email"),
            None => (paid_campaign(channel), channel_name(channel)),
        };
        if let Some((_, _, Some(h))) = recent {
            if self.chunk.deferred_ref(h).vals[ab_assignments::CONVERTED_AT].is_null() {
                self.chunk.deferred_mut(h).set(ab_assignments::CONVERTED_AT, V::Ts(at)).set(ab_assignments::UPDATED_AT, V::Ts(at));
            }
        }
        let mut models = vec![("last_click", campaign, touch)];
        if first {
            let acq = self.shoppers[s].channel;
            if self.shoppers[s].influencer {
                models.push(("first_touch", ms.mkt.influencer.as_ref().map(|c| c.0), "influencer"));
            } else {
                models.push(("first_touch", paid_campaign(acq), channel_name(acq)));
            }
        }
        // what the merchant credits to its paid flights: search by last click; social, which
        // finds new customers, by last click and first touch
        for (model, campaign, _) in &models {
            for k in 0..2 {
                if campaign.is_some() && ms.mkt.paid[k].as_ref().map(|p| p.0) == *campaign && (k == 1 || *model == "last_click") {
                    self.outbox.entry(self.chunk.day).or_default().paid_revenue[k] += grand;
                }
            }
        }
        for (model, campaign, touch) in models {
            let mut r = Row::new(attributions::NCOLS);
            r.set(attributions::TENANT_ID, tenant)
                .set(attributions::USER_ID, user)
                .set(attributions::CAMPAIGN_ID, V::opt_ref(campaign))
                .set(attributions::ORDER_ID, order)
                .set(attributions::MODEL, model)
                .set(attributions::TOUCH_POINT, touch)
                .set(attributions::WEIGHT, V::Dec(10000, 4))
                .set(attributions::ATTRIBUTED_REVENUE, V::Money(grand))
                .set(attributions::CURRENCY_CODE, ms.m.currency.clone())
                .set(attributions::OCCURRED_AT, V::Ts(at))
                .set(attributions::CREATED_AT, V::Ts(at + rng.int(60, 3600) * MICROS_PER_SEC))
                .set(attributions::UPDATED_AT, V::Ts(at + rng.int(60, 3600) * MICROS_PER_SEC));
            self.emit_at(attributions::T, at, r);
        }
        // referral reward on the first order of a referred shopper
        if first {
            if let Some(f) = self.shoppers[s].mkt.referred_by {
                let f = f as usize;
                if let Some(&(h, created, n)) = self.shoppers[f].mkt.referral.as_deref() {
                    if created < at && n < MAX_REFERRALS {
                        let reward = (10.0 * ms.price_level * 100.0).round() as i64;
                        let mut r = Row::new(referral_redemptions::NCOLS);
                        r.set(referral_redemptions::TENANT_ID, tenant)
                            .set(referral_redemptions::REFERRAL_ID, h.rid)
                            .set(referral_redemptions::REFERRED_USER_ID, user)
                            .set(referral_redemptions::ORDER_ID, order)
                            .set(referral_redemptions::REWARD_AMOUNT, V::Money(reward))
                            .set(referral_redemptions::CURRENCY_CODE, ms.m.currency.clone())
                            .set(referral_redemptions::REDEEMED_AT, V::Ts(at))
                            .set(referral_redemptions::CREATED_AT, V::Ts(at))
                            .set(referral_redemptions::UPDATED_AT, V::Ts(at));
                        self.emit_at(referral_redemptions::T, at, r);
                        self.shoppers[f].mkt.referral = Some(Box::new((h, created, n + 1)));
                        self.chunk.deferred_mut(h).set(referrals::REDEMPTION_COUNT, V::Int(n + 1)).set(referrals::UPDATED_AT, V::Ts(at));
                    }
                }
            }
        }
        let m = &mut self.shoppers[s].mkt;
        m.first_order = m.first_order.or(Some(at));
        if m.third_order.is_none() && self.shoppers[s].orders >= 3 {
            self.shoppers[s].mkt.third_order = Some(at);
        }
        self.shoppers[s].mkt.last_order = Some(at);
    }

    /// Points for an order are credited 30 days after delivery, on what was not returned.
    pub(super) fn queue_points(&mut self, ms: &MerchantSim, s: usize, order: Rid, release: Ts, net_cents: i64) {
        let Some((_, ppc)) = ms.mkt.loyalty else { return };
        if self.shoppers[s].mkt.loyalty.is_none() || release > time::end_ts() {
            return;
        }
        let points = (net_cents as f64 / 100.0 * ppc).floor() as i64;
        let d = time::day_of_ts(release) as usize;
        if points > 0 && d < self.calendar.len() {
            self.loyalty_queue.entry(d as Day).or_default().push((s as u32, points, order));
        }
    }

    /// The nightly points job, and redemptions of shoppers who have enough points.
    pub(super) fn loyalty_day(&mut self, rng: &mut Rng, ms: &MerchantSim, day: Day) {
        let Some(todo) = self.loyalty_queue.remove(&day) else { return };
        let tenant = ms.tenant_rid();
        let job = ms.tz.local_to_utc(time::date_of(day), 2 * MICROS_PER_HOUR);
        let mut redeemers: Vec<usize> = Vec::new();
        for (k, (s, points, order)) in todo.into_iter().enumerate() {
            let s = s as usize;
            let at = job + k as i64 * 40_000 + rng.int(0, 30_000);
            let Some(l) = self.shoppers[s].mkt.loyalty.as_mut() else { continue };
            l.balance += points;
            l.lifetime += points;
            let (h, balance) = (l.h, l.balance);
            let user = self.shoppers[s].rid;
            self.loyalty_txn(tenant, h, user, "earn", points, "Points for order", Some(order), balance, at);
            if balance >= REDEEM_POINTS && !redeemers.contains(&s) && rng.chance(0.3) {
                redeemers.push(s);
            }
        }
        for s in redeemers {
            let at = job + rng.int(5, 20) * MICROS_PER_HOUR;
            let user = self.shoppers[s].rid;
            let l = self.shoppers[s].mkt.loyalty.as_mut().unwrap();
            l.balance -= REDEEM_POINTS;
            let (h, balance) = (l.h, l.balance);
            self.loyalty_txn(tenant, h, user, "burn", REDEEM_POINTS, "Redeemed for a reward voucher", None, balance, at);
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn loyalty_txn(&mut self, tenant: Rid, h: DHandle, user: Rid, dir: &'static str, points: i64, reason: &'static str, order: Option<Rid>, balance: i64, at: Ts) {
        if at > time::end_ts() {
            return;
        }
        let mut r = Row::new(loyalty_transactions::NCOLS);
        r.set(loyalty_transactions::TENANT_ID, tenant)
            .set(loyalty_transactions::LOYALTY_ACCOUNT_ID, h.rid)
            .set(loyalty_transactions::USER_ID, user)
            .set(loyalty_transactions::DIRECTION, dir)
            .set(loyalty_transactions::POINTS, V::Int(points))
            .set(loyalty_transactions::REASON, reason)
            .set(loyalty_transactions::ORDER_ID, V::opt_ref(order))
            .set(loyalty_transactions::BALANCE_AFTER, V::Int(balance))
            .set(loyalty_transactions::OCCURRED_AT, V::Ts(at))
            .set(loyalty_transactions::CREATED_AT, V::Ts(at));
        self.emit_at(loyalty_transactions::T, at, r);
        let lifetime = self.chunk.deferred_ref(h).vals[loyalty_accounts::LIFETIME_POINTS].clone();
        let lifetime = match lifetime { V::Int(x) => x, _ => 0 } + if dir == "earn" { points } else { 0 };
        let tier = if lifetime >= 5000 { "Gold" } else if lifetime >= 1500 { "Silver" } else { "Bronze" };
        self.chunk.deferred_mut(h).set(loyalty_accounts::POINTS_BALANCE, V::Int(balance)).set(loyalty_accounts::LIFETIME_POINTS, V::Int(lifetime)).set(loyalty_accounts::TIER, tier).set(loyalty_accounts::UPDATED_AT, V::Ts(at));
    }

    /// Happy customers sometimes create a referral code to share.
    pub(super) fn maybe_referral(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, after: Ts, experience: f64) {
        if self.shoppers[s].mkt.referral.is_some() || experience < 0.4 || !rng.chance(0.03) {
            return;
        }
        let at = after + rng.int(1, 20) * MICROS_PER_DAY + rng.int(0, MICROS_PER_DAY - 1);
        let end = time::end_ts();
        if at > end {
            return;
        }
        // unique per tenant: the chunk index and a per-chunk counter are part of the code
        self.codes += 1;
        let n = (self.local as u64) * 1_000_000 + self.codes as u64;
        let mut b36 = String::new();
        let mut x = n * 7919 + 46_656; // at least four digits
        while x > 0 {
            b36.insert(0, char::from_digit((x % 36) as u32, 36).unwrap().to_ascii_uppercase());
            x /= 36;
        }
        let first = crate::sim::people::ascii_fold(self.shoppers[s].first_name.as_str()).to_uppercase().chars().filter(|c| c.is_ascii_alphabetic()).take(8).collect::<String>();
        let expires = if ms.m.size_rank % 2 == 0 { Some(at + 365 * MICROS_PER_DAY) } else { None };
        let mut r = Row::new(referrals::NCOLS);
        r.set(referrals::TENANT_ID, ms.tenant_rid())
            .set(referrals::REFERRER_USER_ID, self.shoppers[s].rid)
            .set(referrals::CODE, format!("{first}-{b36}"))
            .set(referrals::REWARD_AMOUNT, V::Money((10.0 * ms.price_level * 100.0).round() as i64))
            .set(referrals::CURRENCY_CODE, ms.m.currency.clone())
            .set(referrals::MAX_REDEMPTIONS, V::Int(MAX_REFERRALS))
            .set(referrals::REDEMPTION_COUNT, V::Int(0))
            .set(referrals::IS_ACTIVE, expires.is_none_or(|e| e > end))
            .set(referrals::EXPIRES_AT, V::opt_ts(expires))
            .set(referrals::CREATED_AT, V::Ts(at))
            .set(referrals::UPDATED_AT, V::Ts(at));
        let d = time::day_of_ts(at).max(self.chunk.day as i64) as Day;
        let h = self.chunk.emit_deferred(referrals::T, d, r);
        self.shoppers[s].mkt.referral = Some(Box::new((h, at, 0)));
    }

    /// A pre-sales question in the shop's chat inbox, answered by staff.
    pub(super) fn message_thread(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, at: Ts, product: &str) {
        let end = time::end_ts();
        if ms.agents.is_empty() || at > end {
            return;
        }
        let tenant = ms.tenant_rid();
        let user = self.shoppers[s].rid;
        let agent = &ms.agents[rng.below(ms.agents.len())];
        let q = *rng.pick(&["Is this available in other colours?", "When will this be back in stock?", "Does this run true to size?", "Can you deliver before the weekend?", "Is this compatible with the previous model?", "What is it made of?"]);
        let a = *rng.pick(&["Thanks for your message! Yes - please check the product page for all options.", "Good question - we expect new stock within two weeks.", "Happy to help: it fits true to size for most customers.", "Orders placed before 2pm usually arrive within two working days."]);
        let reply = at + ((10.0 + rng.exp(180.0) + ms.support_delay * 300.0) * MICROS_PER_MIN as f64) as i64;
        let mut msgs = vec![(true, at, format!("Hi, about the {product}: {q}"))];
        if reply <= end {
            msgs.push((false, reply, a.to_string()));
            if rng.chance(0.4) {
                msgs.push((true, reply + rng.int(2, 240) * MICROS_PER_MIN, "Great, thank you!".to_string()));
            }
        }
        let msgs: Vec<(bool, Ts, String)> = msgs.into_iter().filter(|m| m.1 <= end).collect();
        let last = msgs.iter().map(|m| m.1).max().unwrap_or(at);
        let mut r = Row::new(message_threads::NCOLS);
        r.set(message_threads::TENANT_ID, tenant)
            .set(message_threads::USER_ID, user)
            .set(message_threads::SUBJECT, if rng.chance(0.8) { V::Str(format!("Question about {product}")) } else { V::Null })
            .set(message_threads::CHANNEL, if rng.chance(0.7) { "web_chat" } else { "contact_form" })
            .set(message_threads::IS_CLOSED, msgs.len() > 1 && last + 2 * MICROS_PER_DAY <= end)
            .set(message_threads::LAST_MESSAGE_AT, V::Ts(last))
            .set(message_threads::CREATED_AT, V::Ts(at))
            .set(message_threads::UPDATED_AT, V::Ts(last));
        let Some(th) = self.emit_at(message_threads::T, at, r) else { return };
        let n = msgs.len();
        for (i, (customer, t, body)) in msgs.into_iter().enumerate() {
            let read = if i + 1 < n { Some(t + rng.int(1, 60) * MICROS_PER_MIN).filter(|x| *x <= end) } else if !customer { Some(t + rng.int(5, 600) * MICROS_PER_MIN).filter(|x| *x <= end) } else { None };
            let mut r = Row::new(thread_messages::NCOLS);
            r.set(thread_messages::TENANT_ID, tenant)
                .set(thread_messages::THREAD_ID, th)
                .set(thread_messages::SENDER_USER_ID, if customer { user } else { agent.user })
                .set(thread_messages::DIRECTION, if customer { "inbound" } else { "outbound" })
                .set(thread_messages::BODY, body)
                .set(thread_messages::ATTACHMENTS, V::Json(if customer && rng.chance(0.05) { format!(r#"[{{"name":"photo.jpg","content_type":"image/jpeg","size":{}}}]"#, rng.int(80_000, 3_000_000)) } else { "[]".to_string() }))
                .set(thread_messages::READ_AT, V::opt_ts(read))
                .set(thread_messages::CREATED_AT, V::Ts(t))
                .set(thread_messages::UPDATED_AT, V::Ts(read.unwrap_or(t)));
            self.emit_at(thread_messages::T, t, r);
        }
    }

    /// Segment membership as of the last nightly refresh (end of the window).
    pub(super) fn segment_members(&mut self, ms: &MerchantSim, day: Day) {
        let tenant = ms.tenant_rid();
        let refresh = time::ts_of_day(day) + 2 * MICROS_PER_HOUR + 17 * MICROS_PER_MIN;
        let mut counts = [0i64; 5];
        for s in 0..self.shoppers.len() {
            if self.shoppers[s].ident.erased.is_some() {
                continue;
            }
            let (user, m_opt, created) = (self.shoppers[s].rid, self.shoppers[s].mkt.opt_in && self.shoppers[s].mkt.email_ok, self.shoppers[s].created);
            let m = &self.shoppers[s].mkt;
            let mut kinds: Vec<(SegmentKind, Ts)> = Vec::new();
            if m_opt {
                kinds.push((SegmentKind::All, created));
                if let Some(t) = m.third_order {
                    kinds.push((SegmentKind::Vip, t));
                }
                if let Some(t) = m.last_order.filter(|t| refresh - *t > 90 * MICROS_PER_DAY) {
                    kinds.push((SegmentKind::Lapsed, t + 90 * MICROS_PER_DAY));
                }
            }
            if let Some(t) = m.first_order.filter(|t| refresh - *t <= 30 * MICROS_PER_DAY && *t <= refresh) {
                kinds.push((SegmentKind::New, t));
            }
            let since = crate::time::ts_of_date(chrono::NaiveDate::from_ymd_opt(2025, 3, 1).unwrap());
            let built = crate::time::ts_of_date(chrono::NaiveDate::from_ymd_opt(2025, 6, 9).unwrap()) + 10 * MICROS_PER_HOUR;
            if ms.mkt.segments.len() > 4 && m_opt {
                if let Some(t) = self.shoppers[s].sub_ended.filter(|t| *t >= since && *t < built) {
                    kinds.push((SegmentKind::WinBack, t.max(built)));
                }
            }
            for (k, added) in kinds {
                if added > refresh {
                    continue;
                }
                // added by the nightly refresh after the shopper qualified
                let next = time::ts_of_day(time::day_of_ts(added).max(0) as Day + 1) + 2 * MICROS_PER_HOUR;
                let created_at = next.min(refresh);
                let mut r = Row::new(segment_members::NCOLS);
                r.set(segment_members::TENANT_ID, tenant)
                    .set(segment_members::SEGMENT_ID, ms.mkt.segments[k as usize].rid)
                    .set(segment_members::USER_ID, user)
                    .set(segment_members::ADDED_AT, V::Ts(created_at.max(added)))
                    .set(segment_members::CREATED_AT, V::Ts(created_at.max(added)))
                    .set(segment_members::UPDATED_AT, V::Ts(refresh));
                self.chunk.emit(segment_members::T, day, r);
                counts[k as usize] += 1;
            }
        }
        self.outbox.entry(day).or_default().segments = counts;
        let _ = format_uuid;
    }
}
