//! Row values and row references.

use crate::schema::TableId;
use crate::time::{Day, Ts};

/// Reference to a row. Either a final id, or a pending handle (table, day, chunk, index)
/// that becomes an id when its day is finalized. Packed into a u64:
/// bit 63 = pending; then table (9 bits), day (11 bits), chunk (12 bits), index (31 bits).
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct Rid(u64);

const PENDING: u64 = 1 << 63;

impl Rid {
    pub fn final_id(id: i64) -> Rid {
        debug_assert!(id > 0);
        Rid(id as u64)
    }

    pub fn pending(table: TableId, day: Day, chunk: u32, idx: u32) -> Rid {
        assert!(table.0 < 512 && day < 2048 && chunk < 4096 && idx < (1 << 31), "Rid overflow");
        Rid(PENDING | (table.0 as u64) << 54 | (day as u64) << 43 | (chunk as u64) << 31 | idx as u64)
    }

    pub fn is_pending(self) -> bool {
        self.0 & PENDING != 0
    }

    /// (table, day, chunk, idx) of a pending reference.
    pub fn parts(self) -> (TableId, Day, u32, u32) {
        debug_assert!(self.is_pending());
        (
            TableId(((self.0 >> 54) & 0x1FF) as usize),
            ((self.0 >> 43) & 0x7FF) as Day,
            ((self.0 >> 31) & 0xFFF) as u32,
            (self.0 & 0x7FFF_FFFF) as u32,
        )
    }

    pub fn raw_id(self) -> i64 {
        debug_assert!(!self.is_pending());
        self.0 as i64
    }

    pub fn to_bits(self) -> u64 {
        self.0
    }

    pub fn from_bits(b: u64) -> Rid {
        Rid(b)
    }
}

/// A cell value. Conversion to the column type (and validation) happens at finalize.
#[derive(Clone, Debug)]
pub enum V {
    Null,
    Int(i64),
    Bool(bool),
    /// Amount in minor units with 2 decimals (cents); rescaled to the column's scale.
    Money(i64),
    /// Arbitrary decimal: (unscaled value, scale).
    Dec(i128, i8),
    #[allow(dead_code)] // no float columns are generated yet
    F64(f64),
    Str(String),
    Static(&'static str),
    Ts(Ts),
    /// Days since 1970-01-01.
    Date(i32),
    Uuid(u128),
    Json(String),
    Arr(Vec<String>),
    Ref(Rid),
}

impl V {
    pub fn is_null(&self) -> bool {
        matches!(self, V::Null)
    }

    pub fn opt_ref(r: Option<Rid>) -> V {
        r.map_or(V::Null, V::Ref)
    }

    pub fn opt_ts(t: Option<Ts>) -> V {
        t.map_or(V::Null, V::Ts)
    }

    pub fn as_ts(&self) -> Option<Ts> {
        match self {
            V::Ts(t) => Some(*t),
            _ => None,
        }
    }
}

impl From<&'static str> for V {
    fn from(s: &'static str) -> V {
        V::Static(s)
    }
}
impl From<String> for V {
    fn from(s: String) -> V {
        V::Str(s)
    }
}
impl From<bool> for V {
    fn from(b: bool) -> V {
        V::Bool(b)
    }
}
impl From<i64> for V {
    fn from(i: i64) -> V {
        V::Int(i)
    }
}
impl From<i32> for V {
    fn from(i: i32) -> V {
        V::Int(i as i64)
    }
}
impl From<u32> for V {
    fn from(i: u32) -> V {
        V::Int(i as i64)
    }
}
impl From<usize> for V {
    fn from(i: usize) -> V {
        V::Int(i as i64)
    }
}
impl From<Rid> for V {
    fn from(r: Rid) -> V {
        V::Ref(r)
    }
}
impl<T: Into<V>> From<Option<T>> for V {
    fn from(o: Option<T>) -> V {
        o.map_or(V::Null, Into::into)
    }
}

/// A row: one value per column of its table, in schema order.
#[derive(Clone, Debug)]
pub struct Row {
    pub vals: Vec<V>,
    /// the row gets its id but is not written (deleted before the snapshot, e.g. archived
    /// audit rows): leaves a gap in the ids like a real purge does
    pub skip: bool,
}

impl Row {
    pub fn new(ncols: usize) -> Row {
        Row { vals: vec![V::Null; ncols], skip: false }
    }

    #[inline]
    pub fn set(&mut self, col: usize, v: impl Into<V>) -> &mut Row {
        self.vals[col] = v.into();
        self
    }
}
