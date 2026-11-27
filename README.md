# Kloud Kart: inventory and order management

**AmaliTech DE03 SQL for Data Professionals lab.** Author: Yaw Asiamah.

Kloud Kart runs on one PostgreSQL server with a schema nobody ever redesigned. This repository stops overselling, makes the Monday customer-spending report fast, rolls low stock up a category tree of any depth, and records every stock movement. It all runs on the existing server, with no new infrastructure.

## Where each deliverable is

| The brief asks for | File |
|---|---|
| 1. Diagnosis of the data, ranked by danger | `data_findings.md` (checks in `sql/01_integrity_checks.sql`, costs in `sql/01b_cost_of_findings.sql`) |
| 2. The working SQL solution | `sql/` folder, run in order by `sql/run_all.sql` |
| 3. Key decisions, including whether triggers alone would have worked | `decisions/ADR-001` to `ADR-005` (triggers: ADR-001, Alternative C) |
| 4. One-page memo to Nana | `client_memo.md` |
| 5. One improvement beyond the brief | `improvement.md` (built in `sql/09_stock_health.sql`) |
| Performance, before and after | `measurement_report.md` (before query in `benchmarks/`) |
| Evidence that it works | `verification.md` (tests in `tests/verification_tests.sql`) |
| Optional: a visual dashboard for non-technical readers | `dashboard/app.py` (see below) |

## How to run it from a fresh load

**You need:** Docker, Python 3 with `psycopg2-binary`, and the Kloud Kart data bundle.

**1. Get the data.** The `data/` folder (the six CSV files) is **not** in this repository, because it holds customer names, emails and phone numbers. Copy it from the Evalu8 bundle into this folder, so you have `data/categories.csv` and the rest next to `load.sql`.

**2. Start PostgreSQL 18** from this folder. `max_connections=500` is required: the race test opens 400 connections at once, and the default of 100 makes it time out.
```
docker run -d --name kloudkart -e POSTGRES_PASSWORD=kloudkart -p 5432:5432 -v "${PWD}:/lab" postgres:18 -c max_connections=500
```

**3. Build everything from zero** (drops and recreates the `lab` database, loads the data, runs every script, prints row counts):
```
powershell -ExecutionPolicy Bypass -File .\reset.ps1
```
It stops at the first error. It should end with three self-check lines and `Fresh load complete.`:
```
NOTICE:  Monday report reconciles: 380517831.49 of spend, 40420 customers, 12 months each.
NOTICE:  Low-stock rollup adds up: 4023 products, 1685 low stock, no double counting.
NOTICE:  stock_health: 4023 products assessed, 1650 need attention, 157 mismatched or below zero.
```
On Linux or macOS, run the same steps by hand: `dropdb`/`createdb`, then `schema.sql`, `load.sql`, `sql/run_all.sql`, all with `-v ON_ERROR_STOP=1`.

**4. Run the supplied race test** (unmodified):
```
$env:DATABASE_URL="postgresql://postgres:kloudkart@localhost:5432/lab"
python race_test.py
```

**5. Run the behaviour tests** (they roll themselves back, so the database is unchanged):
```
docker exec -w /lab -i kloudkart psql -U postgres -d lab -f tests/verification_tests.sql
```

## Files, in run order

| File | What it does |
|---|---|
| `schema.sql`, `load.sql`, `race_test.py` | Supplied by the course, **unchanged** |
| `check_setup.sql` | Prints the PostgreSQL version, `max_connections` and the six row counts |
| `reset.ps1` | Fresh load: drop, create, schema, load, `run_all.sql`, check |
| `sql/01_integrity_checks.sql` | 31 checks, one per rule the schema doesn't enforce, plus data profiles (read only) |
| `sql/01b_cost_of_findings.sql` | The business cost of each finding (read only) |
| `sql/02_schema_changes.sql` | Rules that stop new bad data (listed below) |
| `sql/03_audit_trail.sql` | Trigger that writes a movement row for every stock change |
| `sql/04_place_order.sql` | `place_order()`: locks the product row, so two buyers can't take the same unit |
| `sql/05_monday_report.sql` | The Monday report: one pass over the orders, stored and refreshed without blocking readers |
| `sql/06_category_rollup.sql` | Low stock rolled up through the category tree, any depth, with a loop guard |
| `sql/07_indexes_and_stats.sql` | 4 indexes chosen by measurement, then `ANALYZE` |
| `sql/08_protect_audit_log.sql` | Refuses edits (`UPDATE`) and emptying (`TRUNCATE`) of the stock log |
| `sql/09_stock_health.sql` | The improvement: days of cover and stock-figure checks |
| `benchmarks/monday_report_before.sql` | The slow "before" report, for the measurement report only (not in `run_all.sql`) |
| `benchmarks/capture_plans.sql` | Saves the query plans to `benchmarks/plans/` (evidence for the measurement report; not in `run_all.sql`). **Run on a test copy only, never on the live server:** to compare with and without an index it drops the index inside a transaction, which locks that table until the rollback |
| `benchmarks/top100_alternative.sql` | Tests a faster top-100 read with a temporary view; changes nothing (see the measurement report, plan 01) |
| `tests/verification_tests.sql` | 13 behaviour tests (not in `run_all.sql`) |
| `dashboard/app.py`, `dashboard/requirements.txt` | Optional read-only dashboard (not in `run_all.sql`) |

