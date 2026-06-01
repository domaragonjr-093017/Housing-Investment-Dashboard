# run-now.ps1 - Ad-hoc Housing Dashboard Refresh + Email
#
# Runs a full data refresh and sends the dashboard email immediately.
# Double-click the desktop shortcut, or run from PowerShell:
#   .\scripts\run-now.ps1
#
# Optional flags (passed through to refresh.ps1):
#   -RatesOnly   refresh mortgage rates only, then email
#   -EmailOnly   skip refresh, just resend the email from current data

param(
    [switch]$RatesOnly,
    [switch]$EmailOnly
)

$ROOT = Split-Path $PSScriptRoot -Parent

# Load credentials from Windows User environment
$env:FRED_API_KEY       = [System.Environment]::GetEnvironmentVariable("FRED_API_KEY",       "User")
$env:ANTHROPIC_API_KEY  = [System.Environment]::GetEnvironmentVariable("ANTHROPIC_API_KEY",  "User")
$env:GMAIL_ADDRESS      = [System.Environment]::GetEnvironmentVariable("GMAIL_ADDRESS",      "User")
$env:GMAIL_APP_PASSWORD = [System.Environment]::GetEnvironmentVariable("GMAIL_APP_PASSWORD", "User")

if (-not $env:GMAIL_ADDRESS -or -not $env:GMAIL_APP_PASSWORD) {
    Write-Host "[run-now] ERROR: Gmail credentials not found in Windows environment variables." -ForegroundColor Red
    Write-Host "          Run these once to set them up:" -ForegroundColor Yellow
    Write-Host "          [System.Environment]::SetEnvironmentVariable('GMAIL_ADDRESS','you@gmail.com','User')" -ForegroundColor Yellow
    Write-Host "          [System.Environment]::SetEnvironmentVariable('GMAIL_APP_PASSWORD','xxxx-xxxx-xxxx-xxxx','User')" -ForegroundColor Yellow
    pause
    exit 1
}

Write-Host ""
Write-Host "  Housing Market Dashboard - Ad-hoc Update" -ForegroundColor Cyan
Write-Host "  =========================================" -ForegroundColor Cyan
Write-Host ""

if ($EmailOnly) {
    Write-Host "[run-now] Skipping refresh - sending email from current data..." -ForegroundColor Yellow
    & "$ROOT\scripts\summarize.ps1"
} elseif ($RatesOnly) {
    Write-Host "[run-now] Refreshing rates only, then emailing..." -ForegroundColor Yellow
    & "$ROOT\scripts\refresh.ps1" -RatesOnly
} else {
    Write-Host "[run-now] Running full refresh (rates + prices) + email..." -ForegroundColor Yellow
    & "$ROOT\scripts\refresh.ps1"
}

Write-Host ""
Write-Host "[run-now] Done! Check your inbox at $env:GMAIL_ADDRESS" -ForegroundColor Green
Write-Host ""
# Keep window open for 5 seconds so you can see the result
Start-Sleep -Seconds 5
