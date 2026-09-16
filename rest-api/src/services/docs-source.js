const db = require('../config/database');
const docsManifest = require('./docs-manifest');
const adapters = require('./plugin-docs/adapters');
const docsContent = require('./docs-content');
const { sqlPluginSubName } = require('../utils/plugin-name');

/**
 * Docs Source Service (v2)
 *
 * Vermittelt zwischen Dashboards/REST-Endpoints und der Adapter-Registry für
 * Doc-Set-Indizes. Hält die alte Funktionsschnittstelle aufrecht
 * (`getDocsetInfo` / `listDocsetCategories` / `getDocsetCategoryInfo` /
 * `listDocsetFunctions`), delegiert intern aber auf die einheitlichen Adapter
 * (siehe rest-api/src/services/plugin-docs/adapters/).
 *
 * Action-Builder (openDashboard / openUrl etc.) bleiben hier, damit die
 * Adapter-Schnittstelle (`IDocSetIndex`) frei von UI-Spezifika bleibt.
 */

function resolveAdapter(id) {
  const catalog = docsManifest.getCatalogEntry(id);
  const installed = docsManifest.getInstalledEntry(id);
  if (!catalog) return null;
  return adapters.resolveForDocset(catalog, installed);
}

function ctxOf(id) {
  return {
    catalog: docsManifest.getCatalogEntry(id),
    installed: docsManifest.getInstalledEntry(id),
  };
}

/**
 * Localized "Open online ↗"-Label, gebaut aus dem Sprach-Param der API-Request.
 * Wir lokalisieren hier serverseitig, weil die Dashboard-Markdown-Templates
 * den Wert direkt einbetten und keine i18n-Brücke ins Frontend haben.
 *
 * Fallback ist Englisch. Sprachen ohne explizite Übersetzung erben dem EN-Label.
 */
const OPEN_ONLINE_LABELS = {
  de: 'Online öffnen ↗',
  en: 'Open online ↗',
  fr: 'Ouvrir en ligne ↗',
  es: 'Abrir en línea ↗',
  it: 'Apri online ↗',
  nl: 'Online openen ↗',
  pt: 'Abrir online ↗',
  sv: 'Öppna online ↗',
  ja: 'オンラインで開く ↗',
  ko: '온라인으로 열기 ↗',
  zh: '在线打开 ↗',
};

function onlineLinkLabel(lang) {
  return OPEN_ONLINE_LABELS[lang] || OPEN_ONLINE_LABELS.en;
}

/**
 * Erzeugt ein Markdown-Link-Snippet `[Online öffnen ↗](url)`. Leerer String,
 * wenn keine URL vorliegt — verhindert tote `[label]()`-Links im Hero.
 */
function onlineLinkMd(url, lang) {
  if (!url) return '';
  return `[${onlineLinkLabel(lang)}](${url})`;
}

// ---------------------------------------------------------------------------
// Action-URLs (Frontend-spezifisch — gehört nicht in den Adapter)
// ---------------------------------------------------------------------------

function buildCategoryAction(setId, cat) {
  // markdown-fs-Root-Seiten (kind 'page') haben keine Zwischenebene — die
  // Category IST die Page, Klick öffnet direkt die DocsEntryView mit
  // Slug == Category-ID. Alles andere (markdown-fs-Ordner, indizierte
  // Categories von claris-help/mbs) navigiert zur Category-Seite mit der
  // enthaltenen Einträge-Liste.
  if (cat.kind === 'page') {
    return {
      action: 'openDocsEntry',
      action_args: `set=${encodeURIComponent(setId)}&category=${encodeURIComponent(cat.id)}&fn=${encodeURIComponent(cat.id)}`,
    };
  }
  return {
    action: 'navigate',
    action_args: `path=/docs/${encodeURIComponent(setId)}/${encodeURIComponent(cat.id)}`,
  };
}

/**
 * Pill-Click-Action auf einer Category-Zeile (docset_home): zur Suchergebnis-
 * Ansicht aller Pseudo-Objects dieser Category. Der `category`-Filter matcht
 * gegen den englischen Kanon-Namen (siehe aggregations.js → cat_agg.category).
 *   - MBS: type=PluginFunction, category=<Component-Name> (Englisch wie z.B. "JSON").
 *   - Claris fn-Categories:  type=BuiltinFunction, category=<name_en>.
 *   - Claris ss-Categories:  type=ScriptStepType,  category=<name_en>.
 */
