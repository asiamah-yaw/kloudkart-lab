-- =====================================================================
-- 01_integrity_checks.sql
-- Phase 1: data diagnosis for Kloud Kart.
--
-- What this file does:
--   Measures how much bad data got in through each rule the schema is
--   MISSING (see the comments in schema.sql). One row per check, with a
--   count, so the whole diagnosis can be re-run on any fresh load.
--
-- Safety: READ ONLY. It changes nothing, so it is safe to run any time,
-- including inside run_all.sql.
--
-- Method (Learning Path, "What this schema does not have"):
--   A. Is every relationship enforced?   -> orphans      (anti-joins)
--   B. Is every identity enforced?       -> duplicates   (GROUP BY ... HAVING)
--   C. Is every value range enforced?    -> impossible values (WHERE)
--   D. Is every type/format right?       -> dates, free text, totals
-- A count here is a MEASUREMENT, not yet a finding. The cost to the
-- business is written up in data_findings.md.
-- =====================================================================

-- ASSUMPTION (to confirm in data_findings.md): the extract was taken at the
-- end of 31 Aug 2026. Normal trading (about 1,000 orders a day) stops
-- there; anything dated later cannot have happened yet when the extract
-- was taken. Using a fixed date (not now()) keeps the result the same no
-- matter what day the script is run on.
\set extract_end '2026-08-31 23:59:59'

\echo '=== Integrity check summary (one row per check) ==='

WITH RECURSIVE
-- Walk UP the category tree from every category. If a walk comes back
-- to a category it has already visited, that is a loop (cycle).
-- CYCLE ... SET is_cycle marks the row where the loop closes and stops
-- following it, so this query always finishes even if loops exist.
cat_walk (start_id, cur_id, parent_id) AS (
    SELECT category_id, category_id, parent_id
    FROM   categories
  UNION ALL
    SELECT w.start_id, c.category_id, c.parent_id
    FROM   cat_walk  w
    JOIN   categories c ON c.category_id = w.parent_id
) CYCLE cur_id SET is_cycle USING walk_path,

-- Total of each order's lines, used to check orders.total_amount.
item_totals AS (
    SELECT order_id, sum(quantity * unit_price) AS items_total
    FROM   order_items
    GROUP  BY order_id
),

-- Net stock movement per product according to the inventory log.
log_totals AS (
    SELECT product_id, sum(change_qty) AS net_movement
    FROM   inventory_log
    GROUP  BY product_id
)

