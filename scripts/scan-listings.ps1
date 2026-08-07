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
    @{ id="mw";  name="Maplewood";        state="NJ"; redfin="NJ/Maplewood";         zillow="maplewood-nj";        trulia="maplewood_nj" }
    @{ id="plh"; name="Pelham";           state="NY"; redfin="NY/Pelham";            zillow="pelham-ny";           trulia="pelham_ny" }
    @{ id="ptw"; name="Port Washington";  state="NY"; redfin="NY/Port-Washington";   zillow="port-washington-ny";  trulia="port-washington_ny" }
    @{ id="lch"; name="Larchmont";        state="NY"; redfin="NY/Larchmont";         zillow="larchmont-ny";        trulia="larchmont_ny" }
    @{ id="mmk"; name="Mamaroneck";       state="NY"; redfin="NY/Mamaroneck";        zillow="mamaroneck-ny";       trulia="mamaroneck_ny" }
    @{ id="brx"; name="Bronxville";       state="NY"; redfin="NY/Bronxville";        zillow="bronxville-ny";       trulia="bronxville_ny" }
    @{ id="scl"; name="Sea Cliff";        state="NY"; redfin="NY/Sea-Cliff";         zillow="sea-cliff-ny";        trulia="sea-cliff_ny" }
    @{ id="nro"; name="New Rochelle";     state="NY"; redfin="NY/New-Rochelle";      zillow="new-rochelle-ny";     trulia="new-rochelle_ny" }
    @{ id="mtc"; name="Montclair";        state="NJ"; redfin="NJ/Montclair";         zillow="montclair-nj";        trulia="montclair_nj" }
    @{ id="wfd"; name="Westfield";        state="NJ"; redfin="NJ/Westfield";         zillow="westfield-nj";        trulia="westfield_nj" }
    @{ id="chm"; name="Chatham";          state="NJ"; redfin="NJ/Chatham";           zillow="chatham-nj";          trulia="chatham_nj" }
    @{ id="rkp";  name="Rockaway Park";  state="NY"; redfin="NY/Rockaway-Park";    zillow="rockaway-park-ny";    trulia="rockaway-park_ny" }
    @{ id="sorg"; name="South Orange";   state="NJ"; redfin="NJ/South-Orange";    zillow="south-orange-nj";     trulia="south-orange_nj" }
    @{ id="worg"; name="West Orange";    state="NJ"; redfin="NJ/West-Orange";     zillow="west-orange-nj";      trulia="west-orange_nj" }
    @{ id="ruth"; name="Rutherford";     state="NJ"; redfin="NJ/Rutherford";      zillow="rutherford-nj";       trulia="rutherford_nj" }
    @{ id="efls"; name="Essex Fells";    state="NJ"; redfin="NJ/Essex-Fells";     zillow="essex-fells-nj";      trulia="essex-fells_nj" }
    @{ id="nutl"; name="Nutley";         state="NJ"; redfin="NJ/Nutley";          zillow="nutley-nj";           trulia="nutley_nj" }
    @{ id="glnr"; name="Glen Ridge";     state="NJ"; redfin="NJ/Glen-Ridge";      zillow="glen-ridge-nj";       trulia="glen-ridge_nj" }
    @{ id="vron"; name="Verona";         state="NJ"; redfin="NJ/Verona";          zillow="verona-nj";           trulia="verona_nj" }
    @{ id="cldw"; name="Caldwell";       state="NJ"; redfin="NJ/Caldwell";        zillow="caldwell-nj";         trulia="caldwell_nj" }
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
