const fs = require('fs');
const path = require('path');
const { LRUCache } = require('lru-cache');
const Database = require('better-sqlite3');

const htmlExtractor = require('./html-extractor');
const pluginDocsConfig = require('../../config/plugin-docs.config');

/**
 * MBS-Source-Adapter
 *
 * Kennt die Verzeichnisstruktur und den SQLite-Index der MBS-Doku. Wandelt
 * einen Funktionsnamen wie "List.AddPrefix" in eine HTML-Datei und delegiert
 * die Extraktion an den generischen html-extractor.
 *
 * Architektur-Hinweis: Der Server läuft in `READ_ONLY`-Modus auf einer
 * Kopie der DuckDB. Hier öffnen wir einen davon unabhängigen SQLite-Reader
 * auf `docs/mbs/docSet.dsidx` (read-only). Kein DuckDB-Touch.
 */

// ─── Cache-Setup ─────────────────────────────────────────────────────────
// Path-Lookup: Funktionsname → HTML-Dateiname (klein, wertvoll)
const pathCache = new LRUCache({
  max: pluginDocsConfig.cacheMaxPaths,
  ttl: pluginDocsConfig.cacheTTL,
});

// Extracted-Doc-Cache: Funktionsname → { short, long, metadata }
const docCache = new LRUCache({
  max: pluginDocsConfig.cacheMaxDocs,
  ttl: pluginDocsConfig.cacheTTL,
});

let dbHandle = null; // better-sqlite3 Database (lazy init)
let dbInitTried = false;
let dbInitError = null;

// Komponenten-Zuordnung (lazy, prozessweit) — siehe getComponentMap().
let componentMap = null;

// Exakte Schreibweise der Rubriken aus dem Index (lazy) — die Rubrik-Route ist
// case-SENSITIV, die Doku schreibt Komponenten aber uneinheitlich
// (`Webview` auf der Funktionsseite, `WebView` im Index). Key = lowercase.
let categoryNameMap = null;

const SOURCE_ID = 'mbs';

function getMbsConfig() {
  return pluginDocsConfig.sources[SOURCE_ID];
}

function getIndexPath() {
  const cfg = getMbsConfig();
  return path.join(cfg.rootPath, cfg.indexFile);
}

function getDocsDir() {
  const cfg = getMbsConfig();
  return path.join(cfg.rootPath, cfg.docsDir);
}

/**
 * Liefert TRUE, wenn die MBS-Doku verfügbar ist (Verzeichnis existiert,
 * Index-Datei lesbar). Wird beim Server-Start aufgerufen, um die Quelle
 * im Status-Endpoint zu markieren.
 */
function isAvailable() {
  const cfg = getMbsConfig();
  if (!cfg || !cfg.rootPath) return false;
  try {
    const stat = fs.statSync(cfg.rootPath);
    if (!stat.isDirectory()) return false;
    fs.accessSync(getIndexPath(), fs.constants.R_OK);
    fs.accessSync(getDocsDir(), fs.constants.R_OK);
    return true;
  } catch {
    return false;
  }
}

/**
 * Lazy-init der SQLite-Verbindung. Im Fehlerfall (z.B. Datei fehlt) wird
 * `dbInitError` gesetzt und alle nachfolgenden Lookups werfen einen
 * deklarativen Error mit `code: 'PLUGIN_DOC_NOT_INSTALLED'`.
 */
function getDb() {
  if (dbHandle) return dbHandle;
  if (dbInitTried) {
    if (dbInitError) throw dbInitError;
    return dbHandle;
  }
  dbInitTried = true;

  const indexPath = getIndexPath();
  if (!fs.existsSync(indexPath)) {
    const err = new Error(`MBS-Doku-Index nicht gefunden: ${indexPath}`);
    err.code = 'PLUGIN_DOC_NOT_INSTALLED';
    err.source = SOURCE_ID;
    dbInitError = err;
    throw err;
  }

  try {
    dbHandle = new Database(indexPath, { readonly: true, fileMustExist: true });
    return dbHandle;
  } catch (e) {
    const err = new Error(`SQLite-Index konnte nicht geöffnet werden: ${e.message}`);
    err.code = 'PLUGIN_DOC_NOT_INSTALLED';
    err.source = SOURCE_ID;
    err.cause = e;
    dbInitError = err;
    throw err;
  }
}

