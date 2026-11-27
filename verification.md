# Verification: what was tested, and the results

Every claim in the decision records, the improvement and the memo is backed by one of the checks below. Each can be repeated from a fresh load (`reset.ps1`). Timings are in `measurement_report.md`; this file records **behaviour** (does it do the right thing).

**Test machine:** the laptop described in `measurement_report.md`, PostgreSQL 18.7 in Docker, `max_connections = 500`. Results recorded 26 November 2026.

## 1. Fresh load

| What it proves | Command | Expected | Result |
|---|---|---|---|
| The whole solution builds from zero with no manual step | `powershell -ExecutionPolicy Bypass -File .\reset.ps1` (or `bash reset.sh`) | Ends with `Fresh load complete.`, no error | Passed |
| The Monday report adds up exactly | (runs inside `reset.ps1`) | `Monday report reconciles: 380517831.49 of spend, 40420 customers, 12 months each.` | Passed |
| The rollup counts every product once | (runs inside `reset.ps1`) | `Low-stock rollup adds up: 4023 products, 1685 low stock, no double counting.` | Passed |
| Stock health assesses every product once, and its labels agree with its flags | (runs inside `reset.ps1`) | `stock_health: 4023 products assessed, 1650 need attention, 157 mismatched or below zero.` | Passed |

Each self-check **stops the load with an error** if its numbers don't add up, so a passing load is itself evidence.

## 2. The supplied race test (unmodified)

`python race_test.py` with `DATABASE_URL` pointing at the lab database.

| Test | What it checks | Result |
|---|---|---|
| 1 | Two buyers, one unit, 25 rounds: exactly one winner each round | 25/25 in every run |
| 2 | 400 buyers, 50 units: exactly 50 sold, none oversold, no errors | Exactly 50 sold in every run |
| 3 | Asking for more than exists is refused cleanly, stock untouched | Passed in every run |
| 4 | Every sale under contention left a stock movement | Passed in every run (e.g. "5 sold, 6 movements": the 6th is the test product's opening stock) |
| **Overall** | | **PASSED in 11 of 11 runs** (275 two-buyer rounds) |

**The same flash sale without the row lock** (a version of `place_order` with `FOR UPDATE` removed, on a scratch copy): **400 orders accepted for 50 units**, stock left showing 48. This is the evidence that the lock is what prevents overselling.

## 3. Behaviour tests

`docker exec -w /lab -i kloudkart psql -U postgres -d lab -f tests/verification_tests.sql`

All tests run in one transaction that is rolled back, on test products, so no real data changes.

| # | What it proves | Backs up | Result |
|---|---|---|---|
| T1 | A new product's starting stock is logged | ADR-004 | PASS |
| T2 | A sale lowers stock and writes an order, a line and one `sale` movement | ADR-001, ADR-004 | PASS |
| T3 | Ordering more than exists is refused with "out of stock"; stock and orders unchanged | ADR-001 | PASS |
| T4 | A labelled **restock** raises stock **and** writes a `restock` movement | ADR-004 | PASS |
| T5 | An unlabelled manual change is still logged, as `manual_change` | ADR-004 | PASS |
| T6 | The test product's history starts with its opening-stock row, and after all of that the stock figure equals the sum of its movements | ADR-004 | PASS |
| T7 | A sale whose transaction **fails halfway leaves no trace**: no order, no stock change, no movement | ADR-001 | PASS |
| T8 | A direct update to negative stock is refused | ADR-001, ADR-005 | PASS |
| T9 | An order for a customer that doesn't exist is refused | ADR-005 | PASS |
| T10 | Editing an old movement is refused | ADR-004 | PASS |
| T11 | Emptying the movement log (`TRUNCATE`) is refused | ADR-004 | PASS |
| T12 | Every status spelling in the data has a meaning | F-01 | PASS |
| T13 | Stock health labels real situations correctly: a product out of stock but still selling, and one with under 7 days of cover | improvement.md | PASS |
| T14 | Rebuilding the Monday report records the time in `report_settings.last_refreshed`, so a stale report is visible | ADR-002, README | PASS |

## 4. Checks run by hand

| What it proves | Command | Result |
|---|---|---|
| The log refuses an edit, with a hint on what to do instead | `UPDATE inventory_log SET change_qty = 0 WHERE log_id = 1;` | `ERROR: inventory_log rows cannot be changed or wiped: UPDATE is not allowed. Record a correction as a new row instead.` |
| Stock health finds the expected problem groups | `SELECT * FROM stock_health_summary;` | 14 / 143 / 565 / 928 / 2,373 products |
| 20 products hold most of the unexplained stock value | `SELECT * FROM stock_count_first;` (plus the share query in `improvement.md`) | 88.3% |

## 5. Safety of the load itself

| What it proves | How it was checked | Result |
|---|---|---|
| A failure inside the schema changes leaves the schema untouched | `02_schema_changes.sql` broken on purpose (a division by zero just before its `COMMIT`), then a full reset | The reset stopped at that error; none of 02's rules, its status table or its identity columns remained |
| A missing or stopped container gives a clear message | The reset run with no container, then with a stopped one | `STOPPED: there is no container named 'kloudkart'...` / `STOPPED: container 'kloudkart' exists but is not running...` |

These two were checked with `reset.sh` on the separate test server (PostgreSQL 16, same data); `reset.ps1` runs the same steps with the same guard.

## What is not tested

- A real flash sale on the production server, with the website in front of it (only the simulated 400-buyer test on a laptop).
- Orders with several products in one go (`place_order` takes one product).
- That the website sends every sale through `place_order`.
- Behaviour under a different isolation level from the default (Read Committed).