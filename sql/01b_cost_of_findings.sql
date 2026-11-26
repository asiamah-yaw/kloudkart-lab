-- =====================================================================
-- 01b_cost_of_findings.sql
-- Phase 1, part 2: turn each integrity count into a BUSINESS cost.
-- "A count is not a finding": each query answers which number Nana or
-- Adwoa uses that this fault changes, and by how much. READ ONLY.
--
-- Assumptions (stated in data_findings.md):
--   * Extract end = 31 Aug 2026 (normal trading stops there).
--   * Money "spent" = orders whose status MEANS completed or shipped.
--   * orders.total_amount is the trusted order value.
-- =====================================================================
\set extract_end '2026-08-31 23:59:59'


\echo '=== Cost 1: status spellings, what an exact-match filter would miss ==='
SELECT count(*)                                              AS completed_orders_all_spellings,
       count(*) FILTER (WHERE status = 'completed')          AS caught_by_status_eq_completed,
       count(*) FILTER (WHERE status <> 'completed')         AS silently_missed,
       sum(total_amount) FILTER (WHERE status <> 'completed') AS value_missed
FROM   orders
WHERE  lower(trim(status)) IN ('completed', 'complete');

\echo '=== Cost 2: orders whose customer does not exist (dropped by a normal join) ==='
SELECT count(*)                                  AS orphan_orders,
       count(*) FILTER (WHERE lower(trim(o.status)) IN ('completed','complete','shipped'))
                                                 AS orphan_spend_orders,
       sum(o.total_amount) FILTER (WHERE lower(trim(o.status)) IN ('completed','complete','shipped'))
                                                 AS orphan_spend_value,
       count(DISTINCT o.customer_id)             AS missing_customer_ids
FROM   orders o
LEFT   JOIN customers c ON c.customer_id = o.customer_id
WHERE  c.customer_id IS NULL;

\echo '=== Cost 3: duplicate emails, customer count and the top-100 list ==='
WITH spend AS (
    SELECT o.customer_id, sum(o.total_amount) AS spent
    FROM   orders o
    WHERE  lower(trim(o.status)) IN ('completed','complete','shipped')
      AND  o.order_date <= :'extract_end'
    GROUP  BY o.customer_id
),
by_row AS (   -- today: one customer row = one customer
    SELECT c.customer_id, s.spent,
           rank() OVER (ORDER BY s.spent DESC) AS rnk
    FROM   customers c JOIN spend s USING (customer_id)
),
by_email AS ( -- if rows sharing an email are one person
    SELECT lower(trim(c.email)) AS person, sum(s.spent) AS spent,
           rank() OVER (ORDER BY sum(s.spent) DESC) AS rnk
    FROM   customers c JOIN spend s USING (customer_id)
    GROUP  BY lower(trim(c.email))
)
SELECT (SELECT count(*) FROM customers)                           AS customer_rows,
       (SELECT count(DISTINCT lower(trim(email))) FROM customers) AS distinct_emails,
       (SELECT count(*) FROM customers)
     - (SELECT count(DISTINCT lower(trim(email))) FROM customers) AS customer_count_overstated_by,
       (SELECT count(*) FROM by_email e WHERE e.rnk <= 100
          AND e.person IN (SELECT lower(trim(email)) FROM customers
                           GROUP BY 1 HAVING count(*) > 1))       AS top100_people_with_split_accounts,
       (SELECT count(*) FROM by_email e WHERE e.rnk <= 100
          AND NOT EXISTS (SELECT 1 FROM by_row r JOIN customers c USING (customer_id)
                          WHERE r.rnk <= 100 AND lower(trim(c.email)) = e.person)) AS top100_people_missing_today;     
\echo '=== Cost 4: negative stock (evidence of overselling) ==='
SELECT count(*)                       AS products_below_zero,
       -sum(stock_quantity)           AS units_sold_that_did_not_exist,
       -sum(stock_quantity * price)   AS value_of_units_oversold
FROM   products
WHERE  stock_quantity < 0;               
\echo '=== Cost 5: stock figure disagrees with the movement history ==='
WITH net AS (
    SELECT product_id, sum(change_qty) AS net
    FROM   inventory_log
    GROUP  BY product_id
)
SELECT count(*)                                                  AS products_drifted,
       sum(abs(p.stock_quantity - coalesce(n.net, 0)))           AS units_unexplained,
       sum(abs(p.stock_quantity - coalesce(n.net, 0)) * p.price) AS value_unexplained,
       count(*) FILTER (WHERE p.stock_quantity > coalesce(n.net, 0)) AS system_shows_more_than_history,
       count(*) FILTER (WHERE p.stock_quantity < coalesce(n.net, 0)) AS system_shows_less_than_history
