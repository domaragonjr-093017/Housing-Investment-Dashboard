# summarize.ps1 - Housing Market AI Agent: Diff + Summarize + Email
#
# Compares data/markets_snapshot.json (pre-refresh) against data/markets.json (post-refresh),
# writes a plain-English summary of what changed, and emails it to you.
#
# Called automatically by refresh.ps1 after every update.
# Can also be run manually: .\scripts\summarize.ps1
#
# Required env var:
#   $env:ICLOUD_APP_PASSWORD  - App-specific password from appleid.apple.com
#   (see setup instructions at bottom of this file)

param(
    [string]$ToEmail   = "domaragonjr@gmail.com",
    [string]$FromEmail = "domaragonjr@gmail.com"
)

$ROOT          = Split-Path $PSScriptRoot -Parent
$CURRENT_FILE  = Join-Path $ROOT "data\markets.json"
$SNAPSHOT_FILE = Join-Path $ROOT "data\markets_snapshot.json"
$SUMMARY_FILE  = Join-Path $ROOT "exports\weekly_summary.md"

function Log($msg) { Write-Host "[summarize] $msg" }

function Build-ListingCard($item) {
    $price    = if ($item.price) { "`$$($item.price.ToString('N0'))" } else { "-" }
    $scoreClr = if ($item.score -ge 8) { "#276749" } elseif ($item.score -ge 6) { "#744210" } else { "#c53030" }
    $url      = if ($item.url) { $item.url } else { "#" }
    $score    = "$($item.score)/10"
    $mkt      = "$($item.market), $($item.state)"
    $beds     = "$($item.beds) BR"
    $why      = $item.why
    $caveat   = $item.caveat
    $addr     = $item.address
    @"
<div style='background:#f7fafc;border-radius:8px;padding:14px 16px;border-left:4px solid $scoreClr;margin-bottom:10px'>
<div style='display:flex;justify-content:space-between;align-items:flex-start;flex-wrap:wrap;gap:6px'>
<div>
<div style='font-weight:700;font-size:.92rem'>$addr</div>
<div style='font-size:.78rem;color:#718096;margin-top:2px'>$mkt · $price · $beds</div>
</div>
<div style='display:flex;align-items:center;gap:8px'>
<span style='font-size:1rem;font-weight:900;color:$scoreClr'>$score</span>
<a href='$url' style='display:inline-block;padding:5px 12px;background:#0f3460;color:#fff;border-radius:6px;font-size:.72rem;font-weight:700;text-decoration:none'>View</a>
</div>
</div>
<div style='margin-top:8px;font-size:.8rem;color:#2d3748'><span style='font-weight:700'>Why:</span> $why</div>
<div style='margin-top:4px;font-size:.78rem;color:#718096'><span style='font-weight:700'>Watch out:</span> $caveat</div>
</div>
"@
}

function Build-TopPicksHtml($markets) {
    if (-not $markets -or $markets.Count -eq 0) {
        return "<div style='color:#718096;font-size:.85rem;padding:10px 0'>Search links unavailable this week.</div>"
    }
    $cards = ($markets | ForEach-Object {
        $name    = $_.name
        $state   = $_.state
        $rfUrl   = $_.redfin
        $zlUrl   = $_.zillow
        $trUrl   = $_.trulia
        @"
<div style='background:#f7fafc;border-radius:8px;padding:10px 14px;border-left:3px solid #0f3460;margin-bottom:8px;display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px'>
<div style='font-weight:700;font-size:.88rem'>$name, $state</div>
<div>
<a href='$rfUrl' style='display:inline-block;padding:4px 11px;background:#d32f2f;color:#fff;border-radius:5px;font-size:.72rem;font-weight:700;text-decoration:none;margin-right:5px'>Redfin</a>
<a href='$zlUrl' style='display:inline-block;padding:4px 11px;background:#0f3460;color:#fff;border-radius:5px;font-size:.72rem;font-weight:700;text-decoration:none;margin-right:5px'>Zillow</a>
<a href='$trUrl' style='display:inline-block;padding:4px 11px;background:#6b21a8;color:#fff;border-radius:5px;font-size:.72rem;font-weight:700;text-decoration:none'>Trulia</a>
</div>
</div>
"@
    }) -join ""
    @"
<div style='font-size:.78rem;color:#718096;margin-bottom:10px'>3+ BR · under `$1,000,000 · single-family · all markets · click to open live search</div>
$cards
"@
}

function Build-WatchlistCard($item) {
    $drop    = [math]::Abs($item.delta)
    $dropPct = [math]::Round(($drop / $item.prevPrice) * 100, 1)
    $curr    = "`$$($item.currPrice.ToString('N0'))"
    $saved   = "`$$($item.savedPrice.ToString('N0'))"
    $dropStr = "`$$($drop.ToString('N0'))"
    $url     = $item.url
    $addr    = $item.address
    $mkt     = $item.market
    $notes   = $item.notes
    $notesHtml = if ($notes) { "<div style='margin-top:6px;font-size:.78rem;color:#718096;font-style:italic'>$notes</div>" } else { "" }
    @"
<div style='background:#fff5f5;border-radius:8px;padding:14px 16px;border-left:4px solid #c53030;margin-bottom:10px'>
<div style='display:flex;justify-content:space-between;align-items:flex-start;flex-wrap:wrap;gap:6px'>
<div>
<div style='font-weight:700;font-size:.92rem'>$addr</div>
<div style='font-size:.78rem;color:#718096;margin-top:2px'>$mkt · Saved at $saved</div>
</div>
<div style='text-align:right'>
<div style='font-size:1rem;font-weight:900;color:#c53030'>▼ $dropStr ($dropPct%)</div>
<div style='font-size:.78rem;color:#718096'>$curr now</div>
</div>
</div>
$notesHtml
<div style='margin-top:8px'><a href='$url' style='display:inline-block;padding:5px 12px;background:#c53030;color:#fff;border-radius:6px;font-size:.72rem;font-weight:700;text-decoration:none'>View Listing</a></div>
</div>
"@
}

# ── Guard: need both files ─────────────────────────────────────────────────────
if (-not (Test-Path $CURRENT_FILE)) {
    Log "ERROR: markets.json not found. Run refresh.ps1 first."; exit 1
}
if (-not (Test-Path $SNAPSHOT_FILE)) {
    Log "No snapshot found - this must be the first run. Saving snapshot for next week."
    Copy-Item $CURRENT_FILE $SNAPSHOT_FILE
    exit 0
}

$current  = Get-Content $CURRENT_FILE  -Raw | ConvertFrom-Json
$snapshot = Get-Content $SNAPSHOT_FILE -Raw | ConvertFrom-Json

# ── Helper formatters ──────────────────────────────────────────────────────────
function FmtMoney([double]$n)   { "`$$([math]::Round($n).ToString('N0'))" }
function FmtRate([double]$r){ "{0:F2}%" -f ($r * 100) }
function Arrow([double]$delta) { if ($delta -gt 0) { "▲" } elseif ($delta -lt 0) { "▼" } else { "->" } }

