# fetch-investment-rates.ps1
#
# Fetches live investment market data from FRED (Federal Reserve Bank of St. Louis):
#   - US Treasury yields (10yr, 2yr, 3-month)
#   - Corporate bond yields (Moody's Aaa / Baa) as bond fund proxy
#   - S&P 500 price index + annualized historical returns (1/5/10/20/30yr)
#
# Writes: data/investment-rates.json
#
# Usage:
#   .\scripts\fetch-investment-rates.ps1
#   .\scripts\fetch-investment-rates.ps1 -DryRun
#
# Requires: $env:FRED_API_KEY (free at https://fred.stlouisfed.org/docs/api/api_key.html)

param([switch]$DryRun)

$ROOT     = Split-Path $PSScriptRoot -Parent
$OUT_FILE = Join-Path $ROOT "data\investment-rates.json"
$PREFIX   = "[investment-rates]"
$FRED_BASE = "https://api.stlouisfed.org/fred/series/observations"

function Log($msg) { Write-Host "$PREFIX $msg" }

# ── Guard ──────────────────────────────────────────────────────────────────────
$fredKey = $env:FRED_API_KEY
if (-not $fredKey) {
    Log "ERROR: FRED_API_KEY env var not set."
    Log "       Get a free key at https://fred.stlouisfed.org/docs/api/api_key.html"
    exit 1
}

# ── Helpers ────────────────────────────────────────────────────────────────────

# Fetch most recent non-null observation for a series
function FredLatest([string]$series) {
    $url = $FRED_BASE + "?series_id=" + $series + "&api_key=" + $fredKey + "&file_type=json&sort_order=desc&limit=10"
    try {
        $r = Invoke-RestMethod $url -UseBasicParsing
        foreach ($obs in $r.observations) {
            if ($obs.value -ne "." -and $obs.value -ne "") {
                return @{ value = [double]$obs.value; date = $obs.date }
            }
        }
    } catch {
        Log ("  WARN: Could not fetch " + $series + " -- " + $_.Exception.Message)
    }
    return $null
}

# Fetch monthly history for a series from a start date
function FredHistory([string]$series, [string]$startDate) {
    $url = $FRED_BASE + "?series_id=" + $series + "&api_key=" + $fredKey + "&file_type=json&observation_start=" + $startDate + "&frequency=m&sort_order=asc"
    try {
        $r = Invoke-RestMethod $url -UseBasicParsing
        return $r.observations |
            Where-Object { $_.value -ne "." -and $_.value -ne "" } |
            ForEach-Object { @{ date = [datetime]$_.date; value = [double]$_.value } }
    } catch {
        Log ("  WARN: Could not fetch history for " + $series + " -- " + $_.Exception.Message)
        return @()
    }
}

# Annualized return: ((current/past)^(1/years)) - 1, finding closest historical observation
function AnnReturn($history, [double]$currentVal, [int]$yearsBack) {
    $target  = (Get-Date).AddYears(-$yearsBack)
    $closest = $history |
        Sort-Object { [math]::Abs(($_.date - $target).TotalDays) } |
        Select-Object -First 1
    if (-not $closest -or $closest.value -le 0) { return $null }
    return [math]::Round(([math]::Pow($currentVal / $closest.value, 1.0 / $yearsBack) - 1) * 100, 2)
}

# ── 1. Treasury Yields ─────────────────────────────────────────────────────────
Log "Fetching Treasury yields (DGS10, DGS2, DGS3MO)..."
$t10  = FredLatest "DGS10"
$t2   = FredLatest "DGS2"
$t3mo = FredLatest "DGS3MO"

if ($t10)  { Log ("  10yr Treasury: " + $t10.value  + "%  (as of " + $t10.date  + ")") }
if ($t2)   { Log ("  2yr Treasury:  " + $t2.value   + "%  (as of " + $t2.date   + ")") }
if ($t3mo) { Log ("  3mo T-Bill:    " + $t3mo.value + "%  (as of " + $t3mo.date + ")") }

# ── 2. Corporate Bond Yields ───────────────────────────────────────────────────
Log "Fetching corporate bond yields (Moody's AAA, BAA)..."
$aaa = FredLatest "AAA"
$baa = FredLatest "BAA"

