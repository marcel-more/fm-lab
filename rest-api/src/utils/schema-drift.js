const fs = require('fs');
const path = require('path');
const environment = require('../config/environment');
const solutions = require('../config/solutions');

/**
 * Schema-Drift-Erkennung (A+B)
 * ────────────────────────────
 * Eine Lösung, die mit einem älteren Converter importiert wurde, trägt ein
 * älteres Katalog-Schema. Die App-Templates (Detail-Views, Dashboards, Reports)
 * referenzieren jedoch Spalten/Tabellen des AKTUELLEN Schemas. DuckDB quittiert
 * das mit einem Binder-/Catalog-Error ("… does not have a column named …" bzw.
 * "Table with name … does not exist"), der bisher als generischer TEMPLATE_ERROR
 * beim Nutzer landete.
 *
 * Statt jeden Fehlertext zu raten, kreuzen wir die Meldung mit einem
 * AUTORITATIVEN Marker: der pro Lösung gestempelten `db_schema_version`
 * (solution.json → technical) gegen die vom Converter aktuell erwartete Version
 * (@SCHEMA_VERSION im Extract-Template). Nur wenn die Lösung nachweislich
 * hinterherhinkt (oder ungestempelt/alt ist) melden wir SCHEMA_DRIFT; ist das
 * Schema aktuell, bleibt es ein echter Template-Bug (unverändertes Signal für
 * die Entwicklung).
 */

// ── Aktuell erwartete Schema-Version (aus dem Extract-Template-Header) ─────────
// Autoritative Quelle: `-- @SCHEMA_VERSION x.y.z` in convert_xml_01_extract.sql.
// (version.json ist ein generiertes Manifest und kann veralten — daher NICHT als
// Quelle genutzt.) Einmal gelesen und gecacht; der Header ändert sich nur mit
// einem Deploy, der ohnehin einen API-Neustart bedeutet.
let cachedCurrentVersion; // undefined = noch nicht versucht, null = nicht lesbar
const REST_API_ROOT = path.resolve(__dirname, '../../');

function currentSchemaVersion() {
  if (cachedCurrentVersion !== undefined) return cachedCurrentVersion;
  cachedCurrentVersion = null;
  // Kandidatenpfade in Vorrang-Reihenfolge: der kanonische Extract-Header zuerst
  // (env-Override CONVERT_XML_SCRIPT kann in Dev-Setups auf einen veralteten Pfad
  // zeigen und wird daher nur als Fallback herangezogen).
  const projectRoot = path.resolve(REST_API_ROOT, '..');
  const candidates = [
    path.join(projectRoot, 'ingestion', 'sql', 'convert_xml_01_extract.sql'),
    path.resolve(REST_API_ROOT, environment.xml.convertScript),
  ];
  for (const sqlPath of candidates) {
    try {
      const header = fs.readFileSync(sqlPath, 'utf-8').slice(0, 4096);
      const m = header.match(/^--\s*@SCHEMA_VERSION\s+([\d.]+)/m);
      if (m) {
        cachedCurrentVersion = m[1];
        break;
      }
    } catch {
      // nächsten Kandidaten versuchen; scheitern alle → „unbekannt" (siehe classify).
    }
  }
  return cachedCurrentVersion;
}

// ── Fehlererkennung ───────────────────────────────────────────────────────────
// DuckDB emittiert diese Meldungen locale-unabhängig auf Englisch — ein
// String-Match ist damit über alle UI-Sprachen stabil.
// DuckDB kennt mehrere Binder-Formulierungen für „Spalte fehlt", je nachdem ob
// die Referenz qualifiziert (tc.X) oder unqualifiziert (X) ist:
//   • qualifiziert:   Table "tc" does not have a column named "Theme_Display"
//   • unqualifiziert: Referenced column "L_Theme_Base" not found in FROM clause!
// Beide bedeuten dasselbe (die Spalte existiert im Katalog nicht) → beide zählen.
const MISSING_COLUMN_RE = /does not have a column named\s+"?([^"\s]+)"?/i;
const REFERENCED_COLUMN_RE = /Referenced column\s+"?([^"\s]+)"?\s+not found/i;
const MISSING_TABLE_RE = /Table with name\s+"?([^"\s]+)"?\s+does not exist/i;

