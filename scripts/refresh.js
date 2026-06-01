#!/usr/bin/env node
/**
 * refresh.js — Housing Market Dashboard Data Refresher
 *
 * What it does:
 *   1. Fetches current mortgage rates from Freddie Mac / FRED API
 *   2. Fetches latest Zillow ZHVI median prices for each market
 *   3. Updates data/markets.json in place
 *   4. Calls export.js to regenerate markdown and HTML exports
 *
 * Usage:
 *   node scripts/refresh.js              # full refresh
 *   node scripts/refresh.js --rates-only # mortgage rates only
 *   node scripts/refresh.js --prices-only # market prices only
 *   node scripts/refresh.js --dry-run    # preview changes without writing
 *
 * Env vars (set in .env or shell):
 *   FRED_API_KEY   — free key from https://fred.stlouisfed.org/docs/api/api_key.html
 *   ZILLOW_API_KEY — RapidAPI Zillow key (optional; falls back to public ZHVI CSVs)
 */

import fs from "fs";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const DATA_FILE = path.join(ROOT, "data", "markets.json");

// ─── CLI flags ────────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const RATES_ONLY = args.includes("--rates-only");
const PRICES_ONLY = args.includes("--prices-only");
const DRY_RUN = args.includes("--dry-run");

// ─── Helpers ──────────────────────────────────────────────────────────────────
function log(msg) {
  console.log(`[refresh] ${new Date().toISOString().slice(0, 19).replace("T", " ")}  ${msg}`);
}

function today() {
  return new Date().toISOString().slice(0, 10);
}

async function fetchJson(url, headers = {}) {
  const res = await fetch(url, { headers });
  if (!res.ok) throw new Error(`HTTP ${res.status} for ${url}`);
  return res.json();
}

// ─── Mortgage Rates (FRED API) ────────────────────────────────────────────────
// Series IDs:
//   MORTGAGE30US  — 30-year fixed weekly avg
//   MORTGAGE15US  — 15-year fixed weekly avg
// 20-year is not tracked by FRED; estimated as midpoint + spread heuristic.
async function fetchMortgageRates() {
  const FRED_KEY = process.env.FRED_API_KEY;
  if (!FRED_KEY) {
    log("WARN: FRED_API_KEY not set — skipping live rate fetch. Using current values.");
    return null;
  }

  const base = "https://api.stlouisfed.org/fred/series/observations";
  const params = (series) =>
    `?series_id=${series}&api_key=${FRED_KEY}&file_type=json&sort_order=desc&limit=1`;

  log("Fetching mortgage rates from FRED...");
  const [r30, r15] = await Promise.all([
    fetchJson(base + params("MORTGAGE30US")),
    fetchJson(base + params("MORTGAGE15US")),
  ]);

  const rate30 = parseFloat(r30.observations[0].value) / 100;
  const rate15 = parseFloat(r15.observations[0].value) / 100;
  const rate20 = parseFloat(((rate30 + rate15) / 2 + 0.001).toFixed(4)); // heuristic

  log(`  30yr: ${(rate30 * 100).toFixed(2)}%  |  20yr: ${(rate20 * 100).toFixed(2)}%  |  15yr: ${(rate15 * 100).toFixed(2)}%`);
  return { "30yr_fixed": rate30, "20yr_fixed": rate20, "15yr_fixed": rate15 };
}

// ─── Market Prices (Zillow ZHVI public CSV fallback) ─────────────────────────
// Zillow publishes free ZHVI CSVs monthly at:
//   https://www.zillow.com/research/data/
// The Metro-level ZHVI (All Homes, smoothed) is the most stable signal.
// CSV format: RegionName, ..., <date columns>, <latest_date>
//
// For simplicity, this fetches the most recent value for each ZIP/city.
// If ZILLOW_API_KEY (RapidAPI) is set, uses the live API instead.

// Zillow region IDs for each market (from Zillow research data)
const ZILLOW_REGION_MAP = {
  fp:  { zip: "11001", city: "Floral Park",      state: "NY" },
  rvc: { zip: "11570", city: "Rockville Centre",  state: "NY" },
  mw:  { zip: "07040", city: "Maplewood",         state: "NJ" },
  plh: { zip: "10803", city: "Pelham",            state: "NY" },
  min: { zip: "11501", city: "Mineola",           state: "NY" },
  hob: { zip: "07030", city: "Hoboken",           state: "NJ" },
  mtc: { zip: "07042", city: "Montclair",         state: "NJ" },
  rdg: { zip: "07450", city: "Ridgewood",         state: "NJ" },
  wpl: { zip: "10601", city: "White Plains",      state: "NY" },
  gcy: { zip: "11530", city: "Garden City",       state: "NY" },
};

