-- =====================================================================
-- 09_stock_health.sql   (improvement beyond the brief)
--
-- The new part: DAYS OF COVER. The low-stock view (06) uses one fixed
-- number for every product, so a slow seller with 5 units looks as
-- urgent as a best-seller with 5 units. stock_health ranks products by
-- how soon they will actually run out at their own recent sales rate.
--
-- The foundation underneath it: a days-of-cover figure is only useful if
-- the stock figure is right. The diagnosis (F-02) found 144 products
-- whose stock figure does not match their own movement history, and 14
-- below zero. So each product is also checked against its history, and
-- untrustworthy figures are listed first.
--
-- Views:
--   stock_health          one row per product, all measures + yes/no flags
--   stock_health_alerts   everything that needs attention, most urgent first
--   stock_count_first     the 20 products to count by hand first
--                         (on this extract: 88.3% of the unexplained value)
--   stock_health_summary  one line per problem type
--
-- Settings live in stock_settings (created in 06), not in the code, so
-- Nana's team changes a number with one UPDATE, not by editing SQL.
-- Run:  SELECT * FROM stock_count_first;   SELECT * FROM stock_health_alerts;
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Two more settings next to the low-stock threshold.
-- ---------------------------------------------------------------------
ALTER TABLE stock_settings
    ADD COLUMN sales_window_days integer NOT NULL DEFAULT 28 CHECK (sales_window_days > 0),
    ADD COLUMN min_days_of_cover integer NOT NULL DEFAULT 7  CHECK (min_days_of_cover > 0);

COMMENT ON COLUMN stock_settings.sales_window_days IS
    'How many days of recent sales set the sales rate for days of cover (default 28).';
COMMENT ON COLUMN stock_settings.min_days_of_cover IS
    'A product selling recently with fewer days of cover than this is flagged (default 7).';

-- ---------------------------------------------------------------------
-- 2. One row per product.
-- ---------------------------------------------------------------------
CREATE VIEW stock_health AS
WITH settings AS (
    -- "Now" = report_settings.as_of (31 Aug 2026 for this extract), NOT
    -- now(). On a static extract now() would find no recent sales at all,
    -- and the result would change with the day it is run.
    SELECT r.as_of, s.sales_window_days, s.min_days_of_cover
    FROM   report_settings r CROSS JOIN stock_settings s
),
history AS (            -- what the movement log says stock should be
    SELECT product_id, sum(change_qty) AS expected_stock
    FROM   inventory_log
    GROUP  BY product_id
),
recent_sales AS (       -- units sold in the window up to as_of
    SELECT l.product_id, -sum(l.change_qty) AS sold_in_window
    FROM   inventory_log l CROSS JOIN settings s
    WHERE  l.reason = 'sale'
      AND  l.created_at >  s.as_of - make_interval(days => s.sales_window_days)
      AND  l.created_at <= s.as_of
    GROUP  BY l.product_id
),
measures AS (
    SELECT p.product_id,
           p.product_name,
           coalesce(t.path, '(no category)')                     AS category_path,
           p.price,
           p.stock_quantity                                      AS stock_figure,
           coalesce(h.expected_stock, 0)                         AS stock_per_history,
           coalesce(r.sold_in_window, 0)                         AS sold_recently,
           s.sales_window_days,
           s.min_days_of_cover
    FROM   products p
    CROSS  JOIN settings s
    LEFT   JOIN history h       ON h.product_id = p.product_id
    LEFT   JOIN recent_sales r  ON r.product_id = p.product_id
    LEFT   JOIN category_tree t ON t.category_id = p.category_id
),
calc AS (
    SELECT m.*,
           stock_figure - stock_per_history                      AS difference,
           -- Size of the gap at SELLING price (no cost price in the data),
           -- so this is the most the gap could be worth, not a loss figure.
           -- abs(): a surplus and a shortfall must not cancel each other out.
           abs(stock_figure - stock_per_history) * price         AS value_unexplained,
           round(sold_recently::numeric / sales_window_days, 2)  AS avg_daily_sales,
           -- NULL when nothing sold recently: no rate to divide by.
           -- Kept unrounded for the comparisons below (rounding 6.96 up to
           -- 7.0 would wrongly drop it out of "under 7 days"); rounded only
           -- for display.
           CASE WHEN sold_recently > 0
                THEN greatest(stock_figure, 0) / (sold_recently::numeric / sales_window_days)
           END                                                   AS cover_exact
    FROM   measures m
)
SELECT product_id, product_name, category_path, stock_figure, stock_per_history,
       difference, value_unexplained, sold_recently, avg_daily_sales,
       round(cover_exact, 1)                                     AS days_of_cover,
       -- Yes/no flags: a product can have several problems at once.
       (stock_figure < 0)                                        AS is_below_zero,
       (stock_figure <> stock_per_history)                       AS figure_mismatch,
       (sold_recently > 0 AND stock_figure <= 0)                 AS out_of_stock_selling,
       (sold_recently > 0 AND stock_figure > 0
            AND cover_exact < min_days_of_cover)                 AS low_cover,
       -- One label for sorting: the most serious problem wins.
       CASE
           WHEN stock_figure < 0                                 THEN '1 below zero (oversold)'
           WHEN stock_figure <> stock_per_history                THEN '2 figure does not match history'
           WHEN sold_recently > 0 AND stock_figure = 0           THEN '3 out of stock and selling'
           WHEN sold_recently > 0 AND cover_exact < min_days_of_cover
                                                                 THEN '4 low days of cover'
           ELSE '5 ok'
       END                                                       AS health