function buildCategoryBadgeAction(setId, cat) {
  let type = null;
  let catName = null;
  if (setId === 'mbs') {
    type = 'PluginFunction';
    catName = cat.id || cat.name;     // MBS: id == name == englischer Component-Name
  } else if (setId === 'claris-help') {
    type = cat.kind === 'script_step' ? 'ScriptStepType' : 'BuiltinFunction';
    catName = cat.name_en || cat.name;
  }
  if (!type || !catName) return { action: '', action_args: '' };
  return {
    action: 'applyFilter',
    action_args: `type=${encodeURIComponent(type)}&category=${encodeURIComponent(catName)}`,
  };
}

/**
 * Überschrift für den Abschnitt der Zweit-Mitglieder einer Rubrik.
 *
 * MBS führt 121 Funktionen auf mehreren Komponentenseiten (z.B.
 * `FM.ExecuteFileSQL` unter FM und FMSQL). Gezählt und gefiltert werden sie
 * über ihre Primärkomponente — auf der Zweit-Rubrik erscheinen sie deshalb
 * unterhalb eines eigenen Abschnitts statt in der Hauptliste.
 */
const SECONDARY_SECTION_LABELS = {
  de: (comp) => `Weitere Funktionen dieser Komponente · Primär: ${comp}`,
  en: (comp) => `Also listed in this component · primary: ${comp}`,
};

function secondarySection(primaryComponent, lang) {
  if (!primaryComponent) return '';
  const build = SECONDARY_SECTION_LABELS[lang] || SECONDARY_SECTION_LABELS.en;
  return build(primaryComponent);
}

function buildFunctionAction(setId, fn, lang, categoryId) {
  // Neue Route /docs/:set/:category/:fn → DocsEntryView.
  // Wir behalten `source_url` für die Code-Referenz-Auflösung und das alte
  // openObject-Fallback, falls ein Konsument den Mirror-Endpoint direkt
  // braucht (z.B. ohne SPA).
  const cat = categoryId || fn.category_id || fn.categoryId || '';
  const args = `set=${encodeURIComponent(setId)}&category=${encodeURIComponent(cat)}&fn=${encodeURIComponent(fn.id)}&lang=${encodeURIComponent(lang || 'en')}`;

  // source_url bleibt der lokale Mirror-Pfad (für externe Tools / Direkt-Links).
  let sourceUrl = null;
  if (setId === 'claris-help') {
    const slug = fn.slug || fn.canonical;
    if (slug) sourceUrl = `/api/reference/help/${encodeURIComponent(lang || 'en')}/${encodeURIComponent(slug)}`;
  } else if (setId === 'mbs') {
    sourceUrl = `/api/plugin-docs/mbs/${encodeURIComponent(fn.id)}/page`;
  }

  return {
    action: 'openDocsEntry',
    action_args: args,
    source_url: sourceUrl,
  };
}

// ---------------------------------------------------------------------------
// Public surface — kompatibel mit dashboard.service.js Builtins
// ---------------------------------------------------------------------------

/**
 * Mindestlänge der rubrikübergreifenden Eintragssuche. Serverseitig
 * durchgesetzt, damit der Client nicht die einzige Bremse ist: kürzere
 * Eingaben liefern ein leeres Ergebnis statt 130 von 168 Rubriken.
 */
const ENTRY_SEARCH_MIN_CHARS = 3;
const ENTRY_SEARCH_SAMPLE_DEFAULT = 5;
const ENTRY_SEARCH_SAMPLE_MAX = 25;

