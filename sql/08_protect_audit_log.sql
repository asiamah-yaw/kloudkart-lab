-- =====================================================================
-- 08_protect_audit_log.sql
-- Protects the stock trail against being EDITED or WIPED: rows can be
-- added, not changed. A mistake in the trail is fixed the way an accountant
-- fixes a ledger -- by adding a 'correction' row -- not by editing old rows.
-- It is NOT fully append-only: single rows can still be DELETED (below), so
-- database permissions, not this trigger, are the real control on deletion.
--
-- Blocked: UPDATE (editing a movement) and TRUNCATE (wiping the log).
-- Deliberately NOT blocked: DELETE. race_test.py, which must run
-- unmodified, deletes the test rows it creates when it cleans up; a hard
-- block on DELETE would break it. Limiting DELETE is done instead with
-- database permissions (the shop application's login should not have
-- DELETE on inventory_log) -- recorded as a recommendation in ADR-004.
-- =====================================================================

CREATE OR REPLACE FUNCTION refuse_log_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'inventory_log rows cannot be changed or wiped: % is not allowed. Record a correction as a new row instead.', TG_OP
        USING HINT = 'INSERT INTO inventory_log (product_id, change_qty, reason, created_at, note) VALUES (..., ''correction'', now(), ''why'')';
END $$;

-- BEFORE: refuse before anything is changed.
CREATE TRIGGER inventory_log_no_update
    BEFORE UPDATE ON inventory_log
    FOR EACH ROW EXECUTE FUNCTION refuse_log_change();

-- TRUNCATE empties a table in one go and does not fire row triggers,
-- so it needs its own statement-level trigger.
CREATE TRIGGER inventory_log_no_truncate
    BEFORE TRUNCATE ON inventory_log
    FOR EACH STATEMENT EXECUTE FUNCTION refuse_log_change();