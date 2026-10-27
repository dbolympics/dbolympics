//! Gift cards and store credit. A gift card bought as a present is redeemed later by another
//! shopper (most within weeks, Christmas cards in January; ~15% never: breakage). Sold cards
//! are a liability, not revenue; redemptions pay for (part of) an order; refunds of orders
//! paid with a gift card go to store credit (wallets).

use super::{Item, ShopperChunk, Visit};
use crate::engine::DHandle;
use crate::rng::Rng;
use crate::sim::merchant::MerchantSim;
use crate::tables::*;
use crate::time::{self, Day, MICROS_PER_DAY, MICROS_PER_HOUR, MICROS_PER_MIN, Ts};
use crate::value::{Rid, Row, V};

pub(super) struct Card {
    h: DHandle,
    balance: i64,
    /// when the recipient has it (the gift is given)
    from: Ts,
    tries: u8,
}

impl ShopperChunk {
    /// The gift card a shopper buys as a present.
    pub(super) fn gift_card_item(&self, rng: &mut Rng, ms: &MerchantSim) -> Option<Item> {
        let pi = ms.gift_card?;
        let p = &ms.products[pi];
        let vi = crate::rng::Weighted::new([0.3, 0.45, 0.25]).sample(rng).min(p.variants.len() - 1);
        let v = &p.variants[vi];
        Some(Item { size: None, pidx: pi, vidx: vi, product: p.rid, product_name: p.name.clone(), variant: v.rid, sku: v.sku.clone(), name: v.name.clone(), qty: 1, unit_gross: v.price_cents, weight_g: v.weight_g })
    }

