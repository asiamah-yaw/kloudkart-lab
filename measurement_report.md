# Query speed report — Kloud Kart

## Target

From the brief:
- **Monday report** (per customer: total spent, order count, monthly spend for the trailing 12 months, running total, top-100 ranking): **"in seconds on an ordinary laptop"**.
- **Low-stock rollup** through the category tree: **"in a couple of seconds"**.
- **Flash sale:** about **400 orders in ten seconds on one product**, with no overselling.

## Method

- **Hardware:** laptop, Intel Core i7-6820HQ @ 2.70 GHz, 32 GB RAM, Windows. PostgreSQL 18.7 in Docker (Docker limited to 4 CPUs and 11.7 GB of memory), `max_connections = 500`.
- **Data:** the full Kloud Kart extract on a fresh load (`reset.ps1`): 159,384 orders, 336,559 order lines, 40,420 customers, 4,023 products, 282,352 stock movements.
- **What was timed:** psql's `\timing` (from sending the statement to receiving the last row). For the flash sale: the wall-clock figure printed by `race_test.py` for Test 2 (from releasing 400 buyers to the last one answering).
- **Runs:** warm (the data had just been loaded and read, so it was in memory). Every run is recorded, not only the best. Where there are several runs, the **median** (middle value) is reported; with 4 runs it is the average of the middle two. With this few runs, p95 is the worst run.
- **Before figure for the Monday report:** Adwoa's real query was not supplied. The "before" is a representative stand-in, `benchmarks/monday_report_before.sql`: the report written the common slow way, with one small query per figure per customer (15 per customer). It was run on the first 50 customers and the full time estimated as `time × 40,420 ÷ 50`. Running it on all customers was not practical (hours).
- **How to reproduce:**
  1. `powershell -ExecutionPolicy Bypass -File .\reset.ps1`
  2. Before: `docker exec -w /lab -i kloudkart psql -U postgres -d lab -v sample=50 -f benchmarks/monday_report_before.sql`
  3. After: `docker exec -i kloudkart psql -U postgres -d lab -c "\timing on" -c "SELECT * FROM low_stock_summary;" -c "SELECT * FROM top_100_customers;" -c "SELECT refresh_monday_report();"`
  4. Flash sale: `python race_test.py` (DATABASE_URL pointing at the lab database)
  5. Stock health (improvement): `docker exec -i kloudkart psql -U postgres -d lab -P pager=off -c "\timing on" -c "SELECT count(*) FROM stock_health_alerts;" -c "SELECT * FROM stock_count_first;"`

## Results

| Scenario | Runs | Median | p95 | Worst | Target met? |
|---|---|---|---|---|---|
| Monday report: read the top 100 | 2 | 0.15 s | 0.15 s | 0.15 s | Yes ("in seconds") |
| Monday report: one customer's 12 months | 1 | 0.7 ms | n/a | 0.7 ms | Yes |
| Monday report: rebuild without blocking readers (`refresh_monday_report()`) | 1 | 7.1 s | n/a | 7.1 s | Yes (a weekly background job, not something Adwoa waits for) |
| Monday report: build on a fresh load | 2 | 2.9 s | 2.9 s | 2.9 s | Yes |
| Low-stock summary through the whole tree | 3 | 8.6 ms | 9.6 ms | 9.6 ms | Yes ("a couple of seconds") |
| Stock health: full alert list (improvement) | 2 (137, 139 ms) | 138 ms | 139 ms | 139 ms | No target set; well under a second |
| Stock health: the 20 products to count first (improvement) | 1 | 72.7 ms | n/a | 72.7 ms | No target set; well under a second |
| Flash sale: 400 buyers, 50 units (Test 2), with all changes in place | 4 (5.0, 5.2, 5.9, 6.3 s) | 5.6 s | 6.3 s | 6.3 s | Yes (under 10 s; exactly 50 sold, 0 errors, every run) |
| Two buyers, one unit (Test 1, 25 rounds per run) | 7 runs (175 rounds) | 25/25 every run | | | Yes (exactly one winner every round) |
| Whole race test (Tests 1 to 4) | 7 runs | passed 7 of 7 | | | Yes |

## Before / after

Each row changes **one** thing.

| Query / stage | Before | After | Change |
|---|---|---|---|
| Monday report, written the slow way (one query per figure, per customer) vs the rewrite (one pass over the orders, result stored) | ~3.5 hours (15.5 s per 50 customers × 808) | 2.9 s to build, 0.15 s to read the top 100 | About 4,000× faster to build; Adwoa now reads in under a second |
| The **same slow query**, only adding indexes | ~3.5 hours | ~1.3 hours (5.9 s per 50 customers × 808) | 2.6× faster but still over an hour: indexes alone do not fix the report; the rewrite does |
| Low-stock summary, before vs after refreshing table statistics (`ANALYZE`) and adding indexes | 917 ms | 8.6 ms | ~107× faster. Isolated separately: `ANALYZE` alone caused it (new settings tables had no statistics, so the planner chose a poor plan); the products index made no difference and was **not** added |
| Flash sale (400 buyers) before vs after the 4 new indexes | 4.4 s (median of 5.2 / 4.3 / 4.4) | 5.6 s (median of 5.2 / 5.9 / 5.0 / 6.3) | About 1.2 s slower at the median. The runs overlap (4.3 to 5.2 before, 5.0 to 6.3 after), so part of this is run-to-run variation; part may be the small extra cost of updating 4 more indexes per order. The 6.3 s run was the first after a full fresh reload (26 Nov), with the Phase 7 changes also in place. Still well within 10 s |

Supporting measurements, taken with the same data on a separate test PostgreSQL server to isolate single changes (same method, 3 runs each):

| Change | Before | After |
|---|---|---|
| Delete 2,000 orders (the foreign key checks the order lines for each one) without / with an index on `order_items(order_id)` | ~28 s | ~15 ms |
| One customer's orders without / with an index on `orders(customer_id, order_date)` | ~7 ms | ~1.2 ms |
| One product's stock history without / with an index on `inventory_log(product_id, created_at)` | ~11 ms | ~2 ms |
| Place 2,000 orders one after another, without / with the 4 indexes | ~263 ms | ~224 ms (no measurable slowdown) |
| Index on `products(category_id)` | 6 ms | 6 ms (no gain, not added) |

## Caveats

- **The "before" is a stand-in.** Adwoa's real 40-minute query was not available. The stand-in is slower than she reported (an estimated 3.5 hours), so the exact speed-up figure should not be quoted as hers. The conclusion holds either way: the old approach repeats a small query hundreds of thousands of times, and the rewrite does the work once.
- **The full "before" time is estimated** from 50 customers, not measured on all 40,420.
- **Warm runs.** First runs after a restart (data not yet in memory) will be somewhat slower.
- **A laptop, not the production server.** The server may be faster or slower; it also serves live orders at the same time.
- **Data will grow.** The Monday report rebuild time grows with the number of orders. At about 4,000 orders a day, re-measure the refresh after a few months.
- **The stored report is only as fresh as its last refresh.** Reading is instant because it was calculated in advance.
- **Run-to-run variation is real.** The same flash sale ranged from 4.3 to 6.3 s across 7 runs on the same laptop, with other programs (Docker Desktop, VS Code) running. That is why every run is listed rather than one figure.
- **Flash-sale timing includes Python opening 400 connections.** Each buyer holds the product lock for only milliseconds. A real flash sale whose application keeps connections open would be quicker; one with slower networks would be slower.
- **Supporting measurements** come from a separate test server (PostgreSQL 16, same data), used to change one thing at a time. The headline results above are all from this laptop.