-- run_all.sql: runs all my lab scripts, in order, against a freshly loaded database.
-- Run AFTER schema.sql and load.sql. Each file is added here as it is built.
\set ON_ERROR_STOP on
\timing on
\ir 01_integrity_checks.sql
\ir 01b_cost_of_findings.sql