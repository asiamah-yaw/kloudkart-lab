# Kloud Kart: inventory and order management

**AmaliTech DE03 SQL for Data Professionals lab.** Author: Yaw Asiamah.

Kloud Kart runs on one PostgreSQL server with a schema nobody ever redesigned. This repository stops overselling, makes the Monday customer-spending report fast, rolls low stock up a category tree of any depth, and records every stock movement. It all runs on the existing server, with no new infrastructure.

## Where each deliverable is

| The brief asks for | File |
|---|---|
| 1. Diagnosis of the data, ranked by danger | `data_findings.md` (checks in `sql/01_integrity_checks.sql`, costs in `sql/01b_cost_of_findings.sql`) |
| 2. The working SQL solution | `sql/` folder, run in order by `sql/run_all.sql` |
| 3. Key decisions, including whether triggers alone would have worked | Five decision records in `decisions/` (list below; triggers: ADR-001, Alternative C) |
| 4. One-page memo to Nana | `client_memo.md` |
| 5. One improvement beyond the brief | `improvement.md` (built in `sql/09_stock_health.sql`) |
| Performance, before and after | `measurement_report.md` (scripts in `benchmarks/`, saved query plans in `benchmarks/plans/`) |
| Evidence that it works | `verification.md` (tests in `tests/verification_tests.sql`) |
| Optional: a visual dashboard for non-technical readers | `dashboard/app.py` (see below) |

**The decision records:**
- [ADR-001: Lock the product row to stop overselling](decisions/ADR-001-row-lock-stops-overselling.md)
- [ADR-002: Rewrite the Monday report as one pass and store the result](decisions/ADR-002-monday-report-one-pass-stored.md)
- [ADR-003: Roll low stock up the category tree with a guarded recursive view](decisions/ADR-003-low-stock-rollup-live-recursive.md)
- [ADR-004: Record every stock change with a trigger, and block edits to the log](decisions/ADR-004-audit-trail-trigger-append-only.md)
- [ADR-005: Stop new bad data with rules; keep the existing bad data visible](decisions/ADR-005-stop-new-bad-data-keep-old-visible.md)

**One known inefficiency, measured and documented:** reading the top 100 takes about 0.15 s, which meets Nana's "in seconds", but the query plan shows it reads the whole stored report instead of using its rank index. A faster read (about 2 ms, same 100 rows) was tested and deliberately not applied; see `measurement_report.md`, plan 01.

## How to run it from a fresh load

**You need:** Docker, Python 3 with `psycopg2-binary`, and the Kloud Kart data bundle.

**1. Get the data.** The `data/` folder (the six CSV files) is **not** in this repository, because it holds customer names, emails and phone numbers. Copy it from the Evalu8 bundle into this folder, so you have `data/categories.csv` and the rest next to `load.sql`.

**2. Start PostgreSQL 18** from this folder. `max_connections=500` is required: the race test opens 400 connections at once, and the default of 100 makes it time out.
```
docker run -d --name kloudkart -e POSTGRES_PASSWORD=kloudkart -p 5432:5432 -v "${PWD}:/lab" postgres:18 -c max_connections=500
```
- **`kloudkart` is a throwaway password for this local practice container only**, taken from the course's setup. Never reuse it, and never use a real password in a command, a file or this repository.
- **Port 5432** is PostgreSQL's usual port. If something else on your machine already uses it, change the first number (for example `-p 5433:5432`) and use that port in `DATABASE_URL` below and in `.env`.

**3. Build everything from zero.** This drops and recreates the `lab` database, loads the data, runs every script in order, and prints the row counts. It stops at the first error, and first checks that the `kloudkart` container exists and is running.
```
powershell -ExecutionPolicy Bypass -File .\reset.ps1      # Windows
bash reset.sh                                             # Linux / macOS (same steps)
```
It should end with three self-check lines and `Fresh load complete.`:
```
NOTICE:  Monday report reconciles: 380517831.49 of spend, 40420 customers, 12 months each.
NOTICE:  Low-stock rollup adds up: 4023 products, 1685 low stock, no double counting.
NOTICE:  stock_health: 4023 products assessed, 1650 need attention, 157 mismatched or below zero.
```
These figures are what **the supplied extract** gives. The self-checks themselves don't compare against fixed numbers: they check that totals reconcile (for example, every unit of spend appears in the report exactly once), so on different data the figures change but the checks still hold. **If any step fails, fix the cause and run the reset again from the start.** Never continue a half-finished load; the schema changes in `02` run as one transaction, so a failure there leaves the schema untouched.

**4. Run the supplied race test** (unmodified):
```
$env:DATABASE_URL="postgresql://postgres:kloudkart@localhost:5432/lab"
python race_test.py
```

**5. Run the behaviour tests** (they roll themselves back, so the database is unchanged):
```
docker exec -w /lab -i kloudkart psql -U postgres -d lab -f tests/verification_tests.sql
```

