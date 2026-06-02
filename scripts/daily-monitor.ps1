# daily-monitor.ps1 - Housing Market Daily Alert Monitor
#
# Runs every day at 8 AM ET via GitHub Actions.
# Checks for significant rate or price movements vs agent-memory.json.
# Fires an immediate email alert if thresholds are crossed.
#
# Thresholds:
#   Rate spike:  30yr fixed moves > 25 bps vs last known rate in memory
#   Price drop:  any tracked market drops > 2% vs last known price
#   Price surge: any tracked market rises > 3% vs last known price

$ErrorActionPreference = "Stop"
$ROOT        = Split-Path $PSScriptRoot -Parent
$MEMORY_FILE = Join-Path $ROOT "data\agent-memory.json"
$DATA_FILE   = Join-Path $ROOT "data\markets.json"

function Log($msg)            { Write-Host "[daily-monitor] $msg" }
function FmtRate([double]$r)  { "{0:F2}%" -f ($r * 100) }
function FmtMoney([double]$n) { "`$$([math]::Round($n).ToString('N0'))" }

if (-not (Test-Path $MEMORY_FILE)) { Log "No memory file - skipping."; exit 0 }
if (-not (Test-Path $DATA_FILE))   { Log "No data file - skipping.";   exit 0 }

$mem  = Get-Content $MEMORY_FILE -Raw | ConvertFrom-Json
$data = Get-Content $DATA_FILE   -Raw | ConvertFrom-Json

$alerts   = @()
$today    = Get-Date -Format "yyyy-MM-dd"
$lastRate = ($mem.rate_history | Select-Object -Last 1).rate_30yr
$currRate = $data.mortgage_rates.rates."30yr_fixed"

Log "=== Daily Monitor ==="
Log "Last known 30yr rate: $(FmtRate $lastRate)"
Log "Current  30yr rate:   $(FmtRate $currRate)"

# ---- 1. Rate spike check -----------------------------------------------------
if ($lastRate -and $currRate) {
    $bps = [math]::Round(($currRate - $lastRate) * 10000)
    $absBps = [math]::Abs($bps)
    if ($absBps -ge 25) {
        $dir    = if ($bps -gt 0) { "UP" } else { "DOWN" }
        $from   = FmtRate $lastRate
        $to     = FmtRate $currRate
        $action = if ($bps -gt 0) {
            "Rates rising - consider locking sooner rather than later."
        } else {
            "Rates dropping - your purchasing power just increased."
        }
        $alerts += [PSCustomObject]@{
            type     = "RATE_SPIKE"
            title    = "Rate Alert: 30yr $dir $absBps bps"
            detail   = "30yr fixed moved from $from to $to ($absBps bps $dir)."
            action   = $action
            severity = if ($absBps -ge 50) { "HIGH" } else { "MEDIUM" }
        }
        Log "ALERT: Rate moved $absBps bps $dir"
    } else {
        Log "Rate within normal range - $absBps bps change, no alert."
    }
}

# ---- 2. Price movement check -------------------------------------------------
$allMarkets = @($data.primary_markets) + @($data.research_markets)
foreach ($m in $allMarkets) {
    $key  = $m.name.ToLower() -replace ' ','_'
    $prev = if ($mem.price_signals.PSObject.Properties[$key]) { $mem.price_signals.$key.last_seen } else { $null }
    $curr = $m.median_price
    if (-not $prev -or -not $curr -or $prev -eq 0) { continue }

    $chgPct = [math]::Round((($curr - $prev) / $prev) * 100, 1)
    $prevFmt = FmtMoney $prev
    $currFmt = FmtMoney $curr

    if ($chgPct -le -2.0) {
        $absPct = [math]::Abs($chgPct)
        $alerts += [PSCustomObject]@{
            type     = "PRICE_DROP"
            title    = "Price Drop: $($m.name) down $absPct%"
            detail   = "$($m.name), $($m.state): $prevFmt to $currFmt ($chgPct%)"
            action   = "Prices cooling in $($m.name) - potential buying opportunity. Consider scheduling viewings."
            severity = if ($chgPct -le -4.0) { "HIGH" } else { "MEDIUM" }
        }
        Log "ALERT: $($m.name) price dropped $chgPct%"
    } elseif ($chgPct -ge 3.0) {
        $alerts += [PSCustomObject]@{
            type     = "PRICE_SURGE"
            title    = "Price Surge: $($m.name) up $chgPct%"
            detail   = "$($m.name), $($m.state): $prevFmt to $currFmt (+$chgPct%)"
            action   = "Prices accelerating in $($m.name) - if this is a target market, act sooner."
            severity = if ($chgPct -ge 5.0) { "HIGH" } else { "MEDIUM" }
        }
        Log "ALERT: $($m.name) price surged $chgPct%"
    }
}

Log "$($alerts.Count) alert(s) triggered."

if ($alerts.Count -eq 0) {
    Log "All clear - no alerts to send today."
    # Still update rate in memory if it changed
    if ($currRate -and $currRate -ne $lastRate) {
        $newEntry = [PSCustomObject]@{
            date      = $today
            rate_30yr = $currRate
            rate_15yr = $data.mortgage_rates.rates."15yr_fixed"
            driver    = $data.mortgage_rates.rate_driver
        }
        $mem.rate_history      = @($mem.rate_history) + $newEntry
        $mem.meta.last_updated = $today
        $mem | ConvertTo-Json -Depth 8 | Set-Content $MEMORY_FILE -Encoding utf8
        Log "Memory updated with new rate."
    }
    exit 0
}