# ── AI Narrative (optional — needs ANTHROPIC_API_KEY env var) ──────────────────
function Get-AINarrative([string]$Context) {
    $apiKey = $env:ANTHROPIC_API_KEY
    if (-not $apiKey) {
        Log "  AI narrative: ANTHROPIC_API_KEY not set - using template narrative."
        return $null
    }
    Log "  Calling Claude API for AI narrative..."
    try {
        $prompt = @"
You are a real estate market analyst writing a weekly update email for a specific family. Their profile:
- Budget: approximately $700K-$1M (they have $658K in home-sale proceeds for a down payment)
- Two young children — school district quality is their #1 filter
- Commute daily to Midtown Manhattan (LIRR, Metro-North, or NJ Transit)
- Tracking markets in Nassau County LI, Westchester NY, and Essex/Bergen County NJ

This week's data:
$Context

Write exactly 3 sentences of plain-English market narrative for their weekly email. Use specific dollar figures and basis points. Sentence 1: rate environment and what it means for their monthly PITI. Sentence 2: any notable market or price movement (or confirm stability). Sentence 3: one concrete, actionable buyer guidance point for this family specifically. No bullet points, no headers — a single flowing paragraph only.
"@

        $reqBody = [ordered]@{
            model      = "claude-haiku-4-5"
            max_tokens = 300
            messages   = @(@{ role = "user"; content = $prompt })
        } | ConvertTo-Json -Depth 5

        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($reqBody)
        $resp = Invoke-RestMethod `
            -Uri "https://api.anthropic.com/v1/messages" `
            -Method POST `
            -Headers @{
                "x-api-key"         = $apiKey
                "anthropic-version" = "2023-06-01"
                "Content-Type"      = "application/json; charset=utf-8"
            } `
            -Body $bodyBytes -UseBasicParsing

        $text = $resp.content[0].text
        Log ("  AI narrative: OK (" + $text.Length + " chars)")
        return $text
    } catch {
        Log "  WARN: AI narrative failed - $($_.Exception.Message). Falling back to template."
        return $null
    }
}

# ── 1. Diff mortgage rates ─────────────────────────────────────────────────────
$rateChanges = @()
$rateFields  = @("30yr_fixed","20yr_fixed","15yr_fixed")
foreach ($f in $rateFields) {
    $old = $snapshot.mortgage_rates.rates.$f
    $new = $current.mortgage_rates.rates.$f
    if ($old -and $new -and [math]::Abs($new - $old) -gt 0.0001) {
        $bps   = [math]::Round(($new - $old) * 10000)
        $label = $f -replace "_fixed","" -replace "_"," "
        $dir   = if ($bps -gt 0) { "up" } else { "down" }
        $rateChanges += "$label $(FmtRate $new) ($dir $([math]::Abs($bps)) bps from $(FmtRate $old))"
    }
}

# ── 2. Diff market prices ──────────────────────────────────────────────────────
$allCurrent  = @($current.primary_markets)  + @($current.research_markets)
$allSnapshot = @($snapshot.primary_markets) + @($snapshot.research_markets)

$priceChanges = @()
$taxChanges   = @()

foreach ($mkt in $allCurrent) {
    $snap = $allSnapshot | Where-Object { $_.id -eq $mkt.id } | Select-Object -First 1
    if (-not $snap) { continue }

    # Price change
    if ($snap.median_price -and $mkt.median_price -and $snap.median_price -ne $mkt.median_price) {
        $delta    = $mkt.median_price - $snap.median_price
        $deltaPct = [math]::Round(($delta / $snap.median_price) * 100, 1)
        $dir      = if ($delta -gt 0) { "up" } else { "down" }
        $priceChanges += "$(Arrow $delta) **$($mkt.name)** $(FmtMoney $mkt.median_price) ($dir $(FmtMoney ([math]::Abs($delta))), $([math]::Abs($deltaPct))%)"
    }

    # Tax change
    if ($snap.annual_tax -and $mkt.annual_tax -and $snap.annual_tax -ne $mkt.annual_tax) {
        $delta = $mkt.annual_tax - $snap.annual_tax
        $dir   = if ($delta -gt 0) { "up" } else { "down" }
        $taxChanges += "$(Arrow $delta) **$($mkt.name)** tax estimate $(FmtMoney $mkt.annual_tax)/yr ($dir $(FmtMoney ([math]::Abs($delta))))"
    }
}

# ── 3. PITI impact of rate changes ────────────────────────────────────────────
function PITI([double]$price,[double]$down,[double]$rate,[int]$yrs,[double]$tax,[double]$ins=2400){
    $loan=$price-$down; $r=$rate/12; $n=$yrs*12
    $pi=if($r -eq 0){$loan/$n}else{($loan*$r*[math]::Pow(1+$r,$n))/([math]::Pow(1+$r,$n)-1)}
    [math]::Round($pi+$tax/12+$ins/12)
}

$down       = $current.meta.owner_context.net_proceeds
$rate30New  = $current.mortgage_rates.rates."30yr_fixed"
$rate30Old  = $snapshot.mortgage_rates.rates."30yr_fixed"
$pitiImpact = @()

if ([math]::Abs($rate30New - $rate30Old) -gt 0.0001) {
    foreach ($mkt in $allCurrent) {
        $pitiOld = PITI $mkt.median_price $down $rate30Old 30 $mkt.annual_tax
        $pitiNew = PITI $mkt.median_price $down $rate30New 30 $mkt.annual_tax
        $diff    = $pitiNew - $pitiOld
        if ([math]::Abs($diff) -ge 10) {
            $dir = if ($diff -gt 0) { "more" } else { "less" }
            $pitiImpact += "  • $($mkt.name): $(FmtMoney $pitiNew)/mo ($(FmtMoney ([math]::Abs($diff))) $dir/mo)"
        }
    }
}

# ── 4. Best value pick (lowest PITI with school rating >= 8) ───────────────────
$topPick = $allCurrent |
    Where-Object { $_.school_rating_greatschools -ge 8 } |
    Sort-Object { PITI $_.median_price $down $rate30New 30 $_.annual_tax } |
    Select-Object -First 1

$topPickLine = if ($topPick) {
    $piti = PITI $topPick.median_price $down $rate30New 30 $topPick.annual_tax
    "**$($topPick.name), $($topPick.state)** - $(FmtMoney $piti)/mo PITI, $($topPick.school_rating_greatschools)/10 schools, $(FmtMoney $topPick.annual_tax)/yr tax"
} else { "No markets meet the criteria this week." }

# ── 5. Build summary text ──────────────────────────────────────────────────────
$date      = Get-Date -Format "MMMM d, yyyy"
$noChanges = ($rateChanges.Count -eq 0 -and $priceChanges.Count -eq 0 -and $taxChanges.Count -eq 0)

$summaryLines = @()
$summaryLines += "# Housing Market Weekly Update - $date"
$summaryLines += ""
$summaryLines += "## What Changed This Week"
$summaryLines += ""