## Files

**The fresh load, in the order the reset runs them:**

| Step | File | What it does |
|---|---|---|
| | `reset.ps1` / `reset.sh` | Checks the container, then runs everything below in order, stopping at the first error |
| 1 | `schema.sql` | Supplied by the course, **unchanged**: creates the original tables |
| 2 | `load.sql` | Supplied by the course, **unchanged**: loads the CSV files |
| 3 | `sql/run_all.sql` | Runs the lab scripts below, in order |
| 3a | `sql/01_integrity_checks.sql` | 31 checks, one per rule the schema doesn't enforce, plus data profiles (read only) |
| 3b | `sql/01b_cost_of_findings.sql` | The business cost of each finding (read only) |
| 3c | `sql/02_schema_changes.sql` | Rules that stop new bad data (listed below), as one transaction |
| 3d | `sql/03_audit_trail.sql` | Trigger that writes a movement row for every stock change |
| 3e | `sql/04_place_order.sql` | `place_order()`: locks the product row, so two buyers can't take the same unit |
| 3f | `sql/05_monday_report.sql` | The Monday report: one pass over the orders, stored and refreshed without blocking readers |
| 3g | `sql/06_category_rollup.sql` | Low stock rolled up through the category tree, any depth, with a loop guard |
| 3h | `sql/07_indexes_and_stats.sql` | 4 indexes chosen by measurement, then `ANALYZE` |
| 3i | `sql/08_protect_audit_log.sql` | Refuses edits (`UPDATE`) and emptying (`TRUNCATE`) of the stock log; single-row `DELETE` stays possible (see ADR-004) |
| 3j | `sql/09_stock_health.sql` | The improvement: days of cover and stock-figure checks |
| 4 | `check_setup.sql` | Prints the PostgreSQL version, `max_connections` and the six row counts |

**Run separately, never part of the fresh load:**

| File | What it does |
|---|---|
| `race_test.py` | Supplied by the course, **unchanged**: the concurrency test |
| `tests/verification_tests.sql` | 14 behaviour tests, rolled back afterwards |
| `benchmarks/monday_report_before.sql` | The slow "before" report, for the measurement report only |
| `benchmarks/capture_plans.sql` | Saves the query plans to `benchmarks/plans/`. **Run on a test copy only, never on the live server:** to compare with and without an index it drops the index inside a transaction, which locks that table until the rollback |
| `benchmarks/top100_alternative.sql` | Tests a faster top-100 read with a temporary view; changes nothing |
| `ops/refresh_monday_report.ps1`, `ops/refresh_monday_report.sh` | Rebuild the Monday report (see "Settings and routine jobs") |
| `dashboard/app.py`, `dashboard/requirements.txt` | Optional read-only dashboard |

## Schema changes (for Nana's team)

Everything below is added by the scripts; nothing in the original data is rewritten or deleted.

| Change | Where | Why |
|---|---|---|
| `order_id`, `order_item_id`, `log_id` become identity columns, started after the highest existing ID | 02 | Two buyers at the same instant get different IDs ("max + 1" would collide) |
| `CHECK (stock_quantity >= 0)`, applied to new changes only (`NOT VALID`) | 02 | A safety net under `place_order`; the 14 old negative rows stay visible until they are fixed (see "Fixing the 14 products below zero") |
| `CHECK (quantity > 0)` on order lines | 02 | No existing line breaks it |
| Foreign keys: product → category, category → parent, order → customer, order line → order, order line → product, movement → product (the ones old data breaks are `NOT VALID`) | 02 | New orphan rows are refused; old ones stay for review |
| Table `order_status_map`, view `unmapped_order_statuses` | 02 | What each of the 15 status spellings means; flags any new spelling |
| Function `log_stock_change()` and 2 triggers on `products` | 03 | Every stock change writes a movement row in the same transaction |
| Function `place_order(customer, product, quantity)` | 04 | The ordering step the shop must call |
| Table `report_settings` (with `last_refreshed`); views `spend_orders`, `monday_report_summary`, `top_100_customers`; materialized view `monday_report` with 2 indexes; function `refresh_monday_report()` | 05 | The Monday report, and a record of when it was last rebuilt |
| Table `stock_settings`; views `category_tree`, `low_stock_by_category`, `low_stock_products`, `low_stock_summary` | 06 | The low-stock rollup |
| Indexes `order_items_order_idx`, `order_items_product_idx`, `orders_customer_date_idx`, `inventory_log_product_date_idx` | 07 | Measured gains (see the measurement report) |
| Function `refuse_log_change()` and 2 triggers on `inventory_log` | 08 | Stock movements can't be edited or wiped, only corrected with a new row |
| 2 columns on `stock_settings`; views `stock_health`, `stock_health_alerts`, `stock_count_first`, `stock_health_summary` | 09 | The improvement |