/**
 * Resolver: Funktionsname → HTML-Dateiname (z.B. "ListAddPrefix.html").
 * Liefert NULL, wenn nicht im Index.
 */
function resolveDocPath(fnName) {
  const cached = pathCache.get(fnName);
  if (cached !== undefined) return cached;

  const db = getDb();
  const stmt = db.prepare(
    "SELECT path FROM searchIndex WHERE type='Function' AND name = ? LIMIT 1"
  );
  const row = stmt.get(fnName);
  const result = row ? row.path : null;
  pathCache.set(fnName, result);
  return result;
}

/**
 * Liefert bis zu `limit` Funktionsnamen, die als Vorschlag bei einem
 * `PLUGIN_FUNCTION_NOT_FOUND`-Fehler zurückgegeben werden. Strategie:
 *   1) LIKE 'name%' (Präfix-Match, z.B. "List." → "List.AddPrefix" …)
 *   2) ergänzt um LIKE '%name%' (Substring-Match) bis zum Limit.
 */
function suggestFunctions(fnName, limit = 10) {
  const db = getDb();
  const trimmed = String(fnName || '').trim();
  if (!trimmed) return [];

  const prefixStmt = db.prepare(
    "SELECT name FROM searchIndex WHERE type='Function' AND name LIKE ? ORDER BY name LIMIT ?"
  );
  const prefix = prefixStmt.all(`${trimmed}%`, limit).map((r) => r.name);

  if (prefix.length >= limit) return prefix;

  const remaining = limit - prefix.length;
  const seen = new Set(prefix);
  const substringStmt = db.prepare(
    "SELECT name FROM searchIndex WHERE type='Function' AND name LIKE ? AND name NOT LIKE ? ORDER BY name LIMIT ?"
  );
  const substring = substringStmt
    .all(`%${trimmed}%`, `${trimmed}%`, remaining)
    .map((r) => r.name)
    .filter((n) => !seen.has(n));

  return prefix.concat(substring).slice(0, limit);
}

/**
 * Lädt eine Funktion und liefert das Ergebnis als
 * `{ source, function, found, metadata, short, long }` — bereits in der
 * Form, die der Controller direkt durchreichen kann.
 *
 * Wirft Errors mit aussagekräftigem `code` für die bekannten Fehlerfälle:
 *   - PLUGIN_DOC_NOT_INSTALLED     — docs/mbs/ fehlt
 *   - PLUGIN_FUNCTION_NOT_FOUND    — Name nicht im SQLite-Index
 *   - PLUGIN_DOC_FILE_MISSING      — Index zeigt auf nicht vorhandene Datei
 */
function getFunctionDoc(fnName) {
  if (!fnName || typeof fnName !== 'string') {
    const err = new Error('Funktionsname ist leer oder ungültig');
    err.code = 'VALIDATION_ERROR';
    throw err;
  }

  const cached = docCache.get(fnName);
  if (cached) return cached;

  const docPath = resolveDocPath(fnName);
  if (!docPath) {
    const err = new Error(`MBS-Funktion nicht im Index: ${fnName}`);
    err.code = 'PLUGIN_FUNCTION_NOT_FOUND';
    err.source = SOURCE_ID;
    err.suggestions = suggestFunctions(fnName, 10);
    throw err;
  }

  const fullPath = path.join(getDocsDir(), docPath);
  if (!fs.existsSync(fullPath)) {
    const err = new Error(`HTML-Datei zur Funktion ${fnName} fehlt: ${docPath}`);
    err.code = 'PLUGIN_DOC_FILE_MISSING';
    err.source = SOURCE_ID;
    err.docPath = docPath;
    throw err;
  }

  const html = fs.readFileSync(fullPath, 'utf-8');
  const extracted = htmlExtractor.extract(html, { sourceId: SOURCE_ID });
  if (!extracted) {
    const err = new Error(`HTML-Datei konnte nicht geparst werden: ${docPath}`);
    err.code = 'PLUGIN_DOC_FILE_MISSING';
    err.source = SOURCE_ID;
    err.docPath = docPath;
    throw err;
  }

  // Ergänze externe URL aus der Konfiguration
  const cfg = getMbsConfig();
  const result = {
    source: SOURCE_ID,
    function: fnName,
    found: true,
    metadata: {
      ...extracted.metadata,
      url: cfg.externalUrl(fnName),
    },
    short: { format: 'html', content: extracted.short },
    long: { format: 'html', content: extracted.long },
  };

  docCache.set(fnName, result);
  return result;
}