if ($noChanges) {
    $summaryLines += "No significant changes detected across rates or market prices this week. Data is stable."
} else {
    if ($rateChanges.Count -gt 0) {
        $summaryLines += "### Mortgage Rates"
        $rateChanges | ForEach-Object { $summaryLines += "- $_" }
        $summaryLines += ""
    }
    if ($priceChanges.Count -gt 0) {
        $summaryLines += "### Market Prices"
        $priceChanges | ForEach-Object { $summaryLines += "- $_" }
        $summaryLines += ""
    }
    if ($taxChanges.Count -gt 0) {
        $summaryLines += "### Tax Estimates"
        $taxChanges | ForEach-Object { $summaryLines += "- $_" }
        $summaryLines += ""
    }
}

if ($pitiImpact.Count -gt 0) {
    $summaryLines += "### PITI Impact of Rate Change (30yr @ $(FmtRate $rate30New), $(FmtMoney $down) down)"
    $pitiImpact | ForEach-Object { $summaryLines += $_ }
    $summaryLines += ""
}

$summaryLines += "## Best Value Pick This Week"
$summaryLines += "(Lowest monthly PITI among markets with GreatSchools rating >= 8)"
$summaryLines += ""
$summaryLines += $topPickLine
$summaryLines += ""
$summaryLines += "## Current Rates Snapshot"
$summaryLines += "| Term | Rate |"
$summaryLines += "|------|------|"
$summaryLines += "| 30yr fixed | $(FmtRate $current.mortgage_rates.rates.'30yr_fixed') |"
$summaryLines += "| 20yr fixed | $(FmtRate $current.mortgage_rates.rates.'20yr_fixed') |"
$summaryLines += "| 15yr fixed | $(FmtRate $current.mortgage_rates.rates.'15yr_fixed') |"
$summaryLines += ""
$summaryLines += "---"
$summaryLines += "*Auto-generated by HousingDashboard agent |$date*"

$summaryText = $summaryLines -join "`n"

# ── 6. Save summary to file ────────────────────────────────────────────────────
$summaryText | Set-Content $SUMMARY_FILE -Encoding utf8
Log "Summary saved -> $SUMMARY_FILE"

# ── 6b. Watchlist price drop check ───────────────────────────────────────────
$watchlistDrops = @()
$watchlistItems = @($current.watchlist)
$watchlistSnap  = @($snapshot.watchlist)
foreach ($item in $watchlistItems) {
    if (-not $item.url -or -not $item.saved_price) { continue }
    $prev      = $watchlistSnap | Where-Object { $_.url -eq $item.url } | Select-Object -First 1
    $prevPrice = if ($prev -and $prev.current_price) { $prev.current_price } else { $item.saved_price }
    $currPrice = if ($item.current_price) { $item.current_price } else { $item.saved_price }
    $delta     = $currPrice - $prevPrice
    if ($delta -lt -500) {
        $watchlistDrops += [PSCustomObject]@{
            address    = $item.address
            market     = $item.market
            savedPrice = $item.saved_price
            prevPrice  = $prevPrice
            currPrice  = $currPrice
            delta      = $delta
            url        = $item.url
            notes      = $item.notes
        }
    }
}
$watchlistHtml = if ($watchlistDrops.Count -gt 0) {
    ($watchlistDrops | ForEach-Object { Build-WatchlistCard $_ }) -join ""
} elseif ($watchlistItems.Count -gt 0) {
    "No price drops on your $($watchlistItems.Count) saved listing(s) this week."
} else {
    "No listings saved to watchlist yet. Add via the dashboard Watchlist tab."
}

# ── 6c. Listing scanner (AI-scored top picks) ─────────────────────────────────
$scanFile     = Join-Path $ROOT "data\listings_scan.json"
$topPicksHtml = "Listing scan unavailable this week."
Log "Running listing scanner..."
try {
    & "$PSScriptRoot\scan-listings.ps1" | Out-Null
    if (Test-Path $scanFile) {
        $scored = Get-Content $scanFile -Raw | ConvertFrom-Json
        $topPicksHtml = Build-TopPicksHtml $scored
    }
} catch {
    Log "WARN: scan-listings.ps1 failed - $($_.Exception.Message)"
}

# ── 7. Send email via Gmail SMTP ──────────────────────────────────────────────
$appPassword = $env:GMAIL_APP_PASSWORD
$gmailAddr   = $env:GMAIL_ADDRESS

if (-not $appPassword -or -not $gmailAddr) {
    Log "WARN: GMAIL_APP_PASSWORD or GMAIL_ADDRESS not set - email skipped."
    Log "      Run these once in PowerShell to activate email:"
    Log "      [System.Environment]::SetEnvironmentVariable('GMAIL_ADDRESS','you@gmail.com','User')"
    Log "      [System.Environment]::SetEnvironmentVariable('GMAIL_APP_PASSWORD','xxxx-xxxx-xxxx-xxxx','User')"
    Log "      Get a Gmail App Password at: myaccount.google.com/apppasswords"
    Log "      Summary still saved to: $SUMMARY_FILE"
    exit 0
}

$FromEmail = if ($gmailAddr) { $gmailAddr } else { "domaragonjr@gmail.com" }
Log "Sending weekly summary email to $ToEmail..."

$subject = "Housing Dashboard $date - $(if ($noChanges){'Stable'}else{'Changes detected'})"

# ── Shared helpers ─────────────────────────────────────────────
$allCurrent = @($current.primary_markets) + @($current.research_markets)
$allSnap    = @($snapshot.primary_markets) + @($snapshot.research_markets)

function EmailPITI($price, $rate, $tax, $ins = 2400) {
    $loan = $price - $down; $r = $rate / 12; $n = 360
    $pi = if ($r -eq 0) { $loan/$n } else { ($loan*$r*[math]::Pow(1+$r,$n))/([math]::Pow(1+$r,$n)-1) }
    [math]::Round($pi + $tax/12 + $ins/12)
}
function M($n)    { [string]::Format('{0:C0}', [math]::Round($n)) }
function Pct($n)  { [string]::Format('{0:F2}%', $n) }
function GS($gs)  { if ($gs) { "$gs/10" } else { "-" } }
function TaxClr($r) { if ($r -gt 3) { "#c53030" } elseif ($r -lt 1.6) { "#276749" } else { "#555" } }
function GsClr($g)  { if ($g -ge 9) { "#276749" } elseif ($g -ge 7) { "#744210" } else { "#555" } }

$th = "style='padding:8px 10px;text-align:left;font-weight:700;font-size:.75rem;text-transform:uppercase;letter-spacing:.3px;background:#0f3460;color:#fff'"
$td = "style='padding:8px 10px;border-bottom:1px solid #f0f4f8;font-size:.83rem'"

# ── Section header helper ──────────────────────────────────────
function SectionHeader($title, $icon) {
    "<div style='margin:28px 0 10px;padding:10px 14px;background:#0f3460;border-radius:8px;color:#fff;font-size:.8rem;font-weight:700;text-transform:uppercase;letter-spacing:.6px'>$icon $title</div>"
}

