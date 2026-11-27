-- =====================================================================
-- 03_audit_trail.sql
-- Nana's 4th ask: "a trail of every stock movement -- sale, restock,
-- correction -- that an auditor could walk through afterwards."
--
-- Design: a TRIGGER on products writes the inventory_log row for EVERY
-- change to stock_quantity, whoever makes it. This is the job triggers
-- are genuinely good at: a reaction that must never be forgotten.
--   * place_order labels its change as a 'sale' with the order number.
--   * Any other change (restock screen, a manual UPDATE in a terminal)
--     is still logged, labelled with whatever reason the caller set,
--     or 'manual_change' plus the database user if none was set.
-- So the trail cannot be bypassed by forgetting to write it.
--
-- How the label reaches the trigger: the caller sets two transaction-
-- local settings (kloudkart.stock_reason, kloudkart.stock_note) before
-- updating stock. "Local" = they vanish when the transaction ends, so
-- one order's label can never leak onto someone else's change.
--
-- Note: this logging trigger does NOT stop two buyers taking the last unit.
-- A trigger that only checks stock lets both through; one that decrements
-- stock does stop it, but can only refuse with an error, not a clean
-- "out of stock" (tested: ADR-001, Alternative C). That job belongs to
-- place_order's row lock, which checks before it writes.
-- =====================================================================

CREATE OR REPLACE FUNCTION log_stock_change() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_old    integer := CASE WHEN TG_OP = 'INSERT' THEN 0 ELSE OLD.stock_quantity END;
    v_reason text    := nullif(current_setting('kloudkart.stock_reason', true), '');
    v_note   text    := nullif(current_setting('kloudkart.stock_note',   true), '');
BEGIN
    IF NEW.stock_quantity IS DISTINCT FROM v_old THEN
        INSERT INTO inventory_log (product_id, change_qty, reason, created_at, note)
        VALUES (NEW.product_id,
                coalesce(NEW.stock_quantity, 0) - coalesce(v_old, 0),
                coalesce(v_reason, CASE WHEN TG_OP = 'INSERT' THEN 'opening_stock'
                                        ELSE 'manual_change' END),
                now(),
                coalesce(v_note, 'no reason given; changed by database user ' || current_user));
    END IF;
    RETURN NULL;   -- AFTER trigger: the return value is ignored
END $$;

COMMENT ON FUNCTION log_stock_change() IS
    'Writes one inventory_log row for every change to products.stock_quantity. '
    'Set kloudkart.stock_reason / kloudkart.stock_note (transaction-local) to label the change.';

-- AFTER: the log row is only written once the stock change has actually
-- happened. FOR EACH ROW: an update touching several products logs each.
-- Both run inside the same transaction as the change, so if the change is
-- rolled back, its log row is rolled back with it.
CREATE TRIGGER products_log_stock_update
    AFTER UPDATE OF stock_quantity ON products
    FOR EACH ROW
    WHEN (OLD.stock_quantity IS DISTINCT FROM NEW.stock_quantity)
    EXECUTE FUNCTION log_stock_change();

CREATE TRIGGER products_log_stock_insert
    AFTER INSERT ON products
    FOR EACH ROW
    WHEN (coalesce(NEW.stock_quantity, 0) <> 0)
    EXECUTE FUNCTION log_stock_change();