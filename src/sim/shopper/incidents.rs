//! Incidents in the shopper chunks: S14 (a customer re-import creates duplicate accounts) and
//! S16 (credential stuffing against shopper logins, and the forced password resets after it).

use super::{Cause, ShopperChunk};
use crate::rng::Rng;
use crate::sim::merchant::{Audit, MerchantSim, audit, emit_address};
use crate::sim::people;
use crate::sim::reference::Refs;
use crate::tables::*;
use crate::time::{self, Day, MICROS_PER_DAY, MICROS_PER_HOUR, MICROS_PER_MIN, MICROS_PER_SEC, Ts};
use crate::value::{Rid, Row, V};

/// A duplicate account of a shopper (S14): (user, email, address).
pub(super) type Alias = (Rid, String, Rid);

const BOT_UAS: &[&str] = &["python-requests/2.31.0", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36", "curl/8.4.0", "okhttp/4.9.3"];

impl ShopperChunk {
    /// S14: the merchant re-imports its customer list; ~8% of customers come in a second time
    /// under a variant of their email address, and later orders are split across both.
    pub(super) fn s14_reimport(&mut self, rng: &mut Rng, ms: &MerchantSim, refs: &Refs, day: Day) {
        let tenant = ms.tenant_rid();
        let at = time::ts_of_day(day) + 13 * MICROS_PER_HOUR;
        let n = self.shoppers.len();
        let mut dups = 0;
        for s in 0..n {
            if self.shoppers[s].created >= at || self.shoppers[s].ident.erased.is_some() || !rng.chance(0.08) {
                continue;
            }
            let email = self.shoppers[s].email.clone();
            let (local, domain) = email.split_once('@').unwrap();
            // plus-addressing: no generated address contains '+', so these never collide
            let variant = match rng.below(3) {
                0 => format!("{local}+{}@{domain}", people::slugify(&ms.m.name).split('-').next().unwrap_or("shop")),
                1 => format!("{local}+orders@{domain}"),
                _ => format!("{local}+{}@{domain}", rng.int(1, 99)),
            };
            if !self.emails.insert(variant.clone()) {
                continue;
            }
            let full = format!("{} {}", self.shoppers[s].first_name, self.shoppers[s].last_name);
            let t = at + dups * 40_000;
            let mut u = Row::new(users::NCOLS);
            u.set(users::PUBLIC_ID, V::Uuid(rng.uuid()))
                .set(users::TENANT_ID, tenant)
                .set(users::EMAIL, variant.clone())
                .set(users::FULL_NAME, full)
                .set(users::STATUS, "active")
                .set(users::IS_STAFF, false)
                .set(users::LOCALE, ms.m.locale.clone())
                .set(users::CREATED_AT, V::Ts(t))
                .set(users::UPDATED_AT, V::Ts(t));
            let h = self.chunk.emit_deferred(users::T, day, u);
            let a = people::address(rng, self.shoppers[s].country);
            let addr = emit_address(&mut self.chunk, tenant, day, t, Some(h.rid), &a, refs, "Home", true);
            let mut r = Row::new(contact_channels::NCOLS);
            r.set(contact_channels::TENANT_ID, tenant).set(contact_channels::USER_ID, h.rid).set(contact_channels::KIND, "email").set(contact_channels::CHANNEL_ADDRESS, variant.clone()).set(contact_channels::IS_PRIMARY, true).set(contact_channels::IS_VERIFIED, false).set(contact_channels::CREATED_AT, V::Ts(t)).set(contact_channels::UPDATED_AT, V::Ts(t));
            self.chunk.emit(contact_channels::T, day, r);
            self.shoppers[s].alias = Some(Box::new((h.rid, variant, addr)));
            dups += 1;
        }
        // the import itself (this chunk's part of the file)
        let total = n as i64 + rng.int(20, 200);
        let failed = rng.poisson(total as f64 * 0.01) as i64;
        let public = rng.uuid();
        let name = format!("customers-export-{}.csv", if ms.shopper_chunks > 1 { format!("part{}", self.local + 1) } else { "full".to_string() });
        let by = ms.staff_actor(&["admin", "owner"]).map(|x| x.0);
        let mut r = Row::new(files::NCOLS);
        r.set(files::PUBLIC_ID, V::Uuid(public))
            .set(files::TENANT_ID, tenant)
            .set(files::FILENAME, name.clone())
            .set(files::CONTENT_TYPE, "text/csv")
            .set(files::BYTE_SIZE, V::Int(total * rng.int(150, 260)))
            .set(files::STORAGE_BUCKET, "tidewick-imports")
            .set(files::STORAGE_KEY, format!("tenants/{}/{}/{name}", ms.m.slug, crate::rng::format_uuid(public)))
            .set(files::UPLOADED_BY_USER_ID, V::opt_ref(by))
            .set(files::CREATED_AT, V::Ts(at - 10 * MICROS_PER_MIN))
            .set(files::UPDATED_AT, V::Ts(at - 10 * MICROS_PER_MIN));
        let file = self.chunk.emit(files::T, day, r);
        let fin = at + total * 30_000;
        let mut r = Row::new(import_batches::NCOLS);
        r.set(import_batches::TENANT_ID, tenant)
            .set(import_batches::ENTITY_TYPE, "customers")
            .set(import_batches::SOURCE_FILENAME, name)
            .set(import_batches::FILE_ID, file)
            .set(import_batches::STATUS, if failed > 0 { "partially_failed" } else { "completed" })
            .set(import_batches::TOTAL_ROWS, V::Int(total))
            .set(import_batches::PROCESSED_ROWS, V::Int(total))
            .set(import_batches::SUCCEEDED_ROWS, V::Int(total - failed))
            .set(import_batches::FAILED_ROWS, V::Int(failed))
            .set(import_batches::STARTED_BY_USER_ID, V::opt_ref(by))
            .set(import_batches::STARTED_AT, V::Ts(at))
            .set(import_batches::FINISHED_AT, V::Ts(fin))
            .set(import_batches::CREATED_AT, V::Ts(at))
            .set(import_batches::UPDATED_AT, V::Ts(fin));
        let batch = self.chunk.emit(import_batches::T, day, r);
        for _ in 0..failed {
            let (col, code, msg) = *rng.pick(&[("email", "invalid_email", "Email address is not valid"), ("email", "duplicate", "Email already exists (exact match)"), ("country", "unknown_country", "Unknown country 'U.K.'"), ("phone", "invalid_phone", "Phone number has too few digits")]);
            let mut r = Row::new(import_errors::NCOLS);
            r.set(import_errors::TENANT_ID, tenant).set(import_errors::IMPORT_BATCH_ID, batch).set(import_errors::SOURCE_ROW_NUMBER, V::Int(rng.int(2, total + 1))).set(import_errors::COLUMN_NAME, col).set(import_errors::ERROR_CODE, code).set(import_errors::ERROR_MESSAGE, msg).set(import_errors::RAW_ROW, V::Json(format!(r#"{{"email":"{}","country":"U.K."}}"#, rng.alnum(8).to_lowercase()))).set(import_errors::OCCURRED_AT, V::Ts(at + MICROS_PER_SEC)).set(import_errors::CREATED_AT, V::Ts(at + MICROS_PER_SEC));
            self.chunk.emit(import_errors::T, day, r);
        }
    }

    /// S16: a botnet replays leaked passwords; a few accounts are taken over.
    pub(super) fn s16_attack(&mut self, rng: &mut Rng, ms: &MerchantSim, refs: &Refs, day: Day) {
        if self.shoppers.is_empty() {
            return;
        }
        let tenant = ms.tenant_rid();
        let ranges: Vec<String> = (0..3).map(|k| format!("{}.{}.{}", [45, 103, 185][k], 60 + (day % 3) as i64 * 7 + k as i64, 20 + k * 31)).collect();
        let n = (self.shoppers.len() as f64 * 0.6) as usize + 20;
        for _ in 0..n {
            let t = time::ts_of_day(day) + rng.int(0, 86_399) * MICROS_PER_SEC;
            let ip = format!("{}.{}", ranges[rng.below(3)], rng.int(2, 250));
            let ua = BOT_UAS[rng.below(BOT_UAS.len())];
            let known = rng.chance(0.7);
            let s = rng.below(self.shoppers.len());
            let (user, email) = if known { (Some(self.shoppers[s].rid), self.shoppers[s].email.clone()) } else { (None, format!("{}{}@{}", rng.alnum(6).to_lowercase(), rng.digits(2), ["gmail.com", "yahoo.com", "outlook.com"][rng.below(3)])) };
            let ok = known && self.shoppers[s].created < t && self.shoppers[s].ident.oauth.is_none() && rng.chance(0.004);
            let mut r = Row::new(login_attempts::NCOLS);
            r.set(login_attempts::TENANT_ID, tenant).set(login_attempts::USER_ID, V::opt_ref(user)).set(login_attempts::EMAIL, email).set(login_attempts::SUCCEEDED, ok).set(login_attempts::IP_ADDRESS, ip.clone()).set(login_attempts::USER_AGENT, ua).set(login_attempts::OCCURRED_AT, V::Ts(t));
            self.chunk.emit(login_attempts::T, day, r);
            if !ok {
                continue;
            }
            // account takeover: a session from the botnet and a new delivery address
            let mut r = Row::new(sessions::NCOLS);
            r.set(sessions::TENANT_ID, tenant).set(sessions::USER_ID, self.shoppers[s].rid).set(sessions::TOKEN_HASH, rng.hex(64)).set(sessions::IP_ADDRESS, ip.clone()).set(sessions::USER_AGENT, ua).set(sessions::STARTED_AT, V::Ts(t)).set(sessions::LAST_SEEN_AT, V::Ts(t + rng.int(60, 900) * MICROS_PER_SEC)).set(sessions::EXPIRES_AT, V::Ts(t + 30 * MICROS_PER_DAY)).set(sessions::REVOKED_AT, V::Ts(time::ts_of_day(day + 1) + 10 * MICROS_PER_HOUR));
            self.chunk.emit(sessions::T, day, r);
            let a = people::address(rng, self.shoppers[s].country);
            let user = self.shoppers[s].rid;
            let addr = emit_address(&mut self.chunk, tenant, day, t + 2 * MICROS_PER_MIN, Some(user), &a, refs, "Home 2", false);
            let mut r2 = Rng::new(rng.u64(), &[9]);
            audit(&mut self.chunk, &mut r2, tenant, Audit { at: t + 2 * MICROS_PER_MIN, action: "create", actor: Some(user), actor_type: "customer", entity: Some((addresses::T, addr)), summary: "Added a delivery address".into(), metadata: r#"{"source":"storefront"}"#.into(), ip: Some(&ip), ua: Some(ua) });
            self.s16_victims.push(s as u32);
            let tt = t + rng.int(1, 4) * MICROS_PER_DAY;
            self.ticket(rng, ms, s, Cause::AccountAccess, tt);
        }
    }

    /// S16: the day after, compromised accounts get forced password resets.
    pub(super) fn s16_resets(&mut self, rng: &mut Rng, ms: &MerchantSim, day: Day) {
        let tenant = ms.tenant_rid();
        let victims = std::mem::take(&mut self.s16_victims);
        for s in victims {
            let s = s as usize;
            let at = time::ts_of_day(day) + 9 * MICROS_PER_HOUR + rng.int(0, 3600) * MICROS_PER_SEC;
            let used = rng.chance(0.7);
            let mut r = Row::new(password_resets::NCOLS);
            r.set(password_resets::TENANT_ID, tenant).set(password_resets::USER_ID, self.shoppers[s].rid).set(password_resets::TOKEN_HASH, rng.hex(64)).set(password_resets::EXPIRES_AT, V::Ts(at + 72 * MICROS_PER_HOUR)).set(password_resets::USED_AT, if used { V::Ts(at + rng.int(1, 48) * MICROS_PER_HOUR) } else { V::Null }).set(password_resets::CREATED_AT, V::Ts(at));
            self.chunk.emit(password_resets::T, day, r);
            let tpl = ms.templates.as_ref().unwrap().password_reset;
            self.email(rng, ms, s, tpl, "Important: please reset your password".into(), "security", at + MICROS_PER_MIN);
        }
    }

    /// S13: the order timestamp as the ERP integration writes it (local Berlin time stored as
    /// UTC from the DST change on), and whether the order came through the ERP at all.
    pub(super) fn erp_time(&self, rng: &mut Rng, ms: &MerchantSim, at: Ts) -> (Ts, bool) {
        if !crate::sim::stories::s13_erp(ms.m) || !rng.chance(0.12) {
            return (at, false);
        }
        if crate::sim::stories::s13_bug(at) { (ms.tz.utc_to_local(at), true) } else { (at, true) }
    }
}