# ── Compare table helpers ───────────────────────────────────────
function CmpCell($val) {
    "<td style='padding:6px 8px;font-size:.8rem;border-bottom:1px solid #e8ecf0;text-align:center;vertical-align:middle'>$val</td>"
}
function CmpRow($label, $cells, $alt) {
    $bg = if ($alt) { "background:#f7fafc" } else { "background:#fff" }
    "<tr style='$bg'><td style='padding:6px 8px;font-size:.75rem;color:#718096;font-weight:600;white-space:nowrap;border-bottom:1px solid #e8ecf0;vertical-align:middle'>$label</td>$cells</tr>"
}
function BuildCmpTbl($markets) {
    $cth = "style='padding:7px 6px;font-size:.68rem;font-weight:700;text-transform:uppercase;background:#0f3460;color:#fff;text-align:center'"
    $mth = "style='padding:7px 6px;font-size:.68rem;font-weight:700;text-transform:uppercase;background:#0f3460;color:#fff;text-align:left;width:110px'"
    $hdrCells = ($markets | ForEach-Object { "<th $cth>$($_.name)</th>" }) -join ""
    $body = ""
    $alt  = $false

    # Median Price
    $cells = ($markets | ForEach-Object { CmpCell (M $_.median_price) }) -join ""
    $body += CmpRow "Median Price" $cells $alt; $alt = -not $alt

    # Zillow ZHVI / YoY
    $cells = ($markets | ForEach-Object {
        if ($_.yoy_pct) {
            $clr  = if ($_.yoy_pct -gt 0) { "#c53030" } else { "#276749" }
            $sign = if ($_.yoy_pct -gt 0) { "+" } else { "" }
            CmpCell "<span style='color:$clr;font-weight:700'>$sign$($_.yoy_pct)%</span>"
        } else { CmpCell "-" }
    }) -join ""
    $body += CmpRow "ZHVI / YoY" $cells $alt; $alt = -not $alt

    # Price / sqft
    $cells = ($markets | ForEach-Object {
        if ($_.price_per_sqft) { CmpCell "`$$($_.price_per_sqft)" } else { CmpCell "-" }
    }) -join ""
    $body += CmpRow "Price / sqft" $cells $alt; $alt = -not $alt

    # Days on Market
    $cells = ($markets | ForEach-Object {
        if ($_.dom) { CmpCell "$($_.dom)d" } else { CmpCell "-" }
    }) -join ""
    $body += CmpRow "Days on Market" $cells $alt; $alt = -not $alt

    # Market Tone
    $cells = ($markets | ForEach-Object {
        if ($_.market_tone) { CmpCell $_.market_tone } else { CmpCell "-" }
    }) -join ""
    $body += CmpRow "Market Tone" $cells $alt; $alt = -not $alt

    # Est. Annual Tax
    $cells = ($markets | ForEach-Object { CmpCell ((M $_.annual_tax) + "/yr") }) -join ""
    $body += CmpRow "Est. Annual Tax" $cells $alt; $alt = -not $alt

    # Monthly Tax Burden
    $cells = ($markets | ForEach-Object { CmpCell ((M ([math]::Round($_.annual_tax / 12))) + "/mo") }) -join ""
    $body += CmpRow "Monthly Tax Burden" $cells $alt; $alt = -not $alt

    # Transit Line
    $cells = ($markets | ForEach-Object {
        if ($_.transit) { CmpCell $_.transit } else { CmpCell "-" }
    }) -join ""
    $body += CmpRow "Transit Line" $cells $alt; $alt = -not $alt

    # Est. Commute to Midtown
    $cells = ($markets | ForEach-Object {
        if ($_.commute_min) { CmpCell "$($_.commute_min.low)-$($_.commute_min.high) min" } else { CmpCell "-" }
    }) -join ""
    $body += CmpRow "Est. Commute" $cells $alt; $alt = -not $alt

    # School District
    $cells = ($markets | ForEach-Object {
        $gs = $_.school_rating_greatschools
        $ni = $_.school_rating_niche
        if ($gs -and $ni)  { CmpCell "$gs/10, Niche $ni" }
        elseif ($gs)       { CmpCell "$gs/10 GS" }
        elseif ($ni)       { CmpCell "Niche $ni" }
        else               { CmpCell "-" }
    }) -join ""
    $body += CmpRow "School District" $cells $alt; $alt = -not $alt

    # Walk Score
    $cells = ($markets | ForEach-Object {
        if ($_.downtown -and $_.downtown.walk_score) { CmpCell "$($_.downtown.walk_score)/100" } else { CmpCell "-" }
    }) -join ""
    $body += CmpRow "Walk Score" $cells $alt; $alt = -not $alt

    # Downtown Walkability Rating
    $cells = ($markets | ForEach-Object {
        if ($_.downtown -and $_.downtown.walkability_rating) {
            $r = $_.downtown.walkability_rating
            $clr = if ($r -ge 9) { "#276749" } elseif ($r -ge 7) { "#744210" } else { "#c53030" }
            CmpCell "<span style='color:$clr;font-weight:700'>$r/10</span>"
        } else { CmpCell "-" }
    }) -join ""
    $body += CmpRow "Downtown Walk" $cells $alt; $alt = -not $alt

    # Downtown Verdict
    $cells = ($markets | ForEach-Object {
        if ($_.downtown -and $_.downtown.verdict) {
            CmpCell "<span style='font-size:.72rem;font-style:italic;color:#718096'>$($_.downtown.verdict)</span>"
        } else { CmpCell "-" }
    }) -join ""
    $body += CmpRow "Downtown Verdict" $cells $alt

    "<table style='width:100%;border-collapse:collapse'><thead><tr><th $mth>Metric</th>$hdrCells</tr></thead><tbody>$body</tbody></table>"
}

# ══════════════════════════════════════════════════════════════
# 1. WHAT CHANGED
# ══════════════════════════════════════════════════════════════
$changedRows = ""
if ($rateChanges.Count -gt 0) {
    $changedRows += "<tr><td style='padding:7px 0;color:#718096;font-size:.8rem;width:90px;vertical-align:top'>Rates</td><td style='padding:7px 0;font-size:.85rem'>" + ($rateChanges -join "<br>") + "</td></tr>"
}
if ($priceChanges.Count -gt 0) {
    $changedRows += "<tr><td style='padding:7px 0;color:#718096;font-size:.8rem;vertical-align:top'>Prices</td><td style='padding:7px 0;font-size:.85rem'>" + ($priceChanges -join "<br>") + "</td></tr>"
}
if ($noChanges) {
    $changedRows = "<tr><td colspan='2' style='padding:7px 0;color:#276749;font-size:.85rem'>No significant changes since last update. Data is stable.</td></tr>"
}

# ══════════════════════════════════════════════════════════════
# 2. BEST VALUE PICK
# ══════════════════════════════════════════════════════════════
$bestHtml = ""
if ($topPick) {
    $bp = EmailPITI $topPick.median_price $rate30New $topPick.annual_tax
    $bestHtml = "<div style='background:linear-gradient(135deg,#0f3460,#16213e);color:#fff;border-radius:10px;padding:16px 20px;margin:12px 0'>" +
        "<div style='font-size:.7rem;opacity:.7;text-transform:uppercase;letter-spacing:.6px'>Best Value Pick</div>" +
        "<div style='font-size:1.15rem;font-weight:800;margin:4px 0'>$($topPick.name), $($topPick.state)</div>" +
        "<div style='font-size:.85rem;opacity:.85'>" + (M $bp) + "/mo PITI &nbsp;|&nbsp; $($topPick.school_rating_greatschools)/10 schools &nbsp;|&nbsp; " + (M $topPick.annual_tax) + "/yr tax</div>" +
        "</div>"
}

