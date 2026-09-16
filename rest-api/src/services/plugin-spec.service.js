const db = require('../config/database');

/**
 * Plugin-Spec Service
 *
 * Read access to reference/plugin_spec.duckdb (ATTACHed as 'plugref' in
 * config/database.js) — the platform map for plug-in functions. The database
 * is bundled with each fm-lab release (maintainer-derived from the vendor
 * documentation mirror); a public install never regenerates it.
 * The platform flags are VERBATIM vendor values (MBS: binary, per-axis) —
 * they never share semantics with the Claris tri-state step_compat table.
 */

function assertAttached() {
  if (!db.isPluginSpecAttached()) {
    const err = new Error(
      'Plugin-Spec-DB not attached: reference/plugin_spec.duckdb is missing. It ships with every fm-lab release — restore the file from the release checkout.'
    );
    err.code = 'PLUGSPEC_NOT_ATTACHED';
    throw err;
  }
}

function normalizeRow(row) {
  const out = {};
  for (const [k, v] of Object.entries(row)) {
    out[k] = typeof v === 'bigint' ? Number(v) : v;
  }
  return out;
}

/** Registered plugins + derivation metadata. */
async function getMeta(ctx) {
  assertAttached();
  const [plugins, meta] = await Promise.all([
    db.executeQuery(ctx, 'SELECT * FROM plugref.plugins ORDER BY plugin_id'),
    db.executeQuery(ctx, 'SELECT key, value FROM plugref.reference_meta ORDER BY key'),
  ]);
  return {
    plugins: plugins.rows.map(normalizeRow),
    meta: Object.fromEntries(meta.rows.map((r) => [r.key, r.value])),
  };
}

/**
 * Doku-Querlinks einer Plugin-Funktion — das Gegenstück zu `buildDocsEntryRef`
 * der Claris-Referenz (reference.service.js):
 *
 *   `docsEntry`  → Seite im Doku-Browser (`/docs/<set>/<category>/<entry>`),
 *                  NULL wenn das Docset nicht installiert ist oder die Funktion
 *                  im Doku-Index fehlt. Der Link wird nur gerendert, wenn das
 *                  Ziel wirklich existiert.
 *   `online_url` → Herstellerseite der Funktion. Rein aus dem Namen abgeleitet
 *                  (`plugin-docs.config.js` → `sources.<id>.externalUrl`), also
 *                  auch ohne installiertes Docset verfügbar — genau der Fall,
 *                  in dem sie als Fallback gebraucht wird. In plugin_spec.duckdb
 *                  steht keine URL; die Namensregel des Herstellers ist die
 *                  einzige Quelle.
 *
 * Doku-Quelle und Plugin teilen sich die Hersteller-ID ('mbs'); eine ID ohne
 * passende Doku-Quelle liefert schlicht keine Links.
 */
function buildDocsLinks(pluginId, fnName) {
  // eslint-disable-next-line global-require
  const pluginDocs = require('./plugin-docs');
  // eslint-disable-next-line global-require
  const docsManifest = require('./docs-manifest');

  const online_url = pluginDocs.externalUrl(pluginId, fnName);
  if (!docsManifest.isInstalled(pluginId)) return { online_url, docsEntry: null };
  const ref = pluginDocs.resolveEntryRef(pluginId, fnName);
  return {
    online_url,
    docsEntry: ref ? { set: pluginId, category: ref.category, entry: ref.entry } : null,
  };
}

/**
 * Dasselbe eine Ebene höher: Rubrikseite einer Komponente. `docsCategory` trägt
 * nur `set` + `category` (eine Rubrik hat keinen Eintragsnamen).
 */
function buildComponentDocsLinks(pluginId, componentName) {
  // eslint-disable-next-line global-require
  const pluginDocs = require('./plugin-docs');
  // eslint-disable-next-line global-require
  const docsManifest = require('./docs-manifest');

  const online_url = pluginDocs.externalCategoryUrl(pluginId, componentName);
  if (!docsManifest.isInstalled(pluginId)) return { online_url, docsCategory: null };
  const ref = pluginDocs.resolveCategoryRef(pluginId, componentName);
  return {
    online_url,
    docsCategory: ref ? { set: pluginId, category: ref.category } : null,
  };
}

/**
 * Platform spec for one plug-in function. `prefix` is the catalog plugin
 * prefix (e.g. 'MBS', matched against plugins.detect_prefix), `name` the
 * qualified function name — old names resolve via the alias table and are
 * reported back (`alias`/`alias_kind`).
 */