async function getDocsetInfo(id, lang = 'en') {
  const { catalog, installed } = ctxOf(id);
  if (!catalog) return null;
  const stats = installed?.stats || {};
  // Capability-Flag des Adapters (E2): nur Sets mit eigener Eintragsebene
  // bekommen auf der Rubrikliste das Kästchen „auch Einträge durchsuchen".
  const adapter = resolveAdapter(id);
  const entrySearch = !!installed
    && !!adapter?.capabilities?.entrySearch
    && typeof adapter.searchEntriesByCategory === 'function';
  return {
    id: catalog.id,
    name: catalog.name,
    description: catalog.description,
    source_url: catalog.source_url,
    online_link_md: onlineLinkMd(catalog.source_url, lang),
    skill: catalog.skill,
    visible: catalog.visible,
    references: catalog.references,
    start_page: catalog.start_page || null,
    directory: installed?.directory || null,
    installed: !!installed,
    languages: installed?.languages || catalog.languages || [],
    categories: stats.categories ?? null,
    // Manifest-Grenze: `.fmlab/docs.json` speichert den Zähler historisch als
    // `stats.functions`. Wir mappen ihn hier auf den Vertragsnamen `entries`,
    // statt das gespeicherte Artefakt zu migrieren — sonst bräuchte jeder
    // bestehende Workspace eine Nachpflege.
    entries: stats.entries ?? stats.functions ?? null,
    entry_search: entrySearch,
    entry_search_url: entrySearch ? `/api/docs/${encodeURIComponent(id)}/search` : null,
    entry_search_min_chars: ENTRY_SEARCH_MIN_CHARS,
  };
}

async function listDocsetCategories(ctx, id, lang = 'en') {
  const adapter = resolveAdapter(id);
  if (!adapter) return [];
  const cats = await adapter.listCategories(ctx, { lang });
  return cats.map(c => {
    const rowAct = buildCategoryAction(id, c);
    const badgeAct = buildCategoryBadgeAction(id, c);
    return {
      ...c,
      description: c.description || null,
      entry_count: typeof c.entry_count === 'number' ? c.entry_count : null,
      // Navigations-Plumbing: '_'-Präfix = technisches Feld. Die Listen-
      // Primitives blenden solche Felder aus Anzeige UND Zeilensuche aus —
      // ohne das trifft z.B. die Suche nach "plugin" jede Zeile, weil in
      // jedem badge_action_args "type=PluginFunction" steht.
      _action: rowAct.action,
      _action_args: rowAct.action_args,
      _badge_action: badgeAct.action,
      _badge_action_args: badgeAct.action_args,
    };
  });
}

async function getDocsetCategoryInfo(ctx, id, categoryId, lang = 'en') {
  const adapter = resolveAdapter(id);
  if (!adapter) return null;
  // Adapter haben keinen dedizierten getCategory — wir filtern aus listCategories.
  const cats = await adapter.listCategories(ctx, { lang });
  const cat = cats.find(c => c.id === categoryId);
  if (!cat) return null;

  // Externe URL der Hersteller-Seite (für den Hero-Card-Link "Online öffnen ↗").
  // Der frühere `source_url` zeigte auf den lokalen Mirror-Pfad
  // (/api/reference/help/...), was im Hero-Card nutzlos war (User würde aus
  // dem SPA-Frame fliegen). Stattdessen verlinken wir direkt auf die
  // Hersteller-Doku.
  let online_url = null;
  if (id === 'claris-help' && cat.slug) {
    online_url = `https://help.claris.com/${encodeURIComponent(lang)}/pro-help/content/${encodeURIComponent(cat.slug)}.html`;
  } else if (id === 'mbs') {
    // MBS hat keine zuverlässig zugängliche externe Component-URL — wir
    // verzichten auf den Online-Link in der Hero-Card für MBS-Kategorien.
  }

  return {
    id: cat.id,
    name: cat.name,
    slug: cat.slug,
    kind: cat.kind || null,
    description: cat.description || null,
    source_url: online_url,                       // Externer Link (Backwards-Compat-Feld)
    online_url,
    online_link_md: onlineLinkMd(online_url, lang),
    entry_count: typeof cat.entry_count === 'number' ? cat.entry_count : null,
  };
}

