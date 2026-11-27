-- run_all.sql: runs all my lab scripts, in order, against a freshly loaded database.
-- Run AFTER schema.sql and load.sql. ON_ERROR_STOP: the first error stops the run.
-- 02 (schema changes) runs inside its own transaction, so a failure there leaves
-- the schema unchanged. After any failure, recover by rerunning reset.ps1 / reset.sh
-- (a fresh load), never by continuing from where it stopped.
\set ON_ERROR_STOP on
\timing on
\echo '##### Phase 1: data diagnosis (read only) #####'
\ir 01_integrity_checks.sql
\ir 01b_cost_of_findings.sql
\echo '##### Phase 2: schema changes #####'
\ir 02_schema_changes.sql
\echo '##### Phase 3: audit trail and order placement #####'
\ir 03_audit_trail.sql
\ir 04_place_order.sql
\echo '##### Phase 4: Monday report #####'
\ir 05_monday_report.sql
\echo '##### Phase 5: low-stock category rollup #####'
\ir 06_category_rollup.sql
\echo '##### Phase 6: indexes and statistics #####'
\ir 07_indexes_and_stats.sql
\echo '##### Phase 7: audit log protection and stock health (improvement) #####'
\ir 08_protect_audit_log.sql
\ir 09_stock_health.sql