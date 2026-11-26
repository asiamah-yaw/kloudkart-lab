-- =====================================================================
-- 07_indexes_and_stats.sql
-- Phase 6: make it fast, and keep only what was measured to help.
-- Every index here has a before/after figure in measurement_report.md.
-- An index makes reads faster and every write slightly slower, and costs
-- disk, so an index nothing uses is pure cost. One candidate
-- (products.category_id) was tested, gave no gain, and was NOT added.
--
-- CONCURRENTLY: builds the index without blocking writes. On the live
-- server a plain CREATE INDEX locks the table against new rows until it
-- finishes -- the shop would stop taking orders. CONCURRENTLY is slower
-- and, if it fails, leaves an INVALID index that must be dropped and
-- rebuilt. (It cannot run inside a transaction block; psql runs each
-- statement on its own, so it works in this script.)
-- =====================================================================

-- 1. order lines by order.
--    Needed by the foreign key order_items -> orders: every deleted order
--    must check no line still points at it. Without this index, deleting
--    2,000 orders took about 28 s (a full scan of 336,559 lines per
--    order); with it, about 15 ms. Also used whenever lines are joined
--    to their order.
CREATE INDEX CONCURRENTLY IF NOT EXISTS order_items_order_idx
    ON order_items (order_id);

-- 2. order lines by product.
--    Supports the foreign key order_items -> products (deleting a product
--    checks no line uses it) and any "sales per product" question.
CREATE INDEX CONCURRENTLY IF NOT EXISTS order_items_product_idx
    ON order_items (product_id);

-- 3. a customer's orders, in date order.
--    Customer first (looked up with =), then date (a range or sort), so
--    one index serves "this customer", "this customer this month" and
--    "this customer's orders in order". One customer's orders: about
--    7 ms -> 1.2 ms. Also supports the foreign key orders -> customers.
CREATE INDEX CONCURRENTLY IF NOT EXISTS orders_customer_date_idx
    ON orders (customer_id, order_date);

-- 4. a product's stock history, in date order (the auditor's question:
--    "walk me through every movement of this product").
--    About 11 ms -> 2 ms. Also supports the foreign key
--    inventory_log -> products and the stock reconciliation check.
CREATE INDEX CONCURRENTLY IF NOT EXISTS inventory_log_product_date_idx
    ON inventory_log (product_id, created_at);

-- 5. Fresh statistics for every table, including the ones this solution
--    created (order_status_map, report_settings, stock_settings).
--    load.sql ran ANALYZE before those tables existed, and PostgreSQL's
--    automatic ANALYZE only starts after about 50 changed rows -- so a
--    one-row settings table would NEVER be analysed on its own. Without
--    statistics the planner guessed badly: the low-stock summary took
--    about 790 ms; after ANALYZE alone, about 6 ms.
ANALYZE;