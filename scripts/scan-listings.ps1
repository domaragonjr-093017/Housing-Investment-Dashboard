# scan-listings.ps1 - Redfin Listing Scanner
#
# Fetches recent Redfin listings for all markets (3BR+, under $1M, SFH).
# Passes results to Claude for scoring against buyer criteria.
# Returns scored listing objects for use in the weekly email.
#
# Called by summarize.ps1. Can also be run standalone:
#   .\scripts\scan-listings.ps1

param(
    [int]$MaxPrice    = 1000000,
    [int]$MinBeds     = 3,
    [int]$MaxResults  = 5   # top N listings to surface per run (across all markets)
)

$ErrorActionPreference = "SilentlyContinue"

function Log($msg) { Write-Host "[scan-listings] $msg" }

# Redfin URL slugs for all markets
$marketSlugs = @{
    # Primary
    fp  = @{ name = "Floral Park";       state = "NY"; redfin = "NY/Floral-Park" }
    rvc = @{ name = "Rockville Centre";  state = "NY"; redfin = "NY/Rockville-Centre" }
    mw  = @{ name = "Maplewood";         state = "NJ"; redfin = "NJ/Maplewood" }
    plh = @{ name = "Pelham";            state = "NY"; redfin = "NY/Pelham" }
    # Research
    rkp = @{ name = "Rockaway Park";     state = "NY"; redfin = "NY/Rockaway-Park" }
    lch = @{ name = "Larchmont";         state = "NY"; redfin = "NY/Larchmont" }
    brx = @{ name = "Bronxville";        state = "NY"; redfin = "NY/Bronxville" }
    scl = @{ name = "Sea Cliff";         state = "NY"; redfin = "NY/Sea-Cliff" }
    mmk = @{ name = "Mamaroneck";        state = "NY"; redfin = "NY/Mamaroneck" }
    mtc = @{ name = "Montclair";         state = "NJ"; redfin = "NJ/Montclair" }
    wfd = @{ name = "Westfield";         state = "NJ"; redfin = "NJ/Westfield" }
    chm = @{ name = "Chatham";           state = "NJ"; redfin = "NJ/Chatham" }
    ptw = @{ name = "Port Washington";   state = "NY"; redfin = "NY/Port-Washington" }
    nro = @{ name = "New Rochelle";      state = "NY"; redfin = "NY/New-Rochelle" }
    wyk = @{ name = "Wykagyl";           state = "NY"; redfin = "NY/New-Rochelle" }
}

# Build Redfin search URL for a market
function Get-RedfinUrl($slug) {
    $maxK = $MaxPrice / 1000
    "https://www.redfin.com/$($slug.redfin)/filter/max-price=$($maxK)k,min-beds=$MinBeds,property-type=house,status=active,sort=newest"
}

# Fetch Redfin CSV download for a market (Redfin allows CSV export via /stingray endpoint)
function Get-RedfinListings($slug) {
    $region = $slug.redfin
    # Redfin CSV download URL pattern
    $url = "https://www.redfin.com/stingray/api/gis-csv?al=1&market=nyc&min_beds=$MinBeds&max_price=$MaxPrice&property_type=house&status=1&uipt=1&region_type=6&region_id=&num_homes=20&v=8"

    # Use the search page URL to get region_id first via a lightweight fetch
    $searchUrl = "https://www.redfin.com/$region/filter/max-price=$($MaxPrice/1000)k,min-beds=$MinBeds,property-type=house"

    try {
        $headers = @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
            "Accept"     = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        }
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36")
        $wc.Headers.Add("Accept-Language", "en-US,en;q=0.9")

        # Fetch the search results page and extract listing data from JSON embed
        $html = $wc.DownloadString($searchUrl)

        # Extract listing cards from Redfin's embedded JSON (window.__reactServerState or similar)
        $listings = @()

        # Parse price + address from og:description or structured data snippets
        $priceMatches  = [regex]::Matches($html, '"price"\s*:\s*(\d+)')
        $bedsMatches   = [regex]::Matches($html, '"beds"\s*:\s*(\d+)')
        $addressMatches = [regex]::Matches($html, '"streetLine"\s*:\s*"([^"]+)"')
        $urlMatches    = [regex]::Matches($html, '"url"\s*:\s*"(/home/\d+[^"]*)"')

        $count = [math]::Min($priceMatches.Count, [math]::Min($bedsMatches.Count, $addressMatches.Count))

        for ($i = 0; $i -lt [math]::Min($count, 8); $i++) {
            $price = [int]$priceMatches[$i].Groups[1].Value
            $beds  = [int]$bedsMatches[$i].Groups[1].Value
            $addr  = $addressMatches[$i].Groups[1].Value
            $path  = if ($i -lt $urlMatches.Count) { $urlMatches[$i].Groups[1].Value } else { "" }

            if ($price -gt 100000 -and $price -le $MaxPrice -and $beds -ge $MinBeds) {
                $listings += [PSCustomObject]@{
                    address = $addr
                    price   = $price
                    beds    = $beds
                    market  = $slug.name
                    state   = $slug.state
                    url     = if ($path) { "https://www.redfin.com$path" } else { $searchUrl }
                }
            }
        }
        return $listings
    } catch {
        Log "  WARN: Could not fetch $($slug.name) — $($_.Exception.Message)"
        return @()
    }
}