    /// Cards for the gift card lines of a paid order, and who will redeem them when.
    pub(super) fn issue_cards(&mut self, rng: &mut Rng, ms: &MerchantSim, s: usize, order: Rid, items: &[Item], at: Ts) {
        use chrono::Datelike;
        let end = time::end_ts();
        let tenant = ms.tenant_rid();
        for it in items.iter().filter(|it| ms.products[it.pidx].voucher) {
            for _ in 0..it.qty {
                let face = it.unit_gross;
                let code = format!("{}-{}-{}-{}", rng.alnum(4), rng.alnum(4), rng.alnum(4), rng.alnum(4)).to_uppercase();
                let d = chrono::DateTime::from_timestamp_micros(at).unwrap().date_naive();
                let xmas = (d.month() == 11 && d.day() >= 15) || (d.month() == 12 && d.day() <= 24);
                let redeem_at = if xmas {
                    time::ts_of_date(chrono::NaiveDate::from_ymd_opt(d.year(), 12, 26).unwrap()) + ((rng.exp(25.0)) * MICROS_PER_DAY as f64) as i64
                } else {
                    at + 3 * MICROS_PER_DAY + (rng.exp(45.0) * MICROS_PER_DAY as f64) as i64
                };
                let rd = time::day_of_ts(redeem_at);
                // the recipient: another shopper here (most cards are used)
                let mut recipient = None;
                if rng.chance(0.85) && rd < time::num_days() as i64 && self.shoppers.len() > 1 {
                    for _ in 0..6 {
                        let r = rng.below(self.shoppers.len());
                        let sh = &self.shoppers[r];
                        if r != s && sh.created < redeem_at && (sh.churn_day as i64) > rd && sh.ident.erased.is_none() {
                            recipient = Some(r);
                            break;
                        }
                    }
                }
                // an order paid in the last minutes of the window: the card is issued within it
                let created = (at + rng.int(1, 30) * MICROS_PER_MIN).min(end);
                let mut row = Row::new(gift_cards::NCOLS);
                row.set(gift_cards::TENANT_ID, tenant)
                    .set(gift_cards::CODE, code)
                    .set(gift_cards::STATUS, "active")
                    .set(gift_cards::INITIAL_BALANCE, V::Money(face))
                    .set(gift_cards::BALANCE, V::Money(face))
                    .set(gift_cards::CURRENCY_CODE, ms.m.currency.clone())
                    .set(gift_cards::ISSUED_TO_USER_ID, V::opt_ref(recipient.filter(|_| rng.chance(0.3)).map(|r| self.shoppers[r].rid)))
                    .set(gift_cards::ISSUED_ORDER_ID, order)
                    .set(gift_cards::EXPIRES_AT, V::Ts(created + 3 * 365 * MICROS_PER_DAY))
                    .set(gift_cards::CREATED_AT, V::Ts(created))
                    .set(gift_cards::UPDATED_AT, V::Ts(created));
                let day = time::day_of_ts(created).max(self.chunk.day as i64) as Day;
                let h = self.chunk.emit_deferred(gift_cards::T, day, row);
                self.card_txn(tenant, ms, h.rid, Some(order), face, face, "Issued", created);
                let k = self.cards.len();
                self.cards.push(Card { h, balance: face, from: redeem_at.max(created + MICROS_PER_HOUR), tries: 0 });
                if let Some(r) = recipient {
                    if redeem_at <= end {
                        self.shoppers[r].cards.push(k as u32);
                        self.calendar[rd as usize].push((r as u32, Visit::Gift(k as u32)));
                    }
                }
            }
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn card_txn(&mut self, tenant: Rid, ms: &MerchantSim, card: Rid, order: Option<Rid>, amount: i64, after: i64, note: &str, at: Ts) {
        let mut r = Row::new(gift_card_transactions::NCOLS);
        r.set(gift_card_transactions::TENANT_ID, tenant)
            .set(gift_card_transactions::GIFT_CARD_ID, card)
            .set(gift_card_transactions::ORDER_ID, V::opt_ref(order))
            .set(gift_card_transactions::AMOUNT, V::Money(amount))
            .set(gift_card_transactions::BALANCE_AFTER, V::Money(after))
            .set(gift_card_transactions::CURRENCY_CODE, ms.m.currency.clone())
            .set(gift_card_transactions::NOTE, note.to_string())
            .set(gift_card_transactions::CREATED_AT, V::Ts(at));
        self.emit_at(gift_card_transactions::T, at, r);
    }

    /// A card in the shopper's hands that can pay for `grand`: (card, amount).
    pub(super) fn take_card(&mut self, s: usize, grand: i64, at: Ts) -> Option<(usize, i64)> {
        let k = self.shoppers[s].cards.iter().map(|k| *k as usize).find(|k| self.cards[*k].balance > 0 && self.cards[*k].from <= at)?;
        Some((k, self.cards[k].balance.min(grand)))
    }

    /// Pay with a gift card: a gift card payment on the order and a debit on the card.
    pub(super) fn redeem_card(&mut self, rng: &mut Rng, ms: &MerchantSim, k: usize, order: Rid, amount: i64, at: Ts) -> Option<Rid> {
        let tenant = ms.tenant_rid();
        self.cards[k].balance -= amount;
        let (h, bal) = (self.cards[k].h, self.cards[k].balance);
        self.chunk.deferred_mut(h).set(gift_cards::BALANCE, V::Money(bal)).set(gift_cards::STATUS, if bal == 0 { "redeemed" } else { "active" }).set(gift_cards::UPDATED_AT, V::Ts(at));
        self.card_txn(tenant, ms, h.rid, Some(order), -amount, bal, "Redeemed at checkout", at);
        let mut r = Row::new(payments::NCOLS);
        r.set(payments::TENANT_ID, tenant)
            .set(payments::ORDER_ID, order)
            .set(payments::STATUS, "captured")
            .set(payments::AMOUNT, V::Money(amount))
            .set(payments::AMOUNT_REFUNDED, V::Money(0))
            .set(payments::CURRENCY_CODE, ms.m.currency.clone())
            .set(payments::GATEWAY, "Gift card")
            .set(payments::GATEWAY_CHARGE_ID, format!("gc_{}", rng.alnum(16)))
            .set(payments::AUTHORIZED_AT, V::Ts(at))
            .set(payments::CAPTURED_AT, V::Ts(at))
            .set(payments::METADATA, V::Json(format!(r#"{{"gift_card":{{"last4":"{}"}}}}"#, rng.alnum(4).to_uppercase())))
            .set(payments::CREATED_AT, V::Ts(at))
            .set(payments::UPDATED_AT, V::Ts(at));
        self.emit_at(payments::T, at, r)
    }

    /// Store credit (refunds of gift-card-paid orders, credit notes after payment).
    pub(super) fn credit_wallet(&mut self, ms: &MerchantSim, s: usize, amount: i64, at: Ts) {
        let day = self.chunk.day;
        let user = self.shoppers[s].rid;
        match self.shoppers[s].wallet.as_deref_mut() {
            Some((h, bal)) => {
                *bal += amount;
                let (h, bal) = (*h, *bal);
                self.chunk.deferred_mut(h).set(wallets::BALANCE, V::Money(bal)).set(wallets::UPDATED_AT, V::Ts(at));
            }
            None => {
                let mut r = Row::new(wallets::NCOLS);
                r.set(wallets::TENANT_ID, ms.tenant_rid()).set(wallets::USER_ID, user).set(wallets::CURRENCY_CODE, ms.m.currency.clone()).set(wallets::BALANCE, V::Money(amount)).set(wallets::IS_ACTIVE, true).set(wallets::CREATED_AT, V::Ts(at)).set(wallets::UPDATED_AT, V::Ts(at));
                let h = self.chunk.emit_deferred(wallets::T, day, r);
                self.shoppers[s].wallet = Some(Box::new((h, amount)));
            }
        }
        let _ = MICROS_PER_HOUR;
    }

    /// The recipient did not get round to using the card: they come back later (a few times).
    pub(super) fn retry_card(&mut self, rng: &mut Rng, s: usize, k: usize) {
        let c = &mut self.cards[k];
        if c.balance == 0 || c.tries >= 3 {
            return;
        }
        c.tries += 1;
        let d = self.chunk.day as usize + 1 + (rng.exp(12.0)) as usize;
        if d < self.calendar.len() {
            self.calendar[d].push((s as u32, Visit::Gift(k as u32)));
        }
    }

    /// Expired cards at the end of the window.
    pub(super) fn finish_cards(&mut self) {
        let end = time::end_ts();
        for k in 0..self.cards.len() {
            let h = self.cards[k].h;
            let exp = self.chunk.deferred_ref(h).vals[gift_cards::EXPIRES_AT].as_ts();
            if self.cards[k].balance > 0 && exp.is_some_and(|e| e <= end) {
                self.chunk.deferred_mut(h).set(gift_cards::STATUS, "expired");
            }
        }
    }
}
