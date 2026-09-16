const fs = require('fs');
const path = require('path');
const { LRUCache } = require('lru-cache');
const settingsStore = require('../../../plugins/settings-store');
const db = require('../../../config/database');
const helpService = require('../../help.service');

// Slug-Map: globaler Lookup `url_slug` → { id, categoryId, kind }. Dient zwei
// Zwecken: (1) Cross-Link-Rewriting in `getEntry` (siehe rewriteHelpLinks),
// (2) optional zukünftig für `/api/docs/...`-Konsumenten, die nur den Slug
// haben. Wird einmal pro Server-Lifecycle gefüllt; bei Reference-DB-Reload
// invalidiert über admin/reload (siehe system-reload.js).
const slugMapCache = new LRUCache({ max: 1, ttl: 1000 * 60 * 60 });
const SLUG_MAP_KEY = 'all';

function clearSlugMapCache() {
  slugMapCache.clear();
}

/**
 * claris-duckdb Adapter — IDocSetIndex implementation
 *
 * Liest aus den `ref.*`-Tabellen der attached Reference-DB
 * (`reference/fm_spec.duckdb`). Diese DB wird von der fm-spec-Pipeline
 * erzeugt und beim Server-Start als `ref` Schema angehängt.
 *
 * Kategorien-IDs sind präfixiert: `fn:<n>` für Funktionen-Kategorien, `ss:<n>`
 * für Script-Step-Kategorien. Funktions-IDs sind plain int (über ref.functions
 * bzw. ref.script_steps).
 */

/**
 * Adapter-Capabilities (siehe adapters/index.js). Funktionen UND Script-Steps
 * bilden die Eintragsebene — beide sind durchsuchbar und über ihre
 * `category_id` einer Rubrik zugeordnet.
 */
const capabilities = { entrySearch: true };

function repoRoot() {
  return settingsStore.resolveRepoRoot();
}

function docsetDir({ installedEntry }) {
  if (!installedEntry?.directory) return null;
  return path.resolve(repoRoot(), installedEntry.directory);
}

async function listCategories(ctx, { lang = 'en' } = {}) {
  // `name_en` ist der englische Kanon-Name der Category — wird für den
  // Pseudo-Token-Filter im Code-Reference-Drill-Down benötigt
  // (PseudoTokenView matcht WHERE category = ?, und die SQL-Aggregation
  // emittiert die englischen Bezeichner).
  const sql = `
    WITH fc AS (
      SELECT
        'fn:' || c.category_id AS id,
        COALESCE(cl.name, c.category_name) AS name,
        c.category_name AS name_en,
        c.url_slug AS slug,
        'function' AS kind,
        (SELECT COUNT(*) FROM ref.functions f WHERE f.category_id = c.category_id) AS entry_count
      FROM ref.function_categories c
      LEFT JOIN ref.function_categories_lang cl
             ON cl.category_id = c.category_id AND cl.language = '${lang}'
    ),
    sc AS (
      SELECT
        'ss:' || c.category_id AS id,
        COALESCE(cl.name, c.category_name_en) AS name,
        c.category_name_en AS name_en,
        c.url_slug AS slug,
        'script_step' AS kind,
        (SELECT COUNT(*) FROM ref.script_steps s WHERE s.category_id = c.category_id) AS entry_count
      FROM ref.script_steps_categories c
      LEFT JOIN ref.script_steps_categories_lang cl
             ON cl.category_id = c.category_id AND cl.language = '${lang}'
    )
    SELECT id, name, name_en, slug, kind, entry_count FROM fc
    UNION ALL
    SELECT id, name, name_en, slug, kind, entry_count FROM sc
    ORDER BY kind, name
  `;
  const result = await db.executeQuery(ctx, sql);
  return result.rows.map(r => ({
    id: r.id,
    name: r.name,
    name_en: r.name_en,
    slug: r.slug,
    kind: r.kind,
    entry_count: Number(r.entry_count || 0),
  }));
}