if ($aaa) { Log ("  Moody's Aaa: " + $aaa.value + "%  (as of " + $aaa.date + ")") }
if ($baa) { Log ("  Moody's Baa: " + $baa.value + "%  (as of " + $baa.date + ")") }

$bondBlend = if ($aaa -and $baa) { [math]::Round(($aaa.value + $baa.value) / 2, 2) } else { $null }

# ── 3. S&P 500 Historical Returns ─────────────────────────────────────────────
Log "Fetching S&P 500 monthly history since 1993 (for 30yr return calc)..."
$spHistory = FredHistory "SP500" "1993-01-01"

$spLast    = $spHistory | Select-Object -Last 1
$spCurrent = if ($spLast) { $spLast.value } else { $null }
$spDate    = if ($spLast) { $spLast.date.ToString("yyyy-MM-dd") } else { $null }

if ($spCurrent) { Log ("  S&P 500 current: " + $spCurrent + "  (as of " + $spDate + ")") }

$sp1yr  = if ($spCurrent) { AnnReturn $spHistory $spCurrent 1  } else { $null }
$sp5yr  = if ($spCurrent) { AnnReturn $spHistory $spCurrent 5  } else { $null }
$sp10yr = if ($spCurrent) { AnnReturn $spHistory $spCurrent 10 } else { $null }
$sp20yr = if ($spCurrent) { AnnReturn $spHistory $spCurrent 20 } else { $null }
$sp30yr = if ($spCurrent) { AnnReturn $spHistory $spCurrent 30 } else { $null }

$janStart = $spHistory | Where-Object { $_.date.Year -eq (Get-Date).Year } | Select-Object -First 1
$spYTD    = if ($janStart -and $spCurrent) {
    [math]::Round(($spCurrent / $janStart.value - 1) * 100, 2)
} else { $null }

if ($sp1yr)  { Log ("  1yr return:      " + $sp1yr  + "%") }
if ($sp5yr)  { Log ("  5yr annualized:  " + $sp5yr  + "%") }
if ($sp10yr) { Log ("  10yr annualized: " + $sp10yr + "%") }
if ($sp20yr) { Log ("  20yr annualized: " + $sp20yr + "%") }
if ($sp30yr) { Log ("  30yr annualized: " + $sp30yr + "%") }

# ── 4. Build output JSON ───────────────────────────────────────────────────────
$out = [ordered]@{
    as_of  = (Get-Date -Format "yyyy-MM-dd")
    source = "FRED - Federal Reserve Bank of St. Louis (api.stlouisfed.org)"
    treasury = [ordered]@{
        t10yr = if ($t10)  { $t10.value  } else { $null }
        t2yr  = if ($t2)   { $t2.value   } else { $null }
        t3mo  = if ($t3mo) { $t3mo.value } else { $null }
        as_of = if ($t10)  { $t10.date   } else { $null }
        note  = "DGS10 / DGS2 / DGS3MO constant-maturity Treasury yields"
    }
    corporate_bonds = [ordered]@{
        aaa   = if ($aaa) { $aaa.value } else { $null }
        baa   = if ($baa) { $baa.value } else { $null }
        blend = $bondBlend
        as_of = if ($baa) { $baa.date  } else { $null }
        note  = "Moody's Aaa / Baa yields (FRED: AAA / BAA). Proxy for investment-grade bond fund yield."
    }
    sp500 = [ordered]@{
        current = $spCurrent
        returns = [ordered]@{
            ytd              = $spYTD
            r1yr             = $sp1yr
            r5yr_annualized  = $sp5yr
            r10yr_annualized = $sp10yr
            r20yr_annualized = $sp20yr
            r30yr_annualized = $sp30yr
        }
        as_of = $spDate
        note  = "FRED SP500 series (price return only). Add ~1.5-2%/yr for estimated total return including dividends."
    }
}

# ── 5. Write ───────────────────────────────────────────────────────────────────
if ($DryRun) {
    Log "DRY RUN - would write to: $OUT_FILE"
    $out | ConvertTo-Json -Depth 5
} else {
    New-Item -ItemType Directory -Force -Path (Join-Path $ROOT "data") | Out-Null
    $out | ConvertTo-Json -Depth 5 | Set-Content $OUT_FILE -Encoding utf8
    Log "Saved -> $OUT_FILE"
}

Log "Done."