SELECT check_id, area, check_name, problem_rows
FROM (
    -- ---------------- A. Relationships (orphans) ---------------------
    SELECT 'A1' AS check_id, 'relationship' AS area,
           'products -> category that does not exist' AS check_name,
           (SELECT count(*) FROM products p
             LEFT JOIN categories c ON c.category_id = p.category_id
             WHERE p.category_id IS NOT NULL AND c.category_id IS NULL) AS problem_rows
    UNION ALL
    SELECT 'A2', 'relationship', 'products with no category (NULL)',
           (SELECT count(*) FROM products WHERE category_id IS NULL)
    UNION ALL
    SELECT 'A3', 'relationship', 'categories -> parent that does not exist',
           (SELECT count(*) FROM categories c
             LEFT JOIN categories p ON p.category_id = c.parent_id
             WHERE c.parent_id IS NOT NULL AND p.category_id IS NULL)
    UNION ALL
    SELECT 'A4', 'relationship', 'categories caught in a parent loop (cycle)',
           (SELECT count(DISTINCT start_id) FROM cat_walk
             WHERE is_cycle AND cur_id = start_id)
    UNION ALL
    SELECT 'A5', 'relationship', 'orders -> customer that does not exist',
           (SELECT count(*) FROM orders o
             LEFT JOIN customers c ON c.customer_id = o.customer_id
             WHERE o.customer_id IS NOT NULL AND c.customer_id IS NULL)
    UNION ALL
    SELECT 'A6', 'relationship', 'orders with no customer (NULL)',
           (SELECT count(*) FROM orders WHERE customer_id IS NULL)
    UNION ALL
    SELECT 'A7', 'relationship', 'order_items -> order that does not exist',
           (SELECT count(*) FROM order_items oi
             LEFT JOIN orders o ON o.order_id = oi.order_id
             WHERE o.order_id IS NULL)
    UNION ALL
    SELECT 'A8', 'relationship', 'order_items -> product that does not exist',
           (SELECT count(*) FROM order_items oi
             LEFT JOIN products p ON p.product_id = oi.product_id
             WHERE oi.product_id IS NOT NULL AND p.product_id IS NULL)
    UNION ALL
    SELECT 'A9', 'relationship', 'inventory_log -> product that does not exist',
           (SELECT count(*) FROM inventory_log l
             LEFT JOIN products p ON p.product_id = l.product_id
             WHERE l.product_id IS NOT NULL AND p.product_id IS NULL)
    UNION ALL
    SELECT 'A10', 'relationship', 'orders with no order_items at all',
           (SELECT count(*) FROM orders o
             WHERE NOT EXISTS (SELECT 1 FROM order_items oi WHERE oi.order_id = o.order_id))

    -- ---------------- B. Identity (duplicates) -----------------------
    UNION ALL
    SELECT 'B1', 'identity', 'email addresses used by more than one customer (groups)',
           (SELECT count(*) FROM (
                SELECT lower(trim(email)) FROM customers
                WHERE  nullif(trim(email), '') IS NOT NULL
                GROUP  BY lower(trim(email)) HAVING count(*) > 1) d)
    UNION ALL
    SELECT 'B2', 'identity', 'customer rows sharing an email with another row',
           (SELECT coalesce(sum(n), 0) FROM (
                SELECT count(*) AS n FROM customers
                WHERE  nullif(trim(email), '') IS NOT NULL
                GROUP  BY lower(trim(email)) HAVING count(*) > 1) d)
    UNION ALL
    SELECT 'B3', 'identity', 'email groups that only match after ignoring case/spaces',
           (SELECT count(*) FROM (
                SELECT 1 FROM customers WHERE nullif(trim(email), '') IS NOT NULL
                GROUP  BY lower(trim(email)) HAVING count(*) > 1) n)
         - (SELECT count(*) FROM (
                SELECT 1 FROM customers WHERE nullif(trim(email), '') IS NOT NULL
                GROUP  BY email HAVING count(*) > 1) r)
    UNION ALL
    SELECT 'B4', 'identity', 'customers with no email (NULL or blank)',
           (SELECT count(*) FROM customers WHERE nullif(trim(email), '') IS NULL)
    UNION ALL
    SELECT 'B5', 'identity', 'same product appears on more than one line of one order',
           (SELECT count(*) FROM (
                SELECT order_id, product_id FROM order_items
                GROUP  BY order_id, product_id HAVING count(*) > 1) d)

    -- ---------------- C. Value ranges (impossible values) -------------
    UNION ALL
    SELECT 'C1', 'value', 'products with negative stock_quantity',
           (SELECT count(*) FROM products WHERE stock_quantity < 0)
    UNION ALL
    SELECT 'C2', 'value', 'products with NULL stock_quantity',
           (SELECT count(*) FROM products WHERE stock_quantity IS NULL)
    UNION ALL
    SELECT 'C3', 'value', 'products with price NULL, zero or negative',
           (SELECT count(*) FROM products WHERE price IS NULL OR price <= 0)
    UNION ALL
    SELECT 'C4', 'value', 'order_items with quantity NULL, zero or negative',
           (SELECT count(*) FROM order_items WHERE quantity IS NULL OR quantity <= 0)
    UNION ALL
    SELECT 'C5', 'value', 'order_items with NULL unit_price',
           (SELECT count(*) FROM order_items WHERE unit_price IS NULL)
    UNION ALL
    SELECT 'C6', 'value', 'order_items with unit_price of zero or less',
           (SELECT count(*) FROM order_items WHERE unit_price <= 0)
    UNION ALL
    SELECT 'C7', 'value', 'orders with total_amount NULL, zero or negative',
           (SELECT count(*) FROM orders WHERE total_amount IS NULL OR total_amount <= 0)
    UNION ALL
    SELECT 'C8', 'value', 'inventory_log rows with change_qty of zero or NULL',
           (SELECT count(*) FROM inventory_log WHERE change_qty IS NULL OR change_qty = 0)

    -- ---------------- D. Consistency, dates and free text ------------
    UNION ALL
    SELECT 'D1', 'consistency', 'orders whose total_amount <> sum of their lines (by > 0.01)',
           (SELECT count(*) FROM orders o
             JOIN item_totals t ON t.order_id = o.order_id
             WHERE abs(o.total_amount - t.items_total) > 0.01)
    UNION ALL
    SELECT 'D2', 'consistency', 'products whose stock_quantity <> net movement in inventory_log',
           (SELECT count(*) FROM products p
             LEFT JOIN log_totals l ON l.product_id = p.product_id
             WHERE p.stock_quantity IS DISTINCT FROM coalesce(l.net_movement, 0))
    UNION ALL
    SELECT 'D3', 'date', 'orders dated after the extract end (31 Aug 2026)',
           (SELECT count(*) FROM orders WHERE order_date > :'extract_end')
    UNION ALL
    SELECT 'D4', 'date', 'orders with NULL order_date',
           (SELECT count(*) FROM orders WHERE order_date IS NULL)
    UNION ALL
    SELECT 'D5', 'date', 'orders placed before the customer registered',
           (SELECT count(*) FROM orders o
             JOIN customers c ON c.customer_id = o.customer_id
             WHERE o.order_date < c.registered_at)
    UNION ALL
    SELECT 'D6', 'date', 'inventory_log rows dated after the extract end',
           (SELECT count(*) FROM inventory_log WHERE created_at > :'extract_end')
    UNION ALL
    SELECT 'D7', 'free text', 'distinct order status spellings (raw)',
           (SELECT count(DISTINCT status) FROM orders)
    UNION ALL
    SELECT 'D8', 'free text', 'distinct order statuses after lower()/trim()',
           (SELECT count(DISTINCT lower(trim(status))) FROM orders)
) checks
ORDER BY left(check_id, 1), substr(check_id, 2)::int;