async function listFunctions(ctx, { categoryId, lang = 'en' } = {}) {
  const [prefix, rawId] = String(categoryId || '').split(':');
  if (!rawId || !/^\d+$/.test(rawId)) return [];
  const numId = parseInt(rawId, 10);

  if (prefix === 'fn') {
    const sql = `
      SELECT
        f.function_id    AS id,
        f.canonical_name AS canonical,
        f.url_slug       AS slug,
        COALESCE(fl.display_name, f.canonical_name) AS display_name,
        fl.signature
      FROM ref.functions f
      LEFT JOIN ref.functions_lang fl
             ON fl.function_id = f.function_id AND fl.language = '${lang}'
      WHERE f.category_id = ${numId}
      ORDER BY display_name
    `;
    const result = await db.executeQuery(ctx, sql);
    return result.rows.map(r => ({
      id: `fn:${r.id}`,
      name: r.display_name,
      canonical: r.canonical,
      slug: r.slug,
      signature: r.signature || null,
      kind: 'function',
    }));
  }
  if (prefix === 'ss') {
    const sql = `
      SELECT
        s.step_id AS id,
        s.canonical_name AS canonical,
        s.url_slug       AS slug,
        COALESCE(sl.display_name, s.canonical_name) AS display_name
      FROM ref.script_steps s
      LEFT JOIN ref.script_steps_lang sl
             ON sl.step_id = s.step_id AND sl.language = '${lang}'
      WHERE s.category_id = ${numId}
      ORDER BY display_name
    `;
    const result = await db.executeQuery(ctx, sql);
    return result.rows.map(r => ({
      id: `ss:${r.id}`,
      name: r.display_name,
      canonical: r.canonical,
      slug: r.slug,
      signature: null,
      kind: 'script_step',
    }));
  }
  return [];
}

/**
 * Builds a global slug→{id, categoryId, kind} index over functions +
 * script_steps. Used to rewrite Claris-internal cross-links into SPA routes.
 *
 * The index is global (slugs are language-independent in the Claris URL
 * scheme; the URL segment differs per language only via the lang path
 * component). Cached for an hour; explicit invalidation via clearSlugMapCache.
 */
async function loadSlugMap(ctx) {
  const cached = slugMapCache.get(SLUG_MAP_KEY);
  if (cached) return cached;
  const map = new Map();
  try {
    const fnRes = await db.executeQuery(
      ctx,
      `SELECT url_slug, function_id, category_id FROM ref.functions`
    );
    for (const r of fnRes.rows) {
      if (r.url_slug) map.set(r.url_slug, { id: `fn:${r.function_id}`, categoryId: `fn:${r.category_id}`, kind: 'fn' });
    }
    const ssRes = await db.executeQuery(
      ctx,
      `SELECT url_slug, step_id, category_id FROM ref.script_steps`
    );
    for (const r of ssRes.rows) {
      if (r.url_slug) map.set(r.url_slug, { id: `ss:${r.step_id}`, categoryId: `ss:${r.category_id}`, kind: 'ss' });
    }
  } catch (err) {
    console.warn(`[claris-duckdb] loadSlugMap failed: ${err.message}`);
  }
  slugMapCache.set(SLUG_MAP_KEY, map);
  return map;
}

/**
 * Loads the Claris-help mirror HTML for a slug + extracts the optimized embed
 * body (already cross-link-rewritten by help.service to `/api/reference/help/
 * <lang>/<slug>` URLs). Returns `{ html, title, lang }` or null if not found.
 *
 * `lang` is the language actually delivered: the mirror is not installed for
 * every language, so `resolveHtml` silently falls back to the reference
 * language and reports that in its `source` marker. Passing it on lets callers
 * tell the user which language they are really reading.
 */
function loadHelpEmbed(lang, slug) {
  const entry = helpService.resolveHtml(lang, slug);
  if (!entry) return null;
  const html = helpService.extractEmbed(entry);
  // Pull the H1 (or <title>) as the page title — the first <h1>…</h1> is set
  // by Claris on every concept page.
  let title = slug;
  const h1 = String(html || '').match(/<h1\b[^>]*>([\s\S]*?)<\/h1>/i);
  if (h1) title = h1[1].replace(/<[^>]+>/g, '').trim();
  const fallback = /^html-cache:fallback:(.+)$/.exec(String(entry.source || ''));
  return { html, title, lang: fallback ? fallback[1] : lang };
}

