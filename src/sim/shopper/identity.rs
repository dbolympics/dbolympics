//! Shopper identity and privacy: login sessions (one per device, kept for 30 days), failed
//! logins and password resets, social sign-in, address validation, help-centre feedback,
//! support staff access to customer data, and GDPR requests (access, rectification, erasure).
//!
//! Erasure is decided when the shopper is created (the request date lies in their future):
//! the final snapshot then shows the user anonymised and their orders without customer
//! email, while logs elsewhere (email log, campaign messages) still hold the old address.

use super::ShopperChunk;
use crate::rng::{Rng, format_uuid};
use crate::sim::merchant::{Audit, MerchantSim, audit, change};
use crate::tables::*;
use crate::time::{self, Day, MICROS_PER_DAY, MICROS_PER_HOUR, MICROS_PER_MIN, MICROS_PER_SEC, Ts};
use crate::value::{Rid, Row, V};
use crate::world::world;

pub(super) struct OpenSession {
    token: String,
    ip: String,
    ua: &'static str,
    start: Ts,
    last: Ts,
    expires: Ts,
}

#[derive(Default)]
pub(super) struct Ident {
    /// signed up with a social login
    pub oauth: Option<&'static str>,
    sess: [Option<Box<OpenSession>>; 2],
    /// erasure completed at this time (decided at creation)
    pub erased: Option<Ts>,
}

impl ShopperChunk {
    fn flush_session(&mut self, ms: &MerchantSim, s: usize, which: usize, revoked: Option<Ts>) {
        let Some(o) = self.shoppers[s].ident.sess[which].take() else { return };
        let mut r = Row::new(sessions::NCOLS);
        r.set(sessions::TENANT_ID, ms.tenant_rid())
            .set(sessions::USER_ID, self.shoppers[s].rid)
            .set(sessions::TOKEN_HASH, o.token)
            .set(sessions::IP_ADDRESS, o.ip)
            .set(sessions::USER_AGENT, o.ua)
            .set(sessions::STARTED_AT, V::Ts(o.start))
            .set(sessions::LAST_SEEN_AT, V::Ts(o.last))
            .set(sessions::EXPIRES_AT, V::Ts(o.expires))
            .set(sessions::REVOKED_AT, V::opt_ts(revoked));
        self.chunk.emit(sessions::T, self.chunk.day, r);
    }