# ══════════════════════════════════════════════════════════════
# 3. OVERVIEW — all markets
# ══════════════════════════════════════════════════════════════
$overviewRows = ""
foreach ($m in ($allCurrent | Sort-Object { EmailPITI $_.median_price $rate30New $_.annual_tax })) {
    $p = EmailPITI $m.median_price $rate30New $m.annual_tax
    $overviewRows += "<tr>" +
        "<td $td style='font-weight:700;padding:8px 10px;border-bottom:1px solid #f0f4f8'>$($m.name)</td>" +
        "<td $td style='color:#718096;padding:8px 10px;border-bottom:1px solid #f0f4f8'>$($m.state)</td>" +
        "<td $td style='font-weight:700;padding:8px 10px;border-bottom:1px solid #f0f4f8'>" + (M $m.median_price) + "</td>" +
        "<td $td style='color:$(TaxClr $m.tax_rate_pct);font-weight:700;padding:8px 10px;border-bottom:1px solid #f0f4f8'>" + (Pct $m.tax_rate_pct) + "</td>" +
        "<td $td style='padding:8px 10px;border-bottom:1px solid #f0f4f8'>" + (M $m.annual_tax) + "/yr</td>" +
        "<td $td style='font-weight:800;color:#e94560;padding:8px 10px;border-bottom:1px solid #f0f4f8'>" + (M $p) + "/mo</td>" +
        "<td $td style='color:$(GsClr $m.school_rating_greatschools);font-weight:700;padding:8px 10px;border-bottom:1px solid #f0f4f8'>" + (GS $m.school_rating_greatschools) + "</td>" +
        "<td $td style='color:#718096;font-size:.75rem;padding:8px 10px;border-bottom:1px solid #f0f4f8'>$($m.transit)</td>" +
        "</tr>"
}

# ══════════════════════════════════════════════════════════════
# 4. COMPARE — metrics x markets
# ══════════════════════════════════════════════════════════════
$compareHtml =
    "<div style='font-size:.72rem;color:#718096;font-weight:700;margin:4px 0 8px;text-transform:uppercase;letter-spacing:.4px'>Primary Markets</div>" +
    (BuildCmpTbl $current.primary_markets) +
    "<div style='font-size:.72rem;color:#718096;font-weight:700;margin:18px 0 8px;text-transform:uppercase;letter-spacing:.4px'>Research Markets</div>" +
    (BuildCmpTbl $current.research_markets)

# ══════════════════════════════════════════════════════════════
# 5. WEEKLY CHANGES — rates bps, price delta, rank shifts, purchasing power
# ══════════════════════════════════════════════════════════════
# Rate bps cards
$rateCards = ""
foreach ($f in @("30yr_fixed","20yr_fixed","15yr_fixed")) {
    $cur = $current.mortgage_rates.rates.$f
    $prv = if ($snapshot.mortgage_rates.rates.$f) { $snapshot.mortgage_rates.rates.$f } else { $cur }
    $bps = [math]::Round(($cur - $prv) * 10000)
    $clr = if ($bps -gt 0) { "#c53030" } elseif ($bps -lt 0) { "#276749" } else { "#718096" }
    $lbl = $f -replace "_fixed","" -replace "_"," "
    $bpsTxt = if ($bps -ne 0) { "$(if ($bps -gt 0){'+'})$bps bps" } else { "No change" }
    $rateCards += "<td style='width:33%;padding:0 6px 0 0;vertical-align:top'>" +
        "<div style='background:#f7fafc;border-radius:8px;padding:12px;border-top:3px solid $clr'>" +
        "<div style='font-size:.72rem;color:#718096;text-transform:uppercase'>$lbl</div>" +
        "<div style='font-size:1.3rem;font-weight:900;color:#0f3460'>" + (Pct ($cur * 100)) + "</div>" +
        "<div style='font-size:.8rem;font-weight:700;color:$clr'>$bpsTxt</div>" +
        "</div></td>"
}

# Price + PITI change rows
$weeklyRows = ""
foreach ($m in ($allCurrent | Sort-Object { EmailPITI $_.median_price $rate30New $_.annual_tax })) {
    $s      = $allSnap | Where-Object { $_.id -eq $m.id } | Select-Object -First 1
    $pPrev  = if ($s) { $s.median_price } else { $m.median_price }
    $tPrev  = if ($s) { $s.annual_tax }   else { $m.annual_tax }
    $rPrev  = if ($snapshot.mortgage_rates.rates."30yr_fixed") { $snapshot.mortgage_rates.rates."30yr_fixed" } else { $rate30New }
    $delta  = $m.median_price - $pPrev
    $pct    = if ($pPrev) { [math]::Round(($delta / $pPrev) * 100, 1) } else { 0 }
    $ppiti  = EmailPITI $pPrev $rPrev $tPrev
    $npiti  = EmailPITI $m.median_price $rate30New $m.annual_tax
    $pd     = $npiti - $ppiti
    $pc     = if ($delta -lt 0) { "#276749" } elseif ($delta -gt 0) { "#c53030" } else { "#a0aec0" }
    $tc     = if ($pd -lt 0) { "#276749" } elseif ($pd -gt 0) { "#c53030" } else { "#a0aec0" }
    $none   = ($delta -eq 0 -and $pd -eq 0)
    $trStyle = if ($none) { "opacity:.45" } else { "" }
    $dTxt  = if ($delta -eq 0) { "-" } else { "$(if ($delta -gt 0){'+'})$(M $delta)" }
    $pTxt  = if ($delta -eq 0) { "-" } else { "$(if ($pct -gt 0){'+'})$pct%" }
    $pdTxt = if ($pd -eq 0)    { "-" } else { "$(if ($pd -gt 0){'+'})$(M $pd)/mo" }
    $weeklyRows += "<tr style='$trStyle'>" +
        "<td $td style='font-weight:700;padding:8px 10px;border-bottom:1px solid #f0f4f8'>$($m.name)</td>" +
        "<td $td style='color:#718096;padding:8px 10px;border-bottom:1px solid #f0f4f8'>$($m.state)</td>" +
        "<td $td style='font-weight:700;padding:8px 10px;border-bottom:1px solid #f0f4f8'>" + (M $m.median_price) + "</td>" +
        "<td $td style='font-weight:700;color:$pc;padding:8px 10px;border-bottom:1px solid #f0f4f8'>$dTxt</td>" +
        "<td $td style='color:$pc;font-weight:700;padding:8px 10px;border-bottom:1px solid #f0f4f8'>$pTxt</td>" +
        "<td $td style='color:#718096;padding:8px 10px;border-bottom:1px solid #f0f4f8'>" + (M $ppiti) + "</td>" +
        "<td $td style='font-weight:700;padding:8px 10px;border-bottom:1px solid #f0f4f8'>" + (M $npiti) + "</td>" +
        "<td $td style='font-weight:700;color:$tc;padding:8px 10px;border-bottom:1px solid #f0f4f8'>$pdTxt</td>" +
        "</tr>"
}