async function listDocsetFunctions(ctx, id, categoryId, lang = 'en') {
  const adapter = resolveAdapter(id);
  if (!adapter) return [];
  const fns = await adapter.listFunctions(ctx, { categoryId, lang });
  if (!fns.length) return [];

  // Pseudo-Object-UUIDs (PluginFunction / BuiltinFunction / ScriptStepType)
  // werden aus dem ObjectCatalog gezogen, damit der Klick auf die Count-Pill
  // direkt in die DetailView mit Caller-Liste deep-linken kann. Bei Claris
  // mappen wir über die sprach-agnostischen Name-Lookup-Tabellen der
  // Reference-DB (eine function_id kann mehrere lokalisierte Object_Names im
  // Katalog haben — wir picken einen pro id deterministisch via MIN).
  const uuidMap = await loadFunctionUuidMap(ctx, id, fns);

  return fns.map(fn => {
    const uuid = uuidMap.get(fn.id) || null;
    const rowAct = buildFunctionAction(id, fn, lang, categoryId);
    const badgeAct = buildFunctionBadgeAction(id, fn, uuid);
    return {
      id: fn.id,
      name: id === 'mbs' ? `MBS::${fn.name}` : fn.name,
      canonical: fn.canonical || null,
      signature: fn.signature || null,
      uuid,
      referenced: !!uuid,
      // Abschnitts-Überschrift für Zweit-Mitglieder (leer = Hauptliste).
      // Die Liste erwartet zusammenhängend sortierte Gruppen; der Adapter
      // liefert Primär-Mitglieder zuerst, danach nach Primärkomponente sortiert.
      section: secondarySection(fn.secondary_of, lang),
      // Technische Felder ('_'-Präfix): weder Anzeige noch Zeilensuche.
      _source_url: rowAct.source_url,
      // Row-Klick: Volltext-View der Function-Dokumentation öffnen.
      _action: rowAct.action,
      _action_args: rowAct.action_args,
      // Pill-Klick: References-Ansicht (DetailView des Pseudo-Objects
      // bzw. Suche nach allen Verwendungen).
      _badge_action: badgeAct.action,
      _badge_action_args: badgeAct.action_args,
    };
  });
}

/**
 * Resolves Object_UUIDs for the given list of doc-set functions/steps. The
 * keys mirror the adapter's id format (PluginFunction-Subname for MBS,
 * `fn:<n>` / `ss:<n>` für Claris).
 */
async function loadFunctionUuidMap(ctx, setId, fns) {
  const map = new Map();
  if (!fns.length) return map;

  if (setId === 'mbs') {
    // Docset-Funktionsnamen sind bereits die fachlichen SubNames (z.B.
    // `FM.InsertRecord`). Der Katalog-Object_Name ist `MBS:<Sub>::<Sub>`
    // (früher `MBS::<Sub>`), daher wird über den extrahierten SubName gematcht —
    // format-tolerant, vgl. utils/plugin-name.js.
    const subExpr = sqlPluginSubName('Object_Name');
    const namesSql = fns
      .map(r => `'${String(r.name).replace(/'/g, "''")}'`)
      .join(',');
    try {
      const sql = `
        SELECT ${subExpr} AS subname, Object_UUID
        FROM ObjectCatalog
        WHERE Object_Type = 'PluginFunction'
          AND ${subExpr} IN (${namesSql})
      `;
      const result = await db.executeQuery(ctx, sql);
      for (const row of result.rows) map.set(row.subname, row.Object_UUID);
    } catch (err) {
      console.warn(`[docs-source:mbs] uuid lookup failed: ${err.message}`);
    }
    return map;
  }

  if (setId === 'claris-help') {
    const fnIds = [];
    const ssIds = [];
    for (const f of fns) {
      const [prefix, num] = String(f.id || '').split(':');
      if (!/^\d+$/.test(num)) continue;
      if (prefix === 'fn') fnIds.push(parseInt(num, 10));
      else if (prefix === 'ss') ssIds.push(parseInt(num, 10));
    }
    if (fnIds.length) {
      try {
        // Der Import schreibt die Referenz-Identität jedes aufgelösten
        // Built-in-Knotens mit (BuiltinFunctionIdentity, Katalog-Schema 1.32.0)
        // — ein Knoten je function_id, sprachunabhängig. Vorher lief der Join
        // namensbasiert über ref.function_name_lookup und traf eine
        // lokalisierte Autorensprache nicht; MIN() war nötig, weil dieselbe
        // function_id mehrere lokalisierte Knoten hatte. Beides ist mit der
        // Normalisierung weg — und der Deep-Link nutzt nun DIESELBE Quelle wie
        // der Pill-Count (docs-references.js), kann also nicht auseinanderlaufen.
        const sql = `
          SELECT bfi.Function_ID AS num_id, bfi.Object_UUID AS uuid
          FROM BuiltinFunctionIdentity bfi
          WHERE bfi.Function_ID IN (${fnIds.join(',')})
        `;
        const r = await db.executeQuery(ctx, sql);
        for (const row of r.rows) map.set(`fn:${row.num_id}`, row.uuid);
      } catch (err) {
        console.warn(`[docs-source:claris-help] fn uuid lookup failed: ${err.message}`);
      }
    }
    if (ssIds.length) {
      try {
        const sql = `
          SELECT lk.step_id AS num_id, MIN(oc.Object_UUID) AS uuid
          FROM ObjectCatalog oc
          JOIN ref.script_step_name_lookup lk
            ON lk.lookup_name = oc.Object_Name AND lk.is_primary = 1
          WHERE oc.Object_Type = 'ScriptStepType'
            AND lk.step_id IN (${ssIds.join(',')})
          GROUP BY lk.step_id
        `;
        const r = await db.executeQuery(ctx, sql);
        for (const row of r.rows) map.set(`ss:${row.num_id}`, row.uuid);
      } catch (err) {
        console.warn(`[docs-source:claris-help] ss uuid lookup failed: ${err.message}`);
      }
    }
    return map;
  }

  return map;
}