async function getFunctionSpec(ctx, prefix, name) {
  assertAttached();
  const head = await db.executeQuery(
    ctx,
    `WITH p AS (
       SELECT plugin_id FROM plugref.plugins WHERE lower(detect_prefix) = lower(?)
     ),
     resolved AS (
       SELECT f.plugin_id, f.function_name,
              CAST(NULL AS VARCHAR) AS alias, CAST(NULL AS VARCHAR) AS alias_kind, 0 AS rank
       FROM plugref.plugin_functions f JOIN p USING (plugin_id)
       WHERE lower(f.function_name) = lower(?)
       UNION ALL
       SELECT a.plugin_id, a.function_name, a.alias, a.kind, 1 AS rank
       FROM plugref.plugin_function_aliases a JOIN p USING (plugin_id)
       WHERE lower(a.alias) = lower(?)
     )
     SELECT r.plugin_id, r.function_name, r.alias, r.alias_kind,
            f.component, f.since_version, f.status, f.status_note,
            f.replacement, f.removed_in,
            pl.name AS plugin_name, pl.doc_version
     FROM resolved r
     JOIN plugref.plugin_functions f
       ON f.plugin_id = r.plugin_id AND f.function_name = r.function_name
     JOIN plugref.plugins pl ON pl.plugin_id = r.plugin_id
     ORDER BY r.rank
     LIMIT 1`,
    [String(prefix), String(name), String(name)]
  );
  if (head.rows.length === 0) {
    const err = new Error(`No plugin-spec entry for '${prefix}' function '${name}'`);
    err.code = 'PLUGSPEC_FN_NOT_FOUND';
    throw err;
  }
  const fn = normalizeRow(head.rows[0]);
  const platforms = await db.executeQuery(
    ctx,
    `SELECT platform, supported, qualifier
     FROM plugref.plugin_function_platforms
     WHERE plugin_id = ? AND function_name = ?
     ORDER BY CASE platform
       WHEN 'macos' THEN 0 WHEN 'windows' THEN 1 WHEN 'linux' THEN 2
       WHEN 'server' THEN 3 WHEN 'ios_sdk' THEN 4 ELSE 5 END`,
    [fn.plugin_id, fn.function_name]
  );
  fn.platforms = platforms.rows.map(normalizeRow);
  // Querlinks auf Basis des AUFGELÖSTEN Namens (nicht des angefragten): bei
  // einem Alias zeigt die Doku-Seite auf den heutigen Namen.
  Object.assign(fn, buildDocsLinks(fn.plugin_id, fn.function_name));
  return fn;
}

/**
 * Referenz-Schicht einer Plugin-KOMPONENTE (Rubrik des Herstellers). `prefix`
 * ist das Katalog-Präfix ('MBS'), `component` der Komponentenname ohne
 * Namespace ('Archive'). Liefert die Größe der Komponente laut Plattform-Map
 * plus die beiden Doku-Querlinks.
 *
 * Eine Komponente, die die Map nicht kennt (Tippfehler, Alt-Bestand), ist kein
 * Fehler: `documented_functions` ist dann 0 und die Links bleiben trotzdem
 * nutzbar, solange die Doku sie führt.
 */
async function getComponentSpec(ctx, prefix, component, { viaFunction = null } = {}) {
  assertAttached();
  const plugins = await db.executeQuery(
    ctx,
    `SELECT plugin_id, name AS plugin_name, doc_version
     FROM plugref.plugins WHERE lower(detect_prefix) = lower(?) LIMIT 1`,
    [String(prefix)]
  );
  if (plugins.rows.length === 0) {
    const err = new Error(`No plugin-spec entry for prefix '${prefix}'`);
    err.code = 'PLUGSPEC_FN_NOT_FOUND';
    throw err;
  }
  const row = normalizeRow(plugins.rows[0]);
  row.component = String(component);

  // Der KATALOG-Komponentenname ist der Funktions-Namenspräfix ('GMImage') und
  // deckt sich nicht immer mit der Komponente des Herstellers
  // ('GraphicsMagick'). Zuerst den Katalognamen gegen die Map prüfen; greift er
  // nicht, verrät ihn eine Mitglieds-Funktion (`viaFunction`). Nur der
  // aufgelöste Name trägt danach Doku-Link und Hersteller-URL — sonst zeigten
  // beide auf eine Seite, die es beim Hersteller nicht gibt.
  const direct = await db.executeQuery(
    ctx,
    `SELECT COUNT(*) AS n FROM plugref.plugin_functions
     WHERE plugin_id = ? AND lower(component) = lower(?)`,
    [row.plugin_id, row.component]
  );
  let vendorComponent = Number(direct.rows[0]?.n ?? 0) > 0 ? row.component : null;
  let documented = Number(direct.rows[0]?.n ?? 0);

  if (!vendorComponent && viaFunction) {
    const viaRow = await db.executeQuery(
      ctx,
      `SELECT f.component,
              (SELECT COUNT(*) FROM plugref.plugin_functions g
                WHERE g.plugin_id = f.plugin_id AND g.component = f.component) AS n
       FROM plugref.plugin_functions f
       WHERE f.plugin_id = ? AND lower(f.function_name) = lower(?)
       LIMIT 1`,
      [row.plugin_id, String(viaFunction)]
    );
    if (viaRow.rows.length > 0 && viaRow.rows[0].component) {
      vendorComponent = viaRow.rows[0].component;
      documented = Number(viaRow.rows[0].n ?? 0);
    }
  }

  row.vendor_component = vendorComponent;
  row.documented_functions = documented;
  // Bewusst NUR aus dem aufgelösten Namen: bleibt er null, kennt der Hersteller
  // weder die Komponente noch eine ihrer Funktionen (z. B. gelöschte Custom
  // Functions, die als Plugin-Referenz im Katalog landen). Dann gibt es keinen
  // belegten Link — lieber gar keiner als einer ins Leere.
  Object.assign(row, buildComponentDocsLinks(row.plugin_id, vendorComponent));
  return row;
}

module.exports = {
  getMeta,
  getFunctionSpec,
  getComponentSpec,
};
