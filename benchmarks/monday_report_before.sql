-- =====================================================================
-- benchmarks/monday_report_before.sql
-- The "BEFORE" for the measurement report: the Monday report written the
-- common slow way -- one small query (a correlated subquery) per figure,
-- per customer, straight on the raw tables with no indexes.
-- Adwoa's real query was not supplied; this is a representative stand-in
-- (stated as such in measurement_report.md).
--
-- NOT part of run_all.sql (on all 40,420 customers it takes far too long).
-- It runs on the first :sample customers; the full time is estimated as
--   (time for sample) x (40,420 / sample).
-- Run:  docker exec -w /lab -i kloudkart psql -U postgres -d lab -v sample=200 -f benchmarks/monday_report_before.sql
-- =====================================================================
\timing on
\set as_of '2026-08-31 23:59:59'

SELECT c.customer_id,
       -- total spent, order count, last-12-month spend: one subquery each
       (SELECT sum(o.total_amount) FROM orders o
         WHERE o.customer_id = c.customer_id
           AND lower(trim(o.status)) IN ('completed','complete','shipped')
           AND o.order_date <= :'as_of')                                  AS total_spent,
       (SELECT count(*) FROM orders o
         WHERE o.customer_id = c.customer_id
           AND lower(trim(o.status)) IN ('completed','complete','shipped')
           AND o.order_date <= :'as_of')                                  AS order_count,
       -- one subquery per month, 12 months
       (SELECT sum(o.total_amount) FROM orders o WHERE o.customer_id = c.customer_id AND lower(trim(o.status)) IN ('completed','complete','shipped') AND date_trunc('month', o.order_date) = date_trunc('month', :'as_of'::timestamp) - interval '11 months') AS m01,
       (SELECT sum(o.total_amount) FROM orders o WHERE o.customer_id = c.customer_id AND lower(trim(o.status)) IN ('completed','complete','shipped') AND date_trunc('month', o.order_date) = date_trunc('month', :'as_of'::timestamp) - interval '10 months') AS m02,
       (SELECT sum(o.total_amount) FROM orders o WHERE o.customer_id = c.customer_id AND lower(trim(o.status)) IN ('completed','complete','shipped') AND date_trunc('month', o.order_date) = date_trunc('month', :'as_of'::timestamp) - interval '9 months')  AS m03,
       (SELECT sum(o.total_amount) FROM orders o WHERE o.customer_id = c.customer_id AND lower(trim(o.status)) IN ('completed','complete','shipped') AND date_trunc('month', o.order_date) = date_trunc('month', :'as_of'::timestamp) - interval '8 months')  AS m04,
       (SELECT sum(o.total_amount) FROM orders o WHERE o.customer_id = c.customer_id AND lower(trim(o.status)) IN ('completed','complete','shipped') AND date_trunc('month', o.order_date) = date_trunc('month', :'as_of'::timestamp) - interval '7 months')  AS m05,
       (SELECT sum(o.total_amount) FROM orders o WHERE o.customer_id = c.customer_id AND lower(trim(o.status)) IN ('completed','complete','shipped') AND date_trunc('month', o.order_date) = date_trunc('month', :'as_of'::timestamp) - interval '6 months')  AS m06,
       (SELECT sum(o.total_amount) FROM orders o WHERE o.customer_id = c.customer_id AND lower(trim(o.status)) IN ('completed','complete','shipped') AND date_trunc('month', o.order_date) = date_trunc('month', :'as_of'::timestamp) - interval '5 months')  AS m07,
       (SELECT sum(o.total_amount) FROM orders o WHERE o.customer_id = c.customer_id AND lower(trim(o.status)) IN ('completed','complete','shipped') AND date_trunc('month', o.order_date) = date_trunc('month', :'as_of'::timestamp) - interval '4 months')  AS m08,
       (SELECT sum(o.total_amount) FROM orders o WHERE o.customer_id = c.customer_id AND lower(trim(o.status)) IN ('completed','complete','shipped') AND date_trunc('month', o.order_date) = date_trunc('month', :'as_of'::timestamp) - interval '3 months')  AS m09,
       (SELECT sum(o.total_amount) FROM orders o WHERE o.customer_id = c.customer_id AND lower(trim(o.status)) IN ('completed','complete','shipped') AND date_trunc('month', o.order_date) = date_trunc('month', :'as_of'::timestamp) - interval '2 months')  AS m10,
       (SELECT sum(o.total_amount) FROM orders o WHERE o.customer_id = c.customer_id AND lower(trim(o.status)) IN ('completed','complete','shipped') AND date_trunc('month', o.order_date) = date_trunc('month', :'as_of'::timestamp) - interval '1 month')   AS m11,
       (SELECT sum(o.total_amount) FROM orders o WHERE o.customer_id = c.customer_id AND lower(trim(o.status)) IN ('completed','complete','shipped') AND date_trunc('month', o.order_date) = date_trunc('month', :'as_of'::timestamp))                         AS m12,
       -- rank: count how many customers spent more (another query per customer)
       1 + (SELECT count(*) FROM (
               SELECT o2.customer_id FROM orders o2
               WHERE lower(trim(o2.status)) IN ('completed','complete','shipped') AND o2.order_date <= :'as_of'
               GROUP BY o2.customer_id
               HAVING sum(o2.total_amount) > (SELECT coalesce(sum(o.total_amount), 0) FROM orders o
                                              WHERE o.customer_id = c.customer_id
                                                AND lower(trim(o.status)) IN ('completed','complete','shipped')
                                                AND o.order_date <= :'as_of')) x)  AS spend_rank
FROM   customers c
ORDER  BY c.customer_id
LIMIT  :sample;