# reset.ps1 - rebuild the lab database from scratch, exactly as a grader would,
# then run all my scripts. Run from the kloudkart-lab folder:
#   powershell -ExecutionPolicy Bypass -File .\reset.ps1

function Run($cmd) {
    Write-Host ">> $cmd" -ForegroundColor Cyan
    Invoke-Expression $cmd
    if ($LASTEXITCODE -ne 0) { Write-Host "STOPPED: that step failed." -ForegroundColor Red; exit 1 }
}

Run "docker exec kloudkart dropdb -U postgres --if-exists --force lab"
Run "docker exec kloudkart createdb -U postgres lab"
Run "docker exec -w /lab -i kloudkart psql -U postgres -d lab -v ON_ERROR_STOP=1 -f schema.sql"
Run "docker exec -w /lab -i kloudkart psql -U postgres -d lab -v ON_ERROR_STOP=1 -f load.sql"
Run "docker exec -w /lab -i kloudkart psql -U postgres -d lab -v ON_ERROR_STOP=1 -f sql/run_all.sql"
Run "docker exec -w /lab -i kloudkart psql -U postgres -d lab -f check_setup.sql"

Write-Host "Fresh load complete." -ForegroundColor Green