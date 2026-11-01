import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const sourceRoot = path.join(root, 'data/provinces/cordoba/source');
const outputPath = process.env.CORDOBA_INVENTORY_OUTPUT
  ? path.resolve(process.env.CORDOBA_INVENTORY_OUTPUT)
  : path.join(root, 'docs/CORDOBA_PERCENTAGE_PENDING_POSITIONS_20261026.csv');
const inputFiles = {
  geo50: path.join(sourceRoot, 'gis/carta_suelo_50mil_2025.json'),
  geo100: path.join(sourceRoot, 'gis/carta_suelo_100mil_2025.json'),
  supplement: path.join(root, 'assets/data/cordoba_series_percentage_supplement.json'),
  sheetGeometry: path.join(sourceRoot, 'gis/cartas_provincia_2024_20261026.json'),
  sheetInventory: path.join(sourceRoot, 'SHEET_INVENTORY.md'),
  sourceCatalog: path.join(sourceRoot, 'SOURCES.md'),
  previousReview: path.join(root, 'docs/CORDOBA_PERCENTAGE_RECOVERY_20261026_ES.md'),
};

const readJson = (file) => JSON.parse(fs.readFileSync(file, 'utf8'));
const hashFile = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const records = readJson(inputFiles.supplement).records;
const sheetCollection = readJson(inputFiles.sheetGeometry);
const sheetInventoryText = fs.readFileSync(inputFiles.sheetInventory, 'utf8');
const sourceCatalogText = fs.readFileSync(inputFiles.sourceCatalog, 'utf8');
const previousReviewText = fs.readFileSync(inputFiles.previousReview, 'utf8');

function markdownCells(line) {
  return line.split('|').map((cell) => cell.trim());
}

const inventoryBySheet = new Map();
for (const line of sheetInventoryText.split(/\r?\n/)) {
  if (!/^\| \d{4}-\d+ \|/.test(line)) continue;
  const cells = markdownCells(line);
  const pageLink = (cells[5] ?? '').match(/\[[^\]]+\]\(([^)]+)\)/)?.[1] ?? '';
  const pdfLink = (cells[6] ?? '').match(/\[PDF\]\(([^)]+)\)/)?.[1] ?? '';
  inventoryBySheet.set(cells[1], {
    title: cells[2] ?? '',
    edition: cells[4] ?? '',
    pageUrl: pageLink,
    pdfUrl: pdfLink,
    status: cells[9] ?? '',
  });
}

function urlKey(value) {
  if (!value) return '';
  try {
    const url = new URL(value);
    return `${url.hostname.toLowerCase()}${decodeURIComponent(url.pathname)}`
      .replace(/\/$/, '').toLowerCase();
  } catch {
    return value.toLowerCase();
  }
}

const sourcesBySheet = new Map();
const sourcesByUrl = new Map();
for (const line of sourceCatalogText.split(/\r?\n/)) {
  if (!/^\| `pdf\/.*\.pdf` \|/.test(line)) continue;
  const cells = markdownCells(line);
  const localPath = (cells[1] ?? '').replaceAll('`', '');
  const url = (cells[6] ?? '').match(/\[PDF\]\(([^)]+)\)/)?.[1] ?? '';
  const source = {
    path: localPath,
    exists: fs.existsSync(path.join(sourceRoot, localPath)),
    url,
    sha256: (cells[7] ?? '').match(/[a-f0-9]{64}/i)?.[0] ?? '',
    pages: cells[4] ?? '',
    label: cells[8] ?? '',
    fullMap: !/Cartas de suelo Cordoba\.pdf|\/cfi\//i.test(localPath),
  };
  const sheetCodes = new Set((cells[2] ?? '').match(/\b\d{4}-\d{1,2}\b/g) ?? []);
  for (const code of sheetCodes) {
    if (!sourcesBySheet.has(code)) sourcesBySheet.set(code, []);
    sourcesBySheet.get(code).push(source);
  }
  if (url) {
    const key = urlKey(url);
    if (!sourcesByUrl.has(key)) sourcesByUrl.set(key, []);
    sourcesByUrl.get(key).push(source);
  }
}

