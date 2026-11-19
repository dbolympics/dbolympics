# Numerics: making query results consistent across databases

The rules below are applied by `tools/canonical.py` (the numeric edits are in
`workload/queries/numerics.json`) and recorded per query in `derivations.json`. The end of this
document has the result checker's comparison rules and how the reference results are made.

## The problem

The agents wrote SQL for DuckDB the way analysts do: they rounded report columns, cast to
`NUMERIC` before rounding, and divided counts by counts. Engines differ on each of these:

| Construct | How engines differ |
|---|---|
| `a / b` on integers | Postgres, Umbra and SQL Server truncate (`7/2 = 3`); DuckDB by default, MySQL, Oracle and ClickHouse give `3.5` |
| `AVG(int)` | Postgres returns numeric, DuckDB double, SQL Server an integer (truncated) |
| `CAST(x AS NUMERIC)` without precision | Postgres keeps every digit; DuckDB means `DECIMAL(18,3)`; SQL Server and the standard mean scale 0; MySQL `DECIMAL(10,0)` |
| Division of decimals | the result scale is engine-defined (e.g. +4 digits in MySQL; 6 in Umbra and SQL Server once 38 digits are exceeded) |
| `ROUND(x, n)` on a tie | away from zero on numerics, often to even on doubles (Postgres `round(double)`), and `round(double, n)` does not exist in Postgres |
| `CAST(x AS BIGINT)` of a fraction | rounds or truncates: DuckDB rounds a double tie to even, Postgres rounds a numeric tie away from zero, SQL Server truncates |
| `EXTRACT(EPOCH FROM interval)` | a double in DuckDB, a numeric in Postgres |
| Double arithmetic | sums of doubles differ in the last bits between engines and plans |

**How much this matters:** each difference emulated on the queries as the agents wrote them
(DuckDB, SF1), with the number of the 409 results that change:

| Emulated behaviour | Typical engine | Results that change |
|---|---|---|
| `ROUND` breaks ties to even | doubles in Postgres | 79 |
| `AVG(int)` truncates to an integer | SQL Server | 76 |
| bare `NUMERIC` means scale 0 | SQL Server, standard | 61 |
| bare `NUMERIC` means `DECIMAL(18,3)` | DuckDB | 18 |
| decimal division keeps 4 more digits | MySQL | 18 |
| decimal division keeps at least 6 digits | SQL Server | 16 |
| ±1 unit of noise in the last bit of doubles | any | 12–13 |
| integer division gives a fraction | DuckDB default, MySQL, Oracle | 6 |
| division by zero raises an error | | 5 |
| `CAST` to an integer truncates | SQL Server | 1 |

## What the standard fixes and what it leaves open

SQL:2023 Part 2 (ISO/IEC 9075-2:2023):

- **Addition and subtraction** of exact numerics: scale = the larger input scale.
- **Multiplication**: scale = the sum of the input scales.
- **Division**: "the precision and scale of the result of division are
  implementation-defined" (6.30 `<numeric value expression>`).
- **`AVG`** over exact numerics: an exact type with scale "not less than the scale" of
  the argument (10.9 `<aggregate function>`).
- **`EXTRACT`** fields are `YEAR` to `SECOND` and the time zone fields (6.31, 10.1). `EPOCH`
  is not standard.

So the inputs of a quotient must carry the scale we want.

## The rules

The query states the arithmetic it means, so every engine computes the same value, and the
checker absorbs only the digits the standard leaves to the engine.

1. **No rounding, anywhere.** Presentation rounding (`ROUND` on an output column) is where
   engines disagree on ties. Internal rounding is worse: rounded values feed later
   computations, sort keys or filters, and change results in ways no tolerance can absorb
   (q054 and q295 subtracted two percentages already rounded to one decimal).
