# alert.ps1 - Housing Market Threshold Alert
#
# Called automatically by refresh.ps1 after every data update.
# Compares current data against the pre-refresh snapshot and sends
# an immediate alert email if any threshold is crossed.
#
# Can also be run manually: .\scripts\alert.ps1
#
# Default thresholds (adjust via params):
#   -RateBpsThreshold  25    alert if 30yr rate moves >= 25 bps either direction
#   -PITIThreshold   5000    alert if a primary market newly drops below this/mo
#   -PriceDropPct       5    alert if any primary market drops >= 5% from snapshot

param(
    [int]   $RateBpsThreshold = 25,
    [double]$PITIThreshold    = 5000,
    [double]$PriceDropPct     = 5
)

$ROOT          = Split-Path $PSScriptRoot -Parent
$CURRENT_FILE  = Join-Path $ROOT "data\markets.json"
$SNAPSHOT_FILE = Join-Path $ROOT "data\markets_snapshot.json"

function Log($msg) { Write-Host "[alert] $msg" }

# ── Guard ──────────────────────────────────────────────────────────────────────
if (-not (Test-Path $CURRENT_FILE) -or -not (Test-Path $SNAPSHOT_FILE)) {
    Log "Missing data files - skipping alert check."
    exit 0
}

$current  = Get-Content $CURRENT_FILE  -Raw | ConvertFrom-Json
$snapshot = Get-Content $SNAPSHOT_FILE -Raw | ConvertFrom-Json

$down       = $current.meta.owner_context.net_proceeds
$rate30     = $current.mortgage_rates.rates."30yr_fixed"
$rate30Prev = $snapshot.mortgage_rates.rates."30yr_fixed"

# ── Helpers ────────────────────────────────────────────────────────────────────
function PITI($price, $rate, $tax, $ins = 2400) {
    $loan = $price - $down; $r = $rate / 12; $n = 360
    $pi = if ($r -eq 0) { $loan / $n } else { ($loan * $r * [math]::Pow(1+$r,$n)) / ([math]::Pow(1+$r,$n) - 1) }
    [math]::Round($pi + $tax / 12 + $ins / 12)
}
function M($n)   { "`$" + [math]::Round($n).ToString("N0") }
function Pct($n) { "{0:F2}%" -f ($n * 100) }

$allSnapshot = @($snapshot.primary_markets) + @($snapshot.research_markets)
$alerts      = @()

# ── Check 1: Rate movement ─────────────────────────────────────────────────────
$bps = [math]::Round(($rate30 - $rate30Prev) * 10000)
if ([math]::Abs($bps) -ge $RateBpsThreshold) {
    $dir  = if ($bps -gt 0) { "UP" } else { "DOWN" }
    $good = ($bps -lt 0)
    $clr  = if ($good) { "#276749" } else { "#c53030" }
    $icon = if ($good) { "Green flag" } else { "Warning" }

    $impact = ($current.primary_markets | ForEach-Object {
        $pNew = PITI $_.median_price $rate30     $_.annual_tax
        $pOld = PITI $_.median_price $rate30Prev $_.annual_tax
        $d    = $pNew - $pOld
        "$($_.name): $(M $pNew)/mo ($(if ($d -gt 0) { '+' })$(M $d)/mo)"
    }) -join "  |  "

    $alerts += [PSCustomObject]@{
        title  = "Rate $dir $([math]::Abs($bps)) bps - 30yr now $(Pct $rate30)"
        detail = "Was $(Pct $rate30Prev). PITI impact -- $impact"
        color  = $clr
        good   = $good
    }
}

# ── Check 2: PITI threshold (newly crossed) ───────────────────────────────────
foreach ($m in $current.primary_markets) {
    $pNow  = PITI $m.median_price $rate30     $m.annual_tax
    $pPrev = PITI $m.median_price $rate30Prev $m.annual_tax
    if ($pNow -le $PITIThreshold -and $pPrev -gt $PITIThreshold) {
        $alerts += [PSCustomObject]@{
            title  = "PITI Alert: $($m.name) dropped to $(M $pNow)/mo"
            detail = "$($m.name), $($m.state): PITI crossed below $(M $PITIThreshold)/mo (was $(M $pPrev)/mo). $(M $m.median_price) median, $(M $down) down at $(Pct $rate30)."
            color  = "#276749"
            good   = $true
        }
    }
}

# ── Check 3: Price drop on primary markets ────────────────────────────────────
foreach ($m in $current.primary_markets) {
    $prev = $allSnapshot | Where-Object { $_.id -eq $m.id } | Select-Object -First 1
    if (-not $prev -or -not $prev.median_price -or $prev.median_price -le 0) { continue }
    $drop = (($prev.median_price - $m.median_price) / $prev.median_price) * 100
    if ($drop -ge $PriceDropPct) {
        $delta = $prev.median_price - $m.median_price
        $alerts += [PSCustomObject]@{
            title  = "Price Drop: $($m.name) fell $([math]::Round($drop,1))%"
            detail = "$($m.name), $($m.state): $(M $m.median_price) (was $(M $prev.median_price), down $(M $delta) / $([math]::Round($drop,1))%). New PITI: $(M (PITI $m.median_price $rate30 $m.annual_tax))/mo."
            color  = "#276749"
            good   = $true
        }
    }
}