/** True, wenn die Meldung ein Binder-/Catalog-Fehler über fehlende Spalte/Tabelle ist. */
function isBinderSchemaError(message) {
  if (!message) return false;
  return (
    MISSING_COLUMN_RE.test(message) ||
    REFERENCED_COLUMN_RE.test(message) ||
    MISSING_TABLE_RE.test(message)
  );
}

/** Fehlendes Objekt (Spalte oder Tabelle) aus der Meldung ziehen — nur fürs Detail-Feld. */
function missingObject(message) {
  const c = message.match(MISSING_COLUMN_RE) || message.match(REFERENCED_COLUMN_RE);
  if (c) return `column "${c[1]}"`;
  const t = message.match(MISSING_TABLE_RE);
  if (t) return `table "${t[1]}"`;
  return null;
}

/** Semver-artiger Vergleich "1.11.0" ⇔ "1.12.1" → -1 | 0 | 1. */
function cmpVersions(a, b) {
  const pa = String(a).split('.').map((n) => parseInt(n, 10) || 0);
  const pb = String(b).split('.').map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d !== 0) return d < 0 ? -1 : 1;
  }
  return 0;
}

/**
 * Prüft einen gefangenen Query-Fehler auf Schema-Drift.
 *
 * @param {Object} ctx - Request-Kontext ({ solution, … })
 * @param {Error}  err - der von DuckDB geworfene Fehler
 * @returns {Error|null} - ein `SCHEMA_DRIFT`-Fehler (mit .code/.details) bei Drift,
 *                         sonst null (Aufrufer wirft den Originalfehler weiter).
 *
 * Entscheidungsbaum (nur bei Binder-/Catalog-Fehler relevant):
 *   • Lösung NICHT importiert            → null  (der bestehende No-Import-Pfad greift)
 *   • Schema bekannt UND ≥ aktuell       → null  (echter Template-Bug, Signal erhalten)
 *   • Schema < aktuell / unbekannt / n.v.→ SCHEMA_DRIFT
 */
function classifySchemaDrift(ctx, err) {
  try {
    const message = err && err.message;
    if (!isBinderSchemaError(message)) return null;

    const solutionId = ctx && typeof ctx.solution === 'string' ? ctx.solution : null;
    if (!solutionId) return null;

    const manifest = solutions.readManifest(solutionId) || {};
    const tech = manifest.technical || {};
    const metrics = manifest.metrics || {};

    // Nie importiert → das ist kein Drift, sondern der Leerzustand. Dem
    // bestehenden No-Import-Pfad (fehlende Tabelle → "erst importieren") den
    // Vortritt lassen, statt fälschlich "neu konvertieren" zu melden.
    const imported = !!tech.last_import_at || (typeof metrics.objects === 'number' && metrics.objects > 0);
    if (!imported) return null;

    const solutionVersion = tech.db_schema_version || null;
    const appVersion = currentSchemaVersion();

    // Schema ist nachweislich aktuell → echter Bug, nicht verschlucken.
    if (solutionVersion && appVersion && cmpVersions(solutionVersion, appVersion) >= 0) {
      return null;
    }

    const missing = missingObject(message);
    const driftErr = new Error(
      `SCHEMA_DRIFT: solution "${solutionId}" was imported with catalog schema ` +
      `${solutionVersion || 'unknown'} but the app expects ${appVersion || 'a newer version'}` +
      ` — re-convert the XML to update the catalog${missing ? ` [missing ${missing}]` : ''}.`
    );
    driftErr.code = 'SCHEMA_DRIFT';
    driftErr.details = {
      solution: solutionId,
      db_schema_version: solutionVersion,
      current_schema_version: appVersion,
      missing,
    };
    return driftErr;
  } catch {
    // Klassifikation darf NIE selbst kippen — im Zweifel Originalfehler behalten.
    return null;
  }
}

module.exports = {
  classifySchemaDrift,
  isBinderSchemaError,
  currentSchemaVersion,
  // für Tests
  cmpVersions,
};