/**
 * Rewrites cross-links emitted by help.service.optimizeBody:
 *   <a href="/api/reference/help/<lang>/<slug>...">
 * into SPA routes:
 *   - Known function/script-step slug:
 *       <a href="/docs/claris-help/<cat>/<id>?lang=<lang>...">
 *   - Concept-page slug (no DB entry):
 *       <a href="/docs/claris-help/_topic/topic:<slug>?lang=<lang>...">
 * Hash-fragments and other query state are preserved.
 */
function rewriteHelpLinks(html, lang, slugMap) {
  if (!html) return html;
  const langSeg = encodeURIComponent(lang);
  // Match `/api/reference/help/<lang>/<slug>[#hash]` href values.
  return String(html).replace(
    /(<a\b[^>]*\bhref=")\/api\/reference\/help\/([^/"]+)\/([^"#?]+)(#[^"]*)?(")/gi,
    (_, prefix, urlLang, slug, anchor, suffix) => {
      const decodedSlug = (() => {
        try { return decodeURIComponent(slug); } catch { return slug; }
      })();
      const known = slugMap.get(decodedSlug);
      const usedLang = urlLang || langSeg;
      let target;
      if (known) {
        target = `/docs/claris-help/${encodeURIComponent(known.categoryId)}/${encodeURIComponent(known.id)}?lang=${encodeURIComponent(usedLang)}`;
      } else {
        target = `/docs/claris-help/_topic/${encodeURIComponent(`topic:${decodedSlug}`)}?lang=${encodeURIComponent(usedLang)}`;
      }
      return `${prefix}${target}${anchor || ''}${suffix}`;
    }
  );
}

