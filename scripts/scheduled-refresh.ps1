# scheduled-refresh.ps1 - Windows Task Scheduler entry point
#
# Runs every Wednesday automatically (registered via Task Scheduler).
# Loads all credentials from Windows User-level env vars, then runs a full refresh + AI summary + email.
#
# Do NOT run this file manually — use run-now.ps1 instead (it has better output formatting).
#
# To trigger immediately for testing:
#   Start-ScheduledTask -TaskName "HousingDashboard-Wednesday"

$ErrorActionPreference = "Stop"
$ROOT = Split-Path $PSScriptRoot -Parent

# Load all credentials from Windows User environment
# (Scheduled tasks run in a separate session and don't inherit the interactive User env vars)
$env:FRED_API_KEY       = [System.Environment]::GetEnvironmentVariable("FRED_API_KEY",       "User")
$env:ANTHROPIC_API_KEY  = [System.Environment]::GetEnvironmentVariable("ANTHROPIC_API_KEY",  "User")
$env:GMAIL_ADDRESS      = [System.Environment]::GetEnvironmentVariable("GMAIL_ADDRESS",      "User")
$env:GMAIL_APP_PASSWORD = [System.Environment]::GetEnvironmentVariable("GMAIL_APP_PASSWORD", "User")

# Log to a file so you can audit runs even when no window is visible
$logFile = Join-Path $ROOT "exports\scheduled-run.log"
$stamp   = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Add-Content $logFile "[$stamp] Scheduled Wednesday refresh starting..."

try {
    & "$PSScriptRoot\refresh.ps1"
    $stamp2 = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content $logFile "[$stamp2] Completed successfully."
} catch {
    $stamp2 = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content $logFile "[$stamp2] ERROR: $($_.Exception.Message)"
    throw
}