// ─── Komponenten-Zuordnung ───────────────────────────────────────────────
// Der Doku-Index kennt pro Funktion nur Name und Dateipfad. Welche Komponente
// (= Rubrik) eine Funktion hat, steht auf ihrer Doku-Seite und wird beim
// Doku-Install nach reference/mbs_component_exceptions.csv abgeleitet.
//
// Die Namens-Heuristik `<Komponente>.<Funktion>` trägt nur für den Regelfall:
// ~1.000 Funktionen weichen ab (Funktionen ohne Punkt wie `IsError` gehören zu
// `Plugin`), 121 sind in mehreren Komponenten gelistet. Ohne die Tabelle bleiben
// diese Funktionen in keiner Rubrik auffindbar.
//
// Auflösung je Funktion (identisch mit Import-Pipeline und Objekt-Filter):
//   Primärkomponente = CSV-Eintrag, sonst Namenspräfix
// Zusätzlich liefert die CSV-Spalte `Components` die vollständige Liste; alles
// jenseits der Primärkomponente ist eine Zweit-Mitgliedschaft.

/**
 * Zerlegt eine CSV-Zeile mit optionalen Anführungszeichen. Reicht für die
 * schmale Zuordnungstabelle (drei Spalten, keine Zeilenumbrüche in Werten).
 */
function parseCsvLine(line) {
  const out = [];
  let cur = '';
  let quoted = false;
  for (let i = 0; i < line.length; i += 1) {
    const ch = line[i];
    if (quoted) {
      if (ch === '"') {
        if (line[i + 1] === '"') { cur += '"'; i += 1; } else { quoted = false; }
      } else cur += ch;
    } else if (ch === '"') {
      quoted = true;
    } else if (ch === ',') {
      out.push(cur); cur = '';
    } else cur += ch;
  }
  out.push(cur);
  return out.map((v) => v.trim());
}

/**
 * Lädt die Zuordnungstabelle einmal pro Prozess.
 * Rückgabe: `Map<Funktionsname, string[]>` (Komponenten in Doku-Reihenfolge,
 * erste = Primärkomponente). Fehlt die Datei, bleibt die Map leer und es
 * greift überall der Namenspräfix — der bisherige Stand, nur ohne Ausnahmen.
 */
function getComponentMap() {
  if (componentMap) return componentMap;
  componentMap = new Map();

  const cfg = getMbsConfig();
  const file = cfg && cfg.componentMapFile;
  if (!file || !fs.existsSync(file)) {
    console.warn(
      `MBS-Komponenten-Tabelle nicht gefunden (${file || 'nicht konfiguriert'}) — ` +
      'Rubriken fallen auf die Namens-Heuristik zurück (install-mbs-docs erzeugt sie neu).'
    );
    return componentMap;
  }

  const text = fs.readFileSync(file, 'utf-8');
  const lines = text.split(/\r?\n/).filter((l) => l.trim() !== '');
  if (!lines.length) return componentMap;

  const header = parseCsvLine(lines[0]);
  const idxName = header.indexOf('Funktionsname');
  const idxPrimary = header.indexOf('Component');
  const idxAll = header.indexOf('Components');
  if (idxName < 0 || idxPrimary < 0) return componentMap;

  for (let i = 1; i < lines.length; i += 1) {
    const cells = parseCsvLine(lines[i]);
    const name = cells[idxName];
    if (!name) continue;
    const all = idxAll >= 0 && cells[idxAll]
      ? cells[idxAll].split(',').map((c) => c.trim()).filter(Boolean)
      : [];
    const primary = cells[idxPrimary];
    const list = all.length ? all : (primary ? [primary] : []);
    if (list.length) componentMap.set(name, list);
  }
  return componentMap;
}

/** Komponenten einer Funktion; ohne Tabelleneintrag greift der Namenspräfix. */
function componentsOf(fnName) {
  const mapped = getComponentMap().get(fnName);
  if (mapped && mapped.length) return mapped;
  const dot = fnName.indexOf('.');
  return dot > 0 ? [fnName.slice(0, dot)] : [];
}

/**
 * Kategorienamen aus dem Index vergleichen. Die Doku schreibt einzelne
 * Komponenten uneinheitlich (`Webview` auf der Funktionsseite, `WebView` im
 * Index) — Vergleiche laufen daher case-insensitiv.
 */
