#!/usr/bin/env bash
# ops/refresh_monday_report.sh - rebuild the stored Monday report on a server
# where PostgreSQL runs directly (no Docker), for example Kloud Kart's own
# server. Needs DATABASE_URL set to that database. Prints the rebuild time.
# Schedule it with cron for Monday 06:00 (README.md, "Settings and routine jobs"):
#   0 6 * * 1  DATABASE_URL=... /path/to/kloudkart-lab/ops/refresh_monday_report.sh
set -euo pipefail
: "${DATABASE_URL:?DATABASE_URL is not set}"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 \
    -c 'SELECT refresh_monday_report();' \
    -c 'SELECT last_refreshed FROM report_settings;'