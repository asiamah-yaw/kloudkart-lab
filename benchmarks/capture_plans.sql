-- =====================================================================
-- benchmarks/capture_plans.sql
-- Saves the database's own explanation (EXPLAIN ANALYZE) of the key
-- queries, as evidence for measurement_report.md.
--
-- Run AFTER a fresh load (reset.ps1), from the kloudkart-lab folder:
--   mkdir benchmarks\plans
--   docker exec -w /lab -i kloudkart psql -U postgres -d lab -f benchmarks/capture_plans.sql
-- Each plan is written to benchmarks/plans/NN_name.txt.
--
-- Each plan is ONE warm run (data already in memory), so its time is a
-- single measurement; the medians are in measurement_report.md.
-- "Without index" plans drop the index INSIDE a transaction and then
-- ROLL BACK, so the database ends exactly as it started.
--
-- RUN ON A TEST COPY ONLY, NEVER ON THE LIVE SERVER: DROP INDEX locks the
-- whole table until the rollback, so every order or stock change waiting on
-- that table would stall for the length of the query.
-- Read-only otherwise. Not part of run_all.sql.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

-- A real customer and product to look up (the top spender, and the product
-- with the most stock movements), chosen the same way on every machine.
SELECT customer_id AS cust FROM top_100_customers ORDER BY spend_rank, customer_id LIMIT 1 \gset
SELECT product_id AS prod FROM inventory_log GROUP BY product_id ORDER BY count(*) DESC, product_id LIMIT 1 \gset

-- ---------------------------------------------------------------------
-- 1. Monday report: Adwoa reading the top 100 (the stored result)
-- ---------------------------------------------------------------------
\o benchmarks/plans/01_top_100_read.txt
\echo '-- Plan: reading the top 100 from the stored Monday report (sql/05).'
\echo '-- Look for: an Index Scan on monday_report_rank_idx; very few rows read.'
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM top_100_customers;
\o

-- ---------------------------------------------------------------------
-- 2. Monday report: building it (what refresh_monday_report() runs)
-- ---------------------------------------------------------------------
\o benchmarks/plans/02_monday_report_build.txt
\echo '-- Plan: the query that builds the Monday report, run once per refresh (sql/05).'
\echo '-- Look for: ONE scan of orders feeding a HashAggregate (the one pass), then'
\echo '-- WindowAgg nodes for the running total and the rank. No loop per customer.'
SELECT 'EXPLAIN (ANALYZE, BUFFERS) ' || pg_get_viewdef('monday_report'::regclass) \gexec
\o

-- ---------------------------------------------------------------------
-- 3. One customer's 12 months from the stored report
-- ---------------------------------------------------------------------
\o benchmarks/plans/03_one_customer_months.txt
\echo '-- Plan: one customer, 12 months, from the stored report (sql/05).'
\echo '-- Look for: an Index Scan on the unique (customer_id, month) index.'
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM monday_report WHERE customer_id = :cust ORDER BY month;
\o

-- ---------------------------------------------------------------------
-- 4. Low-stock rollup through the category tree
-- ---------------------------------------------------------------------
\o benchmarks/plans/04_low_stock_summary.txt
\echo '-- Plan: low stock rolled up through the whole category tree (sql/06).'
\echo '-- Look for: a Recursive Union (the tree walk) over only 94 categories, then'
\echo '-- one join to products. Millisecond total: no index is needed here.'
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM low_stock_summary;
\o

-- ---------------------------------------------------------------------
-- 5. Stock health alert list (the improvement)
-- ---------------------------------------------------------------------
\o benchmarks/plans/05_stock_health_alerts.txt
\echo '-- Plan: the stock health alert list (sql/09).'
\echo '-- Look for: one pass over inventory_log for the history totals, and the'
\echo '-- recent-sales part filtered by date.'
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM stock_health_alerts;
\o

-- ---------------------------------------------------------------------
-- 6. One customer's orders: WITH vs WITHOUT orders_customer_date_idx
-- ---------------------------------------------------------------------
-- Warm-up read (output discarded), so the WITH and WITHOUT runs both start with data in memory.
SELECT * FROM orders WHERE customer_id = :cust \g /dev/null
\o benchmarks/plans/06_customer_orders_with_without_index.txt
\echo '-- Plan pair: one customer''s orders, newest first (sql/07).'
\echo '-- WITH the index: Index Scan, a handful of rows read.'
\echo '-- WITHOUT it: Seq Scan over all 159,384 orders, almost all thrown away.'
\echo ''
\echo '======== WITH orders_customer_date_idx ========'
EXPLAIN (ANALYZE, BUFFERS) SELECT order_id, order_date, total_amount
FROM orders WHERE customer_id = :cust ORDER BY order_date DESC;
BEGIN;
DROP INDEX orders_customer_date_idx;
\echo ''
\echo '======== WITHOUT orders_customer_date_idx (dropped inside a transaction, rolled back after) ========'
EXPLAIN (ANALYZE, BUFFERS) SELECT order_id, order_date, total_amount
FROM orders WHERE customer_id = :cust ORDER BY order_date DESC;
ROLLBACK;
\o

-- ---------------------------------------------------------------------
-- 7. One product's stock history: WITH vs WITHOUT inventory_log_product_date_idx
-- ---------------------------------------------------------------------
SELECT * FROM inventory_log WHERE product_id = :prod \g /dev/null
\o benchmarks/plans/07_product_history_with_without_index.txt
\echo '-- Plan pair: one product''s stock movements, in time order (sql/07).'
\echo '-- WITH the index: Index Scan on (product_id, created_at), already in order.'
\echo '-- WITHOUT it: Seq Scan over all 282,352 movements, then a Sort.'
\echo ''
\echo '======== WITH inventory_log_product_date_idx ========'
EXPLAIN (ANALYZE, BUFFERS) SELECT log_id, change_qty, reason, created_at
FROM inventory_log WHERE product_id = :prod ORDER BY created_at;
BEGIN;
DROP INDEX inventory_log_product_date_idx;
\echo ''
\echo '======== WITHOUT inventory_log_product_date_idx (dropped inside a transaction, rolled back after) ========'
EXPLAIN (ANALYZE, BUFFERS) SELECT log_id, change_qty, reason, created_at
FROM inventory_log WHERE product_id = :prod ORDER BY created_at;
ROLLBACK;
\o

-- ---------------------------------------------------------------------
-- 8. An order's lines: WITH vs WITHOUT order_items_order_idx
--    (the lookup every foreign-key check and order view does)
-- ---------------------------------------------------------------------
SELECT max(order_id) AS ord FROM orders WHERE order_date <= (SELECT as_of FROM report_settings) \gset
SELECT * FROM order_items WHERE order_id = :ord \g /dev/null
SELECT count(*) FROM order_items \g /dev/null
\o benchmarks/plans/08_order_lines_with_without_index.txt
\echo '-- Plan pair: the lines of one order (sql/07).'
\echo '-- WITH the index: Index Scan. WITHOUT it: Seq Scan over all 336,559 lines.'
\echo '-- This is also what each order deletion checks through the foreign key.'
\echo ''
\echo '======== WITH order_items_order_idx ========'
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM order_items WHERE order_id = :ord;
BEGIN;
DROP INDEX order_items_order_idx;
\echo ''
\echo '======== WITHOUT order_items_order_idx (dropped inside a transaction, rolled back after) ========'
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM order_items WHERE order_id = :ord;
ROLLBACK;
\o

\echo 'Plans written to benchmarks/plans/ (8 files). All indexes are still in place.'