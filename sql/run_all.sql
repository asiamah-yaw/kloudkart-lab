-- run_all.sql: runs all my lab scripts, in order, against a freshly loaded database.
-- Run AFTER schema.sql and load.sql. Each file is added here as it is built.
\set ON_ERROR_STOP on
\timing on
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