function sameComponent(a, b) {
  return String(a || '').toLowerCase() === String(b || '').toLowerCase();
}

/**
 * Baut die Mitgliederliste je Kategorie in einem Durchlauf über den Index.
 * Rückgabe: `Map<lowercase(Kategorie), { primary: [], secondary: [] }>`, beide
 * Listen nach Funktionsname sortiert. `secondary`-Einträge tragen zusätzlich
 * die Primärkomponente, damit die Rubrikseite sie ausweisen kann.
 */
function buildMembership() {
  const db = getDb();
  const rows = db.prepare(
    "SELECT name, path FROM searchIndex WHERE type='Function' ORDER BY name"
  ).all();

  const byComponent = new Map();
  const bucket = (component) => {
    const key = String(component).toLowerCase();
    if (!byComponent.has(key)) byComponent.set(key, { primary: [], secondary: [] });
    return byComponent.get(key);
  };

  for (const row of rows) {
    const comps = componentsOf(row.name);
    if (!comps.length) continue;
    bucket(comps[0]).primary.push({ name: row.name, path: row.path, primaryComponent: comps[0] });
    for (const extra of comps.slice(1)) {
      if (sameComponent(extra, comps[0])) continue;
      bucket(extra).secondary.push({ name: row.name, path: row.path, primaryComponent: comps[0] });
    }
  }
  return byComponent;
}

let membershipCache = null;
function getMembership() {
  if (!membershipCache) membershipCache = buildMembership();
  return membershipCache;
}

/**
 * Liefert die Kategorien-Liste aus dem SQLite-Index. Mit `withFunctionCounts`
 * wird zusätzlich pro Kategorie die Anzahl ihrer Funktionen ermittelt.
 *
 * Gezählt werden nur Primär-Mitglieder — dieselbe Grundgesamtheit wie im
 * Objekt-Katalog und im Kategorie-Filter, damit Zähler und Badge übereinstimmen.
 * Zweit-Mitgliedschaften erscheinen auf der Rubrikseite als eigener Abschnitt.
 *
 * Rückgabe: Array von `{ name, path, functionCount? }`.
 */
function listCategories({ withFunctionCounts = false } = {}) {
  const db = getDb();
  const stmt = db.prepare(
    "SELECT name, path FROM searchIndex WHERE type='Category' ORDER BY name"
  );
  const rows = stmt.all();

  if (!withFunctionCounts) return rows;

  const membership = getMembership();
  return rows.map((r) => ({
    ...r,
    functionCount: (membership.get(String(r.name).toLowerCase())?.primary.length) || 0,
  }));
}

/** Rubriknamen des Index in ihrer exakten Schreibweise, nach lowercase indiziert. */
function getCategoryNameMap() {
  if (categoryNameMap) return categoryNameMap;
  categoryNameMap = new Map();
  for (const row of listCategories()) {
    categoryNameMap.set(String(row.name).toLowerCase(), row.name);
  }
  return categoryNameMap;
}

/**
 * Adresse der Doku-Seite einer Funktion im Doku-Browser:
 * `{ category, entry }` → `/docs/mbs/<category>/<entry>`.
 *
 * NULL, wenn die Doku nicht installiert ist, die Funktion nicht im Index steht
 * oder ihre Komponente keine Rubrikseite hat — der Aufrufer rendert den Link
 * dann gar nicht erst, statt ins Leere zu zeigen. Die Rubrik kommt in der
 * EXAKTEN Schreibweise des Index zurück (die Rubrik-Route ist case-sensitiv).
 */
function resolveEntryRef(fnName) {
  if (!fnName) return null;
  try {
    if (!resolveDocPath(fnName)) return null;
    const comps = componentsOf(fnName);
    if (!comps.length) return null;
    const exact = getCategoryNameMap().get(String(comps[0]).toLowerCase());
    return exact ? { category: exact, entry: fnName } : null;
  } catch {
    // Doku nicht installiert / Index nicht lesbar — kein Fehler, nur kein Link.
    return null;
  }
}

/**
 * Adresse der Rubrikseite einer Komponente im Doku-Browser: `{ category }` →
 * `/docs/mbs/<category>`. NULL, wenn die Doku nicht installiert ist oder die
 * Komponente keine Rubrikseite (mehr) hat — Alt-Komponenten wie `Addressbook`
 * stehen noch in der Plattform-Map, aber nicht mehr im Doku-Index.
 *
 * Die Rubrik kommt in der EXAKTEN Schreibweise des Index zurück: die
 * Rubrik-Route ist case-sensitiv.
 */