/**
 * Pill-Click-Action: führt zur References-Ansicht der Function-Verwendungen.
 *   - UUID bekannt → `openObject` (DetailView mit Caller-Liste).
 *   - Sonst → `applyFilter` auf den passenden Pseudo-ObjectType + Name-Suche.
 * Sets ohne Pseudo-Type-Mapping (z.B. fmide/fm-lab) liefern keine Action;
 * die Pill rendert dann ohne Click-Handler.
 */
function buildFunctionBadgeAction(setId, fn, uuid) {
  if (uuid) {
    // Direkt in den Referenzen-Tab des Pseudo-Objects springen — die Pill
    // signalisiert ja gerade "X Verwendungen", also will der User die Caller-
    // Liste sehen, nicht die Detail-Beschreibung.
    return { action: 'openObject', action_args: `uuid=${uuid}&tab=references` };
  }
  let type = null;
  let q = '';
  if (setId === 'mbs') {
    type = 'PluginFunction';
    // Fallback-Namensfilter: der SubName (fn.id) ist Teilstring des
    // Katalog-Object_Name `MBS:<Sub>::<Sub>` → ohne `MBS::`-Präfix suchen.
    q = fn.id;
  } else if (setId === 'claris-help') {
    if (String(fn.id || '').startsWith('fn:')) type = 'BuiltinFunction';
    else if (String(fn.id || '').startsWith('ss:')) type = 'ScriptStepType';
    q = fn.name;
  }
  if (!type) return { action: '', action_args: '' };
  return {
    action: 'applyFilter',
    action_args: `type=${encodeURIComponent(type)}&q=${encodeURIComponent(q)}`,
  };
}

async function searchDocset(ctx, id, q, lang = 'en') {
  const adapter = resolveAdapter(id);
  if (!adapter) return { categories: [], functions: [] };
  return adapter.search(ctx, { q, lang });
}

/**
 * Rubrikübergreifende Eintragssuche, konsolidiert auf Rubrikebene.
 *
 * Der Unterschied zu `searchDocset`: hier wird UNGEDECKELT aggregiert. Der
 * Treffer-Cap der Zeilen-Suche (50/200) darf nicht vorgelagert greifen, sonst
 * fehlen ganze Rubriken im Ergebnis — und eine fehlende Rubrik ist im
 * konsolidierten Bild nicht als Lücke erkennbar. Begrenzt wird nur das
 * Beleg-Sample je Rubrik.
 *
 * Rückgabe: `[{ category_id, hit_count, sample: string[] }]` — absteigend nach
 * Trefferzahl. Leeres Array bei zu kurzer Eingabe oder Sets ohne Eintragsebene.
 */
async function searchDocsetEntriesByCategory(ctx, id, q, { lang = 'en', sample } = {}) {
  const term = String(q || '').trim();
  if (term.length < ENTRY_SEARCH_MIN_CHARS) return [];
  const adapter = resolveAdapter(id);
  if (!adapter?.capabilities?.entrySearch) return [];
  if (typeof adapter.searchEntriesByCategory !== 'function') return [];

  const parsed = Number(sample);
  const size = Number.isFinite(parsed) && parsed > 0
    ? Math.min(ENTRY_SEARCH_SAMPLE_MAX, Math.floor(parsed))
    : ENTRY_SEARCH_SAMPLE_DEFAULT;

  const rows = await adapter.searchEntriesByCategory(ctx, { q: term, lang, sample: size });
  return (rows || []).map(r => ({
    category_id: r.category_id,
    hit_count: Number(r.hit_count || 0),
    sample: Array.isArray(r.sample) ? r.sample : [],
  }));
}

