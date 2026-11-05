const dashboardCleanup = require('../services/dashboard-cleanup');
const testCleanup = require('../services/test-cleanup');
const updateBackupImport = require('../services/update-backup-import');
const dashboardService = require('../services/dashboard.service');
const queryDiscovery = require('../services/query-discovery');
const templateService = require('../services/template.service');
const testsService = require('../services/tests.service');
const resultsService = require('../services/results.service');
const { isAuthorized } = require('./admin.controller');
const { buildSuccess } = require('../utils/response-builder');
const { createError } = require('../middleware/error-handler');

/**
 * Maintenance Controller — HTTP only; the classification and the moves live in
 * services/dashboard-cleanup.js and services/test-cleanup.js (engine:
 * services/template-cleanup.js). Solution-independent: the handlers never read
 * req.solutionContext.
 */

const ROUTINES = {
  dashboards: {
    cleanup: dashboardCleanup,
    // Moved files change the dashboard discovery, the name resolution of
    // `custom:`/`/api/query` and the result registry.
    clearCaches() {
      dashboardService.clearCache();
      queryDiscovery.clearCache();
      templateService.clearCache();
      resultsService.clearCache();
    },
  },
  tests: {
    cleanup: testCleanup,
    clearCaches() {
      testsService.clearCache();
      resultsService.clearCache();
    },
  },
};

/**
 * GET /api/maintenance/{dashboards,tests}/cleanup — the preview plus the newest
 * automatic run at server start (`last_startup_run`) and the newest own
 * versions taken over from an update backup (`last_update_import`); null when
 * there is none. The overview reports both once.
 */
function previewCleanup(kind) {
  const { cleanup } = ROUTINES[kind];
  return async (req, res, next) => {
    try {
      res.json(buildSuccess({
        ...cleanup.preview(),
        running: cleanup.isRunning(),
        last_startup_run: cleanup.lastRun({ trigger: 'startup' }),
        last_update_import: updateBackupImport.lastImport(kind),
      }));
    } catch (err) {
      next(err);
    }
  };
}

/** POST /api/maintenance/{dashboards,tests}/cleanup */
function runCleanup(kind) {
  const { cleanup, clearCaches } = ROUTINES[kind];
  return async (req, res, next) => {
    try {
      if (!isAuthorized(req)) {
        return res.status(401).json({
          success: false,
          error: { code: 'UNAUTHORIZED', message: 'Invalid or missing X-Admin-Token header' },
        });
      }
      const exclude = req.body?.exclude ?? [];
      if (!Array.isArray(exclude) || exclude.some(e => typeof e !== 'string')) {
        throw createError('VALIDATION_ERROR', '"exclude" must be an array of strings (the "from" values of the preview)');
      }
      let report;
      try {
        report = await cleanup.run({ exclude });
      } catch (err) {
        if (err.code === 'CLEANUP_RUNNING') throw createError('CLEANUP_RUNNING', err.message);
        throw err;
      }
      if (report.moved.length) clearCaches();
      res.json(buildSuccess(report));
    } catch (err) {
      next(err);
    }
  };
}

module.exports = {
  previewDashboardCleanup: previewCleanup('dashboards'),
  runDashboardCleanup: runCleanup('dashboards'),
  previewTestCleanup: previewCleanup('tests'),
  runTestCleanup: runCleanup('tests'),
};
