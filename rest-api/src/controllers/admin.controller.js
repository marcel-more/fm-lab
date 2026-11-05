const environment = require('../config/environment');
const solutions = require('../config/solutions');
const { buildSuccess } = require('../utils/response-builder');
const { performReload } = require('../services/system-reload');

/**
 * Admin Controller
 * Handles administrative endpoints (DB reload, etc.).
 */

/**
 * Optional shared-secret check. If ADMIN_RELOAD_TOKEN is configured, the
 * request must carry a matching X-Admin-Token header. Empty token = open.
 */
function isAuthorized(req) {
  const expected = environment.admin.reloadToken;
  if (!expected) return true;
  const provided = req.get('X-Admin-Token') || '';
  return provided === expected;
}

/**
 * POST /api/admin/reload
 * Invalidates the DuckDB pool entry of ONE solution and re-opens it from disk.
 * Called by convert-xml after a fresh copy of the master DB has been synced
 * into rest-api/db/solutions/<id>/.
 *
 * Optional body `{"solution": "<id>"}`: names the solution whose copy was just
 * synced. Stage M: the reload targets exactly that solution's pool entry —
 * other solutions/users keep working undisturbed. A never-requested solution
 * is merely invalidated (status 'invalidated'), not opened.
 */
async function reload(req, res, next) {
  try {
    if (!isAuthorized(req)) {
      return res.status(401).json({
        success: false,
        error: {
          code: 'UNAUTHORIZED',
          message: 'Invalid or missing X-Admin-Token header',
        },
      });
    }

    const requested = req.body && req.body.solution;
    if (requested && !solutions.solutionExists(requested)) {
      return res.status(404).json({
        success: false,
        error: { code: 'SOLUTION_NOT_FOUND', message: `Unknown solution: ${requested}` },
      });
    }

    console.log(`Admin reload requested${requested ? ` (solution: ${requested})` : ''} - re-opening DuckDB connection`);
    const result = await performReload(requested || undefined);
    console.log(`Admin reload complete: ${result.status} (${result.solution})${result.tables != null ? ` — ${result.tables} tables from ${result.path}` : ''}`);

    res.json(buildSuccess({
      status: result.status,
      solution: result.solution,
      tables: result.tables,
      path: result.path,
      timestamp: new Date().toISOString(),
    }));
  } catch (error) {
    console.error('Admin reload failed:', error);
    next(error);
  }
}

/**
 * GET /api/admin/pool — Diagnose der Pool-Belegung (Ausbaustufe M): welche
 * Lösungen sind offen, wie alt, wie viele Queries laufen. Token-geschützt.
 */
function poolStatus(req, res, next) {
  try {
    if (!isAuthorized(req)) {
      return res.status(401).json({
        success: false,
        error: { code: 'UNAUTHORIZED', message: 'Invalid or missing X-Admin-Token header' },
      });
    }
    const db = require('../config/database');
    res.json(buildSuccess({ pool: db.poolStatus() }));
  } catch (error) {
    next(error);
  }
}

/**
 * POST /api/admin/solution/activate {"id": "<id>"}
 * Sets the server default („active solution"): pointer file + workspace
 * symlinks, then an internal reload onto the new solution's copy.
 * Token-protected like the reload. In multiuser operation (stage M) this
 * only ever changes the SERVER DEFAULT, never another user's selection.
 */
async function activateSolution(req, res, next) {
  try {
    if (!isAuthorized(req)) {
      return res.status(401).json({
        success: false,
        error: { code: 'UNAUTHORIZED', message: 'Invalid or missing X-Admin-Token header' },
      });
    }
    const id = req.body && req.body.id;
    if (!solutions.isValidId(id || '')) {
      return res.status(400).json({
        success: false,
        error: { code: 'INVALID_SOLUTION_ID', message: 'Body must be {"id": "<solution-id>"}' },
      });
    }
    if (!solutions.solutionExists(id)) {
      return res.status(404).json({
        success: false,
        error: { code: 'SOLUTION_NOT_FOUND', message: `Unknown solution: ${id}` },
      });
    }

    const already = solutions.getActiveSolutionId() === id;
    const pointer = solutions.setActiveSolution(id);
    const result = await performReload();
    console.log(`Solution activated: ${id} (${result.tables} tables from ${result.path})`);

    res.json(buildSuccess({
      status: already ? 'unchanged' : 'activated',
      active: pointer.active,
      switched_at: pointer.switched_at,
      tables: result.tables,
      path: result.path,
    }));
  } catch (error) {
    console.error('Solution activate failed:', error);
    next(error);
  }
}

/**
 * GET /api/solutions — list all solution bundles (manifest scan, no DB opens).
 */
function listSolutions(req, res, next) {
  try {
    res.json(buildSuccess({ solutions: solutions.listSolutions() }));
  } catch (error) {
    next(error);
  }
}

/**
 * POST /api/solutions {"id": "...", "display_name": "...", "description": "..."}
 * Creates an empty solution bundle (skeleton + manifest v1). Token-protected.
 */
