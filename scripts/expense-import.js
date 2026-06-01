#!/usr/bin/env node
import fs from 'fs';
import path from 'path';
import crypto from 'crypto';
import { fileURLToPath } from 'url';
import Anthropic from '@anthropic-ai/sdk';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const DATA_FILE = path.join(ROOT, 'data', 'expenses.json');

const args = process.argv.slice(2);
const csvPath = args.find(a => !a.startsWith('--'));
const DRY_RUN = args.includes('--dry-run');
const accountArg = args.find(a => a.startsWith('--account='));
const account = accountArg
  ? accountArg.replace(/^--account=/, '').replace(/^["']|["']$/g, '')
  : 'Unknown Account';

if (!csvPath) {
  console.error('Usage: node scripts/expense-import.js <path-to-csv> [--account="Chase Checking"] [--dry-run]');
  process.exit(1);
}

// ── CSV Parser ────────────────────────────────────────────────────────────────

function parseCSVLine(line) {
  const cells = [];
  let cell = '';
  let inQuotes = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (ch === '"') {
      if (inQuotes && line[i + 1] === '"') { cell += '"'; i++; }
      else inQuotes = !inQuotes;
    } else if (ch === ',' && !inQuotes) {
      cells.push(cell);
      cell = '';
    } else {
      cell += ch;
    }
  }
  cells.push(cell);
  return cells;
}

function parseCSV(text) {
  const lines = text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').trim().split('\n');
  const headers = parseCSVLine(lines[0]).map(h => h.trim());
  return lines.slice(1)
    .filter(l => l.trim() && l.split(',').some(c => c.trim()))
    .map(line => {
      const vals = parseCSVLine(line);
      return Object.fromEntries(headers.map((h, i) => [h, (vals[i] ?? '').trim()]));
    });
}

// ── Format Detection & Normalization ──────────────────────────────────────────

function parseDateToISO(str) {
  if (!str) return '';
  const mdy = str.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})$/);
  if (mdy) return `${mdy[3]}-${mdy[1].padStart(2, '0')}-${mdy[2].padStart(2, '0')}`;
  return str.slice(0, 10);
}

function makeId(date, description, amount) {
  return crypto
    .createHash('sha256')
    .update(`${date}|${description}|${String(amount)}`)
    .digest('hex')
    .slice(0, 12);
}

function normalizeTransaction(date, description, amount, accountName, sourceFile) {
  return { id: makeId(date, description, amount), date, description, amount, account: accountName, source_file: path.basename(sourceFile) };
}

function detectAndNormalize(rows, sourceFile, accountName) {
  if (!rows.length) return [];
  const keys = Object.keys(rows[0]).map(k => k.toLowerCase());

  // Chase checking: Details, Posting Date, Description, Amount, Type, Balance
  if (keys.includes('posting date') && keys.includes('details')) {
    return rows.map(r => {
      const date = parseDateToISO(r['Posting Date'] ?? '');
      const description = r['Description'] ?? '';
      const amount = parseFloat(r['Amount'] ?? '0') || 0;
      return normalizeTransaction(date, description, amount, accountName, sourceFile);
    });
  }

  // Chase credit: Transaction Date, Post Date, Description, Category, Type, Amount, Memo
  // Positive = charge (expense), negative = payment/credit — flip sign to match our convention
  if (keys.includes('transaction date') && keys.includes('post date')) {
    return rows.map(r => {
      const date = parseDateToISO(r['Transaction Date'] ?? '');
      const description = r['Description'] ?? '';
      const amount = -(parseFloat(r['Amount'] ?? '0') || 0);
      return normalizeTransaction(date, description, amount, accountName, sourceFile);
    });
  }

  // Generic: Date, Description, Amount
  return rows.map(r => {
    const dateKey = Object.keys(r).find(k => k.toLowerCase() === 'date') ?? '';
    const descKey = Object.keys(r).find(k => k.toLowerCase() === 'description') ?? '';
    const amtKey = Object.keys(r).find(k => k.toLowerCase() === 'amount') ?? '';
    const date = parseDateToISO(r[dateKey] ?? '');
    const description = r[descKey] ?? '';
    const amount = parseFloat(r[amtKey] ?? '0') || 0;
    return normalizeTransaction(date, description, amount, accountName, sourceFile);
  });
}