    /// A known shopper's visit from a device: reuse the session or sign in again.
    /// Returns the login method when a new sign-in happened.
    pub(super) fn touch_session(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, which: usize, start: Ts, end: Ts) -> Option<&'static str> {
        let end = end.min(time::end_ts());
        if let Some(o) = self.shoppers[s].ident.sess[which].as_mut() {
            if start < o.expires {
                o.last = o.last.max(end);
                return None;
            }
        }
        let logout = self.shoppers[s].ident.sess[which].as_ref().map(|o| o.last).filter(|_| rng.chance(0.08));
        self.flush_session(ms, s, which, logout);
        let tenant = ms.tenant_rid();
        let (user, email, ip) = (self.shoppers[s].rid, self.shoppers[s].email.clone(), self.shoppers[s].ip.clone());
        let ua = if which == 0 { self.shoppers[s].ua } else { self.shoppers[s].ua2 };
        let method = match self.shoppers[s].ident.oauth {
            Some(p) => p,
            None if rng.chance(0.15) => "magic_link",
            None => "password",
        };
        let mut t = start;
        if method == "password" {
            if rng.chance(0.012) {
                // forgot the password: reset link by email
                let at = start - rng.int(2, 10) * MICROS_PER_MIN;
                let used = rng.chance(0.85);
                let mut r = Row::new(password_resets::NCOLS);
                r.set(password_resets::TENANT_ID, tenant)
                    .set(password_resets::USER_ID, user)
                    .set(password_resets::TOKEN_HASH, rng.hex(64))
                    .set(password_resets::EXPIRES_AT, V::Ts(at + MICROS_PER_HOUR))
                    .set(password_resets::USED_AT, if used { V::Ts(at + rng.int(30, 600) * MICROS_PER_SEC) } else { V::Null })
                    .set(password_resets::CREATED_AT, V::Ts(at));
                self.chunk.emit(password_resets::T, self.chunk.day, r);
                let tpl = ms.templates.as_ref().unwrap().password_reset;
                self.email(rng, ms, s, tpl, "Reset your password".into(), "no-reply", at + 5 * MICROS_PER_SEC);
            } else if rng.chance(0.05) {
                for _ in 0..1 + rng.below(2) {
                    let mut r = Row::new(login_attempts::NCOLS);
                    r.set(login_attempts::TENANT_ID, tenant).set(login_attempts::USER_ID, user).set(login_attempts::EMAIL, email.clone()).set(login_attempts::SUCCEEDED, false).set(login_attempts::IP_ADDRESS, ip.clone()).set(login_attempts::USER_AGENT, ua).set(login_attempts::OCCURRED_AT, V::Ts(t - rng.int(5, 60) * MICROS_PER_SEC));
                    self.chunk.emit(login_attempts::T, self.chunk.day, r);
                }
            } else if rng.chance(0.004) {
                // a typo in the email: no such user
                let typo = email.replacen('@', ".@", 1).replacen(".com", ".con", 1);
                let mut r = Row::new(login_attempts::NCOLS);
                r.set(login_attempts::TENANT_ID, tenant).set(login_attempts::USER_ID, V::Null).set(login_attempts::EMAIL, typo).set(login_attempts::SUCCEEDED, false).set(login_attempts::IP_ADDRESS, ip.clone()).set(login_attempts::USER_AGENT, ua).set(login_attempts::OCCURRED_AT, V::Ts(t - rng.int(5, 60) * MICROS_PER_SEC));
                self.chunk.emit(login_attempts::T, self.chunk.day, r);
            }
            t += rng.int(1, 3) * MICROS_PER_SEC;
        }
        let mut r = Row::new(login_attempts::NCOLS);
        r.set(login_attempts::TENANT_ID, tenant).set(login_attempts::USER_ID, user).set(login_attempts::EMAIL, email).set(login_attempts::SUCCEEDED, true).set(login_attempts::IP_ADDRESS, ip.clone()).set(login_attempts::USER_AGENT, ua).set(login_attempts::OCCURRED_AT, V::Ts(t));
        self.chunk.emit(login_attempts::T, self.chunk.day, r);
        self.shoppers[s].ident.sess[which] = Some(Box::new(OpenSession { token: rng.hex(64), ip, ua, start: t, last: end.max(t), expires: t + 30 * MICROS_PER_DAY }));
        Some(method)
    }

    /// Sessions still open at the end of the window.
    pub(super) fn flush_sessions(&mut self, ms: &MerchantSim) {
        for s in 0..self.shoppers.len() {
            for w in 0..2 {
                self.flush_session(ms, s, w, None);
            }
        }
    }

    pub(super) fn validate_address(&mut self, rng: &mut Rng, ms: &MerchantSim, address: Rid, a: &crate::sim::people::Address, at: Ts) {
        if !rng.chance(0.7) || at > time::end_ts() {
            return;
        }
        let ok = rng.chance(0.96);
        let resp = if ok {
            format!(r#"{{"verdict":"valid","confidence":{:.2},"standardized":{{"city":{},"postal_code":{}}}}}"#, rng.uniform(0.9, 1.0), super::json_str(&a.city_name), a.postal.as_deref().map_or("null".to_string(), super::json_str))
        } else {
            format!(r#"{{"verdict":"invalid","reason":"{}","confidence":{:.2}}}"#, rng.pick(&["postal_code_mismatch", "street_not_found", "missing_house_number"]), rng.uniform(0.3, 0.7))
        };
        let mut r = Row::new(address_validations::NCOLS);
        r.set(address_validations::TENANT_ID, ms.tenant_rid())
            .set(address_validations::ADDRESS_ID, address)
            .set(address_validations::PROVIDER, "qgeo-1")
            .set(address_validations::IS_VALID, ok)
            .set(address_validations::RESPONSE, V::Json(resp))
            .set(address_validations::VALIDATED_AT, V::Ts(at + rng.int(200, 1500) * 1000));
        let d = time::day_of_ts(at).max(self.chunk.day as i64) as Day;
        self.chunk.emit(address_validations::T, d, r);
    }

    /// Help-centre feedback: an article that did (not) answer the question.
    pub(super) fn article_feedback(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, category: usize, helpful: bool, at: Ts) {
        let arts: Vec<Rid> = ms.articles.iter().filter(|(c, _)| *c == category).map(|(_, r)| *r).collect();
        if arts.is_empty() || at > time::end_ts() {
            return;
        }
        let mut r = Row::new(article_feedback::NCOLS);
        r.set(article_feedback::TENANT_ID, ms.tenant_rid())
            .set(article_feedback::KNOWLEDGE_ARTICLE_ID, arts[rng.below(arts.len())])
            .set(article_feedback::USER_ID, if rng.chance(0.7) { V::Ref(self.shoppers[s].rid) } else { V::Null })
            .set(article_feedback::WAS_HELPFUL, helpful)
            .set(article_feedback::COMMENT, if !helpful && rng.chance(0.3) { V::Static(*rng.pick(&["Doesn't answer my question", "My case is different", "Too generic", "Link to contact form is hard to find"])) } else { V::Null })
            .set(article_feedback::CREATED_AT, V::Ts(at))
            .set(article_feedback::UPDATED_AT, V::Ts(at));
        let d = time::day_of_ts(at).max(self.chunk.day as i64) as Day;
        self.chunk.emit(article_feedback::T, d, r);
    }

    /// A support agent opens the customer's profile.
    pub(super) fn access_customer(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, agent_user: Rid, at: Ts, purpose: &'static str) {
        if at > time::end_ts() {
            return;
        }
        let fields: &[&str] = match rng.below(3) { 0 => &["email", "full_name"], 1 => &["email", "full_name", "phone", "addresses"], _ => &["email", "orders", "payment_methods"] };
        let mut r = Row::new(access_log::NCOLS);
        r.set(access_log::TENANT_ID, ms.tenant_rid())
            .set(access_log::ACTOR_USER_ID, agent_user)
            .set(access_log::ENTITY_SCHEMA, crate::schema::table(users::T).module.clone())
            .set(access_log::ENTITY_TABLE, "users")
            .set(access_log::ENTITY_ID, self.shoppers[s].rid)
            .set(access_log::ACCESS_KIND, "view")
            .set(access_log::FIELD_NAMES, V::Arr(fields.iter().map(|x| x.to_string()).collect()))
            .set(access_log::PURPOSE, purpose)
            .set(access_log::IP_ADDRESS, ms.admin.office_ip.clone())
            .set(access_log::OCCURRED_AT, V::Ts(at))
            .set(access_log::CREATED_AT, V::Ts(at + 80_000));
        let d = time::day_of_ts(at).max(self.chunk.day as i64) as Day;
        self.chunk.emit(access_log::T, d, r);
    }

    /// GDPR requests planned at signup (EU/EEA/UK shoppers; a few elsewhere).
    pub(super) fn plan_privacy(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize) {
        let w = world();
        let end = time::end_ts();
        let iso = &w.geo.countries[self.shoppers[s].country].iso2;
        let gdpr = super::is_eu(iso) || ["GB", "NO", "CH"].contains(&iso.as_str());
        let x = rng.f64() * if gdpr { 1.0 } else { 4.0 };
        let kind = if x < 0.007 { "erasure" } else if x < 0.011 { "access" } else if x < 0.012 { "rectification" } else { return };
        let received = self.shoppers[s].created + ((7.0 + rng.exp(420.0)) * MICROS_PER_DAY as f64) as i64;
        if received > end {
            return;
        }
        let tenant = ms.tenant_rid();
        let Some((staff, ip, ua)) = ms.staff_actor(&["admin", "owner"]) else { return };
        let late = rng.chance(0.08);
        let completed = received + ((if late { rng.uniform(31.0, 60.0) } else { rng.lognormal(libm::log(6.0), 0.8).min(29.0) }) * MICROS_PER_DAY as f64) as i64;
        // a pending chargeback dispute blocks some erasures (legal hold)
        let hold = kind == "erasure" && rng.chance(0.05);
        let done = completed <= end;
        let user = self.shoppers[s].rid;
        let email = self.shoppers[s].email.clone();
        let d0 = time::day_of_ts(received).max(self.chunk.day as i64) as Day;
        let mut export = None;
        if kind == "access" && done {
            let mut r = Row::new(data_exports::NCOLS);
            let public = rng.uuid();
            r.set(data_exports::PUBLIC_ID, V::Uuid(public))
                .set(data_exports::TENANT_ID, tenant)
                .set(data_exports::REQUESTED_BY_USER_ID, staff)
                .set(data_exports::SUBJECT_USER_ID, user)
                .set(data_exports::STATUS, if completed + 30 * MICROS_PER_DAY <= end { "expired" } else { "completed" })
                .set(data_exports::FORMAT, if rng.chance(0.8) { "json" } else { "csv" })
                .set(data_exports::FILE_URL, format!("https://exports.tidewick.app/{}/{}.zip", ms.m.slug, format_uuid(public)))
                .set(data_exports::ROW_COUNT, V::Int(rng.int(40, 2500)))
                .set(data_exports::REQUESTED_AT, V::Ts(received + MICROS_PER_HOUR))
                .set(data_exports::COMPLETED_AT, V::Ts(completed - MICROS_PER_HOUR))
                .set(data_exports::EXPIRES_AT, V::Ts(completed + 30 * MICROS_PER_DAY))
                .set(data_exports::CREATED_AT, V::Ts(received + MICROS_PER_HOUR))
                .set(data_exports::UPDATED_AT, V::Ts(completed - MICROS_PER_HOUR));
            export = Some(self.chunk.emit(data_exports::T, d0, r));
        }
        let status = if hold { "rejected" } else if done { "completed" } else if rng.chance(0.5) { "in_progress" } else { "received" };
        let mut r = Row::new(data_subject_requests::NCOLS);
        r.set(data_subject_requests::PUBLIC_ID, V::Uuid(rng.uuid()))
            .set(data_subject_requests::TENANT_ID, tenant)
            .set(data_subject_requests::SUBJECT_USER_ID, user)
            .set(data_subject_requests::SUBJECT_EMAIL, email.clone())
            .set(data_subject_requests::REQUEST_TYPE, kind)
            .set(data_subject_requests::STATUS, status)
            .set(data_subject_requests::ASSIGNED_TO_USER_ID, staff)
            .set(data_subject_requests::DATA_EXPORT_ID, V::opt_ref(export))
            .set(data_subject_requests::NOTES, if hold { V::Static("Erasure deferred: open payment dispute (legal hold)") } else if kind == "rectification" { V::Static("Customer asked to correct their name and address") } else { V::Null })
            .set(data_subject_requests::RECEIVED_AT, V::Ts(received))
            .set(data_subject_requests::DUE_AT, V::Ts(received + 30 * MICROS_PER_DAY))
            .set(data_subject_requests::COMPLETED_AT, if done && !hold { V::Ts(completed) } else { V::Null })
            .set(data_subject_requests::CREATED_AT, V::Ts(received))
            .set(data_subject_requests::UPDATED_AT, V::Ts(if done { completed } else { received }));
        let dsar = self.chunk.emit(data_subject_requests::T, d0, r);
        if hold {
            let mut r = Row::new(legal_holds::NCOLS);
            r.set(legal_holds::TENANT_ID, tenant)
                .set(legal_holds::NAME, format!("Chargeback dispute {}", rng.digits(6)))
                .set(legal_holds::REASON, V::Static("Payment dispute pending with the card network; records must be kept until it is resolved"))
                .set(legal_holds::SUBJECT_USER_ID, user)
                .set(legal_holds::PLACED_BY_USER_ID, staff)
                .set(legal_holds::IS_ACTIVE, true)
                .set(legal_holds::PLACED_AT, V::Ts(received + MICROS_PER_DAY))
                .set(legal_holds::CREATED_AT, V::Ts(received + MICROS_PER_DAY))
                .set(legal_holds::UPDATED_AT, V::Ts(received + MICROS_PER_DAY));
            self.chunk.emit(legal_holds::T, d0, r);
        }
        if late && received + 30 * MICROS_PER_DAY <= end {
            let at = received + 30 * MICROS_PER_DAY + rng.int(1, 6) * MICROS_PER_HOUR;
            let mut r = Row::new(compliance_events::NCOLS);
            r.set(compliance_events::TENANT_ID, tenant)
                .set(compliance_events::EVENT_TYPE, "dsar_sla_breach")
                .set(compliance_events::SEVERITY, "medium")
                .set(compliance_events::ENTITY_SCHEMA, crate::schema::table(data_subject_requests::T).module.clone())
                .set(compliance_events::ENTITY_TABLE, "data_subject_requests")
                .set(compliance_events::ENTITY_ID, dsar)
                .set(compliance_events::DETAILS, V::Json(format!(r#"{{"request_type":"{kind}","due_days":30}}"#)))
                .set(compliance_events::RESOLVED, done)
                .set(compliance_events::RESOLVED_AT, if done { V::Ts(completed) } else { V::Null })
                .set(compliance_events::OCCURRED_AT, V::Ts(at))
                .set(compliance_events::CREATED_AT, V::Ts(at));
            let d = time::day_of_ts(at).max(self.chunk.day as i64) as Day;
            self.chunk.emit(compliance_events::T, d, r);
        }
        if !done || hold {
            return;
        }
        let mut rng2 = Rng::new(rng.u64(), &[1]);
        match kind {
            "access" => {
                audit(&mut self.chunk, &mut rng2, tenant, Audit { at: completed, action: "export", actor: Some(staff), actor_type: "staff", entity: Some((users::T, user)), summary: "Exported personal data (GDPR access request)".into(), metadata: r#"{"reason":"dsar_access"}"#.into(), ip: Some(&ip), ua: Some(ua) });
            }
            "rectification" => {
                let a = audit(&mut self.chunk, &mut rng2, tenant, Audit { at: completed, action: "update", actor: Some(staff), actor_type: "staff", entity: Some((users::T, user)), summary: "Corrected customer name (GDPR rectification)".into(), metadata: r#"{"reason":"dsar_rectification"}"#.into(), ip: Some(&ip), ua: Some(ua) });
                change(&mut self.chunk, tenant, a, Some(staff), (users::T, user), &["full_name"], r#"{"full_name":"[previous]"}"#.into(), r#"{"full_name":"[corrected]"}"#.into(), completed);
            }
            _ => {
                // erasure: anonymise the account, stop all activity
                self.shoppers[s].ident.erased = Some(completed);
                self.shoppers[s].churn_day = self.shoppers[s].churn_day.min(time::day_of_ts(received).max(0) as Day);
                let public = match &self.chunk.deferred_ref(self.shoppers[s].user).vals[users::PUBLIC_ID] { V::Uuid(u) => *u, _ => 0 };
                let h = self.shoppers[s].user;
                self.chunk
                    .deferred_mut(h)
                    .set(users::EMAIL, format!("erased-{}@privacy.invalid", &format_uuid(public)[..13]))
                    .set(users::FULL_NAME, V::Null)
                    .set(users::PASSWORD_HASH, V::Null)
                    .set(users::STATUS, "deactivated")
                    .set(users::DELETED_AT, V::Ts(completed));
                audit(&mut self.chunk, &mut rng2, tenant, Audit { at: completed, action: "delete", actor: Some(staff), actor_type: "staff", entity: Some((users::T, user)), summary: "Erased personal data (GDPR erasure request)".into(), metadata: r#"{"reason":"dsar_erasure","anonymized":["email","full_name","password_hash"]}"#.into(), ip: Some(&ip), ua: Some(ua) });
            }
        }
    }

    /// Final state of an erased user (visits update the row until the request).
    pub(super) fn finish_erasures(&mut self) {
        for s in 0..self.shoppers.len() {
            if let Some(t) = self.shoppers[s].ident.erased {
                let h = self.shoppers[s].user;
                self.chunk.deferred_mut(h).set(users::UPDATED_AT, V::Ts(t));
            }
        }
    }
}