# ---- 3. Send alert email -----------------------------------------------------
$appPassword = $env:GMAIL_APP_PASSWORD
$gmailAddr   = $env:GMAIL_ADDRESS
$toEmail     = "domaragonjr@gmail.com"

if (-not $appPassword -or -not $gmailAddr) {
    Log "WARN: Gmail credentials not set - alert email skipped."
    $alerts | ForEach-Object { Log "  [$($_.severity)] $($_.title): $($_.detail)" }
    exit 0
}

function Build-AlertCard($alert) {
    $borderClr = if ($alert.severity -eq "HIGH") { "#c53030" } else { "#d97706" }
    $badgeClr  = if ($alert.severity -eq "HIGH") { "#fee2e2" } else { "#fef3c7" }
    $badgeTxt  = if ($alert.severity -eq "HIGH") { "#c53030" } else { "#92400e" }
    $icon = switch ($alert.type) {
        "RATE_SPIKE"  { if ($alert.title -match "UP") { "Rate UP" } else { "Rate DOWN" } }
        "PRICE_DROP"  { "Price Drop" }
        "PRICE_SURGE" { "Price Surge" }
        default       { "Alert" }
    }
    $title  = $alert.title
    $detail = $alert.detail
    $action = $alert.action
    $sev    = $alert.severity
    @"
<div style='background:#fff;border-radius:10px;padding:16px 20px;border-left:5px solid $borderClr;margin-bottom:14px;box-shadow:0 1px 4px rgba(0,0,0,.06)'>
<div style='display:flex;justify-content:space-between;align-items:flex-start;margin-bottom:8px'>
<div style='font-size:1rem;font-weight:800;color:#1a202c'>${icon} - $title</div>
<span style='font-size:.65rem;font-weight:700;padding:2px 8px;border-radius:4px;background:$badgeClr;color:$badgeTxt'>$sev</span>
</div>
<div style='font-size:.85rem;color:#4a5568;margin-bottom:8px'>$detail</div>
<div style='font-size:.82rem;font-weight:600;color:$borderClr'>Action: $action</div>
</div>
"@
}

$alertCards = ($alerts | ForEach-Object { Build-AlertCard $_ }) -join ""
$alertCount = $alerts.Count
$highCount  = ($alerts | Where-Object { $_.severity -eq "HIGH" }).Count
$subjectTag = if ($highCount -gt 0) { "ACTION REQUIRED" } else { "FYI" }
$subject    = "Housing Alert [$subjectTag] - $alertCount signal(s) detected $today"

$htmlBody = @"
<!DOCTYPE html><html><body style='margin:0;padding:0;background:#f0f4f8'>
<div style='max-width:600px;margin:0 auto;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif'>
<div style='background:linear-gradient(135deg,#7c3aed,#4f46e5);padding:20px 24px;color:#fff'>
<div style='font-size:1.1rem;font-weight:800'>Housing Market Alert</div>
<div style='font-size:.8rem;opacity:.75;margin-top:3px'>$today · $alertCount signal(s) detected by your agent</div>
</div>
<div style='background:#fff;padding:20px 24px'>
<p style='font-size:.88rem;color:#4a5568;margin:0 0 18px'>Your housing agent detected the following signals that crossed your alert thresholds:</p>
$alertCards
<div style='margin-top:20px;padding:14px;background:#f7fafc;border-radius:8px;font-size:.78rem;color:#718096'>
Alert thresholds: Rate spike more than 25 bps · Price drop more than 2% · Price surge more than 3%
</div>
</div>
<div style='padding:12px 24px;background:#16213e;font-size:.72rem;color:#718096;text-align:center'>
<a href='https://domaragonjr-093017.github.io/Housing-Investment-Dashboard/' style='color:#93c5fd;text-decoration:none;font-weight:600'>View Live Dashboard</a>
&nbsp;·&nbsp; Housing Agent Daily Monitor
</div>
</div>
</body></html>
"@

try {
    $smtp                       = New-Object System.Net.Mail.SmtpClient("smtp.gmail.com", 587)
    $smtp.EnableSsl             = $true
    $smtp.UseDefaultCredentials = $false
    $smtp.Credentials           = New-Object System.Net.NetworkCredential($gmailAddr, $appPassword)

    $msg            = New-Object System.Net.Mail.MailMessage
    $msg.From       = $gmailAddr
    $msg.To.Add($toEmail)
    $msg.Subject    = $subject
    $msg.IsBodyHtml = $true
    $msg.Body       = $htmlBody

    $smtp.Send($msg)
    Log "Alert email sent to $toEmail"
} catch {
    Log "ERROR sending alert: $($_.Exception.Message)"
}

# ---- 4. Update memory --------------------------------------------------------
$newEntry = [PSCustomObject]@{
    date      = $today
    rate_30yr = $currRate
    rate_15yr = $data.mortgage_rates.rates."15yr_fixed"
    driver    = $data.mortgage_rates.rate_driver
}
$mem.rate_history      = @($mem.rate_history) + $newEntry
$mem.meta.last_updated = $today
$mem | ConvertTo-Json -Depth 8 | Set-Content $MEMORY_FILE -Encoding utf8
Log "Memory updated."
Log "=== Daily Monitor Complete ==="