# Affordability rank shifts
$rPrev   = if ($snapshot.mortgage_rates.rates."30yr_fixed") { $snapshot.mortgage_rates.rates."30yr_fixed" } else { $rate30New }
$rankNow = $allCurrent | Sort-Object { EmailPITI $_.median_price $rate30New $_.annual_tax }

# Pre-compute each market's previous PITI (no inline if inside Sort-Object)
$prevPitiObjs = foreach ($mkt in $allCurrent) {
    $mktId  = $mkt.id
    $sv     = $allSnap | Where-Object { $_.id -eq $mktId } | Select-Object -First 1
    $pPrice = if ($sv -and $sv.median_price) { $sv.median_price } else { $mkt.median_price }
    $pTax   = if ($sv -and $sv.annual_tax)   { $sv.annual_tax }   else { $mkt.annual_tax }
    [PSCustomObject]@{ id = $mktId; prevPiti = (EmailPITI $pPrice $rPrev $pTax) }
}
$rankPrevIds = @($prevPitiObjs | Sort-Object prevPiti | ForEach-Object { $_.id })

$rankRows    = ""
$rankNowList = @($rankNow)
for ($i = 0; $i -lt $rankNowList.Count; $i++) {
    $m    = $rankNowList[$i]
    $pr   = [array]::IndexOf($rankPrevIds, $m.id)
    $move = $pr - $i
    $mt   = if ($move -eq 0) { "<span style='color:#a0aec0'>No change</span>" } `
            elseif ($move -gt 0) { "<span style='color:#276749;font-weight:700'>Up $move</span>" } `
            else { "<span style='color:#c53030;font-weight:700'>Down $([math]::Abs($move))</span>" }
    $rankRows += "<tr>" +
        "<td $td style='font-weight:700;padding:7px 10px;border-bottom:1px solid #f0f4f8'>$($m.name), $($m.state)</td>" +
        "<td $td style='color:#718096;padding:7px 10px;border-bottom:1px solid #f0f4f8'>#$($pr+1)</td>" +
        "<td $td style='font-weight:700;padding:7px 10px;border-bottom:1px solid #f0f4f8'>#$($i+1)</td>" +
        "<td $td style='padding:7px 10px;border-bottom:1px solid #f0f4f8'>$mt</td>" +
        "<td $td style='font-weight:700;color:#e94560;padding:7px 10px;border-bottom:1px solid #f0f4f8'>" + (M (EmailPITI $m.median_price $rate30New $m.annual_tax)) + "/mo</td>" +
        "</tr>"
}

# Purchasing power
$avgTax  = [math]::Round(($allCurrent | Measure-Object -Property annual_tax -Average).Average)
function MaxHome($rate, $maxP = 5000) {
    $lo = 100000; $hi = 3000000
    for ($i = 0; $i -lt 40; $i++) {
        $mid = ($lo + $hi) / 2
        if ((EmailPITI $mid $rate $avgTax) -le $maxP) { $lo = $mid } else { $hi = $mid }
    }
    [math]::Round($lo)
}
$pwNow  = MaxHome $rate30New
$pwPrev = MaxHome $rPrev
$pwD    = $pwNow - $pwPrev
$pwClr  = if ($pwD -ge 0) { "#276749" } else { "#c53030" }
$pwSign = if ($pwD -ge 0) { "+" } else { "" }

# ══════════════════════════════════════════════════════════════
# NARRATIVE SUMMARY
# ══════════════════════════════════════════════════════════════

# Best commute (primary markets with commute_min data)
$bestCommute = $current.primary_markets |
    Where-Object { $_.commute_min } |
    Sort-Object { $_.commute_min.low } |
    Select-Object -First 1
$bestCommuteText = if ($bestCommute) {
    "$($bestCommute.name), $($bestCommute.state) ($($bestCommute.commute_min.low)-$($bestCommute.commute_min.high) min via $($bestCommute.transit))"
} else { "N/A" }

# Best schools (all markets)
$bestSchool = $allCurrent |
    Where-Object { $_.school_rating_greatschools } |
    Sort-Object school_rating_greatschools -Descending |
    Select-Object -First 1
$bestSchoolText = if ($bestSchool) {
    "$($bestSchool.name), $($bestSchool.state) ($($bestSchool.school_rating_greatschools)/10 GreatSchools)"
} else { "N/A" }

# Average price across all markets
$avgMarketPrice = [math]::Round(($allCurrent | Measure-Object -Property median_price -Average).Average)

# Best pick in $700K-$1M budget: lowest PITI in range
$inBudget     = $allCurrent | Where-Object { $_.median_price -ge 700000 -and $_.median_price -le 1000000 }
$bestInBudget = $inBudget | Sort-Object { EmailPITI $_.median_price $rate30New $_.annual_tax } | Select-Object -First 1
$bestInBudgetText = if ($bestInBudget) {
    $bpiti = EmailPITI $bestInBudget.median_price $rate30New $bestInBudget.annual_tax
    $bgs   = if ($bestInBudget.school_rating_greatschools) { ", $($bestInBudget.school_rating_greatschools)/10 schools" } else { "" }
    "$($bestInBudget.name), $($bestInBudget.state) at " + (M $bestInBudget.median_price) + " (" + (M $bpiti) + "/mo PITI$bgs)"
} else { "No markets currently fall in this range." }

# ── Build AI context string ────────────────────────────────────────────────────
$rateShift = if ([math]::Abs($rate30New - $rate30Old) -gt 0.0001) {
    $bps = [math]::Round(($rate30New - $rate30Old) * 10000)
    if ($bps -gt 0) { " (up $bps bps from prior week)" } else { " (down $([math]::Abs($bps)) bps from prior week)" }
} else { " (unchanged from prior week)" }

$marketLines = ($allCurrent | ForEach-Object {
    $p    = EmailPITI $_.median_price $rate30New $_.annual_tax
    $comm = if ($_.commute_min) { "$($_.commute_min.low)-$($_.commute_min.high) min to Midtown" } else { "commute N/A" }
    $gs   = if ($_.school_rating_greatschools) { "$($_.school_rating_greatschools)/10 GS" } else { "schools N/A" }
    "  - $($_.name), $($_.state): " + (M $_.median_price) + " median / " + (M $p) + "/mo PITI, $gs, $comm"
}) -join "`n"

$rateChangeStr  = if ($rateChanges.Count -gt 0)  { "Rate changes this week: "  + ($rateChanges  -join "; ") } else { "Rates: no significant change this week" }
$priceChangeStr = if ($priceChanges.Count -gt 0) { "Price changes this week: " + ($priceChanges -join "; ") } else { "Prices: stable, no changes detected" }