# ── Nothing triggered ──────────────────────────────────────────────────────────
if ($alerts.Count -eq 0) {
    Log "All thresholds clear - no alert needed."
    exit 0
}

Log "$($alerts.Count) threshold(s) crossed:"
$alerts | ForEach-Object { Log "  --> $($_.title)" }

# ── Build + send alert email ───────────────────────────────────────────────────
$gmailAddr = $env:GMAIL_ADDRESS
$appPwd    = $env:GMAIL_APP_PASSWORD

if (-not $gmailAddr -or -not $appPwd) {
    Log "WARN: Email credentials not set - alert logged above but not emailed."
    exit 0
}

$date       = Get-Date -Format "MMMM d, yyyy"
$allGood    = ($alerts | Where-Object { -not $_.good }).Count -eq 0
$hdrClr     = if ($allGood) { "linear-gradient(135deg,#276749,#1a4731)" } else { "linear-gradient(135deg,#c53030,#9b2c2c)" }

$alertCards = ($alerts | ForEach-Object {
    $icon = if ($_.good) { "+" } else { "!" }
    "<div style='background:$($_.color)18;border-left:4px solid $($_.color);border-radius:6px;padding:14px 16px;margin-bottom:10px'>" +
    "<div style='font-weight:700;color:$($_.color);font-size:.95rem'>[$icon] $($_.title)</div>" +
    "<div style='color:#4a5568;font-size:.83rem;margin-top:5px;line-height:1.5'>$($_.detail)</div>" +
    "</div>"
}) -join ""

$th = "style='padding:7px 10px;text-align:left;font-size:.72rem;font-weight:700;text-transform:uppercase;letter-spacing:.4px;background:#0f3460;color:#fff'"
$td = "style='padding:8px 10px;font-size:.83rem;border-bottom:1px solid #f0f4f8'"

$snapRows = ($current.primary_markets | ForEach-Object {
    $p    = PITI $_.median_price $rate30 $_.annual_tax
    $flag = if ($p -le $PITIThreshold) { " [below threshold]" } else { "" }
    "<tr>" +
    "<td $td style='font-weight:700'>$($_.name)</td>" +
    "<td $td style='color:#718096'>$($_.state)</td>" +
    "<td $td style='font-weight:700'>$(M $_.median_price)</td>" +
    "<td $td style='font-weight:700;color:#e94560'>$(M $p)/mo$flag</td>" +
    "</tr>"
}) -join ""

$htmlBody = "<!DOCTYPE html><html><body style='margin:0;padding:0;background:#f0f4f8'>" +
    "<div style='max-width:620px;margin:0 auto;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;color:#1a202c'>" +
    "<div style='background:$hdrClr;padding:20px 24px;color:#fff'>" +
    "<div style='font-size:1.1rem;font-weight:800'>Housing Dashboard Alert</div>" +
    "<div style='font-size:.78rem;opacity:.8;margin-top:3px'>$date - $($alerts.Count) threshold(s) triggered</div>" +
    "</div>" +
    "<div style='background:#fff;padding:20px 24px'>" +
    "<div style='font-size:.72rem;font-weight:700;text-transform:uppercase;letter-spacing:.5px;color:#718096;margin-bottom:12px'>What Triggered</div>" +
    $alertCards +
    "<div style='margin-top:22px;font-size:.72rem;font-weight:700;text-transform:uppercase;letter-spacing:.5px;color:#718096;margin-bottom:8px'>Current Primary Markets</div>" +
    "<table style='width:100%;border-collapse:collapse'>" +
    "<thead><tr><th $th>Market</th><th $th>State</th><th $th>Median Price</th><th $th>PITI/mo</th></tr></thead>" +
    "<tbody>$snapRows</tbody></table>" +
    "<div style='margin-top:10px;font-size:.72rem;color:#a0aec0'>" +
    "PITI threshold: $(M $PITIThreshold)/mo  |  Rate threshold: $RateBpsThreshold bps  |  Price drop threshold: $PriceDropPct%  |  $(M $down) down assumed" +
    "</div>" +
    "</div>" +
    "<div style='padding:10px 24px;background:#16213e;font-size:.7rem;color:#718096'>HousingDashboard alert - $date</div>" +
    "</div></body></html>"

try {
    $smtp                       = New-Object System.Net.Mail.SmtpClient("smtp.gmail.com", 587)
    $smtp.EnableSsl             = $true
    $smtp.UseDefaultCredentials = $false
    $smtp.Credentials           = New-Object System.Net.NetworkCredential($gmailAddr, $appPwd)

    $firstTitle = ($alerts | Select-Object -First 1).title
    $subject    = "Housing Alert: $firstTitle"
    if ($alerts.Count -gt 1) { $subject = $subject + " (+" + ($alerts.Count - 1) + " more)" }

    $msg            = New-Object System.Net.Mail.MailMessage
    $msg.From       = $gmailAddr
    $msg.To.Add("domaragonjr@gmail.com")
    $msg.Subject    = $subject
    $msg.IsBodyHtml = $true
    $msg.Body       = $htmlBody
    $smtp.Send($msg)
    Log "Alert email sent: $subject"
} catch {
    Log "ERROR sending alert email: $($_.Exception.Message)"
}