FROM   products p
LEFT   JOIN net n USING (product_id)
WHERE  p.stock_quantity IS DISTINCT FROM coalesce(n.net, 0);
\echo '=== Cost 6: order total vs its lines, why they differ ==='
WITH t AS (
    SELECT order_id,
           sum(quantity * unit_price)                     AS lines_total,
           count(*) > count(DISTINCT product_id)          AS has_duplicate_line,
           bool_or(unit_price IS NULL OR unit_price = 0)  AS has_missing_price
    FROM   order_items
    GROUP  BY order_id
),
m AS (
    SELECT o.order_id, o.total_amount, t.*
    FROM   orders o JOIN t USING (order_id)
    WHERE  t.lines_total IS NULL OR abs(o.total_amount - t.lines_total) > 0.01
)
SELECT count(*)                                                             AS mismatched_orders,
       count(*) FILTER (WHERE has_duplicate_line)                           AS explained_by_duplicate_line,
       count(*) FILTER (WHERE has_missing_price AND NOT has_duplicate_line) AS explained_by_missing_price,
       count(*) FILTER (WHERE NOT has_duplicate_line AND NOT has_missing_price) AS exact_percentage_gap,
       sum(abs(total_amount - lines_total))                                 AS total_gap_value
FROM   m;
\echo '=== Cost 6b: the unexplained gaps are exact percentages ==='
WITH t AS (
    SELECT order_id, sum(quantity * unit_price) AS s,
           count(*) AS n, count(DISTINCT product_id) AS np,
           bool_or(unit_price IS NULL OR unit_price = 0) AS z
    FROM   order_items GROUP BY order_id
)
SELECT round(o.total_amount / t.s, 2) AS total_divided_by_lines, count(*) AS orders
FROM   orders o JOIN t USING (order_id)
WHERE  abs(o.total_amount - t.s) > 0.01 AND t.n = t.np AND NOT t.z
GROUP  BY 1
HAVING count(*) > 10
ORDER  BY 2 DESC;
\echo '=== Cost 7: orders dated after the extract end ==='
SELECT count(*) AS future_orders, sum(total_amount) AS future_value,
       min(order_date) AS first, max(order_date) AS last
FROM   orders
WHERE  order_date > :'extract_end';
\echo '=== Cost 8: order lines whose order does not exist ==='
SELECT count(*) AS orphan_lines, count(DISTINCT order_id) AS missing_order_ids,
       sum(quantity) AS units, sum(quantity * unit_price) AS line_value
FROM   order_items oi
WHERE  NOT EXISTS (SELECT 1 FROM orders o WHERE o.order_id = oi.order_id);
\echo '=== Cost 9: stock movements for products that do not exist ==='
SELECT count(*) AS orphan_movements, count(DISTINCT product_id) AS missing_product_ids,
       sum(change_qty) AS net_units
FROM   inventory_log l
WHERE  NOT EXISTS (SELECT 1 FROM products p WHERE p.product_id = l.product_id);
\echo '=== Cost 10: broken category tree, products cut off from the rollup ==='
WITH RECURSIVE up (start_id, cur_id, parent_id) AS (
    SELECT category_id, category_id, parent_id FROM categories
  UNION ALL
    SELECT u.start_id, c.category_id, c.parent_id
    FROM   up u JOIN categories c ON c.category_id = u.parent_id
) CYCLE cur_id SET is_cycle USING path,
reaches_root AS (
    SELECT DISTINCT start_id FROM up WHERE parent_id IS NULL AND NOT is_cycle
)
SELECT (SELECT count(*) FROM categories)                                AS categories,
       (SELECT count(*) FROM categories
         WHERE category_id NOT IN (SELECT start_id FROM reaches_root))  AS categories_not_reaching_a_root,
       (SELECT count(*) FROM products p
         WHERE p.category_id IS NOT NULL
           AND p.category_id NOT IN (SELECT start_id FROM reaches_root)) AS products_in_cut_off_categories,
       (SELECT count(*) FROM products WHERE category_id IS NULL)        AS products_with_no_category;
\echo '=== Cost 11: duplicate order lines, effect on units-sold figures ==='
SELECT count(*) AS duplicate_pairs,
       sum(extra_units) AS extra_units_if_counted_from_lines
FROM (
    SELECT order_id, product_id, sum(quantity) - max(quantity) AS extra_units
    FROM   order_items
    GROUP  BY 1, 2
    HAVING count(*) > 1
) d;