function resolveCategoryRef(categoryName) {
  if (!categoryName) return null;
  try {
    const exact = getCategoryNameMap().get(String(categoryName).toLowerCase());
    return exact ? { category: exact } : null;
  } catch {
    return null;
  }
}

/**
 * Funktionen innerhalb einer Kategorie — aufgelöst über die Komponenten-
 * Zuordnung (siehe getComponentMap), nicht über den Funktionsnamen.
 *
 * Reihenfolge: erst alle Primär-Mitglieder alphabetisch, danach die Zweit-
 * Mitglieder (Funktionen, die MBS zusätzlich auf dieser Komponentenseite
 * führt), gruppiert nach ihrer Primärkomponente. Damit bleiben die Gruppen
 * für die Listendarstellung zusammenhängend.
 *
 * `total` zählt nur die Primär-Mitglieder — dieselbe Grundgesamtheit wie der
 * Zähler auf der Übersichtsseite und der Objekt-Filter.
 *
 * Rückgabe: `{ exists, total, secondaryTotal, results: [{ name, path,
 * secondaryOf }] }` — `secondaryOf` ist die Primärkomponente einer Zweit-
 * Mitgliedschaft, sonst null.
 */
function listFunctionsInCategory(categoryName, { limit = 200, offset = 0 } = {}) {
  const db = getDb();
  const trimmed = String(categoryName || '').trim();
  if (!trimmed) return { exists: false, total: 0, secondaryTotal: 0, results: [] };

  const catStmt = db.prepare(
    "SELECT name FROM searchIndex WHERE type='Category' AND name = ? LIMIT 1"
  );
  const cat = catStmt.get(trimmed);
  if (!cat) return { exists: false, total: 0, secondaryTotal: 0, results: [] };

  const entry = getMembership().get(trimmed.toLowerCase()) || { primary: [], secondary: [] };
  const secondary = [...entry.secondary].sort(
    (a, b) => a.primaryComponent.localeCompare(b.primaryComponent) || a.name.localeCompare(b.name)
  );

  const ordered = [
    ...entry.primary.map((f) => ({ name: f.name, path: f.path, secondaryOf: null })),
    ...secondary.map((f) => ({ name: f.name, path: f.path, secondaryOf: f.primaryComponent })),
  ];

  return {
    exists: true,
    total: entry.primary.length,
    secondaryTotal: secondary.length,
    results: ordered.slice(offset, offset + limit),
  };
}

/**
 * Volltextsuche über Funktionsnamen. Strategie analog zu `suggestFunctions`,
 * aber mit konfigurierbarem Limit/Offset und Kennzeichnung des Match-Typs
 * (`prefix` zuerst, dann `substring`).
 *
 * Rückgabe: `{ total, results: [{ name, path, match }] }`.
 */
function searchFunctions(query, { limit = 50, offset = 0 } = {}) {
  const db = getDb();
  const trimmed = String(query || '').trim();
  if (!trimmed) return { total: 0, results: [] };

  // Total: alle Funktionen, die irgendwo den Suchbegriff enthalten.
  const totalStmt = db.prepare(
    "SELECT COUNT(*) AS cnt FROM searchIndex WHERE type='Function' AND name LIKE ?"
  );
  const total = totalStmt.get(`%${trimmed}%`).cnt;
  if (total === 0) return { total: 0, results: [] };

  // Kombinierte Sortierung: erst Präfix-Treffer, dann Substring-Treffer,
  // jeweils alphabetisch. Klassisch in einer Query mit CASE als Sortkey.
  const stmt = db.prepare(
    "SELECT name, path, " +
    "  CASE WHEN name LIKE ? THEN 'prefix' ELSE 'substring' END AS match_type " +
    "FROM searchIndex " +
    "WHERE type='Function' AND name LIKE ? " +
    "ORDER BY CASE WHEN name LIKE ? THEN 0 ELSE 1 END, name " +
    "LIMIT ? OFFSET ?"
  );
  const prefixPattern = `${trimmed}%`;
  const substringPattern = `%${trimmed}%`;
  const rows = stmt.all(
    prefixPattern,
    substringPattern,
    prefixPattern,
    limit,
    offset
  );
  return {
    total,
    results: rows.map((r) => ({ name: r.name, path: r.path, match: r.match_type })),
  };
}

