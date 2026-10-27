//! Rows packed into bytes, for rows that are kept until the end (deferred tables): a `Row` takes
//! 32 bytes per value plus an allocation per string, a packed row one tag byte per value plus a
//! varint or the string's bytes.

use crate::value::{Rid, Row, V};

const NULL: u8 = 0;
const INT: u8 = 1;
const FALSE: u8 = 2;
const TRUE: u8 = 3;
const MONEY: u8 = 4;
const DEC: u8 = 5;
const F64: u8 = 6;
const STR: u8 = 7;
const STATIC: u8 = 8;
const TS: u8 = 9;
const DATE: u8 = 10;
const UUID: u8 = 11;
const JSON: u8 = 12;
const ARR: u8 = 13;
const REF: u8 = 14;

pub fn pack(row: &Row) -> Box<[u8]> {
    let mut b = Vec::with_capacity(1 + 6 * row.vals.len());
    b.push(row.skip as u8);
    for v in &row.vals {
        match v {
            V::Null => b.push(NULL),
            V::Int(i) => {
                b.push(INT);
                varint(&mut b, zigzag(*i as i128));
            }
            V::Bool(x) => b.push(if *x { TRUE } else { FALSE }),
            V::Money(i) => {
                b.push(MONEY);
                varint(&mut b, zigzag(*i as i128));
            }
            V::Dec(i, s) => {
                b.push(DEC);
                varint(&mut b, zigzag(*i));
                b.push(*s as u8);
            }
            V::F64(f) => {
                b.push(F64);
                b.extend_from_slice(&f.to_le_bytes());
            }
            V::Str(s) => {
                b.push(STR);
                bytes(&mut b, s.as_bytes());
            }
            V::Static(s) => {
                // the string lives forever: keep where it is
                b.push(STATIC);
                b.extend_from_slice(&(s.as_ptr() as usize).to_le_bytes());
                varint(&mut b, s.len() as u128);
            }
            V::Ts(t) => {
                b.push(TS);
                varint(&mut b, zigzag(*t as i128));
            }
            V::Date(d) => {
                b.push(DATE);
                varint(&mut b, zigzag(*d as i128));
            }
            V::Uuid(u) => {
                b.push(UUID);
                b.extend_from_slice(&u.to_le_bytes());
            }
            V::Json(s) => {
                b.push(JSON);
                bytes(&mut b, s.as_bytes());
            }
            V::Arr(a) => {
                b.push(ARR);
                varint(&mut b, a.len() as u128);
                for s in a {
                    bytes(&mut b, s.as_bytes());
                }
            }
            V::Ref(r) => {
                b.push(REF);
                b.extend_from_slice(&r.to_bits().to_le_bytes());
            }
        }
    }
    b.into_boxed_slice()
}

pub fn unpack(b: &[u8]) -> Row {
    let mut r = Reader { b, pos: 1 };
    let mut vals = Vec::new();
    while r.pos < b.len() {
        let tag = r.b[r.pos];
        r.pos += 1;
        vals.push(match tag {
            NULL => V::Null,
            INT => V::Int(unzigzag(r.varint()) as i64),
            FALSE => V::Bool(false),
            TRUE => V::Bool(true),
            MONEY => V::Money(unzigzag(r.varint()) as i64),
            DEC => {
                let i = unzigzag(r.varint());
                V::Dec(i, r.take(1)[0] as i8)
            }
            F64 => V::F64(f64::from_le_bytes(r.take(8).try_into().unwrap())),
            STR => V::Str(r.string()),
            STATIC => {
                let ptr = usize::from_le_bytes(r.take(8).try_into().unwrap()) as *const u8;
                let len = r.varint() as usize;
                // SAFETY: written by `pack` from a `&'static str`, which is never freed
                V::Static(unsafe { std::str::from_utf8_unchecked(std::slice::from_raw_parts(ptr, len)) })
            }
            TS => V::Ts(unzigzag(r.varint()) as i64),
            DATE => V::Date(unzigzag(r.varint()) as i32),
            UUID => V::Uuid(u128::from_le_bytes(r.take(16).try_into().unwrap())),
            JSON => V::Json(r.string()),
            ARR => {
                let n = r.varint() as usize;
                V::Arr((0..n).map(|_| r.string()).collect())
            }
            REF => V::Ref(Rid::from_bits(u64::from_le_bytes(r.take(8).try_into().unwrap()))),
            _ => unreachable!("packed row: unknown tag {tag}"),
        });
    }
    Row { vals, skip: b[0] != 0 }
}

fn zigzag(i: i128) -> u128 {
    ((i << 1) ^ (i >> 127)) as u128
}

fn unzigzag(u: u128) -> i128 {
    (u >> 1) as i128 ^ -((u & 1) as i128)
}

fn varint(b: &mut Vec<u8>, mut u: u128) {
    while u >= 0x80 {
        b.push(u as u8 | 0x80);
        u >>= 7;
    }
    b.push(u as u8);
}

fn bytes(b: &mut Vec<u8>, s: &[u8]) {
    varint(b, s.len() as u128);
    b.extend_from_slice(s);
}

struct Reader<'a> {
    b: &'a [u8],
    pos: usize,
}

impl Reader<'_> {
    fn take(&mut self, n: usize) -> &[u8] {
        let s = &self.b[self.pos..self.pos + n];
        self.pos += n;
        s
    }

    fn varint(&mut self) -> u128 {
        let (mut u, mut shift) = (0u128, 0);
        loop {
            let x = self.b[self.pos];
            self.pos += 1;
            u |= ((x & 0x7F) as u128) << shift;
            if x < 0x80 {
                return u;
            }
            shift += 7;
        }
    }

    fn string(&mut self) -> String {
        let n = self.varint() as usize;
        // SAFETY: written by `pack` from a `String`
        unsafe { String::from_utf8_unchecked(self.take(n).to_vec()) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let mut r = Row::new(15);
        r.set(0, V::Int(-5))
            .set(1, true)
            .set(2, V::Money(-123456))
            .set(3, V::Dec(-12345678901234567890123, 4))
            .set(4, V::F64(1.5))
            .set(5, "static")
            .set(6, "owned".to_string())
            .set(7, V::Ts(1_700_000_000_000_000))
            .set(8, V::Date(-3))
            .set(9, V::Uuid(u128::MAX - 7))
            .set(10, V::Json(r#"{"a":1}"#.into()))
            .set(11, V::Arr(vec!["x".into(), String::new()]))
            .set(12, V::Ref(Rid::final_id(42)))
            .set(13, false);
        r.skip = true;
        assert_eq!(format!("{:?}", unpack(&pack(&r))), format!("{r:?}"));
    }
}
