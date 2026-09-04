# refresh.ps1 - Housing Market Dashboard Data Refresher
#
# Usage:
#   .\scripts\refresh.ps1                  # full refresh (rates + prices)
#   .\scripts\refresh.ps1 -RatesOnly       # mortgage rates only
#   .\scripts\refresh.ps1 -PricesOnly      # market prices only
#   .\scripts\refresh.ps1 -DryRun          # preview without writing
#
# Env vars (optional):
#   $env:FRED_API_KEY  - free key from https://fred.stlouisfed.org/docs/api/api_key.html
#                        Without it, rates section is skipped gracefully.

param(
    [switch]$RatesOnly,
    [switch]$PricesOnly,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ROOT          = Split-Path $PSScriptRoot -Parent
$DATA_FILE     = Join-Path $ROOT "data\markets.json"
$SNAPSHOT_FILE = Join-Path $ROOT "data\markets_snapshot.json"
$LOG_PREFIX    = "[refresh]"

function Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "$LOG_PREFIX $ts  $msg"
}

function Today { Get-Date -Format "yyyy-MM-dd" }

# Parse a Zillow ZHVI CSV into a "City|State" -> latest price lookup (+ as-of date)
# Uses WebClient.DownloadString to ensure proper UTF-8 text decoding for large CSVs
# (Invoke-WebRequest returns raw bytes for large files in PS 5.1, breaking -split)
function Build-ZillowLookup($url) {
    $wc      = New-Object System.Net.WebClient
    $csvText = $wc.DownloadString($url)
    $lines   = $csvText -split "`n"
    if (-not $lines -or $lines.Length -lt 2) { throw "Empty or unreadable CSV from $url" }
    $headers = $lines[0] -split ","
    $lastCol = $headers.Length - 1
    $date    = $headers[$lastCol].Trim()
    $lookup  = @{}
    for ($i = 1; $i -lt $lines.Length; $i++) {
        $cols = $lines[$i] -split ","
        if ($cols.Length -le $lastCol) { continue }
        $city  = $cols[2].Trim()
        $state = $cols[4].Trim()
        $val   = $cols[$lastCol]
        if ($city -and $state -and $val -match '^\d') {
            $lookup["$city|$state"] = [math]::Round([double]$val)
        }
    }
    return @{ lookup = $lookup; date = $date }
}

# -- Load data ------------------------------------------------------------------
if (-not (Test-Path $DATA_FILE)) {
    Log "ERROR: $DATA_FILE not found."
    exit 1
}
$data    = Get-Content $DATA_FILE -Raw | ConvertFrom-Json
$changed = $false

Log "=== Housing Market Refresh Starting ==="
if ($DryRun) { Log "DRY RUN - no files will be written." }

# Save pre-refresh snapshot so summarize.ps1 can diff old vs new
if (-not $DryRun -and (Test-Path $DATA_FILE)) {
    Copy-Item $DATA_FILE $SNAPSHOT_FILE -Force
    Log "Snapshot saved -> $SNAPSHOT_FILE"
}

# -- 1. Mortgage Rates (FRED API) -----------------------------------------------
if (-not $PricesOnly) {
    $fredKey = $env:FRED_API_KEY
    if (-not $fredKey) {
        Log "WARN: FRED_API_KEY not set - skipping live rate fetch."
        Log "      Get a free key at: https://fred.stlouisfed.org/docs/api/api_key.html"
        Log "      Then set it with: `$env:FRED_API_KEY = 'your_key_here'"
    } else {
        Log "Fetching mortgage rates from FRED..."
        try {
            $base   = "https://api.stlouisfed.org/fred/series/observations"
            $params = "api_key=$fredKey&file_type=json&sort_order=desc&limit=1"

            $r30 = Invoke-RestMethod "$base`?series_id=MORTGAGE30US&$params"
            $r15 = Invoke-RestMethod "$base`?series_id=MORTGAGE15US&$params"

            $rate30 = [double]$r30.observations[0].value / 100
            $rate15 = [double]$r15.observations[0].value / 100
            $rate20 = [math]::Round(($rate30 + $rate15) / 2 + 0.001, 4)

            Log ("  30yr: {0:P2}  |  20yr: {1:P2}  |  15yr: {2:P2}" -f $rate30, $rate20, $rate15)

            $data.mortgage_rates.rates."30yr_fixed" = $rate30
            $data.mortgage_rates.rates."20yr_fixed" = $rate20
            $data.mortgage_rates.rates."15yr_fixed" = $rate15
            $data.mortgage_rates.as_of              = Today
            $data.mortgage_rates.rate_driver        = "(auto-updated by refresh.ps1)"
            $changed = $true
        } catch {
            Log "WARN: FRED fetch failed - $($_.Exception.Message). Rates unchanged."
        }
    }
}

# -- 2. Investment Rates (FRED: Treasury, Bonds, S&P 500) ----------------------
if (-not $PricesOnly) {
    Log "Fetching investment market rates..."
    try {
        & "$PSScriptRoot\fetch-investment-rates.ps1"
    } catch {
        Log "WARN: fetch-investment-rates.ps1 failed -- $($_.Exception.Message)"
    }
}