## Optional: dashboard for non-technical readers

A small read-only web page that shows the same figures as charts and tables, for Nana and Adwoa: sales per month, the top 100 (names hidden unless switched on), one customer's months and running total, low stock by category with drill-down, stock health and the 20 products to count first, and the data problems counted live. Its header shows when the Monday report was last rebuilt.

```
python -m pip install -r dashboard/requirements.txt
copy .env.example .env
python -m streamlit run dashboard/app.py
```
Run these from the `kloudkart-lab` folder, then open the address it prints (usually http://localhost:8501). The `copy` line is needed once: it creates `.env`, which holds `DATABASE_URL` so it need not be typed in every new terminal (on Linux / macOS use `cp` instead of `copy`). `.env` is in `.gitignore`, so it is never uploaded. (`race_test.py` doesn't read `.env`; it still needs `$env:DATABASE_URL=...` set in the terminal.)

- **Optional.** It is not part of the graded SQL solution, and the reset doesn't run it. Everything it shows comes from the views the SQL already builds, so the figures are the same as in the reports.
- **Read-only.** It connects with `default_transaction_read_only=on`, so the database refuses any change made through it.
- **Doesn't reveal the connection string.** If it can't connect, it shows a short message without `DATABASE_URL` or the driver's error text, so the password never appears on screen.
- **Pinned libraries.** `dashboard/requirements.txt` pins the exact versions it was tested with.
- **No new server or bill.** It runs on the laptop that opens it; a reviewer who doesn't install it loses nothing.

## Settings and routine jobs

**Rebuilding the Monday report (must be scheduled).** The stored report only changes when it is rebuilt, so schedule a rebuild for early Monday, before Adwoa opens it. Each rebuild takes about 7 seconds, readers are not blocked, and the time is recorded in `report_settings.last_refreshed`, so a stale report is visible (the dashboard shows it; in SQL: `SELECT last_refreshed FROM report_settings;`).

| Where the database runs | Script | Schedule it with |
|---|---|---|
| This laptop's Docker container | `ops/refresh_monday_report.ps1` | Windows Task Scheduler, Monday 06:00: `schtasks /Create /TN "KloudKart Monday report" /SC WEEKLY /D MON /ST 06:00 /TR "powershell -ExecutionPolicy Bypass -File C:\path\to\kloudkart-lab\ops\refresh_monday_report.ps1"` (replace the path) |
| Kloud Kart's own server (PostgreSQL directly) | `ops/refresh_monday_report.sh` | cron, Monday 06:00: `0 6 * * 1 DATABASE_URL=postgresql://... /path/to/kloudkart-lab/ops/refresh_monday_report.sh` |

**Other settings:**

| What | How |
|---|---|
| End of the report period | `UPDATE report_settings SET as_of = '<end of last complete month>';` then rebuild |
| What counts as spend | `order_status_map.counts_as_spend` (currently completed and shipped) |
| Low-stock threshold, sales window, days of cover | `UPDATE stock_settings SET low_stock_threshold = 5, sales_window_days = 28, min_days_of_cover = 7;` |
| Label a stock change | `SELECT set_config('kloudkart.stock_reason', 'restock', true);` in the same transaction as the update; unlabelled changes are logged as `manual_change` |

**Fixing the 14 products below zero.** The "stock can't go below zero" rule is checked on every new change but not yet on these 14 old rows. To fix them:
1. List them: `SELECT * FROM stock_health_alerts WHERE is_below_zero;` (most valuable first).
2. Count each product physically.
3. Record each counted figure as a labelled correction, so the trail stays complete:
```
BEGIN;
SELECT set_config('kloudkart.stock_reason', 'correction', true);
SELECT set_config('kloudkart.stock_note', 'physical count <date>', true);
UPDATE products SET stock_quantity = <counted figure> WHERE product_id = <id>;
COMMIT;
```
4. When none are left below zero, make the rule cover old rows too: `ALTER TABLE products VALIDATE CONSTRAINT products_stock_not_negative;`

## Assumptions (the brief left these open)

- The extract ends on **31 Aug 2026**; 24 later-dated orders are left out of the report period.
- **Spend** = orders whose status means completed or shipped.
- **Order value** = `orders.total_amount`, not the sum of its lines.
- **Running total** = lifetime spend up to the end of each month. **Ranking** uses `rank()`, so ties share a place.
- **Low stock** = 5 units or fewer.
- Details and reasons: ADR-002, ADR-003 and `data_findings.md`.

## Use of AI

I used Claude (an AI assistant) as a pair-programmer and reviewer for this lab: to help write and check the SQL, review my documents, and explain concepts. Every result was run and measured on my own laptop, and the decisions and their reasons are ones I can explain and defend. I shared queries, counts and error messages with it, not customers' names, emails or phone numbers.