FROM   calc;

COMMENT ON VIEW stock_health IS
    'Per product: days of cover at the recent sales rate, and whether the stock figure matches its movement '
    'history. Flags show every problem; health shows the most serious one (1 below zero, 2 figure does not '
    'match history, 3 out of stock and selling, 4 low days of cover, 5 ok). Settings: stock_settings.';

-- ---------------------------------------------------------------------
-- 3. The full action list: most serious first, then the most money at
--    stake, then the fewest days left.
-- ---------------------------------------------------------------------
CREATE VIEW stock_health_alerts AS
SELECT *
FROM   stock_health
WHERE  health <> '5 ok'
ORDER  BY health, value_unexplained DESC, days_of_cover NULLS LAST, product_id;

-- ---------------------------------------------------------------------
-- 4. Where to start: the 20 untrustworthy figures with the most value
--    unexplained. A physical count of these settles most of the money.
-- ---------------------------------------------------------------------
CREATE VIEW stock_count_first AS
SELECT product_id, product_name, category_path, stock_figure, stock_per_history,
       difference, value_unexplained,
       round(100.0 * value_unexplained / sum(value_unexplained) OVER (), 1) AS percent_of_top_20
FROM  (SELECT * FROM stock_health
       WHERE  value_unexplained > 0
       ORDER  BY value_unexplained DESC, product_id
       LIMIT  20) top
ORDER  BY value_unexplained DESC, product_id;

COMMENT ON VIEW stock_count_first IS
    'The 20 products whose stock figure and history disagree by the most value: count these by hand first.';

-- ---------------------------------------------------------------------
-- 5. One line per problem type, for the memo and the Monday meeting.
-- ---------------------------------------------------------------------
CREATE VIEW stock_health_summary AS
SELECT health,
       count(*)               AS products,
       sum(abs(difference))   AS units_unexplained,
       sum(value_unexplained) AS value_unexplained
FROM   stock_health
GROUP  BY health
ORDER  BY health;

-- ---------------------------------------------------------------------
-- 6. Self-check. Stops the load if any of these is false.
--   a. every product is assessed exactly once
--   b. every mismatch the flags find carries a label 1 or 2 (none hidden)
--   c. the label always agrees with the flags
-- ---------------------------------------------------------------------
DO $$
DECLARE
    v_products   bigint := (SELECT count(*) FROM products);
    v_assessed   bigint := (SELECT count(*) FROM stock_health);
    v_distinct   bigint := (SELECT count(DISTINCT product_id) FROM stock_health);
    v_hidden     bigint := (SELECT count(*) FROM stock_health
                            WHERE (is_below_zero OR figure_mismatch)
                              AND health NOT IN ('1 below zero (oversold)', '2 figure does not match history'));
    v_disagree   bigint := (SELECT count(*) FROM stock_health
                            WHERE (health = '1 below zero (oversold)'         AND NOT is_below_zero)
                               OR (health = '2 figure does not match history' AND NOT figure_mismatch)
                               OR (health = '3 out of stock and selling'      AND NOT out_of_stock_selling)
                               OR (health = '4 low days of cover'             AND NOT low_cover)
                               OR (health = '5 ok' AND (is_below_zero OR figure_mismatch
                                                        OR out_of_stock_selling OR low_cover)));
BEGIN
    IF v_assessed <> v_products OR v_distinct <> v_products THEN
        RAISE EXCEPTION 'stock_health does not cover every product exactly once: % products, % rows, % distinct',
                        v_products, v_assessed, v_distinct;
    END IF;
    IF v_hidden > 0 OR v_disagree > 0 THEN
        RAISE EXCEPTION 'stock_health labels and flags disagree: % hidden mismatches, % disagreements',
                        v_hidden, v_disagree;
    END IF;
    RAISE NOTICE 'stock_health: % products assessed, % need attention, % mismatched or below zero.',
                 v_products,
                 (SELECT count(*) FROM stock_health_alerts),
                 (SELECT count(*) FROM stock_health WHERE is_below_zero OR figure_mismatch);
END $$;