function scaleKey(value) {
  return String(value ?? '').replace(/[^0-9]/g, '');
}

function polygons(geometry) {
  if (geometry?.type === 'Polygon') return [geometry.coordinates];
  if (geometry?.type === 'MultiPolygon') return geometry.coordinates;
  return [];
}

function bounds(rings) {
  let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
  for (const [x, y] of rings[0] ?? []) {
    minX = Math.min(minX, x); minY = Math.min(minY, y);
    maxX = Math.max(maxX, x); maxY = Math.max(maxY, y);
  }
  return [minX, minY, maxX, maxY];
}

function overlaps(a, b) {
  return a[0] <= b[2] && a[2] >= b[0] && a[1] <= b[3] && a[3] >= b[1];
}

// Returns 1 inside, 0 on boundary, and -1 outside so edge-only contact is not
// treated as evidence that a unit belongs to a survey sheet.
function pointInRing(point, ring) {
  let inside = false;
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const a = ring[j], b = ring[i];
    const cross = (point[0] - a[0]) * (b[1] - a[1]) - (point[1] - a[1]) * (b[0] - a[0]);
    if (Math.abs(cross) < 1e-10 &&
        point[0] >= Math.min(a[0], b[0]) - 1e-10 && point[0] <= Math.max(a[0], b[0]) + 1e-10 &&
        point[1] >= Math.min(a[1], b[1]) - 1e-10 && point[1] <= Math.max(a[1], b[1]) + 1e-10) return 0;
    if ((b[1] > point[1]) !== (a[1] > point[1]) &&
        point[0] < (a[0] - b[0]) * (point[1] - b[1]) / (a[1] - b[1]) + b[0]) inside = !inside;
  }
  return inside ? 1 : -1;
}