## Schema changes (for Nana's team)

Everything below is added by the scripts; nothing in the original data is rewritten or deleted.

| Change | Where | Why |
|---|---|---|
| `order_id`, `order_item_id`, `log_id` become identity columns, started after the highest existing ID | 02 | Two buyers at the same instant get different IDs ("max + 1" would collide) |
| `CHECK (stock_quantity >= 0)`, applied to new changes only (`NOT VALID`) | 02 | A safety net under `place_order`; the 14 old negative rows stay visible |
| `CHECK (quantity > 0)` on order lines | 02 | No existing line breaks it |
| Foreign keys: product → category, category → parent, order → customer, order line → order, order line → product, movement → product (the ones old data breaks are `NOT VALID`) | 02 | New orphan rows are refused; old ones stay for review |
| Table `order_status_map`, view `unmapped_order_statuses` | 02 | What each of the 15 status spellings means; flags any new spelling |
| Function `log_stock_change()` and 2 triggers on `products` | 03 | Every stock change writes a movement row in the same transaction |
| Function `place_order(customer, product, quantity)` | 04 | The ordering step the shop must call |
| Table `report_settings`; views `spend_orders`, `monday_report_summary`, `top_100_customers`; materialized view `monday_report` with 2 indexes; function `refresh_monday_report()` | 05 | The Monday report |
| Table `stock_settings`; views `category_tree`, `low_stock_by_category`, `low_stock_products`, `low_stock_summary` | 06 | The low-stock rollup |
| Indexes `order_items_order_idx`, `order_items_product_idx`, `orders_customer_date_idx`, `inventory_log_product_date_idx` | 07 | Measured gains (see the measurement report) |
| Function `refuse_log_change()` and 2 triggers on `inventory_log` | 08 | The stock trail can be added to, not rewritten |
| 2 columns on `stock_settings`; views `stock_health`, `stock_health_alerts`, `stock_count_first`, `stock_health_summary` | 09 | The improvement |

## Optional: dashboard for non-technical readers

A small read-only web page that shows the same figures as charts and tables, for Nana and Adwoa: sales per month, the top 100 (names hidden unless switched on), one customer's months and running total, low stock by category with drill-down, stock health and the 20 products to count first, and the data problems counted live.

```
python -m pip install -r dashboard/requirements.txt
copy .env.example .env
python -m streamlit run dashboard/app.py
```
Run these from the `kloudkart-lab` folder, then open the address it prints (usually http://localhost:8501). The `copy` line is needed once: it creates `.env`, which holds `DATABASE_URL` so it need not be typed in every new terminal. `.env` is in `.gitignore`, so it is never uploaded. (`race_test.py` doesn't read `.env`; it still needs `$env:DATABASE_URL=...` set in the terminal.)

- **Optional.** It is not part of the graded SQL solution, and `reset.ps1` doesn't run it. Everything it shows comes from the views the SQL already builds, so the figures are the same as in the reports.
- **Read-only.** It connects with `default_transaction_read_only=on`, so the database refuses any change made through it.
- **No new server or bill.** It runs on the laptop that opens it; a reviewer who doesn't install it loses nothing.

## Settings and routine jobs

| What | How |
|---|---|
| Rebuild the Monday report (**must be scheduled**; nothing starts it yet) | `SELECT refresh_monday_report();` about 7 s; readers are not blocked. On a Linux server, for example, a cron line for Monday 06:00: `0 6 * * 1 psql -d <database> -c "SELECT refresh_monday_report();"` |
| End of the report period | `UPDATE report_settings SET as_of = '<end of last complete month>';` then refresh |
| What counts as spend | `order_status_map.counts_as_spend` (currently completed and shipped) |
| Low-stock threshold, sales window, days of cover | `UPDATE stock_settings SET low_stock_threshold = 5, sales_window_days = 28, min_days_of_cover = 7;` |
| Label a stock change | `SELECT set_config('kloudkart.stock_reason', 'restock', true);` in the same transaction as the update; unlabelled changes are logged as `manual_change` |

## Assumptions (the brief left these open)

- The extract ends on **31 Aug 2026**; 24 later-dated orders are left out of the report period.
- **Spend** = orders whose status means completed or shipped.
- **Order value** = `orders.total_amount`, not the sum of its lines.
- **Running total** = lifetime spend up to the end of each month. **Ranking** uses `rank()`, so ties share a place.
- **Low stock** = 5 units or fewer.
- Details and reasons: `decisions/ADR-002`, `ADR-003` and `data_findings.md`.

## Use of AI

I used Claude (an AI assistant) as a pair-programmer and reviewer for this lab: to help write and check the SQL, review my documents, and explain concepts. Every result was run and measured on my own laptop, and the decisions and their reasons are ones I can explain and defend. I shared queries, counts and error messages with it, not customers' names, emails or phone numbers.