# Score listings with Claude API
function Invoke-ClaudeScoring($listings, $dataJson) {
    $apiKey = $env:ANTHROPIC_API_KEY
    if (-not $apiKey) {
        Log "ANTHROPIC_API_KEY not set — skipping AI scoring, returning raw listings."
        return $listings | Select-Object -First $MaxResults
    }
    if ($listings.Count -eq 0) {
        Log "No listings to score."
        return @()
    }

    Log "Sending $($listings.Count) listings to Claude for scoring..."

    $listingText = ($listings | ForEach-Object {
        "- $($_.address), $($_.market) $($_.state) | Price: `$$($_.price.ToString('N0')) | Beds: $($_.beds) | URL: $($_.url)"
    }) -join "`n"

    $prompt = @"
You are a real estate analyst helping a family buy a home in the NYC suburbs. Their profile:
- Budget: up to `$1,000,000
- Need: 3+ bedrooms, single-family home
- Top priorities: school district quality, commute to Midtown Manhattan, low property tax, value for money
- Has ~`$658K in proceeds for a down payment
- Works in NYC finance — commute time and transit access matter a lot
- Two young children — school district is the #1 filter

Here are current active listings across their tracked markets:
$listingText

Score and rank the TOP $MaxResults listings from this list. For each, provide:
1. A score out of 10
2. One sentence on why it stands out (be specific — mention price, location advantage, or value)
3. One risk or caveat

Format your response as a JSON array like this:
[
  {
    "address": "123 Main St",
    "market": "Town Name",
    "state": "NY",
    "price": 850000,
    "beds": 3,
    "url": "https://...",
    "score": 8,
    "why": "Strong value in top-rated district with direct LIRR access.",
    "caveat": "Tax rate is above market average for Nassau County."
  }
]
Only return the JSON array, no other text.
"@

    try {
        $body = [ordered]@{
            model      = "claude-haiku-4-5"
            max_tokens = 1000
            messages   = @(@{ role = "user"; content = $prompt })
        } | ConvertTo-Json -Depth 5

        $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)
        $resp = Invoke-RestMethod `
            -Uri "https://api.anthropic.com/v1/messages" `
            -Method POST `
            -Headers @{
                "x-api-key"         = $apiKey
                "anthropic-version" = "2023-06-01"
                "Content-Type"      = "application/json; charset=utf-8"
            } `
            -Body $bodyBytes -UseBasicParsing

        $json = $resp.content[0].text.Trim()
        # Strip markdown code fences if present
        $json = $json -replace '```json','' -replace '```',''
        $scored = $json | ConvertFrom-Json
        Log "Claude scored $($scored.Count) listings."
        return $scored
    } catch {
        Log "WARN: Claude scoring failed — $($_.Exception.Message). Returning top raw listings."
        return $listings | Select-Object -First $MaxResults
    }
}

# ── Main ────────────────────────────────────────────────────────────────────────
Log "Starting listing scan — $MinBeds+ BR, under `$$($MaxPrice.ToString('N0')), all markets..."

$allListings = @()
foreach ($id in $marketSlugs.Keys) {
    $slug = $marketSlugs[$id]
    Log "  Fetching $($slug.name), $($slug.state)..."
    $results = Get-RedfinListings $slug
    Log "    $($results.Count) listings found"
    $allListings += $results
}

Log "Total raw listings collected: $($allListings.Count)"

$ROOT      = Split-Path $PSScriptRoot -Parent
$dataFile  = Join-Path $ROOT "data\markets.json"
$dataJson  = if (Test-Path $dataFile) { Get-Content $dataFile -Raw } else { "{}" }

$scored = Invoke-ClaudeScoring $allListings $dataJson

# Save to file for summarize.ps1 to pick up
$outFile = Join-Path $ROOT "data\listings_scan.json"
$scored | ConvertTo-Json -Depth 5 | Set-Content $outFile -Encoding utf8
Log "Saved $($scored.Count) scored listings -> $outFile"

return $scored
