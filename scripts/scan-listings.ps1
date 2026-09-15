# scan-listings.ps1 - Listing Search Link Generator
#
# Generates pre-filtered Redfin + Zillow search URLs for all tracked markets.
# Criteria: 3+ BR, under $1M, single-family homes, active listings.
# Returns a JSON array of market search links for use in the weekly email.
#
# Called by summarize.ps1. Can also be run standalone.

param(
    [int]$MaxPrice = 1000000,
    [int]$MinBeds  = 3
)

$ROOT     = Split-Path $PSScriptRoot -Parent
$OUT_FILE = Join-Path $ROOT "data\listings_scan.json"
$MaxK     = $MaxPrice / 1000

function Log($msg) { Write-Host "[scan-listings] $msg" }

# Market slugs for Redfin and Zillow
$markets = @(
    @{ id="fp";  name="Floral Park";      state="NY"; redfin="NY/Floral-Park";       zillow="floral-park-ny";      trulia="floral-park_ny" }
    @{ id="rvc"; name="Rockville Centre"; state="NY"; redfin="NY/Rockville-Centre";  zillow="rockville-centre-ny"; trulia="rockville-centre_ny" }
    @{ id="ptw"; name="Port Washington";  state="NY"; redfin="NY/Port-Washington";   zillow="port-washington-ny";  trulia="port-washington_ny" }
    @{ id="scl"; name="Sea Cliff";        state="NY"; redfin="NY/Sea-Cliff";         zillow="sea-cliff-ny";        trulia="sea-cliff_ny" }
    @{ id="mrk";  name="Merrick";        state="NY"; redfin="NY/Merrick";         zillow="merrick-ny";          trulia="merrick_ny" }
)

Log "Generating search links for $($markets.Count) markets (${MinBeds}+ BR, under ${MaxK}k)..."

$results = $markets | ForEach-Object {
    $m = $_
    [PSCustomObject]@{
        id     = $m.id
        name   = $m.name
        state  = $m.state
        redfin = "https://www.redfin.com/$($m.redfin)/filter/max-price=${MaxK}k,min-beds=${MinBeds},property-type=house"
        zillow = "https://www.zillow.com/$($m.zillow)/${MinBeds}-beds/?price=0-${MaxPrice}"
        trulia = "https://www.trulia.com/$($m.trulia)/SINGLE-FAMILY_HOME/0-${MaxPrice}_price/${MinBeds}p_beds/"
    }
}

$results | ConvertTo-Json -Depth 3 | Set-Content $OUT_FILE -Encoding utf8
Log "Saved $($results.Count) market links -> $OUT_FILE"
