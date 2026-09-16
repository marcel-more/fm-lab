const db = require('../config/database');
const referenceService = require('./reference.service');
const helpService = require('./help.service');
const templateService = require('./template.service');
const graphService = require('./graph.service');
const annotationsService = require('./annotations.service');
const dashboardService = require('./dashboard.service');
const dashboardI18nService = require('./dashboard-i18n.service');
const testsService = require('./tests.service');
const pluginI18nService = require('../plugins/plugin-i18n.service');
const docsReferences = require('./docs-references');
const clarisAdapter = require('./plugin-docs/adapters/claris-duckdb');

/**
 * Re-opens the DuckDB connection from disk and clears all in-process caches.
 *
 * Shared between POST /api/admin/reload (admin controller) und dem internen
 * Reload nach erfolgreichem `POST /api/docs/install/:id`
 * (Adapter-Refresh nach Installation).
 *
 * Optional gezielt für EINE Lösung (`solutionId`) — invalidiert
 * genau deren Pool-Eintrag (+ Sidecar); ohne Argument der Server-Default.
 * Die In-Process-Caches werden weiterhin komplett geleert (sie sind per
 * ctx.solution geschlüsselt — Komplett-Clear ist grob, aber korrekt).
 */
async function performReload(solutionId) {
  // Reload läuft ohne Request — der Kontext ist explizit die Ziel-Lösung
  // bzw. der Server-Default (einzige legitime Quelle kontextloser Kontexte).
  const ctx = solutionId
    ? { solution: solutionId, requested: null }
    : require('../config/solutions').serverDefaultContext();
  const result = await db.reload(solutionId);
  referenceService.clearCaches();
  // Feature-Cache der Objekt-Suche (Verfügbarkeit von v_builtin_token_lookup):
  // ein Re-Import kann das Katalog-Schema heben, dann muss die Suche den
  // lokalisierten Built-in-Branch wieder anbieten.
  require('./object.service').clearObjectServiceCaches();
  helpService.clearCache();
  templateService.clearCache();
  graphService.clearCache();
  // Vor dem User-Remap: Skill-Semantic-Names durabel halten — erst
  // den Sidecar-Cache auf die neue Partition restaurieren (greift nach Force-
  // Rebuild), dann den Cache aus der Copy auffrischen (nur wenn die Copy Namen
  // hat). Best-effort: ein Fehler darf den Reload nie kippen.
  // NUR wenn der Pool-Eintrag wirklich (neu) geöffnet wurde — eine bloß
  // invalidierte, nie angefragte Lösung nicht extra öffnen (status 'invalidated').
  if (result.status === 'reloaded') {
    try {
      await annotationsService.restoreSemanticNamesAfterReload(ctx);
    } catch (err) {
      console.warn(`reload: semantic-name restore skipped: ${err.message}`);
    }
    // User-Community-Annotationen auf die (ggf. neue) Cluster-Partition re-mappen
    // (Objekt-Mehrheitsvotum). Best-effort: ein Fehler darf den Reload nie kippen.
    try {
      await annotationsService.remapAfterReload(ctx);
    } catch (err) {
      console.warn(`reload: annotations remap skipped: ${err.message}`);
    }
  }
  dashboardService.clearCache();
  dashboardI18nService.clearCache();
  testsService.clearCache();
  pluginI18nService.clearCache();
  docsReferences.clearCache();
  clarisAdapter.clearSlugMapCache();

  // Recompute the fmIDE per-file script status against the freshly reloaded DB,
  // but only if a scan was ever run (don't scan for a never-activated plugin).
  // fmIDE ist Workspace-Zustand (FileMaker auf DIESEM Rechner) → nur beim
  // Server-Default-Reload auffrischen, nicht für Pool-Fremdlösungen.
  // Best-effort, lazily required so a missing plugin never breaks the reload.
  const isServerDefault = !solutionId
    || solutionId === require('../config/solutions').getActiveSolutionId();
  if (result.status === 'reloaded' && isServerDefault) {
    try {
      const fmide = require('../plugins/fmide/fmide.service');
      if (fmide.hasScanData()) await fmide.refreshFileStatuses(ctx);
    } catch (err) {
      console.warn(`reload: fmIDE status refresh skipped: ${err.message}`);
    }
  }

  return result;
}

module.exports = { performReload };
