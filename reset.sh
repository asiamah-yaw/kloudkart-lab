#!/usr/bin/env bash
# reset.sh - Linux / macOS version of reset.ps1: rebuild the lab database
# from scratch, then run all my scripts. Run from the kloudkart-lab folder:
#   bash reset.sh
set -euo pipefail   # stop at the first failing command

CONTAINER=kloudkart

# Guard: Docker must be available and the container must exist and be running.
if ! command -v docker >/dev/null 2>&1; then
    echo "STOPPED: docker was not found. Install and start Docker first." >&2; exit 1
fi
if ! running=$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2>/dev/null); then
    echo "STOPPED: there is no container named '$CONTAINER'. Create it with the docker run command in README.md." >&2; exit 1
fi
if [ "$running" != "true" ]; then
    echo "STOPPED: container '$CONTAINER' exists but is not running. Start it with: docker start $CONTAINER" >&2; exit 1
fi

# Runs one step; set -e stops the script if it fails.
step() {
    local description=$1; shift
    echo ">> $description"
    "$@" || { echo "STOPPED: '$description' failed. Fix the error above, then run reset.sh again." >&2; exit 1; }
}

PSQL=(docker exec -w /lab -i "$CONTAINER" psql -U postgres -d lab -v ON_ERROR_STOP=1)

step "Drop the lab database"                  docker exec "$CONTAINER" dropdb -U postgres --if-exists --force lab
step "Create an empty lab database"           docker exec "$CONTAINER" createdb -U postgres lab
step "Create the original tables"             "${PSQL[@]}" -f schema.sql
step "Load the CSV data"                      "${PSQL[@]}" -f load.sql
step "Run every lab script (sql/run_all.sql)" "${PSQL[@]}" -f sql/run_all.sql
step "Check version, connections, row counts" "${PSQL[@]}" -f check_setup.sql

echo "Fresh load complete."