async function fetchZillowPrices() {
  log("Fetching Zillow ZHVI data...");

  // Public CSV URL — city-level ZHVI (all homes, smoothed, seasonally adjusted)
  const CSV_URL =
    "https://files.zillowstatic.com/research/public_csvs/zhvi/City_zhvi_uc_sfrcondo_tier_0.33_0.67_sm_sa_month.csv";

  let csvText;
  try {
    const res = await fetch(CSV_URL);
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    csvText = await res.text();
    log("  Zillow CSV downloaded successfully.");
  } catch (err) {
    log(`  WARN: Could not fetch Zillow CSV (${err.message}). Prices unchanged.`);
    return null;
  }

  // Parse CSV — header row contains date columns
  const lines = csvText.split("\n");
  const headers = lines[0].split(",");
  const latestDateCol = headers.length - 1; // last column = most recent month
  const latestDate = headers[latestDateCol].trim();

  // Build lookup: "City|State" → latest ZHVI value
  const lookup = {};
  for (let i = 1; i < lines.length; i++) {
    const cols = lines[i].split(",");
    if (cols.length < latestDateCol) continue;
    const city = cols[2]?.trim();   // RegionName
    const state = cols[4]?.trim();  // StateName (2-letter)
    const value = parseFloat(cols[latestDateCol]);
    if (city && state && !isNaN(value)) {
      lookup[`${city}|${state}`] = { price: Math.round(value), as_of: latestDate };
    }
  }

  // Match each market
  const results = {};
  for (const [id, region] of Object.entries(ZILLOW_REGION_MAP)) {
    const key = `${region.city}|${region.state}`;
    if (lookup[key]) {
      results[id] = lookup[key];
      log(`  ${id.padEnd(4)} ${region.city}: $${lookup[key].price.toLocaleString()} (${latestDate})`);
    } else {
      log(`  ${id.padEnd(4)} ${region.city}: not found in CSV`);
    }
  }

  return results;
}

// ─── Main ─────────────────────────────────────────────────────────────────────
async function main() {
  log("=== Housing Market Refresh Starting ===");
  if (DRY_RUN) log("DRY RUN — no files will be written.");

  // Load current data
  const data = JSON.parse(fs.readFileSync(DATA_FILE, "utf-8"));
  let changed = false;

  // 1. Mortgage rates
  if (!PRICES_ONLY) {
    const rates = await fetchMortgageRates();
    if (rates) {
      data.mortgage_rates.rates = rates;
      data.mortgage_rates.as_of = today();
      data.mortgage_rates.rate_driver = "(auto-updated by refresh.js)";
      changed = true;
    }
  }

  // 2. Market prices
  if (!RATES_ONLY) {
    const prices = await fetchZillowPrices();
    if (prices) {
      const allMarkets = [...data.primary_markets, ...data.research_markets];
      for (const market of allMarkets) {
        if (prices[market.id]) {
          const prev = market.median_price;
          const next = prices[market.id].price;
          market.median_price = next;
          market.price_as_of = prices[market.id].as_of;
          if (prev !== next) {
            market.yoy_pct = parseFloat((((next - prev) / prev) * 100).toFixed(1));
          }
          changed = true;
        }
      }
    }
  }

  // 3. Bump last_updated
  if (changed) {
    data.meta.last_updated = today();
  }

  // 4. Write
  if (changed && !DRY_RUN) {
    fs.writeFileSync(DATA_FILE, JSON.stringify(data, null, 2));
    log(`markets.json updated → ${DATA_FILE}`);

    // Regenerate exports
    log("Regenerating exports...");
    const { execSync } = await import("child_process");
    try {
      execSync("node scripts/export.js", { cwd: ROOT, stdio: "inherit" });
    } catch {
      log("WARN: export.js failed — run manually to regenerate exports.");
    }
  } else if (!changed) {
    log("No changes detected — markets.json unchanged.");
  } else {
    log("DRY RUN complete — no files written.");
  }

  log("=== Refresh Complete ===");
}

main().catch((err) => {
  console.error("[refresh] Fatal error:", err.message);
  process.exit(1);
});
