-- =====================================================================
-- tests/verification_tests.sql
-- Behaviour tests for the claims in the ADRs and improvement.md.
-- Run AFTER a fresh load (reset.ps1):
--   docker exec -w /lab -i kloudkart psql -U postgres -d lab -f tests/verification_tests.sql
-- Each test prints PASS or FAIL. Everything runs inside one transaction
-- that is ROLLED BACK at the end, so the database is left unchanged.
-- Not part of run_all.sql: these are checks, not part of the solution.
-- =====================================================================
\set ON_ERROR_STOP on
BEGIN;

-- A test product and customer, so no real data is touched.
INSERT INTO products (product_id, product_name, category_id, price, stock_quantity, created_at)
VALUES (990001, 'TEST product', NULL, 100.00, 10, now());

DO $$
DECLARE
    v_cust   bigint := (SELECT min(customer_id) FROM customers);
    v_n      bigint;
    v_stock  int;
    v_reason text;
    v_ok     boolean;
    v_msg    text;
    v_orders_before bigint;
    v_open   bigint;
BEGIN
    -- T1. A new product's starting stock is logged (ADR-004).
    SELECT count(*) INTO v_n FROM inventory_log
    WHERE product_id = 990001 AND reason = 'opening_stock' AND change_qty = 10;
    RAISE NOTICE '% T1  new product logs its opening stock', CASE WHEN v_n = 1 THEN 'PASS' ELSE 'FAIL' END;

    -- T2. A sale through place_order: stock down, order + line + labelled log row (ADR-001, ADR-004).
    SELECT success INTO v_ok FROM place_order(v_cust, 990001, 3);
    SELECT stock_quantity INTO v_stock FROM products WHERE product_id = 990001;
    SELECT count(*) INTO v_n FROM inventory_log
    WHERE product_id = 990001 AND reason = 'sale' AND change_qty = -3;
    RAISE NOTICE '% T2  sale: stock 10 -> 7 and one "sale" row of -3', CASE WHEN v_ok AND v_stock = 7 AND v_n = 1 THEN 'PASS' ELSE 'FAIL' END;

    -- T3. Asking for more than exists is refused cleanly, nothing changes (race_test Test 3 shape).
    SELECT count(*) INTO v_orders_before FROM orders;
    SELECT success, message INTO v_ok, v_msg FROM place_order(v_cust, 990001, 50);
    SELECT stock_quantity INTO v_stock FROM products WHERE product_id = 990001;
    SELECT count(*) INTO v_n FROM orders;
    RAISE NOTICE '% T3  over-order refused with "out of stock", stock and orders unchanged (%)',
        CASE WHEN NOT v_ok AND v_msg ILIKE '%out of stock%' AND v_stock = 7 AND v_n = v_orders_before THEN 'PASS' ELSE 'FAIL' END, v_msg;

    -- T4. A labelled restock updates stock AND writes a "restock" row (ADR-004).
    PERFORM set_config('kloudkart.stock_reason', 'restock', true);
    PERFORM set_config('kloudkart.stock_note',   'supplier delivery (test)', true);
    UPDATE products SET stock_quantity = stock_quantity + 20 WHERE product_id = 990001;
    PERFORM set_config('kloudkart.stock_reason', '', true);
    PERFORM set_config('kloudkart.stock_note',   '', true);
    SELECT stock_quantity INTO v_stock FROM products WHERE product_id = 990001;
    SELECT count(*) INTO v_n FROM inventory_log
    WHERE product_id = 990001 AND reason = 'restock' AND change_qty = 20;
    RAISE NOTICE '% T4  restock: stock 7 -> 27 and one "restock" row of +20', CASE WHEN v_stock = 27 AND v_n = 1 THEN 'PASS' ELSE 'FAIL' END;

    -- T5. An unlabelled manual change is still logged, as manual_change (ADR-004).
    UPDATE products SET stock_quantity = stock_quantity - 2 WHERE product_id = 990001;
    SELECT reason INTO v_reason FROM inventory_log
    WHERE product_id = 990001 ORDER BY log_id DESC LIMIT 1;
    RAISE NOTICE '% T5  unlabelled manual change still logged (reason: %)', CASE WHEN v_reason = 'manual_change' THEN 'PASS' ELSE 'FAIL' END, v_reason;

    -- T6. Stock and its history agree for the test product after all of this.
    -- The sum only means something if the history starts with the opening
    -- stock row (written by the trigger), so that is asserted too, not assumed.
    SELECT count(*) INTO v_open FROM inventory_log
    WHERE product_id = 990001 AND reason = 'opening_stock';
    SELECT p.stock_quantity - (SELECT sum(change_qty) FROM inventory_log l WHERE l.product_id = 990001)
    INTO v_n FROM products p WHERE p.product_id = 990001;
    RAISE NOTICE '% T6  history starts with its opening stock row (%) and adds up to the stock figure (difference %)',
        CASE WHEN v_open = 1 AND v_n = 0 THEN 'PASS' ELSE 'FAIL' END, v_open, v_n;
END $$;

