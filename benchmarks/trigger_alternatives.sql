-- =====================================================================
-- benchmarks/trigger_alternatives.sql
-- Re-runnable evidence for ADR-001, Alternative C: would a trigger ALONE
-- have stopped the overselling? Two buyers race for ONE unit at the same
-- moment, against two kinds of trigger:
--   C1  a trigger that checks the stock, then writes the new figure
--   C2  a trigger that decrements in one statement (stock = stock - qty),
--       with CHECK (stock >= 0) underneath
--
-- How two buyers run at once from one script: the dblink extension opens
-- two separate database connections and sends both orders without waiting
-- (dblink_send_query), so they really overlap. pg_sleep(1) inside each
-- trigger holds the gap open long enough for the race to happen every time.
--
-- Everything is created in its own schema, trigger_demo, which is dropped
-- at the end (with the dblink extension inside it). Kloud Kart's own tables
-- are never touched. Run on a test copy, after a fresh load:
--   docker exec -w /lab -i kloudkart psql -U postgres -d lab -f benchmarks/trigger_alternatives.sql
-- Expected: C1 sells 2 for 1 unit (stock shows 0, hiding it); C2 sells 1
-- and the other buyer gets a raw "violates check constraint" error.
-- Not part of run_all.sql.
-- =====================================================================
\set ON_ERROR_STOP on
\pset pager off
\set QUIET on
SET client_min_messages = warning;   -- hide routine notices (drops, the remote error echo)

DROP SCHEMA IF EXISTS trigger_demo CASCADE;
CREATE SCHEMA trigger_demo;
CREATE EXTENSION dblink SCHEMA trigger_demo;
SET search_path = trigger_demo, public;

CREATE TABLE trigger_demo.stock_item (product_id int PRIMARY KEY, stock int NOT NULL CHECK (stock >= 0));
CREATE TABLE trigger_demo.order_line (line_id serial PRIMARY KEY, product_id int NOT NULL, qty int NOT NULL);

-- C1: check, then write. The write uses the value READ, not the current one.
CREATE FUNCTION trigger_demo.c1_check_then_write() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_stock int;
BEGIN
    SELECT stock INTO v_stock FROM trigger_demo.stock_item WHERE product_id = NEW.product_id;
    PERFORM pg_sleep(1);                      -- the other buyer reads in this gap
    IF v_stock < NEW.qty THEN
        RAISE EXCEPTION 'out of stock';
    END IF;
    UPDATE trigger_demo.stock_item SET stock = v_stock - NEW.qty WHERE product_id = NEW.product_id;
    RETURN NEW;
END $$;

-- C2: decrement in one statement. The UPDATE takes the row lock, so the
-- second buyer waits, then re-reads the new stock; CHECK refuses below zero.
CREATE FUNCTION trigger_demo.c2_decrement() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE trigger_demo.stock_item SET stock = stock - NEW.qty WHERE product_id = NEW.product_id;
    PERFORM pg_sleep(1);                      -- hold the lock, so the other buyer must wait
    RETURN NEW;
END $$;

-- Results of each race.
CREATE TABLE trigger_demo.result (version text, buyer int, outcome text);

-- Runs one race: reset to 1 unit, fire two buyers at once, record what each got.
CREATE FUNCTION trigger_demo.race(p_version text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_conn   text;
    v_status text;
    v_err    text;
BEGIN
    FOR b IN 1..2 LOOP
        v_conn := 'buyer' || b;
        PERFORM trigger_demo.dblink_connect(v_conn, 'dbname=' || current_database());
        PERFORM trigger_demo.dblink_send_query(v_conn,
            'INSERT INTO trigger_demo.order_line (product_id, qty) VALUES (1, 1)');
    END LOOP;
    FOR b IN 1..2 LOOP
        v_conn := 'buyer' || b;
        v_status := NULL;
        -- fail = false: a remote error is returned to us instead of stopping this script
        SELECT s INTO v_status FROM trigger_demo.dblink_get_result(v_conn, false) AS t(s text);
        v_err := trigger_demo.dblink_error_message(v_conn);
        INSERT INTO trigger_demo.result VALUES (p_version, b,
            CASE WHEN v_status IS NOT NULL AND v_err = 'OK' THEN 'order placed'
                 ELSE split_part(v_err, E'\n', 1) END);   -- first line of the error the buyer got
        PERFORM * FROM trigger_demo.dblink_get_result(v_conn, false) AS t(s text);   -- clear the connection
        PERFORM trigger_demo.dblink_disconnect(v_conn);
    END LOOP;
END $$;

-- ---------------------------------------------------------------- C1
INSERT INTO trigger_demo.stock_item VALUES (1, 1);
CREATE TRIGGER c1 BEFORE INSERT ON trigger_demo.order_line
    FOR EACH ROW EXECUTE FUNCTION trigger_demo.c1_check_then_write();
SELECT trigger_demo.race('C1 check-then-write') \g /dev/null
CREATE TABLE trigger_demo.summary AS
SELECT 'C1 check-then-write'::text AS version,
       (SELECT count(*) FROM trigger_demo.order_line) AS units_sold_for_1_in_stock,
       (SELECT stock FROM trigger_demo.stock_item)    AS stock_shown_afterwards;

-- ---------------------------------------------------------------- C2
DROP TRIGGER c1 ON trigger_demo.order_line;
TRUNCATE trigger_demo.order_line;
UPDATE trigger_demo.stock_item SET stock = 1;
CREATE TRIGGER c2 BEFORE INSERT ON trigger_demo.order_line
    FOR EACH ROW EXECUTE FUNCTION trigger_demo.c2_decrement();
SELECT trigger_demo.race('C2 decrement + CHECK') \g /dev/null
INSERT INTO trigger_demo.summary
SELECT 'C2 decrement + CHECK',
       (SELECT count(*) FROM trigger_demo.order_line),
       (SELECT stock FROM trigger_demo.stock_item);

\set QUIET off
\echo '=== Two buyers, one unit: what each kind of trigger allowed ==='
SELECT * FROM trigger_demo.summary ORDER BY version;
\echo '=== What each buyer was told ==='
SELECT version, buyer, outcome FROM trigger_demo.result ORDER BY version, buyer;

DROP SCHEMA trigger_demo CASCADE;
\echo 'Done. The trigger_demo schema (and dblink with it) has been removed.'