# -- 3. Market Prices (Zillow ZHVI public CSV) ----------------------------------
if (-not $RatesOnly) {
    Log "Fetching Zillow ZHVI data..."

    # Zillow ZHVI public CSVs -- two series:
    #   ALL = single-family + condo/co-op combined (default for most markets)
    #   SFR = single-family homes ONLY (EXCLUDES condos / co-ops / apartments)
    $CSV_URL_ALL = "https://files.zillowstatic.com/research/public_csvs/zhvi/City_zhvi_uc_sfrcondo_tier_0.33_0.67_sm_sa_month.csv"
    $CSV_URL_SFR = "https://files.zillowstatic.com/research/public_csvs/zhvi/City_zhvi_uc_sfr_tier_0.33_0.67_sm_sa_month.csv"

    # Market lookup: id -> city + state as they appear in Zillow CSV.
    #   sfrOnly = $true  ->  pull the single-family series (EXCLUDES apartments/condos)
    $zillowMap = @{
        fp  = @{ city = "Floral Park";      state = "NY" }
        rvc = @{ city = "Rockville Centre";  state = "NY" }
        mw  = @{ city = "Maplewood";         state = "NJ" }
        min = @{ city = "Mineola";           state = "NY" }
        scl = @{ city = "Sea Cliff";         state = "NY" }
        mtc = @{ city = "Montclair";         state = "NJ" }
        chm = @{ city = "Chatham";           state = "NJ" }
        wfd = @{ city = "Westfield";         state = "NJ" }
        ptw = @{ city = "Port Washington";   state = "NY" }
        sorg = @{ city = "South Orange";    state = "NJ" }
        worg = @{ city = "West Orange";     state = "NJ" }
        ruth = @{ city = "Rutherford";      state = "NJ" }
        efls = @{ city = "Essex Fells";     state = "NJ" }
        nutl = @{ city = "Nutley";          state = "NJ" }
        glnr = @{ city = "Glen Ridge";      state = "NJ" }
        vron = @{ city = "Verona";          state = "NJ" }
        cldw = @{ city = "Caldwell";        state = "NJ" }
        mrk  = @{ city = "Merrick";         state = "NY" }
        mlv  = @{ city = "Malverne";        state = "NY" }
        lbk  = @{ city = "Lynbrook";        state = "NY" }
        crf  = @{ city = "Cranford";        state = "NJ" }
        rdg  = @{ city = "Ridgewood";       state = "NJ" }
    }

    try {
        $allData = Build-ZillowLookup $CSV_URL_ALL
        $needSfr = @($zillowMap.Values | Where-Object { $_.sfrOnly }).Count -gt 0
        $sfrData = if ($needSfr) { Build-ZillowLookup $CSV_URL_SFR } else { $null }

        # Update each market
        $allMarkets = @($data.primary_markets) + @($data.research_markets)
        foreach ($market in $allMarkets) {
            $id = $market.id
            if ($zillowMap.ContainsKey($id)) {
                $entry  = $zillowMap[$id]
                $useSfr = [bool]$entry.sfrOnly
                $src    = if ($useSfr) { $sfrData } else { $allData }
                $key    = "$($entry.city)|$($entry.state)"
                if ($src -and $src.lookup.ContainsKey($key)) {
                    $prev = $market.median_price
                    $next = $src.lookup[$key]
                    $market.median_price = $next
                    $market | Add-Member -MemberType NoteProperty -Name 'price_as_of' -Value $src.date -Force
                    if ($prev -and $prev -ne $next) {
                        $market.yoy_pct = [math]::Round((($next - $prev) / $prev) * 100, 1)
                    }
                    $tag = if ($useSfr) { "SFR-only, no apts" } else { "all homes" }
                    Log ("  {0,-5} {1}: `${2:N0} ({3}, {4})" -f $id, $entry.city, $next, $src.date, $tag)
                    $changed = $true
                } else {
                    Log "  $id  $($entry.city): not found in Zillow CSV"
                }
            }
        }
    } catch {
        Log "WARN: Zillow fetch failed - $($_.Exception.Message). Prices unchanged."
    }
}

# -- 3. Save & export -----------------------------------------------------------
if ($changed) {
    $data.meta.last_updated = Today
    if (-not $DryRun) {
        $data | ConvertTo-Json -Depth 10 | Set-Content $DATA_FILE -Encoding utf8
        Log "markets.json updated -> $DATA_FILE"

        Log "Regenerating exports..."
        try {
            & "$PSScriptRoot\export.ps1"
        } catch {
            Log "WARN: export.ps1 failed - run it manually to regenerate exports."
        }
    } else {
        Log "DRY RUN complete - no files written."
    }
} else {
    Log "No changes detected - markets.json unchanged."
}

# Run threshold alert check (fires immediately if any threshold crossed)
if (-not $DryRun) {
    Log "Checking alert thresholds..."
    try {
        & "$PSScriptRoot\alert.ps1"
    } catch {
        Log "WARN: alert.ps1 failed - $($_.Exception.Message)"
    }
}

# Run agent: diff data, generate AI summary, send weekly email
if (-not $DryRun -and -not $RatesOnly) {
    Log "Running AI summary agent..."
    try {
        & "$PSScriptRoot\summarize.ps1"
    } catch {
        Log "WARN: summarize.ps1 failed - $($_.Exception.Message)"
    }
}

Log "=== Refresh Complete ==="
