-- =====================================================================
-- 05_monday_report.sql
-- Nana's 2nd ask: a fast Monday report. For every customer: total spent,
-- order count, monthly spend for the trailing 12 months, a running
-- per-customer total (Adwoa keeps this by hand today) and a top-100
-- ranking -- in seconds on an ordinary laptop.
--
-- Shape of the solution:
--   report_settings      one row: the date the report is "as of"
--   spend_orders         ONE definition of "money spent", used everywhere
--   monday_report        the report, pre-computed (materialized view):
--                        one row per customer per month, last 12 months
--   monday_report_summary  one row per customer (totals + rank)
--   top_100_customers    the ranking Nana negotiates with
--   refresh_monday_report()  rebuilds the report without blocking readers
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. The "as of" date. The 12-month window ends here.
-- For this extract: 31 Aug 2026 (finding F-06: activity stops there and
-- 24 stray orders are dated later). In normal use, set it to the end of
-- yesterday before the Monday refresh. A table, not a hard-coded date,
-- so changing it needs no code change.
-- ---------------------------------------------------------------------
CREATE TABLE report_settings (
    only_row  boolean   PRIMARY KEY DEFAULT true CHECK (only_row),  -- guarantees exactly one row
    as_of     timestamp NOT NULL
);
INSERT INTO report_settings (as_of) VALUES ('2026-08-31 23:59:59');

COMMENT ON TABLE report_settings IS
    'Single-row settings for the Monday report. as_of = the moment the report is calculated up to.';

-- ---------------------------------------------------------------------
-- 2. ONE definition of "money spent" (findings F-01, F-03, F-04, F-06).
--   * status MEANING, via order_status_map (not the 15 raw spellings)
--   * counts_as_spend = completed or shipped
--   * total_amount is the order value (lines are less reliable, F-03)
--   * nothing after the as_of date
--   * orders whose customer does not exist are KEPT and flagged, so
--     totals still add up (a plain inner join would drop them silently)
-- Every report reads this view, so the rule can never differ between them.
-- ---------------------------------------------------------------------
CREATE VIEW spend_orders AS
SELECT o.order_id,
       o.customer_id,
       o.order_date,
       o.total_amount,
       m.meaning                        AS status_meaning,
       (c.customer_id IS NOT NULL)      AS customer_known
FROM   orders o
JOIN   order_status_map m ON m.status_key = lower(trim(o.status))
LEFT   JOIN customers c   ON c.customer_id = o.customer_id
CROSS  JOIN report_settings s
WHERE  m.counts_as_spend
  AND  o.order_date <= s.as_of;

COMMENT ON VIEW spend_orders IS
    'The single definition of a spend order: status means completed or shipped, dated on or '
    'before report_settings.as_of. Orders for unknown customers are kept, with customer_known = false.';