async function getEntry(ctx, { functionId, lang = 'en' } = {}) {
  // functionId formats:
  //   fn:<n>     → function row
  //   ss:<n>     → script-step row
  //   topic:<s>  → concept page (no DB row; HTML loaded directly from mirror)
  const idStr = String(functionId || '');
  const colonIdx = idStr.indexOf(':');
  if (colonIdx < 0) return null;
  const prefix = idStr.slice(0, colonIdx);
  const rest = idStr.slice(colonIdx + 1);

  const slugMap = await loadSlugMap(ctx);

  // --- Concept pages (Claris topic / overview pages without a DB-side entry) ---
  if (prefix === 'topic') {
    if (!rest || /[\s"]/.test(rest)) return null;
    const embed = loadHelpEmbed(lang, rest);
    if (!embed) return null;
    const html = rewriteHelpLinks(embed.html, lang, slugMap);
    return {
      id: functionId,
      title: embed.title,
      content_html: html,
      // Language actually delivered — differs from `lang` when the mirror for
      // the requested language is not installed (see loadHelpEmbed).
      lang_effective: embed.lang,
      metadata: { source_slug: rest, kind: 'topic' },
      online_url: `https://help.claris.com/${lang}/pro-help/content/${rest}.html`,
      format: 'html',
    };
  }

  // --- Functions + Script-Steps ---
  if (!rest || !/^\d+$/.test(rest)) return null;
  const numId = parseInt(rest, 10);

  let row = null;
  let extraMetadata = {};
  if (prefix === 'fn') {
    const sql = `
      SELECT
        f.function_id, f.canonical_name, f.url_slug,
        COALESCE(fl.display_name, f.canonical_name) AS display_name,
        fl.signature, fl.description
      FROM ref.functions f
      LEFT JOIN ref.functions_lang fl
             ON fl.function_id = f.function_id AND fl.language = '${lang}'
      WHERE f.function_id = ${numId}
    `;
    const result = await db.executeQuery(ctx, sql);
    row = result.rows[0] || null;
    if (row) extraMetadata = { canonical: row.canonical_name, signature: row.signature, description: row.description };
  } else if (prefix === 'ss') {
    const sql = `
      SELECT
        s.step_id, s.canonical_name, s.url_slug,
        COALESCE(sl.display_name, s.canonical_name) AS display_name
      FROM ref.script_steps s
      LEFT JOIN ref.script_steps_lang sl
             ON sl.step_id = s.step_id AND sl.language = '${lang}'
      WHERE s.step_id = ${numId}
    `;
    const result = await db.executeQuery(ctx, sql);
    row = result.rows[0] || null;
    if (row) extraMetadata = { canonical: row.canonical_name };
  } else {
    return null;
  }
  if (!row) return null;

  // Load + rewrite the Claris-mirror HTML so cross-links stay inside the SPA.
  let content_html = null;
  const embed = loadHelpEmbed(lang, row.url_slug);
  if (embed) {
    content_html = rewriteHelpLinks(embed.html, lang, slugMap);
  }

  return {
    id: functionId,
    title: row.display_name,
    // Counterpart in the fm-spec browser (`/fm-spec/<kind>/<id>`). The row was
    // just read from ref.script_steps / ref.functions — the same tables the
    // fm-spec routes serve — so the target exists whenever this entry does.
    // Topic pages have no counterpart and carry no spec_ref.
    spec_ref: { kind: prefix === 'ss' ? 'step' : 'function', id: numId },
    // Embed-HTML wird bereits sanitized + link-rewritten ausgeliefert. Bleibt
    // null, wenn der Mirror nichts hatte — DocsEntryView fällt dann auf
    // content_url zurück (Legacy-Pfad).
    content_html,
    // Language actually delivered — differs from `lang` when the mirror for
    // the requested language is not installed (see loadHelpEmbed).
    lang_effective: embed ? embed.lang : lang,
    content_url: content_html
      ? null
      : `/api/reference/help/${encodeURIComponent(lang)}/${encodeURIComponent(row.url_slug)}`,
    metadata: extraMetadata,
    online_url: `https://help.claris.com/${lang}/pro-help/content/${row.url_slug}.html`,
    format: 'html',
  };
}

async function search(ctx, { q, lang = 'en' } = {}) {
  const term = String(q || '').trim();
  if (!term) return { categories: [], functions: [] };
  const like = `%${term.replace(/'/g, "''")}%`;

  // Kategorien (Funktionen + Script-Steps gemischt)
  const catSql = `
    WITH fc AS (
      SELECT 'fn:' || c.category_id AS id, COALESCE(cl.name, c.category_name) AS name, 'function' AS kind
      FROM ref.function_categories c
      LEFT JOIN ref.function_categories_lang cl
             ON cl.category_id = c.category_id AND cl.language = '${lang}'
    ),
    sc AS (
      SELECT 'ss:' || c.category_id AS id, COALESCE(cl.name, c.category_name_en) AS name, 'script_step' AS kind
      FROM ref.script_steps_categories c
      LEFT JOIN ref.script_steps_categories_lang cl
             ON cl.category_id = c.category_id AND cl.language = '${lang}'
    )
    SELECT id, name, kind FROM fc WHERE name ILIKE '${like}'
    UNION ALL
    SELECT id, name, kind FROM sc WHERE name ILIKE '${like}'
    ORDER BY kind, name
    LIMIT 50
  `;
  const catRes = await db.executeQuery(ctx, catSql);

  const fnSql = `
    SELECT 'fn:' || f.function_id AS id,
           COALESCE(fl.display_name, f.canonical_name) AS name,
           f.canonical_name AS canonical
    FROM ref.functions f
    LEFT JOIN ref.functions_lang fl
           ON fl.function_id = f.function_id AND fl.language = '${lang}'
    WHERE COALESCE(fl.display_name, f.canonical_name) ILIKE '${like}'
       OR f.canonical_name ILIKE '${like}'
    UNION ALL
    SELECT 'ss:' || s.step_id AS id,
           COALESCE(sl.display_name, s.canonical_name) AS name,
           s.canonical_name AS canonical
    FROM ref.script_steps s
    LEFT JOIN ref.script_steps_lang sl
           ON sl.step_id = s.step_id AND sl.language = '${lang}'
    WHERE COALESCE(sl.display_name, s.canonical_name) ILIKE '${like}'
       OR s.canonical_name ILIKE '${like}'
    ORDER BY name
    LIMIT 200
  `;
  const fnRes = await db.executeQuery(ctx, fnSql);

  return {
    categories: catRes.rows.map(r => ({ id: r.id, name: r.name, kind: r.kind })),
    functions: fnRes.rows.map(r => ({ id: r.id, name: r.name, canonical: r.canonical })),
  };
}

/**
 * Rubrikübergreifende Eintragssuche, konsolidiert auf Rubrikebene.
 *
 * Ein `GROUP BY` über Funktions- UND Script-Step-Kategorien, ungedeckelt —
 * nur das Beleg-Sample pro Rubrik wird über `list(...)[1:n]` begrenzt. Gesucht
 * wird über den lokalisierten Anzeigenamen und den Kanon-Namen, also über
 * dieselben Felder, die auf der Rubrikseite in der Zeile stehen; damit kann
 * der Beleg keinen Eintrag nennen, den der Filter dort nicht findet.
 *
 * `category_id` trägt dasselbe `fn:`/`ss:`-Präfix wie listCategories und ist
 * damit direkt das Deep-Link-Ziel.
 */
async function searchEntriesByCategory(ctx, { q, lang = 'en', sample = 5 } = {}) {
  const term = String(q || '').trim();
  if (!term) return [];
  const esc = term.replace(/'/g, "''");
  const like = `%${esc}%`;
  const prefix = `${esc}%`;
  const size = Math.max(1, Math.min(50, Number(sample) || 5));

  const sql = `
    WITH hits AS (
      SELECT 'fn:' || f.category_id AS category_id,
             COALESCE(fl.display_name, f.canonical_name) AS name
      FROM ref.functions f
      LEFT JOIN ref.functions_lang fl
             ON fl.function_id = f.function_id AND fl.language = '${lang}'
      WHERE COALESCE(fl.display_name, f.canonical_name) ILIKE '${like}'
         OR f.canonical_name ILIKE '${like}'
      UNION ALL
      SELECT 'ss:' || s.category_id AS category_id,
             COALESCE(sl.display_name, s.canonical_name) AS name
      FROM ref.script_steps s
      LEFT JOIN ref.script_steps_lang sl
             ON sl.step_id = s.step_id AND sl.language = '${lang}'
      WHERE COALESCE(sl.display_name, s.canonical_name) ILIKE '${like}'
         OR s.canonical_name ILIKE '${like}'
    ),
    ranked AS (
      SELECT category_id, name,
             CASE WHEN name ILIKE '${prefix}' THEN 0 ELSE 1 END AS match_rank
      FROM hits
    )
    SELECT category_id,
           COUNT(*) AS hit_count,
           list(name ORDER BY match_rank, name)[1:${size}] AS sample
    FROM ranked
    -- Einträge ohne Rubrik (category_id NULL) haben kein Navigationsziel —
    -- eine Belegzeile ohne anklickbare Rubrik wäre eine Sackgasse.
    WHERE category_id IS NOT NULL
    GROUP BY category_id
    ORDER BY hit_count DESC, category_id
  `;
  const result = await db.executeQuery(ctx, sql);
  return result.rows.map(r => ({
    category_id: r.category_id,
    hit_count: Number(r.hit_count || 0),
    sample: Array.isArray(r.sample) ? r.sample.map(String) : [],
  }));
}

async function listLanguages({ installedEntry } = {}) {
  return Array.isArray(installedEntry?.languages) ? installedEntry.languages : ['en'];
}

async function validate(ctx, { catalogEntry, installedEntry } = {}) {
  const errors = [];
  const dir = docsetDir({ installedEntry });
  if (!dir) {
    errors.push('No installed directory configured.');
    return { ok: false, errors };
  }
  const indexRel = catalogEntry?.index?.path || 'fm_spec.duckdb';
  const indexAbs = path.join(dir, indexRel);
  if (!fs.existsSync(indexAbs)) {
    errors.push(`Reference DB missing: ${indexAbs}`);
  }
  // Tabellen-Existenz prüfen (ref-Schema sollte attached sein)
  try {
    const probe = await db.executeQuery(ctx, "SELECT COUNT(*) AS n FROM ref.functions LIMIT 1");
    if (!probe?.rows?.length) errors.push('ref.functions table empty');
  } catch (err) {
    errors.push(`ref schema unreadable: ${err.message}`);
  }
  return { ok: errors.length === 0, errors };
}

module.exports = {
  capabilities,
  listCategories,
  listFunctions,
  getEntry,
  search,
  searchEntriesByCategory,
  listLanguages,
  validate,
  clearSlugMapCache,
};