function orientation(a, b, c) {
  return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

function properCross(a, b, c, d) {
  const x = orientation(a, b, c), y = orientation(a, b, d);
  const z = orientation(c, d, a), w = orientation(c, d, b);
  return ((x > 1e-10 && y < -1e-10) || (x < -1e-10 && y > 1e-10)) &&
    ((z > 1e-10 && w < -1e-10) || (z < -1e-10 && w > 1e-10));
}

function ringsCross(a, b) {
  for (let i = 1; i < a.length; i++) {
    const p = a[i - 1], q = a[i];
    const ab = [Math.min(p[0], q[0]), Math.min(p[1], q[1]), Math.max(p[0], q[0]), Math.max(p[1], q[1])];
    for (let j = 1; j < b.length; j++) {
      const r = b[j - 1], s = b[j];
      const bb = [Math.min(r[0], s[0]), Math.min(r[1], s[1]), Math.max(r[0], s[0]), Math.max(r[1], s[1])];
      if (overlaps(ab, bb) && properCross(p, q, r, s)) return true;
    }
  }
  return false;
}

function polygonIntersects(a, b) {
  const outerA = a[0], outerB = b[0];
  if (!outerA || !outerB || !overlaps(bounds(a), bounds(b))) return false;
  if (outerA.some((point) => pointInRing(point, outerB) === 1) ||
      outerB.some((point) => pointInRing(point, outerA) === 1)) return true;
  return ringsCross(outerA, outerB);
}

const preparedSheets = sheetCollection.features.map((feature) => ({
  properties: feature.properties,
  polygons: polygons(feature.geometry).map((rings) => ({ rings, bounds: bounds(rings) })),
}));

function sheetCandidates(feature, dataScale) {
  const unitPolygons = polygons(feature.geometry).map((rings) => ({ rings, bounds: bounds(rings) }));
  const matches = [];
  for (const sheet of preparedSheets) {
    const properties = sheet.properties;
    if (scaleKey(properties.escala) !== scaleKey(dataScale)) continue;
    const intersects = unitPolygons.some((unit) => sheet.polygons.some((outline) =>
      overlaps(unit.bounds, outline.bounds) && polygonIntersects(unit.rings, outline.rings)));
    if (!intersects) continue;
    const index = inventoryBySheet.get(properties.hoja) ?? {};
    const sources = [...(sourcesBySheet.get(properties.hoja) ?? []),
      ...(sourcesByUrl.get(urlKey(index.pdfUrl)) ?? [])];
    const uniqueSources = [...new Map(sources.map((source) => [source.path, source])).values()];
    const localFullPdfs = uniqueSources.filter((source) => source.exists && source.fullMap);
    let coverage, search;
    if (localFullPdfs.length) {
      coverage = 'ARCHIVED_FULL_MAP_PDF';
      search = 'Local full map publication archived; prior report says local full PDFs reviewed, but exact negative passage/page for this occurrence is not preserved.';
    } else if (index.pdfUrl) {
      coverage = 'OFFICIAL_PDF_IDENTIFIED_NOT_ARCHIVED';
      search = 'Official sheet index identifies a PDF URL, but no local full publication is archived; this task did not access or inspect it.';
    } else if (/^verified(?:\s|$)/i.test(index.status ?? '')) {
      coverage = 'OFFICIAL_HTML_NO_PDF';
      search = properties.nombre === 'NOROESTE'
        ? 'Prior Noroeste page lookup recorded; no matching unit-composition passage found.'
        : 'Official HTML page is listed, but full unit-composition review is not evidenced.';
    } else {
      coverage = 'PUBLICATION_NOT_LOCATED';
      search = 'Official sheet index identifies sheet/edition only; no accessible full map-unit publication is recorded in the source inventory.';
    }
    const sourceDetails = (items) => items.map((item) => ({
      path: item.path, exists: item.exists, url: item.url, sha256: item.sha256,
      pages: item.pages, label: item.label, fullMap: item.fullMap,
    }));
    matches.push({
      sheet: properties.hoja,
      name: index.title || properties.nombre,
      edition: index.edition || properties.fecha || '',
      scale: properties.escala,
      coverage,
      pageUrl: index.pageUrl || properties.link || '',
      pdfUrl: index.pdfUrl || '',
      publicationStatus: index.status || '',
      localSources: sourceDetails(localFullPdfs),
      otherArchivedSources: sourceDetails(uniqueSources.filter((source) => source.exists && !source.fullMap)),
      search,
    });
  }
  return matches.sort((a, b) => a.sheet.localeCompare(b.sheet));
}

function reviewedSymbols(scaleLine) {
  const line = previousReviewText.split(/\r?\n/).find((value) => value.startsWith(`${scaleLine}:`));
  if (!line) return new Set();
  return new Set(line.slice(line.indexOf(': ') + 2).split(',').map((value) =>
    value.replaceAll('`', '').trim().replace(/[.:]$/, '')).filter(Boolean));
}

const reviewed50 = reviewedSymbols('1:50.000');
const reviewed100 = reviewedSymbols('1:100.000');
const inaccessibleUnitPdfs = new Set(['CoN', 'MNtc-9', 'MOtc-11', 'MGtc-2']);
const rows = [];
let eligible = 0, sourceNull = 0, supplemented = 0;

for (const [scale, filename] of [
  ['1:50.000', 'carta_suelo_50mil_2025.json'],
  ['1:100.000', 'carta_suelo_100mil_2025.json'],
]) {
  const collection = readJson(path.join(sourceRoot, 'gis', filename));
  for (const feature of collection.features) {
    const properties = feature.properties;
    const recordId = String(properties.id);
    const symbol = properties.simbolo || properties.SIMBC || '';
    const supplement = records[recordId];
    for (let slot = 1; slot <= 8; slot++) {
      const series = properties[`serie_${slot}`];
      if (typeof series !== 'string' || !series.trim() || series !== series.toUpperCase()) continue;
      eligible++;
      const rawPercentage = properties[`porc_${slot}`];
      if (rawPercentage !== null && rawPercentage !== undefined && String(rawPercentage).trim()) continue;
      sourceNull++;
      const phase = properties[`fase_${slot}`] || '';
      const exact = (supplement?.individualPercentages ?? []).find((entry) =>
        entry.classification === 'EXACT_INDIVIDUAL' && entry.series === series &&
        String(entry.phase || '') === String(phase));
      if (exact) { supplemented++; continue; }
      const aggregate = (supplement?.aggregateCompositions ?? []).find((entry) =>
        entry.classification === 'AGGREGATE_ONLY' && entry.series?.includes(series));
      const kind = aggregate ? 'AGGREGATE_ONLY' : symbol === 'EAr'
        ? 'DOCUMENTED_NON_ESTIMABLE' : 'UNKNOWN_INDIVIDUAL';
      const sheets = sheetCandidates(feature, scale);
      const inaccessible = inaccessibleUnitPdfs.has(symbol);
      const reviewedSet = scale === '1:50.000' ? reviewed50 : reviewed100;
      const unitPdfReview = inaccessible
        ? 'OFFICIAL_IDECOR_UNIT_PDF_PREVIOUSLY_HTTP_403'
        : reviewedSet.has(symbol)
          ? 'IN_PRIOR_IDECOR_SYMBOL_SCALE_REVIEW; exact unit-level negative passage/page was not retained.'
          : 'NOT_IN_PRIOR_IDECOR_SYMBOL_SCALE_LIST; do not assume the unit-specific PDF was reviewed.';
      const coverage = [...new Set(sheets.map((sheet) => sheet.coverage))].join(';') || 'NO_SHEET_INTERSECTION';
      const search = [...new Set(sheets.map((sheet) => sheet.search))].join(' || ') ||
        'No intersecting sheet; do not assign a publication by proximity.';
      const reason = kind === 'AGGREGATE_ONLY'
        ? 'Source gives only a shared aggregate; it does not provide an individual split.'
        : kind === 'DOCUMENTED_NON_ESTIMABLE'
          ? 'The reviewed source says the individual contribution could not be estimated.'
          : 'Source POR is null and no exact individual proportion is verified for this record/series; do not infer or split totals.';
      rows.push({
        province: 'Córdoba', scale, recordId, symbol, slot, series, phase, kind,
        sheets, coverage, archivedSources: [...new Map(sheets.flatMap((sheet) => sheet.localSources)
          .map((source) => [source.path, source])).values()], search, unitPdfReview,
        aggregateEvidence: aggregate?.evidence || '', reason,
      });
    }
  }
}

rows.sort((a, b) => (a.scale === '1:50.000' ? 0 : 1) - (b.scale === '1:50.000' ? 0 : 1) ||
  Number(a.recordId) - Number(b.recordId) || a.slot - b.slot);

const headers = [
  'province', 'data_scale', 'source_record_id', 'map_unit_symbol', 'series_slot', 'series_name',
  'phase', 'pending_classification', 'candidate_sheets_and_publications_json', 'coverage_status',
  'archived_sources_json', 'prior_search_and_passages', 'aggregate_evidence', 'unresolved_reason',
  'idecor_individual_unit_pdf_review_status',
];
const quote = (value) => {
  const text = String(value ?? '');
  return /[",\r\n]/.test(text) ? `"${text.replaceAll('"', '""')}"` : text;
};
const csv = [headers.join(',')];
for (const row of rows) csv.push([
  row.province, row.scale, row.recordId, row.symbol, row.slot, row.series, row.phase, row.kind,
  JSON.stringify(row.sheets), row.coverage, JSON.stringify(row.archivedSources), row.search,
  row.aggregateEvidence, row.reason, row.unitPdfReview,
].map(quote).join(','));
fs.writeFileSync(outputPath, `${csv.join('\r\n')}\r\n`, 'utf8');

const counts = { eligible, sourceNull, supplemented, remaining: rows.length, byScale: {}, byKind: {}, byCoverage: {} };
for (const row of rows) {
  counts.byScale[row.scale] = (counts.byScale[row.scale] ?? 0) + 1;
  counts.byKind[row.kind] = (counts.byKind[row.kind] ?? 0) + 1;
  counts.byCoverage[row.coverage] = (counts.byCoverage[row.coverage] ?? 0) + 1;
}
const inputHashes = Object.fromEntries(Object.entries(inputFiles).map(([key, file]) => [key, hashFile(file)]));
console.log(JSON.stringify({ ...counts, output: path.relative(root, outputPath), outputSha256: hashFile(outputPath), inputHashes }, null, 2));