function createSolution(req, res, next) {
  try {
    if (!isAuthorized(req)) {
      return res.status(401).json({
        success: false,
        error: { code: 'UNAUTHORIZED', message: 'Invalid or missing X-Admin-Token header' },
      });
    }
    const { id, display_name: displayName, description } = req.body || {};
    const manifest = solutions.createSolution(id, { displayName, description });
    res.status(201).json(buildSuccess({ solution: manifest }));
  } catch (error) {
    if (error.code === 'INVALID_SOLUTION_ID' || error.code === 'SOLUTION_EXISTS') {
      return res.status(error.code === 'SOLUTION_EXISTS' ? 409 : 400).json({
        success: false,
        error: { code: error.code, message: error.message },
      });
    }
    next(error);
  }
}

/**
 * PATCH /api/solutions/:id — update the user-owned description block of the
 * manifest (display_name, description, maintainer, url, notes). Key-scoped
 * merge; the convert-owned technical/metrics blocks are never touched.
 * Token-protected.
 */
function updateSolution(req, res, next) {
  try {
    if (!isAuthorized(req)) {
      return res.status(401).json({
        success: false,
        error: { code: 'UNAUTHORIZED', message: 'Invalid or missing X-Admin-Token header' },
      });
    }
    const patch = req.body || {};
    if (typeof patch.display_name === 'string' && patch.display_name.trim() === '') {
      return res.status(400).json({
        success: false,
        error: { code: 'INVALID_DISPLAY_NAME', message: 'display_name must not be empty' },
      });
    }
    const manifest = solutions.updateSolutionMeta(req.params.id, patch);
    res.json(buildSuccess({ solution: manifest }));
  } catch (error) {
    if (error.code === 'SOLUTION_NOT_FOUND') {
      return res.status(404).json({ success: false, error: { code: error.code, message: error.message } });
    }
    next(error);
  }
}

/**
 * POST /api/admin/solution/rename {"from": "<id>", "to": "<id>"} — bundle
 * rename (folder name / id; the manifest UUID keeps the identity). Deliberately
 * its own admin endpoint, NOT a PATCH field: the operation touches the file
 * system and possibly the active state and must not look like a metadata edit.
 * If the renamed solution was active, the pointer/symlinks moved with it —
 * reload the API onto the new path before answering. Token-protected.
 */
async function renameSolutionBundle(req, res, next) {
  try {
    if (!isAuthorized(req)) {
      return res.status(401).json({
        success: false,
        error: { code: 'UNAUTHORIZED', message: 'Invalid or missing X-Admin-Token header' },
      });
    }
    const { from, to } = req.body || {};
    // Pool-Eintrag + Sidecar der Quelle VOR dem Verschieben schließen — offene
    // Handles auf Pfaden, die gleich umbenannt werden (Stage M: auch
    // Fremdlösungen können einen Pool-Eintrag haben).
    const db = require('../config/database');
    const annoDb = require('../config/annotations-db');
    await db.evictSolution(String(from || ''));
    await annoDb.closeSolution(String(from || ''));
    const result = solutions.renameSolution(String(from || ''), String(to || ''));
    if (result.was_active) {
      await performReload();
    }
    console.log(`Solution renamed: ${result.from} → ${result.to}${result.was_active ? ' (active, reloaded)' : ''}`);
    res.json(buildSuccess(result));
  } catch (error) {
    if (error.code === 'SOLUTION_NOT_FOUND') {
      return res.status(404).json({ success: false, error: { code: error.code, message: error.message } });
    }
    if (error.code === 'INVALID_SOLUTION_ID') {
      return res.status(400).json({ success: false, error: { code: error.code, message: error.message } });
    }
    if (error.code === 'SOLUTION_EXISTS' || error.code === 'SOLUTION_LOCKED') {
      return res.status(409).json({ success: false, error: { code: error.code, message: error.message } });
    }
    next(error);
  }
}

/**
 * DELETE /api/solutions/:id — removes the whole bundle INCLUDING the XML
 * sources (the UI shows a double confirmation + export offer before
 * calling this). The active solution cannot be deleted. Token-protected.
 */
async function deleteSolution(req, res, next) {
  try {
    if (!isAuthorized(req)) {
      return res.status(401).json({
        success: false,
        error: { code: 'UNAUTHORIZED', message: 'Invalid or missing X-Admin-Token header' },
      });
    }
    // Pool-Eintrag + Sidecar schließen, BEVOR das Bundle gelöscht wird —
    // ein anderer User könnte die Lösung gerade im Kontext haben (Stage M);
    // seine nächsten Requests laufen dann in den sauberen 404.
    const db = require('../config/database');
    const annoDb = require('../config/annotations-db');
    await db.evictSolution(req.params.id);
    await annoDb.closeSolution(req.params.id);
    const result = solutions.deleteSolution(req.params.id);
    res.json(buildSuccess(result));
  } catch (error) {
    if (error.code === 'SOLUTION_NOT_FOUND') {
      return res.status(404).json({ success: false, error: { code: error.code, message: error.message } });
    }
    if (error.code === 'SOLUTION_ACTIVE' || error.code === 'SOLUTION_DEFAULT' || error.code === 'SOLUTION_LOCKED') {
      return res.status(409).json({ success: false, error: { code: error.code, message: error.message } });
    }
    next(error);
  }
}

module.exports = {
  isAuthorized,
  reload,
  poolStatus,
  activateSolution,
  listSolutions,
  createSolution,
  updateSolution,
  renameSolutionBundle,
  deleteSolution,
};
