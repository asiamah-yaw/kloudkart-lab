# reset.ps1 - rebuild the lab database from scratch, exactly as a grader would,
# then run all my scripts. Run from the kloudkart-lab folder:
#   powershell -ExecutionPolicy Bypass -File .\reset.ps1
# Linux / macOS: ./reset.sh runs the same steps.

$Container = 'kloudkart'

# Runs one docker command, passed as a list of arguments (not one string), so
# PowerShell never re-reads it and paths or quotes cannot be misinterpreted.
# Stops the whole script at the first failure.
function Invoke-Step {
    param(
        [Parameter(Mandatory)] [string]   $Description,
        [Parameter(Mandatory)] [string[]] $DockerArgs
    )
    Write-Host ">> $Description" -ForegroundColor Cyan
    & docker @DockerArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Host "STOPPED: '$Description' failed. Fix the error above, then run reset.ps1 again." -ForegroundColor Red
        exit 1
    }
}

# Guard: Docker must be available and the container must exist and be running,
# so a missing or stopped container gives a clear message, not a raw docker error.
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "STOPPED: docker was not found. Install and start Docker Desktop first." -ForegroundColor Red
    exit 1
}
$running = & docker inspect --format '{{.State.Running}}' $Container 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "STOPPED: there is no container named '$Container'. Create it with the docker run command in README.md." -ForegroundColor Red
    exit 1
}
if ("$running".Trim() -ne 'true') {
    Write-Host "STOPPED: container '$Container' exists but is not running. Start it with: docker start $Container" -ForegroundColor Red
    exit 1
}

# psql inside the container, in the shared /lab folder, stopping at the first error.
$Psql = @('exec', '-w', '/lab', '-i', $Container, 'psql', '-U', 'postgres', '-d', 'lab', '-v', 'ON_ERROR_STOP=1')

Invoke-Step 'Drop the lab database'                 @('exec', $Container, 'dropdb', '-U', 'postgres', '--if-exists', '--force', 'lab')
Invoke-Step 'Create an empty lab database'          @('exec', $Container, 'createdb', '-U', 'postgres', 'lab')
Invoke-Step 'Create the original tables'            ($Psql + @('-f', 'schema.sql'))
Invoke-Step 'Load the CSV data'                     ($Psql + @('-f', 'load.sql'))
Invoke-Step 'Run every lab script (sql/run_all.sql)' ($Psql + @('-f', 'sql/run_all.sql'))
Invoke-Step 'Check version, connections, row counts' ($Psql + @('-f', 'check_setup.sql'))

Write-Host "Fresh load complete." -ForegroundColor Green