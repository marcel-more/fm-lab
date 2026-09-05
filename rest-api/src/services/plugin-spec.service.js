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
  return fn;
}

module.exports = {
  getMeta,
  getFunctionSpec,
};