$aiContext = "30yr fixed: " + (FmtRate $rate30New) + $rateShift + "`n" +
    "Markets:`n" + $marketLines + "`n" +
    $rateChangeStr + "`n" +
    $priceChangeStr + "`n" +
    "Best value pick (lowest PITI, GreatSchools >= 8): $topPickLine" + "`n" +
    "Markets in target budget range ($700K-$1M): $($inBudget.Count) of $($allCurrent.Count)"

$aiText = Get-AINarrative $aiContext
$narrativeMode = if ($aiText) { "AI-generated (Claude)" } else { "template" }
Log "Narrative mode: $narrativeMode"

# ── Narrative section: AI if available, template fallback ──────────────────────
$summaryTitle = if ($aiText) { "AI Market Narrative" } else { "Market Summary" }
$summaryBadge = if ($aiText) {
    "<span style='font-size:.65rem;background:#dbeafe;color:#1d4ed8;padding:2px 8px;border-radius:4px;font-weight:700;margin-left:8px;letter-spacing:.3px'>CLAUDE</span>"
} else { "" }
$summaryBody = if ($aiText) {
    "<p style='margin:0 0 14px;font-size:.9rem;color:#2d3748;line-height:1.75;font-style:italic'>$aiText</p>"
} else {
    "<p style='margin:0 0 10px;font-size:.88rem;color:#2d3748;line-height:1.6'>" +
    "Across all $($allCurrent.Count) tracked markets, the average home price is <strong>" + (M $avgMarketPrice) + "</strong> as of $($current.mortgage_rates.as_of), " +
    "with the 30-year fixed rate at <strong>" + (Pct ($rate30New * 100)) + "</strong>. " +
    "Your target budget of <strong>`$700K-`$1M</strong> covers $($inBudget.Count) of $($allCurrent.Count) markets." +
    "</p>"
}

$narrativeHtml =
    "<div style='background:#f0f4f8;border-radius:10px;padding:18px 20px;margin-bottom:22px'>" +
    "<div style='display:flex;align-items:center;gap:8px;margin-bottom:12px'>" +
    "<div style='font-size:.72rem;font-weight:700;text-transform:uppercase;letter-spacing:.6px;color:#0f3460'>$summaryTitle</div>$summaryBadge" +
    "</div>" +
    $summaryBody +
    "<table style='width:100%;border-collapse:collapse'>" +
    "<tr><td style='padding:5px 10px 5px 0;font-size:.82rem;color:#718096;width:160px;vertical-align:top'>Best commute</td>" +
    "<td style='padding:5px 0;font-size:.85rem;color:#1a202c;font-weight:600'>$bestCommuteText</td></tr>" +
    "<tr><td style='padding:5px 10px 5px 0;font-size:.82rem;color:#718096;vertical-align:top'>Best schools</td>" +
    "<td style='padding:5px 0;font-size:.85rem;color:#1a202c;font-weight:600'>$bestSchoolText</td></tr>" +
    "<tr><td style='padding:5px 10px 5px 0;font-size:.82rem;color:#718096;vertical-align:top'>Best pick `$700K-`$1M</td>" +
    "<td style='padding:5px 0;font-size:.85rem;color:#e94560;font-weight:700'>$bestInBudgetText</td></tr>" +
    "</table>" +
    "</div>"

# ══════════════════════════════════════════════════════════════
# ══════════════════════════════════════════════════════════════
# LISTING PULSE — pre-filtered search links per primary market
# ══════════════════════════════════════════════════════════════
# Search filters: 4+ beds, max $950K, single-family homes
$maxPrice = 1000000

# URL slugs for each primary market (Redfin state/city, Zillow city-state)
$listingUrls = @{
    fp  = @{ redfin = "NY/Floral-Park";       zillow = "floral-park-ny" }
    rvc = @{ redfin = "NY/Rockville-Centre";  zillow = "rockville-centre-ny" }
    mw  = @{ redfin = "NJ/Maplewood";         zillow = "maplewood-nj" }
    plh = @{ redfin = "NY/Pelham";            zillow = "pelham-ny" }
}

$btnStyle = "display:inline-block;padding:6px 14px;border-radius:6px;font-size:.75rem;font-weight:700;text-decoration:none;margin-right:6px"
$rfBtnStyle  = "$btnStyle;background:#d32f2f;color:#fff"
$zlBtnStyle  = "$btnStyle;background:#0f3460;color:#fff"

$pulseCards = ($current.primary_markets | ForEach-Object {
    $m    = $_
    $p    = EmailPITI $m.median_price $rate30New $m.annual_tax
    $dom  = if ($m.dom) { "$($m.dom)d DOM" } else { "DOM N/A" }
    $tone = if ($m.market_tone) { $m.market_tone } else { "" }
    $urls = $listingUrls[$m.id]
    $rfUrl = "https://www.redfin.com/$($urls.redfin)/filter/max-price=$maxPrice,min-beds=3,property-type=house"
    $zlUrl = "https://www.zillow.com/$($urls.zillow)/3-beds/?price=0-$maxPrice"

    "<div style='background:#f7fafc;border-radius:8px;padding:14px 16px;border-left:3px solid #0f3460;margin-bottom:10px'>" +
    "<div style='display:flex;justify-content:space-between;align-items:flex-start;flex-wrap:wrap;gap:8px'>" +
    "<div>" +
    "<div style='font-weight:700;font-size:.92rem'>$($m.name), $($m.state)</div>" +
    "<div style='font-size:.78rem;color:#718096;margin-top:3px'>" +
    (M $m.median_price) + " median &nbsp;·&nbsp; " + (M $p) + "/mo PITI &nbsp;·&nbsp; $dom" +
    $(if ($tone) { " &nbsp;·&nbsp; $tone" } else { "" }) +
    "</div>" +
    "</div>" +
    "<div style='white-space:nowrap'>" +
    "<a href='$rfUrl' style='$rfBtnStyle'>Redfin ↗</a>" +
    "<a href='$zlUrl' style='$zlBtnStyle'>Zillow ↗</a>" +
    "</div></div></div>"
}) -join ""

$listingPulseHtml =
    "<div style='font-size:.78rem;color:#718096;margin-bottom:12px'>4+ bedrooms &nbsp;·&nbsp; under $(M $maxPrice) &nbsp;·&nbsp; single-family &nbsp;·&nbsp; primary markets only &nbsp;·&nbsp; click to open live search</div>" +
    $pulseCards

# ══════════════════════════════════════════════════════════════
# BUILD FULL EMAIL HTML
# ══════════════════════════════════════════════════════════════
$W = "style='max-width:680px;margin:0 auto;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;color:#1a202c'"