-- T7. All or nothing: a sale whose transaction fails halfway leaves no trace (ADR-001).
-- Note: \gset ENDS a query the way a semicolon does, and stores the result in a
-- psql variable. Adding a semicolon as well would run the query and then make
-- \gset run it a second time, so these lines correctly have none.
SAVEPOINT before_t7;
SELECT stock_quantity AS t7_stock_before FROM products WHERE product_id = 990001 \gset
SELECT count(*) AS t7_orders_before FROM orders \gset
SELECT count(*) AS t7_log_before FROM inventory_log \gset
DO $$
BEGIN
    PERFORM place_order((SELECT min(customer_id) FROM customers), 990001, 1);
    RAISE EXCEPTION 'simulated failure after the sale';   -- e.g. the connection drops
EXCEPTION WHEN raise_exception THEN
    NULL;   -- the block's work is undone, as if the transaction had failed
END $$;
SELECT CASE WHEN p.stock_quantity = :t7_stock_before
             AND (SELECT count(*) FROM orders) = :t7_orders_before
             AND (SELECT count(*) FROM inventory_log) = :t7_log_before
            THEN 'PASS' ELSE 'FAIL' END
       || ' T7  failed sale left no order, no stock change, no log row' AS result
FROM products p WHERE p.product_id = 990001;

DO $$
DECLARE v_failed boolean;
BEGIN
    -- T8. Stock cannot be pushed below zero by a direct update (ADR-001 safety net).
    v_failed := false;
    BEGIN UPDATE products SET stock_quantity = -1 WHERE product_id = 990001;
    EXCEPTION WHEN check_violation THEN v_failed := true; END;
    RAISE NOTICE '% T8  direct update to negative stock refused', CASE WHEN v_failed THEN 'PASS' ELSE 'FAIL' END;

    -- T9. A new order for a customer that does not exist is refused (ADR-005).
    v_failed := false;
    BEGIN INSERT INTO orders (customer_id, order_date, status, total_amount) VALUES (-12345, now(), 'pending', 1);
    EXCEPTION WHEN foreign_key_violation THEN v_failed := true; END;
    RAISE NOTICE '% T9  order for a non-existent customer refused', CASE WHEN v_failed THEN 'PASS' ELSE 'FAIL' END;

    -- T10. Old movements cannot be edited (ADR-004, sql/08).
    v_failed := false;
    BEGIN UPDATE inventory_log SET change_qty = 0 WHERE log_id = (SELECT min(log_id) FROM inventory_log);
    EXCEPTION WHEN raise_exception THEN v_failed := true; END;
    RAISE NOTICE '% T10 editing a movement refused', CASE WHEN v_failed THEN 'PASS' ELSE 'FAIL' END;

    -- T11. The log cannot be emptied (ADR-004, sql/08).
    v_failed := false;
    BEGIN TRUNCATE inventory_log;
    EXCEPTION WHEN raise_exception THEN v_failed := true; END;
    RAISE NOTICE '% T11 emptying the log (TRUNCATE) refused', CASE WHEN v_failed THEN 'PASS' ELSE 'FAIL' END;

    -- T12. Every status spelling in the data has a meaning (F-01).
    RAISE NOTICE '% T12 no unmapped order status spellings',
        CASE WHEN NOT EXISTS (SELECT 1 FROM unmapped_order_statuses) THEN 'PASS' ELSE 'FAIL' END;
END $$;

-- T13. Stock health labels match real situations (improvement).
-- Test product A: stock 0 and sold recently  -> "3 out of stock and selling".
-- Test product B: stock 2, sells 1 a day      -> "4 low days of cover".
INSERT INTO products (product_id, product_name, category_id, price, stock_quantity, created_at)
VALUES (990002, 'TEST out of stock', NULL, 10, 0, now()), (990003, 'TEST low cover', NULL, 10, 2, now());
-- Give both a history that matches their stock: inward stock, then 28 sales of 1 in the last 28 days of as_of.
INSERT INTO inventory_log (product_id, change_qty, reason, created_at, note)
SELECT id, CASE WHEN id = 990002 THEN 28 ELSE 30 END, 'restock', (SELECT as_of FROM report_settings) - interval '30 days', 'test'
FROM (VALUES (990002::bigint), (990003::bigint)) v(id);
DELETE FROM inventory_log WHERE product_id IN (990002, 990003) AND reason = 'opening_stock';
INSERT INTO inventory_log (product_id, change_qty, reason, created_at, note)
SELECT id, -1, 'sale', (SELECT as_of FROM report_settings) - make_interval(days => d), 'test'
FROM (VALUES (990002::bigint), (990003::bigint)) v(id), generate_series(0, 27) d;
SELECT CASE WHEN (SELECT health FROM stock_health WHERE product_id = 990002) = '3 out of stock and selling'
             AND (SELECT health FROM stock_health WHERE product_id = 990003) = '4 low days of cover'
            THEN 'PASS' ELSE 'FAIL' END || ' T13 stock health labels: out-of-stock-and-selling and low-cover detected' AS result;

-- T14. Rebuilding the Monday report records when it happened, so a stale
-- report is visible (README, "Settings and routine jobs").
-- (Inside this test's transaction now() is the moment the transaction began,
-- which is after the fresh load set the first last_refreshed, so it must be later.)
SELECT last_refreshed AS t14_before FROM report_settings \gset
SELECT refresh_monday_report();
SELECT CASE WHEN last_refreshed > :'t14_before'::timestamptz THEN 'PASS' ELSE 'FAIL' END
       || ' T14 rebuilding the Monday report updates report_settings.last_refreshed' AS result
FROM report_settings;

ROLLBACK;
\echo 'All tests ran inside one transaction and were rolled back: the database is unchanged.'