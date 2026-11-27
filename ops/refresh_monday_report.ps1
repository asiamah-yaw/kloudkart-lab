# ops/refresh_monday_report.ps1 - rebuild the stored Monday report on this
# laptop's Docker container (about 7 seconds; people can keep reading the old
# figures meanwhile). Prints when the report was last rebuilt.
# Run by hand, or schedule it for Monday 06:00 with Windows Task Scheduler
# (the exact command is in README.md, "Settings and routine jobs").

$Container = 'kloudkart'
& docker exec $Container psql -U postgres -d lab -v ON_ERROR_STOP=1 `
    -c 'SELECT refresh_monday_report();' `
    -c 'SELECT last_refreshed FROM report_settings;'
if ($LASTEXITCODE -ne 0) {
    Write-Host "STOPPED: the Monday report was NOT rebuilt. Is the '$Container' container running?" -ForegroundColor Red
    exit 1
}