$htmlBody = "<!DOCTYPE html><html><body style='margin:0;padding:0;background:#f0f4f8'><div $W>" +

    # Header
    "<div style='background:linear-gradient(135deg,#0f3460,#16213e);padding:22px 24px;color:#fff'>" +
    "<div style='display:flex;justify-content:space-between;align-items:flex-start;flex-wrap:wrap;gap:10px'>" +
    "<div><div style='font-size:1.2rem;font-weight:800'>Housing Market Dashboard</div>" +
    "<div style='font-size:.8rem;opacity:.7;margin-top:3px'>$date &nbsp;|&nbsp; Auto-generated weekly update</div></div>" +
    "<a href='https://domaragonjr-093017.github.io/Housing-Investment-Dashboard/' style='display:inline-block;background:rgba(255,255,255,0.15);color:#fff;text-decoration:none;font-size:.75rem;font-weight:700;padding:7px 14px;border-radius:6px;border:1px solid rgba(255,255,255,0.3);white-space:nowrap'>View Live Dashboard &rarr;</a>" +
    "</div></div>" +

    "<div style='background:#fff;padding:20px 24px'>" +

    # Narrative summary
    $narrativeHtml +

    # What Changed
    (SectionHeader "What Changed" "") +
    "<table style='width:100%'><tbody>$changedRows</tbody></table>" +

    # Rates bar
    "<div style='margin:20px 0 8px;font-size:.75rem;font-weight:700;text-transform:uppercase;letter-spacing:.5px;color:#718096'>Current Mortgage Rates</div>" +
    "<table style='width:100%;border-collapse:collapse'><tr>$rateCards</tr></table>" +

    # Overview
    (SectionHeader "Overview" "") +
    "<table style='width:100%;border-collapse:collapse'>" +
    "<thead><tr>" +
    "<th $th>Market</th><th $th>St</th><th $th>Price</th><th $th>Tax Rate</th><th $th>Ann Tax</th><th $th>PITI/mo</th><th $th>Schools</th><th $th>Transit</th>" +
    "</tr></thead><tbody>$overviewRows</tbody></table>" +

    # Compare
    (SectionHeader "Compare" "") +
    $compareHtml +

    # Weekly Changes
    (SectionHeader "Weekly Changes" "") +
    "<table style='width:100%;border-collapse:collapse'>" +
    "<thead><tr>" +
    "<th $th>Market</th><th $th>St</th><th $th>Price</th><th $th>Price Chg</th><th $th>%</th><th $th>PITI Prev</th><th $th>PITI Now</th><th $th>PITI Chg</th>" +
    "</tr></thead><tbody>$weeklyRows</tbody></table>" +

    "<div style='margin-top:16px;background:#f7fafc;border-radius:8px;padding:14px;border-left:4px solid $pwClr'>" +
    "<div style='font-size:.75rem;color:#718096;text-transform:uppercase;letter-spacing:.4px;margin-bottom:4px'>Purchasing Power (max home at `$5,000/mo PITI)</div>" +
    "<div style='font-size:1.1rem;font-weight:800;color:#0f3460'>" + (M $pwNow) + " <span style='font-size:.85rem;font-weight:600;color:$pwClr'>$pwSign$(M $pwD) vs prior</span></div>" +
    "<div style='font-size:.75rem;color:#a0aec0;margin-top:2px'>Prior period max: " + (M $pwPrev) + " &nbsp;|&nbsp; Avg tax used: " + (M $avgTax) + "/yr</div>" +
    "</div>" +

    "</div>" +

    # ── Listing Pulse ──────────────────────────────────────────────────────────
    (SectionHeader "Listing Pulse" "🏠") +
    $listingPulseHtml +

    "</div>" +

    # Footer
    "<div style='padding:12px 24px;background:#16213e;font-size:.72rem;color:#718096;display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:6px'>" +
    "<span>PITI = Principal + Interest + Tax + Insurance &nbsp;|&nbsp; " + (M $down) + " down assumed &nbsp;|&nbsp; Rates as of $($current.mortgage_rates.as_of)</span>" +
    "<a href='https://domaragonjr-093017.github.io/Housing-Investment-Dashboard/' style='color:#93c5fd;text-decoration:none;font-weight:600'>Live Dashboard &rarr;</a>" +
    "</div></div></body></html>"

try {
    $smtp                       = New-Object System.Net.Mail.SmtpClient("smtp.gmail.com", 587)
    $smtp.EnableSsl             = $true
    $smtp.DeliveryMethod        = [System.Net.Mail.SmtpDeliveryMethod]::Network
    $smtp.UseDefaultCredentials = $false
    $smtp.Credentials           = New-Object System.Net.NetworkCredential($gmailAddr, $appPassword)

    $msg            = New-Object System.Net.Mail.MailMessage
    $msg.From       = $gmailAddr
    $msg.To.Add($ToEmail)
    $msg.To.Add("Laurencgrant@gmail.com")
    $msg.To.Add("LouieVAragon@gmail.com")
    $msg.Subject    = $subject
    $msg.IsBodyHtml = $true
    # Inject Watchlist Alerts + Top Picks before the email footer
    $footerMarker = "<div style='padding:12px 24px;background:#16213e"
    $footerIdx    = $htmlBody.IndexOf($footerMarker)
    if ($footerIdx -gt 0) {
        $wlHeader  = "<div style='margin:28px 0 10px;padding:10px 14px;background:#0f3460;border-radius:8px;color:#fff;font-size:.8rem;font-weight:700;text-transform:uppercase;letter-spacing:.6px'>Watchlist Alerts</div>"
        $tpHeader  = "<div style='margin:28px 0 10px;padding:10px 14px;background:#0f3460;border-radius:8px;color:#fff;font-size:.8rem;font-weight:700;text-transform:uppercase;letter-spacing:.6px'>Search All Markets</div>"
        $injection = $wlHeader + $watchlistHtml + $tpHeader + $topPicksHtml
        $htmlBody  = $htmlBody.Substring(0, $footerIdx) + $injection + $htmlBody.Substring($footerIdx)
    }
    $msg.Body       = $htmlBody

    $smtp.Send($msg)
    Log "Email sent to $ToEmail"
} catch {
    Log "ERROR sending email: $($_.Exception.Message)"
    Log "Summary is still saved at: $SUMMARY_FILE"
}

# ── 8. Roll snapshot forward ───────────────────────────────────────────────────
Copy-Item $CURRENT_FILE $SNAPSHOT_FILE -Force
Log "Snapshot updated for next week's diff."

<#
==============================================================================
  GMAIL APP PASSWORD SETUP (one-time, ~2 minutes)
==============================================================================
  Gmail requires an App Password - your regular Google password won't work.
  You must have 2-Step Verification enabled on your Google account first.

  Steps:
  1. Go to: https://myaccount.google.com/apppasswords
  2. Under "App name" type: HousingDashboard -> click Create
  3. Copy the 16-character password shown (you only see it once)
  4. Run these two commands in PowerShell to save permanently:

     [System.Environment]::SetEnvironmentVariable("GMAIL_ADDRESS", "domaragonjr@gmail.com", "User")
     [System.Environment]::SetEnvironmentVariable("GMAIL_APP_PASSWORD", "xxxx xxxx xxxx xxxx", "User")

  To test immediately (current session only):
     $env:GMAIL_ADDRESS = "domaragonjr@gmail.com"
     $env:GMAIL_APP_PASSWORD = "xxxx xxxx xxxx xxxx"
     .\scripts\summarize.ps1

  Your password is NEVER stored in any file - only in your Windows env vars.
  The weekly summary is always saved to exports/weekly_summary.md regardless.
==============================================================================
#>