2. **No bare `NUMERIC`/`DECIMAL` casts.** The ones that only prepared a `ROUND` are dropped.
3. **Exact arithmetic has one type, `NUMERIC(18,6)`.** Every cast we add uses it.
   - **Precision 18** fits 64-bit arithmetic, which every engine supports (wider types make
     engines compute in 128 bits). Its 12 integer digits exceed any amount, count or duration
     in the data.
   - **Scale 6** is the floor for engines that keep only the input scale (the standard's
     minimum for `AVG`, ClickHouse's division): their rounding stays near 5e-7, 1% of the
     checker's tolerance (at scale 4, half of it). It also matches the exchange rates
     (`DECIMAL(12,6)`) and holds microseconds exactly.
4. **Averages of integers are decimal:** `AVG(CAST(x AS NUMERIC(18,6)))`, so `AVG` returns a
   fraction everywhere, including engines where `AVG(int)` returns an integer.
5. **Divisions that should give a fraction say so:** `CAST(a AS NUMERIC(18,6)) / b`, for
   rates such as "failures per 1,000 orders". Divisions that should truncate stay integer
   divisions; DuckDB runs with `SET integer_division = true`.
6. **Fractions become integers only explicitly:** `FLOOR` or `CEIL`, never a `CAST` or a
   `ROUND`, whose tie rules differ. Example: q378 counted whole days of exposure with
   `CAST(epoch / 86400 AS BIGINT)`. For exactly 580.5 days, DuckDB (double, ties to even)
   gave 580 and Postgres (numeric, ties away from zero) gave 581. Whole days elapsed is
   `FLOOR`.
7. **Seconds between timestamps are `NUMERIC(18,6)`:**
   `CAST(EXTRACT(EPOCH FROM (b - a)) AS NUMERIC(18,6))` (142 sites).
   - `EPOCH` is not standard, but every engine we target has it; the cast gives the value one
     exact type (microseconds exactly, up to 31,000 years).
   - It is written by the `epoch_seconds` step of `tools/canonical.py` and then becomes the
     placeholder `{{seconds_between(a, b)}}`, whose default is this cast, so that a system
     without `EPOCH` can spell it its own way.
8. **Currency conversions are `NUMERIC(18,6)`:** `CAST(x / er.rate AS NUMERIC(18,6))`, 264
   sites in 146 queries (the `rate_conversions` step, which also covers `NULLIF`/`COALESCE`
   of a rate).
   - The division is then the placeholder `{{divide_decimal(x, er.rate)}}`, as every division
     becomes one by the types of its operands (the `divide` step, [DIALECTS.md](DIALECTS.md)).
     Its default is `x / er.rate`; ClickHouse, whose division keeps the dividend's scale (4 for
     amounts) and fails on the rate's 6, divides in double precision, as DuckDB does.
   - **Why:** DuckDB divides decimals in double precision; the standard requires an exact
     type when both operands are exact (6.30). In
     `CASE WHEN currency = 'EUR' THEN amount ELSE amount / rate END` the double branch made
     the EUR amounts doubles too, and in q230 two exactly tied rows sorted by float noise
     instead of by the tie-breaker. With the cast the CASE is exact in every engine.
   - **The other results of such a CASE** that are columns of a known decimal type (a table
     column of scale up to 6 and up to 12 integer digits, or a CTE's column that passes one
     through) get the same type, `CAST(amount AS NUMERIC(18,6))`: 73 results in 50 queries
     (the `exact_case_branch` step). The cast is exact, so no value changes, and the CASE has
     one type: ClickHouse rejects a CASE over decimals of different scales (the amount's 4
     next to the conversion's 6). An expression such as `amount - amount_refunded` stays.
   - **q258** converted with `x * (1.0 / rate)`. It now uses `x / rate`, so the cast rounds
     the amount and not the inverse rate (1/400 at scale 6 would be off by 2e-4 relative).
9. **Divisors that are zero on partial loads are guarded:** `x / NULLIF(y, 0)` in q080,
   q147, q198 and q279 only, which divide by a count or total of a 2025 period the early load
   steps do not contain yet. The standard raises an error there (Postgres, Umbra), DuckDB
   returns inf/nan; with `NULLIF` all return NULL.
10. **The engine's quotient scale is not amplified.** We emulated two division rules on all
   queries (DuckDB, SF1): the quotient keeps 6 decimals (Umbra or SQL Server past 38 digits),
   or the dividend's scale + 4 (MySQL). Five queries exceeded the tolerance, and each was
   rewritten without changing its value:
   - **q125, q186:** multiply by 1,000 before dividing;
   - **q155** (found separately, on Umbra at SF10, where the 6-decimal quotient times 100 tied
     two rows of the sort key): multiply by 100 before dividing;
   - **q062:** cast the dividend, not the divisor, and multiply by 100 before dividing;
   - **q084:** average the percentage directly (`THEN 100.0`) instead of averaging a fraction
     and multiplying by 100;
   - **q382:** compare with the quartile boundaries exactly (`4 * elapsed < lifetime` instead
     of `elapsed / lifetime < 0.25`, the same buckets since lifetimes are positive).

   Afterwards no division or `AVG` uses more than 48% of the tolerance under either rule
   (q149).

## Comparing results

`dbo-bench check <expected dir> <actual dir>` (or two `.csv` files) compares headerless CSV
results by value, not text. Rows are compared in order, because the queries are deterministic:
a different row order is a mismatch. Two values are equal when:

- **Integers:** both are integers and equal exactly, so counts cannot slip by one.
- **Other numbers:** they are close, in the numpy form with the reference as `expected`:

  ```
  |actual - expected| <= atol + rtol * |expected|,   rtol = 1e-4, atol = 1e-4
  ```
- **Exact rationals** `x/y*2^p` (from Umbra's exact arithmetic; `/y` and `*2^p` optional,
  integers of any length) count as the number they denote.
- **JSON** is equal once parsed, so key order and spacing don't matter.
- **Timestamps** may differ in trailing fractional zeros (`.411140` vs `.41114`).
- **Booleans** may be written `t`/`true` and `f`/`false`, in any case.
- **NULL and the empty string** count as equal, because CSV can't tell them apart.

**Why 1e-4:** a 6-decimal quotient (the standard leaves its scale to the engine) multiplied by
100 is only good to about 5e-5. Double noise is far below that: about 1e-12 relative between
engines, about 1e-8 when summing 10⁸ doubles at SF100. The errors to catch (rounding semantics,
integer division, a count off by one) are 1e-3 or larger. `atol` absorbs values around zero,
such as a difference of two large sums that should be 0 (q309).

## Does this change what the queries ask?

The normalization touches 373 of 409 queries: it removes 1,100 `ROUND`s and all 232 bare
`NUMERIC` casts, adds 198 casts to `NUMERIC(18,6)` (`AVG` arguments and numerators), changes one
`CAST` to `FLOOR`, and casts the 142 `EPOCH` sites and the 264 currency conversions. Each new
DuckDB result was compared with the old rounded one (SF1); a value counts as unchanged within
half a unit of the last shown decimal.

| Outcome | Queries |
|---|---|
| Unchanged apart from rounding | 387 |
| Same rows, different order (ties that existed only after rounding are now sorted by the exact value) | 15 |
| Float noise | 2 (q017, q309) |
| Exact instead of rounded intermediates | 2 (q054, q295; deltas move by up to 0.1 percentage points) |
| Integer division now gives the intended fraction | 3 (q125, q131, q186; they showed 0 or whole numbers) |

No query asks a different question; the order and value changes make the answers more
accurate. Scale 6, the `EPOCH` and conversion casts and rules 9 and 10 change no DuckDB result
beyond the tolerance, except the order of exact ties in q230 at SF10.

Umbra (the reference engine) and DuckDB agree on all 409 results at SF1, SF10 and SF100, and
on all 407 queries DuckDB answers at SF1000, where Hyper also matches on all 403 it answers.

## Trade-offs

The queries move away from what the agents wrote (each change is a derivation step, so the
original stays traceable); results read `36.038961038961034` instead of `36.0`; and the `AVG`,
numerator and conversion casts add a little per-row work, kept because they define the
result.

## Reference results

The references in `workload/results/sf<sf>/through-2025-Q4/` were made by
`tools/references/make-references.sh`: Umbra with exact arithmetic, run natively with every
period loaded at once and the queries run once without a timeout. It needs an Umbra build with
exact arithmetic (rationals), which is not public. `tools/references/validation.sh` makes them
again with another Umbra build and compares them with the committed ones. Numbers are written
exactly (up to 40 decimals).

Any trusted system can produce references instead: run the benchmark with `--keep`, then
`dbo-bench references bench/out/<date>/<config>/<system>` makes the results of its last run the
reference results of its scale factor.