/**
 * Rubrikübergreifende Eintragssuche, konsolidiert auf Komponenten-Ebene.
 *
 * Ungedeckelt: es wird über ALLE Mitglieder aggregiert, nur das Beleg-Sample
 * pro Rubrik ist begrenzt. Ein vorgelagerter Treffer-Cap (wie in
 * `searchFunctions`) würde stillschweigend ganze Rubriken unterschlagen.
 *
 * Die Mitgliederlisten kommen aus `getMembership()` — derselben Auflösung, die
 * auch die Rubrikseite füllt. Damit kann der Beleg keine Funktion nennen, die
 * in der Zielrubrik dann fehlt. Gezählt werden nur Primär-Mitglieder, dieselbe
 * Grundgesamtheit wie `entry_count` und der Objekt-Filter.
 *
 * Sample-Reihenfolge: Präfix-Treffer vor Substring-Treffern, darin alphabetisch.
 *
 * Rückgabe: `[{ category, hitCount, sample: string[] }]`, nach Trefferzahl
 * absteigend.
 */
function searchByComponent(query, { sample = 5 } = {}) {
  const trimmed = String(query || '').trim();
  if (!trimmed) return [];
  const needle = trimmed.toLowerCase();

  const membership = getMembership();
  const out = [];
  // Der Index-Kategoriename ist maßgeblich — er ist das Deep-Link-Ziel der
  // Rubrikseite. Die Mitglieder liegen unter dem case-insensitiven Schlüssel
  // (die Doku schreibt `Webview`/`WebView` uneinheitlich, siehe sameComponent).
  for (const cat of listCategories()) {
    const entry = membership.get(String(cat.name).toLowerCase());
    if (!entry) continue;
    const hits = entry.primary.filter((f) => f.name.toLowerCase().includes(needle));
    if (!hits.length) continue;
    const ordered = hits.slice().sort((a, b) => {
      const ap = a.name.toLowerCase().startsWith(needle) ? 0 : 1;
      const bp = b.name.toLowerCase().startsWith(needle) ? 0 : 1;
      return ap - bp || a.name.localeCompare(b.name, 'en');
    });
    out.push({
      category: cat.name,
      hitCount: hits.length,
      sample: ordered.slice(0, Math.max(0, sample)).map((f) => f.name),
    });
  }
  out.sort((a, b) => b.hitCount - a.hitCount || a.category.localeCompare(b.category, 'en'));
  return out;
}

/**
 * Status-Information für /api/plugin-docs Endpoint.
 */
function getStatus() {
  const cfg = getMbsConfig();
  const available = isAvailable();
  const status = {
    id: SOURCE_ID,
    label: cfg.label,
    publisher: cfg.publisher,
    homepage: cfg.homepage,
    available,
    path: cfg.rootPath,
  };

  if (!available) return status;

  // Versions-Info aus .version Datei (sofern vorhanden) auslesen
  try {
    const versionPath = path.join(cfg.rootPath, cfg.versionFile);
    if (fs.existsSync(versionPath)) {
      status.version = fs.readFileSync(versionPath, 'utf-8').trim();
    }
  } catch {
    // ignorierbar
  }

  // Funktion- und Kategorie-Anzahl aus SQLite
  try {
    const db = getDb();
    const countStmt = db.prepare(
      "SELECT type, COUNT(*) AS count FROM searchIndex GROUP BY type"
    );
    const counts = countStmt.all();
    status.counts = counts.reduce((acc, r) => {
      acc[r.type.toLowerCase()] = r.count;
      return acc;
    }, {});
  } catch {
    // ignorierbar — Quelle bleibt available, aber ohne Counts
  }

  return status;
}

/**
 * Cache leeren — z.B. nach Doku-Update durch `install-mbs-docs`.
 */
function clearCaches() {
  pathCache.clear();
  docCache.clear();
  componentMap = null;
  membershipCache = null;
  categoryNameMap = null;
}

module.exports = {
  id: SOURCE_ID,
  isAvailable,
  getStatus,
  getFunctionDoc,
  suggestFunctions,
  resolveDocPath,
  resolveEntryRef,
  resolveCategoryRef,
  listCategories,
  listFunctionsInCategory,
  searchFunctions,
  searchByComponent,
  clearCaches,
};