-- ---------------------------------------------------------------------
-- 3. The report itself, computed in ONE pass over the orders and stored.
-- Why a MATERIALIZED view: the work (about 125,000 orders grouped by
-- customer and month) is done once, at refresh time, not every time
-- Adwoa opens the report. Reading it afterwards takes milliseconds.
-- The cost: figures are as fresh as the last refresh (see section 5).
-- ---------------------------------------------------------------------
CREATE MATERIALIZED VIEW monday_report AS
WITH settings AS (
    SELECT as_of,
           date_trunc('month', as_of)                         AS last_month,
           date_trunc('month', as_of) - interval '11 months'  AS first_month
    FROM   report_settings
),
-- One pass over spend_orders: spend and order count per customer per month.
monthly AS (
    SELECT customer_id,
           bool_and(customer_known)              AS customer_known,
           date_trunc('month', order_date)       AS month,
           sum(total_amount)                     AS month_spend,
           count(*)                              AS month_orders
    FROM   spend_orders
    GROUP  BY customer_id, date_trunc('month', order_date)
),
-- Lifetime totals per customer (all months up to as_of, not just 12),
-- and the ranking. Ranked HERE, on one row per customer: ranking the
-- 12-rows-per-customer grid later would give wrong positions.
-- RANK, not ROW_NUMBER: customers who spent exactly the same share a
-- position, so nobody is cut from the top 100 by an arbitrary tie-break
-- (the list can therefore hold slightly more than 100 if there is a tie
-- at 100th). Unknown customers are not ranked: they are not real people.
lifetime AS (
    SELECT customer_id,
           bool_and(customer_known)  AS customer_known,
           sum(month_spend)          AS total_spent,
           sum(month_orders)         AS order_count
    FROM   monthly
    GROUP  BY customer_id
),
ranked AS (
    SELECT customer_id, total_spent, order_count,
           rank() OVER (ORDER BY total_spent DESC) AS spend_rank
    FROM   lifetime
    WHERE  customer_known
),
-- Everyone who should appear: every registered customer (even with no
-- spend, so "for every customer" holds) plus unknown IDs that have spend.
people AS (
    SELECT c.customer_id, true AS customer_known FROM customers c
    UNION ALL
    SELECT l.customer_id, false FROM lifetime l WHERE NOT l.customer_known
),
-- The 12 report months, oldest first.
months AS (
    SELECT generate_series(s.first_month, s.last_month, interval '1 month') AS month
    FROM   settings s
),
-- Spend BEFORE the window, so the running total starts from the right
-- figure (it is a lifetime running total, not "since the window began").
before_window AS (
    SELECT m.customer_id, sum(m.month_spend) AS spend_before
    FROM   monthly m, settings s
    WHERE  m.month < s.first_month
    GROUP  BY m.customer_id
),
grid AS (   -- every person x every month, 0 where nothing was bought
    SELECT p.customer_id, p.customer_known, mo.month,
           coalesce(mm.month_spend, 0)  AS month_spend,
           coalesce(mm.month_orders, 0) AS month_orders
    FROM   people p
    CROSS  JOIN months mo
    LEFT   JOIN monthly mm ON mm.customer_id = p.customer_id AND mm.month = mo.month
)
SELECT g.customer_id,
       g.customer_known,
       g.month::date                                        AS month,
       g.month_spend,
       g.month_orders,
       -- Running total: lifetime spend up to the end of this month.
       -- ROWS frame: exactly one row per customer per month, so ties
       -- cannot occur; ROWS states that intent explicitly.
       coalesce(b.spend_before, 0)
         + sum(g.month_spend) OVER (PARTITION BY g.customer_id
                                    ORDER BY g.month
                                    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                                            AS running_total,
       sum(g.month_spend) OVER (PARTITION BY g.customer_id) AS spend_last_12_months,
       coalesce(r.total_spent, l.total_spent, 0)            AS total_spent,
       coalesce(r.order_count, l.order_count, 0)            AS order_count,
       r.spend_rank
FROM   grid g
LEFT   JOIN ranked r        ON r.customer_id = g.customer_id
LEFT   JOIN lifetime l      ON l.customer_id = g.customer_id
LEFT   JOIN before_window b ON b.customer_id = g.customer_id;

-- A unique index is what allows REFRESH ... CONCURRENTLY (section 5),
-- and it makes "one customer's 12 months" an instant lookup.
CREATE UNIQUE INDEX monday_report_customer_month ON monday_report (customer_id, month);
-- Makes "the top 100" an instant lookup instead of a scan.
CREATE INDEX monday_report_rank ON monday_report (spend_rank) WHERE spend_rank IS NOT NULL;

COMMENT ON MATERIALIZED VIEW monday_report IS
    'Monday customer-spending report, one row per customer per month for the 12 months ending at '
    'report_settings.as_of. running_total = lifetime spend to the end of that month. '
    'Refresh with SELECT refresh_monday_report();';

-- ---------------------------------------------------------------------
-- 4. Easy views for Adwoa (they read the stored report, so they are fast).
-- ---------------------------------------------------------------------
-- One row per customer.
CREATE VIEW monday_report_summary AS
SELECT DISTINCT ON (customer_id)
       customer_id, customer_known, total_spent, order_count,
       spend_last_12_months, spend_rank
FROM   monday_report
ORDER  BY customer_id, month;

-- The ranking Nana negotiates with, best first, with names.
CREATE VIEW top_100_customers AS
SELECT r.spend_rank, r.customer_id, c.full_name, c.city,
       r.total_spent, r.order_count, r.spend_last_12_months
FROM   monday_report_summary r
JOIN   customers c USING (customer_id)
WHERE  r.spend_rank <= 100
ORDER  BY r.spend_rank, r.customer_id;

-- ---------------------------------------------------------------------
-- 5. Refreshing.
-- CONCURRENTLY: people can keep reading the old figures while the new
-- ones are calculated, instead of being locked out (a plain refresh
-- blocks every reader until it finishes). It needs the unique index
-- above, and takes a little longer overall. Worth it: the report is read
-- by people; the refresh is a background job (e.g. 06:00 every Monday).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION refresh_monday_report() RETURNS void
LANGUAGE sql AS $$
    REFRESH MATERIALIZED VIEW CONCURRENTLY monday_report;
$$;

COMMENT ON FUNCTION refresh_monday_report() IS
    'Rebuilds the Monday report without blocking readers. Run before Adwoa opens it (e.g. Monday 06:00).';

-- ---------------------------------------------------------------------
-- 6. Self-check (runs on every fresh load). Stops the whole run with an
-- error if the report does not reconcile, instead of shipping a wrong
-- number quietly.
--   a) every unit of spend appears in the report exactly once
--   b) every registered customer appears (the brief says "for every customer")
--   c) each customer has exactly 12 months
--   d) the running total in the last month equals lifetime spend
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_spend_orders  numeric := (SELECT coalesce(sum(total_amount), 0) FROM spend_orders);
    v_report        numeric := (SELECT coalesce(sum(total_spent), 0) FROM monday_report_summary);
    v_customers     bigint  := (SELECT count(*) FROM customers);
    v_in_report     bigint  := (SELECT count(*) FROM monday_report_summary WHERE customer_known);
    v_bad_months    bigint  := (SELECT count(*) FROM (SELECT customer_id FROM monday_report
                                                      GROUP BY customer_id HAVING count(*) <> 12) x);
    v_bad_running   bigint  := (SELECT count(*) FROM monday_report r
                                WHERE r.month = (SELECT max(month) FROM monday_report)
                                  AND r.running_total <> r.total_spent);
BEGIN
    IF v_spend_orders <> v_report THEN
        RAISE EXCEPTION 'Monday report does not reconcile: spend_orders % vs report %', v_spend_orders, v_report;
    END IF;
    IF v_customers <> v_in_report THEN
        RAISE EXCEPTION 'Monday report is missing customers: % registered, % in report', v_customers, v_in_report;
    END IF;
    IF v_bad_months > 0 THEN
        RAISE EXCEPTION '% customers do not have exactly 12 months in the report', v_bad_months;
    END IF;
    IF v_bad_running > 0 THEN
        RAISE EXCEPTION '% customers: running total in the last month <> lifetime spend', v_bad_running;
    END IF;
    RAISE NOTICE 'Monday report reconciles: % of spend, % customers, 12 months each.', v_report, v_in_report;
END $$;