$env:GMAIL_ADDRESS      = [System.Environment]::GetEnvironmentVariable("GMAIL_ADDRESS",      "User")
$env:GMAIL_APP_PASSWORD = [System.Environment]::GetEnvironmentVariable("GMAIL_APP_PASSWORD", "User")
& "$PSScriptRoot\summarize.ps1"