async function getDocsetEntry(ctx, id, categoryId, functionId, lang = 'en') {
  const adapter = resolveAdapter(id);
  if (!adapter) return null;
  const raw = await adapter.getEntry(ctx, { categoryId, functionId, lang });
  if (!raw) return null;

  // pagePath = content-root-relative Pfad ohne .md-Endung. Für markdown-fs
  // ist das identisch mit functionId/categoryId (Adapter-Konvention); für
  // indizierte Sets (MBS, Claris) gibt es keine Verzeichnis-Hierarchie, der
  // pagePath ist dann irrelevant für die Relativ-Auflösung.
  const pagePath = functionId || categoryId || '';

  // Run content through the shared render/sanitize/link-rewrite pipeline.
  // Markdown sources end up with `content_html` populated; HTML sources are
  // sanitized in place. Adapter-provided `content_url` (e.g. Claris) is left
  // intact — the Frontend lädt es dann separat über /api/reference/help.
  const entry = docsContent.processEntry(raw, { setId: id, pagePath });

  // Breadcrumb-Tupel für die DocsEntryView (Docs → Set → Category → Function).
  // Wir bauen es serverseitig, damit das Frontend keinen separaten Category-
  // Request brauchen muss. Bei markdown-fs ist die Category leer (die Datei
  // selbst IST die Page).
  const { catalog } = ctxOf(id);
  const breadcrumb = await buildBreadcrumb(ctx, {
    catalog,
    setId: id,
    categoryId,
    entryId: functionId,
    entryTitle: entry.title,
    lang,
    adapter,
  });

  return { ...entry, breadcrumb };
}

/**
 * Erzeugt das Breadcrumb-Array für eine Doc-Entry-View. Jedes Element hat
 * `{ label, href, kind }`; das letzte Element (`kind: 'current'`) hat keinen href.
 */
async function buildBreadcrumb(ctx, { catalog, setId, categoryId, entryId, entryTitle, lang, adapter }) {
  const crumbs = [
    { kind: 'root', label: 'Docs', href: '/docs' },
  ];
  if (catalog) {
    crumbs.push({
      kind: 'docset',
      label: catalog.name,
      href: `/docs/${encodeURIComponent(setId)}?lang=${encodeURIComponent(lang)}`,
    });
  }

  // Category — bei markdown-fs gibt es keine Funktion-Ebene, daher ist
  // categoryId entweder leer oder gleich der entryId (selbe Ebene). Pseudo-
  // Kategorien mit führendem "_" (z.B. "_topic" für Claris-Concept-Pages)
  // werden im Breadcrumb übersprungen — sie sind ein Routing-Detail und
  // nicht navigationsfähig.
  if (categoryId && categoryId !== entryId && !categoryId.startsWith('_')) {
    let catName = categoryId;
    try {
      const cats = await adapter.listCategories(ctx, { lang });
      const found = cats.find(c => c.id === categoryId);
      if (found) catName = found.name;
    } catch { /* fall back to id */ }
    // Bare route `/docs/:set/:category` → DocsCategoryPage rendert das
    // docset_category-Bundle (das den Set-Identifier als `docset=` erwartet,
    // siehe dashboard.service.js Builtins; die Page mappt :set → docset).
    crumbs.push({
      kind: 'category',
      label: catName,
      href: `/docs/${encodeURIComponent(setId)}/${encodeURIComponent(categoryId)}?lang=${encodeURIComponent(lang)}`,
    });
  }

  crumbs.push({
    kind: 'current',
    label: entryTitle || entryId,
    href: null,
  });
  return crumbs;
}

async function validateDocset(ctx, id) {
  const adapter = resolveAdapter(id);
  if (!adapter) return { ok: false, errors: ['No adapter configured for this doc-set.'] };
  return adapter.validate(ctx);
}

module.exports = {
  ENTRY_SEARCH_MIN_CHARS,
  ENTRY_SEARCH_SAMPLE_DEFAULT,
  getDocsetInfo,
  listDocsetCategories,
  getDocsetCategoryInfo,
  listDocsetFunctions,
  searchDocset,
  searchDocsetEntriesByCategory,
  getDocsetEntry,
  validateDocset,
};
