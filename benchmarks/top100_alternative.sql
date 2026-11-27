-- =====================================================================
-- benchmarks/top100_alternative.sql
-- Tests a faster way to read the top 100, WITHOUT changing the delivered
-- solution. Background: measurement_report.md, "Finding from reading the
-- plans" (plan 01 shows top_100_customers does not use the rank index).
--
-- The alternative is a TEMPORARY view: it exists only in this session and
-- disappears when the script ends. Nothing in the database is changed.
--
-- Run after a fresh load, from the kloudkart-lab folder:
--   docker exec -w /lab -i kloudkart psql -U postgres -d lab -f benchmarks/top100_alternative.sql
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off

-- The alternative: read the ranked rows straight from the stored report,
-- for the report's last month only (each customer has one row per month,
-- all carrying the same rank and totals), so the rank index can be used.
CREATE TEMP VIEW top_100_by_rank AS
SELECT r.spend_rank, r.customer_id, c.full_name, c.city,
       r.total_spent, r.order_count, r.spend_last_12_months
FROM   monday_report r
JOIN   customers c USING (customer_id)
WHERE  r.spend_rank <= 100
  AND  r.month = (SELECT date_trunc('month', as_of)::date FROM report_settings)
ORDER  BY r.spend_rank, r.customer_id;

-- 1. Same answer? Rows in one and not the other, both directions. Expect 0 and 0.
\echo '=== 1. Same result as the delivered view? (expect 0 and 0) ==='
SELECT (SELECT count(*) FROM (SELECT * FROM top_100_customers EXCEPT SELECT * FROM top_100_by_rank) a) AS only_in_delivered,
       (SELECT count(*) FROM (SELECT * FROM top_100_by_rank EXCEPT SELECT * FROM top_100_customers) b) AS only_in_alternative,
       (SELECT count(*) FROM top_100_customers) AS delivered_rows,
       (SELECT count(*) FROM top_100_by_rank)   AS alternative_rows;

-- 2. Does it use the rank index? (look for monday_report_rank)
\echo '=== 2. Plan of the alternative (look for monday_report_rank) ==='
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM top_100_by_rank;

-- 3. Timings: 5 warm runs each, full query time as psql measures it.
\echo '=== 3. Delivered view, 5 runs ==='
\timing on
SELECT * FROM top_100_customers \g /dev/null
SELECT * FROM top_100_customers \g /dev/null
SELECT * FROM top_100_customers \g /dev/null
SELECT * FROM top_100_customers \g /dev/null
SELECT * FROM top_100_customers \g /dev/null
\echo '=== 3. Alternative, 5 runs ==='
SELECT * FROM top_100_by_rank \g /dev/null
SELECT * FROM top_100_by_rank \g /dev/null
SELECT * FROM top_100_by_rank \g /dev/null
SELECT * FROM top_100_by_rank \g /dev/null
SELECT * FROM top_100_by_rank \g /dev/null
\timing off
\echo 'Done. The temporary view is dropped automatically; the delivered solution is unchanged.'