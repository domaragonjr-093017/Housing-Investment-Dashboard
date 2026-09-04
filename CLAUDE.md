# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

---

## Project Purpose

Track and compare suburban NYC housing markets to support a home purchase decision. The owner evaluates markets across Nassau County LI, Westchester, and NJ on four axes: **price, all-in PITI cost, commute to Midtown Manhattan, and school district quality.**

---

## Owner Context

- Current home estimated value: ~$700K → net proceeds after sale: ~$658K (primary down payment source)
- Family with young children — school district quality is a top filter
- Works in NYC (finance); commute time and transit access (LIRR vs. Metro-North vs. NJ Transit) matter
- Budget ceiling is implicitly set by proceeds + conforming loan limit ($832,750); jumbo adds ~0.10–0.15% to rate

---

## Primary Markets (Dashboard)

| ID  | Market           | State | County      | Median Price | Ann. Tax  | Commute to Midtown |
|-----|------------------|-------|-------------|--------------|-----------|-------------------|
| fp  | Floral Park      | NY    | Nassau LI   | $790K        | ~$13K/yr  | 35–45 min (LIRR)  |
| rvc | Rockville Centre | NY    | Nassau LI   | $850K        | ~$17K/yr  | 40–45 min (LIRR)  |
| mw  | Maplewood        | NJ    | Essex       | $840K        | ~$18K/yr  | 45–55 min (NJ Transit) |

Tax figures are **fully combined**: county + town + school district + special districts. School tax ≈ 60–70% of total bill and is not broken out separately in the dashboard.

## Secondary Research Markets (town_research.md)

A second set of 5 towns was researched for comparison — see `town_research.md` for full detail:

| Town         | State | Median Price    | Tax Rate | Ann. Tax     | Schools              |
|--------------|-------|-----------------|----------|--------------|----------------------|
| Hoboken      | NJ    | ~$872K          | ~1.14%*  | ~$9,948      | 8/10 GreatSchools    |
| Montclair    | NJ    | ~$1M+           | ~3.38%   | ~$22,487     | Niche A              |
| Ridgewood    | NJ    | ~$1.05–1.35M    | ~2.80%   | ~$17–21K     | 9/10 GreatSchools    |
| White Plains | NY    | ~$695K          | ~1.97%   | ~$9,854      | Above avg, diverse   |
| Garden City  | NY    | ~$1.07M         | ~1.46%   | ~$12,269     | 10/10 (top 5% NY)    |

\* Hoboken faces ~18–23% combined tax hike in 2026–27.

---

## Dashboard Architecture (v6)

The interactive dashboard widget was built iteratively across multiple Claude.ai sessions. Current version has five tabs:

- **Overview** — Market cards: price, DOM, YoY%, "Use for mortgage" shortcut
- **Compare** — Side-by-side table + YoY bar chart
- **Mortgage / PITI Calculator** — P&I + property/school tax + insurance, all editable; cumulative interest chart across 3 loan terms; net proceeds pre-loaded
- **Executive Summary** — AI-generated on Refresh: headline, rate environment, per-market blurbs, key takeaways, buyer guidance
- **Watchlist** — Save specific listings with notes

---

## File Structure

**Project root: `C:\Users\domar\housing-dashboard\`**
(Migrated June 2026 from `C:\Users\domar\` — always use the housing-dashboard folder)

```
C:\Users\domar\housing-dashboard\
├── CLAUDE.md                        # This file
├── town_research.md                 # Research: Hoboken, Montclair, Ridgewood, White Plains, Garden City
├── data/
│   ├── markets.json                 # All market data, watchlist, mortgage rate config
│   ├── markets_snapshot.json        # Pre-refresh snapshot for diff/summary
│   └── investment-rates.json        # Live FRED rates for Investment tab
├── exports/                         # Generated markdown/HTML exports
├── docs/
│   └── index.html                   # GitHub Pages live dashboard (auto-pushed by export.ps1)
└── scripts/
    ├── dashboard-template.html      # Dashboard source template (all tabs/JS)
    ├── export.ps1                   # Generates exports + pushes to GitHub Pages
    ├── refresh.ps1                  # Wednesday data refresh (Zillow + FRED)
    ├── scheduled-refresh.ps1        # Entry point for Windows Task Scheduler
    ├── summarize.ps1                # Claude API narrative + Gmail email send
    ├── send-summary.ps1             # Entry point for email scheduled task
    ├── fetch-investment-rates.ps1   # FRED live rates for Investment tab
    └── alert.ps1                    # Price threshold alerts
```

**GitHub Pages live URL:** https://domaragonjr-093017.github.io/Housing-Investment-Dashboard/

**Windows Scheduled Tasks (both updated to new path):**
- `HousingDashboard-Wednesday` — runs `scheduled-refresh.ps1` at Wed 10:00 AM
- `HousingDashboard_Weekly`    — runs `send-summary.ps1` at Wed 10:30 AM

---

## Current Mortgage Rates (updated 2026-05-19)

| Term     | Rate      | Notes                          |
|----------|-----------|-------------------------------|
| 30yr fix | **6.50%** | 9-month high                  |
| 20yr fix | **6.39%** |                               |
| 15yr fix | **5.79%** |                               |

Rate driver: Iran conflict + May CPI at 3.8%. Cross-reference: Freddie Mac weekly avg vs. daily quotes.

---

## Data Source Conventions

- **Price signal**: Zillow ZHVI (most stable); Redfin/Homes.com for recent trend confirmation
- **Tax figures**: Fully combined all-in annual bill; sourced from Ownwell, county assessor sites
- **School ratings**: GreatSchools (1–10 scale) + Niche letter grades
- **Commute times**: Door-to-door to Midtown Manhattan via primary transit line

---

## Key Design Decisions

- Sea Cliff NY and Port Washington NY were evaluated and removed; replaced by Maplewood NJ (NJ diversity + NYC spillover demand)
- All Westchester (Pelham, Bronxville, Larchmont, New Rochelle, Wykagyl) and Queens (Rockaway Park) markets were removed per owner preference (2026-09) — LI/NJ focus only going forward
- Mineola is retained as the value/commute anchor for LI markets
- Tax is displayed as one combined figure — school tax is already the dominant component (~60–70%) and breaking it out added confusion without clarity
- PITI calculator pre-loads net proceeds (~$658K) as the default down payment

---

## Refresh Cadence

| Data point      | Frequency                              |
|-----------------|----------------------------------------|
| Mortgage rates  | Weekly or on significant Fed/CPI events|
| Market prices   | Monthly (Zillow ZHVI cycle)            |
| DOM / listings  | Monthly via Redfin/Homes.com spot check|
| Tax estimates   | Annually (reassessment cycles)         |

---

## Session Continuity Notes

- Dashboard originated in a pinned Claude.ai chat: **"Housing Market Dashboard (NY, NJ, LI)"** (v6 is current)
- `town_research.md` was created in a separate Claude Code session (May 2026) covering a second set of comparison towns
- If the dashboard widget fails to render, check that `claudemcpcontent.com` is not blocked by McAfee or home network firewall — use hotspot or whitelist the domain
- Claude Code session search only covers Claude Code sessions, not Claude.ai web chats