-- ---------------------------------------------------------------------
-- Profiles: not checks, but context needed to judge the checks above.
-- They show shapes and spellings only, never customer personal data.
-- ---------------------------------------------------------------------
\echo '=== Profile: order status values as stored ==='
SELECT status, count(*) AS orders
FROM   orders
GROUP  BY status
ORDER  BY orders DESC;

\echo '=== Profile: order statuses grouped by meaning (lower/trim, plus spelling variants) ==='
SELECT CASE lower(trim(status))
           WHEN 'complete' THEN 'completed'
           WHEN 'canceled' THEN 'cancelled'
           ELSE lower(trim(status))
       END                       AS meaning,
       count(DISTINCT status)    AS spellings,
       count(*)                  AS orders
FROM   orders
GROUP  BY 1
ORDER  BY orders DESC;

\echo '=== Profile: orders per month (spot where the extract really ends) ==='
SELECT to_char(date_trunc('month', order_date), 'YYYY-MM') AS month, count(*) AS orders
FROM   orders
GROUP  BY 1
ORDER  BY 1;

\echo '=== Profile: inventory_log reason values, with sign of change_qty ==='
SELECT reason,
       count(*)                                   AS rows,
       count(*) FILTER (WHERE change_qty < 0)     AS outward_rows,
       count(*) FILTER (WHERE change_qty > 0)     AS inward_rows
FROM   inventory_log
GROUP  BY reason
ORDER  BY rows DESC;

\echo '=== Profile: date ranges ==='
SELECT 'orders.order_date'        AS column_name, min(order_date)    AS earliest, max(order_date)    AS latest FROM orders
UNION ALL
SELECT 'inventory_log.created_at', min(created_at), max(created_at) FROM inventory_log
UNION ALL
SELECT 'customers.registered_at',  min(registered_at), max(registered_at) FROM customers
UNION ALL
SELECT 'products.created_at',      min(created_at), max(created_at) FROM products;