// ── Claude Categorization ─────────────────────────────────────────────────────

const SYSTEM_PROMPT =
  'Categorize bank transactions into exactly one category from the provided list.\n' +
  'Return ONLY a JSON array: [{"id":"...","category":"..."}]. No explanation, no markdown.';

async function categorize(transactions, categories) {
  const client = new Anthropic();
  const results = [];
  const categoriesList = categories.join(', ');

  for (let i = 0; i < transactions.length; i += 50) {
    const batch = transactions.slice(i, i + 50);
    const payload = batch.map(t => ({ id: t.id, description: t.description, amount: t.amount }));

    const response = await client.messages.create({
      model: 'claude-haiku-4-5-20251001',
      max_tokens: 2048,
      system: [
        {
          type: 'text',
          text: `${SYSTEM_PROMPT}\nCategories: ${categoriesList}`,
          // System prompt is identical across all batches — cache it
          cache_control: { type: 'ephemeral' },
        },
      ],
      messages: [{ role: 'user', content: JSON.stringify(payload) }],
    });

    const text = response.content.find(b => b.type === 'text')?.text ?? '[]';
    const jsonMatch = text.match(/\[[\s\S]*\]/);
    const categoryMap = new Map();

    if (jsonMatch) {
      try {
        JSON.parse(jsonMatch[0]).forEach(c => categoryMap.set(c.id, c.category));
      } catch { /* fall through to 'Other' default */ }
    }

    batch.forEach(t => results.push({ ...t, category: categoryMap.get(t.id) ?? 'Other' }));

    if (i + 50 < transactions.length) process.stdout.write('.');
  }
  if (transactions.length > 50) process.stdout.write('\n');

  return results;
}

// ── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  if (!fs.existsSync(csvPath)) {
    console.error(`[import] ERROR: ${csvPath} not found`);
    process.exit(1);
  }
  if (!fs.existsSync(DATA_FILE)) {
    console.error(`[import] ERROR: ${DATA_FILE} not found — ensure data/expenses.json exists`);
    process.exit(1);
  }

  const data = JSON.parse(fs.readFileSync(DATA_FILE, 'utf-8'));
  const existingIds = new Set(data.transactions.map(t => t.id));

  const rows = parseCSV(fs.readFileSync(csvPath, 'utf-8'));
  const normalized = detectAndNormalize(rows, csvPath, account)
    .filter(t => t.date && t.description);

  const newTxs = normalized.filter(t => !existingIds.has(t.id));
  const skipped = normalized.length - newTxs.length;

  if (DRY_RUN) {
    console.log(`[import] Dry run: ${newTxs.length} new transactions, ${skipped} duplicates`);
    newTxs.slice(0, 10).forEach(t =>
      console.log(`  ${t.date}  ${t.description.slice(0, 40).padEnd(40)}  $${t.amount.toFixed(2)}`)
    );
    return;
  }

  if (!newTxs.length) {
    console.log(`[import] No new transactions to import (${skipped} duplicates skipped)`);
    return;
  }

  process.stdout.write(`[import] Categorizing ${newTxs.length} transactions...`);
  const categorized = await categorize(newTxs, data.categories);
  process.stdout.write('\n');

  data.transactions.push(...categorized);
  data.transactions.sort((a, b) => b.date.localeCompare(a.date));
  data.meta.total_transactions = data.transactions.length;
  data.meta.last_updated = new Date().toISOString().slice(0, 10);

  fs.writeFileSync(DATA_FILE, JSON.stringify(data, null, 2));

  console.log(`[import] ✅ ${newTxs.length} new transactions imported, ${skipped} duplicates skipped, ${categorized.length} categorized`);
}

main().catch(err => { console.error('[import] ERROR:', err.message); process.exit(1); });
